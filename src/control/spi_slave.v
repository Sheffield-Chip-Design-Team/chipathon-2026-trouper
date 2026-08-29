// spi_slave.v
// SPI slave: RPi host interface (SPI0 CS1, Mode 0, MSB first, up to 2 MHz).
//
// Frame format (TRPR-SPS-002/009/010/011):
//   Byte 0 (command): [7] = R/W# (1 = read, 0 = write), [6:0] = register address.
//   Byte 1..N (data): write data on MOSI, or register read data on MISO.
//   Burst: while HOST_CS stays low, each additional data byte accesses the next
//   consecutive address (7-bit wrap).  Exception: the PSRAM debug data ports
//   PSRAM_DBG_DATA (0x76, read) and PSRAM_DBG_WDATA (0x79, write) do not
//   auto-increment — repeated bytes re-access the same port (0x76 re-reads the
//   same window byte-by-byte; 0x79 pushes successive bytes into the write shadow).
//   The command byte 0x7F (write to 0x7F) is reserved for a future protocol
//   escape; register 0x7F is not implemented, so it is accepted and discarded.
//
// Read-data timing (TRPR-SPS-009): the command byte is parsed combinationally on
// its final (8th) rising SCK edge, so the register address tap settles during the
// following half SCK period and read data is valid for every bit of the data byte.
//
// Clock domains: shift/frame logic runs in the SPI clock domain (async reset on
// HOST_CS deassert).  Register writes cross into clk_32m via a toggle
// synchroniser and bundled-data mailbox; completed events therefore survive
// HOST_CS deassertion.
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
    input  wire        SPI_SCK,    // SPI clock (CPOL=0 CPHA=0, up to 2 MHz)
    input  wire        SPI_MOSI,
    output reg         SPI_MISO,

    // Register bank interface
    output reg  [7:0]  reg_wr_addr,  // clk_32m domain, valid with reg_we
    output reg  [7:0]  reg_wdata,
    output reg         reg_we,       // two-cycle write strobe (clk_32m)
    output wire [7:0]  reg_rd_addr,  // asynchronous read-address tap (SPI domain)
    output reg  [7:0]  reg_re_addr,  // clk_32m domain, valid with reg_re
    output reg         reg_re,       // one-cycle read-side-effect strobe (clk_32m)
    input  wire [7:0]  reg_rdata     // combinational peek data for reg_rd_addr
);

    // PSRAM debug data ports: burst-exempt (address holds across the burst).
    localparam [6:0] NO_INC_RD_ADDR = 7'h76;  // PSRAM_DBG_DATA  (read pop)
    localparam [6:0] NO_INC_WR_ADDR = 7'h79;  // PSRAM_DBG_WDATA (write push)

    // -----------------------------------------------------------------------
    // SPI domain: shift register, bit counter, frame state
    // -----------------------------------------------------------------------
    reg [7:0] spi_shreg;     // shift register (MSB first; [7] unused at capture)
    reg [2:0] spi_bit_cnt;   // counts 0..7 within each byte

    reg       have_cmd;      // command byte received; subsequent bytes are data
    reg       fp_rw;         // 1 = read transaction, 0 = write
    reg [6:0] cur_addr;      // current register address (auto-increments in burst)

    // Persistent event toggles and bundled-data mailboxes.  Unlike frame state,
    // these are reset only by rst_n so a completed event cannot be erased when
    // HOST_CS rises immediately after the final SCK edge.
    reg       spi_we_toggle;
    reg       spi_re_toggle;
    reg [6:0] spi_wr_addr_lat;
    reg [7:0] spi_wdata_lat;
    reg [6:0] spi_re_addr_lat;

    // Byte assembled combinationally at the 8th rising edge
    wire [7:0] byte_now = {spi_shreg[6:0], SPI_MOSI};

    // Async reset for the SPI-clock-domain frame flops.  HOST_CS idles high and
    // sees no rising edge until the FIRST transaction ends, so gating the reset
    // on HOST_CS alone leaves these flops uninitialised at power-on — the first
    // post-reset transaction would then parse against random state and be lost
    // (Open Risks #26).  Fold the chip reset into the async-clear term so the
    // frame comes up cleared without relying on a HOST_CS edge.  A single OR'd
    // reset signal (not two edge events) keeps this a one-async-reset flop that
    // synthesis accepts; the reset pin is level-sensitive in silicon, so it is
    // held asserted for the whole rst_n=0 window regardless of HOST_CS.
    wire spi_frame_arst = HOST_CS | ~rst_n;

    always @(posedge SPI_SCK or posedge spi_frame_arst) begin
        if (spi_frame_arst) begin
            spi_shreg       <= 8'd0;
            spi_bit_cnt     <= 3'd0;
            have_cmd        <= 1'b0;
            fp_rw           <= 1'b0;
            cur_addr        <= 7'd0;
        end else begin
            spi_shreg <= byte_now;

            if (spi_bit_cnt == 3'd7) begin
                spi_bit_cnt <= 3'd0;
                if (!have_cmd) begin
                    // Command byte completes on this (8th) edge
                    fp_rw    <= byte_now[7];
                    cur_addr <= byte_now[6:0];
                    have_cmd <= 1'b1;
                end else begin
                    // Data byte completes
                    // Burst auto-increment (7-bit wrap); 0x76/0x79 hold
                    if (cur_addr != NO_INC_RD_ADDR && cur_addr != NO_INC_WR_ADDR)
                        cur_addr <= cur_addr + 7'd1;
                end
            end else begin
                spi_bit_cnt <= spi_bit_cnt + 3'd1;
            end
        end
    end

    // Completed-byte events must outlive the SPI frame.  This block observes
    // the pre-edge frame state above, latches the bundled payload, and toggles
    // one bit per event.  At 2 MHz consecutive events are at least one byte
    // (4 us) apart, leaving >128 clk_32m cycles for the destination to observe
    // each toggle.  Guard with HOST_CS in case SCK toggles while deselected.
    always @(posedge SPI_SCK or negedge rst_n) begin
        if (!rst_n) begin
            spi_we_toggle   <= 1'b0;
            spi_re_toggle   <= 1'b0;
            spi_wr_addr_lat <= 7'd0;
            spi_wdata_lat   <= 8'd0;
            spi_re_addr_lat <= 7'd0;
        end else if (!HOST_CS) begin
            // Read side effect: event once at the first bit of each read data
            // byte.  The returned byte was loaded at the preceding falling
            // edge, so the ordering remains load-then-advance.
            if (spi_bit_cnt == 3'd0 && have_cmd && fp_rw) begin
                spi_re_addr_lat <= cur_addr;
                spi_re_toggle   <= ~spi_re_toggle;
            end

            if (spi_bit_cnt == 3'd7 && have_cmd && !fp_rw) begin
                spi_wr_addr_lat <= cur_addr;
                spi_wdata_lat   <= byte_now;
                spi_we_toggle   <= ~spi_we_toggle;
            end
        end
    end

    // -----------------------------------------------------------------------
    // MISO: loaded at the falling edge that precedes each data byte
    // (spi_bit_cnt == 0 after the previous byte's 8th rising edge).
    // reg_rdata is the asynchronous reg_bank peek addressed by cur_addr; it has
    // half an SCK period to settle (250 ns at the 2 MHz maximum).
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
    // Clock-domain crossing: SPI → clk_32m persistent event toggles.
    // Two-FF sync plus change detect; the bundled address/data are stable for
    // the full byte period (≥4 us at 2 MHz) around each event.
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
            spi_we_sync0 <= spi_we_toggle;
            spi_we_sync1 <= spi_we_sync0;
            spi_we_sync2 <= spi_we_sync1;
            spi_re_sync0 <= spi_re_toggle;
            spi_re_sync1 <= spi_re_sync0;
            spi_re_sync2 <= spi_re_sync1;

            // 2-cycle-wide write strobe (edge pulse OR its 1-cycle delay)
            reg_we_p <= spi_we_sync1 ^ spi_we_sync2;
            reg_we <= (spi_we_sync1 ^ spi_we_sync2) || reg_we_p;
            reg_re <= spi_re_sync1 ^ spi_re_sync2;

            if (spi_we_sync1 ^ spi_we_sync2) begin
                reg_wr_addr <= {1'b0, spi_wr_addr_lat};
                reg_wdata   <= spi_wdata_lat;
            end
            if (spi_re_sync1 ^ spi_re_sync2) begin
                reg_re_addr <= {1'b0, spi_re_addr_lat};
            end
        end
    end

`ifdef FORMAL
    // Formal-only checker instantiation (see formal/spi_slave_formal.sv).
    // Dead code in every real build: read_verilog defines FORMAL only when
    // passed `-formal` (yosys's sby-driven proof flow); LibreLane synthesis
    // and cocotb (Icarus/Verilator) never pass that flag and get SYNTHESIS
    // instead, so this instantiation never exists outside `sby`. Deliberately
    // NOT a `bind` — this yosys version silently drops `bind` statements
    // (confirmed 2026-07-05 by the psram_buf_ctrl checker), which made every
    // bind-based proof vacuous. Do NOT delete this block (commit 0c0171a did
    // exactly that to psram_buf_ctrl.v, silently making its sby proof prove
    // nothing while still reporting PASS).
    spi_slave_formal u_spi_slave_formal (
        .clk_32m         (clk_32m),
        .rst_n           (rst_n),
        .HOST_CS         (HOST_CS),
        .SPI_SCK         (SPI_SCK),
        .SPI_MOSI        (SPI_MOSI),
        .SPI_MISO        (SPI_MISO),
        .reg_wr_addr     (reg_wr_addr),
        .reg_wdata       (reg_wdata),
        .reg_we          (reg_we),
        .reg_rd_addr     (reg_rd_addr),
        .reg_re_addr     (reg_re_addr),
        .reg_re          (reg_re),
        .reg_rdata       (reg_rdata),
        .spi_shreg       (spi_shreg),
        .spi_bit_cnt     (spi_bit_cnt),
        .have_cmd        (have_cmd),
        .fp_rw           (fp_rw),
        .cur_addr        (cur_addr),
        .spi_we_toggle   (spi_we_toggle),
        .spi_re_toggle   (spi_re_toggle),
        .spi_wr_addr_lat (spi_wr_addr_lat),
        .spi_wdata_lat   (spi_wdata_lat),
        .spi_re_addr_lat (spi_re_addr_lat),
        .spi_we_sync0    (spi_we_sync0),
        .spi_we_sync1    (spi_we_sync1),
        .spi_we_sync2    (spi_we_sync2),
        .spi_re_sync0    (spi_re_sync0),
        .spi_re_sync1    (spi_re_sync1),
        .spi_re_sync2    (spi_re_sync2),
        .reg_we_p        (reg_we_p)
    );
`endif

endmodule
