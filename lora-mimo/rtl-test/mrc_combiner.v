// mrc_combiner.v
// MRC combiner: computes y = W * x over 4 antennas, outputs int8 I+Q.
// Weight generation stores already-conjugated MRC weights.
// TDM: one shared multiply-accumulate unit processes antennas 0-3 serially.
// Two pipeline stages:
//   w_re_a_r/w_im_b_r/w_re_c_r/w_im_d_r : four dedicated MUX registers, one per multiply sub-expression.
//   prod_i_r/prod_q_r   : registered multiply output (decouples multiply from add)
// At 16 MHz (62.5 ns) a full 16x8 signed multiply (~8 ns at TT, ~20-30 ns at SS)
// fits in one cycle; the registered product stage prevents multiply+add chaining
// which exceeded the SS corner budget.
// GF180MCU, 3.3V, 16 MHz DSP clock domain

module mrc_combiner (
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

    // State machine:
    //  0 : idle — wait for x_valid, latch all inputs, prime ant-0 multiply regs
    //  1 : latch prod(ant0) → prod_i_r/prod_q_r; prime ant-1 multiply regs
    //  2 : acc += prod_r(ant0); latch prod(ant1); prime ant-2 multiply regs
    //  3 : acc += prod_r(ant1); latch prod(ant2); prime ant-3 multiply regs
    //  4 : acc += prod_r(ant2); latch prod(ant3)
    //  5 : acc_final = acc + prod_r(ant3)
    //  9 : saturate + output
    reg [3:0] state;

    // Latched inputs
    reg signed [7:0]  xr_i [0:3];
    reg signed [7:0]  xr_q [0:3];
    reg signed [15:0] wr_re [0:3];
    reg signed [15:0] wr_im [0:3];
    reg signed [7:0]  bypass_i_r, bypass_q_r;
    reg               use_mrc_r;

    // Eight dedicated MUX pipeline registers — one W and one X copy per multiply sub-expression.
    //   A: w_re_a_r * x_i_a_r  (prod_i real)
    //   B: w_im_b_r * x_q_b_r  (prod_i imag)
    //   C: w_re_c_r * x_q_c_r  (prod_q real)
    //   D: w_im_d_r * x_i_d_r  (prod_q imag)
    reg signed [15:0] w_re_a_r, w_im_b_r, w_re_c_r, w_im_d_r;
    reg signed [7:0]  x_i_a_r,  x_q_b_r,  x_q_c_r,  x_i_d_r;

    // Registered multiply output — decouples the multiply tree from the adder tree.
    // Critical path is now: W/X regs → multiply → prod_r (one cycle)
    // followed by:          prod_r → add → acc (next cycle).
    reg signed [23:0] prod_i_r, prod_q_r;

    // Running accumulator (26-bit: 24-bit product sign-extended, sum of 4)
    reg signed [25:0] acc_i, acc_q;

    // Final-sum pipeline register (breaks final add from saturate)
    reg signed [25:0] acc_i_final_r, acc_q_final_r;

    // Full 16x8 signed multiplies — combinatorial; result registered into prod_i_r/prod_q_r
    wire signed [23:0] prod_i_next = (w_re_a_r * x_i_a_r) - (w_im_b_r * x_q_b_r);
    wire signed [23:0] prod_q_next = (w_re_c_r * x_q_c_r) + (w_im_d_r * x_i_d_r);

    // Saturation from registered final accumulator. A fixed guard divide-by-2
    // remains before the software-selectable post-combine gain shift.
    wire signed [25:0] guarded_i_f = acc_i_final_r >>> 1;
    wire signed [25:0] guarded_q_f = acc_q_final_r >>> 1;
    wire signed [32:0] shifted_i_f = $signed({{7{guarded_i_f[25]}}, guarded_i_f}) <<< post_gain_shift;
    wire signed [32:0] shifted_q_f = $signed({{7{guarded_q_f[25]}}, guarded_q_f}) <<< post_gain_shift;
    wire signed [8:0] sat_i = (shifted_i_f > 33'sd127)  ?  9'sd127 :
                               (shifted_i_f < -33'sd128) ? -9'sd128 :
                               shifted_i_f[8:0];
    wire signed [8:0] sat_q = (shifted_q_f > 33'sd127)  ?  9'sd127 :
                               (shifted_q_f < -33'sd128) ? -9'sd128 :
                               shifted_q_f[8:0];

    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n) begin
            state           <= 4'd0;
            w_re_a_r        <= 16'sd0;
            w_im_b_r        <= 16'sd0;
            w_re_c_r        <= 16'sd0;
            w_im_d_r        <= 16'sd0;
            x_i_a_r         <= 8'sd0;
            x_q_b_r         <= 8'sd0;
            x_q_c_r         <= 8'sd0;
            x_i_d_r         <= 8'sd0;
            prod_i_r        <= 24'sd0;
            prod_q_r        <= 24'sd0;
            acc_i           <= 26'sd0;
            acc_q           <= 26'sd0;
            acc_i_final_r   <= 26'sd0;
            acc_q_final_r   <= 26'sd0;
            xr_i[0]  <= 8'sd0; xr_i[1]  <= 8'sd0; xr_i[2]  <= 8'sd0; xr_i[3]  <= 8'sd0;
            xr_q[0]  <= 8'sd0; xr_q[1]  <= 8'sd0; xr_q[2]  <= 8'sd0; xr_q[3]  <= 8'sd0;
            wr_re[0] <= 16'sd0; wr_re[1] <= 16'sd0; wr_re[2] <= 16'sd0; wr_re[3] <= 16'sd0;
            wr_im[0] <= 16'sd0; wr_im[1] <= 16'sd0; wr_im[2] <= 16'sd0; wr_im[3] <= 16'sd0;
            bypass_i_r <= 8'sd0;
            bypass_q_r <= 8'sd0;
            use_mrc_r  <= 1'b0;
            y_i        <= 8'sd0;
            y_q        <= 8'sd0;
            y_valid    <= 1'b0;
        end else begin
            y_valid <= 1'b0;

            if (x_valid && state == 4'd0) begin
                // Latch all inputs; prime ant-0 multiply regs
                xr_i[0] <= x_i0; xr_q[0] <= x_q0;
                xr_i[1] <= x_i1; xr_q[1] <= x_q1;
                xr_i[2] <= x_i2; xr_q[2] <= x_q2;
                xr_i[3] <= x_i3; xr_q[3] <= x_q3;
                wr_re[0] <= W_re0; wr_im[0] <= W_im0;
                wr_re[1] <= W_re1; wr_im[1] <= W_im1;
                wr_re[2] <= W_re2; wr_im[2] <= W_im2;
                wr_re[3] <= W_re3; wr_im[3] <= W_im3;
                case (bypass_ant)
                    2'd0: begin bypass_i_r <= x_i0; bypass_q_r <= x_q0; end
                    2'd1: begin bypass_i_r <= x_i1; bypass_q_r <= x_q1; end
                    2'd2: begin bypass_i_r <= x_i2; bypass_q_r <= x_q2; end
                    default: begin bypass_i_r <= x_i3; bypass_q_r <= x_q3; end
                endcase
                use_mrc_r  <= W_valid && !mode;
                acc_i      <= 26'sd0;
                acc_q      <= 26'sd0;
                w_re_a_r <= W_re0; w_im_b_r <= W_im0;
                w_re_c_r <= W_re0; w_im_d_r <= W_im0;
                x_i_a_r  <= x_i0;  x_q_b_r  <= x_q0;
                x_q_c_r  <= x_q0;  x_i_d_r  <= x_i0;
                state    <= 4'd1;

            end else if (state == 4'd1) begin
                // Ant-0 multiply result is ready — register it; prime ant-1
                prod_i_r  <= prod_i_next;
                prod_q_r  <= prod_q_next;
                w_re_a_r  <= wr_re[1]; w_im_b_r <= wr_im[1];
                w_re_c_r  <= wr_re[1]; w_im_d_r <= wr_im[1];
                x_i_a_r   <= xr_i[1];  x_q_b_r  <= xr_q[1];
                x_q_c_r   <= xr_q[1];  x_i_d_r  <= xr_i[1];
                state     <= 4'd2;

            end else if (state == 4'd2) begin
                // Accumulate ant-0 product; register ant-1 result; prime ant-2
                acc_i     <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q     <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                prod_i_r  <= prod_i_next;
                prod_q_r  <= prod_q_next;
                w_re_a_r  <= wr_re[2]; w_im_b_r <= wr_im[2];
                w_re_c_r  <= wr_re[2]; w_im_d_r <= wr_im[2];
                x_i_a_r   <= xr_i[2];  x_q_b_r  <= xr_q[2];
                x_q_c_r   <= xr_q[2];  x_i_d_r  <= xr_i[2];
                state     <= 4'd3;

            end else if (state == 4'd3) begin
                // Accumulate ant-1 product; register ant-2 result; prime ant-3
                acc_i     <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q     <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                prod_i_r  <= prod_i_next;
                prod_q_r  <= prod_q_next;
                w_re_a_r  <= wr_re[3]; w_im_b_r <= wr_im[3];
                w_re_c_r  <= wr_re[3]; w_im_d_r <= wr_im[3];
                x_i_a_r   <= xr_i[3];  x_q_b_r  <= xr_q[3];
                x_q_c_r   <= xr_q[3];  x_i_d_r  <= xr_i[3];
                state     <= 4'd4;

            end else if (state == 4'd4) begin
                // Accumulate ant-2 product; register ant-3 result
                acc_i     <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q     <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                prod_i_r  <= prod_i_next;
                prod_q_r  <= prod_q_next;
                state     <= 4'd5;

            end else if (state == 4'd5) begin
                // Final accumulate — latch for saturate path
                acc_i_final_r <= acc_i + {{2{prod_i_r[23]}}, prod_i_r};
                acc_q_final_r <= acc_q + {{2{prod_q_r[23]}}, prod_q_r};
                state <= 4'd9;

            end else if (state == 4'd9) begin
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
        end
    end

endmodule
