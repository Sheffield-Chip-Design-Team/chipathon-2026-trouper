// sd_fir_mac.v
// Shared FIR MAC engine for the TDM decimator refactor.
// Time-multiplexes one 13×16 multiplier across 4 channels in round-robin.
//
// Per-channel state (small):
//   fir_acc_i/q_[0:3]   — 32-bit accumulators (cleared at start of each ch)
//   out_i/q_[0:3]       — 8-bit output registers
//
// Shared pipeline (verbatim depth from sd_decimator_combchain):
//   Stage 1: register tap_pair + coeff  → fir_pair_*_r, fir_coeff_r
//   Stage 2: combinational multiply, register product → fir_mul_*_r
//   Stage 3: accumulate fir_mul_*_r into acc[ch_sel]
//
// Scheduling:
//   All 4 channels strobe simultaneously (same decim_ratio, synchronous CIC).
//   Pending requests are latched in ch_pending.
//   Round-robin: lowest pending channel processed first.
//   7 clk_16m cycles per channel × 4 channels = 28 cycles < 128-cycle budget.
//
// load_strobe[k]: combinational, asserted for 1 clk_16m cycle when channel k
//   begins processing.  Drives sd_fir_state[k].load_strobe.
//
// Timing w.r.t. sd_fir_state:
//   load_strobe fires in cycle N → sd_fir_state shifts dl at clock edge of N
//   → cycle N+1: tap_pair for tap_sel=0 reads from NEW delay line ✓
//   (Same as original fir_strobe_ext && !fir_busy in sd_decimator_combchain)
//
// GF180MCU 3.3V

