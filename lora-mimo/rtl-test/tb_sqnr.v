`timescale 1ns/100ps
// tb_sqnr.v
// SQNR testbench for sd_decimator.
// Reads pre-computed sigma-delta stimulus from sim/tb_data/stim_i.txt and
// stim_q.txt, drives sd_decimator, writes 8-bit IQ output to
// sim/tb_data/rtl_out.txt for Python SQNR analysis.
//
// Tool: iverilog -g2001 + vvp (iic-osic-tools Docker)
// Run:  see sim/sims/run_sqnr_tb.py

module tb_sqnr;

    // Parameters — must match run_sqnr_tb.py
    parameter N_STIM   = 34816;   // input bits  (544 output samples × R=64)
    parameter DECIM    = 2'd2;    // decim_ratio=2 → R=64, 500 kHz BW

    // -----------------------------------------------------------------------
    // Clocks: clk_16m is an exact divide-by-2 of clk_32m (matches CDC intent)
    // -----------------------------------------------------------------------
    reg clk_32m = 1'b0;
    reg clk_16m = 1'b0;
    always #1 clk_32m = ~clk_32m;                        // 2 ns period
    always @(posedge clk_32m) clk_16m <= ~clk_16m;       // 4 ns period

    reg rst_n = 1'b0;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    reg  iq_in_i = 1'b0;
    reg  iq_in_q = 1'b0;

    wire signed [7:0] iq_out_i;
    wire signed [7:0] iq_out_q;
    wire              iq_valid;

    sd_decimator dut (
        .clk_32m    (clk_32m),
        .clk_16m    (clk_16m),
        .rst_n      (rst_n),
        .iq_in_i    (iq_in_i),
        .iq_in_q    (iq_in_q),
        .decim_ratio(DECIM),
        .iq_out_i   (iq_out_i),
        .iq_out_q   (iq_out_q),
        .iq_valid   (iq_valid)
    );

    // -----------------------------------------------------------------------
    // Stimulus and output storage
    // -----------------------------------------------------------------------
    reg [0:0] stim_i [0:N_STIM-1];
    reg [0:0] stim_q [0:N_STIM-1];

    integer outfile;
    integer n_out;
    integer idx;

    // -----------------------------------------------------------------------
    // Driver
    // -----------------------------------------------------------------------
    initial begin
        $readmemb("sim/tb_data/stim_i.txt", stim_i);
        $readmemb("sim/tb_data/stim_q.txt", stim_q);

        outfile = $fopen("sim/tb_data/rtl_out.txt", "w");
        n_out   = 0;
        idx     = 0;

        // Hold reset for a few clk_32m cycles
        repeat(8) @(posedge clk_32m);
        rst_n = 1'b1;
        @(posedge clk_32m);

        // Feed one bit per clk_32m cycle
        repeat(N_STIM) begin
            iq_in_i = stim_i[idx];
            iq_in_q = stim_q[idx];
            idx = idx + 1;
            @(posedge clk_32m);
        end

        // Drain FIR pipeline (a few output-rate cycles)
        iq_in_i = 1'b0;
        iq_in_q = 1'b0;
        repeat(256) @(posedge clk_32m);

        $fclose(outfile);
        $display("tb_sqnr: %0d output samples written to sim/tb_data/rtl_out.txt", n_out);
        $finish;
    end

    // -----------------------------------------------------------------------
    // Capture valid outputs
    // -----------------------------------------------------------------------
    always @(posedge clk_16m) begin
        if (iq_valid) begin
            $fdisplay(outfile, "%0d %0d", $signed(iq_out_i), $signed(iq_out_q));
            n_out = n_out + 1;
        end
    end

endmodule
