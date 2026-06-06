// psram_buf_ctrl.v
// Same-packet MRC PSRAM buffer controller for APS6404L-3SQR (64 Mbit QPI PSRAM).
//
// Always-writing circular buffer: writes 8 bytes (4-branch IQ) per iq_valid
// continuously once initialised. At sc_lock, buf_base is back-calculated to the
// preamble start using timing_ref. At W_commit, switches to REPLAY: interleaved
// QPI read (from buf_base) + write (live), feeding replay IQ to the combiner.
//
// Timing at 32 MHz:
//   QPI write: 25 sub-cycles. QPI read: 31 sub-cycles. Total REPLAY: 56 cycles.
//   Budget at 125 kHz: 256 cycles. Budget at 500 kHz: 64 cycles (8 spare). ✓
//   At 1 MS/s (32 cycles): REPLAY impossible — falls back to next-packet.
//
// QPI init sequence (SPI serial mode on SIO[0]):
//   RSTEN(0x66) → RST(0x99) → tRST wait → Enter QPI(0x35)
//   Device then responds to 4-bit-wide QPI commands.
//
// Sample format in PSRAM (8 bytes/sample):
//   byte 0=i0, 1=q0, 2=i1, 3=q1, 4=i2, 5=q2, 6=i3, 7=q3
//
// GF180MCU, 3.3V, 32 MHz

