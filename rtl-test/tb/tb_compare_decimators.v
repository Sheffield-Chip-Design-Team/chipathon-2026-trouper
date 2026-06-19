// tb_compare_decimators.v
// Drive both sd_decimator_cic_only and sd_decimator_cic_tdm8 with the same
// sigma-delta bitstream, dump IQ output samples to stdout as CSV.
//
// Output format (stdout):
//   # FREQ <hz>
//   CIC,<i>,<q>       — one line per output sample from sd_decimator_cic_only
//   TDM,<i>,<q>       — one line per output sample from sd_decimator_cic_tdm8 ch0
//   # END
//
// Pipe into sim/tests/compare_decimators.py for the DFT amplitude table.
//
// Build:
//   iverilog -g2012 -o tb_compare_decimators.vvp \
//       tb/tb_compare_decimators.v \
//       rtl/sd_decimator_cic_only.v \
//       rtl/sd_decimator_cic_tdm8.v
//   vvp tb_compare_decimators.vvp

`timescale 1ns/100ps

module tb_compare_decimators;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam integer OSR       = 128;   // R=128 for both DUTs
    localparam integer BURN_IN   = 128;   // output samples to skip (CIC settling)
    localparam integer N_MEAS    = 1024;  // output samples to capture per tone
    localparam integer AMP       = 64;    // sigma-delta input amplitude (< -3 dBFS)

    // Test tones (period in 32 MHz clocks):
    //   31.25 kHz → period = 32e6/31.25e3 = 1024
    //   50.00 kHz → period = 32e6/50e3    = 640
    //   62.50 kHz → period = 32e6/62.5e3  = 512
    localparam integer N_FREQS = 3;

    real    pi;
    integer freq_list  [0:N_FREQS-1];
    integer period_list[0:N_FREQS-1];

    // -----------------------------------------------------------------------
    // Clocks / reset
    // -----------------------------------------------------------------------
    reg clk_32m = 0;
    reg clk_16m = 0;
    reg rst_n   = 0;

    always #15.625 clk_32m = ~clk_32m;
    always @(posedge clk_32m) clk_16m <= ~clk_16m;

    // -----------------------------------------------------------------------
    // Shared sigma-delta input
    // -----------------------------------------------------------------------
    reg sd_bit = 0;   // driven by encoder task

    // -----------------------------------------------------------------------
    // DUT 1: sd_decimator_cic_only (single channel)
    // -----------------------------------------------------------------------
    wire signed [7:0] cic_out_i, cic_out_q;
    wire cic_valid;

    sd_decimator_cic_only dut_cic (
        .clk_32m    (clk_32m),
        .clk_16m    (clk_16m),
        .rst_n      (rst_n),
        .iq_in_i    (sd_bit),
        .iq_in_q    (1'b0),
        .decim_ratio(2'd1),       // R=128
        .iq_out_i   (cic_out_i),
        .iq_out_q   (cic_out_q),
        .iq_valid   (cic_valid)
    );

    // -----------------------------------------------------------------------
    // DUT 2: sd_decimator_cic_tdm8 (4 channels; drive channel 0 only)
    // -----------------------------------------------------------------------
    wire [31:0] tdm_raw_i, tdm_raw_q;
    wire [3:0]  tdm_valid;

    sd_decimator_cic_tdm8 dut_tdm (
        .clk_32m  (clk_32m),
        .rst_n    (rst_n),
        .iq_in_i  ({3'b0, sd_bit}),  // channel 0 gets the tone; 1-3 = 0
        .iq_in_q  (4'b0),
        .iq_out_i (tdm_raw_i),
        .iq_out_q (tdm_raw_q),
        .iq_valid (tdm_valid)
    );

    wire signed [7:0] tdm_out_i = $signed(tdm_raw_i[7:0]);
    wire signed [7:0] tdm_out_q = $signed(tdm_raw_q[7:0]);

    // -----------------------------------------------------------------------
    // Rising-edge detect for cic_valid (it pulses for 2 cycles)
    // -----------------------------------------------------------------------
    reg cic_valid_r;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) cic_valid_r <= 1'b0;
        else        cic_valid_r <= cic_valid;

    wire cic_valid_rise = cic_valid && !cic_valid_r;
    // tdm_valid[0] is already a single-cycle pulse — use directly.

    // -----------------------------------------------------------------------
    // Input LUTs
    // -----------------------------------------------------------------------
    reg signed [7:0] lut [0:1023];   // max period = 1024 samples

    // -----------------------------------------------------------------------
    // Tasks
    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst_n = 0; sd_bit = 0;
            repeat(8) @(posedge clk_32m);
            @(negedge clk_32m); rst_n = 1;
        end
    endtask

    // run_tone: drive a single test frequency, dump N_MEAS samples from each DUT.
    task run_tone;
        input integer sig_period;  // LUT period in 32 MHz clocks
        input integer freq_hz;
        begin : tone_blk
            integer sd_acc;
            integer lut_idx;
            integer cic_skip, cic_meas;
            integer tdm_skip, tdm_meas;
            integer lv;    // lut value (integer)
            reg     bit_out;

            $display("# FREQ %0d", freq_hz);
            do_reset;

            sd_acc   = 0;
            lut_idx  = 0;
            cic_skip = 0; cic_meas = 0;
            tdm_skip = 0; tdm_meas = 0;

            while (cic_meas < N_MEAS || tdm_meas < N_MEAS) begin
                @(negedge clk_32m);

                // 1st-order sigma-delta encoder
                lv      = lut[lut_idx % sig_period];
                bit_out = ((sd_acc + lv) >= 0) ? 1'b1 : 1'b0;
                sd_bit  = bit_out;

                @(posedge clk_32m); #1;

                sd_acc  = sd_acc + lv - (bit_out ? 127 : -127);
                lut_idx = lut_idx + 1;

                // capture CIC_ONLY on rising edge
                if (cic_valid_rise) begin
                    if (cic_skip < BURN_IN) begin
                        cic_skip = cic_skip + 1;
                    end else if (cic_meas < N_MEAS) begin
                        $display("CIC,%0d,%0d",
                                 $signed(cic_out_i), $signed(cic_out_q));
                        cic_meas = cic_meas + 1;
                    end
                end

                // capture TDM8 ch0 (single-cycle valid)
                if (tdm_valid[0]) begin
                    if (tdm_skip < BURN_IN) begin
                        tdm_skip = tdm_skip + 1;
                    end else if (tdm_meas < N_MEAS) begin
                        $display("TDM,%0d,%0d",
                                 $signed(tdm_out_i), $signed(tdm_out_q));
                        tdm_meas = tdm_meas + 1;
                    end
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main
    // -----------------------------------------------------------------------
    integer i, f;

    initial begin
        pi = 3.14159265358979;

        // Frequency table
        freq_list[0]   = 31250;  period_list[0] = 1024;
        freq_list[1]   = 50000;  period_list[1] = 640;
        freq_list[2]   = 62500;  period_list[2] = 512;

        // Build one combined LUT (max 1024 entries, reused per tone)
        // The appropriate period is passed to run_tone as sig_period.
        for (f = 0; f < N_FREQS; f = f + 1) begin
            for (i = 0; i < period_list[f]; i = i + 1)
                lut[i] = $rtoi(AMP * $sin(2.0 * pi * i / period_list[f]));
            run_tone(period_list[f], freq_list[f]);
        end

        $display("# END");
        $finish;
    end

    // Safety timeout: 3 tones × (BURN_IN+N_MEAS) × OSR × 2 (margin)
    initial begin
        #(3 * (BURN_IN + N_MEAS) * OSR * 2 * 32);
        $display("FAIL: timeout");
        $finish(1);
    end

endmodule
