// training_acc.v
// All-pairs cross-correlator: computes all C(4,2)=6 branch-pair cross-correlations
// and accumulates them into per-branch sums W_k = Σ_{l≠k} Z_kl.
//
// MRC weight:  w_k = conj(W_k) / noise_est[k]²
//   No fixed reference branch — robust to individual branch fading.
//   Inactive branches (raw=0) contribute zero automatically.
//
// TDM: 6 pairs × 4 sub-steps = 24 active steps, 25 cycles total.
// Budget: iq_valid every ≥128 cycles (CIC R=128) — 103 cycles idle.
//
// Pair table (a < b):
//   0=(0,1)  1=(0,2)  2=(0,3)  3=(1,2)  4=(1,3)  5=(2,3)
//
// Sub-steps per pair (a,b):
//   sub=0: I_a×I_b → p_latch
//   sub=1: Q_a×Q_b → W_i[a] += p_latch+mul,  W_i[b] += p_latch+mul
//   sub=2: Q_a×I_b → p_latch
//   sub=3: I_a×Q_b → W_q[a] += p_latch−mul,  W_q[b] −= p_latch−mul  (conj)
//          at pair=5, last_samp: commit all outputs, assert training_done
//
// Operand encoding (same as single-ref design, op_b now uses pair_b branch):
//   op_a = (sub[0]^sub[1]) ? raw_qr[pair_a] : raw_ir[pair_a]
//   op_b =  sub[0]         ? raw_qr[pair_b] : raw_ir[pair_b]
//
// Accumulators: 32-bit signed. Max |W_k| = 3×1.06G ≈ 3.2G — fits with AGC.
// Output ports: 32-bit (direct, no sign extension).
// GF180MCU, 3.3V, 16 MHz clock domain.

