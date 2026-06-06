// sc_detector.v
// Schmidl-Cox preamble detector — NR=1 (antenna 0 only)
// Post-lock combining uses all 4 antennas via training_acc independently.
// GF180MCU, 3.3V, 32 MHz single clock domain
//
// Area-reduction changes vs original:
//   Single-channel (NR=1): ch1 inputs/accumulators/eval steps removed.
//     TDM steps: 16 → 8 (ch0 correlation + ch0 energy only).
//     Eval steps: 7 → 4 (ci0², cq0², E0cur×E0del, threshold).
//     training_acc does its own independent 4-channel preamble accumulation,
//     so sc_detector ch1 outputs were not load-bearing for MIMO combining.
//   Accumulator width: 32 → 24 bit.  Max value = 128 × 255² ≈ 8.3 M = 23 bits;
//     32-bit was 8 bits of wasted headroom.
//   Eval multiplier: 17 → 13 bit (shift snapshot from [22:6] to [22:10]).
//     13-bit gives ~78 dB SNR on the metric; channel noise dominates well before
//     that.  signed_mul24_pipe output narrowed from 34 to 26 bits accordingly.
//   sc_thr firmware value must be divided by 64 vs the original to preserve
//     the same detection threshold (both LHS and RHS of the comparison scale
//     as k² with k = 1/64, so the ratio is invariant).
//   Per-sample multipliers: 16 simultaneous combinational 8×8 wires → 1 shared
//     8×8 multiplier, 8-step TDM FSM.
//   eval_mag_acc/eval_e_acc: 48 → 28 bit. Max |C|² = 2×4095² < 2^25; 28 bits
//     gives 3 bits headroom. sym_E_ref eliminated (was unused). sc_stat now
//     reads sym_mag_sc[27:12] (same top-16-bits-of-useful-range semantics).
//   timing_ref offset: replaced 32×32 hardware multiply with shift+concat.
//     (sc_hits_req+1)*M_val where M_val ∈ {64,128} — pure wiring, no multiplier.

