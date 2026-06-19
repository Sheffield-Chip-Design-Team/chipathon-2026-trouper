// tb_cic_droop_eq.v — self-checking droop-equalizer testbench for sd_decimator_cic_only.
//
// Drives a 1st-order sigma-delta encoded sine through the CIC and measures the
// output amplitude via quadrature cross-correlation.  Tests two frequencies:
//   F1 = 31.25 kHz (mid-band,  CIC-3 droop -0.67 dB, +EQ expected +0.27 dB)
//   F2 = 50 kHz    (near-edge, CIC-3 droop -1.73 dB, +EQ expected +0.22 dB)
//
// PASS thresholds: amplitude ratio (output/input) > 0.97 at both frequencies.
// Without the equalizer, F2 gives 0.82 which would FAIL.
//
// Run: iverilog -g2012 -o tb_cic_droop_eq tb_cic_droop_eq.v ../rtl/sd_decimator_cic_only.v && vvp tb_cic_droop_eq

`timescale 1ns/100ps

module tb_cic_droop_eq;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    // F1: 31.25 kHz — SIG_PERIOD1 = 32M/31.25k = 1024, out_period = 8 samples
    localparam integer SIG_PERIOD1  = 1024;
    localparam integer OUT_PERIOD1  = 8;       // SIG_PERIOD1/OSR

    // F2: 50 kHz — SIG_PERIOD2 = 32M/50k = 640, out_period = 5 samples
    localparam integer SIG_PERIOD2  = 640;
    localparam integer OUT_PERIOD2  = 5;

    localparam integer OSR          = 128;     // decimation ratio R=128
    localparam integer AMP          = 64;      // input amplitude (< -3 dBFS)
    localparam integer BURN_IN      = 64;      // CIC settling (output samples)
    localparam integer N_MEAS       = 512;     // measurement window (output samples)
    // Total: (BURN_IN + N_MEAS) * OSR = 73728 clock cycles per test
    localparam integer N_CYCLES     = (BURN_IN + N_MEAS) * OSR + 32;

    real pi;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    reg  clk_32m = 0, clk_16m = 0, rst_n = 0;
    reg  iq_in_i = 0, iq_in_q = 0;
    wire signed [7:0] iq_out_i, iq_out_q;
    wire iq_valid;

    always #15.625 clk_32m = ~clk_32m;
    always @(posedge clk_32m) clk_16m <= ~clk_16m;

    sd_decimator_cic_only dut (
        .clk_32m    (clk_32m),
        .clk_16m    (clk_16m),
        .rst_n      (rst_n),
        .iq_in_i    (iq_in_i),
        .iq_in_q    (iq_in_q),
        .decim_ratio(2'd1),    // R=128
        .iq_out_i   (iq_out_i),
        .iq_out_q   (iq_out_q),
        .iq_valid   (iq_valid)
    );

    // -----------------------------------------------------------------------
    // Sine LUTs (one full period each)
    // -----------------------------------------------------------------------
    reg signed [7:0] lut1 [0:SIG_PERIOD1-1];
    reg signed [7:0] lut2 [0:SIG_PERIOD2-1];

    // Reference LUTs at output rate (sin and cos for quadrature)
    reg signed [7:0] ref_sin1 [0:OUT_PERIOD1-1];
    reg signed [7:0] ref_cos1 [0:OUT_PERIOD1-1];
    reg signed [7:0] ref_sin2 [0:OUT_PERIOD2-1];
    reg signed [7:0] ref_cos2 [0:OUT_PERIOD2-1];

    // -----------------------------------------------------------------------
    // 1st-order sigma-delta encoder state
    // -----------------------------------------------------------------------
    integer sd_acc;    // error accumulator

    // -----------------------------------------------------------------------
    // Measurement state
    // -----------------------------------------------------------------------
    integer clk_cnt, out_cnt;
    integer lut_idx;

    real corr_sin, corr_cos, corr_mag;
    real ref_power;
    real ratio;
    integer i;

    // -----------------------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------------------
    task reset_dut;
        begin
            rst_n = 0; iq_in_i = 0; iq_in_q = 0;
            repeat(8) @(posedge clk_32m);
            @(negedge clk_32m); rst_n = 1;
        end
    endtask

    // Run a measurement: drive sine from lut[], collect N_MEAS output samples
    // starting after BURN_IN, correlate with ref_sin/cos[period].
    // Returns amplitude ratio via corr_sin, corr_cos, corr_mag.
    task measure_tone;
        input integer period_in;   // lut period (SIG_PERIOD)
        input integer period_out;  // reference period at output rate
        begin : meas
            integer k;
            reg signed [7:0] lut_val;
            reg [0:0] bit_out;
            integer out_skip;
            integer out_meas;

            corr_sin = 0.0; corr_cos = 0.0;
            sd_acc   = 0;
            lut_idx  = 0;
            out_skip = 0;
            out_meas = 0;
            clk_cnt  = 0;

            // reset + re-init
            reset_dut;

            // drive clock cycles
            while (out_meas < N_MEAS) begin
                @(negedge clk_32m);

                // 1st-order sigma-delta: quantise lut[lut_idx]
                lut_val = (period_in == SIG_PERIOD1) ? lut1[lut_idx] : lut2[lut_idx];
                bit_out = ((sd_acc + $signed(lut_val)) >= 0) ? 1'b1 : 1'b0;
                iq_in_i = bit_out;
                iq_in_q = 1'b0;

                @(posedge clk_32m); #1;

                sd_acc  = sd_acc + $signed(lut_val) - (bit_out ? 127 : -127);
                lut_idx = (lut_idx + 1) % period_in;

                // capture valid output
                if (iq_valid) begin
                    if (out_skip < BURN_IN) begin
                        out_skip = out_skip + 1;
                    end else begin
                        // quadrature correlation with reference
                        if (period_out == OUT_PERIOD1) begin
                            corr_sin = corr_sin + $itor($signed(iq_out_i)) *
                                       $itor($signed(ref_sin1[out_meas % OUT_PERIOD1]));
                            corr_cos = corr_cos + $itor($signed(iq_out_i)) *
                                       $itor($signed(ref_cos1[out_meas % OUT_PERIOD1]));
                        end else begin
                            corr_sin = corr_sin + $itor($signed(iq_out_i)) *
                                       $itor($signed(ref_sin2[out_meas % OUT_PERIOD2]));
                            corr_cos = corr_cos + $itor($signed(iq_out_i)) *
                                       $itor($signed(ref_cos2[out_meas % OUT_PERIOD2]));
                        end
                        out_meas = out_meas + 1;
                    end
                end
            end

            // magnitude of complex correlation → amplitude
            corr_mag = $sqrt(corr_sin*corr_sin + corr_cos*corr_cos) / N_MEAS;
        end
    endtask

    // -----------------------------------------------------------------------
    // Main
    // -----------------------------------------------------------------------
    initial begin
        pi = 3.14159265358979;

        // Build input LUTs
        for (i = 0; i < SIG_PERIOD1; i = i+1)
            lut1[i] = $rtoi(AMP * $sin(2.0*pi*i/SIG_PERIOD1));
        for (i = 0; i < SIG_PERIOD2; i = i+1)
            lut2[i] = $rtoi(AMP * $sin(2.0*pi*i/SIG_PERIOD2));

        // Build output-rate reference LUTs (quadrature, amplitude = AMP)
        for (i = 0; i < OUT_PERIOD1; i = i+1) begin
            ref_sin1[i] = $rtoi(AMP * $sin(2.0*pi*i/OUT_PERIOD1));
            ref_cos1[i] = $rtoi(AMP * $cos(2.0*pi*i/OUT_PERIOD1));
        end
        for (i = 0; i < OUT_PERIOD2; i = i+1) begin
            ref_sin2[i] = $rtoi(AMP * $sin(2.0*pi*i/OUT_PERIOD2));
            ref_cos2[i] = $rtoi(AMP * $cos(2.0*pi*i/OUT_PERIOD2));
        end

        // Reference power = AMP^2/2 (RMS of a sine at amplitude AMP)
        ref_power = 1.0 * AMP * AMP / 2.0;

        // -------------------------------------------------------------------
        // Test 1: 31.25 kHz (CIC-3 droop -0.67 dB; with EQ expect +0.27 dB)
        // -------------------------------------------------------------------
        measure_tone(SIG_PERIOD1, OUT_PERIOD1);
        // amplitude ratio = measured_amplitude / AMP (input amplitude)
        ratio = corr_mag / AMP;
        $display("31.25 kHz: amplitude_ratio=%.4f  (%+.2f dB)  [expect +0.27 dB with EQ]",
                 ratio, 20.0*$ln(ratio)/$ln(10.0));
        if (ratio < 0.97) begin
            $display("FAIL 31.25 kHz: ratio %.4f < 0.97 (droop not corrected)", ratio);
            $finish(1);
        end

        // -------------------------------------------------------------------
        // Test 2: 50 kHz (CIC-3 droop -1.73 dB; with EQ expect +0.22 dB)
        // -------------------------------------------------------------------
        measure_tone(SIG_PERIOD2, OUT_PERIOD2);
        ratio = corr_mag / AMP;
        $display("50.00 kHz: amplitude_ratio=%.4f  (%+.2f dB)  [expect +0.22 dB with EQ]",
                 ratio, 20.0*$ln(ratio)/$ln(10.0));
        if (ratio < 0.97) begin
            $display("FAIL 50 kHz: ratio %.4f < 0.97 (droop not corrected)", ratio);
            $finish(1);
        end

        $display("PASS: droop equalizer verified at 31.25 kHz and 50 kHz");
        $finish;
    end

    // Safety timeout
    initial begin
        #(N_CYCLES * 32 * 4);
        $display("FAIL: timeout");
        $finish(1);
    end

endmodule
