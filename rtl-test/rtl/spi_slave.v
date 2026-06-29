// spi_slave.v
// SPI slave: RPi host interface (SPI0 CS1, Mode 0, MSB first, up to 10 MHz).
//
// Frame format (TRPR-SPS-002/009/010/011):
//   Byte 0 (command): [7] = R/W# (1 = read, 0 = write), [6:0] = register address.
//   Byte 1..N (data): write data on MOSI, or register read data on MISO.
//   Burst: while HOST_CS stays low, each additional data byte accesses the next
//   consecutive address (7-bit wrap).  Exception: PSRAM_DBG_DATA (0x76) does not
//   auto-increment — repeated bytes re-read the same data port.
//   The command byte 0x7F (write to 0x7F) is reserved for a future protocol
//   escape; register 0x7F is not implemented, so it is accepted and discarded.
//
// Read-data timing (TRPR-SPS-009): the command byte is parsed combinationally on
// its final (8th) rising SCK edge, so the register address tap settles during the
// following half SCK period and read data is valid for every bit of the data byte.
//
// Clock domains: shift/frame logic runs in the SPI clock domain (async reset on
// HOST_CS deassert).  Register writes cross into clk_32m via a pulse synchroniser.
// Register reads use an asynchronous address tap into the reg_bank combinational
// peek port, plus a synchronised read pulse (reg_re) for read side effects such as
// the PSRAM debug-data pop on 0x76.  reg_re fires at the START of each read data
// byte (the returned byte is already latched into the MISO shifter), so the side
// effect completes well before the next byte boundary.
//
// GF180MCU, 3.3V