/* verilator lint_off DECLFILENAME */
module signed_mul24_pipe (
    input  wire               clk,
    input  wire signed [12:0] a,
    input  wire signed [12:0] b,
    output reg  signed [25:0] p
);
    // 2-stage pipeline: stage 1 registers inputs, stage 2 registers product.
    reg signed [12:0] a_q, b_q;

    always @(posedge clk) begin
        a_q <= a;
        b_q <= b;
        p   <= a_q * b_q;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module sc_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] cur_i0,
    input  wire signed [7:0] cur_q0,
    input  wire signed [7:0] del_i0,
    input  wire signed [7:0] del_q0,
    input  wire        delayed_valid,
    input  wire [3:0]  sf,
    input  wire [15:0] sc_thr,
    input  wire [1:0]  sc_hits_req,
    output reg         sc_lock,
    output reg  [31:0] timing_ref,
    output reg  signed [31:0] c_i0, c_q0,
    output reg  [15:0] sc_stat,
    output reg         sc_hit_dbg,
    output reg  [1:0]  sc_hit_count_dbg,
    output reg  [31:0] sc_first_hit_dbg,
    output reg  [31:0] sc_lock_sample_dbg
);

    // =========================================================
    // Input registers
    // =========================================================
    reg signed [7:0] cur_i0_r, cur_q0_r;
    reg signed [7:0] del_i0_r, del_q0_r;
    reg              iq_valid_r, delayed_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_i0_r <= 8'sd0; cur_q0_r <= 8'sd0;
            del_i0_r <= 8'sd0; del_q0_r <= 8'sd0;
            iq_valid_r <= 1'b0; delayed_valid_r <= 1'b0;
        end else begin
            cur_i0_r <= cur_i0; cur_q0_r <= cur_q0;
            del_i0_r <= del_i0; del_q0_r <= del_q0;
            iq_valid_r      <= iq_valid;
            delayed_valid_r <= delayed_valid;
        end
    end

    reg [31:0] sample_count;
    reg [8:0]  sym_cnt;  // 9-bit to count up to 255 (SF8-SF12 L=256)
    reg [8:0]  M_val;  // 9-bit: SF8 needs 256
    always @(*) begin
        case (sf)
            4'd6:    M_val = 9'd64;
            4'd7:    M_val = 9'd128;
            default: M_val = 9'd256;  // SF8-SF12: accumulate L=256 samples per block
        endcase
    end

    // =========================================================
    // Per-symbol accumulators (NR=1, 24-bit)
    // =========================================================
    reg signed [23:0] acc_ci0, acc_cq0;
    reg signed [23:0] acc_E0cur, acc_E0del;

    // =========================================================
    // TDM per-sample 8×8 multiplier
    //
    // 8 steps per sample (down from 16 — ch1 removed):
    //
    //   Step  Inputs A×B              Accumulate at odd step
    //   ----  ----------------------  ------------------------------------------
    //   0,1   cur_i0×del_i0, cq0×dq0  acc_ci0 += P0 + P1  (re corr ch0)
    //   2,3   cur_q0×del_i0, ci0×dq0  acc_cq0 += P2 - P3  (im corr ch0)
    //   4,5   cur_i0², cur_q0²         acc_E0cur += P4 + P5
    //   6,7   del_i0², del_q0²         acc_E0del += P6 + P7; end TDM
    //
    // Pipeline: tdm_a_r/tdm_b_r registered → tdm_mul (comb) → tdm_mul_r (registered).
    // At odd step N: tdm_mul_r = P_{N-1}, tdm_mul = P_N (comb).
    // =========================================================
    reg signed [7:0] tlat_ci0, tlat_qi0, tlat_di0, tlat_dq0;

    reg        tdm_busy;
    reg [3:0]  tdm_step;
    reg signed [7:0]  tdm_a_r, tdm_b_r;
    wire signed [15:0] tdm_mul = tdm_a_r * tdm_b_r;
    reg  signed [15:0] tdm_mul_r;

    reg signed [23:0] sym_ci0, sym_cq0;
    reg signed [27:0] sym_mag_sc;   // max |C|² = 2×4095² < 2^25; 28-bit sufficient

    reg [1:0]  hit_count;
    reg [31:0] first_hit_sample, eval_sample_mark;
    reg        metric_valid_pulse;

    // =========================================================
    // Serialised metric engine — 4 multiplications (steps 0..3),
    // single shared signed_mul24_pipe (13-bit, 2-stage, 3-cycle latency).
    // =========================================================
    reg        eval_busy, eval_issue_done;
    reg [3:0]  eval_step;
    reg signed [27:0] eval_mag_acc, eval_e_acc;  // 28-bit: 3-bit headroom over max 2^25

    reg signed [12:0] eval_ci0, eval_cq0;
    reg signed [12:0] eval_E0cur, eval_E0del;

    reg signed [12:0] eval_mul_a_sel, eval_mul_b_sel;
    wire signed [25:0] eval_prod;
    signed_mul24_pipe u_eval_mul (
        .clk(clk), .a(eval_mul_a_sel), .b(eval_mul_b_sel), .p(eval_prod));

    reg [2:0]  eval_valid_pipe;
    reg [3:0]  eval_step_0, eval_step_1, eval_step_2;
    reg        eval_hit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eval_mul_a_sel <= 13'sd0;
            eval_mul_b_sel <= 13'sd0;
        end else begin
            case (eval_step)
                4'd0: begin eval_mul_a_sel <= eval_ci0;   eval_mul_b_sel <= eval_ci0;   end
                4'd1: begin eval_mul_a_sel <= eval_cq0;   eval_mul_b_sel <= eval_cq0;   end
                4'd2: begin eval_mul_a_sel <= eval_E0cur; eval_mul_b_sel <= eval_E0del;  end
                default: begin
                    eval_mul_a_sel <= $signed({1'b0, sc_thr[12:0]});
                    eval_mul_b_sel <= $signed(eval_e_acc[25:13]);
                end
            endcase
        end
    end

    // =========================================================
    // Main sequential block
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count    <= 32'd0;
            sym_cnt         <= 8'd0;
            acc_ci0  <= 24'sd0; acc_cq0  <= 24'sd0;
            acc_E0cur<= 24'sd0; acc_E0del<= 24'sd0;
            tlat_ci0 <= 8'sd0; tlat_qi0 <= 8'sd0;
            tlat_di0 <= 8'sd0; tlat_dq0 <= 8'sd0;
            tdm_busy    <= 1'b0;
            tdm_step    <= 4'd0;
            tdm_a_r     <= 8'sd0; tdm_b_r <= 8'sd0;
            tdm_mul_r   <= 16'sd0;
            sym_ci0  <= 24'sd0; sym_cq0  <= 24'sd0;
            sym_mag_sc <= 28'sd0;
            hit_count        <= 2'd0;
            first_hit_sample <= 32'd0;
            eval_sample_mark <= 32'd0;
            metric_valid_pulse <= 1'b0;
            eval_busy       <= 1'b0;
            eval_step       <= 4'd0;
            eval_issue_done <= 1'b0;
            eval_valid_pipe <= 3'd0;
            eval_step_0 <= 4'd0; eval_step_1 <= 4'd0; eval_step_2 <= 4'd0;
            eval_mag_acc <= 28'sd0; eval_e_acc <= 28'sd0;
            eval_hit     <= 1'b0;
            eval_ci0  <= 13'sd0; eval_cq0  <= 13'sd0;
            eval_E0cur<= 13'sd0; eval_E0del<= 13'sd0;
            sc_lock            <= 1'b0;
            timing_ref         <= 32'd0;
            c_i0 <= 32'sd0; c_q0 <= 32'sd0;
            sc_stat            <= 16'd0;
            sc_hit_dbg         <= 1'b0;
            sc_hit_count_dbg   <= 2'd0;
            sc_first_hit_dbg   <= 32'd0;
            sc_lock_sample_dbg <= 32'd0;
        end else begin
            metric_valid_pulse <= 1'b0;
            sc_hit_dbg         <= 1'b0;

            // -----------------------------------------------------------------
            // Sample arrives: latch inputs, start TDM
            // -----------------------------------------------------------------
            if (delayed_valid_r && !tdm_busy) begin
                tlat_ci0 <= cur_i0_r; tlat_qi0 <= cur_q0_r;
                tlat_di0 <= del_i0_r; tlat_dq0 <= del_q0_r;
                tdm_a_r  <= cur_i0_r;
                tdm_b_r  <= del_i0_r;
                tdm_step <= 4'd0;
                tdm_busy <= 1'b1;
            end else if (iq_valid_r && !delayed_valid_r && !tdm_busy) begin
                sample_count <= sample_count + 32'd1;
            end

            // -----------------------------------------------------------------
            // TDM engine: one 8×8 multiply per cycle, 8 cycles per sample
            // -----------------------------------------------------------------
            if (tdm_busy) begin
                tdm_mul_r <= tdm_mul;
                tdm_step  <= tdm_step + 4'd1;

                // Pre-select inputs for next step
                case (tdm_step)
                    4'd0:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_dq0; end
                    4'd1:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_di0; end
                    4'd2:  begin tdm_a_r <= tlat_ci0; tdm_b_r <= tlat_dq0; end
                    4'd3:  begin tdm_a_r <= tlat_ci0; tdm_b_r <= tlat_ci0; end
                    4'd4:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_qi0; end
                    4'd5:  begin tdm_a_r <= tlat_di0; tdm_b_r <= tlat_di0; end
                    4'd6:  begin tdm_a_r <= tlat_dq0; tdm_b_r <= tlat_dq0; end
                    default: begin end  // step 7: last step
                endcase

                // Accumulate at odd steps (24-bit accumulators)
                case (tdm_step)
                    4'd1:  acc_ci0   <= acc_ci0
                                + {{8{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{8{tdm_mul[15]}},   tdm_mul};
                    4'd3:  acc_cq0   <= acc_cq0
                                + {{8{tdm_mul_r[15]}}, tdm_mul_r}
                                - {{8{tdm_mul[15]}},   tdm_mul};
                    4'd5:  acc_E0cur <= acc_E0cur
                                + {{8{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{8{tdm_mul[15]}},   tdm_mul};
                    4'd7: begin
                        acc_E0del <= acc_E0del
                                + {{8{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{8{tdm_mul[15]}},   tdm_mul};
                        // ----- End of TDM for this sample -----
                        tdm_busy     <= 1'b0;
                        sample_count <= sample_count + 32'd1;

                        if (sym_cnt == M_val - 8'd1) begin
                            sym_cnt <= 8'd0;
                            sym_ci0 <= acc_ci0; sym_cq0 <= acc_cq0;

                            // Snapshot for eval: shift right by 10 → 13-bit signed
                            eval_ci0   <= acc_ci0[22:10];   eval_cq0   <= acc_cq0[22:10];
                            eval_E0cur <= acc_E0cur[22:10]; eval_E0del <= acc_E0del[22:10];

                            eval_mag_acc    <= 28'sd0;
                            eval_e_acc      <= 28'sd0;
                            eval_step       <= 4'd0;
                            eval_issue_done <= 1'b0;
                            eval_valid_pipe <= 3'd0;
                            eval_busy       <= 1'b1;
                            eval_sample_mark <= sample_count + 32'd1;

                            acc_ci0   <= 24'sd0; acc_cq0   <= 24'sd0;
                            acc_E0cur <= 24'sd0; acc_E0del <= 24'sd0;
                        end else begin
                            sym_cnt <= sym_cnt + 8'd1;
                        end
                    end
                    default: begin end
                endcase
            end

            // -----------------------------------------------------------------
            // Metric evaluation engine (4 steps: ci0², cq0², E0cur×E0del, thr)
            // -----------------------------------------------------------------
            if (eval_busy) begin
                eval_valid_pipe <= {eval_valid_pipe[1:0], !eval_issue_done};

                eval_step_0 <= eval_step;
                eval_step_1 <= eval_step_0;
                eval_step_2 <= eval_step_1;

                if (!eval_issue_done) begin
                    if (eval_step == 4'd3)
                        eval_issue_done <= 1'b1;
                    else
                        eval_step <= eval_step + 4'd1;
                end

                if (eval_valid_pipe[2]) begin
                    case (eval_step_2)
                        4'd0: eval_mag_acc <= eval_mag_acc + {{2{eval_prod[25]}}, eval_prod};
                        4'd1: eval_mag_acc <= eval_mag_acc + {{2{eval_prod[25]}}, eval_prod};
                        4'd2: begin
                            eval_e_acc <= eval_e_acc + {{2{eval_prod[25]}}, eval_prod};
                            sym_mag_sc <= eval_mag_acc;
                        end
                        default: begin
                            eval_hit           <= (eval_e_acc > 28'sd0) &&
                                                  ({1'b0, eval_mag_acc[27:1]} >=
                                                   {{2{eval_prod[25]}}, eval_prod});
                            eval_busy          <= 1'b0;
                            metric_valid_pulse <= 1'b1;
                        end
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // Lock detection
            // -----------------------------------------------------------------
            if (metric_valid_pulse && !sc_lock) begin
                sc_hit_dbg <= eval_hit;
                if (eval_hit) begin
                    if (hit_count == 2'd0)
                        first_hit_sample <= eval_sample_mark;
                    if (hit_count == sc_hits_req) begin
                        sc_lock            <= 1'b1;
                        sc_lock_sample_dbg <= eval_sample_mark;
                        // (sc_hits_req+1)*M: M=2^sf, shift by sf — no multiplier.
                        // n_hits_p1 ∈ 1..4 (3 bits); offset ≤ 4×4096=16384 (14 bits).
                        begin : blk_timing
                            reg [2:0]  n_hits_p1;
                            reg [13:0] sc_off;
                            n_hits_p1 = {1'b0, sc_hits_req} + 2'd1;
                            sc_off = {11'd0, n_hits_p1} << sf;
                            timing_ref <= eval_sample_mark - {18'd0, sc_off} + 32'd1;
                        end
                        c_i0 <= {{8{sym_ci0[23]}}, sym_ci0};
                        c_q0 <= {{8{sym_cq0[23]}}, sym_cq0};
                        sc_first_hit_dbg <= first_hit_sample;
                        hit_count <= 2'd0;
                    end else begin
                        hit_count <= hit_count + 2'd1;
                    end
                end else begin
                    hit_count <= 2'd0;
                end
                sc_hit_count_dbg <= hit_count;
            end

            sc_stat <= {sym_mag_sc[27:13], 1'b0}; // top 15 useful bits, zero-padded LSB
        end
    end

endmodule
