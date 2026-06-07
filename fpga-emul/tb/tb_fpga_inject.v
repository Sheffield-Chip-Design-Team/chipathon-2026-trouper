// tb_fpga_inject.v
// INJECT mode simulation for fpga_dsp_wrap.
//
// Injects a 4-branch periodic I-axis signal (alternating ±AMP every sample,
// period=2 so x[n]=x[n-128]) through the full DSP chain and verifies:
//   1. sc_lock asserts within 8000 iq_valid strobes
//   2. training_done asserts within 16000 iq_valid strobes after sc_lock
//   3. W_commit asserts within 200 iq_valid strobes after training_done
//   4. W_re non-zero after W_commit
//
// Uses alternating ±AMP stimulus (zero-mean) so the IIR DC-removal filter
// passes the signal; dc_bypass was removed from dc_removal.

`timescale 1ns/1ps

module tb_fpga_inject;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    // -----------------------------------------------------------------------
    // iq_valid strobe: one pulse every 20 cycles
    // -----------------------------------------------------------------------
    // 32-cycle strobe — training_acc TDM takes 25 clk cycles; must use >25
    // so every iq_valid finds tdm_active=0 and the last window sample is never skipped.
    reg [4:0] strobe_cnt;
    initial strobe_cnt = 0;
    always @(posedge clk)
        if (!rst_n) strobe_cnt <= 0;
        else        strobe_cnt <= (strobe_cnt == 5'd31) ? 5'd0 : strobe_cnt + 5'd1;

    wire iq_valid_w = (strobe_cnt == 5'd31);

    // Alternating sign flips on each iq_valid — period 2 → x[n]=x[n-128]
    reg sign_bit;
    initial sign_bit = 0;
    always @(posedge clk)
        if (!rst_n)          sign_bit <= 0;
        else if (iq_valid_w) sign_bit <= ~sign_bit;

    localparam signed [7:0] AMP = 8'sd50;
    wire signed [7:0] stimulus = sign_bit ? -AMP : AMP;

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    wire [63:0] eth_data;
    wire        eth_push;
    wire        sc_lock;
    wire [31:0] timing_ref;
    wire        training_done;
    wire        W_commit;
    wire        packet_active;
    wire signed [15:0] W_re0, W_im0, W_re1, W_im1;
    wire signed [15:0] W_re2, W_im2, W_re3, W_im3;
    wire [15:0] energy0, energy1, energy2, energy3;
    wire        remod_i, remod_q, inj_ready;

    fpga_dsp_wrap u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .mode             (2'b10),     // INJECT
        .decim_ratio      (2'd1),
        .dc_alpha_shift   (4'd8),
        .dc_bypass        (1'b0),
        .sf               (4'd7),      // SF7: M=128
        .antenna_en       (4'hF),
        .sc_thr           (16'h0600),  // 1536 threshold
        .sc_hits_req      (3'd3),
        .wgt_mode         (2'b11),     // MRC
        .wgt_src          (1'b0),
        .wgt_auto_commit  (1'b1),
        .mimo_mode        (2'b00),
        .pkt_timeout_syms (8'd20),
        .noise_thresh     (16'h0008),
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
        .hw_iq_i          (4'b0),
        .hw_iq_q          (4'b0),
        .inj_i0 (stimulus), .inj_q0 (8'sd0),
        .inj_i1 (stimulus), .inj_q1 (8'sd0),
        .inj_i2 (stimulus), .inj_q2 (8'sd0),
        .inj_i3 (stimulus), .inj_q3 (8'sd0),
        .inj_valid        (iq_valid_w),
        .inj_ready        (inj_ready),
        .eth_data         (eth_data),
        .eth_push         (eth_push),
        .eth_full         (1'b0),
        .sc_lock          (sc_lock),
        .timing_ref       (timing_ref),
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
    // Observation registers (updated in always block, read in initial)
    // -----------------------------------------------------------------------
    integer valid_cnt;
    integer sc_lock_cycle;
    integer td_cycle;
    integer wc_cycle;

    initial begin
        valid_cnt     = 0;
        sc_lock_cycle = -1;
        td_cycle      = -1;
        wc_cycle      = -1;
    end

    always @(posedge clk) begin
        if (iq_valid_w)                              valid_cnt     <= valid_cnt + 1;
        if (sc_lock    && sc_lock_cycle < 0)         sc_lock_cycle <= valid_cnt;
        if (training_done && td_cycle < 0
                          && sc_lock_cycle >= 0)     td_cycle      <= valid_cnt;
        if (W_commit   && wc_cycle < 0)              wc_cycle      <= valid_cnt;
    end

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    integer pass_cnt, fail_cnt;
    integer i;

    initial begin
        rst_n    = 0;
        pass_cnt = 0;
        fail_cnt = 0;

        repeat (10) @(posedge clk);
        rst_n = 1;

        // Wait for W_commit or timeout (700k clk cycles ≈ 21k 32-cycle strobes)
        begin : wait_wcommit
            for (i = 0; i < 700000; i = i + 1) begin
                @(posedge clk);
                if (wc_cycle >= 0) disable wait_wcommit;
            end
        end

        // Extra settling time after W_commit
        repeat (200 * 20) @(posedge clk);

        // ---- Checks -------------------------------------------------------
        if (sc_lock_cycle >= 0 && sc_lock_cycle <= 8000) begin
            $display("PASS: sc_lock at strobe %0d", sc_lock_cycle);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: sc_lock not seen or late (strobe=%0d)", sc_lock_cycle);
            fail_cnt = fail_cnt + 1;
        end

        if (td_cycle >= 0 && sc_lock_cycle >= 0 &&
                (td_cycle - sc_lock_cycle) <= 16000) begin
            $display("PASS: training_done at strobe %0d (delta=%0d)",
                     td_cycle, td_cycle - sc_lock_cycle);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: training_done delta=%0d",
                     (td_cycle < 0 || sc_lock_cycle < 0) ? -1 : td_cycle - sc_lock_cycle);
            fail_cnt = fail_cnt + 1;
        end

        if (wc_cycle >= 0 && td_cycle >= 0 && (wc_cycle - td_cycle) <= 200) begin
            $display("PASS: W_commit at strobe %0d (delta=%0d)",
                     wc_cycle, wc_cycle - td_cycle);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: W_commit delta=%0d",
                     (wc_cycle < 0 || td_cycle < 0) ? -1 : wc_cycle - td_cycle);
            fail_cnt = fail_cnt + 1;
        end

        if (W_re0 !== 16'sh0 || W_re1 !== 16'sh0 ||
            W_re2 !== 16'sh0 || W_re3 !== 16'sh0) begin
            $display("PASS: W_re non-zero (re0=0x%04X re1=0x%04X re2=0x%04X re3=0x%04X)",
                     W_re0, W_re1, W_re2, W_re3);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: all W_re still zero after W_commit");
            fail_cnt = fail_cnt + 1;
        end

        $display("Results: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
        if (fail_cnt > 0) $fatal(1, "tb_fpga_inject: FAILED");
        else               $display("tb_fpga_inject: ALL PASS");
        $finish;
    end

endmodule
