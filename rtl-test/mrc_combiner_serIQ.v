// mrc_combiner_serIQ.v
// MRC combiner — Option A: serialise I and Q multiply (4 muls → 2 muls).
//
// Each complex multiply is split into two sub-cycles sharing two 16×8 multipliers:
//   Sub-cycle 1 (using w_re): mul_i = w_re × x_i,  mul_q = w_re × x_q  → save a_r, c_r
//   Sub-cycle 2 (using w_im): mul_i = w_im × x_q,  mul_q = w_im × x_i
//     prod_i = a_r − mul_i = w_re×x_i − w_im×x_q
//     prod_q = c_r + mul_q = w_re×x_q + w_im×x_i
//
// State count: 11 (vs 7 in mrc_combiner.v). Budget: 256 cycles at R=256.
// Accumulator, bypass, saturation, post_gain_shift logic unchanged.
// GF180MCU, 3.3V, 16 MHz DSP clock domain

`timescale 1ns/100ps

module mrc_combiner_serIQ (
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire signed [7:0]  x_i0, x_q0, x_i1, x_q1,
    input  wire signed [7:0]  x_i2, x_q2, x_i3, x_q3,
    input  wire        x_valid,
    input  wire signed [15:0] W_re0, W_im0, W_re1, W_im1,
    input  wire signed [15:0] W_re2, W_im2, W_re3, W_im3,
    input  wire        W_valid,
    input  wire        mode,
    input  wire [1:0]  bypass_ant,
    input  wire [2:0]  post_gain_shift,
    output reg  signed [7:0] y_i, y_q,
    output reg         y_valid
);

    reg [3:0] state;

    // Latched inputs
    reg signed [7:0]  xr_i [0:3];
    reg signed [7:0]  xr_q [0:3];
    reg signed [15:0] wr_re [0:3];
    reg signed [15:0] wr_im [0:3];
    reg signed [7:0]  bypass_i_r, bypass_q_r;
    reg               use_mrc_r;

    // 2-multiplier shared registers (instead of 8 dedicated A/B/C/D regs)
    reg signed [15:0] w_r;       // W coefficient for this sub-cycle
    reg signed [7:0]  xi_r;      // feeds mul_i = w_r × xi_r
    reg signed [7:0]  xq_r;      // feeds mul_q = w_r × xq_r

    // Sub-cycle 1 intermediate saves
    reg signed [23:0] a_r, c_r;  // w_re×x_i and w_re×x_q

    // Registered multiply output
    reg signed [23:0] prod_i_r, prod_q_r;

    // Accumulator
    reg signed [25:0] acc_i, acc_q;
    reg signed [25:0] acc_i_final_r, acc_q_final_r;

    // Two shared multipliers — combinatorial from w_r/xi_r/xq_r
    wire signed [23:0] mul_i_next = w_r * xi_r;
    wire signed [23:0] mul_q_next = w_r * xq_r;

    // Saturation path (unchanged from mrc_combiner.v)
    wire signed [25:0] guarded_i_f = acc_i_final_r >>> 1;
    wire signed [25:0] guarded_q_f = acc_q_final_r >>> 1;
    wire signed [32:0] shifted_i_f = $signed({{7{guarded_i_f[25]}}, guarded_i_f}) <<< post_gain_shift;
    wire signed [32:0] shifted_q_f = $signed({{7{guarded_q_f[25]}}, guarded_q_f}) <<< post_gain_shift;
    wire signed [8:0] sat_i = (shifted_i_f >  33'sd127) ?  9'sd127 :
                               (shifted_i_f < -33'sd128) ? -9'sd128 :
                               shifted_i_f[8:0];
    wire signed [8:0] sat_q = (shifted_q_f >  33'sd127) ?  9'sd127 :
                               (shifted_q_f < -33'sd128) ? -9'sd128 :
                               shifted_q_f[8:0];

    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n) begin
            state <= 4'd0;
            w_r <= 16'sd0; xi_r <= 8'sd0; xq_r <= 8'sd0;
            a_r <= 24'sd0; c_r <= 24'sd0;
            prod_i_r <= 24'sd0; prod_q_r <= 24'sd0;
            acc_i <= 26'sd0; acc_q <= 26'sd0;
            acc_i_final_r <= 26'sd0; acc_q_final_r <= 26'sd0;
            xr_i[0]<=8'sd0; xr_i[1]<=8'sd0; xr_i[2]<=8'sd0; xr_i[3]<=8'sd0;
            xr_q[0]<=8'sd0; xr_q[1]<=8'sd0; xr_q[2]<=8'sd0; xr_q[3]<=8'sd0;
            wr_re[0]<=16'sd0; wr_re[1]<=16'sd0; wr_re[2]<=16'sd0; wr_re[3]<=16'sd0;
            wr_im[0]<=16'sd0; wr_im[1]<=16'sd0; wr_im[2]<=16'sd0; wr_im[3]<=16'sd0;
            bypass_i_r<=8'sd0; bypass_q_r<=8'sd0; use_mrc_r<=1'b0;
            y_i<=8'sd0; y_q<=8'sd0; y_valid<=1'b0;
        end else begin
            y_valid <= 1'b0;

            case (state)

            // ── IDLE ────────────────────────────────────────────────────────
            4'd0: if (x_valid) begin
                xr_i[0]<=x_i0; xr_q[0]<=x_q0; wr_re[0]<=W_re0; wr_im[0]<=W_im0;
                xr_i[1]<=x_i1; xr_q[1]<=x_q1; wr_re[1]<=W_re1; wr_im[1]<=W_im1;
                xr_i[2]<=x_i2; xr_q[2]<=x_q2; wr_re[2]<=W_re2; wr_im[2]<=W_im2;
                xr_i[3]<=x_i3; xr_q[3]<=x_q3; wr_re[3]<=W_re3; wr_im[3]<=W_im3;
                case (bypass_ant)
                    2'd0: begin bypass_i_r<=x_i0; bypass_q_r<=x_q0; end
                    2'd1: begin bypass_i_r<=x_i1; bypass_q_r<=x_q1; end
                    2'd2: begin bypass_i_r<=x_i2; bypass_q_r<=x_q2; end
                    default: begin bypass_i_r<=x_i3; bypass_q_r<=x_q3; end
                endcase
                use_mrc_r <= W_valid && !mode;
                acc_i <= 26'sd0; acc_q <= 26'sd0;
                // Prime ant0 sub-cycle 1: w_re0, x_i0, x_q0
                w_r <= W_re0; xi_r <= x_i0; xq_r <= x_q0;
                state <= 4'd1;
            end

            // ── ANT0 SUB1 result ready → save a_r/c_r; prime ant0 sub2 ────
            4'd1: begin
                a_r <= mul_i_next;              // w_re0 × x_i0
                c_r <= mul_q_next;              // w_re0 × x_q0
                w_r <= wr_im[0]; xi_r <= xr_q[0]; xq_r <= xr_i[0];  // sub2: swap xi/xq
                state <= 4'd2;
            end

            // ── ANT0 SUB2 → form prod0; prime ant1 sub1 ─────────────────────
            4'd2: begin
                prod_i_r <= a_r - mul_i_next;   // w_re0×x_i0 − w_im0×x_q0
                prod_q_r <= c_r + mul_q_next;   // w_re0×x_q0 + w_im0×x_i0
                w_r <= wr_re[1]; xi_r <= xr_i[1]; xq_r <= xr_q[1];
                state <= 4'd3;
            end

            // ── ANT1 SUB1: acc+=prod0; save a_r/c_r; prime ant1 sub2 ────────
            4'd3: begin
                acc_i <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                a_r <= mul_i_next;              // w_re1 × x_i1
                c_r <= mul_q_next;              // w_re1 × x_q1
                w_r <= wr_im[1]; xi_r <= xr_q[1]; xq_r <= xr_i[1];
                state <= 4'd4;
            end

            // ── ANT1 SUB2 → form prod1; prime ant2 sub1 ─────────────────────
            4'd4: begin
                prod_i_r <= a_r - mul_i_next;
                prod_q_r <= c_r + mul_q_next;
                w_r <= wr_re[2]; xi_r <= xr_i[2]; xq_r <= xr_q[2];
                state <= 4'd5;
            end

            // ── ANT2 SUB1: acc+=prod1; save a_r/c_r; prime ant2 sub2 ────────
            4'd5: begin
                acc_i <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                a_r <= mul_i_next;
                c_r <= mul_q_next;
                w_r <= wr_im[2]; xi_r <= xr_q[2]; xq_r <= xr_i[2];
                state <= 4'd6;
            end

            // ── ANT2 SUB2 → form prod2; prime ant3 sub1 ─────────────────────
            4'd6: begin
                prod_i_r <= a_r - mul_i_next;
                prod_q_r <= c_r + mul_q_next;
                w_r <= wr_re[3]; xi_r <= xr_i[3]; xq_r <= xr_q[3];
                state <= 4'd7;
            end

            // ── ANT3 SUB1: acc+=prod2; save a_r/c_r; prime ant3 sub2 ────────
            4'd7: begin
                acc_i <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                a_r <= mul_i_next;
                c_r <= mul_q_next;
                w_r <= wr_im[3]; xi_r <= xr_q[3]; xq_r <= xr_i[3];
                state <= 4'd8;
            end

            // ── ANT3 SUB2 → form prod3 ──────────────────────────────────────
            4'd8: begin
                prod_i_r <= a_r - mul_i_next;
                prod_q_r <= c_r + mul_q_next;
                state <= 4'd9;
            end

            // ── Final accumulate ─────────────────────────────────────────────
            4'd9: begin
                acc_i_final_r <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q_final_r <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                state <= 4'd10;
            end

            // ── Output ───────────────────────────────────────────────────────
            4'd10: begin
                state   <= 4'd0;
                y_valid <= 1'b1;
                if (use_mrc_r) begin
                    y_i <= sat_i[7:0];
                    y_q <= sat_q[7:0];
                end else begin
                    y_i <= bypass_i_r;
                    y_q <= bypass_q_r;
                end
            end

            default: state <= 4'd0;
            endcase
        end
    end

endmodule