module psram_buf_ctrl (
    input  wire        clk_32m,
    input  wire        rst_n,

    // Config
    input  wire        psram_en,     // 1 = capture and replay enabled
    input  wire        init_start,   // firmware strobe after tPU ≥ 150 µs

    // Live IQ stream (4 branches, 8-bit signed)
    input  wire signed [7:0] iq_i0, iq_i1, iq_i2, iq_i3,
    input  wire signed [7:0] iq_q0, iq_q1, iq_q2, iq_q3,
    input  wire        iq_valid,

    // Packet control
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,    // preamble-start sample index from sc_detector
    input  wire [31:0] iq_sample_cnt, // free-running iq_valid counter from mimo_rx_top
    input  wire        W_commit,
    input  wire        packet_end,

    // QPI pad interface (shared with JTAG at padframe level)
    output wire        sck,           // PSRAM clock (32 MHz, gated internally)
    output reg         ce_n,          // PSRAM CE# active-low
    output reg  [3:0]  sio_out,       // SIO[3:0] output to PSRAM
    input  wire [3:0]  sio_in,        // SIO[3:0] input from PSRAM
    output reg  [3:0]  sio_oe,        // output-enable (1=ASIC drives, 0=PSRAM drives)

    // Replay IQ output — muxed into combiner during REPLAY
    output reg  signed [7:0] rpl_i0, rpl_i1, rpl_i2, rpl_i3,
    output reg  signed [7:0] rpl_q0, rpl_q1, rpl_q2, rpl_q3,
    output reg         rpl_valid,     // one pulse per replayed sample

    // Status
    output reg         buf_active,    // sc_lock → packet_end (BUFFERING or REPLAY)
    output reg         replay_active, // W_commit → packet_end
    output reg         qe_init_done,
    output reg         replay_missed, // sticky: packet_end before W_commit
    output reg         overflow,      // sticky: wr_ptr lapped rd_ptr
    output reg  [2:0]  state_dbg
);

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam S_UNINIT  = 3'd0;
    localparam S_QE_INIT = 3'd1;
    localparam S_WRITE   = 3'd2;
    localparam S_REPLAY  = 3'd3;
    reg [2:0] state;

    // -----------------------------------------------------------------------
    // PSRAM address pointers — 23-bit (8 MB = 2^23 bytes), circular
    // -----------------------------------------------------------------------
    localparam ABITS = 23;
    localparam AMASK = 23'h7FFFFF;

    reg [ABITS-1:0] wr_ptr;
    reg [ABITS-1:0] rd_ptr;
    reg [ABITS-1:0] buf_base;
    reg             buf_base_valid;
    reg             sc_lock_prev;

    // -----------------------------------------------------------------------
    // QPI transaction sub-cycle FSM
    //   sub 0..24  : QPI write  (cmd 2 + addr 6 + data 16 + CE#-high 1)
    //   sub 25..55 : QPI read   (cmd 2 + addr 6 + dummy 6 + data 16 + CE#-high 1)
    //                            only executed in S_REPLAY
    // -----------------------------------------------------------------------
    reg [5:0] sub;
    reg       qpi_busy;

    reg [63:0] wr_data;  // {i0,q0,i1,q1,i2,q2,i3,q3} latched from iq_valid
    reg [63:0] rd_data;  // accumulated nibbles from PSRAM during read phase

    // -----------------------------------------------------------------------
    // QE_INIT sub-cycle FSM
    //   Sends RSTEN(0x66), RST(0x99), wait tRST, Enter QPI(0x35) in SPI mode.
    //   Each command: CE# low + 8 bit-cycles + CE# high = 10 cycles.
    //   tRST wait: 2 cycles. Total: 3×10 + 2 = 32 sub-cycles.
    // -----------------------------------------------------------------------
    reg [5:0] init_sub;
    reg [7:0] init_sr;   // serial shift register for SPI output

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    reg  sck_en;
    assign sck = sck_en & clk_32m;

    wire [ABITS-1:0] cur_wr = wr_ptr;
    wire [ABITS-1:0] cur_rd = rd_ptr;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_UNINIT;
            wr_ptr         <= {ABITS{1'b0}};
            rd_ptr         <= {ABITS{1'b0}};
            buf_base       <= {ABITS{1'b0}};
            buf_base_valid <= 1'b0;
            sc_lock_prev   <= 1'b0;
            sub            <= 6'd0;
            qpi_busy       <= 1'b0;
            wr_data        <= 64'd0;
            rd_data        <= 64'd0;
            init_sub       <= 6'd0;
            init_sr        <= 8'd0;
            sck_en         <= 1'b0;
            ce_n           <= 1'b1;
            sio_out        <= 4'd0;
            sio_oe         <= 4'd0;
            rpl_i0 <= 8'sd0; rpl_q0 <= 8'sd0;
            rpl_i1 <= 8'sd0; rpl_q1 <= 8'sd0;
            rpl_i2 <= 8'sd0; rpl_q2 <= 8'sd0;
            rpl_i3 <= 8'sd0; rpl_q3 <= 8'sd0;
            rpl_valid      <= 1'b0;
            buf_active     <= 1'b0;
            replay_active  <= 1'b0;
            qe_init_done   <= 1'b0;
            replay_missed  <= 1'b0;
            overflow       <= 1'b0;
            state_dbg      <= 3'd0;
        end else begin
            sc_lock_prev <= sc_lock;
            rpl_valid    <= 1'b0;
            state_dbg    <= state;

            // ----------------------------------------------------------------
            // Global: sck_en follows qpi_busy or QE_INIT activity
            // ----------------------------------------------------------------
            sck_en <= (state == S_QE_INIT) || qpi_busy;

            case (state)

                // ------------------------------------------------------------
                // S_UNINIT — wait for firmware init_start after tPU ≥ 150 µs
                // ------------------------------------------------------------
                S_UNINIT: begin
                    ce_n   <= 1'b1;
                    sio_oe <= 4'd0;
                    if (init_start) begin
                        state    <= S_QE_INIT;
                        init_sub <= 6'd0;
                        init_sr  <= 8'h66; // RSTEN
                    end
                end

                // ------------------------------------------------------------
                // S_QE_INIT — SPI serial: RSTEN → RST → wait → Enter QPI
                // SIO[0] = MOSI, 1 bit per clock, MSB first.
                // Sub 0-9:  RSTEN (0x66)    CE#↓ bit7..bit0 CE#↑ gap
                // Sub 10-20: RST  (0x99)    CE#↓ bit7..bit0 CE#↑ tRST×2
                // Sub 21-31: Enter QPI(0x35) CE#↓ bit7..bit0 CE#↑ done
                // ------------------------------------------------------------
                S_QE_INIT: begin
                    sio_oe <= 4'b0001; // drive only SIO[0]

                    case (init_sub)
                        // --- RSTEN (0x66) ---
                        6'd0:  begin ce_n <= 1'b0; sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd1; end
                        6'd1:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd2; end
                        6'd2:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd3; end
                        6'd3:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd4; end
                        6'd4:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd5; end
                        6'd5:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd6; end
                        6'd6:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd7; end
                        6'd7:  begin sio_out <= {3'd0, init_sr[7]}; init_sub <= 6'd8; end
                        6'd8:  begin ce_n <= 1'b1; sio_oe <= 4'd0; init_sub <= 6'd9; end
                        6'd9:  begin init_sr <= 8'h99; init_sub <= 6'd10; end // gap; load RST
                        // --- RST (0x99) ---
                        6'd10: begin ce_n <= 1'b0; sio_oe <= 4'b0001; sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd11; end
                        6'd11: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd12; end
                        6'd12: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd13; end
                        6'd13: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd14; end
                        6'd14: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd15; end
                        6'd15: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd16; end
                        6'd16: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd17; end
                        6'd17: begin sio_out <= {3'd0, init_sr[7]}; init_sub <= 6'd18; end
                        6'd18: begin ce_n <= 1'b1; sio_oe <= 4'd0; init_sub <= 6'd19; end
                        6'd19: init_sub <= 6'd20; // tRST wait cycle 1
                        6'd20: begin init_sr <= 8'h35; init_sub <= 6'd21; end // tRST cycle 2; load Enter QPI
                        // --- Enter QPI (0x35) ---
                        6'd21: begin ce_n <= 1'b0; sio_oe <= 4'b0001; sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd22; end
                        6'd22: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd23; end
                        6'd23: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd24; end
                        6'd24: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd25; end
                        6'd25: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd26; end
                        6'd26: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd27; end
                        6'd27: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd28; end
                        6'd28: begin sio_out <= {3'd0, init_sr[7]}; init_sub <= 6'd29; end
                        6'd29: begin
                            ce_n         <= 1'b1;
                            sio_oe       <= 4'd0;
                            qe_init_done <= 1'b1;
                            state        <= S_WRITE;
                        end
                        default: init_sub <= init_sub + 6'd1;
                    endcase
                end

                // ------------------------------------------------------------
                // S_WRITE — always-writing circular buffer.
                // Per iq_valid: QPI write 8 bytes at wr_ptr, advance wr_ptr.
                // sc_lock rising edge: snapshot buf_base.
                // W_commit: transition to S_REPLAY.
                // packet_end: clear buf_base_valid.
                // ------------------------------------------------------------
                S_WRITE: begin
                    // sc_lock rising edge → compute buf_base
                    if (sc_lock && !sc_lock_prev && psram_en) begin : blk_bufbase_w
                        reg [22:0] back_bytes;
                        back_bytes = (iq_sample_cnt - timing_ref) << 3;
                        buf_base       <= (wr_ptr - back_bytes) & AMASK;
                        buf_base_valid <= 1'b1;
                        buf_active     <= 1'b1;
                    end

                    if (W_commit && buf_base_valid && psram_en) begin
                        rd_ptr        <= buf_base;
                        replay_active <= 1'b1;
                        state         <= S_REPLAY;
                    end

                    if (packet_end) begin
                        if (buf_base_valid) replay_missed <= 1'b1;
                        buf_base_valid <= 1'b0;
                        buf_active     <= 1'b0;
                    end

                    // QPI write sub-FSM
                    if (!qpi_busy) begin
                        ce_n   <= 1'b1;
                        sio_oe <= 4'd0;
                        if (iq_valid && psram_en && qe_init_done) begin
                            wr_data  <= {iq_i0, iq_q0, iq_i1, iq_q1,
                                         iq_i2, iq_q2, iq_i3, iq_q3};
                            qpi_busy <= 1'b1;
                            sub      <= 6'd0;
                        end
                    end else
                        psram_do_write_sub(0); // write-only in S_WRITE
                end

                // ------------------------------------------------------------
                // S_REPLAY — interleaved write (live) + read (from buf_base).
                // Per iq_valid: write sub 0..24, then read sub 25..55.
                // Latch replay IQ at sub 55 → rpl_*, assert rpl_valid.
                // packet_end → back to S_WRITE.
                // ------------------------------------------------------------
                S_REPLAY: begin
                    if (packet_end) begin
                        buf_base_valid <= 1'b0;
                        buf_active     <= 1'b0;
                        replay_active  <= 1'b0;
                        qpi_busy       <= 1'b0;
                        sub            <= 6'd0;
                        ce_n           <= 1'b1;
                        sio_oe         <= 4'd0;
                        state          <= S_WRITE;
                    end else if (!qpi_busy) begin
                        ce_n   <= 1'b1;
                        sio_oe <= 4'd0;
                        if (iq_valid && psram_en) begin
                            wr_data  <= {iq_i0, iq_q0, iq_i1, iq_q1,
                                         iq_i2, iq_q2, iq_i3, iq_q3};
                            qpi_busy <= 1'b1;
                            sub      <= 6'd0;
                        end
                    end else
                        psram_do_write_sub(1); // write then read in S_REPLAY
                end

                default: state <= S_UNINIT;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Shared QPI write+read sub-FSM (task)
    // do_read=0: write only (sub 0..24, then done)
    // do_read=1: write (sub 0..24) then read (sub 25..55)
    // -----------------------------------------------------------------------
    task psram_do_write_sub;
        input do_read;
        begin
            case (sub)
                // ---- QPI WRITE: CMD 0x02 (2 nibbles) ----
                6'd0:  begin ce_n<=1'b0; sio_oe<=4'hF; sio_out<=4'h0; sub<=6'd1;  end
                6'd1:  begin              sio_out<=4'h2; sub<=6'd2;  end
                // ---- WRITE ADDR (6 nibbles) ----
                6'd2:  begin sio_out<=cur_wr[22:20]; sub<=6'd3;  end
                6'd3:  begin sio_out<=cur_wr[19:16]; sub<=6'd4;  end
                6'd4:  begin sio_out<=cur_wr[15:12]; sub<=6'd5;  end
                6'd5:  begin sio_out<=cur_wr[11:8];  sub<=6'd6;  end
                6'd6:  begin sio_out<=cur_wr[7:4];   sub<=6'd7;  end
                6'd7:  begin sio_out<=cur_wr[3:0];   sub<=6'd8;  end
                // ---- WRITE DATA (8 bytes = 16 nibbles, sub 8..23) ----
                6'd8:  begin sio_out<=wr_data[63:60]; sub<=6'd9;  end
                6'd9:  begin sio_out<=wr_data[59:56]; sub<=6'd10; end
                6'd10: begin sio_out<=wr_data[55:52]; sub<=6'd11; end
                6'd11: begin sio_out<=wr_data[51:48]; sub<=6'd12; end
                6'd12: begin sio_out<=wr_data[47:44]; sub<=6'd13; end
                6'd13: begin sio_out<=wr_data[43:40]; sub<=6'd14; end
                6'd14: begin sio_out<=wr_data[39:36]; sub<=6'd15; end
                6'd15: begin sio_out<=wr_data[35:32]; sub<=6'd16; end
                6'd16: begin sio_out<=wr_data[31:28]; sub<=6'd17; end
                6'd17: begin sio_out<=wr_data[27:24]; sub<=6'd18; end
                6'd18: begin sio_out<=wr_data[23:20]; sub<=6'd19; end
                6'd19: begin sio_out<=wr_data[19:16]; sub<=6'd20; end
                6'd20: begin sio_out<=wr_data[15:12]; sub<=6'd21; end
                6'd21: begin sio_out<=wr_data[11:8];  sub<=6'd22; end
                6'd22: begin sio_out<=wr_data[7:4];   sub<=6'd23; end
                6'd23: begin sio_out<=wr_data[3:0];   sub<=6'd24; end
                // ---- WRITE DONE: CE# high, advance wr_ptr ----
                6'd24: begin
                    ce_n     <= 1'b1;
                    sio_oe   <= 4'd0;
                    wr_ptr   <= (wr_ptr + {{(ABITS-4){1'b0}}, 4'd8}) & AMASK;
                    if (do_read) sub <= 6'd25;
                    else begin qpi_busy <= 1'b0; sub <= 6'd0; end
                end

                // ---- QPI READ: CMD 0xEB (2 nibbles) ----
                6'd25: begin ce_n<=1'b0; sio_oe<=4'hF; sio_out<=4'hE; sub<=6'd26; end
                6'd26: begin              sio_out<=4'hB; sub<=6'd27; end
                // ---- READ ADDR (6 nibbles) ----
                6'd27: begin sio_out<=cur_rd[22:20]; sub<=6'd28; end
                6'd28: begin sio_out<=cur_rd[19:16]; sub<=6'd29; end
                6'd29: begin sio_out<=cur_rd[15:12]; sub<=6'd30; end
                6'd30: begin sio_out<=cur_rd[11:8];  sub<=6'd31; end
                6'd31: begin sio_out<=cur_rd[7:4];   sub<=6'd32; end
                6'd32: begin sio_out<=cur_rd[3:0];   sub<=6'd33; end
                // ---- 6 DUMMY CLOCKS (tristate SIO) ----
                6'd33: begin sio_oe<=4'd0; sub<=6'd34; end
                6'd34: sub<=6'd35;
                6'd35: sub<=6'd36;
                6'd36: sub<=6'd37;
                6'd37: sub<=6'd38;
                6'd38: sub<=6'd39;
                // ---- READ DATA: 8 bytes = 16 nibbles, shift into rd_data ----
                6'd39: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd40; end
                6'd40: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd41; end
                6'd41: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd42; end
                6'd42: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd43; end
                6'd43: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd44; end
                6'd44: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd45; end
                6'd45: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd46; end
                6'd46: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd47; end
                6'd47: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd48; end
                6'd48: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd49; end
                6'd49: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd50; end
                6'd50: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd51; end
                6'd51: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd52; end
                6'd52: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd53; end
                6'd53: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd54; end
                6'd54: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd55; end
                // ---- READ DONE: CE# high, advance rd_ptr, latch replay IQ ----
                6'd55: begin
                    ce_n      <= 1'b1;
                    sio_oe    <= 4'd0;
                    rd_ptr    <= (rd_ptr + {{(ABITS-4){1'b0}}, 4'd8}) & AMASK;
                    // rd_data[63:56]=i0, [55:48]=q0, ..., [7:0]=q3
                    rpl_i0    <= $signed(rd_data[63:56]);
                    rpl_q0    <= $signed(rd_data[55:48]);
                    rpl_i1    <= $signed(rd_data[47:40]);
                    rpl_q1    <= $signed(rd_data[39:32]);
                    rpl_i2    <= $signed(rd_data[31:24]);
                    rpl_q2    <= $signed(rd_data[23:16]);
                    rpl_i3    <= $signed(rd_data[15:8]);
                    rpl_q3    <= $signed(rd_data[7:0]);
                    rpl_valid <= 1'b1;
                    qpi_busy  <= 1'b0;
                    sub       <= 6'd0;
                    if (rd_ptr == wr_ptr) overflow <= 1'b1;
                end
                default: sub <= 6'd0;
            endcase
        end
    endtask

endmodule
