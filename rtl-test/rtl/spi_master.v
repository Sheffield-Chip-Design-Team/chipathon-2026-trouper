// spi_master.v
// SPI master for SX1257 configuration (Mode 0, MSB first, 4 MHz default = 32 MHz / 8).
// 16-bit transactions: [15]=WNR [14:8]=REG_ADDR [7:0]=DATA.
// CS_A[1:0] drives a board-level 74HC139 decoder → SX1257_0..3 NSS lines.
// AHB-Lite slave port (from ahb_lite_bus slave 1).
// GF180MCU, 3.3V, 32 MHz single clock domain

module spi_master #(
    parameter SCK_DIV = 4   // SCK half-period = SCK_DIV clk_32m cycles; default /8 = 4 MHz
) (
    input  wire       clk_32m,
    input  wire       rst_n,

    // AHB-Lite slave port
    input  wire [7:0] s_addr,
    input  wire [7:0] s_wdata,
    input  wire       s_we,
    input  wire       s_re,
    output reg  [7:0] s_rdata,
    output wire       s_ready,

    // Pass-through trigger from register bank (W1P from SX_CTRL.START)
    input  wire       sx_start,        // one-cycle strobe: begin transaction
    input  wire       sx_rnw,          // 0=write, 1=read
    input  wire [1:0] sx_target,       // SX1257 device 0..3
    input  wire [6:0] sx_addr_in,      // SX1257 register address
    input  wire [7:0] sx_wdata_in,     // write payload

    // Read-data result back to register bank
    output reg  [7:0] sx_rdata_out,    // captured MISO byte (read transactions)
    output reg        sx_rdata_valid,  // one-cycle strobe when rdata updated

    // SPI bus
    output reg        SPI_SCK,
    output reg        SPI_MOSI,
    input  wire       SPI_MISO,
    output reg  [1:0] CS_A,            // device address to 74HC139 decoder

    output wire       busy             // high during active transaction
);

    assign s_ready = 1'b1;    // register-map reads/writes always single-cycle

    // -----------------------------------------------------------------------
    // Internal registers (local shadow of SX_TARGET/ADDR/DATA/CTRL)
    // -----------------------------------------------------------------------
    reg        tx_rnw;
    reg [1:0]  tx_target;
    reg [6:0]  tx_reg_addr;
    reg [7:0]  tx_wdata;

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    localparam ST_IDLE    = 3'd0;
    localparam ST_CS_SETUP = 3'd1;   // CS_A stable, SCK still low
    localparam ST_SHIFT   = 3'd2;    // shifting 16 bits
    localparam ST_CS_HOLD = 3'd3;    // final SCK low, before CS release
    localparam ST_DONE    = 3'd4;    // capture MISO, pulse rdata_valid

    reg [2:0]  state;
    assign busy = (state != ST_IDLE);
    reg [4:0]  bit_cnt;    // counts 0..15 (16 bits)
    reg [15:0] shift_out;  // MOSI shift register
    reg [7:0]  shift_in;   // MISO capture
    reg [3:0]  div_cnt;    // SCK divider counter

    wire div_done = (div_cnt == SCK_DIV - 1);

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            SPI_SCK      <= 1'b0;
            SPI_MOSI     <= 1'b0;
            CS_A         <= 2'd0;
            sx_rdata_out  <= 8'd0;
            sx_rdata_valid <= 1'b0;
            s_rdata      <= 8'd0;
            tx_rnw       <= 1'b0;
            tx_target    <= 2'd0;
            tx_reg_addr  <= 7'd0;
            tx_wdata     <= 8'd0;
            shift_out    <= 16'd0;
            shift_in     <= 8'd0;
            div_cnt      <= 4'd0;
            bit_cnt      <= 5'd0;
        end else begin
            sx_rdata_valid <= 1'b0;

            // AHB-Lite register read (local shadow regs, addr offset within slave)
            if (s_re) begin
                case (s_addr[2:0])
                    3'd0: s_rdata <= {6'd0, tx_target};
                    3'd1: s_rdata <= {1'b0, tx_reg_addr};
                    3'd2: s_rdata <= tx_wdata;
                    3'd3: s_rdata <= {5'd0, busy, tx_rnw, 1'b0};
                    default: s_rdata <= 8'd0;
                endcase
            end

            // AHB-Lite register write (local shadow only; sx_start triggers TX)
            if (s_we) begin
                case (s_addr[2:0])
                    3'd0: tx_target   <= s_wdata[1:0];
                    3'd1: tx_reg_addr <= s_wdata[6:0];
                    3'd2: tx_wdata    <= s_wdata;
                    default: ;
                endcase
            end

            case (state)
                ST_IDLE: begin
                    SPI_SCK  <= 1'b0;
                    div_cnt  <= 4'd0;
                    bit_cnt  <= 5'd0;
                    if (sx_start && !busy) begin
                        // Latch transaction parameters
                        tx_rnw      <= sx_rnw;
                        tx_target   <= sx_target;
                        tx_reg_addr <= sx_addr_in;
                        tx_wdata    <= sx_wdata_in;
                        // Build 16-bit shift word: [15]=WNR [14:8]=addr [7:0]=data
                        shift_out <= {~sx_rnw, sx_addr_in, sx_wdata_in};
                        CS_A      <= sx_target;
                        state     <= ST_CS_SETUP;
                    end
                end

                ST_CS_SETUP: begin
                    // One cycle with CS_A stable and SCK low before first edge
                    SPI_MOSI <= shift_out[15];
                    state    <= ST_SHIFT;
                    div_cnt  <= 4'd0;
                end

                ST_SHIFT: begin
                    if (div_done) begin
                        div_cnt <= 4'd0;
                        if (!SPI_SCK) begin
                            // Rising edge: data already on MOSI; sample MISO
                            SPI_SCK  <= 1'b1;
                            shift_in <= {shift_in[6:0], SPI_MISO};
                        end else begin
                            // Falling edge: shift out next bit
                            SPI_SCK <= 1'b0;
                            if (bit_cnt == 5'd15) begin
                                state <= ST_CS_HOLD;
                            end else begin
                                shift_out <= {shift_out[14:0], 1'b0};
                                SPI_MOSI  <= shift_out[14];
                                bit_cnt   <= bit_cnt + 5'd1;
                            end
                        end
                    end else begin
                        div_cnt <= div_cnt + 4'd1;
                    end
                end

                ST_CS_HOLD: begin
                    // SCK already low after last falling edge; release CS next cycle
                    state <= ST_DONE;
                end

                ST_DONE: begin
                    CS_A <= 2'd0;
                    if (tx_rnw) begin
                        sx_rdata_out   <= shift_in;
                        sx_rdata_valid <= 1'b1;
                    end
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
