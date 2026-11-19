`timescale 1ns/1ps
`default_nettype none

// remod_lora.v -- production-only harness for the LoRa symbol-error gate.
//
// Salvaged from rtl-test/tb/remod_compare/remod_compare.v, which instantiated
// canonical sd_remod alongside the experimental sd_remod_ef2 and only ever
// asserted EF2 <= production+1 -- it never gated production's own SER. This
// harness has one DUT: the deployed interpolator + 4th-order CIFF core. The
// cocotb test reconstructs its 1-bit stream through the repo's bit-true
// CIC3/HB1/HB2 decimator + LoRa demodulator and asserts an ABSOLUTE
// symbol-error bound.
module remod_lora (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              en,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire              in_valid,
    output wire              out_i,
    output wire              out_q
);
    sd_remod u_remod (
        .clk_32m (clk),
        .rst_n   (rst_n),
        .en      (en),
        .in_i    (in_i),
        .in_q    (in_q),
        .in_valid(in_valid),
        .out_i   (out_i),
        .out_q   (out_q)
    );
endmodule

`default_nettype wire
