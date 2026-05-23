// sc_detector.v
// Schmidl-Cox preamble detector — NR=2 acquisition (antennas 0 and 1 only)
// Post-lock combining uses all 4 antennas via training_acc independently.
// GF180MCU, 3.3V, 32 MHz single clock domain

/* verilator lint_off DECLFILENAME */
module signed_mul24_pipe (
    input  wire               clk,
    input  wire signed [23:0] a,
    input  wire signed [23:0] b,
    output reg  signed [47:0] p
);
    wire [23:0] a_abs_w = a[23] ? (~a + 24'd1) : a;
    wire [23:0] b_abs_w = b[23] ? (~b + 24'd1) : b;
    wire        sign_w  = a[23] ^ b[23];

    reg [23:0] a_abs_q, b_abs_q;
    reg        sign_q0, sign_q1, sign_q2, sign_q3;
    reg [15:0] pp00_q, pp01_q, pp02_q;
    reg [15:0] pp10_q, pp11_q, pp12_q;
    reg [15:0] pp20_q, pp21_q, pp22_q;
    reg [47:0] row0_q, row1_q, row2_q;
    reg [47:0] sum01_q, sum2_q;

    always @(posedge clk) begin
        a_abs_q <= a_abs_w;
        b_abs_q <= b_abs_w;
        sign_q0 <= sign_w;

        pp00_q <= a_abs_q[7:0]   * b_abs_q[7:0];
        pp01_q <= a_abs_q[7:0]   * b_abs_q[15:8];
        pp02_q <= a_abs_q[7:0]   * b_abs_q[23:16];
        pp10_q <= a_abs_q[15:8]  * b_abs_q[7:0];
        pp11_q <= a_abs_q[15:8]  * b_abs_q[15:8];
        pp12_q <= a_abs_q[15:8]  * b_abs_q[23:16];
        pp20_q <= a_abs_q[23:16] * b_abs_q[7:0];
        pp21_q <= a_abs_q[23:16] * b_abs_q[15:8];
        pp22_q <= a_abs_q[23:16] * b_abs_q[23:16];
        sign_q1 <= sign_q0;

        row0_q <= {32'd0, pp00_q} + {24'd0, pp01_q, 8'd0} + {16'd0, pp02_q, 16'd0};
        row1_q <= {24'd0, pp10_q, 8'd0} + {16'd0, pp11_q, 16'd0} + {8'd0, pp12_q, 24'd0};
        row2_q <= {16'd0, pp20_q, 16'd0} + {8'd0, pp21_q, 24'd0} + {pp22_q, 32'd0};
        sign_q2 <= sign_q1;

        sum01_q <= row0_q + row1_q;
        sum2_q  <= row2_q;
        sign_q3 <= sign_q2;

        p <= sign_q3 ? -(sum01_q + sum2_q) : (sum01_q + sum2_q);
    end
endmodule
/* verilator lint_on DECLFILENAME */

module sc_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] cur_i0, cur_i1,
    input  wire signed [7:0] cur_q0, cur_q1,
    input  wire signed [7:0] del_i0, del_i1,
    input  wire signed [7:0] del_q0, del_q1,
    input  wire        delayed_valid,
    input  wire [3:0]  sf,
    input  wire [15:0] sc_thr,
    input  wire [1:0]  sc_hits_req,
    output reg         sc_lock,
    output reg  [31:0] timing_ref,
    output reg  signed [31:0] c_i0, c_q0, c_i1, c_q1,
    output reg  [15:0] sc_stat,
    output reg         sc_hit_dbg,
    output reg  [1:0]  sc_hit_count_dbg,
    output reg  [31:0] sc_first_hit_dbg,
    output reg  [31:0] sc_lock_sample_dbg
);

    // Input registers: break port→multiply combinational path to close 32 MHz timing
    reg signed [7:0] cur_i0_r, cur_i1_r, cur_q0_r, cur_q1_r;
    reg signed [7:0] del_i0_r, del_i1_r, del_q0_r, del_q1_r;
    reg              iq_valid_r, delayed_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_i0_r <= 8'sd0; cur_i1_r <= 8'sd0;
            cur_q0_r <= 8'sd0; cur_q1_r <= 8'sd0;
            del_i0_r <= 8'sd0; del_i1_r <= 8'sd0;
            del_q0_r <= 8'sd0; del_q1_r <= 8'sd0;
            iq_valid_r <= 1'b0; delayed_valid_r <= 1'b0;
        end else begin
            cur_i0_r <= cur_i0; cur_i1_r <= cur_i1;
            cur_q0_r <= cur_q0; cur_q1_r <= cur_q1;
            del_i0_r <= del_i0; del_i1_r <= del_i1;
            del_q0_r <= del_q0; del_q1_r <= del_q1;
            iq_valid_r  <= iq_valid;
            delayed_valid_r <= delayed_valid;
        end
    end

    // Free-running sample counter (counts iq_valid pulses)
    reg [31:0] sample_count;

    // Symbol boundary counter (M samples per symbol)
    reg [7:0]  sym_cnt;
    reg [7:0]  M_val;
    always @(*) begin
        case (sf)
            4'd6: M_val = 8'd64;
            4'd7: M_val = 8'd128;
            4'd8: M_val = 8'd128;
            4'd9: M_val = 8'd128;
            4'd10: M_val = 8'd128;
            4'd11: M_val = 8'd128;
            4'd12: M_val = 8'd128;
            default: M_val = 8'd128;
        endcase
    end

    // Per-symbol accumulators — NR=2 (antennas 0 and 1 only)
    reg signed [31:0] acc_ci0, acc_cq0;
    reg signed [31:0] acc_ci1, acc_cq1;
    reg signed [31:0] acc_E0cur, acc_E0del;
    reg signed [31:0] acc_E1cur, acc_E1del;

    // Per-sample product pipeline — NR=2. First stage is raw 8x8 multiplies;
    // second stage forms the signed correlation/energy sums.
    wire signed [15:0] mul_ci0_i = cur_i0_r * del_i0_r;
    wire signed [15:0] mul_ci0_q = cur_q0_r * del_q0_r;
    wire signed [15:0] mul_cq0_qi = cur_q0_r * del_i0_r;
    wire signed [15:0] mul_cq0_iq = cur_i0_r * del_q0_r;
    wire signed [15:0] mul_ci1_i = cur_i1_r * del_i1_r;
    wire signed [15:0] mul_ci1_q = cur_q1_r * del_q1_r;
    wire signed [15:0] mul_cq1_qi = cur_q1_r * del_i1_r;
    wire signed [15:0] mul_cq1_iq = cur_i1_r * del_q1_r;
    wire signed [15:0] mul_e_cur0_i = cur_i0_r * cur_i0_r;
    wire signed [15:0] mul_e_cur0_q = cur_q0_r * cur_q0_r;
    wire signed [15:0] mul_e_del0_i = del_i0_r * del_i0_r;
    wire signed [15:0] mul_e_del0_q = del_q0_r * del_q0_r;
    wire signed [15:0] mul_e_cur1_i = cur_i1_r * cur_i1_r;
    wire signed [15:0] mul_e_cur1_q = cur_q1_r * cur_q1_r;
    wire signed [15:0] mul_e_del1_i = del_i1_r * del_i1_r;
    wire signed [15:0] mul_e_del1_q = del_q1_r * del_q1_r;

    reg        sample_m_valid;
    reg        sample_p_valid;
    reg signed [15:0] mul_ci0_i_q, mul_ci0_q_q, mul_cq0_qi_q, mul_cq0_iq_q;
    reg signed [15:0] mul_ci1_i_q, mul_ci1_q_q, mul_cq1_qi_q, mul_cq1_iq_q;
    reg signed [15:0] mul_e_cur0_i_q, mul_e_cur0_q_q, mul_e_del0_i_q, mul_e_del0_q_q;
    reg signed [15:0] mul_e_cur1_i_q, mul_e_cur1_q_q, mul_e_del1_i_q, mul_e_del1_q_q;
    reg signed [15:0] p_ci0_q, p_cq0_q, p_ci1_q, p_cq1_q;
    reg signed [15:0] e_cur0_q, e_del0_q, e_cur1_q, e_del1_q;

/* verilator lint_off UNUSEDSIGNAL */
wire signed [31:0] next_ci0   = acc_ci0 + {{16{p_ci0_q[15]}}, p_ci0_q};
wire signed [31:0] next_cq0   = acc_cq0 + {{16{p_cq0_q[15]}}, p_cq0_q};
wire signed [31:0] next_ci1   = acc_ci1 + {{16{p_ci1_q[15]}}, p_ci1_q};
wire signed [31:0] next_cq1   = acc_cq1 + {{16{p_cq1_q[15]}}, p_cq1_q};
wire signed [31:0] next_E0cur = acc_E0cur + {{16{e_cur0_q[15]}}, e_cur0_q};
wire signed [31:0] next_E0del = acc_E0del + {{16{e_del0_q[15]}}, e_del0_q};
wire signed [31:0] next_E1cur = acc_E1cur + {{16{e_cur1_q[15]}}, e_cur1_q};
wire signed [31:0] next_E1del = acc_E1del + {{16{e_del1_q[15]}}, e_del1_q};
/* verilator lint_on UNUSEDSIGNAL */

    // Symbol-boundary evaluation registers — NR=2
/* verilator lint_off UNUSEDSIGNAL */
    reg signed [31:0] sym_ci0, sym_cq0, sym_ci1, sym_cq1;
    reg signed [47:0] sym_mag_sc;
    reg signed [47:0] sym_E_ref;
/* verilator lint_on UNUSEDSIGNAL */

    // Hit detection
    reg [1:0]  hit_count;
    reg [31:0] first_hit_sample;
    reg [31:0] eval_sample_mark;
    reg        metric_valid_pulse;

    // Serialized metric engine — 7 steps total (NR=2):
    //   0-3: |c|^2 accumulation (ci0^2, cq0^2, ci1^2, cq1^2)
    //   4-5: energy accumulation (E0cur*E0del, E1cur*E1del) + latch sym_mag_sc at step 5
    //   6 (default): threshold: eval_prod = {8'b0,sc_thr} * eval_e_acc[47:24]
    //                hit iff {1'b0,eval_mag_acc[47:1]} >= eval_prod
    // Note: eval operands reduced to 24-bit (values fit in 23-bit signed).
    // sc_thr interpretation shifts by 2^8 vs. 32-bit version; scale sc_thr in software.
    reg        eval_busy;
    reg [3:0]  eval_step;
    reg signed [47:0] eval_mag_acc;
    reg signed [47:0] eval_e_acc;
    reg signed [23:0] eval_ci0, eval_cq0, eval_ci1, eval_cq1;
    reg signed [23:0] eval_E0cur, eval_E0del, eval_E1cur, eval_E1del;
    reg signed [23:0] eval_mul_a_sel, eval_mul_b_sel;
    wire signed [47:0] eval_prod;
    signed_mul24_pipe u_eval_mul (.clk(clk), .a(eval_mul_a_sel), .b(eval_mul_b_sel), .p(eval_prod));
    reg        eval_issue_done;
    reg [6:0]  eval_valid_pipe;
    reg [3:0]  eval_step_0, eval_step_1, eval_step_2, eval_step_3, eval_step_4, eval_step_5, eval_step_6;
    reg        eval_hit;

    // Registered mux: breaks the eval_step-fanout → mux-decode → abs-value critical path.
    // Adds one pipeline stage; eval_step_6 and eval_valid_pipe[6] track the extra cycle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eval_mul_a_sel <= 24'sd0;
            eval_mul_b_sel <= 24'sd0;
        end else begin
            case (eval_step)
                4'd0: begin eval_mul_a_sel <= eval_ci0;               eval_mul_b_sel <= eval_ci0;   end
                4'd1: begin eval_mul_a_sel <= eval_cq0;               eval_mul_b_sel <= eval_cq0;   end
                4'd2: begin eval_mul_a_sel <= eval_ci1;               eval_mul_b_sel <= eval_ci1;   end
                4'd3: begin eval_mul_a_sel <= eval_cq1;               eval_mul_b_sel <= eval_cq1;   end
                4'd4: begin eval_mul_a_sel <= eval_E0cur;             eval_mul_b_sel <= eval_E0del; end
                4'd5: begin eval_mul_a_sel <= eval_E1cur;             eval_mul_b_sel <= eval_E1del; end
                default: begin
                    eval_mul_a_sel <= $signed({8'b0, sc_thr});
                    eval_mul_b_sel <= $signed(eval_e_acc[47:24]);
                end
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count <= 32'd0;
            sym_cnt      <= 8'd0;
            acc_ci0 <= 32'sd0; acc_cq0 <= 32'sd0;
            acc_ci1 <= 32'sd0; acc_cq1 <= 32'sd0;
            acc_E0cur <= 32'sd0; acc_E0del <= 32'sd0;
            acc_E1cur <= 32'sd0; acc_E1del <= 32'sd0;
            sample_m_valid <= 1'b0;
            sample_p_valid <= 1'b0;
            mul_ci0_i_q <= 16'sd0; mul_ci0_q_q <= 16'sd0;
            mul_cq0_qi_q <= 16'sd0; mul_cq0_iq_q <= 16'sd0;
            mul_ci1_i_q <= 16'sd0; mul_ci1_q_q <= 16'sd0;
            mul_cq1_qi_q <= 16'sd0; mul_cq1_iq_q <= 16'sd0;
            mul_e_cur0_i_q <= 16'sd0; mul_e_cur0_q_q <= 16'sd0;
            mul_e_del0_i_q <= 16'sd0; mul_e_del0_q_q <= 16'sd0;
            mul_e_cur1_i_q <= 16'sd0; mul_e_cur1_q_q <= 16'sd0;
            mul_e_del1_i_q <= 16'sd0; mul_e_del1_q_q <= 16'sd0;
            p_ci0_q <= 16'sd0; p_cq0_q <= 16'sd0;
            p_ci1_q <= 16'sd0; p_cq1_q <= 16'sd0;
            e_cur0_q <= 16'sd0; e_del0_q <= 16'sd0;
            e_cur1_q <= 16'sd0; e_del1_q <= 16'sd0;
            sym_ci0 <= 32'sd0; sym_cq0 <= 32'sd0;
            sym_ci1 <= 32'sd0; sym_cq1 <= 32'sd0;
            sym_mag_sc <= 48'sd0;
            sym_E_ref  <= 48'sd0;
            hit_count  <= 2'd0;
            first_hit_sample <= 32'd0;
            eval_sample_mark <= 32'd0;
            metric_valid_pulse <= 1'b0;
            eval_busy <= 1'b0;
            eval_step <= 4'd0;
            eval_issue_done <= 1'b0;
            eval_valid_pipe <= 7'd0;
            eval_step_0 <= 4'd0; eval_step_1 <= 4'd0; eval_step_2 <= 4'd0;
            eval_step_3 <= 4'd0; eval_step_4 <= 4'd0; eval_step_5 <= 4'd0; eval_step_6 <= 4'd0;
            eval_mag_acc <= 48'sd0;
            eval_e_acc   <= 48'sd0;
            eval_hit     <= 1'b0;
            eval_ci0 <= 24'sd0; eval_cq0 <= 24'sd0;
            eval_ci1 <= 24'sd0; eval_cq1 <= 24'sd0;
            eval_E0cur <= 24'sd0; eval_E0del <= 24'sd0;
            eval_E1cur <= 24'sd0; eval_E1del <= 24'sd0;
            sc_lock    <= 1'b0;
            timing_ref <= 32'd0;
            c_i0 <= 32'sd0; c_q0 <= 32'sd0;
            c_i1 <= 32'sd0; c_q1 <= 32'sd0;
            sc_stat <= 16'd0;
            sc_hit_dbg <= 1'b0;
            sc_hit_count_dbg <= 2'd0;
            sc_first_hit_dbg <= 32'd0;
            sc_lock_sample_dbg <= 32'd0;
        end else begin
            metric_valid_pulse <= 1'b0;
            sc_hit_dbg <= 1'b0;

            sample_m_valid <= iq_valid_r && delayed_valid_r;
            sample_p_valid <= sample_m_valid;
            if (iq_valid_r && delayed_valid_r) begin
                mul_ci0_i_q <= mul_ci0_i;
                mul_ci0_q_q <= mul_ci0_q;
                mul_cq0_qi_q <= mul_cq0_qi;
                mul_cq0_iq_q <= mul_cq0_iq;
                mul_ci1_i_q <= mul_ci1_i;
                mul_ci1_q_q <= mul_ci1_q;
                mul_cq1_qi_q <= mul_cq1_qi;
                mul_cq1_iq_q <= mul_cq1_iq;
                mul_e_cur0_i_q <= mul_e_cur0_i;
                mul_e_cur0_q_q <= mul_e_cur0_q;
                mul_e_del0_i_q <= mul_e_del0_i;
                mul_e_del0_q_q <= mul_e_del0_q;
                mul_e_cur1_i_q <= mul_e_cur1_i;
                mul_e_cur1_q_q <= mul_e_cur1_q;
                mul_e_del1_i_q <= mul_e_del1_i;
                mul_e_del1_q_q <= mul_e_del1_q;
            end
            if (sample_m_valid) begin
                p_ci0_q <= mul_ci0_i_q + mul_ci0_q_q;
                p_cq0_q <= mul_cq0_qi_q - mul_cq0_iq_q;
                p_ci1_q <= mul_ci1_i_q + mul_ci1_q_q;
                p_cq1_q <= mul_cq1_qi_q - mul_cq1_iq_q;
                e_cur0_q <= mul_e_cur0_i_q + mul_e_cur0_q_q;
                e_del0_q <= mul_e_del0_i_q + mul_e_del0_q_q;
                e_cur1_q <= mul_e_cur1_i_q + mul_e_cur1_q_q;
                e_del1_q <= mul_e_del1_i_q + mul_e_del1_q_q;
            end

            if (sample_p_valid) begin
                sample_count <= sample_count + 32'd1;

                // Running accumulation uses registered products to keep input paths short.
                acc_ci0 <= next_ci0;
                acc_cq0 <= next_cq0;
                acc_ci1 <= next_ci1;
                acc_cq1 <= next_cq1;
                acc_E0cur <= next_E0cur;
                acc_E0del <= next_E0del;
                acc_E1cur <= next_E1cur;
                acc_E1del <= next_E1del;

                if (sym_cnt == M_val - 8'd1) begin
                    sym_cnt <= 8'd0;

                    sym_ci0 <= next_ci0;
                    sym_cq0 <= next_cq0;
                    sym_ci1 <= next_ci1;
                    sym_cq1 <= next_cq1;

                    // Values fit in 23-bit signed range for supported symbol lengths.
                    eval_ci0   <= next_ci0[23:0];
                    eval_cq0   <= next_cq0[23:0];
                    eval_ci1   <= next_ci1[23:0];
                    eval_cq1   <= next_cq1[23:0];
                    eval_E0cur <= next_E0cur[23:0];
                    eval_E0del <= next_E0del[23:0];
                    eval_E1cur <= next_E1cur[23:0];
                    eval_E1del <= next_E1del[23:0];
                    eval_mag_acc <= 48'sd0;
                    eval_e_acc   <= 48'sd0;
                    eval_step    <= 4'd0;
                    eval_issue_done <= 1'b0;
                    eval_valid_pipe <= 7'd0;
                    eval_busy    <= 1'b1;
                    eval_sample_mark <= sample_count + 32'd1;

                    acc_ci0 <= 32'sd0; acc_cq0 <= 32'sd0;
                    acc_ci1 <= 32'sd0; acc_cq1 <= 32'sd0;
                    acc_E0cur <= 32'sd0; acc_E0del <= 32'sd0;
                    acc_E1cur <= 32'sd0; acc_E1del <= 32'sd0;
                end else begin
                    sym_cnt <= sym_cnt + 8'd1;
                end
            end else if (iq_valid_r && !delayed_valid_r) begin
                sample_count <= sample_count + 32'd1;
            end

            if (eval_busy) begin
                eval_valid_pipe <= {eval_valid_pipe[5:0], !eval_issue_done};
                eval_step_0 <= eval_step;
                eval_step_1 <= eval_step_0;
                eval_step_2 <= eval_step_1;
                eval_step_3 <= eval_step_2;
                eval_step_4 <= eval_step_3;
                eval_step_5 <= eval_step_4;
                eval_step_6 <= eval_step_5;

                if (!eval_issue_done) begin
                    if (eval_step == 4'd6)
                        eval_issue_done <= 1'b1;
                    else
                        eval_step <= eval_step + 4'd1;
                end

                if (eval_valid_pipe[6]) begin
                    case (eval_step_6)
                        4'd0: eval_mag_acc <= eval_mag_acc + eval_prod;
                        4'd1: eval_mag_acc <= eval_mag_acc + eval_prod;
                        4'd2: eval_mag_acc <= eval_mag_acc + eval_prod;
                        4'd3: eval_mag_acc <= eval_mag_acc + eval_prod;
                        4'd4: eval_e_acc   <= eval_e_acc + eval_prod;
                        4'd5: begin
                            eval_e_acc <= eval_e_acc + eval_prod;
                            sym_mag_sc <= eval_mag_acc;
                        end
                        default: begin  // step 6: threshold and hit decision
                            sym_E_ref          <= eval_e_acc;
                            eval_hit           <= (eval_e_acc > 48'sd0) &&
                                                 ({1'b0, eval_mag_acc[47:1]} >= eval_prod);
                            eval_busy          <= 1'b0;
                            metric_valid_pulse <= 1'b1;
                        end
                    endcase
                end
            end

            if (metric_valid_pulse && !sc_lock) begin
                sc_hit_dbg <= eval_hit;
                if (eval_hit) begin
                    if (hit_count == 2'd0)
                        first_hit_sample <= eval_sample_mark;
                    if (hit_count == sc_hits_req) begin
                        sc_lock            <= 1'b1;
                        sc_lock_sample_dbg <= eval_sample_mark;
                        timing_ref <= eval_sample_mark
                                    - ({29'd0, sc_hits_req} + 32'd1) * {24'd0, M_val}
                                    + 32'd1;
                        c_i0 <= sym_ci0; c_q0 <= sym_cq0;
                        c_i1 <= sym_ci1; c_q1 <= sym_cq1;
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

            sc_stat <= sym_mag_sc[47:32];
        end
    end

endmodule
