// sd_decim_2ch_shiftadd.v
// Synthesis wrapper: 2 × sd_decimator_shiftadd (CIC + shift-add FIR, NR=2).

`timescale 1ns/100ps

module sd_decim_2ch_shiftadd (
    input  wire        clk_32m,
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire [1:0]  iq_in_i,
    input  wire [1:0]  iq_in_q,
    output wire [15:0] iq_out_i,
    output wire [15:0] iq_out_q,
    output wire [1:0]  iq_valid
);
    genvar g;
    generate
        for (g = 0; g < 2; g = g+1) begin : ch
            sd_decimator_shiftadd u (
                .clk_32m    (clk_32m),
                .clk_16m    (clk_16m),
                .rst_n      (rst_n),
                .iq_in_i    (iq_in_i[g]),
                .iq_in_q    (iq_in_q[g]),
                .decim_ratio(2'b00),
                .iq_out_i   (iq_out_i[8*g+7 -: 8]),
                .iq_out_q   (iq_out_q[8*g+7 -: 8]),
                .iq_valid   (iq_valid[g])
            );
        end
    endgenerate
endmodule