`timescale 1ns/100ps

module sd_fir_mac (
    input  wire        clk_16m,
    input  wire        rst_n,

    // Per-channel start-of-computation strobes (from CDC in sd_decimator_top)
    input  wire [3:0]  ch_valid,

    // Per-channel tap pairs from sd_fir_state instances (combinational)
    input  wire signed [12:0] tap_pair_i_0,
    input  wire signed [12:0] tap_pair_i_1,
    input  wire signed [12:0] tap_pair_i_2,
    input  wire signed [12:0] tap_pair_i_3,
    input  wire signed [12:0] tap_pair_q_0,
    input  wire signed [12:0] tap_pair_q_1,
    input  wire signed [12:0] tap_pair_q_2,
    input  wire signed [12:0] tap_pair_q_3,

    // To all sd_fir_state instances (common tap index, all see the same sel)
    output reg  [2:0]  tap_sel,
    // Which channel is being processed (routes load_strobe and tap_pair mux)
    output reg  [1:0]  ch_sel,

    // Per-channel load strobes to sd_fir_state (1-cycle, combinational)
    output wire [3:0]  load_strobe,

    // Per-channel 8-bit I/Q outputs
    output reg  signed [7:0] out_i_0, out_i_1, out_i_2, out_i_3,
    output reg  signed [7:0] out_q_0, out_q_1, out_q_2, out_q_3,
    output reg  [3:0]  out_valid          // one-hot, 1-cycle pulse per channel
);

    // -----------------------------------------------------------------------
    // Pending channel tracker
    // -----------------------------------------------------------------------
    reg [3:0] ch_pending;

    // Priority encoder: lowest pending channel
    wire [1:0] next_ch =
        ch_pending[0] ? 2'd0 :
        ch_pending[1] ? 2'd1 :
        ch_pending[2] ? 2'd2 : 2'd3;
    wire any_pending = |ch_pending;

    // -----------------------------------------------------------------------
    // FSM / pipeline state (shared)
    // -----------------------------------------------------------------------
    reg        mac_busy;
    reg [2:0]  tap_idx;        // 0..6; tap_idx=6 is the output cycle

    reg        fir_pair_valid_r, fir_mul_valid_r;
    reg signed [12:0] fir_pair_i_r, fir_pair_q_r;
    reg signed [15:0] fir_coeff_r;
    reg signed [28:0] fir_mul_i_r, fir_mul_q_r;

    // Per-channel accumulators (32-bit, reset at start of each channel run)
    reg signed [31:0] fir_acc_i_0, fir_acc_i_1, fir_acc_i_2, fir_acc_i_3;
    reg signed [31:0] fir_acc_q_0, fir_acc_q_1, fir_acc_q_2, fir_acc_q_3;

    // -----------------------------------------------------------------------
    // Combinational mux: select active channel's tap pair
    // -----------------------------------------------------------------------
    wire signed [12:0] tap_pair_i_mux =
        (ch_sel == 2'd0) ? tap_pair_i_0 :
        (ch_sel == 2'd1) ? tap_pair_i_1 :
        (ch_sel == 2'd2) ? tap_pair_i_2 : tap_pair_i_3;
    wire signed [12:0] tap_pair_q_mux =
        (ch_sel == 2'd0) ? tap_pair_q_0 :
        (ch_sel == 2'd1) ? tap_pair_q_1 :
        (ch_sel == 2'd2) ? tap_pair_q_2 : tap_pair_q_3;

    // -----------------------------------------------------------------------
    // Coefficient ROM
    // -----------------------------------------------------------------------
    reg signed [15:0] fir_coeff_sel;
    always @(*) begin
        case (tap_sel)
            3'd0: fir_coeff_sel = 16'sd470;
            3'd1: fir_coeff_sel = -16'sd1111;
            3'd2: fir_coeff_sel = 16'sd2623;
            3'd3: fir_coeff_sel = -16'sd7089;
            3'd4: fir_coeff_sel = 16'sd26862;
            default: fir_coeff_sel = 16'sd0;
        endcase
    end

    // -----------------------------------------------------------------------
    // Multiply (combinational, from stage-1 registers)
    // -----------------------------------------------------------------------
    wire signed [28:0] fir_mul_i = fir_pair_i_r * fir_coeff_r;
    wire signed [28:0] fir_mul_q = fir_pair_q_r * fir_coeff_r;

    // -----------------------------------------------------------------------
    // Accumulator (reads current channel's acc)
    // -----------------------------------------------------------------------
    wire signed [31:0] fir_acc_i_cur =
        (ch_sel == 2'd0) ? fir_acc_i_0 :
        (ch_sel == 2'd1) ? fir_acc_i_1 :
        (ch_sel == 2'd2) ? fir_acc_i_2 : fir_acc_i_3;
    wire signed [31:0] fir_acc_q_cur =
        (ch_sel == 2'd0) ? fir_acc_q_0 :
        (ch_sel == 2'd1) ? fir_acc_q_1 :
        (ch_sel == 2'd2) ? fir_acc_q_2 : fir_acc_q_3;

    wire signed [31:0] fir_acc_i_next = fir_acc_i_cur + {{3{fir_mul_i_r[28]}}, fir_mul_i_r};
    wire signed [31:0] fir_acc_q_next = fir_acc_q_cur + {{3{fir_mul_q_r[28]}}, fir_mul_q_r};

    // Round-to-nearest (Q1.14 → 8-bit) and saturation
    wire signed [31:0] round_i = fir_acc_i_next + 32'sd8192;
    wire signed [31:0] round_q = fir_acc_q_next + 32'sd8192;
    wire signed [17:0] scaled_i = round_i[31:14];
    wire signed [17:0] scaled_q = round_q[31:14];

    wire fir_output_now = mac_busy && (tap_idx == 3'd6) && fir_mul_valid_r;

    // -----------------------------------------------------------------------
    // load_strobe: fired when a channel is about to start (combinational)
    // Scenario A: !mac_busy && any_pending → start next_ch
    // Scenario B: fir_output_now && any_pending_after → start next channel
    // In both cases, the delay line in sd_fir_state shifts at the clock edge,
    // ready for tap_sel=0 on the following cycle (same as original design).
    // -----------------------------------------------------------------------
    wire pending_after = |(ch_pending & ~(4'd1 << ch_sel));  // pending excl. current
    wire [1:0] next_ch_after =
        (ch_pending[0] && ch_sel != 2'd0) ? 2'd0 :
        (ch_pending[1] && ch_sel != 2'd1) ? 2'd1 :
        (ch_pending[2] && ch_sel != 2'd2) ? 2'd2 : 2'd3;

    wire start_new = (!mac_busy && any_pending) ||
                     (fir_output_now && pending_after);
    wire [1:0] start_ch = (!mac_busy) ? next_ch : next_ch_after;

    assign load_strobe[0] = start_new && (start_ch == 2'd0);
    assign load_strobe[1] = start_new && (start_ch == 2'd1);
    assign load_strobe[2] = start_new && (start_ch == 2'd2);
    assign load_strobe[3] = start_new && (start_ch == 2'd3);

    // -----------------------------------------------------------------------
    // Sequential logic
    // -----------------------------------------------------------------------
    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n) begin
            ch_pending       <= 4'd0;
            mac_busy         <= 1'b0;
            tap_idx          <= 3'd0;
            tap_sel          <= 3'd0;
            ch_sel           <= 2'd0;
            fir_pair_valid_r <= 1'b0;
            fir_mul_valid_r  <= 1'b0;
            fir_pair_i_r     <= 13'sd0;
            fir_pair_q_r     <= 13'sd0;
            fir_coeff_r      <= 16'sd0;
            fir_mul_i_r      <= 29'sd0;
            fir_mul_q_r      <= 29'sd0;
            fir_acc_i_0 <= 32'sd0; fir_acc_i_1 <= 32'sd0;
            fir_acc_i_2 <= 32'sd0; fir_acc_i_3 <= 32'sd0;
            fir_acc_q_0 <= 32'sd0; fir_acc_q_1 <= 32'sd0;
            fir_acc_q_2 <= 32'sd0; fir_acc_q_3 <= 32'sd0;
            out_i_0 <= 8'sd0; out_i_1 <= 8'sd0;
            out_i_2 <= 8'sd0; out_i_3 <= 8'sd0;
            out_q_0 <= 8'sd0; out_q_1 <= 8'sd0;
            out_q_2 <= 8'sd0; out_q_3 <= 8'sd0;
            out_valid <= 4'd0;
        end else begin
            // --- Latch incoming channel requests ---
            // (OR in new ch_valid; clear bit when we start processing that ch)
            ch_pending <= (ch_pending | ch_valid) &
                          ~(start_new ? (4'd1 << start_ch) : 4'd0);

            out_valid <= 4'd0;  // default: no output this cycle

            if (!mac_busy) begin
                // --- Idle: start next pending channel ---
                if (any_pending) begin
                    mac_busy         <= 1'b1;
                    tap_idx          <= 3'd0;
                    tap_sel          <= 3'd0;
                    ch_sel           <= next_ch;
                    fir_pair_valid_r <= 1'b0;
                    fir_mul_valid_r  <= 1'b0;
                    // acc cleared here (will be re-cleared on first tap cycle too)
                    case (next_ch)
                        2'd0: begin fir_acc_i_0 <= 32'sd0; fir_acc_q_0 <= 32'sd0; end
                        2'd1: begin fir_acc_i_1 <= 32'sd0; fir_acc_q_1 <= 32'sd0; end
                        2'd2: begin fir_acc_i_2 <= 32'sd0; fir_acc_q_2 <= 32'sd0; end
                        2'd3: begin fir_acc_i_3 <= 32'sd0; fir_acc_q_3 <= 32'sd0; end
                    endcase
                end
            end else begin
                // --- Busy: run multiply-accumulate pipeline ---
                if (tap_idx <= 3'd4) begin
                    // Stage 1: latch tap pair + coefficient
                    fir_pair_i_r     <= tap_pair_i_mux;
                    fir_pair_q_r     <= tap_pair_q_mux;
                    fir_coeff_r      <= fir_coeff_sel;
                    fir_pair_valid_r <= 1'b1;
                    tap_idx          <= tap_idx + 3'd1;
                    tap_sel          <= tap_idx + 3'd1;  // pre-fetch next tap
                end else begin
                    fir_pair_valid_r <= 1'b0;
                    if (fir_output_now) begin
                        // --- Output current channel ---
                        case (ch_sel)
                            2'd0: begin
                                out_i_0 <= (scaled_i > 18'sd127)  ?  8'sd127 :
                                           (scaled_i < -18'sd128) ? -8'sd128 : scaled_i[7:0];
                                out_q_0 <= (scaled_q > 18'sd127)  ?  8'sd127 :
                                           (scaled_q < -18'sd128) ? -8'sd128 : scaled_q[7:0];
                                out_valid[0] <= 1'b1;
                            end
                            2'd1: begin
                                out_i_1 <= (scaled_i > 18'sd127)  ?  8'sd127 :
                                           (scaled_i < -18'sd128) ? -8'sd128 : scaled_i[7:0];
                                out_q_1 <= (scaled_q > 18'sd127)  ?  8'sd127 :
                                           (scaled_q < -18'sd128) ? -8'sd128 : scaled_q[7:0];
                                out_valid[1] <= 1'b1;
                            end
                            2'd2: begin
                                out_i_2 <= (scaled_i > 18'sd127)  ?  8'sd127 :
                                           (scaled_i < -18'sd128) ? -8'sd128 : scaled_i[7:0];
                                out_q_2 <= (scaled_q > 18'sd127)  ?  8'sd127 :
                                           (scaled_q < -18'sd128) ? -8'sd128 : scaled_q[7:0];
                                out_valid[2] <= 1'b1;
                            end
                            2'd3: begin
                                out_i_3 <= (scaled_i > 18'sd127)  ?  8'sd127 :
                                           (scaled_i < -18'sd128) ? -8'sd128 : scaled_i[7:0];
                                out_q_3 <= (scaled_q > 18'sd127)  ?  8'sd127 :
                                           (scaled_q < -18'sd128) ? -8'sd128 : scaled_q[7:0];
                                out_valid[3] <= 1'b1;
                            end
                        endcase
                        // --- Transition to next channel or go idle ---
                        if (pending_after) begin
                            ch_sel  <= next_ch_after;
                            tap_idx <= 3'd0;
                            tap_sel <= 3'd0;
                            fir_pair_valid_r <= 1'b0;
                            fir_mul_valid_r  <= 1'b0;
                            case (next_ch_after)
                                2'd0: begin fir_acc_i_0 <= 32'sd0; fir_acc_q_0 <= 32'sd0; end
                                2'd1: begin fir_acc_i_1 <= 32'sd0; fir_acc_q_1 <= 32'sd0; end
                                2'd2: begin fir_acc_i_2 <= 32'sd0; fir_acc_q_2 <= 32'sd0; end
                                2'd3: begin fir_acc_i_3 <= 32'sd0; fir_acc_q_3 <= 32'sd0; end
                            endcase
                            // mac_busy stays 1
                        end else begin
                            mac_busy <= 1'b0;
                            tap_idx  <= 3'd0;
                            tap_sel  <= 3'd0;
                        end
                    end else begin
                        tap_idx <= tap_idx + 3'd1;
                    end
                end

                // --- Pipeline stage 2: register multiply result ---
                fir_mul_i_r     <= fir_mul_i;
                fir_mul_q_r     <= fir_mul_q;
                fir_mul_valid_r <= fir_pair_valid_r;

                // --- Pipeline stage 3: accumulate ---
                if (fir_mul_valid_r) begin
                    case (ch_sel)
                        2'd0: begin fir_acc_i_0 <= fir_acc_i_next; fir_acc_q_0 <= fir_acc_q_next; end
                        2'd1: begin fir_acc_i_1 <= fir_acc_i_next; fir_acc_q_1 <= fir_acc_q_next; end
                        2'd2: begin fir_acc_i_2 <= fir_acc_i_next; fir_acc_q_2 <= fir_acc_q_next; end
                        2'd3: begin fir_acc_i_3 <= fir_acc_i_next; fir_acc_q_3 <= fir_acc_q_next; end
                    endcase
                end
            end
        end
    end

endmodule
