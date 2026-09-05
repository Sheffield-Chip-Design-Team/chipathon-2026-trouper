// tb_sd_remod.v — fast smoke test for sd_remod, NOT the fidelity regression.
//
// This testbench only checks normalised cross-correlation of a decimated
// output against a reference sine (threshold 0.80), and only proves the loop
// hasn't gone completely dead or unity-weight -- it does NOT compute SQNR or
// RMS error despite what an earlier version of this header comment claimed
// ("SQNR ~55dB"). Correlation is a very weak proxy: for uncorrelated additive
// error, correlation 0.80 corresponds to roughly 2.5 dB SNR, and a genuine
// 40 dB SQNR requirement would need correlation around 0.99995 for the metric
// to mean anything close to that. The old x8192 error-scaling bug (fixed
// 2026-09-04, see planning/sd-remod-4th-order-fix-2026-09-04.md) measured
// ~0.99 correlation here -- comfortably "passing" -- while its real SQNR was
// only ~15-20 dB, nowhere near spec. This test also used to change the input
// every 32 MHz clock instead of holding each 500 kS/s sample for 64 clocks
// the way production does; that cadence bug is fixed below, but the
// correlation-only metric is NOT -- rewriting this into a real quantitative
// check is exactly what cocotb/tests/test_remod_sqnr.py now does (actual
// SQNR, RMS error in LSB, and fitted gain, across several frequencies,
// amplitudes, and an amplitude transition). Treat a PASS here as "not
// obviously broken", and cocotb/remod_sqnr as the real regression gate.
//
// Drives a 31.25 kHz sine at -6 dBFS through the CIFF re-modulator, holding
// each baseband sample for OSR=64 clocks (production cadence), CIC-decimates
// the 1-bit output by the same OSR, then checks correlation as described
// above.
//
// Parameters:
//   SIG_PERIOD_BB = 16   (FS_OUT=500 kS/s / 31.25 kHz; period in BASEBAND samples)
//   OSR           = 64   (matches sd_remod's real OSR -- int8 @500kS/s -> 1-bit @32MS/s)
//   N_DECIM       = 512  (512 CIC output samples = 32768 baseband-sample periods)
//   AMP           = 64   (≈ -6 dBFS relative to ±127 FS)
//
// Run with: iverilog -g2012 -o tb_sd_remod tb_sd_remod.v ../rtl/sd_remod.v && ./tb_sd_remod

