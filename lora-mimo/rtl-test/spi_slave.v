// spi_slave.v
// SPI slave: RPi host interface (SPI0 CS1, Mode 0, MSB first, up to 10 MHz).
//
// Two transaction classes:
//   Normal (2-byte): Byte0 != 0x7F → [7]=R/W# [6:0]=addr, Byte1=data
//   Extended (N+5 bytes): Byte0 = 0x7F → opcode / addr_hi / addr_lo / len-1 / payload
//     Opcode 0x01 = firmware load write  (CPU SRAM, 0x000–0xFFF)
//     Opcode 0x02 = firmware readback    (MISO returns SRAM contents from byte 5)
//
// Clock domain: SPI shift and frame parser run in the SPI clock domain.
// Completed register operations are crossed into clk_32m via a small pulse-sync.
// Firmware-load bytes are written directly into the fw_ld_* port on the SPI clock
// (downstream SRAM write latency >> one SPI byte period at 10 MHz).
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

    // Register bank interface (clk_32m domain)
    output reg  [7:0]  reg_addr,
    output reg  [7:0]  reg_wdata,
    output reg         reg_we,
    input  wire [7:0]  reg_rdata,

    // Firmware-load port (SPI clock domain — strobe from SPI domain, addr auto-inc)
    output reg  [11:0] fw_ld_addr,
    output reg  [7:0]  fw_ld_wdata,
    output reg         fw_ld_we,
    input  wire [7:0]  fw_ld_rdata,
    output reg         fw_ld_req,
    input  wire        fw_ld_ready
);

    // -----------------------------------------------------------------------
    // SPI domain: shift register and byte assembler
    // -----------------------------------------------------------------------
    // All logic clocked on rising SPI_SCK, reset on HOST_CS deassert (high).

    reg [7:0]  spi_shreg;      // 8-bit shift register (MSB first)
    reg [2:0]  spi_bit_cnt;    // counts 0..7
    reg        spi_byte_rdy;   // pulses for one SCK cycle when a byte is complete
    reg [7:0]  spi_byte;       // assembled byte

    // MISO output: driven on falling SCK edge (sampled by host on rising SCK)
    reg [7:0]  miso_shreg;

    // Frame parser state (SPI domain)
    localparam FP_BYTE0    = 3'd0;  // waiting for first byte
    localparam FP_BYTE1    = 3'd1;  // normal frame second byte
    localparam FP_EXT_OP   = 3'd2;  // extended: opcode
    localparam FP_EXT_AH   = 3'd3;  // extended: addr_hi
    localparam FP_EXT_AL   = 3'd4;  // extended: addr_lo
    localparam FP_EXT_LEN  = 3'd5;  // extended: len-1
    localparam FP_EXT_DATA = 3'd6;  // extended: payload bytes

    reg [2:0]  fp_state;
    reg        fp_rw;          // 1=read, 0=write (normal frame)
    reg [7:0]  fp_reg_addr;    // register address (normal frame)
    reg [7:0]  fp_opcode;
    reg [11:0] fp_fw_addr;     // current firmware-load address
    reg [7:0]  fp_len_rem;     // remaining payload bytes

    // Register-access request to clk_32m domain (pulse in SPI domain)
    reg        spi_reg_we_req; // write strobe (SPI domain)
    reg [7:0]  spi_reg_addr_lat;
    reg [7:0]  spi_reg_wdata_lat;

    // MISO source mux: register read data or fw readback, latched at byte boundary
    reg [7:0]  miso_byte;

    // Rising-edge SCK: shift in MOSI, pulse byte_rdy every 8 bits
    always @(posedge SPI_SCK or posedge HOST_CS) begin
        if (HOST_CS) begin
            spi_bit_cnt  <= 3'd0;
            spi_byte_rdy <= 1'b0;
            spi_shreg    <= 8'd0;
        end else begin
            spi_shreg    <= {spi_shreg[6:0], SPI_MOSI};
            spi_byte_rdy <= (spi_bit_cnt == 3'd7);
            if (spi_bit_cnt == 3'd7) begin
                spi_byte    <= {spi_shreg[6:0], SPI_MOSI};
                spi_bit_cnt <= 3'd0;
            end else begin
                spi_bit_cnt <= spi_bit_cnt + 3'd1;
            end
        end
    end

    // Falling-edge SCK: shift out MISO
    always @(negedge SPI_SCK or posedge HOST_CS) begin
        if (HOST_CS) begin
            SPI_MISO  <= 1'b0;
            miso_shreg <= 8'd0;
        end else begin
            if (spi_bit_cnt == 3'd0) begin
                // Load new byte into MISO shift register at the start of each byte
                miso_shreg <= miso_byte;
                SPI_MISO   <= miso_byte[7];
            end else begin
                miso_shreg <= {miso_shreg[6:0], 1'b0};
                SPI_MISO   <= miso_shreg[6];
            end
        end
    end

    // Frame parser: triggered when spi_byte_rdy pulses (once per complete byte)
    always @(posedge SPI_SCK or posedge HOST_CS) begin
        if (HOST_CS) begin
            fp_state          <= FP_BYTE0;
            fp_rw             <= 1'b0;
            fp_reg_addr       <= 8'd0;
            fp_opcode         <= 8'd0;
            fp_fw_addr        <= 12'd0;
            fp_len_rem        <= 8'd0;
            spi_reg_we_req    <= 1'b0;
            spi_reg_addr_lat  <= 8'd0;
            spi_reg_wdata_lat <= 8'd0;
            fw_ld_addr        <= 12'd0;
            fw_ld_wdata       <= 8'd0;
            fw_ld_we          <= 1'b0;
            fw_ld_req         <= 1'b0;
            miso_byte         <= 8'd0;
        end else begin
            spi_reg_we_req <= 1'b0;
            fw_ld_we       <= 1'b0;

            if (spi_byte_rdy) begin
                case (fp_state)
                    FP_BYTE0: begin
                        if (spi_byte == 8'h7F) begin
                            // Extended command escape
                            fp_state  <= FP_EXT_OP;
                            miso_byte <= 8'h00;
                        end else begin
                            // Normal 2-byte register frame
                            fp_rw       <= spi_byte[7];   // 1=read, 0=write
                            fp_reg_addr <= {1'b0, spi_byte[6:0]};
                            fp_state    <= FP_BYTE1;
                            // Pre-load MISO with register data for read transactions
                            miso_byte   <= reg_rdata;
                        end
                    end

                    FP_BYTE1: begin
                        // Second byte of normal frame
                        if (!fp_rw) begin
                            // Write: latch and request clk_32m-domain write
                            spi_reg_addr_lat  <= fp_reg_addr;
                            spi_reg_wdata_lat <= spi_byte;
                            spi_reg_we_req    <= 1'b1;
                        end
                        miso_byte <= 8'h00;
                        fp_state  <= FP_BYTE0;
                    end

                    FP_EXT_OP: begin
                        fp_opcode <= spi_byte;
                        miso_byte <= 8'h00;
                        fp_state  <= FP_EXT_AH;
                    end

                    FP_EXT_AH: begin
                        fp_fw_addr[11:8] <= spi_byte[3:0];
                        miso_byte        <= 8'h00;
                        fp_state         <= FP_EXT_AL;
                    end

                    FP_EXT_AL: begin
                        fp_fw_addr[7:0] <= spi_byte;
                        miso_byte       <= 8'h00;
                        fp_state        <= FP_EXT_LEN;
                    end

                    FP_EXT_LEN: begin
                        fp_len_rem <= spi_byte;   // transfer count = spi_byte + 1
                        miso_byte  <= 8'h00;
                        fp_state   <= FP_EXT_DATA;
                    end

                    FP_EXT_DATA: begin
                        if (fp_opcode == 8'h01) begin
                            // Firmware load write
                            if (fp_fw_addr <= 12'hFFF) begin
                                fw_ld_addr  <= fp_fw_addr;
                                fw_ld_wdata <= spi_byte;
                                fw_ld_we    <= 1'b1;
                                fw_ld_req   <= 1'b1;
                            end
                            miso_byte <= 8'h00;
                        end else if (fp_opcode == 8'h02) begin
                            // Firmware readback: MISO carries current address data
                            miso_byte <= fw_ld_rdata;
                        end else begin
                            miso_byte <= 8'h00;
                        end

                        if (fp_len_rem == 8'd0) begin
                            fp_state   <= FP_BYTE0;
                            fw_ld_req  <= 1'b0;
                        end else begin
                            fp_fw_addr <= fp_fw_addr + 12'd1;
                            fp_len_rem <= fp_len_rem - 8'd1;
                        end
                    end

                    default: fp_state <= FP_BYTE0;
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Clock-domain crossing: SPI → clk_32m for register writes
    // Two-FF sync on spi_reg_we_req pulse, edge-detect to produce reg_we strobe.
    // -----------------------------------------------------------------------
    reg spi_we_sync0, spi_we_sync1, spi_we_sync2;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            spi_we_sync0 <= 1'b0;
            spi_we_sync1 <= 1'b0;
            spi_we_sync2 <= 1'b0;
            reg_addr     <= 8'd0;
            reg_wdata    <= 8'd0;
            reg_we       <= 1'b0;
        end else begin
            spi_we_sync0 <= spi_reg_we_req;
            spi_we_sync1 <= spi_we_sync0;
            spi_we_sync2 <= spi_we_sync1;

            // Rising edge of synced pulse → generate one-cycle reg_we strobe
            reg_we <= spi_we_sync1 && !spi_we_sync2;
            if (spi_we_sync1 && !spi_we_sync2) begin
                reg_addr  <= spi_reg_addr_lat;
                reg_wdata <= spi_reg_wdata_lat;
            end
        end
    end

endmodule
