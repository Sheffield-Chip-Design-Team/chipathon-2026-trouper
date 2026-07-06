// tb_dsp_chain.v — End-to-end DSP chain testbench matching trouper_top wiring
//
// Signal flow (matches trouper_top):
//   raw_i/q → dc_removal → [dcr_i/q + dcr_valid]
//              ↓ dcr feeds:
//              psram_buf_ctrl (behavioral: 128-deep delay, branch 0 only)
//                  → psram_cur_i0/q0, psram_del_i0/q0, psram_del_valid
//              sc_detector (cur/del from psram behavioral model)
//              training_acc (all 4 branches, dcr output)
//              mrc_combiner (dcr output — no PSRAM replay in this testbench)
//   [fw compute: pgs + weights] → mrc_combiner → sd_remod
//
// weight_gen RTL is NOT instantiated — firmware path only.
//
// Stimulus: complex sinusoid, period=128 samples (SF7 M), all 4 branches identical
//   so x[n+128]=x[n] exactly → perfect Schmidl-Cox correlation peak.
//   Zero DC → passes through dc_removal cleanly after ~16-sample transient.
//
// Tests (self-checking):
//   1. sc_lock      fires <= 20000 cycles
//   2. training_done fires <= 60000 cycles after sc_lock
//   3. fw_W_commit  fires <= 50 cycles after training_done; fw_W_re0 != 0
//   3b. combiner output amplitude matches pgs rule within ±4 counts
//   4. y_valid      fires <= 50 cycles after fw_W_commit
//   5. sd_remod latches the first MRC sample and shows output activity

