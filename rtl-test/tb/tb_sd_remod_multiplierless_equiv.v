// tb_sd_remod_multiplierless_equiv.v
//
// Bit-exact equivalence check: sd_remod (general `*` operator) vs
// sd_remod_multiplierless (shift/add rewrite of the same Q8 feed-forward
// cone). Drives both DUTs with IDENTICAL clk/rst/in_i/in_q/in_valid/en and
// asserts out_i/out_q match every cycle post-reset. Not an SQNR/spectral
// check -- a direct bit-for-bit equivalence check, which is the right test
// for a claimed-bit-exact arithmetic rewrite.
//
// Three phases:
//   1. Directed extremes: full-scale +/-127 steps and alternating rails, to
//      hit the saturating-integrator corners hardest.
//   2. Dense random stimulus, in_valid pulsed every cycle (not paced to a
//      real OSR=64 cadence -- irrelevant for a same-input equivalence check,
//      and denser stimulus finds a width/logic bug faster).
//   3. A long random run with in_valid paced realistically (still identical
//      to both DUTs) to also exercise the sat16 integrator dynamics over a
//      more realistic trajectory, not just single-step transitions.
//
// PASS: zero mismatches across all phases. FAIL: any out_i/out_q divergence
// (printed with the sample index and both DUTs' internal state for debug).

`timescale 1ns/1ps
`default_nettype none

module tb_sd_remod_multiplierless_equiv;

    reg clk_32m;
    reg rst_n;
    reg signed [7:0] in_i, in_q;
    reg in_valid;
    reg en;

    wire out_i_ref, out_q_ref;
    wire out_i_mul, out_q_mul;

    sd_remod u_ref (
        .clk_32m  (clk_32m),
        .rst_n    (rst_n),
        .in_i     (in_i),
        .in_q     (in_q),
        .in_valid (in_valid),
        .en       (en),
        .out_i    (out_i_ref),
        .out_q    (out_q_ref)
    );

    sd_remod_multiplierless u_mul (
        .clk_32m  (clk_32m),
        .rst_n    (rst_n),
        .in_i     (in_i),
        .in_q     (in_q),
        .in_valid (in_valid),
        .en       (en),
        .out_i    (out_i_mul),
        .out_q    (out_q_mul)
    );

    always #15.625 clk_32m = ~clk_32m;

    integer mismatches;
    integer sample_idx;
    integer seed;

    task check_outputs;
        begin
            if (out_i_ref !== out_i_mul || out_q_ref !== out_q_mul) begin
                mismatches = mismatches + 1;
                $display("MISMATCH @cycle=%0d: ref(out_i=%b out_q=%b) mul(out_i=%b out_q=%b) in_i=%0d in_q=%0d",
                          sample_idx, out_i_ref, out_q_ref, out_i_mul, out_q_mul, in_i, in_q);
                $display("  ref  s1_i=%0d s2_i=%0d s3_i=%0d s4_i=%0d",
                          u_ref.s1_i, u_ref.s2_i, u_ref.s3_i, u_ref.s4_i);
                $display("  mul  s1_i=%0d s2_i=%0d s3_i=%0d s4_i=%0d",
                          u_mul.s1_i, u_mul.s2_i, u_mul.s3_i, u_mul.s4_i);
            end
            sample_idx = sample_idx + 1;
        end
    endtask

    task drive_sample;
        input signed [7:0] i_val;
        input signed [7:0] q_val;
        begin
            @(posedge clk_32m);
            in_i <= i_val;
            in_q <= q_val;
            in_valid <= 1'b1;
            @(posedge clk_32m);
            in_valid <= 1'b0;
            check_outputs;
        end
    endtask

    integer k;

    initial begin
        clk_32m  = 1'b0;
        rst_n    = 1'b0;
        in_i     = 8'sd0;
        in_q     = 8'sd0;
        in_valid = 1'b0;
        en       = 1'b1;
        mismatches = 0;
        sample_idx = 0;
        seed = 32'hC0FFEE;

        repeat (4) @(posedge clk_32m);
        rst_n = 1'b1;
        repeat (4) @(posedge clk_32m);

        // ---------------------------------------------------------------
        // Phase 1: directed extremes -- hit the saturating-integrator
        // corners and the exact +32768-class overflow region (bounded by
        // the multiplierless header's own derived 25-bit-sum claim).
        // ---------------------------------------------------------------
        for (k = 0; k < 40; k = k + 1)
            drive_sample(8'sd127, 8'sd127);
        for (k = 0; k < 40; k = k + 1)
            drive_sample(-8'sd128, -8'sd128);
        for (k = 0; k < 60; k = k + 1)
            drive_sample((k % 2) ? 8'sd127 : -8'sd128,
                         (k % 2) ? -8'sd128 : 8'sd127);
        for (k = 0; k < 20; k = k + 1)
            drive_sample(8'sd0, 8'sd0);

        // ---------------------------------------------------------------
        // Phase 2: dense random stimulus, in_valid every sample -- widest,
        // fastest-converging search for any arithmetic-equivalence bug.
        // ---------------------------------------------------------------
        for (k = 0; k < 4000; k = k + 1)
            drive_sample($random(seed), $random(seed));

        // ---------------------------------------------------------------
        // Phase 3: realistic OSR=64-paced random run -- same stimulus
        // style, spaced like real usage, to exercise the sat16 integrator
        // trajectory over a longer, more representative run.
        // ---------------------------------------------------------------
        for (k = 0; k < 500; k = k + 1) begin
            @(posedge clk_32m);
            in_i <= $random(seed) % 256;
            in_q <= $random(seed) % 256;
            in_valid <= 1'b1;
            @(posedge clk_32m);
            in_valid <= 1'b0;
            check_outputs;
            repeat (62) begin
                @(posedge clk_32m);
                check_outputs;
            end
        end

        if (mismatches == 0)
            $display("PASS: %0d samples, 0 mismatches -- sd_remod_multiplierless is bit-exact vs sd_remod", sample_idx);
        else
            $display("FAIL: %0d samples, %0d mismatches", sample_idx, mismatches);

        $finish;
    end

endmodule

`default_nettype wire
