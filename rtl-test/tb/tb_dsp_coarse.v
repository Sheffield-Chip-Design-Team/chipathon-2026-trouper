`timescale 1ns/1ps
// tb_dsp_coarse.v
// Experimental chain testbench:
//   energy_meas_coarse -> noise_floor_est_coarse

module tb_dsp_coarse;

    reg clk, rst_n;
    initial clk = 0;
    always #16 clk = ~clk;

    reg signed [7:0] iq_i_0, iq_i_1, iq_i_2, iq_i_3;
    reg signed [7:0] iq_q_0, iq_q_1, iq_q_2, iq_q_3;
    reg        iq_valid, sc_lock;
    reg [3:0]  sf;

    wire [15:0] energy_0, energy_1, energy_2, energy_3;
    wire [9:0]  noise_metric_0, noise_metric_1, noise_metric_2, noise_metric_3;
    wire        energy_valid, energy_snapshot_valid, noise_metric_valid;

    energy_meas_coarse u_em (
        .clk_32m(clk), .rst_n(rst_n),
        .iq_i_0(iq_i_0), .iq_i_1(iq_i_1), .iq_i_2(iq_i_2), .iq_i_3(iq_i_3),
        .iq_q_0(iq_q_0), .iq_q_1(iq_q_1), .iq_q_2(iq_q_2), .iq_q_3(iq_q_3),
        .iq_valid(iq_valid), .sf(sf), .sc_lock(sc_lock),
        .energy_0(energy_0), .energy_1(energy_1), .energy_2(energy_2), .energy_3(energy_3),
        .noise_metric_0(noise_metric_0), .noise_metric_1(noise_metric_1),
        .noise_metric_2(noise_metric_2), .noise_metric_3(noise_metric_3),
        .energy_valid(energy_valid),
        .energy_snapshot_valid(energy_snapshot_valid),
        .noise_metric_valid(noise_metric_valid)
    );

    reg        noise_sample_en;
    reg [2:0]  noise_alpha_shift;
    reg [15:0] sigma2_sw_0, sigma2_sw_1, sigma2_sw_2, sigma2_sw_3;
    reg        sigma2_commit, sigma2_src, agc_gain_changed;

    wire [15:0] sigma2_hw_0, sigma2_hw_1, sigma2_hw_2, sigma2_hw_3;
    wire [15:0] sigma2_active_0, sigma2_active_1, sigma2_active_2, sigma2_active_3;
    wire        sigma2_valid;
    wire [7:0]  n_updates;

    noise_floor_est_coarse u_nfe (
        .clk_32m(clk), .rst_n(rst_n),
        .noise_metric_0(noise_metric_0), .noise_metric_1(noise_metric_1),
        .noise_metric_2(noise_metric_2), .noise_metric_3(noise_metric_3),
        .noise_sample_en(noise_sample_en), .noise_alpha_shift(noise_alpha_shift),
        .sigma2_sw_0(sigma2_sw_0), .sigma2_sw_1(sigma2_sw_1),
        .sigma2_sw_2(sigma2_sw_2), .sigma2_sw_3(sigma2_sw_3),
        .sigma2_commit(sigma2_commit), .sigma2_src(sigma2_src),
        .agc_gain_changed(agc_gain_changed),
        .sigma2_hw_0(sigma2_hw_0), .sigma2_hw_1(sigma2_hw_1),
        .sigma2_hw_2(sigma2_hw_2), .sigma2_hw_3(sigma2_hw_3),
        .sigma2_active_0(sigma2_active_0), .sigma2_active_1(sigma2_active_1),
        .sigma2_active_2(sigma2_active_2), .sigma2_active_3(sigma2_active_3),
        .sigma2_valid(sigma2_valid), .n_updates(n_updates)
    );

    integer errors;
    integer k;

    task drive_sample;
        begin
            @(posedge clk); #1; iq_valid = 1;
            @(posedge clk); #1; iq_valid = 0;
            repeat(9) @(posedge clk); #1;
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 0;
        iq_valid = 0;
        sc_lock = 0;
        sf = 4'd7;
        iq_i_0 = 0; iq_q_0 = 0;
        iq_i_1 = 0; iq_q_1 = 0;
        iq_i_2 = 0; iq_q_2 = 0;
        iq_i_3 = 0; iq_q_3 = 0;
        noise_sample_en = 0;
        noise_alpha_shift = 3'd4;
        sigma2_sw_0 = 0; sigma2_sw_1 = 0; sigma2_sw_2 = 0; sigma2_sw_3 = 0;
        sigma2_commit = 0;
        sigma2_src = 0;
        agc_gain_changed = 0;

        repeat(4) @(posedge clk); #1;
        rst_n = 1;

        iq_i_0 = 8'd127; iq_q_0 = 8'd0;
        iq_i_1 = 8'd64;  iq_q_1 = 8'd0;
        iq_i_2 = 8'd32;  iq_q_2 = 8'd0;
        iq_i_3 = 8'd10;  iq_q_3 = 8'd0;

        for (k = 0; k < 128; k = k + 1)
            drive_sample();

        wait (noise_metric_valid == 1'b1);
        @(posedge clk); #1;

        if (noise_metric_0 !== 10'd504) begin
            $display("FAIL noise_metric_0: got=%0d exp=504", noise_metric_0); errors = errors + 1;
        end
        if (noise_metric_1 !== 10'd128) begin
            $display("FAIL noise_metric_1: got=%0d exp=128", noise_metric_1); errors = errors + 1;
        end
        if (noise_metric_2 !== 10'd32) begin
            $display("FAIL noise_metric_2: got=%0d exp=32", noise_metric_2); errors = errors + 1;
        end
        if (noise_metric_3 !== 10'd3) begin
            $display("FAIL noise_metric_3: got=%0d exp=3", noise_metric_3); errors = errors + 1;
        end

        @(posedge clk); #1; noise_sample_en = 1;
        @(posedge clk); #1; noise_sample_en = 0;
        repeat(4) @(posedge clk); #1;

        if (sigma2_hw_0 !== 16'd504) begin
            $display("FAIL sigma2_hw_0: got=%0d exp=504", sigma2_hw_0); errors = errors + 1;
        end
        if (sigma2_hw_1 !== 16'd128) begin
            $display("FAIL sigma2_hw_1: got=%0d exp=128", sigma2_hw_1); errors = errors + 1;
        end
        if (sigma2_hw_2 !== 16'd32) begin
            $display("FAIL sigma2_hw_2: got=%0d exp=32", sigma2_hw_2); errors = errors + 1;
        end
        if (sigma2_hw_3 !== 16'd3) begin
            $display("FAIL sigma2_hw_3: got=%0d exp=3", sigma2_hw_3); errors = errors + 1;
        end

        if (!sigma2_valid) begin
            $display("FAIL sigma2_valid not set after coarse seed"); errors = errors + 1;
        end
        if (n_updates !== 8'd1) begin
            $display("FAIL n_updates: got=%0d exp=1", n_updates); errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS tb_dsp_coarse");
        end else begin
            $display("FAIL tb_dsp_coarse errors=%0d", errors);
        end

        $finish;
    end

endmodule