module spi_slave (
    // System clock domain
    input  wire        clk_32m,
    input  wire        rst_n,

    // SPI bus (asynchronous to clk_32m)
    input  wire        HOST_CS,    // active-low chip select from RPi
    input  wire        SPI_SCK,    // SPI clock (CPOL=0 CPHA=0, up to 10 MHz)
    input  wire        SPI_MOSI,
    output reg         SPI_MISO,

    // Register bank interface
    output reg  [7:0]  reg_wr_addr,  // clk_32m domain, valid with reg_we
    output reg  [7:0]  reg_wdata,
    output reg         reg_we,       // one-cycle write strobe (clk_32m)
    output wire [7:0]  reg_rd_addr,  // asynchronous read-address tap (SPI domain)
    output reg  [7:0]  reg_re_addr,  // clk_32m domain, valid with reg_re
    output reg         reg_re,       // one-cycle read-side-effect strobe (clk_32m)
    input  wire [7:0]  reg_rdata     // combinational peek data for reg_rd_addr
);

    localparam [6:0] NO_INC_ADDR = 7'h76;  // PSRAM_DBG_DATA: burst-exempt

    // -----------------------------------------------------------------------
    // SPI domain: shift register, bit counter, frame state
    // -----------------------------------------------------------------------
    reg [7:0] spi_shreg;     // shift register (MSB first; [7] unused at capture)
    reg [2:0] spi_bit_cnt;   // counts 0..7 within each byte

    reg       have_cmd;      // command byte received; subsequent bytes are data
    reg       fp_rw;         // 1 = read transaction, 0 = write
    reg [6:0] cur_addr;      // current register address (auto-increments in burst)

    // Requests to clk_32m domain (one-SCK-period pulses, ≥3 clk_32m at 10 MHz)
    reg       spi_reg_we_req;
    reg       spi_reg_re_req;
    reg [6:0] spi_wr_addr_lat;
    reg [7:0] spi_wdata_lat;
    reg [6:0] spi_re_addr_lat;

    // Byte assembled combinationally at the 8th rising edge
    wire [7:0] byte_now = {spi_shreg[6:0], SPI_MOSI};

    always @(posedge SPI_SCK or posedge HOST_CS) begin
        if (HOST_CS) begin
            spi_shreg       <= 8'd0;
            spi_bit_cnt     <= 3'd0;
            have_cmd        <= 1'b0;
            fp_rw           <= 1'b0;
            cur_addr        <= 7'd0;
            spi_reg_we_req  <= 1'b0;
            spi_reg_re_req  <= 1'b0;
            spi_wr_addr_lat <= 7'd0;
            spi_wdata_lat   <= 8'd0;
            spi_re_addr_lat <= 7'd0;
        end else begin
            spi_reg_we_req <= 1'b0;
            spi_reg_re_req <= 1'b0;

            spi_shreg <= byte_now;

            // Read side effect: pulse once at the first bit of each read data
            // byte.  The byte being shifted out was loaded at the preceding
            // falling edge, so the pop ordering is load-then-advance.
            if (spi_bit_cnt == 3'd0 && have_cmd && fp_rw) begin
                spi_re_addr_lat <= cur_addr;
                spi_reg_re_req  <= 1'b1;
            end

            if (spi_bit_cnt == 3'd7) begin
                spi_bit_cnt <= 3'd0;
                if (!have_cmd) begin
                    // Command byte completes on this (8th) edge
                    fp_rw    <= byte_now[7];
                    cur_addr <= byte_now[6:0];
                    have_cmd <= 1'b1;
                end else begin
                    // Data byte completes
                    if (!fp_rw) begin
                        spi_wr_addr_lat <= cur_addr;
                        spi_wdata_lat   <= byte_now;
                        spi_reg_we_req  <= 1'b1;
                    end
                    // Burst auto-increment (7-bit wrap); 0x76 holds
                    if (cur_addr != NO_INC_ADDR)
                        cur_addr <= cur_addr + 7'd1;
                end
            end else begin
                spi_bit_cnt <= spi_bit_cnt + 3'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // MISO: loaded at the falling edge that precedes each data byte
    // (spi_bit_cnt == 0 after the previous byte's 8th rising edge).
    // reg_rdata is the asynchronous reg_bank peek addressed by cur_addr; it has
    // half an SCK period to settle (50 ns at the 10 MHz maximum).
    // -----------------------------------------------------------------------
    reg  [7:0] miso_shreg;
    wire [7:0] miso_byte = (have_cmd && fp_rw) ? reg_rdata : 8'h00;

    assign reg_rd_addr = {1'b0, cur_addr};

    always @(negedge SPI_SCK or posedge HOST_CS) begin
        if (HOST_CS) begin
            SPI_MISO   <= 1'b0;
            miso_shreg <= 8'd0;
        end else begin
            if (spi_bit_cnt == 3'd0) begin
                miso_shreg <= miso_byte;
                SPI_MISO   <= miso_byte[7];
            end else begin
                miso_shreg <= {miso_shreg[6:0], 1'b0};
                SPI_MISO   <= miso_shreg[6];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Clock-domain crossing: SPI → clk_32m request pulses.
    // Two-FF sync plus edge detect; the latched address/data are stable for the
    // full byte period (≥800 ns at 10 MHz) around each request.
    // -----------------------------------------------------------------------
    reg spi_we_sync0, spi_we_sync1, spi_we_sync2;
    reg spi_re_sync0, spi_re_sync1, spi_re_sync2;
    // Edge pulse held one extra cycle → reg_we is 2 clocks wide so the CE-gated
    // reg_bank (samples every other clock) always catches it.  addr/wdata are
    // latched on the edge and held, so they stay valid across both.  reg_re is
    // left 1-cycle: SPI reads use the combinational peek path (not a strobe into
    // the bank), and reg_re also drives a single-shot PSRAM-debug pop at 32 MHz.
    reg reg_we_p;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            spi_we_sync0 <= 1'b0;
            spi_we_sync1 <= 1'b0;
            spi_we_sync2 <= 1'b0;
            spi_re_sync0 <= 1'b0;
            spi_re_sync1 <= 1'b0;
            spi_re_sync2 <= 1'b0;
            reg_wr_addr  <= 8'd0;
            reg_wdata    <= 8'd0;
            reg_we       <= 1'b0;
            reg_we_p     <= 1'b0;
            reg_re_addr  <= 8'd0;
            reg_re       <= 1'b0;
        end else begin
            spi_we_sync0 <= spi_reg_we_req;
            spi_we_sync1 <= spi_we_sync0;
            spi_we_sync2 <= spi_we_sync1;
            spi_re_sync0 <= spi_reg_re_req;
            spi_re_sync1 <= spi_re_sync0;
            spi_re_sync2 <= spi_re_sync1;

            // 2-cycle-wide write strobe (edge pulse OR its 1-cycle delay)
            reg_we_p <= spi_we_sync1 && !spi_we_sync2;
            reg_we <= (spi_we_sync1 && !spi_we_sync2) || reg_we_p;
            reg_re <= spi_re_sync1 && !spi_re_sync2;

            if (spi_we_sync1 && !spi_we_sync2) begin
                reg_wr_addr <= {1'b0, spi_wr_addr_lat};
                reg_wdata   <= spi_wdata_lat;
            end
            if (spi_re_sync1 && !spi_re_sync2) begin
                reg_re_addr <= {1'b0, spi_re_addr_lat};
            end
        end
    end

endmodule
