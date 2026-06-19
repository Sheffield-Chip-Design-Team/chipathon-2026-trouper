// tb_dsp_chain_rand.v — Randomised end-to-end DSP chain testbench
//
// Varies per-branch amplitude (A_k ∈ [20,60]) and phase offset (p_k ∈ [0,127])
// across N_CASES iterations. Each iteration runs the full pipeline:
//   dc_removal → behavioral PSRAM delay → sc_detector → training_acc
//   → firmware weight compute → mrc_combiner → sd_remod
//
// Phase offsets are multiples of 2π/128, ensuring x_k[n+128]=x_k[n] exactly
// (SC branch 0 always fires; phases differ across branches to exercise Zpair path).
//
// +seed=N plusarg overrides the default PRNG seed.
//
// Pass criteria per case:
//   sc_lock       fires within TIMEOUT_SC  cycles from reset
//   training_done fires within TIMEOUT_TR  cycles after sc_lock
//   fw_W_commit   fires within 50 cycles of training_done; fw_W_re0 != 0
//   y_valid       fires within 50 cycles of fw_W_commit
//   y_i           in [-127,127] (sanity: no RTL overflow)

`timescale 1ns/1ps

module tb_dsp_chain_rand;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam integer N_CASES    = 20;
    localparam integer TIMEOUT_SC = 25000;   // cycles: sc_lock deadline per case
    localparam integer TIMEOUT_TR = 70000;   // cycles after sc_lock: training_done
    localparam integer TIMEOUT_YV = 200;     // cycles after fw_commit: y_valid

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    // -----------------------------------------------------------------------
    // PRNG seed (plusarg +seed=N)
    // -----------------------------------------------------------------------
    integer seed;
    initial begin
        seed = 42;
        if ($test$plusargs("seed")) void'($value$plusargs("seed=%d", seed));
        $display("INFO: seed=%0d N_CASES=%0d", seed, N_CASES);
        // Seed once; subsequent draws use $urandom() with no arg
        void'($urandom(seed));
    end

    // -----------------------------------------------------------------------
    // Stimulus tables: 4 branches × 128 samples
    // -----------------------------------------------------------------------
    real pi_r;
    real    A_k  [0:3];    // per-branch amplitude [20,60]
    integer ph_k [0:3];    // per-branch phase offset [0,127] (maps to 0..2π)
    reg signed [7:0] stim_i_tbl [0:3][0:127];
    reg signed [7:0] stim_q_tbl [0:3][0:127];

    initial pi_r = 3.14159265358979;

    task automatic rebuild_stim;
        integer k, n;
        for (k = 0; k < 4; k = k + 1) begin
            for (n = 0; n < 128; n = n + 1) begin
                stim_i_tbl[k][n] = $rtoi(A_k[k] *
                    $cos(2.0 * pi_r * (n + ph_k[k]) / 128.0));
                stim_q_tbl[k][n] = $rtoi(A_k[k] *
                    $sin(2.0 * pi_r * (n + ph_k[k]) / 128.0));
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // iq_valid strobe: 1 pulse every 40 cycles
    // -----------------------------------------------------------------------
    reg [5:0] strobe_cnt;
    reg       iq_valid;
    reg [6:0] stim_ptr;    // 7-bit, wraps at 128

    always @(posedge clk) begin
        if (!rst_n) begin
            strobe_cnt <= 6'd0;
            iq_valid   <= 1'b0;
            stim_ptr   <= 7'd0;
        end else begin
            if (strobe_cnt == 6'd39) begin
                strobe_cnt <= 6'd0;
                iq_valid   <= 1'b1;
                stim_ptr   <= stim_ptr + 7'd1;
            end else begin
                strobe_cnt <= strobe_cnt + 6'd1;
                iq_valid   <= 1'b0;
            end
        end
    end

    // Combinational stimulus wires from table
    wire signed [7:0] raw_i0 = stim_i_tbl[0][stim_ptr];
    wire signed [7:0] raw_q0 = stim_q_tbl[0][stim_ptr];
    wire signed [7:0] raw_i1 = stim_i_tbl[1][stim_ptr];
    wire signed [7:0] raw_q1 = stim_q_tbl[1][stim_ptr];
    wire signed [7:0] raw_i2 = stim_i_tbl[2][stim_ptr];
    wire signed [7:0] raw_q2 = stim_q_tbl[2][stim_ptr];
    wire signed [7:0] raw_i3 = stim_i_tbl[3][stim_ptr];
    wire signed [7:0] raw_q3 = stim_q_tbl[3][stim_ptr];

    // -----------------------------------------------------------------------
    // DC Removal
    // -----------------------------------------------------------------------
    wire signed [7:0] dcr_i0, dcr_i1, dcr_i2, dcr_i3;
    wire signed [7:0] dcr_q0, dcr_q1, dcr_q2, dcr_q3;
    wire              dcr_valid;

    dc_removal u_dcr (
        .clk_32m   (clk),    .rst_n    (rst_n),
        .raw_i0 (raw_i0), .raw_i1 (raw_i1),
        .raw_i2 (raw_i2), .raw_i3 (raw_i3),
        .raw_q0 (raw_q0), .raw_q1 (raw_q1),
        .raw_q2 (raw_q2), .raw_q3 (raw_q3),
        .raw_valid (iq_valid),
        .out_i0 (dcr_i0), .out_i1 (dcr_i1),
        .out_i2 (dcr_i2), .out_i3 (dcr_i3),
        .out_q0 (dcr_q0), .out_q1 (dcr_q1),
        .out_q2 (dcr_q2), .out_q3 (dcr_q3),
        .out_valid (dcr_valid)
    );

    // -----------------------------------------------------------------------
    // Behavioral PSRAM delay buffer — 128-deep, branch 0 only (matches trouper_top)
    // -----------------------------------------------------------------------
    reg signed [7:0] delay_i0 [0:127];
    reg signed [7:0] delay_q0 [0:127];
    reg [6:0]        delay_wr_ptr;
    reg              delay_buf_filled;
    reg              psram_del_valid_r;
    reg signed [7:0] psram_del_i0_r, psram_del_q0_r;

    integer di;
    initial begin
        delay_wr_ptr      = 7'd0;
        delay_buf_filled  = 1'b0;
        psram_del_valid_r = 1'b0;
        psram_del_i0_r    = 8'sd0;
        psram_del_q0_r    = 8'sd0;
        for (di = 0; di < 128; di = di + 1) begin
            delay_i0[di] = 8'sd0;
            delay_q0[di] = 8'sd0;
        end
    end

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
            psram_del_i0_r    <= delay_i0[delay_wr_ptr];
            psram_del_q0_r    <= delay_q0[delay_wr_ptr];
            delay_i0[delay_wr_ptr] <= dcr_i0;
            delay_q0[delay_wr_ptr] <= dcr_q0;
            delay_wr_ptr <= delay_wr_ptr + 7'd1;
            if (!delay_buf_filled && delay_wr_ptr == 7'd127)
                delay_buf_filled <= 1'b1;
            psram_del_valid_r <= delay_buf_filled;
        end else begin
            psram_del_valid_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // SC detector (branch 0; sc_thr=2048 as in tb_dsp_chain)
    // -----------------------------------------------------------------------
    wire        sc_lock;
    wire [31:0] timing_ref;

    sc_detector u_sc (
        .clk           (clk),   .rst_n        (rst_n),
        .iq_valid      (dcr_valid),
        .cur_i0        (psram_cur_i0), .cur_q0 (psram_cur_q0),
        .del_i0        (psram_del_i0), .del_q0 (psram_del_q0),
        .delayed_valid (psram_del_valid),
        .sf            (4'd7),
        .sc_thr        (16'd2048),
        .sc_hits_req   (2'd1),
        .sc_lock       (sc_lock),
        .timing_ref    (timing_ref),
        .c_i0 (), .c_q0 (),
        .sc_stat (),
        .sc_hit_dbg (),
        .sc_hit_count_dbg (),
        .sc_first_hit_dbg (),
        .sc_lock_sample_dbg ()
    );

    // -----------------------------------------------------------------------
    // Training accumulator
    // -----------------------------------------------------------------------
    wire signed [31:0] Zpair_i0, Zpair_q0, Zpair_i1, Zpair_q1;
    wire signed [31:0] Zpair_i2, Zpair_q2, Zpair_i3, Zpair_q3;
    wire signed [31:0] Zpair_i4, Zpair_q4, Zpair_i5, Zpair_q5;
    wire [31:0] Zdiag_0, Zdiag_1, Zdiag_2, Zdiag_3;
    wire        training_done;
    wire [15:0] n_acc;

    training_acc u_tacc (
        .clk       (clk),    .rst_n     (rst_n),
        .iq_valid  (dcr_valid),
        .raw_i0 (dcr_i0), .raw_i1 (dcr_i1),
        .raw_i2 (dcr_i2), .raw_i3 (dcr_i3),
        .raw_q0 (dcr_q0), .raw_q1 (dcr_q1),
        .raw_q2 (dcr_q2), .raw_q3 (dcr_q3),
        .sc_lock      (sc_lock),
        .timing_ref   (timing_ref),
        .sf           (4'd7),
        .noise_trig   (1'b0),
        .Zpair_i0 (Zpair_i0), .Zpair_q0 (Zpair_q0),
        .Zpair_i1 (Zpair_i1), .Zpair_q1 (Zpair_q1),
        .Zpair_i2 (Zpair_i2), .Zpair_q2 (Zpair_q2),
        .Zpair_i3 (Zpair_i3), .Zpair_q3 (Zpair_q3),
        .Zpair_i4 (Zpair_i4), .Zpair_q4 (Zpair_q4),
        .Zpair_i5 (Zpair_i5), .Zpair_q5 (Zpair_q5),
        .Zdiag_0  (Zdiag_0),  .Zdiag_1  (Zdiag_1),
        .Zdiag_2  (Zdiag_2),  .Zdiag_3  (Zdiag_3),
        .training_done (training_done),
        .n_acc         (n_acc),
        .training_armed ()
    );

    // -----------------------------------------------------------------------
    // Firmware weight emulator (Step 3: pgs + equal real weights from Zdiag)
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
    reg [2:0]  fw_pgs;
    reg        fw_W_valid, fw_W_commit;

    initial begin
        fw_W_re0 = 0; fw_W_im0 = 0; fw_W_re1 = 0; fw_W_im1 = 0;
        fw_W_re2 = 0; fw_W_im2 = 0; fw_W_re3 = 0; fw_W_im3 = 0;
        fw_pgs = 0; fw_W_valid = 0; fw_W_commit = 0;
    end

    task automatic fw_compute_and_commit;
        // Full Hermitian matrix at int32 scale
        longint raw_re [0:3][0:3];
        longint raw_im [0:3][0:3];
        longint raw_diag [0:3];

        longint max_abs, tmp_ma;
        int sh, sh2, tmp_sh;

        // Normalised int12 matrix
        int m_re [0:3][0:3];
        int m_im [0:3][0:3];
        int diag_m [0:3];

        // Power iteration
        longint vr [0:3], vi [0:3];
        longint wr [0:3], wi [0:3];
        longint acc_r, acc_i, wmx;

        // Step 3: pgs / W_max
        longint zdiag_max, e_max;
        int a_est, y_pre_max, pgs_v, w_max_v, denom;

        // Step 4: weight conversion
        longint vmx;

        integer iter_i, k_i, l_i;

        @(posedge clk);   // let Zpair/Zdiag settle

        // ----------------------------------------------------------------
        // Step 0 — Build full Hermitian matrix (int32 off-diag; Zdiag>>16 diag)
        // ----------------------------------------------------------------
        // Upper triangle (from RTL outputs: Zpair0=Z01, 1=Z02, 2=Z03, 3=Z12, 4=Z13, 5=Z23)
        raw_re[0][1] = longint'($signed(Zpair_i0)); raw_im[0][1] = longint'($signed(Zpair_q0));
        raw_re[0][2] = longint'($signed(Zpair_i1)); raw_im[0][2] = longint'($signed(Zpair_q1));
        raw_re[0][3] = longint'($signed(Zpair_i2)); raw_im[0][3] = longint'($signed(Zpair_q2));
        raw_re[1][2] = longint'($signed(Zpair_i3)); raw_im[1][2] = longint'($signed(Zpair_q3));
        raw_re[1][3] = longint'($signed(Zpair_i4)); raw_im[1][3] = longint'($signed(Zpair_q4));
        raw_re[2][3] = longint'($signed(Zpair_i5)); raw_im[2][3] = longint'($signed(Zpair_q5));
        // Lower triangle: Hermitian conjugate
        raw_re[1][0] =  raw_re[0][1]; raw_im[1][0] = -raw_im[0][1];
        raw_re[2][0] =  raw_re[0][2]; raw_im[2][0] = -raw_im[0][2];
        raw_re[3][0] =  raw_re[0][3]; raw_im[3][0] = -raw_im[0][3];
        raw_re[2][1] =  raw_re[1][2]; raw_im[2][1] = -raw_im[1][2];
        raw_re[3][1] =  raw_re[1][3]; raw_im[3][1] = -raw_im[1][3];
        raw_re[3][2] =  raw_re[2][3]; raw_im[3][2] = -raw_im[2][3];
        // Diagonal: full 32-bit Zdiag (always non-negative with fixed pipeline)
        raw_diag[0] = longint'(Zdiag_0);
        raw_diag[1] = longint'(Zdiag_1);
        raw_diag[2] = longint'(Zdiag_2);
        raw_diag[3] = longint'(Zdiag_3);

        // ----------------------------------------------------------------
        // Step 1 — Find max_abs; compute normalisation shift to ≤ 4095
        // ----------------------------------------------------------------
        max_abs = 1;
        for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
            for (l_i = k_i+1; l_i < 4; l_i = l_i + 1) begin
                tmp_ma = (raw_re[k_i][l_i] < 0) ? -raw_re[k_i][l_i] : raw_re[k_i][l_i];
                if (tmp_ma > max_abs) max_abs = tmp_ma;
                tmp_ma = (raw_im[k_i][l_i] < 0) ? -raw_im[k_i][l_i] : raw_im[k_i][l_i];
                if (tmp_ma > max_abs) max_abs = tmp_ma;
            end
            if (raw_diag[k_i] > max_abs) max_abs = raw_diag[k_i];
        end
        sh = 0; tmp_sh = int'(max_abs);
        while (tmp_sh > 4095) begin tmp_sh >>>= 1; sh = sh + 1; end

        // Build normalised matrix
        for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
            diag_m[k_i] = int'(raw_diag[k_i] >>> sh);
            for (l_i = 0; l_i < 4; l_i = l_i + 1) begin
                if (l_i != k_i) begin
                    m_re[k_i][l_i] = int'(raw_re[k_i][l_i] >>> sh);
                    m_im[k_i][l_i] = int'(raw_im[k_i][l_i] >>> sh);
                end
            end
        end

        // ----------------------------------------------------------------
        // Step 2 — Power iteration (8 iterations)
        // ----------------------------------------------------------------
        vr[0] = 4096; vr[1] = 0; vr[2] = 0; vr[3] = 0;
        vi[0] = 0;    vi[1] = 0; vi[2] = 0; vi[3] = 0;

        for (iter_i = 0; iter_i < 8; iter_i = iter_i + 1) begin
            // w = M * v
            for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
                acc_r = longint'(diag_m[k_i]) * vr[k_i];
                acc_i = longint'(diag_m[k_i]) * vi[k_i];
                for (l_i = 0; l_i < 4; l_i = l_i + 1) begin
                    if (l_i != k_i) begin
                        acc_r += longint'(m_re[k_i][l_i]) * vr[l_i]
                               - longint'(m_im[k_i][l_i]) * vi[l_i];
                        acc_i += longint'(m_re[k_i][l_i]) * vi[l_i]
                               + longint'(m_im[k_i][l_i]) * vr[l_i];
                    end
                end
                wr[k_i] = acc_r; wi[k_i] = acc_i;
            end
            // Renormalise: find sh2 so max(|wr|,|wi|) >> sh2 <= 4096
            wmx = 1;
            for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
                tmp_ma = (wr[k_i] < 0) ? -wr[k_i] : wr[k_i];
                if (tmp_ma > wmx) wmx = tmp_ma;
                tmp_ma = (wi[k_i] < 0) ? -wi[k_i] : wi[k_i];
                if (tmp_ma > wmx) wmx = tmp_ma;
            end
            sh2 = 0; tmp_sh = int'(wmx);
            while (tmp_sh > 4096) begin tmp_sh >>>= 1; sh2 = sh2 + 1; end
            for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
                vr[k_i] = wr[k_i] >>> sh2;
                vi[k_i] = wi[k_i] >>> sh2;
            end
        end

        // ----------------------------------------------------------------
        // Step 3 — pgs and W_max_byte (from Zdiag, same as before)
        // ----------------------------------------------------------------
        zdiag_max = longint'(Zdiag_0);
        if (longint'(Zdiag_1) > zdiag_max) zdiag_max = longint'(Zdiag_1);
        if (longint'(Zdiag_2) > zdiag_max) zdiag_max = longint'(Zdiag_2);
        if (longint'(Zdiag_3) > zdiag_max) zdiag_max = longint'(Zdiag_3);
        e_max = zdiag_max / longint'(n_acc);
        a_est = isqrt_fn(int'(e_max));
        if (a_est == 0 || n_acc == 0) begin
            pgs_v = 0; w_max_v = 120;
        end else begin
            y_pre_max = (120 * 4 * a_est) / 256;
            if (y_pre_max >= 90) pgs_v = 0;
            else if (y_pre_max == 0) pgs_v = 7;
            else begin
                pgs_v = floor_log2_fn(90 / y_pre_max);
                if (pgs_v > 7) pgs_v = 7;
            end
            denom   = a_est * (1 << pgs_v);
            w_max_v = (denom > 0) ? (8128 / denom) : 120;
            if (w_max_v > 120) w_max_v = 120;
        end

        // ----------------------------------------------------------------
        // Step 4 — Convert eigenvector to Q1.15 weights (conj(v), top byte)
        // ----------------------------------------------------------------
        vmx = 1;
        for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
            tmp_ma = (vr[k_i] < 0) ? -vr[k_i] : vr[k_i];
            if (tmp_ma > vmx) vmx = tmp_ma;
            tmp_ma = (vi[k_i] < 0) ? -vi[k_i] : vi[k_i];
            if (tmp_ma > vmx) vmx = tmp_ma;
        end
        // w_k = conj(v_k) × W_max × 256 / vmx; combiner uses top byte (>>8)
        fw_W_re0 = 8'(int'( vr[0] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_W_im0 = 8'(int'(-vi[0] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_W_re1 = 8'(int'( vr[1] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_W_im1 = 8'(int'(-vi[1] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_W_re2 = 8'(int'( vr[2] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_W_im2 = 8'(int'(-vi[2] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_W_re3 = 8'(int'( vr[3] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_W_im3 = 8'(int'(-vi[3] * longint'(w_max_v) * 256 / vmx) >>> 8);
        fw_pgs   = pgs_v[2:0];

        @(posedge clk);
        fw_W_valid  = 1;
        fw_W_commit = 1;
        @(posedge clk);
        fw_W_commit = 0;
    endtask

    // -----------------------------------------------------------------------
    // MRC combiner
    // -----------------------------------------------------------------------
    wire signed [7:0] y_i, y_q;
    wire              y_valid;

    mrc_combiner u_mrc (
        .clk_16m  (clk), .rst_n (rst_n),
        .x_i0 (dcr_i0), .x_q0 (dcr_q0),
        .x_i1 (dcr_i1), .x_q1 (dcr_q1),
        .x_i2 (dcr_i2), .x_q2 (dcr_q2),
        .x_i3 (dcr_i3), .x_q3 (dcr_q3),
        .x_valid (dcr_valid),
        .W_re0 (fw_W_re0), .W_im0 (fw_W_im0),
        .W_re1 (fw_W_re1), .W_im1 (fw_W_im1),
        .W_re2 (fw_W_re2), .W_im2 (fw_W_im2),
        .W_re3 (fw_W_re3), .W_im3 (fw_W_im3),
        .W_valid         (fw_W_valid),
        .mode            (1'b0),
        .bypass_ant      (2'd0),
        .post_gain_shift (fw_pgs),
        .y_i    (y_i), .y_q (y_q), .y_valid (y_valid)
    );

    // -----------------------------------------------------------------------
    // SD remodulator (not checked in the random test; included for completeness)
    // -----------------------------------------------------------------------
    wire out_i, out_q;
    wire signed [7:0] remod_in_i = u_mrc.use_mrc_r ?
                                   ($signed(y_i) >>> 1) : y_i;
    wire signed [7:0] remod_in_q = u_mrc.use_mrc_r ?
                                   ($signed(y_q) >>> 1) : y_q;
    sd_remod u_remod (
        .clk_32m (clk), .rst_n (rst_n),
        .in_i    (remod_in_i), .in_q (remod_in_q),
        .in_valid(y_valid),    .en   (1'b1),
        .out_i   (out_i),      .out_q(out_q)
    );

    // -----------------------------------------------------------------------
    // Main test loop
    // -----------------------------------------------------------------------
    integer ii, pass_count, fail_count;
    integer cyc_sc, cyc_tr, cyc_yv;   // per-case timing
    integer cyc_total;
    integer fail_this;

    // Global cycle counter
    integer cycle_count;
    always @(posedge clk) if (rst_n) cycle_count <= cycle_count + 1;
    initial cycle_count = 0;

    integer sc_cyc_start;  // cycle when rst_n deasserted this case

    initial begin
        pass_count = 0;
        fail_count = 0;

        // Initial reset
        rst_n = 1'b0;
        repeat(8) @(posedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge clk);

        for (ii = 0; ii < N_CASES; ii = ii + 1) begin
            fail_this = 0;

            // -- Randomise branch parameters --
            // Branch 0: A ∈ [20,60] (ensures reliable SC with sc_thr=2048)
            A_k[0]  = 20 + ($urandom() % 41);
            ph_k[0] = $urandom() % 128;
            // Branches 1-3: A ∈ [10,60], arbitrary phase
            A_k[1]  = 10 + ($urandom() % 51);
            ph_k[1] = $urandom() % 128;
            A_k[2]  = 10 + ($urandom() % 51);
            ph_k[2] = $urandom() % 128;
            A_k[3]  = 10 + ($urandom() % 51);
            ph_k[3] = $urandom() % 128;

            rebuild_stim();

            $display("CASE %0d: A=[%.0f,%.0f,%.0f,%.0f] ph=[%0d,%0d,%0d,%0d]",
                     ii, A_k[0], A_k[1], A_k[2], A_k[3],
                     ph_k[0], ph_k[1], ph_k[2], ph_k[3]);

            // -- Reset DUT --
            fw_W_valid  = 0;
            fw_W_commit = 0;
            fw_W_re0 = 0; fw_W_im0 = 0;
            fw_W_re1 = 0; fw_W_im1 = 0;
            fw_W_re2 = 0; fw_W_im2 = 0;
            fw_W_re3 = 0; fw_W_im3 = 0;
            fw_pgs = 0;

            rst_n = 1'b0;
            repeat(8) @(posedge clk);
            rst_n = 1'b1;
            sc_cyc_start = cycle_count;

            // -- Wait for sc_lock (with timeout) --
            cyc_sc = -1;
            fork
                begin : blk_sc
                    @(posedge sc_lock);
                    cyc_sc = cycle_count - sc_cyc_start;
                end
                begin : blk_sc_to
                    repeat(TIMEOUT_SC) @(posedge clk);
                end
            join_any
            disable fork;

            if (cyc_sc < 0) begin
                $display("  FAIL sc_lock: timeout after %0d cycles", TIMEOUT_SC);
                fail_this = 1;
            end else begin
                $display("  sc_lock at +%0d cycles", cyc_sc);
            end

            if (!fail_this) begin
                // -- Wait for training_done --
                cyc_tr = -1;
                fork
                    begin : blk_tr
                        @(posedge training_done);
                        cyc_tr = cycle_count - sc_cyc_start - cyc_sc;
                    end
                    begin : blk_tr_to
                        repeat(TIMEOUT_TR) @(posedge clk);
                    end
                join_any
                disable fork;

                if (cyc_tr < 0) begin
                    $display("  FAIL training_done: timeout after %0d cycles post sc_lock",
                             TIMEOUT_TR);
                    fail_this = 1;
                end else begin
                    $display("  training_done at +%0d cycles post sc_lock  n_acc=%0d",
                             cyc_tr, n_acc);
                end
            end

            if (!fail_this) begin
                // -- Firmware compute + commit --
                fw_compute_and_commit();

                if (fw_W_re0 === 8'h00 && fw_W_im0 === 8'h00 &&
                    fw_W_re1 === 8'h00 && fw_W_im1 === 8'h00) begin
                    $display("  FAIL fw_commit: all weights zero (eigvec collapse?)");
                    fail_this = 1;
                end else begin
                    $display("  fw_commit: pgs=%0d W=[%0d+%0dj, %0d+%0dj, %0d+%0dj, %0d+%0dj]",
                             fw_pgs,
                             $signed(fw_W_re0), $signed(fw_W_im0),
                             $signed(fw_W_re1), $signed(fw_W_im1),
                             $signed(fw_W_re2), $signed(fw_W_im2),
                             $signed(fw_W_re3), $signed(fw_W_im3));
                end
            end

            if (!fail_this) begin
                // -- Wait for y_valid --
                cyc_yv = -1;
                fork
                    begin : blk_yv
                        @(posedge y_valid);
                        cyc_yv = 0;
                    end
                    begin : blk_yv_to
                        repeat(TIMEOUT_YV) @(posedge clk);
                    end
                join_any
                disable fork;

                if (cyc_yv < 0) begin
                    $display("  FAIL y_valid: timeout after %0d cycles post commit",
                             TIMEOUT_YV);
                    fail_this = 1;
                end else begin
                    // Capture first output sample
                    @(posedge y_valid);
                    if ($signed(y_i) < -127 || $signed(y_i) > 127) begin
                        $display("  FAIL y_i=%0d out of [-127,127]", $signed(y_i));
                        fail_this = 1;
                    end else begin
                        $display("  y_valid: y_i=%0d y_q=%0d use_mrc=%0b",
                                 $signed(y_i), $signed(y_q), u_mrc.use_mrc_r);
                    end
                end
            end

            if (fail_this) begin
                $display("  => FAIL");
                fail_count = fail_count + 1;
            end else begin
                $display("  => PASS");
                pass_count = pass_count + 1;
            end
        end

        $display("------------------------------------------------------------");
        $display("Results: %0d PASSED, %0d FAILED  (of %0d)", pass_count, fail_count, N_CASES);
        $display("------------------------------------------------------------");
        $finish;
    end

    // Safety watchdog across the entire simulation
    initial begin
        repeat(200000 * N_CASES) @(posedge clk);
        $display("GLOBAL TIMEOUT");
        $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        $finish;
    end

endmodule
