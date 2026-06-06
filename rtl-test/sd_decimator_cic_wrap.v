// Wrapper to let tb_sqnr.v (which instantiates sd_decimator) test
// sd_decimator_cic_only. Drop-in: identical port list, clk_16m accepted
// but unused inside sd_decimator_cic_only.
module sd_decimator (
    input  wire        clk_32m,
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire        iq_in_i,
    input  wire        iq_in_q,
    input  wire [1:0]  decim_ratio,
    output wire signed [7:0] iq_out_i,
    output wire signed [7:0] iq_out_q,
    output wire              iq_valid
);
    sd_decimator_cic_only u (
        .clk_32m    (clk_32m),
        .clk_16m    (clk_16m),
        .rst_n      (rst_n),
        .iq_in_i    (iq_in_i),
        .iq_in_q    (iq_in_q),
        .decim_ratio(decim_ratio),
        .iq_out_i   (iq_out_i),
        .iq_out_q   (iq_out_q),
        .iq_valid   (iq_valid)
    );
endmodule
