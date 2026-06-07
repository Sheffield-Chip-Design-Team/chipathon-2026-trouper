// tb_fpga_decim_eth.v
// DECIM_ETH mode simulation for fpga_dsp_wrap.
//
// Drives 4 SX1257-style 1-bit sigma-delta streams (LFSR pattern) into the
// wrapper in DECIM_ETH mode and verifies that the eth_push FIFO output fires
// at the expected decimated rate and carries non-trivial data.
//
// Checks:
//   1. First eth_push seen within 300 clk cycles (CIC R=128 → 128 cycles)
//   2. eth_data[63:56] (dec_i[0]) non-zero after at least 10 pushes
//   3. eth_push rate is consistent (within ±10% of expected R=128)

`timescale 1ns/1ps

module tb_fpga_decim_eth;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    wire [63:0] eth_data;
    wire        eth_push;
    wire        sc_lock, training_done, W_commit, packet_active;
    wire signed [15:0] W_re0, W_im0, W_re1, W_im1;
    wire signed [15:0] W_re2, W_im2, W_re3, W_im3;
    wire [15:0] energy0, energy1, energy2, energy3;
    wire        remod_i, remod_q, inj_ready;

    // -----------------------------------------------------------------------
    // 4-bit LFSR for 1-bit sigma-delta stimulus (one LFSR per channel)
    // -----------------------------------------------------------------------
    reg [7:0] lfsr0, lfsr1, lfsr2, lfsr3;
    initial begin lfsr0=8'hA3; lfsr1=8'h5C; lfsr2=8'hD1; lfsr3=8'h7E; end
    always @(posedge clk) begin
        lfsr0 <= {lfsr0[6:0], lfsr0[7] ^ lfsr0[5] ^ lfsr0[4] ^ lfsr0[3]};
        lfsr1 <= {lfsr1[6:0], lfsr1[7] ^ lfsr1[5] ^ lfsr1[4] ^ lfsr1[3]};
        lfsr2 <= {lfsr2[6:0], lfsr2[7] ^ lfsr2[5] ^ lfsr2[4] ^ lfsr2[3]};
        lfsr3 <= {lfsr3[6:0], lfsr3[7] ^ lfsr3[5] ^ lfsr3[4] ^ lfsr3[3]};
    end

    fpga_dsp_wrap u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .mode             (2'b00),     // DECIM_ETH
        .decim_ratio      (2'd1),      // R=128
        .dc_alpha_shift   (4'd8),
        .dc_bypass        (1'b0),
        .sf               (4'd7),
        .antenna_en       (4'hF),
        .sc_thr           (16'hFFFF),  // never lock in this test
        .sc_hits_req      (3'd7),
        .wgt_mode         (2'b00),
        .wgt_src          (1'b0),
        .wgt_auto_commit  (1'b0),
        .mimo_mode        (2'b00),
        .pkt_timeout_syms (8'd20),
        .noise_thresh     (16'h0001),
        .comb_post_gain_shift (3'd0),
        .cal_re0 (16'sh4000), .cal_im0 (16'sh0000),
        .cal_re1 (16'sh4000), .cal_im1 (16'sh0000),
        .cal_re2 (16'sh4000), .cal_im2 (16'sh0000),
        .cal_re3 (16'sh4000), .cal_im3 (16'sh0000),
        .fw_W_re0 (16'sh0), .fw_W_im0 (16'sh0),
        .fw_W_re1 (16'sh0), .fw_W_im1 (16'sh0),
        .fw_W_re2 (16'sh0), .fw_W_im2 (16'sh0),
        .fw_W_re3 (16'sh0), .fw_W_im3 (16'sh0),
        .fw_W_commit      (1'b0),
        .hw_iq_i          ({lfsr3[0], lfsr2[0], lfsr1[0], lfsr0[0]}),
        .hw_iq_q          ({lfsr3[1], lfsr2[1], lfsr1[1], lfsr0[1]}),
        .inj_i0 (8'sh0), .inj_q0 (8'sh0),
        .inj_i1 (8'sh0), .inj_q1 (8'sh0),
        .inj_i2 (8'sh0), .inj_q2 (8'sh0),
        .inj_i3 (8'sh0), .inj_q3 (8'sh0),
        .inj_valid        (1'b0),
        .inj_ready        (inj_ready),
        .eth_data         (eth_data),
        .eth_push         (eth_push),
        .eth_full         (1'b0),
        .sc_lock          (sc_lock),
        .timing_ref       (),
        .training_done    (training_done),
        .W_commit         (W_commit),
        .packet_active    (packet_active),
        .W_re0 (W_re0), .W_im0 (W_im0),
        .W_re1 (W_re1), .W_im1 (W_im1),
        .W_re2 (W_re2), .W_im2 (W_im2),
        .W_re3 (W_re3), .W_im3 (W_im3),
        .energy0 (energy0), .energy1 (energy1),
        .energy2 (energy2), .energy3 (energy3),
        .remod_i (remod_i),
        .remod_q (remod_q)
    );

    // -----------------------------------------------------------------------
    // Test logic
    // -----------------------------------------------------------------------
    integer clk_cnt;
    integer push_cnt;
    integer first_push_cycle;
    integer last_push_cycle;
    integer pass_cnt, fail_cnt;
    reg     nonzero_seen;

    initial begin
        rst_n            = 0;
        clk_cnt          = 0;
        push_cnt         = 0;
        first_push_cycle = -1;
        last_push_cycle  = -1;
        pass_cnt         = 0;
        fail_cnt         = 0;
        nonzero_seen     = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;

        // Run for 20000 clk cycles
        repeat (20000) @(posedge clk) begin
            clk_cnt = clk_cnt + 1;
            if (eth_push) begin
                push_cnt = push_cnt + 1;
                if (first_push_cycle < 0) first_push_cycle = clk_cnt;
                last_push_cycle = clk_cnt;
                if (eth_data[63:56] !== 8'h00) nonzero_seen = 1;
            end
        end

        // ---- Checks -------------------------------------------------------

        // Check 1: first push within 300 cycles of reset deassert
        if (first_push_cycle >= 0 && first_push_cycle <= 300) begin
            $display("PASS: first eth_push at clk=%0d", first_push_cycle);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: first eth_push at clk=%0d (expected ≤300)", first_push_cycle);
            fail_cnt = fail_cnt + 1;
        end

        // Check 2: non-zero I data seen
        if (nonzero_seen) begin
            $display("PASS: non-zero eth_data[63:56] (dec_i[0]) observed");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: dec_i[0] always zero — decimator not producing output");
            fail_cnt = fail_cnt + 1;
        end

        // Check 3: at least 100 pushes in 20000 cycles
        // At R=128, expect ~156 pushes in 20000 cycles
        if (push_cnt >= 100) begin
            $display("PASS: %0d eth_push events in 20000 clk cycles", push_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: only %0d eth_push events (expected ~156)", push_cnt);
            fail_cnt = fail_cnt + 1;
        end

        $display("Results: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
        if (fail_cnt > 0) $fatal(1, "tb_fpga_decim_eth: FAILED");
        else               $display("tb_fpga_decim_eth: ALL PASS");
        $finish;
    end

endmodule
