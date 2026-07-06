// tb_dsp_chain_real.v
// End-to-end DSP chain testbench driven by real LoRa IQ capture.
//
// Stimulus file: 1_packet_mingain_chip.bin
//   Format: raw int8, interleaved I/Q, 125 kHz chip rate (after 8x decimation)
//   15,000 chip samples, all 4 antennas driven with same data (single SDR capture)
//
// Chain: dc_removal → frontend_buf_ctrl → sc_detector
//                                       → energy_meas → noise_floor_est
//                                       → training_acc → weight_gen
//                                       → mrc_combiner → sd_remod
//
// Tests (self-checking):
//   1. energy_valid fires (noise floor window completes)
//   2. sigma2_valid fires before sc_lock
//   3. sc_lock fires before stimulus ends
//   4. training_done fires after sc_lock
//   5. W_commit fires after training_done; W_hw_re0 != 0
//   6. y_valid fires after W_commit
//   7. sd_remod out_i toggles after y_valid

`timescale 1ns/1ps

// Behavioral SRAM model (same as in tb_dsp_chain.v)
/* verilator lint_off DECLFILENAME */
module gf180mcu_ocd_ip_sram__sram512x8m8wm1_real (
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
/* verilator lint_on DECLFILENAME */

module tb_dsp_chain_real;

    // -----------------------------------------------------------------------
    // Clock / reset  (32 MHz)
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #15.625 clk = ~clk;

    // -----------------------------------------------------------------------
    // Stimulus: load chip-rate binary, feed at 20-cycle strobe
    // -----------------------------------------------------------------------
    localparam MAX_SAMPLES = 16000;

    reg signed [7:0] stim_i [0:MAX_SAMPLES-1];
    reg signed [7:0] stim_q [0:MAX_SAMPLES-1];
    integer stim_n;   // actual samples loaded

    // Read binary file: int8 interleaved I/Q
    integer stim_fd, rd, s;
    reg [7:0] rbuf;
    initial begin
        stim_n = 0;
        stim_fd = $fopen("/foss/designs/lora-mimo/sim/examples/1_packet_mingain_chip.bin", "rb");
        if (stim_fd == 0) begin
            $display("ERROR: could not open stimulus file");
            $finish;
        end
        for (s = 0; s < MAX_SAMPLES; s = s + 1) begin
            rd = $fread(rbuf, stim_fd);
            if (rd == 0) begin stim_n = s; s = MAX_SAMPLES; end
            else stim_i[s] = $signed(rbuf);

            if (rd != 0) begin
                rd = $fread(rbuf, stim_fd);
                stim_q[s] = $signed(rbuf);
                stim_n = s + 1;
            end
        end
        $fclose(stim_fd);
        $display("Loaded %0d chip samples from stimulus file", stim_n);
    end

    // iq_valid strobe: 1 pulse every 20 cycles
    reg [4:0]  strobe_cnt;
    reg        iq_valid;
    integer    stim_idx;

    reg signed [7:0] raw_i0, raw_i1, raw_i2, raw_i3;
    reg signed [7:0] raw_q0, raw_q1, raw_q2, raw_q3;

    initial begin
        rst_n      = 1'b0;
        iq_valid   = 1'b0;
        strobe_cnt = 5'd0;
        stim_idx   = 0;
        raw_i0 = 8'sd0; raw_q0 = 8'sd0;
        raw_i1 = 8'sd0; raw_q1 = 8'sd0;
        raw_i2 = 8'sd0; raw_q2 = 8'sd0;
        raw_i3 = 8'sd0; raw_q3 = 8'sd0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge clk);
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            strobe_cnt <= 5'd0;
            iq_valid   <= 1'b0;
        end else begin
            if (strobe_cnt == 5'd19) begin
                strobe_cnt <= 5'd0;
                if (stim_idx < stim_n) begin
                    iq_valid <= 1'b1;
                    // Same sample to all 4 antennas (single-channel capture)
                    raw_i0 <= stim_i[stim_idx]; raw_q0 <= stim_q[stim_idx];
                    raw_i1 <= stim_i[stim_idx]; raw_q1 <= stim_q[stim_idx];
                    raw_i2 <= stim_i[stim_idx]; raw_q2 <= stim_q[stim_idx];
                    raw_i3 <= stim_i[stim_idx]; raw_q3 <= stim_q[stim_idx];
                    stim_idx <= stim_idx + 1;
                end else begin
                    iq_valid <= 1'b0;
                end
            end else begin
                strobe_cnt <= strobe_cnt + 5'd1;
                iq_valid   <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Stage 1: DC removal (active — real capture may have DC offset)
    // -----------------------------------------------------------------------
    wire signed [7:0] dcr_i0, dcr_i1, dcr_i2, dcr_i3;
    wire signed [7:0] dcr_q0, dcr_q1, dcr_q2, dcr_q3;
    wire              dcr_valid;

    dc_removal u_dcr (
        .clk_32m       (clk),       .rst_n         (rst_n),
        .sample_i0     (raw_i0),    .sample_i1     (raw_i1),
        .sample_i2     (raw_i2),    .sample_i3     (raw_i3),
        .sample_q0     (raw_q0),    .sample_q1     (raw_q1),
        .sample_q2     (raw_q2),    .sample_q3     (raw_q3),
        .sample_valid  (iq_valid),
        .sample_out_i0 (dcr_i0),    .sample_out_i1 (dcr_i1),
        .sample_out_i2 (dcr_i2),    .sample_out_i3 (dcr_i3),
        .sample_out_q0 (dcr_q0),    .sample_out_q1 (dcr_q1),
        .sample_out_q2 (dcr_q2),    .sample_out_q3 (dcr_q3),
        .sample_out_valid (dcr_valid)
    );

    // -----------------------------------------------------------------------
    // Stage 2: Frontend buffer (SRAM-backed M/2 delay)
    // -----------------------------------------------------------------------
    wire [8:0]  sram0_A, sram1_A;
    wire [7:0]  sram0_D, sram1_D, sram0_Q, sram1_Q;
    wire        sram0_CEN, sram1_CEN, sram0_GWEN, sram1_GWEN;

    gf180mcu_ocd_ip_sram__sram512x8m8wm1_real u_sram0 (
        .CLK(clk), .CEN(sram0_CEN), .GWEN(sram0_GWEN),
        .WEN(8'h00), .A(sram0_A), .D(sram0_D), .Q(sram0_Q)
    );
    gf180mcu_ocd_ip_sram__sram512x8m8wm1_real u_sram1 (
        .CLK(clk), .CEN(sram1_CEN), .GWEN(sram1_GWEN),
        .WEN(8'h00), .A(sram1_A), .D(sram1_D), .Q(sram1_Q)
    );

    wire signed [7:0] cur_i0, cur_i1, cur_i2, cur_i3;
    wire signed [7:0] cur_q0, cur_q1, cur_q2, cur_q3;
    wire signed [7:0] del_i0, del_i1, del_i2, del_i3;
    wire signed [7:0] del_q0, del_q1, del_q2, del_q3;
    wire              delayed_valid;
    wire              sc_lock;   // forward ref for frontend_buf_ctrl

    frontend_buf_ctrl u_fbuf (
        .clk(clk),          .rst_n(rst_n),
        .iq_valid(dcr_valid),
        .in_i0(dcr_i0),  .in_i1(dcr_i1),  .in_i2(dcr_i2),  .in_i3(dcr_i3),
        .in_q0(dcr_q0),  .in_q1(dcr_q1),  .in_q2(dcr_q2),  .in_q3(dcr_q3),
        .sf(4'd7),          .sc_lock(sc_lock),  .buf_freeze(1'b0),
        .sram0_A(sram0_A),  .sram0_D(sram0_D),  .sram0_Q(sram0_Q),
        .sram0_CEN(sram0_CEN), .sram0_GWEN(sram0_GWEN),
        .sram1_A(sram1_A),  .sram1_D(sram1_D),  .sram1_Q(sram1_Q),
        .sram1_CEN(sram1_CEN), .sram1_GWEN(sram1_GWEN),
        .cur_i0(cur_i0), .cur_i1(cur_i1), .cur_i2(cur_i2), .cur_i3(cur_i3),
        .cur_q0(cur_q0), .cur_q1(cur_q1), .cur_q2(cur_q2), .cur_q3(cur_q3),
        .del_i0(del_i0), .del_i1(del_i1), .del_i2(del_i2), .del_i3(del_i3),
        .del_q0(del_q0), .del_q1(del_q1), .del_q2(del_q2), .del_q3(del_q3),
        .delayed_valid(delayed_valid),
        .buf_mode(), .buf_valid(), .wr_ptr()
    );

    // -----------------------------------------------------------------------
    // Stage 3: Energy measurement
    // -----------------------------------------------------------------------
    wire [31:0] energy_sum_0, energy_sum_1, energy_sum_2, energy_sum_3;
    wire [15:0] energy_snap_0, energy_snap_1, energy_snap_2, energy_snap_3;
    wire        energy_valid, energy_snapshot_valid;

    energy_meas u_em (
        .clk_32m(clk),      .rst_n(rst_n),
        .iq_i_0(dcr_i0),  .iq_i_1(dcr_i1),  .iq_i_2(dcr_i2),  .iq_i_3(dcr_i3),
        .iq_q_0(dcr_q0),  .iq_q_1(dcr_q1),  .iq_q_2(dcr_q2),  .iq_q_3(dcr_q3),
        .iq_valid(dcr_valid),
        .sf(4'd7),          .sc_lock(sc_lock),
        .energy_sum_0(energy_sum_0), .energy_sum_1(energy_sum_1),
        .energy_sum_2(energy_sum_2), .energy_sum_3(energy_sum_3),
        .energy_0(energy_snap_0),    .energy_1(energy_snap_1),
        .energy_2(energy_snap_2),    .energy_3(energy_snap_3),
        .energy_valid(energy_valid),
        .energy_snapshot_valid(energy_snapshot_valid)
    );

    // -----------------------------------------------------------------------
    // Stage 4: Noise floor estimator
    // -----------------------------------------------------------------------
    wire noise_sample_en = energy_valid && !sc_lock;

    wire [15:0] sigma2_hw_0, sigma2_hw_1, sigma2_hw_2, sigma2_hw_3;
    wire [15:0] sigma2_active_0, sigma2_active_1, sigma2_active_2, sigma2_active_3;
    wire        sigma2_valid;
    wire [7:0]  n_updates_nfe;

    noise_floor_est u_nfe (
        .clk_32m(clk),       .rst_n(rst_n),
        .energy_sum_0(energy_sum_0), .energy_sum_1(energy_sum_1),
        .energy_sum_2(energy_sum_2), .energy_sum_3(energy_sum_3),
        .noise_sample_en(noise_sample_en),
        .sf(4'd7),
        .noise_alpha_shift(3'd4),
        .sigma2_sw_0(16'h0), .sigma2_sw_1(16'h0),
        .sigma2_sw_2(16'h0), .sigma2_sw_3(16'h0),
        .sigma2_commit(1'b0),  .sigma2_src(1'b0),  .agc_gain_changed(1'b0),
        .sigma2_hw_0(sigma2_hw_0), .sigma2_hw_1(sigma2_hw_1),
        .sigma2_hw_2(sigma2_hw_2), .sigma2_hw_3(sigma2_hw_3),
        .sigma2_active_0(sigma2_active_0), .sigma2_active_1(sigma2_active_1),
        .sigma2_active_2(sigma2_active_2), .sigma2_active_3(sigma2_active_3),
        .sigma2_valid(sigma2_valid),
        .n_updates(n_updates_nfe)
    );

    // -----------------------------------------------------------------------
    // Stage 5: Schmidl-Cox preamble detector
    // -----------------------------------------------------------------------
    wire [31:0] timing_ref;
    wire signed [31:0] c_i0, c_q0;

    sc_detector u_sc (
        .clk(clk),           .rst_n(rst_n),
        .iq_valid(dcr_valid),
        .delayed_valid(delayed_valid),
        .sf(4'd7),
        .sc_thr(16'd32),    // realistic threshold for real capture
        .sc_hits_req(2'd1),
        .sc_clr(1'b0),
        .sc_lock(sc_lock),
        .timing_ref(timing_ref),
        .c_i0(c_i0), .c_q0(c_q0),
        .sc_stat(), .sc_hit_dbg(),
        .sc_hit_hold    (), .sc_hit_count_dbg(),
        .sc_first_hit_dbg(), .sc_lock_sample_dbg()
    );

    // -----------------------------------------------------------------------
    // Stage 6: Training accumulator
    // -----------------------------------------------------------------------
    wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3;
    wire        training_done;
    wire [15:0]  n_acc;

    training_acc u_tacc (
        .clk(clk),           .rst_n(rst_n),
        .iq_valid(dcr_valid),
        .raw_i0(dcr_i0), .raw_i1(dcr_i1), .raw_i2(dcr_i2), .raw_i3(dcr_i3),
        .raw_q0(dcr_q0), .raw_q1(dcr_q1), .raw_q2(dcr_q2), .raw_q3(dcr_q3),
        .sc_lock(sc_lock),   .timing_ref(timing_ref),
        .Z_i0(Z_i0), .Z_q0(Z_q0), .Z_i1(Z_i1), .Z_q1(Z_q1),
        .Z_i2(Z_i2), .Z_q2(Z_q2), .Z_i3(Z_i3), .Z_q3(Z_q3),
        .training_done(training_done), .n_acc(n_acc)
    );

    // -----------------------------------------------------------------------
    // Stage 7: Weight generator
    // -----------------------------------------------------------------------
    wire signed [15:0] W_hw_re0, W_hw_im0, W_hw_re1, W_hw_im1;
    wire signed [15:0] W_hw_re2, W_hw_im2, W_hw_re3, W_hw_im3;
    wire        W_commit;

    weight_gen u_wgen (
        .clk(clk),           .rst_n(rst_n),
        .training_done(training_done),
        .Z_i0(Z_i0), .Z_q0(Z_q0), .Z_i1(Z_i1), .Z_q1(Z_q1),
        .Z_i2(Z_i2), .Z_q2(Z_q2), .Z_i3(Z_i3), .Z_q3(Z_q3),
        .n_acc(n_acc),
        .wgt_src(1'b0),      .wgt_auto_commit(1'b1),
        .wgt_mode(2'b11),    .antenna_en(4'hF),
        .cal_re0(16'h7FFF),  .cal_im0(16'h0),
        .cal_re1(16'h7FFF),  .cal_im1(16'h0),
        .cal_re2(16'h7FFF),  .cal_im2(16'h0),
        .cal_re3(16'h7FFF),  .cal_im3(16'h0),
        .fw_W_re0(16'h0), .fw_W_im0(16'h0), .fw_W_re1(16'h0), .fw_W_im1(16'h0),
        .fw_W_re2(16'h0), .fw_W_im2(16'h0), .fw_W_re3(16'h0), .fw_W_im3(16'h0),
        .fw_W_commit(1'b0),
        .W_hw_re0(W_hw_re0), .W_hw_im0(W_hw_im0),
        .W_hw_re1(W_hw_re1), .W_hw_im1(W_hw_im1),
        .W_hw_re2(W_hw_re2), .W_hw_im2(W_hw_im2),
        .W_hw_re3(W_hw_re3), .W_hw_im3(W_hw_im3),
        .W_shadow_re0(), .W_shadow_im0(), .W_shadow_re1(), .W_shadow_im1(),
        .W_shadow_re2(), .W_shadow_im2(), .W_shadow_re3(), .W_shadow_im3(),
        .W_commit(W_commit),
        .wgen_hw_done(), .wgen_active(), .wgen_mode_dbg()
    );

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
        .clk_16m(clk),      .rst_n(rst_n),
        .x_i0(dcr_i0), .x_q0(dcr_q0),
        .x_i1(dcr_i1), .x_q1(dcr_q1),
        .x_i2(dcr_i2), .x_q2(dcr_q2),
        .x_i3(dcr_i3), .x_q3(dcr_q3),
        .x_valid(dcr_valid),
        .W_re0      (W_hw_re0[15:8]), .W_im0      (W_hw_im0[15:8]),
        .W_re1      (W_hw_re1[15:8]), .W_im1      (W_hw_im1[15:8]),
        .W_re2      (W_hw_re2[15:8]), .W_im2      (W_hw_im2[15:8]),
        .W_re3      (W_hw_re3[15:8]), .W_im3      (W_hw_im3[15:8]),
        .W_valid(W_valid),
        .mode(1'b0),        .bypass_ant(2'd0),
        .post_gain_shift(3'd0),
        .y_i(y_i),          .y_q(y_q),          .y_valid(y_valid)
    );

    // -----------------------------------------------------------------------
    // Stage 9: SD remodulator
    // -----------------------------------------------------------------------
    wire out_i, out_q;

    sd_remod u_remod (
        .clk_32m(clk),  .rst_n(rst_n),
        .in_i(y_i),     .in_q(y_q),
        .in_valid(y_valid),
        .en(1'b1),
        .out_i(out_i),  .out_q(out_q)
    );

    // -----------------------------------------------------------------------
    // Test control
    // -----------------------------------------------------------------------
    integer cycle_count;
    integer pass_count, fail_count;
    integer t_energy_valid, t_sigma2_valid;
    integer t_sc_lock, t_train_done, t_w_commit, t_y_valid;
    reg     test_done;
    reg     out_i_seen_0, out_i_seen_1;

    initial begin
        cycle_count    = 0;
        pass_count     = 0;
        fail_count     = 0;
        t_energy_valid = -1;
        t_sigma2_valid = -1;
        t_sc_lock      = -1;
        t_train_done   = -1;
        t_w_commit     = -1;
        t_y_valid      = -1;
        test_done      = 1'b0;
        out_i_seen_0   = 1'b0;
        out_i_seen_1   = 1'b0;
    end

    always @(posedge clk) if (rst_n) cycle_count <= cycle_count + 1;

    // Total clock cycles for all 15,000 chip samples at 20 cycles/sample
    // = 300,000 cycles + pipeline flush margin
    localparam TIMEOUT = 360000;

    // Test 1: energy_valid
    always @(posedge clk) begin
        if (rst_n && energy_valid && t_energy_valid < 0) begin
            t_energy_valid = cycle_count;
            $display("PASS test1: energy_valid at cycle %0d  energy_sum_0=%0d",
                     cycle_count, energy_sum_0);
            pass_count = pass_count + 1;
        end
    end

    // Test 2: sigma2_valid before sc_lock
    always @(posedge clk) begin
        if (rst_n && sigma2_valid && t_sigma2_valid < 0) begin
            t_sigma2_valid = cycle_count;
            if (!sc_lock) begin
                $display("PASS test2: sigma2_valid at cycle %0d (before sc_lock)  sigma2_hw_0=%0d",
                         cycle_count, sigma2_hw_0);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test2: sigma2_valid at cycle %0d but sc_lock already high",
                         cycle_count);
                fail_count = fail_count + 1;
            end
        end
    end

    // Test 3: sc_lock
    always @(posedge clk) begin
        if (rst_n && sc_lock && t_sc_lock < 0) begin
            t_sc_lock = cycle_count;
            $display("PASS test3: sc_lock at cycle %0d  timing_ref=%0d",
                     cycle_count, timing_ref);
            pass_count = pass_count + 1;
        end
    end

    // Test 4: training_done within 20000 cycles of sc_lock
    always @(posedge clk) begin
        if (rst_n && training_done && t_train_done < 0) begin
            t_train_done = cycle_count;
            if (t_sc_lock >= 0 && (cycle_count - t_sc_lock) <= 20000) begin
                $display("PASS test4: training_done at cycle %0d (%0d after sc_lock)",
                         cycle_count, cycle_count - t_sc_lock);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test4: training_done at cycle %0d  t_sc_lock=%0d",
                         cycle_count, t_sc_lock);
                fail_count = fail_count + 1;
            end
        end
    end

    // Test 5: W_commit within 200 cycles of training_done; W_hw_re0 != 0
    always @(posedge clk) begin
        if (rst_n && W_commit && t_w_commit < 0) begin
            t_w_commit = cycle_count;
            if (t_train_done >= 0 && (cycle_count - t_train_done) <= 200
                    && W_hw_re0 !== 16'h0) begin
                $display("PASS test5: W_commit at cycle %0d (%0d after training_done)  W=[%0d %0d %0d %0d]",
                         cycle_count, cycle_count - t_train_done,
                         W_hw_re0, W_hw_re1, W_hw_re2, W_hw_re3);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test5: W_commit at cycle %0d  t_train_done=%0d  W_hw_re0=%0d",
                         cycle_count, t_train_done, W_hw_re0);
                fail_count = fail_count + 1;
            end
        end
    end

    // Test 6: y_valid within 30 cycles of W_commit
    always @(posedge clk) begin
        if (rst_n && y_valid && t_w_commit >= 0 && t_y_valid < 0) begin
            t_y_valid = cycle_count;
            if ((cycle_count - t_w_commit) <= 30) begin
                $display("PASS test6: y_valid at cycle %0d (%0d after W_commit)  y_i=%0d y_q=%0d",
                         cycle_count, cycle_count - t_w_commit,
                         $signed(y_i), $signed(y_q));
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL test6: y_valid at cycle %0d (%0d after W_commit)",
                         cycle_count, cycle_count - t_w_commit);
                fail_count = fail_count + 1;
            end
        end
    end

    // Test 7: sd_remod out_i toggles within 64 cycles of y_valid
    always @(posedge clk) begin
        if (!rst_n) begin
            out_i_seen_0 <= 1'b0;
            out_i_seen_1 <= 1'b0;
        end else if (t_y_valid >= 0 && !test_done) begin
            if (out_i == 1'b0) out_i_seen_0 <= 1'b1;
            if (out_i == 1'b1) out_i_seen_1 <= 1'b1;
            if (out_i_seen_0 && out_i_seen_1) begin
                test_done = 1'b1;
                $display("PASS test7: sd_remod out_i toggles at cycle %0d (%0d after y_valid)",
                         cycle_count, cycle_count - t_y_valid);
                pass_count = pass_count + 1;
                #1;
                $display("------------------------------------------------------------");
                $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
                $display("------------------------------------------------------------");
                $finish;
            end
            if ((cycle_count - t_y_valid) == 64 && !(out_i_seen_0 && out_i_seen_1)) begin
                test_done = 1'b1;
                $display("FAIL test7: sd_remod out_i stuck at %0d", out_i);
                fail_count = fail_count + 1;
                #1;
                $display("------------------------------------------------------------");
                $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
                $display("------------------------------------------------------------");
                $finish;
            end
        end
    end

    // Timeout / stimulus exhausted
    always @(posedge clk) begin
        if (cycle_count == TIMEOUT || (stim_idx >= stim_n && stim_n > 0
                                       && cycle_count > 1000 && !test_done)) begin
            if (cycle_count == TIMEOUT)
                $display("TIMEOUT at cycle %0d", cycle_count);
            else
                $display("STIMULUS EXHAUSTED at cycle %0d (%0d samples)",
                         cycle_count, stim_n);
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
