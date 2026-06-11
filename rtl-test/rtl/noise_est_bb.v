// Noise estimation removed from Trouper — training_acc ZDIAG handles it.
`default_nettype none
module noise_est (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire        sc_lock,
    input  wire signed [7:0] dcr_i0, dcr_i1, dcr_i2, dcr_i3,
    input  wire signed [7:0] dcr_q0, dcr_q1, dcr_q2, dcr_q3,
    output wire [7:0]  noise_snap_0, noise_snap_1,
    output wire [7:0]  noise_snap_2, noise_snap_3
);
    assign noise_snap_0 = 8'b0;
    assign noise_snap_1 = 8'b0;
    assign noise_snap_2 = 8'b0;
    assign noise_snap_3 = 8'b0;
endmodule
`default_nettype wire
