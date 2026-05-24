// tb_dsp_chain.v
// End-to-end DSP chain testbench:
//   dc_removal → frontend_buf_ctrl → sc_detector
//                                  → energy_meas → noise_floor_est
//                                  → training_acc → weight_gen
//                                  → mrc_combiner → sd_remod
//
// No PicoRV32. CPU-controlled knobs are hardwired:
//   dc_bypass=1    — bypass DC removal so constant-tone stimulus works
//   noise_sample_en = energy_valid && !sc_lock  (simplified packet_ctrl_fsm)
//   buf_freeze=0, all antennas enabled, MRC mode, auto-commit weights
//
// Strobe period: 20 cycles (frontend_buf_ctrl needs 17 sub-cycles per sample).
//
// Tests (self-checking):
//   1. sc_lock      fires <= 8000 cycles
//   2. training_done fires <= 16000 cycles after sc_lock
//   3. W_commit     fires <= 200 cycles after training_done; W_hw_re0 != 0
//   4. y_valid      fires <= 30 cycles after W_commit
//   5. sd_remod out_i toggles <= 64 cycles after y_valid
//   6. energy_valid fires <= 3500 cycles (before sc_lock)
//   7. sigma2_valid fires <= 3500 cycles (noise floor estimated while idle)

`timescale 1ns/1ps

// -------------------------------------------------------------------------
// Behavioral model of GF180 512x8 SRAM (used by frontend_buf_ctrl)
// -------------------------------------------------------------------------
module gf180mcu_ocd_ip_sram__sram512x8m8wm1 (
    input         CLK,
    input         CEN,
    input         GWEN,
    input  [7:0]  WEN,
    input  [8:0]  A,
    input  [7:0]  D,
    output reg [7:0] Q
);
    reg [7:0] mem [0:511];
    integer mi;
    initial begin
        Q = 8'h00;
        for (mi = 0; mi < 512; mi = mi + 1) mem[mi] = 8'h00;
    end
    always @(posedge CLK) begin
        if (!CEN) begin
            if (!GWEN) mem[A] <= D;
            Q <= mem[A];
        end
    end
endmodule

// -------------------------------------------------------------------------

module tb_dsp_chain;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    // -----------------------------------------------------------------------
    // Raw stimulus: constant I-axis tone (post-AGC signal level)
    // -----------------------------------------------------------------------
    reg signed [7:0] raw_i0, raw_i1, raw_i2, raw_i3;
    reg signed [7:0] raw_q0, raw_q1, raw_q2, raw_q3;

    // iq_valid strobe: 1 pulse every 20 cycles
    // (frontend_buf_ctrl needs 17 sub-cycles; training_acc TDM needs 6;
    //  mrc_combiner state machine needs 10 — 20 covers all)
    reg [4:0] strobe_cnt;
    reg       iq_valid;

    // -----------------------------------------------------------------------
    // Stage 1: DC removal (bypass=1 so constant-tone stimulus passes through)
    // -----------------------------------------------------------------------
    wire signed [7:0] dcr_i0, dcr_i1, dcr_i2, dcr_i3;
    wire signed [7:0] dcr_q0, dcr_q1, dcr_q2, dcr_q3;
    wire              dcr_valid;

    dc_removal u_dcr (
        .clk_32m       (clk),
        .rst_n         (rst_n),
        .raw_i0        (raw_i0),  .raw_i1 (raw_i1),
        .raw_i2        (raw_i2),  .raw_i3 (raw_i3),
        .raw_q0        (raw_q0),  .raw_q1 (raw_q1),
        .raw_q2        (raw_q2),  .raw_q3 (raw_q3),
        .raw_valid     (iq_valid),
        .dc_alpha_shift(4'd8),
        .dc_bypass     (1'b1),    // bypass: constant tone passes through unchanged
        .out_i0        (dcr_i0),  .out_i1 (dcr_i1),
        .out_i2        (dcr_i2),  .out_i3 (dcr_i3),
        .out_q0        (dcr_q0),  .out_q1 (dcr_q1),
        .out_q2        (dcr_q2),  .out_q3 (dcr_q3),
        .out_valid     (dcr_valid),
        .dc_est_i0 (), .dc_est_i1 (), .dc_est_i2 (), .dc_est_i3 (),
        .dc_est_q0 (), .dc_est_q1 (), .dc_est_q2 (), .dc_est_q3 ()
    );

    // -----------------------------------------------------------------------
    // Stage 2: Frontend buffer controller (M/2 SRAM delay + cur/del outputs)
    // -----------------------------------------------------------------------
    wire [8:0]  sram0_A, sram1_A;
    wire [7:0]  sram0_D, sram1_D;
    wire [7:0]  sram0_Q, sram1_Q;
    wire        sram0_CEN, sram1_CEN;
    wire        sram0_GWEN, sram1_GWEN;

    gf180mcu_ocd_ip_sram__sram512x8m8wm1 u_sram0 (
        .CLK  (clk), .CEN (sram0_CEN), .GWEN (sram0_GWEN),
        .WEN  (8'h00), .A (sram0_A), .D (sram0_D), .Q (sram0_Q)
    );
    gf180mcu_ocd_ip_sram__sram512x8m8wm1 u_sram1 (
        .CLK  (clk), .CEN (sram1_CEN), .GWEN (sram1_GWEN),
        .WEN  (8'h00), .A (sram1_A), .D (sram1_D), .Q (sram1_Q)
    );

    wire signed [7:0] cur_i0, cur_i1, cur_i2, cur_i3;
    wire signed [7:0] cur_q0, cur_q1, cur_q2, cur_q3;
    wire signed [7:0] del_i0, del_i1, del_i2, del_i3;
    wire signed [7:0] del_q0, del_q1, del_q2, del_q3;
    wire              delayed_valid;

    frontend_buf_ctrl u_fbuf (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .in_i0      (dcr_i0),  .in_i1 (dcr_i1),
        .in_i2      (dcr_i2),  .in_i3 (dcr_i3),
        .in_q0      (dcr_q0),  .in_q1 (dcr_q1),
        .in_q2      (dcr_q2),  .in_q3 (dcr_q3),
        .sf         (4'd7),
        .sc_lock    (sc_lock),
        .buf_freeze (1'b0),
        .sram0_A    (sram0_A),  .sram0_D (sram0_D),  .sram0_Q (sram0_Q),
        .sram0_CEN  (sram0_CEN), .sram0_GWEN (sram0_GWEN),
        .sram1_A    (sram1_A),  .sram1_D (sram1_D),  .sram1_Q (sram1_Q),
        .sram1_CEN  (sram1_CEN), .sram1_GWEN (sram1_GWEN),
        .cur_i0     (cur_i0),  .cur_i1 (cur_i1),
        .cur_i2     (cur_i2),  .cur_i3 (cur_i3),
        .cur_q0     (cur_q0),  .cur_q1 (cur_q1),
        .cur_q2     (cur_q2),  .cur_q3 (cur_q3),
        .del_i0     (del_i0),  .del_i1 (del_i1),
        .del_i2     (del_i2),  .del_i3 (del_i3),
        .del_q0     (del_q0),  .del_q1 (del_q1),
        .del_q2     (del_q2),  .del_q3 (del_q3),
        .delayed_valid (delayed_valid),
        .buf_mode   (),
        .buf_valid  (),
        .wr_ptr     ()
    );

    // -----------------------------------------------------------------------
    // Stage 3: Energy measurement
    // -----------------------------------------------------------------------
    wire [31:0] energy_sum_0, energy_sum_1, energy_sum_2, energy_sum_3;
    wire [15:0] energy_snap_0, energy_snap_1, energy_snap_2, energy_snap_3;
    wire        energy_valid;
    wire        energy_snapshot_valid;

    energy_meas u_em (
        .clk_32m     (clk),
        .rst_n       (rst_n),
        .iq_i_0      (dcr_i0),  .iq_i_1 (dcr_i1),
        .iq_i_2      (dcr_i2),  .iq_i_3 (dcr_i3),
        .iq_q_0      (dcr_q0),  .iq_q_1 (dcr_q1),
        .iq_q_2      (dcr_q2),  .iq_q_3 (dcr_q3),
        .iq_valid    (dcr_valid),
        .sf          (4'd7),
        .sc_lock     (sc_lock),
        .energy_sum_0 (energy_sum_0), .energy_sum_1 (energy_sum_1),
        .energy_sum_2 (energy_sum_2), .energy_sum_3 (energy_sum_3),
        .energy_0    (energy_snap_0), .energy_1 (energy_snap_1),
        .energy_2    (energy_snap_2), .energy_3 (energy_snap_3),
        .energy_valid           (energy_valid),
        .energy_snapshot_valid  (energy_snapshot_valid)
    );

    // -----------------------------------------------------------------------
    // Stage 4: Noise floor estimator
    // noise_sample_en: simplified packet_ctrl_fsm logic —
    //   sample noise when energy window completes and no preamble locked yet
    // -----------------------------------------------------------------------
    wire        noise_sample_en = energy_valid && !sc_lock;

    wire [15:0] sigma2_hw_0, sigma2_hw_1, sigma2_hw_2, sigma2_hw_3;
    wire [15:0] sigma2_active_0, sigma2_active_1, sigma2_active_2, sigma2_active_3;
    wire        sigma2_valid;
    wire [7:0]  n_updates_nfe;

    noise_floor_est u_nfe (
        .clk_32m           (clk),
        .rst_n             (rst_n),
        .energy_sum_0      (energy_sum_0), .energy_sum_1 (energy_sum_1),
        .energy_sum_2      (energy_sum_2), .energy_sum_3 (energy_sum_3),
        .noise_sample_en   (noise_sample_en),
        .sf                (4'd7),
        .noise_alpha_shift (3'd4),
        .sigma2_sw_0       (16'h0), .sigma2_sw_1 (16'h0),
        .sigma2_sw_2       (16'h0), .sigma2_sw_3 (16'h0),
        .sigma2_commit     (1'b0),
        .sigma2_src        (1'b0),
        .agc_gain_changed  (1'b0),
        .sigma2_hw_0       (sigma2_hw_0), .sigma2_hw_1 (sigma2_hw_1),
        .sigma2_hw_2       (sigma2_hw_2), .sigma2_hw_3 (sigma2_hw_3),
        .sigma2_active_0   (sigma2_active_0), .sigma2_active_1 (sigma2_active_1),
        .sigma2_active_2   (sigma2_active_2), .sigma2_active_3 (sigma2_active_3),
        .sigma2_valid      (sigma2_valid),
        .n_updates         (n_updates_nfe)
    );

    // -----------------------------------------------------------------------
    // Stage 5: Schmidl-Cox preamble detector
    // -----------------------------------------------------------------------
    wire        sc_lock;
    wire [31:0] timing_ref;
    wire signed [31:0] c_i0, c_q0, c_i1, c_q1;

    sc_detector u_sc (
        .clk            (clk),
        .rst_n          (rst_n),
        .iq_valid       (dcr_valid),
        .cur_i0         (cur_i0),  .cur_i1 (cur_i1),
        .cur_q0         (cur_q0),  .cur_q1 (cur_q1),
        .del_i0         (del_i0),  .del_i1 (del_i1),
        .del_q0         (del_q0),  .del_q1 (del_q1),
        .delayed_valid  (delayed_valid),
        .sf             (4'd7),
        .sc_thr         (16'd1),
        .sc_hits_req    (2'd1),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .c_i0           (c_i0),  .c_q0  (c_q0),
        .c_i1           (c_i1),  .c_q1  (c_q1),
        .sc_stat        (),
        .sc_hit_dbg     (),
        .sc_hit_count_dbg (),
        .sc_first_hit_dbg (),
        .sc_lock_sample_dbg ()
    );

    // -----------------------------------------------------------------------
    // Stage 6: Training accumulator
    // -----------------------------------------------------------------------
    wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3;
    wire signed [63:0] E_ref;
    wire        training_done;
    wire [9:0]  n_acc;

    training_acc u_tacc (
        .clk            (clk),
        .rst_n          (rst_n),
        .iq_valid       (dcr_valid),
        .raw_i0         (dcr_i0),  .raw_i1 (dcr_i1),
        .raw_i2         (dcr_i2),  .raw_i3 (dcr_i3),
        .raw_q0         (dcr_q0),  .raw_q1 (dcr_q1),
        .raw_q2         (dcr_q2),  .raw_q3 (dcr_q3),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .sf             (4'd7),
        .ref_sel        (2'd0),
        .noise_en       (1'b0),
        .Z_i0           (Z_i0),  .Z_q0  (Z_q0),
        .Z_i1           (Z_i1),  .Z_q1  (Z_q1),
        .Z_i2           (Z_i2),  .Z_q2  (Z_q2),
        .Z_i3           (Z_i3),  .Z_q3  (Z_q3),
        .E_ref          (E_ref),
        .training_done  (training_done),
        .noise_ready    (),
        .n_acc          (n_acc)
    );

    // -----------------------------------------------------------------------
    // Stage 7: Weight generator
    // -----------------------------------------------------------------------
    wire signed [15:0] W_hw_re0, W_hw_im0, W_hw_re1, W_hw_im1;
    wire signed [15:0] W_hw_re2, W_hw_im2, W_hw_re3, W_hw_im3;
    wire        W_commit;

    weight_gen u_wgen (
        .clk            (clk),
        .rst_n          (rst_n),
        .training_done  (training_done),
        .Z_i0           (Z_i0),  .Z_q0  (Z_q0),
        .Z_i1           (Z_i1),  .Z_q1  (Z_q1),
        .Z_i2           (Z_i2),  .Z_q2  (Z_q2),
        .Z_i3           (Z_i3),  .Z_q3  (Z_q3),
        .n_acc          (n_acc),
        .wgt_src        (1'b0),
        .wgt_auto_commit(1'b1),
        .wgt_mode       (2'b00),
        .antenna_en     (4'hF),
        .cal_re0        (16'h7FFF),  .cal_im0 (16'h0),
        .cal_re1        (16'h7FFF),  .cal_im1 (16'h0),
        .cal_re2        (16'h7FFF),  .cal_im2 (16'h0),
        .cal_re3        (16'h7FFF),  .cal_im3 (16'h0),
        .fw_W_re0       (16'h0),  .fw_W_im0 (16'h0),
        .fw_W_re1       (16'h0),  .fw_W_im1 (16'h0),
        .fw_W_re2       (16'h0),  .fw_W_im2 (16'h0),
        .fw_W_re3       (16'h0),  .fw_W_im3 (16'h0),
        .fw_W_commit    (1'b0),
        .W_hw_re0       (W_hw_re0),  .W_hw_im0 (W_hw_im0),
        .W_hw_re1       (W_hw_re1),  .W_hw_im1 (W_hw_im1),
        .W_hw_re2       (W_hw_re2),  .W_hw_im2 (W_hw_im2),
        .W_hw_re3       (W_hw_re3),  .W_hw_im3 (W_hw_im3),
        .W_shadow_re0   (),  .W_shadow_im0 (),
        .W_shadow_re1   (),  .W_shadow_im1 (),
        .W_shadow_re2   (),  .W_shadow_im2 (),
        .W_shadow_re3   (),  .W_shadow_im3 (),
        .W_commit       (W_commit),
        .wgen_hw_done   (),
        .wgen_active    (),
        .wgen_mode_dbg  ()
    );

    // W_valid latch: set on W_commit, cleared on reset
    reg W_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) W_valid <= 1'b0;
        else if (W_commit) W_valid <= 1'b1;
    end

    // -----------------------------------------------------------------------
    // Stage 8: MRC combiner
    // -----------------------------------------------------------------------
    wire signed [7:0] y_i, y_q;
    wire              y_valid;

    mrc_combiner u_mrc (
        .clk_16m    (clk),
        .rst_n      (rst_n),
        .x_i0       (dcr_i0),  .x_q0 (dcr_q0),
        .x_i1       (dcr_i1),  .x_q1 (dcr_q1),
        .x_i2       (dcr_i2),  .x_q2 (dcr_q2),
        .x_i3       (dcr_i3),  .x_q3 (dcr_q3),
        .x_valid    (dcr_valid),
        .W_re0      (W_hw_re0),  .W_im0 (W_hw_im0),
        .W_re1      (W_hw_re1),  .W_im1 (W_hw_im1),
        .W_re2      (W_hw_re2),  .W_im2 (W_hw_im2),
        .W_re3      (W_hw_re3),  .W_im3 (W_hw_im3),
        .W_valid    (W_valid),
        .mode       (1'b0),
        .bypass_ant (2'd0),
        .post_gain_shift(3'd0),
        .y_i        (y_i),
        .y_q        (y_q),
        .y_valid    (y_valid)
    );

    // -----------------------------------------------------------------------
    // Stage 9: SD remodulator
    // -----------------------------------------------------------------------
    wire out_i, out_q;

    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (y_i),
        .in_q     (y_q),
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
    integer  t_sc_lock, t_train_done, t_w_commit, t_y_valid;
    reg      test_done;
    reg      out_i_seen_0, out_i_seen_1;

    initial begin
        rst_n        = 1'b0;
        iq_valid     = 1'b0;
        strobe_cnt   = 5'd0;
        raw_i0 = 8'sd50; raw_q0 = 8'sd0;
        raw_i1 = 8'sd50; raw_q1 = 8'sd0;
        raw_i2 = 8'sd50; raw_q2 = 8'sd0;
        raw_i3 = 8'sd50; raw_q3 = 8'sd0;
        cycle_count   = 0;
        pass_count    = 0;
        fail_count    = 0;
        t_energy_valid = -1;
        t_sigma2_valid = -1;
        t_sc_lock     = -1;
        t_train_done  = -1;
        t_w_commit    = -1;
        t_y_valid     = -1;
        test_done     = 1'b0;
        out_i_seen_0  = 1'b0;
        out_i_seen_1  = 1'b0;

        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge clk);
    end

    // iq_valid strobe: high for 1 cycle every 20 cycles
    always @(posedge clk) begin
        if (!rst_n) begin
            strobe_cnt <= 5'd0;
            iq_valid   <= 1'b0;
        end else begin
            if (strobe_cnt == 5'd19) begin
                strobe_cnt <= 5'd0;
                iq_valid   <= 1'b1;
            end else begin
                strobe_cnt <= strobe_cnt + 5'd1;
                iq_valid   <= 1'b0;
            end
        end
    end

    // Cycle counter
    always @(posedge clk) if (rst_n) cycle_count <= cycle_count + 1;

    // -----------------------------------------------------------------------
    // Test 6: energy_valid fires <= 3500 cycles (one SF7 window = 128 samples)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && energy_valid && t_energy_valid < 0) begin
            t_energy_valid = cycle_count;
            if (cycle_count <= 3500) begin
                $display("PASS test6: energy_valid at cycle %0d (<=3500), energy_sum_0=%0d",
                         cycle_count, energy_sum_0);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test6: energy_valid at cycle %0d (>3500)", cycle_count);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 7: sigma2_valid fires <= 3500 cycles (noise floor seeded)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && sigma2_valid && t_sigma2_valid < 0) begin
            t_sigma2_valid = cycle_count;
            if (cycle_count <= 3500 && !sc_lock) begin
                $display("PASS test7: sigma2_valid at cycle %0d (<=3500, before sc_lock), sigma2_hw_0=%0d",
                         cycle_count, sigma2_hw_0);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test7: sigma2_valid at cycle %0d (sc_lock=%0b)", cycle_count, sc_lock);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 1: sc_lock fires <= 8000 cycles
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && sc_lock && t_sc_lock < 0) begin
            t_sc_lock = cycle_count;
            if (cycle_count <= 8000) begin
                $display("PASS test1: sc_lock at cycle %0d (<=8000)", cycle_count);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test1: sc_lock at cycle %0d (>8000)", cycle_count);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 2: training_done within 16000 cycles of sc_lock
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && training_done && t_train_done < 0) begin
            t_train_done = cycle_count;
            if (t_sc_lock >= 0 && (cycle_count - t_sc_lock) <= 16000) begin
                $display("PASS test2: training_done at cycle %0d (%0d cycles after sc_lock)",
                         cycle_count, cycle_count - t_sc_lock);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test2: training_done at cycle %0d (t_sc_lock=%0d)",
                         cycle_count, t_sc_lock);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 3: W_commit within 200 cycles of training_done; W_hw_re0 != 0
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && W_commit && t_w_commit < 0) begin
            t_w_commit = cycle_count;
            if (t_train_done >= 0 && (cycle_count - t_train_done) <= 200 && W_hw_re0 !== 16'h0) begin
                $display("PASS test3: W_commit at cycle %0d (%0d after training_done), W_hw_re0=%0d",
                         cycle_count, cycle_count - t_train_done, W_hw_re0);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test3: W_commit at cycle %0d (t_train_done=%0d), W_hw_re0=%0d",
                         cycle_count, t_train_done, W_hw_re0);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 4: y_valid within 30 cycles of W_commit
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && y_valid && t_w_commit >= 0 && t_y_valid < 0) begin
            t_y_valid = cycle_count;
            if ((cycle_count - t_w_commit) <= 30) begin
                $display("PASS test4: y_valid at cycle %0d (%0d after W_commit), y_i=%0d y_q=%0d",
                         cycle_count, cycle_count - t_w_commit, $signed(y_i), $signed(y_q));
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test4: y_valid at cycle %0d (%0d after W_commit)",
                         cycle_count, cycle_count - t_w_commit);
                fail_count = fail_count + 1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Test 5: sd_remod out_i toggles within 64 cycles of first y_valid
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            out_i_seen_0 <= 1'b0;
            out_i_seen_1 <= 1'b0;
        end else if (t_y_valid >= 0 && !test_done) begin
            if (out_i == 1'b0) out_i_seen_0 <= 1'b1;
            if (out_i == 1'b1) out_i_seen_1 <= 1'b1;

            if (out_i_seen_0 && out_i_seen_1) begin
                test_done = 1'b1;
                if ((cycle_count - t_y_valid) <= 64) begin
                    $display("PASS test5: sd_remod out_i toggles at cycle %0d (%0d after y_valid)",
                             cycle_count, cycle_count - t_y_valid);
                    pass_count = pass_count + 1;
                end else begin
                    $display("FAIL test5: sd_remod out_i toggle took %0d cycles (>64)",
                             cycle_count - t_y_valid);
                    fail_count = fail_count + 1;
                end
                #1;
                $display("------------------------------------------------------------");
                $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
                $display("------------------------------------------------------------");
                $finish;
            end

            if ((cycle_count - t_y_valid) == 64 && !(out_i_seen_0 && out_i_seen_1)) begin
                test_done = 1'b1;
                $display("FAIL test5: sd_remod out_i stuck at %0d for 64 cycles after y_valid", out_i);
                fail_count = fail_count + 1;
                #1;
                $display("------------------------------------------------------------");
                $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
                $display("------------------------------------------------------------");
                $finish;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Timeout watchdog: 35000 cycles
    // (sc_lock ~6400 + training ~15400 + wgen ~200 + remod ~64)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (cycle_count == 35000) begin
            $display("TIMEOUT at cycle %0d — chain did not complete.", cycle_count);
            if (t_energy_valid < 0) $display("  energy_valid never fired");
            if (t_sigma2_valid < 0) $display("  sigma2_valid never fired");
            if (t_sc_lock < 0)      $display("  sc_lock never fired");
            if (t_train_done < 0)   $display("  training_done never fired");
            if (t_w_commit < 0)     $display("  W_commit never fired");
            if (t_y_valid < 0)      $display("  y_valid never fired");
            if (!test_done)         $display("  sd_remod out_i never toggled");
            $display("------------------------------------------------------------");
            $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count + 1);
            $display("------------------------------------------------------------");
            $finish;
        end
    end

endmodule
