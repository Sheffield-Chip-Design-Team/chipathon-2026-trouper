// remod_flatness.v -- thin direct-instantiation wrapper for the canonical
// sd_remod.v, mirroring cocotb/remod_sqnr/remod_sqnr.v: expose the DUT's own
// ports untouched so the cocotb test drives/observes real RTL.
//
// This suite is the salvage of rtl-test/tb/remod_interp2x/test_sd_remod_interp2x.py
// (an uncommitted, unwired, 2026-09-05 investigation TB whose harness compared
// canonical sd_remod against the now-superseded experimental sd_remod_interp2x
// module -- a comparison that no longer exists after the 2026-09-05 promotion,
// commit 7f64c88). Here there is one DUT: the deployed interpolator + 4th-order
// CIFF multiplierless core. The test measures swept-frequency STF gain
// (passband ripple) over the LoRa in-band range, not a handful of tone points.
`timescale 1ns/1ps
`default_nettype none

module remod_flatness (
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