`timescale 1ns/1ps

module tb_sd_remod;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam integer SIG_PERIOD_BB = 16;  // baseband samples per sine period (500kS/s / 31.25kHz)
    localparam integer OSR        = 64;     // production hold length == CIC decimation ratio
    localparam integer N_DECIM    = 512;    // number of decimated output samples
    localparam integer BURN_IN    = 32;     // discard first N_BURN decimated samples
    localparam integer AMP        = 64;     // input amplitude (< -3 dBFS → 0.504)

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    reg        clk = 0, rst_n = 0, en = 1, in_valid = 0;
    reg signed [7:0] in_i, in_q;
    wire out_i, out_q;

    sd_remod dut (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (in_i),
        .in_q     (in_q),
        .in_valid (in_valid),
        .en       (en),
        .out_i    (out_i),
        .out_q    (out_q)
    );

    // 32 MHz clock: half-period = 15.625 ns
    always #15.625 clk = ~clk;

    // -----------------------------------------------------------------------
    // Sine LUT (one full period at the BASEBAND rate, computed in initial)
    // -----------------------------------------------------------------------
    reg signed [7:0] sine_lut [0:SIG_PERIOD_BB-1];

    // -----------------------------------------------------------------------
    // CIC decimator state and output storage
    // -----------------------------------------------------------------------
    integer cic_acc_i, cic_acc_q;      // signed 32-bit accumulators
    reg signed [15:0] decim_i [0:N_DECIM-1];
    reg signed [15:0] decim_q [0:N_DECIM-1];

    // -----------------------------------------------------------------------
    // Correlation check variables
    // -----------------------------------------------------------------------
    real corr_num, ref_sq, sig_sq, corr_norm;
    real ref_val;
    integer i, k, cycle, decim_idx, pass_count;
    real pi;

    // -----------------------------------------------------------------------
    // Main sequence
    // -----------------------------------------------------------------------
    initial begin
        pi = 3.14159265358979;

        // Build sine LUT
        for (i = 0; i < SIG_PERIOD_BB; i = i + 1)
            sine_lut[i] = $rtoi(AMP * $sin(2.0 * pi * i / SIG_PERIOD_BB));

        // Reset
        rst_n = 0; in_i = 0; in_q = 0; in_valid = 0;
        @(posedge clk); @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1;

        cycle     = 0;
        decim_idx = 0;
        cic_acc_i = 0;
        cic_acc_q = 0;

        // Drive sine and collect decimated output. Each baseband sample is
        // held for exactly OSR=64 clocks (production cadence -- in_valid
        // pulses once, in_i/in_q stay constant for the rest), and since OSR
        // here equals the CIC decimation ratio, every outer iteration
        // produces exactly one decimated sample.
        while (decim_idx < N_DECIM) begin
            @(negedge clk);
            // I channel: sine; Q channel: cosine (90° lead)
            in_i = sine_lut[cycle % SIG_PERIOD_BB];
            in_q = sine_lut[(cycle + SIG_PERIOD_BB/4) % SIG_PERIOD_BB];
            in_valid = 1;

            @(posedge clk);  // latch happens on posedge
            #1;              // wait past posedge for DUT output
            in_valid = 0;

            // CIC-1 accumulate (±1 from 1-bit output)
            cic_acc_i = cic_acc_i + (out_i ? 1 : -1);
            cic_acc_q = cic_acc_q + (out_q ? 1 : -1);

            // Hold in_i/in_q constant (in_valid low) for the remaining
            // OSR-1 clocks of this baseband sample's period.
            for (k = 1; k < OSR; k = k + 1) begin
                @(posedge clk);
                #1;
                cic_acc_i = cic_acc_i + (out_i ? 1 : -1);
                cic_acc_q = cic_acc_q + (out_q ? 1 : -1);
            end
            cycle = cycle + 1;

            // Saturate to int16 for storage (should never clip with AMP=64)
            decim_i[decim_idx] = (cic_acc_i >  32767) ?  32767 :
                                 (cic_acc_i < -32768) ? -32768 :
                                  cic_acc_i[15:0];
            decim_q[decim_idx] = (cic_acc_q >  32767) ?  32767 :
                                 (cic_acc_q < -32768) ? -32768 :
                                  cic_acc_q[15:0];
            cic_acc_i = 0;
            cic_acc_q = 0;
            decim_idx = decim_idx + 1;
        end

        // ---------------------------------------------------------------
        // Self-check: normalised cross-correlation of I channel with
        // reference sine.  Skip BURN_IN samples for integrator settling.
        // ---------------------------------------------------------------
        corr_num = 0.0;
        ref_sq   = 0.0;
        sig_sq   = 0.0;

        for (i = BURN_IN; i < N_DECIM; i = i + 1) begin
            // Reference: sine at decimated rate -- one decimated output sample
            // per baseband input sample (hold length == decimation ratio), so
            // the period in decimated-sample units is just SIG_PERIOD_BB.
            ref_val  = AMP * OSR * $sin(2.0 * pi * i / (1.0 * SIG_PERIOD_BB));
            corr_num = corr_num + $itor($signed(decim_i[i])) * ref_val;
            ref_sq   = ref_sq   + ref_val * ref_val;
            sig_sq   = sig_sq   + $itor($signed(decim_i[i])) * $itor($signed(decim_i[i]));
        end

        if (ref_sq < 1.0 || sig_sq < 1.0) begin
            $display("FAIL: zero-power output — modulator stuck");
            $finish(1);
        end

        corr_norm = corr_num / $sqrt(ref_sq * sig_sq);
        $display("sd_remod sine test: I-channel correlation = %.4f (threshold 0.80)", corr_norm);

        if (corr_norm > 0.80) begin
            $display("PASS: noise shaping correct (CIFF coefficients valid)");
        end else begin
            $display("FAIL: correlation %.4f <= 0.80 — broken noise shaping (check CIFF coefficients)", corr_norm);
            $finish(1);
        end

        $finish;
    end

    // Safety timeout
    initial begin
        #(N_DECIM * OSR * 32 + 10000);
        $display("FAIL: timeout");
        $finish(1);
    end

endmodule