module training_acc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] raw_i0, raw_i1, raw_i2, raw_i3,
    input  wire signed [7:0] raw_q0, raw_q1, raw_q2, raw_q3,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire [3:0]  sf,
    output reg  signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    output reg         training_done,
    output reg  [9:0]  n_acc
);

    reg [31:0] sample_count;
    reg [31:0] acc_start, acc_end;
    reg        armed;

    // TDM counters: pair (0-5) and sub-step (0-3)
    reg [2:0] tdm_pair;
    reg [1:0] tdm_sub;
    reg       tdm_active;

    // 1-cycle delayed tags (synchronised with mul_out)
    reg [2:0] acc_pair;
    reg [1:0] acc_sub;
    reg       acc_active;

    // Pair lookup: pair index → (branch_a, branch_b), always a < b
    reg [1:0] tdm_pa, tdm_pb;
    always @(*) begin
        case (tdm_pair)
            3'd0: begin tdm_pa = 2'd0; tdm_pb = 2'd1; end
            3'd1: begin tdm_pa = 2'd0; tdm_pb = 2'd2; end
            3'd2: begin tdm_pa = 2'd0; tdm_pb = 2'd3; end
            3'd3: begin tdm_pa = 2'd1; tdm_pb = 2'd2; end
            3'd4: begin tdm_pa = 2'd1; tdm_pb = 2'd3; end
            default: begin tdm_pa = 2'd2; tdm_pb = 2'd3; end  // pair 5
        endcase
    end

    reg [1:0] acc_pa, acc_pb;
    always @(*) begin
        case (acc_pair)
            3'd0: begin acc_pa = 2'd0; acc_pb = 2'd1; end
            3'd1: begin acc_pa = 2'd0; acc_pb = 2'd2; end
            3'd2: begin acc_pa = 2'd0; acc_pb = 2'd3; end
            3'd3: begin acc_pa = 2'd1; acc_pb = 2'd2; end
            3'd4: begin acc_pa = 2'd1; acc_pb = 2'd3; end
            default: begin acc_pa = 2'd2; acc_pb = 2'd3; end  // pair 5
        endcase
    end

    // Latched branch samples (captured at iq_valid trigger)
    reg signed [7:0] raw_ir [0:3];
    reg signed [7:0] raw_qr [0:3];
    reg              last_samp;

    // Registered operands → pipelined 8×8 multiplier
    reg signed [7:0]  op_a, op_b;
    reg signed [15:0] mul_out;
    always @(posedge clk) begin
        op_a    <= (tdm_sub[0]^tdm_sub[1]) ? raw_qr[tdm_pa] : raw_ir[tdm_pa];
        op_b    <=  tdm_sub[0]              ? raw_qr[tdm_pb] : raw_ir[tdm_pb];
        mul_out <= op_a * op_b;
    end

    // Intermediate product latch (holds even-sub result for odd-sub combine)
    reg signed [15:0] p_latch;

    // Per-branch 32-bit accumulators: W_k = Σ_{l≠k} Z_kl
    reg signed [31:0] W_i_a [0:3];
    reg signed [31:0] W_q_a [0:3];

    // Sign-extended addends (32-bit) for the current product
    wire signed [31:0] pl_ext  = {{16{p_latch[15]}},  p_latch};
    wire signed [31:0] mul_ext = {{16{mul_out[15]}},  mul_out};
    wire signed [31:0] zq_cur  = pl_ext - mul_ext;

    // Explicit read muxes for variable-index accumulator reads.
    // Direct variable-index array reads (W_x_a[acc_p*]) cause Yosys $mem2reg to
    // produce fully-undriven read data (all 32 bits → 0 after setundef), silently
    // breaking accumulation.  Case-mux forces purely combinational MUX inference.
    reg signed [31:0] wia_pa_r, wia_pb_r, wqa_pa_r, wqa_pb_r;
    always @(*) begin
        case (acc_pa)
            2'd0: begin wia_pa_r = W_i_a[0]; wqa_pa_r = W_q_a[0]; end
            2'd1: begin wia_pa_r = W_i_a[1]; wqa_pa_r = W_q_a[1]; end
            2'd2: begin wia_pa_r = W_i_a[2]; wqa_pa_r = W_q_a[2]; end
            default: begin wia_pa_r = W_i_a[3]; wqa_pa_r = W_q_a[3]; end
        endcase
        case (acc_pb)
            2'd0: begin wia_pb_r = W_i_a[0]; wqa_pb_r = W_q_a[0]; end
            2'd1: begin wia_pb_r = W_i_a[1]; wqa_pb_r = W_q_a[1]; end
            2'd2: begin wia_pb_r = W_i_a[2]; wqa_pb_r = W_q_a[2]; end
            default: begin wia_pb_r = W_i_a[3]; wqa_pb_r = W_q_a[3]; end
        endcase
    end

    // Fresh W_q values for the last pair (2,3) — needed at commit same cycle
    wire signed [31:0] wq2_final = W_q_a[2] + zq_cur;
    wire signed [31:0] wq3_final = W_q_a[3] - zq_cur;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count  <= 32'd0;
            armed         <= 1'b0;
            training_done <= 1'b0;
            n_acc         <= 10'd0;
            acc_start     <= 32'd0;
            acc_end       <= 32'd0;
            tdm_pair      <= 3'd0;
            tdm_sub       <= 2'd0;
            tdm_active    <= 1'b0;
            acc_pair      <= 3'd0;
            acc_sub       <= 2'd0;
            acc_active    <= 1'b0;
            last_samp     <= 1'b0;
            raw_ir[0] <= 8'sd0; raw_ir[1] <= 8'sd0;
            raw_ir[2] <= 8'sd0; raw_ir[3] <= 8'sd0;
            raw_qr[0] <= 8'sd0; raw_qr[1] <= 8'sd0;
            raw_qr[2] <= 8'sd0; raw_qr[3] <= 8'sd0;
            p_latch <= 16'sd0;
            W_i_a[0] <= 32'sd0; W_q_a[0] <= 32'sd0;
            W_i_a[1] <= 32'sd0; W_q_a[1] <= 32'sd0;
            W_i_a[2] <= 32'sd0; W_q_a[2] <= 32'sd0;
            W_i_a[3] <= 32'sd0; W_q_a[3] <= 32'sd0;
            Z_i0 <= 32'sd0; Z_q0 <= 32'sd0;
            Z_i1 <= 32'sd0; Z_q1 <= 32'sd0;
            Z_i2 <= 32'sd0; Z_q2 <= 32'sd0;
            Z_i3 <= 32'sd0; Z_q3 <= 32'sd0;
        end else begin
            if (iq_valid)
                sample_count <= sample_count + 32'd1;

            // Disarm when sc_lock deasserts
            if (!sc_lock) begin
                armed      <= 1'b0;
                tdm_active <= 1'b0;
                tdm_pair   <= 3'd0;
                tdm_sub    <= 2'd0;
            end

            // Arm on sc_lock rising edge — reset per-branch accumulators
            if (sc_lock && !armed) begin
                armed         <= 1'b1;
                training_done <= 1'b0;
                acc_start     <= timing_ref;
                acc_end       <= timing_ref + (32'd1 << (sf[3:0] + 4'd3)) - 32'd1;
                W_i_a[0] <= 32'sd0; W_q_a[0] <= 32'sd0;
                W_i_a[1] <= 32'sd0; W_q_a[1] <= 32'sd0;
                W_i_a[2] <= 32'sd0; W_q_a[2] <= 32'sd0;
                W_i_a[3] <= 32'sd0; W_q_a[3] <= 32'sd0;
                n_acc <= 10'd0;
            end

            // Trigger TDM on iq_valid within window when idle
            if (armed && sc_lock && iq_valid && !tdm_active &&
                    sample_count >= acc_start && sample_count <= acc_end &&
                    !training_done) begin
                raw_ir[0] <= raw_i0; raw_qr[0] <= raw_q0;
                raw_ir[1] <= raw_i1; raw_qr[1] <= raw_q1;
                raw_ir[2] <= raw_i2; raw_qr[2] <= raw_q2;
                raw_ir[3] <= raw_i3; raw_qr[3] <= raw_q3;
                last_samp  <= (sample_count == acc_end);
                if (n_acc < 10'd1023)
                    n_acc <= n_acc + 10'd1;
                tdm_pair   <= 3'd0;
                tdm_sub    <= 2'd0;
                tdm_active <= 1'b1;
            end else if (tdm_active) begin
                if (tdm_sub == 2'd3) begin
                    tdm_sub <= 2'd0;
                    if (tdm_pair == 3'd5)
                        tdm_active <= 1'b0;
                    else
                        tdm_pair <= tdm_pair + 3'd1;
                end else
                    tdm_sub <= tdm_sub + 2'd1;
            end

            // Delayed tags — synchronised with mul_out
            acc_pair   <= tdm_pair;
            acc_sub    <= tdm_sub;
            acc_active <= tdm_active;

            // Accumulate when product is ready
            if (acc_active) begin
                if (acc_sub[0] == 1'b0) begin
                    // Even sub (0 or 2): latch product
                    p_latch <= mul_out;

                end else if (acc_sub[1] == 1'b0) begin
                    // sub=1: Z_i = I_a×I_b + Q_a×Q_b
                    // Both pair_a and pair_b branches accumulate the same value
                    W_i_a[acc_pa] <= wia_pa_r + pl_ext + mul_ext;
                    W_i_a[acc_pb] <= wia_pb_r + pl_ext + mul_ext;

                end else begin
                    // sub=3: Z_q = Q_a×I_b − I_a×Q_b
                    // pair_a adds +zq_cur, pair_b adds −zq_cur (conjugate symmetry)
                    if (acc_pair == 3'd5 && last_samp) begin
                        // Last pair (2,3): commit using combinatorial fresh values
                        W_q_a[2]      <= wq2_final;
                        W_q_a[3]      <= wq3_final;
                        Z_i0          <= W_i_a[0];
                        Z_q0          <= W_q_a[0];
                        Z_i1          <= W_i_a[1];
                        Z_q1          <= W_q_a[1];
                        Z_i2          <= W_i_a[2];
                        Z_q2          <= wq2_final;
                        Z_i3          <= W_i_a[3];
                        Z_q3          <= wq3_final;
                        training_done <= 1'b1;
                    end else begin
                        W_q_a[acc_pa] <= wqa_pa_r + zq_cur;
                        W_q_a[acc_pb] <= wqa_pb_r - zq_cur;
                    end
                end
            end
        end
    end

endmodule