`timescale 1ns/1ps

module tb_dsp_chain;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    // -----------------------------------------------------------------------
    // Sinusoidal stimulus table: period=128 samples (= M for SF7)
    // Precomputed so x[n+128]=x[n] exactly → perfect SC autocorrelation.
    // Zero-mean → passes through dc_removal without attenuation.
    // -----------------------------------------------------------------------
    real  pi_r;
    reg signed [7:0] stim_i_tbl [0:127];
    reg signed [7:0] stim_q_tbl [0:127];
    integer si;
    initial begin
        pi_r = 3.14159265358979;
        for (si = 0; si < 128; si = si + 1) begin
            stim_i_tbl[si] = $rtoi(40.0 * $cos(2.0 * pi_r * si / 128.0));
            stim_q_tbl[si] = $rtoi(40.0 * $sin(2.0 * pi_r * si / 128.0));
        end
    end

    reg [6:0] stim_ptr;   // 7-bit → wraps at 128 automatically

    // raw_i/q are combinational from table (so dc_removal samples on iq_valid cycle)
    wire signed [7:0] raw_i0 = stim_i_tbl[stim_ptr];
    wire signed [7:0] raw_q0 = stim_q_tbl[stim_ptr];
    wire signed [7:0] raw_i1 = stim_i_tbl[stim_ptr];
    wire signed [7:0] raw_q1 = stim_q_tbl[stim_ptr];
    wire signed [7:0] raw_i2 = stim_i_tbl[stim_ptr];
    wire signed [7:0] raw_q2 = stim_q_tbl[stim_ptr];
    wire signed [7:0] raw_i3 = stim_i_tbl[stim_ptr];
    wire signed [7:0] raw_q3 = stim_q_tbl[stim_ptr];

    // iq_valid strobe: 1 pulse every 40 cycles
    // (training_acc TDM needs 32 sub-cycles; mrc_combiner needs 10; 40-cycle gap fits both)
    reg [5:0] strobe_cnt;
    reg       iq_valid;

    always @(posedge clk) begin
        if (!rst_n) begin
            strobe_cnt <= 6'd0;
            iq_valid   <= 1'b0;
            stim_ptr   <= 7'd0;
        end else begin
            if (strobe_cnt == 6'd39) begin
                strobe_cnt <= 6'd0;
                iq_valid   <= 1'b1;
                stim_ptr   <= stim_ptr + 7'd1;  // advance table index
            end else begin
                strobe_cnt <= strobe_cnt + 6'd1;
                iq_valid   <= 1'b0;
            end
        end
    end

    // Forward declarations needed by sc_detector and delay buffer
    wire        sc_lock;
    wire [31:0] timing_ref;

    // -----------------------------------------------------------------------
    // Stage 2: DC Removal — enabled (matches trouper_top wiring)
    // -----------------------------------------------------------------------
    wire signed [7:0] dcr_i0, dcr_i1, dcr_i2, dcr_i3;
    wire signed [7:0] dcr_q0, dcr_q1, dcr_q2, dcr_q3;
    wire              dcr_valid;

    dc_removal u_dcr (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .sample_i0 (raw_i0), .sample_i1 (raw_i1),
        .sample_i2 (raw_i2), .sample_i3 (raw_i3),
        .sample_q0 (raw_q0), .sample_q1 (raw_q1),
        .sample_q2 (raw_q2), .sample_q3 (raw_q3),
        .sample_valid     (iq_valid),
        .sample_out_i0 (dcr_i0), .sample_out_i1 (dcr_i1),
        .sample_out_i2 (dcr_i2), .sample_out_i3 (dcr_i3),
        .sample_out_q0 (dcr_q0), .sample_out_q1 (dcr_q1),
        .sample_out_q2 (dcr_q2), .sample_out_q3 (dcr_q3),
        .sample_out_valid (dcr_valid)
    );

    // -----------------------------------------------------------------------
    // Stage 3a: Behavioral PSRAM delay buffer (replaces psram_buf_ctrl)
    // Provides psram_cur_i0/q0 and psram_del_i0/q0 for sc_detector.
    // Depth = 128 (SF7: M=128). Branch 0 only (matches sc_detector NR=1).
    // -----------------------------------------------------------------------
    reg signed [7:0] delay_i0 [0:127];
    reg signed [7:0] delay_q0 [0:127];
    reg [6:0]        delay_wr_ptr;     // 7-bit → natural mod-128 wrap
    reg              delay_buf_filled;
    reg              psram_del_valid_r;
    reg signed [7:0] psram_del_i0_r, psram_del_q0_r;

    integer di;
    initial begin
        delay_wr_ptr     = 7'd0;
        delay_buf_filled = 1'b0;
        psram_del_valid_r = 1'b0;
        psram_del_i0_r   = 8'sd0;
        psram_del_q0_r   = 8'sd0;
        for (di = 0; di < 128; di = di + 1) begin
            delay_i0[di] = 8'sd0;
            delay_q0[di] = 8'sd0;
        end
    end

    // cur: direct wires to dc_removal output (same-cycle availability)
    wire signed [7:0] psram_cur_i0 = dcr_i0;
    wire signed [7:0] psram_cur_q0 = dcr_q0;
    wire signed [7:0] psram_del_i0 = psram_del_i0_r;
    wire signed [7:0] psram_del_q0 = psram_del_q0_r;
    wire              psram_del_valid = psram_del_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delay_wr_ptr      <= 7'd0;
            delay_buf_filled  <= 1'b0;
            psram_del_valid_r <= 1'b0;
            psram_del_i0_r    <= 8'sd0;
            psram_del_q0_r    <= 8'sd0;
        end else if (dcr_valid) begin
            // Read before write (NB assigns): captures sample from 128 strobes ago
            psram_del_i0_r    <= delay_i0[delay_wr_ptr];
            psram_del_q0_r    <= delay_q0[delay_wr_ptr];
            // Write current sample into circular buffer slot
            delay_i0[delay_wr_ptr] <= dcr_i0;
            delay_q0[delay_wr_ptr] <= dcr_q0;
            delay_wr_ptr <= delay_wr_ptr + 7'd1;  // wraps at 128
            if (!delay_buf_filled && delay_wr_ptr == 7'd127)
                delay_buf_filled <= 1'b1;
            psram_del_valid_r <= delay_buf_filled;
        end else begin
            psram_del_valid_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // Stage 3b: Schmidl-Cox preamble detector
    // sc_thr=2048 (~50% normalised metric): fires reliably for A=40 sine.
    // -----------------------------------------------------------------------
    wire [15:0] sc_stat;
    wire signed [31:0] c_i0, c_q0;

    sc_detector u_sc (
        .clk            (clk),
        .rst_n          (rst_n),
        .iq_valid       (dcr_valid),
        .cur_i0         (psram_cur_i0),
        .cur_q0         (psram_cur_q0),
        .del_i0         (psram_del_i0),
        .del_q0         (psram_del_q0),
        .delayed_valid  (psram_del_valid),
        .sf             (4'd7),
        .sc_thr         (16'd2048),
        .sc_hits_req    (2'd1),
        .sc_clr         (1'b0),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .c_i0           (c_i0), .c_q0 (c_q0),
        .sc_stat        (sc_stat),
        .sc_hit_dbg     (),
        .sc_hit_hold    (),
        .sc_hit_count_dbg (),
        .sc_first_hit_dbg (),
        .sc_lock_sample_dbg ()
    );

    // -----------------------------------------------------------------------
    // Stage 4: Training accumulator (all-pairs cross-correlator)
    // Inputs: dcr outputs (matches trouper_top)
    // -----------------------------------------------------------------------
    wire signed [31:0] Zpair_i0, Zpair_q0;
    wire signed [31:0] Zpair_i1, Zpair_q1;
    wire signed [31:0] Zpair_i2, Zpair_q2;
    wire signed [31:0] Zpair_i3, Zpair_q3;
    wire signed [31:0] Zpair_i4, Zpair_q4;
    wire signed [31:0] Zpair_i5, Zpair_q5;
    wire [31:0] Zdiag_0, Zdiag_1, Zdiag_2, Zdiag_3;
    wire        training_done;
    wire [15:0] n_acc;

    training_acc u_tacc (
        .clk            (clk),
        .rst_n          (rst_n),
        .iq_valid       (dcr_valid),
        .raw_i0         (dcr_i0), .raw_i1 (dcr_i1),
        .raw_i2         (dcr_i2), .raw_i3 (dcr_i3),
        .raw_q0         (dcr_q0), .raw_q1 (dcr_q1),
        .raw_q2         (dcr_q2), .raw_q3 (dcr_q3),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .sf             (4'd7),
        .noise_trig     (1'b0),
        .Zpair_i0       (Zpair_i0), .Zpair_q0 (Zpair_q0),
        .Zpair_i1       (Zpair_i1), .Zpair_q1 (Zpair_q1),
        .Zpair_i2       (Zpair_i2), .Zpair_q2 (Zpair_q2),
        .Zpair_i3       (Zpair_i3), .Zpair_q3 (Zpair_q3),
        .Zpair_i4       (Zpair_i4), .Zpair_q4 (Zpair_q4),
        .Zpair_i5       (Zpair_i5), .Zpair_q5 (Zpair_q5),
        .Zdiag_0        (Zdiag_0),  .Zdiag_1  (Zdiag_1),
        .Zdiag_2        (Zdiag_2),  .Zdiag_3  (Zdiag_3),
        .training_done  (training_done),
        .n_acc          (n_acc),
        .training_armed ()
    );

    // -----------------------------------------------------------------------
    // Stub signals for removed noise_est / energy paths (tests 6/7 are stubs)
    // -----------------------------------------------------------------------
    wire        energy_valid = 1'b0;
    wire        sigma2_valid = 1'b0;
    wire [9:0]  noise_metric_0 = 10'd0;
    wire [15:0] sigma2_hw_0    = 16'd0;

    // -----------------------------------------------------------------------
    // Stage 7: Firmware weight compute (emulates PicoRV32 Step 3 + weight commit)
    // -----------------------------------------------------------------------
    function automatic int isqrt_fn(input int n);
        int x, x1;
        if (n <= 0) return 0;
        x = n; x1 = (n + 1) / 2;
        while (x1 < x) begin x = x1; x1 = (x + n/x) / 2; end
        return x;
    endfunction

    function automatic int floor_log2_fn(input int n);
        int k, tmp;
        if (n <= 1) return 0;
        tmp = n; k = 0;
        while (tmp > 1) begin tmp = tmp >> 1; k = k + 1; end
        return k;
    endfunction

    reg signed [7:0] fw_W_re0, fw_W_im0, fw_W_re1, fw_W_im1;
    reg signed [7:0] fw_W_re2, fw_W_im2, fw_W_re3, fw_W_im3;
    reg [2:0]        fw_pgs;
    reg              fw_W_valid;
    reg              fw_W_commit;
    integer          fw_expected_y_i;

    initial begin
        fw_W_re0 = 0; fw_W_im0 = 0; fw_W_re1 = 0; fw_W_im1 = 0;
        fw_W_re2 = 0; fw_W_im2 = 0; fw_W_re3 = 0; fw_W_im3 = 0;
        fw_pgs        = 0;
        fw_W_valid    = 0;
        fw_W_commit   = 0;
        fw_expected_y_i = 0;

        @(posedge training_done);
        @(posedge clk);   // let Zdiag outputs settle

        begin : fw_compute
            longint zdiag_max;
            longint e_max;
            int a_est, y_pre_max, pgs_v, w_max_v, denom, acc_i_expected;

            zdiag_max = Zdiag_0[31:16];
            if (longint'(Zdiag_1[31:16]) > zdiag_max) zdiag_max = Zdiag_1[31:16];
            if (longint'(Zdiag_2[31:16]) > zdiag_max) zdiag_max = Zdiag_2[31:16];
            if (longint'(Zdiag_3[31:16]) > zdiag_max) zdiag_max = Zdiag_3[31:16];

            e_max = (zdiag_max << 16) / longint'(n_acc);
            a_est = isqrt_fn(int'(e_max));
            $display("FW: n_acc=%0d zdiag_max=%0d e_max=%0d a_est=%0d",
                     n_acc, zdiag_max, e_max, a_est);

            if (a_est == 0 || n_acc == 0) begin
                pgs_v   = 0;
                w_max_v = 120;
            end else begin
                y_pre_max = (120 * 4 * a_est) / 256;
                if (y_pre_max >= 90) begin
                    pgs_v = 0;
                end else if (y_pre_max == 0) begin
                    pgs_v = 7;
                end else begin
                    pgs_v = floor_log2_fn(90 / y_pre_max);
                    if (pgs_v > 7) pgs_v = 7;
                end
                denom   = a_est * (1 << pgs_v);
                w_max_v = (denom > 0) ? (8128 / denom) : 120;
                if (w_max_v > 120) w_max_v = 120;
            end
            $display("FW: pgs=%0d w_max=%0d", pgs_v, w_max_v);

            acc_i_expected  = 4 * w_max_v * a_est;
            fw_expected_y_i = (acc_i_expected >> 8) << pgs_v;
            if (fw_expected_y_i > 127) fw_expected_y_i = 127;
            $display("FW: expected y_i = %0d", fw_expected_y_i);

            fw_W_re0 = w_max_v[7:0]; fw_W_im0 = 0;
            fw_W_re1 = w_max_v[7:0]; fw_W_im1 = 0;
            fw_W_re2 = w_max_v[7:0]; fw_W_im2 = 0;
            fw_W_re3 = w_max_v[7:0]; fw_W_im3 = 0;
            fw_pgs   = pgs_v[2:0];
        end

        @(posedge clk);
        fw_W_valid  = 1;
        fw_W_commit = 1;
        @(posedge clk);
        fw_W_commit = 0;
    end

    // -----------------------------------------------------------------------
    // Stage 8: MRC combiner — inputs from dcr (matches trouper_top, no replay)
    // -----------------------------------------------------------------------
    wire signed [7:0] y_i, y_q;
    wire              y_valid;

    mrc_combiner u_mrc (
        .clk_16m         (clk),
        .rst_n           (rst_n),
        .x_i0            (dcr_i0), .x_q0 (dcr_q0),
        .x_i1            (dcr_i1), .x_q1 (dcr_q1),
        .x_i2            (dcr_i2), .x_q2 (dcr_q2),
        .x_i3            (dcr_i3), .x_q3 (dcr_q3),
        .x_valid         (dcr_valid),
        .W_re0           (fw_W_re0), .W_im0 (fw_W_im0),
        .W_re1           (fw_W_re1), .W_im1 (fw_W_im1),
        .W_re2           (fw_W_re2), .W_im2 (fw_W_im2),
        .W_re3           (fw_W_re3), .W_im3 (fw_W_im3),
        .W_valid         (fw_W_valid),
        .mode            (1'b0),
        .bypass_ant      (2'd0),
        .post_gain_shift (fw_pgs),
        .y_i             (y_i),
        .y_q             (y_q),
        .y_valid         (y_valid)
    );

    // -----------------------------------------------------------------------
    // Stage 9: SD remodulator
    // -----------------------------------------------------------------------
    localparam [1:0] REMOD_BACKOFF_SHIFT = 2'd1;
    wire out_i, out_q;
    wire signed [7:0] remod_in_i = u_mrc.use_mrc_r ?
                                   ($signed(y_i) >>> REMOD_BACKOFF_SHIFT) : y_i;
    wire signed [7:0] remod_in_q = u_mrc.use_mrc_r ?
                                   ($signed(y_q) >>> REMOD_BACKOFF_SHIFT) : y_q;

    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (remod_in_i),
        .in_q     (remod_in_q),
        .in_valid (y_valid),
        .en       (1'b1),
        .out_i    (out_i),
        .out_q    (out_q)
    );

    // -----------------------------------------------------------------------
    // Test control
    // -----------------------------------------------------------------------
    integer  cycle_count;
    integer  pass_count, fail_count;
    integer  t_energy_valid, t_sigma2_valid;
    integer  t_sc_lock, t_train_done, t_w_commit, t_y_valid, t_y_valid_mrc;
    integer  t_out_i_flip, t_out_q_flip, t_mrc_input_latched;
    integer  y_valid_seen_after_commit;
    integer  remod_trace_count;
    reg      test_done;
    reg      out_i_seen_0, out_i_seen_1;
    reg      out_q_seen_0, out_q_seen_1;
    reg      out_i_at_y_valid;
    reg      remod_obs_started;
    reg signed [7:0] remod_target_i, remod_target_q;

    initial begin
        rst_n        = 1'b0;
        stim_ptr     = 7'd0;
        cycle_count   = 0;
        pass_count    = 0;
        fail_count    = 0;
        t_energy_valid = -1;
        t_sigma2_valid = -1;
        t_sc_lock     = -1;
        t_train_done  = -1;
        t_w_commit    = -1;
        t_y_valid     = -1;
        t_y_valid_mrc = -1;
        t_out_i_flip  = -1;
        t_out_q_flip  = -1;
        t_mrc_input_latched = -1;
        y_valid_seen_after_commit = 0;
        remod_trace_count = 0;
        test_done     = 1'b0;
        out_i_seen_0  = 1'b0;
        out_i_seen_1  = 1'b0;
        out_q_seen_0  = 1'b0;
        out_q_seen_1  = 1'b0;
        out_i_at_y_valid = 1'b0;
        remod_obs_started = 1'b0;
        remod_target_i = 8'sd0;
        remod_target_q = 8'sd0;

        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge clk);
    end

    always @(posedge clk) if (rst_n) cycle_count <= cycle_count + 1;

    // -----------------------------------------------------------------------
    // Test 6/7: energy_valid / sigma2_valid (stubs — never fires)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && energy_valid && t_energy_valid < 0) begin
            t_energy_valid = cycle_count;
            if (cycle_count <= 7000) begin
                $display("PASS test6: energy_valid at cycle %0d (<=7000), noise_metric_0=%0d",
                         cycle_count, noise_metric_0);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test6: energy_valid at cycle %0d (>7000)", cycle_count);
                fail_count = fail_count + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && sigma2_valid && t_sigma2_valid < 0) begin
            t_sigma2_valid = cycle_count;
            if (cycle_count <= 7000 && !sc_lock) begin
                $display("PASS test7: sigma2_valid at cycle %0d (<=7000, before sc_lock), sigma2_hw_0=%0d",
                         cycle_count, sigma2_hw_0);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test7: sigma2_valid at cycle %0d (>7000, sc_lock=%0b)",
                         cycle_count, sc_lock);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 1: sc_lock fires <= 20000 cycles
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && sc_lock && t_sc_lock < 0) begin
            t_sc_lock = cycle_count;
            if (cycle_count <= 20000) begin
                $display("PASS test1: sc_lock at cycle %0d (<=20000) sc_stat=%0d",
                         cycle_count, sc_stat);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test1: sc_lock at cycle %0d (>20000)", cycle_count);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 2: training_done arrives within 60000 cycles after sc_lock
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && training_done && t_train_done < 0) begin
            t_train_done = cycle_count;
            if (t_sc_lock >= 0 && (cycle_count - t_sc_lock) <= 60000) begin
                $display("PASS test2: training_done at cycle %0d (%0d cycles after sc_lock)",
                         cycle_count, cycle_count - t_sc_lock);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test2: training_done at cycle %0d (%0d cycles after sc_lock)",
                         cycle_count, cycle_count - t_sc_lock);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 3: fw_W_commit fires <= 50 cycles after training_done; fw_W_re0 != 0
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && fw_W_commit && t_w_commit < 0) begin
            t_w_commit = cycle_count;
            if (t_train_done >= 0 && (cycle_count - t_train_done) <= 50 && fw_W_re0 !== 8'h0) begin
                $display("PASS test3: fw_W_commit at cycle %0d (%0d after training_done), fw_W_re0=%0d pgs=%0d expected_y_i=%0d",
                         cycle_count, cycle_count - t_train_done, fw_W_re0, fw_pgs, fw_expected_y_i);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test3: fw_W_commit at cycle %0d (t_train_done=%0d), fw_W_re0=%0d",
                         cycle_count, t_train_done, fw_W_re0);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 3b: combiner output amplitude matches fw_expected_y_i (within ±4)
    // -----------------------------------------------------------------------
    integer t_test3b;
    initial t_test3b = -1;
    always @(posedge clk) begin
        if (rst_n && fw_W_valid && y_valid && u_mrc.use_mrc_r && t_test3b < 0
                && t_w_commit >= 0) begin
            t_test3b = cycle_count;
            if ($signed(y_i) >= (fw_expected_y_i - 4) &&
                $signed(y_i) <= (fw_expected_y_i + 4)) begin
                $display("PASS test3b: combiner amplitude y_i=%0d expected=%0d (±4), y_q=%0d",
                         $signed(y_i), fw_expected_y_i, $signed(y_q));
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test3b: combiner amplitude y_i=%0d expected=%0d (±4), y_q=%0d pgs=%0d",
                         $signed(y_i), fw_expected_y_i, $signed(y_q), fw_pgs);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 4: y_valid within 50 cycles of fw_W_commit
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && y_valid && t_w_commit >= 0 && t_y_valid < 0) begin
            t_y_valid = cycle_count;
            if ((cycle_count - t_w_commit) <= 50) begin
                $display("PASS test4: y_valid at cycle %0d (%0d after fw_W_commit), y_i=%0d y_q=%0d use_mrc_r=%0b",
                         cycle_count, cycle_count - t_w_commit,
                         $signed(y_i), $signed(y_q), u_mrc.use_mrc_r);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test4: y_valid at cycle %0d (%0d after W_commit)",
                         cycle_count, cycle_count - t_w_commit);
                fail_count = fail_count + 1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            y_valid_seen_after_commit <= 0;
        end else if (y_valid && t_w_commit >= 0 && y_valid_seen_after_commit < 8) begin
            y_valid_seen_after_commit <= y_valid_seen_after_commit + 1;
            $display("TRACE y_valid[%0d]: cycle=%0d y_i=%0d y_q=%0d remod_in_i=%0d remod_in_q=%0d W_valid=%0b use_mrc_r=%0b out_i=%0d out_q=%0d in_i_lat=%0d in_q_lat=%0d",
                     y_valid_seen_after_commit, cycle_count,
                     $signed(y_i), $signed(y_q), $signed(remod_in_i), $signed(remod_in_q),
                     fw_W_valid, u_mrc.use_mrc_r, out_i, out_q,
                     $signed(u_remod.in_i_lat), $signed(u_remod.in_q_lat));
        end
    end

    // -----------------------------------------------------------------------
    // Test 5: sd_remod latches MRC sample and shows live output behavior
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && y_valid && u_mrc.use_mrc_r && t_y_valid_mrc < 0)
            t_y_valid_mrc = cycle_count;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            out_i_seen_0 <= 1'b0; out_i_seen_1 <= 1'b0;
            out_q_seen_0 <= 1'b0; out_q_seen_1 <= 1'b0;
            remod_obs_started <= 1'b0;
            remod_trace_count <= 0;
        end else if (t_y_valid_mrc >= 0 && !test_done) begin
            if (!remod_obs_started && cycle_count >= t_y_valid_mrc) begin
                remod_obs_started <= 1'b1;
                out_i_at_y_valid  <= out_i;
                out_i_seen_0      <= (out_i == 1'b0);
                out_i_seen_1      <= (out_i == 1'b1);
                out_q_seen_0      <= (out_q == 1'b0);
                out_q_seen_1      <= (out_q == 1'b1);
                remod_target_i    <= remod_in_i;
                remod_target_q    <= remod_in_q;
                remod_trace_count <= 0;
                $display("INFO test5: start remod observe at cycle %0d out_i=%0d out_q=%0d target_i=%0d target_q=%0d",
                         cycle_count, out_i, out_q,
                         $signed(remod_in_i), $signed(remod_in_q));
            end else if (remod_obs_started) begin
                if (remod_trace_count < 16) begin
                    $display("TRACE test5: cycle=%0d dt=%0d out_i=%0d out_q=%0d y_i=%0d y_q=%0d in_i_lat=%0d in_q_lat=%0d s1_i=%0d s2_i=%0d s3_i=%0d",
                             cycle_count, cycle_count - t_y_valid_mrc,
                             out_i, out_q, $signed(y_i), $signed(y_q),
                             $signed(u_remod.in_i_lat), $signed(u_remod.in_q_lat),
                             $signed(u_remod.s1_i), $signed(u_remod.s2_i), $signed(u_remod.s3_i));
                    remod_trace_count <= remod_trace_count + 1;
                end

                if (out_i == 1'b0) out_i_seen_0 <= 1'b1;
                if (out_i == 1'b1) out_i_seen_1 <= 1'b1;
                if (out_q == 1'b0) out_q_seen_0 <= 1'b1;
                if (out_q == 1'b1) out_q_seen_1 <= 1'b1;

                if (t_out_i_flip < 0 && out_i != out_i_at_y_valid)
                    t_out_i_flip = cycle_count;
                if (t_out_q_flip < 0 && out_q != out_q_seen_1)
                    t_out_q_flip = cycle_count;
                if (t_mrc_input_latched < 0 &&
                    u_remod.in_i_lat == remod_target_i &&
                    u_remod.in_q_lat == remod_target_q)
                    t_mrc_input_latched = cycle_count;

                if (t_mrc_input_latched >= 0 && out_q_seen_0 && out_q_seen_1 &&
                    (($signed(remod_target_i) >= 8'sd120 && out_i_seen_1) ||
                     ($signed(remod_target_i) <= -8'sd120 && out_i_seen_0) ||
                     (($signed(remod_target_i) < 8'sd120 && $signed(remod_target_i) > -8'sd120) &&
                      out_i_seen_0 && out_i_seen_1))) begin
                    test_done = 1'b1;
                    $display("PASS test5: remod latched MRC sample by cycle %0d and showed expected output behavior (input_latched=%0d, out_i_first_flip=%0d)",
                             cycle_count, t_mrc_input_latched, t_out_i_flip);
                    pass_count = pass_count + 1;
                    #1;
                    $display("------------------------------------------------------------");
                    $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
                    $display("------------------------------------------------------------");
                    $finish;
                end

                if ((cycle_count - t_y_valid_mrc) == 2048) begin
                    test_done = 1'b1;
                    $display("FAIL test5: remod did not show expected post-MRC behavior within 2048 cycles (input_latched=%0d target_i=%0d target_q=%0d in_i_lat=%0d in_q_lat=%0d out_i_seen={%0d,%0d} out_q_seen={%0d,%0d})",
                             t_mrc_input_latched, $signed(remod_target_i), $signed(remod_target_q),
                             $signed(u_remod.in_i_lat), $signed(u_remod.in_q_lat),
                             out_i_seen_1, out_i_seen_0, out_q_seen_1, out_q_seen_0);
                    fail_count = fail_count + 1;
                    #1;
                    $display("------------------------------------------------------------");
                    $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
                    $display("------------------------------------------------------------");
                    $finish;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Timeout watchdog: 200000 cycles
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (cycle_count == 200000) begin
            $display("TIMEOUT at cycle %0d — chain did not complete.", cycle_count);
            if (t_energy_valid < 0) $display("  energy_valid never fired (stub — expected)");
            if (t_sigma2_valid < 0) $display("  sigma2_valid never fired (stub — expected)");
            if (t_sc_lock < 0)      $display("  sc_lock never fired");
            if (t_train_done < 0)   $display("  training_done never fired");
            if (t_w_commit < 0)     $display("  W_commit never fired");
            if (t_y_valid < 0)      $display("  y_valid never fired");
            if (!test_done)         $display("  sd_remod post-MRC behavior was not observed");
            $display("------------------------------------------------------------");
            $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count + 1);
            $display("------------------------------------------------------------");
            $finish;
        end
    end

    // Debug: n_acc progress
    reg [15:0] n_acc_prev;
    always @(posedge clk) begin
        n_acc_prev <= n_acc;
        if (rst_n && n_acc != n_acc_prev && (n_acc % 50 == 0))
            $display("DBG n_acc=%0d cycle=%0d sc_lock=%0b", n_acc, cycle_count, sc_lock);
    end

endmodule
