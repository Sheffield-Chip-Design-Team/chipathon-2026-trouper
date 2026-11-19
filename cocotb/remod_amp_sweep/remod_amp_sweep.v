`timescale 1ns/1ps
`default_nettype none

// remod_amp_sweep.v -- thin direct-instantiation wrapper for canonical
// sd_remod.v (same pattern as cocotb/remod_sqnr, cocotb/remod_flatness). The
// cocotb test sweeps input amplitude from ~-20 dBFS to just under the -3 dBFS
// wall at several in-band frequencies and checks the SQNR-vs-amplitude curve
// for a cliff -- the stability-margin failure the 5th-order coefficient
// searches repeatedly hit (planning/sd-remod-4th-order-fix-2026-09-04.md sec.6).
module remod_amp_sweep (
    input  wire              clk,
    input  wire              rst_n,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire              in_valid,
    input  wire              en,
    output wire              out_i,
    output wire              out_q
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

`default_nettype wire
