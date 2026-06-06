// weight_gen_bb.v — Yosys blackbox stub; synthesised separately via synth_weight_gen.ys
(* blackbox *)
module weight_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        training_done,
    input  wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    input  wire [9:0]  n_acc,
    input  wire        wgt_src,
    input  wire        wgt_auto_commit,
    input  wire [1:0]  wgt_mode,
    input  wire [3:0]  antenna_en,
    input  wire signed [15:0] cal_re0, cal_im0, cal_re1, cal_im1,
    input  wire signed [15:0] cal_re2, cal_im2, cal_re3, cal_im3,
    input  wire signed [15:0] fw_W_re0, fw_W_im0, fw_W_re1, fw_W_im1,
    input  wire signed [15:0] fw_W_re2, fw_W_im2, fw_W_re3, fw_W_im3,
    input  wire        fw_W_commit,
    output reg  signed [15:0] W_hw_re0, W_hw_im0, W_hw_re1, W_hw_im1,
    output reg  signed [15:0] W_hw_re2, W_hw_im2, W_hw_re3, W_hw_im3,
    output reg  signed [15:0] W_shadow_re0, W_shadow_im0,
    output reg  signed [15:0] W_shadow_re1, W_shadow_im1,
    output reg  signed [15:0] W_shadow_re2, W_shadow_im2,
    output reg  signed [15:0] W_shadow_re3, W_shadow_im3,
    output reg         W_commit,
    output reg         wgen_hw_done,
    output reg         wgen_active,
    output reg  [1:0]  wgen_mode_dbg
);
endmodule
