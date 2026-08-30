module comb_remod_transfer (
    input wire clk, input wire rst_n, input wire x_valid,
    input wire signed [7:0] x_i, x_q,
    input wire signed [7:0] w_re, w_im,
    input wire [2:0] pgs, input wire mode,
    output wire y_valid, output wire signed [7:0] y_i, y_q,
    output wire out_i, out_q
);
    mrc_combiner u_comb (
        .clk_16m(clk), .rst_n(rst_n),
        .x_i0(x_i), .x_q0(x_q), .x_i1(0), .x_q1(0), .x_i2(0), .x_q2(0), .x_i3(0), .x_q3(0),
        .x_valid(x_valid), .W_re0(w_re), .W_im0(w_im), .W_re1(0), .W_im1(0), .W_re2(0), .W_im2(0), .W_re3(0), .W_im3(0),
        .W_valid(1'b1), .mode(mode), .bypass_ant(2'd0), .post_gain_shift(pgs),
        .y_i(y_i), .y_q(y_q), .y_valid(y_valid));
    sd_remod u_remod (.clk_32m(clk), .rst_n(rst_n), .in_i(y_i), .in_q(y_q), .in_valid(y_valid), .en(1'b1), .out_i(out_i), .out_q(out_q));
endmodule
