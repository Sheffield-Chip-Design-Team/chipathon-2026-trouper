`timescale 1ns/100ps
// tb_sqnr_4ch.v
// 4-channel SQNR testbench for sd_decimator_top.
// All 4 channels driven with the same sigma-delta stimulus (stim_i/q.txt).
// Writes ch 0 output to sim/tb_data/rtl_out.txt (for existing Python analysis).
// Writes all 4 channels to sim/tb_data/rtl_out_4ch.txt for multi-ch check.

module tb_sqnr_4ch;

    parameter N_STIM = 34816;
    parameter DECIM  = 2'd2;   // R=64

    reg clk_32m = 1'b0;
    reg clk_16m = 1'b0;
    always #1 clk_32m = ~clk_32m;
    always @(posedge clk_32m) clk_16m <= ~clk_16m;

    reg rst_n = 1'b0;

    // All 4 channels driven with the same stimulus
    reg  [3:0] iq_in_i = 4'b0000;
    reg  [3:0] iq_in_q = 4'b0000;

    wire signed [7:0] iq_out_i_0, iq_out_i_1, iq_out_i_2, iq_out_i_3;
    wire signed [7:0] iq_out_q_0, iq_out_q_1, iq_out_q_2, iq_out_q_3;
    wire              iq_valid;

    sd_decimator_top dut (
        .clk_32m    (clk_32m),
        .clk_16m    (clk_16m),
        .rst_n      (rst_n),
        .iq_in_i    (iq_in_i),
        .iq_in_q    (iq_in_q),
        .decim_ratio(DECIM),
        .iq_out_i_0 (iq_out_i_0), .iq_out_i_1 (iq_out_i_1),
        .iq_out_i_2 (iq_out_i_2), .iq_out_i_3 (iq_out_i_3),
        .iq_out_q_0 (iq_out_q_0), .iq_out_q_1 (iq_out_q_1),
        .iq_out_q_2 (iq_out_q_2), .iq_out_q_3 (iq_out_q_3),
        .iq_valid   (iq_valid)
    );

    reg [0:0] stim_i [0:N_STIM-1];
    reg [0:0] stim_q [0:N_STIM-1];

    integer outfile, outfile_4ch;
    integer n_out, idx;
    reg [0:0] bit_i, bit_q;

    initial begin
        $readmemb("sim/tb_data/stim_i.txt", stim_i);
        $readmemb("sim/tb_data/stim_q.txt", stim_q);

        outfile    = $fopen("sim/tb_data/rtl_out.txt",     "w");
        outfile_4ch = $fopen("sim/tb_data/rtl_out_4ch.txt", "w");
        n_out = 0; idx = 0;

        repeat(8) @(posedge clk_32m);
        rst_n = 1'b1;
        @(posedge clk_32m);

        repeat(N_STIM) begin
            bit_i = stim_i[idx]; bit_q = stim_q[idx]; idx = idx + 1;
            iq_in_i = {bit_i[0], bit_i[0], bit_i[0], bit_i[0]};
            iq_in_q = {bit_q[0], bit_q[0], bit_q[0], bit_q[0]};
            @(posedge clk_32m);
        end

        iq_in_i = 4'b0; iq_in_q = 4'b0;
        repeat(256) @(posedge clk_32m);

        $fclose(outfile);
        $fclose(outfile_4ch);
        $display("tb_sqnr_4ch: %0d output samples written", n_out);
        $finish;
    end

    always @(posedge clk_16m) begin
        if (iq_valid) begin
            // ch 0 → existing rtl_out.txt (for single-ch Python analysis)
            $fdisplay(outfile, "%0d %0d",
                $signed(iq_out_i_0), $signed(iq_out_q_0));
            // all 4 channels → 4ch file: I0 Q0 I1 Q1 I2 Q2 I3 Q3
            $fdisplay(outfile_4ch, "%0d %0d %0d %0d %0d %0d %0d %0d",
                $signed(iq_out_i_0), $signed(iq_out_q_0),
                $signed(iq_out_i_1), $signed(iq_out_q_1),
                $signed(iq_out_i_2), $signed(iq_out_q_2),
                $signed(iq_out_i_3), $signed(iq_out_q_3));
            n_out = n_out + 1;
        end
    end

endmodule
