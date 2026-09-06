// remod_sqnr.v -- thin direct-instantiation wrapper for sd_remod.v, mirroring
// cocotb/comb_remod_transfer's pattern: expose the DUT's own ports untouched
// so the cocotb test drives/observes real RTL, not a Python behavioral model.
module remod_sqnr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire        in_valid,
    input  wire        en,
    output wire         out_i,
    output wire         out_q
);
    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (in_i),
        .in_q     (in_q),
        .in_valid (in_valid),
        .en       (en),
        .out_i    (out_i),
        .out_q    (out_q)
    );
endmodule
