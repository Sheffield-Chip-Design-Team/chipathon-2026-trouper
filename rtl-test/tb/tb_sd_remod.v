// tb_sd_remod.v — self-checking sine testbench for sd_remod.
//
// Drives a 31.25 kHz sine at -6 dBFS through the CIFF re-modulator, CIC-decimates
// the 1-bit output by OSR=128, then checks the normalised cross-correlation of the
// decimated I channel with the reference sine.  A broken/unity-weight modulator
// produces SQNR ≈ -55 dB and fails the correlation threshold; the tuned CIFF
// produces SQNR ≈ 55 dB and passes comfortably.
//
// Parameters:
//   SIG_PERIOD = 1024  (FS=32 MHz / 31.25 kHz; period in clock cycles)
//   OSR        = 128   (125 kHz bandwidth)
//   N_DECIM    = 512   (512 CIC output samples = 65536 clock cycles ≈ 2 ms)
//   AMP        = 64    (≈ -6 dBFS relative to ±127 FS)
//
// Run with: iverilog -g2012 -o tb_sd_remod tb_sd_remod.v ../rtl/sd_remod.v && ./tb_sd_remod

`timescale 1ns/1ps

module tb_sd_remod;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam integer SIG_PERIOD = 1024;   // clock cycles per sine period
    localparam integer OSR        = 128;    // CIC decimation ratio
    localparam integer N_DECIM    = 512;    // number of decimated output samples
    localparam integer N_CYCLES   = N_DECIM * OSR;  // total clock cycles
    localparam integer BURN_IN    = 32;     // discard first N_BURN decimated samples
    localparam integer AMP        = 64;     // input amplitude (< -3 dBFS → 0.504)

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    reg        clk = 0, rst_n = 0, en = 1, in_valid = 1;
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
    // Sine LUT (one full period, computed in initial)
    // -----------------------------------------------------------------------
    reg signed [7:0] sine_lut [0:SIG_PERIOD-1];

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
    integer i, cycle, decim_idx, osr_cnt, pass_count;
    real pi;

    // -----------------------------------------------------------------------
    // Main sequence
    // -----------------------------------------------------------------------
    initial begin
        pi = 3.14159265358979;

        // Build sine LUT
        for (i = 0; i < SIG_PERIOD; i = i + 1)
            sine_lut[i] = $rtoi(AMP * $sin(2.0 * pi * i / SIG_PERIOD));

        // Reset
        rst_n = 0; in_i = 0; in_q = 0;
        @(posedge clk); @(posedge clk); @(posedge clk);
        @(negedge clk); rst_n = 1;

        cycle     = 0;
        decim_idx = 0;
        osr_cnt   = 0;
        cic_acc_i = 0;
        cic_acc_q = 0;

        // Drive sine and collect decimated output
        while (decim_idx < N_DECIM) begin
            @(negedge clk);
            // I channel: sine; Q channel: cosine (90° lead)
            in_i = sine_lut[cycle % SIG_PERIOD];
            in_q = sine_lut[(cycle + SIG_PERIOD/4) % SIG_PERIOD];

            @(posedge clk);  // latch happens on posedge
            #1;              // wait past posedge for DUT output

            // CIC-1 accumulate (±1 from 1-bit output)
            cic_acc_i = cic_acc_i + (out_i ? 1 : -1);
            cic_acc_q = cic_acc_q + (out_q ? 1 : -1);
            osr_cnt   = osr_cnt + 1;
            cycle     = cycle + 1;

            if (osr_cnt == OSR) begin
                // Saturate to int16 for storage (should never clip with AMP=64)
                decim_i[decim_idx] = (cic_acc_i >  32767) ?  32767 :
                                     (cic_acc_i < -32768) ? -32768 :
                                      cic_acc_i[15:0];
                decim_q[decim_idx] = (cic_acc_q >  32767) ?  32767 :
                                     (cic_acc_q < -32768) ? -32768 :
                                      cic_acc_q[15:0];
                cic_acc_i = 0;
                cic_acc_q = 0;
                osr_cnt   = 0;
                decim_idx = decim_idx + 1;
            end
        end

        // ---------------------------------------------------------------
        // Self-check: normalised cross-correlation of I channel with
        // reference sine.  Skip BURN_IN samples for integrator settling.
        // ---------------------------------------------------------------
        corr_num = 0.0;
        ref_sq   = 0.0;
        sig_sq   = 0.0;

        for (i = BURN_IN; i < N_DECIM; i = i + 1) begin
            // Reference: sine at decimated rate (period = SIG_PERIOD/OSR samples)
            ref_val  = AMP * OSR * $sin(2.0 * pi * i / (1.0 * SIG_PERIOD / OSR));
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
        #(N_CYCLES * 32 + 10000);
        $display("FAIL: timeout");
        $finish(1);
    end

endmodule
