// tb_dsp_chain_sf.v — BW × SF sweep: {125 kHz, 250 kHz} × SF 7–12
//
// Tests the full DSP chain (DCR → SC detector → training_acc →
// firmware eigenvector MRC → mrc_combiner → sd_remod) across both
// supported LoRa bandwidths and all spreading factors.
//
// BW mapping (CIC decimation at the ASIC boundary):
//   BW mode 0 — 125 kHz LoRa: decim_ratio=0 (R=256), CIC output at 125 kHz,
//                              1 sample/chip → stim_period = 2^SF
//   BW mode 1 — 250 kHz LoRa: decim_ratio=1 (R=128), CIC output at 250 kHz,
//                              1 sample/chip → stim_period = 2^SF
//
// From the sample domain both BWs look identical (same samples/chip). The
// difference is noise bandwidth: R=128 passes twice the noise power of R=256
// (~3 dB penalty for 250 kHz mode). This testbench models that difference by
// injecting approximate AWGN using a 4-uniform CLT sum per I/Q branch sample:
//   noise ≈ (u0 + u1 + u2 + u3) / 2, with each u_k uniform in [-noise_sigma,+noise_sigma]
//   BW mode 0 (125 kHz, R=256): noise_sigma = 3
//   BW mode 1 (250 kHz, R=128): noise_sigma = 5  (≈ +4 dB, conservative)
//
// All timing scales with 2^SF:
//   PSRAM delay buffer  : 2^SF deep (max 4096 for SF12)
//   TIMEOUT_SC          : 600 × 2^SF cycles
//   TIMEOUT_TR          : 640 × 2^SF cycles (≥ 2× training window 2^(SF+3))
//
// Pass criteria per case:
//   sc_lock       fires within TIMEOUT_SC
//   training_done fires within TIMEOUT_TR after sc_lock
//   fw_W_commit   non-zero weights
//   y_i           ∈ [−127, 127]

`timescale 1ns/1ps

module tb_dsp_chain_sf;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam integer N_CASES_PER_SF = 5;
    localparam integer SF_MIN         = 7;
    localparam integer SF_MAX         = 12;
    localparam integer N_BW           = 2;
    localparam integer MAX_SYMS       = 1 << SF_MAX;   // 4096
    localparam integer TIMEOUT_YV     = 200;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    // -----------------------------------------------------------------------
    // PRNG seed
    // -----------------------------------------------------------------------
    integer seed;
    initial begin
        seed = 42;
        if ($test$plusargs("seed")) void'($value$plusargs("seed=%d", seed));
        $display("INFO: seed=%0d N_CASES_PER_SF=%0d SF=%0d..%0d BW=125k+250k",
                 seed, N_CASES_PER_SF, SF_MIN, SF_MAX);
        void'($urandom(seed));
    end

    // -----------------------------------------------------------------------
    // Stimulus tables: 4 branches × 4096 samples (max SF12)
    // -----------------------------------------------------------------------
    real pi_r;
    real    A_k  [0:3];
    integer ph_k [0:3];
    reg signed [7:0] stim_i_tbl [0:3][0:MAX_SYMS-1];
    reg signed [7:0] stim_q_tbl [0:3][0:MAX_SYMS-1];

    initial pi_r = 3.14159265358979;

    task automatic rebuild_stim;
        input integer sf_v;
        integer k, n, period;
        period = 1 << sf_v;
        for (k = 0; k < 4; k = k + 1)
            for (n = 0; n < period; n = n + 1) begin
                stim_i_tbl[k][n] = $rtoi(A_k[k] *
                    $cos(2.0 * pi_r * (n + ph_k[k]) / period));
                stim_q_tbl[k][n] = $rtoi(A_k[k] *
                    $sin(2.0 * pi_r * (n + ph_k[k]) / period));
            end
    endtask

    // -----------------------------------------------------------------------
    // Noise injection — approximate AWGN per branch via CLT
    // noise_sigma=0 → no noise; set in outer BW loop
    // -----------------------------------------------------------------------
    integer noise_sigma;
    reg signed [7:0] n_i0_r, n_q0_r;
    reg signed [7:0] n_i1_r, n_q1_r;
    reg signed [7:0] n_i2_r, n_q2_r;
    reg signed [7:0] n_i3_r, n_q3_r;

    initial begin
        noise_sigma = 0;
        n_i0_r = 0; n_q0_r = 0;
        n_i1_r = 0; n_q1_r = 0;
        n_i2_r = 0; n_q2_r = 0;
        n_i3_r = 0; n_q3_r = 0;
    end

    function automatic signed [7:0] approx_awgn8;
        input integer sigma;
        integer acc;
        begin
            if (sigma <= 0) begin
                approx_awgn8 = 8'sd0;
            end else begin
                acc = ($random % (2*sigma+1))
                    + ($random % (2*sigma+1))
                    + ($random % (2*sigma+1))
                    + ($random % (2*sigma+1));
                approx_awgn8 = clamp8v(acc >>> 1);
            end
        end
    endfunction

    always @(posedge clk) begin
        if (noise_sigma > 0) begin
            n_i0_r <= approx_awgn8(noise_sigma);
            n_q0_r <= approx_awgn8(noise_sigma);
            n_i1_r <= approx_awgn8(noise_sigma);
            n_q1_r <= approx_awgn8(noise_sigma);
            n_i2_r <= approx_awgn8(noise_sigma);
            n_q2_r <= approx_awgn8(noise_sigma);
            n_i3_r <= approx_awgn8(noise_sigma);
            n_q3_r <= approx_awgn8(noise_sigma);
        end else begin
            n_i0_r <= 8'sd0; n_q0_r <= 8'sd0;
            n_i1_r <= 8'sd0; n_q1_r <= 8'sd0;
            n_i2_r <= 8'sd0; n_q2_r <= 8'sd0;
            n_i3_r <= 8'sd0; n_q3_r <= 8'sd0;
        end
    end

    function automatic signed [7:0] clamp8v;
        input integer v;
        if      (v >  127) return 8'sd127;
        else if (v < -128) return -8'sd128;
        else               return 8'(v);
    endfunction

    // -----------------------------------------------------------------------
    // iq_valid strobe: 1 pulse every 40 cycles (≈ 800 kHz behavioural rate)
    // stim_ptr wraps at stim_period = 2^sf_cur
    // -----------------------------------------------------------------------
    reg [5:0]  strobe_cnt;
    reg        iq_valid;
    reg [11:0] stim_ptr;
    integer    stim_period;

    always @(posedge clk) begin
        if (!rst_n) begin
            strobe_cnt <= 6'd0;
            iq_valid   <= 1'b0;
            stim_ptr   <= 12'd0;
        end else begin
            if (strobe_cnt == 6'd39) begin
                strobe_cnt <= 6'd0;
                iq_valid   <= 1'b1;
                stim_ptr   <= (stim_ptr == stim_period - 1) ? 12'd0
                                                            : stim_ptr + 12'd1;
            end else begin
                strobe_cnt <= strobe_cnt + 6'd1;
                iq_valid   <= 1'b0;
            end
        end
    end

    wire signed [7:0] raw_i0 = clamp8v(int'(stim_i_tbl[0][stim_ptr]) + int'(n_i0_r));
    wire signed [7:0] raw_q0 = clamp8v(int'(stim_q_tbl[0][stim_ptr]) + int'(n_q0_r));
    wire signed [7:0] raw_i1 = clamp8v(int'(stim_i_tbl[1][stim_ptr]) + int'(n_i1_r));
    wire signed [7:0] raw_q1 = clamp8v(int'(stim_q_tbl[1][stim_ptr]) + int'(n_q1_r));
    wire signed [7:0] raw_i2 = clamp8v(int'(stim_i_tbl[2][stim_ptr]) + int'(n_i2_r));
    wire signed [7:0] raw_q2 = clamp8v(int'(stim_q_tbl[2][stim_ptr]) + int'(n_q2_r));
    wire signed [7:0] raw_i3 = clamp8v(int'(stim_i_tbl[3][stim_ptr]) + int'(n_i3_r));
    wire signed [7:0] raw_q3 = clamp8v(int'(stim_q_tbl[3][stim_ptr]) + int'(n_q3_r));

    // -----------------------------------------------------------------------
    // DC Removal
    // -----------------------------------------------------------------------
    wire signed [7:0] dcr_i0, dcr_i1, dcr_i2, dcr_i3;
    wire signed [7:0] dcr_q0, dcr_q1, dcr_q2, dcr_q3;
    wire              dcr_valid;

    dc_removal u_dcr (
        .clk_32m   (clk),    .rst_n     (rst_n),
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
    // Behavioral PSRAM delay buffer — 2^SF deep (max 4096), branch 0
    // -----------------------------------------------------------------------
    reg signed [7:0] delay_i0 [0:MAX_SYMS-1];
    reg signed [7:0] delay_q0 [0:MAX_SYMS-1];
    reg [11:0]       delay_wr_ptr;
    reg              delay_buf_filled;
    reg              psram_del_valid_r;
    reg signed [7:0] psram_del_i0_r, psram_del_q0_r;

    integer di;
    initial begin
        delay_wr_ptr      = 12'd0;
        delay_buf_filled  = 1'b0;
        psram_del_valid_r = 1'b0;
        psram_del_i0_r    = 8'sd0;
        psram_del_q0_r    = 8'sd0;
        for (di = 0; di < MAX_SYMS; di = di + 1) begin
            delay_i0[di] = 8'sd0;
            delay_q0[di] = 8'sd0;
        end
    end

    wire signed [7:0] psram_del_i0   = psram_del_i0_r;
    wire signed [7:0] psram_del_q0   = psram_del_q0_r;
    wire              psram_del_valid = psram_del_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delay_wr_ptr      <= 12'd0;
            delay_buf_filled  <= 1'b0;
            psram_del_valid_r <= 1'b0;
            psram_del_i0_r    <= 8'sd0;
            psram_del_q0_r    <= 8'sd0;
        end else if (dcr_valid) begin
            psram_del_i0_r        <= delay_i0[delay_wr_ptr];
            psram_del_q0_r        <= delay_q0[delay_wr_ptr];
            delay_i0[delay_wr_ptr] <= dcr_i0;
            delay_q0[delay_wr_ptr] <= dcr_q0;
            if (delay_wr_ptr == stim_period - 1) begin
                delay_wr_ptr     <= 12'd0;
                delay_buf_filled <= 1'b1;
            end else begin
                delay_wr_ptr <= delay_wr_ptr + 12'd1;
            end
            psram_del_valid_r <= delay_buf_filled;
        end else begin
            psram_del_valid_r <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // SC detector
    // -----------------------------------------------------------------------
    reg  [3:0]  sf_cur;
    wire        sc_lock;
    wire [31:0] timing_ref;

    sc_detector u_sc (
        .clk           (clk),         .rst_n        (rst_n),
        .iq_valid      (dcr_valid),
        .cur_i0        (dcr_i0),       .cur_q0       (dcr_q0),
        .del_i0        (psram_del_i0), .del_q0       (psram_del_q0),
        .delayed_valid (psram_del_valid),
        .sf            (sf_cur),
        .sc_thr        (16'd2048),
        .sc_hits_req   (2'd1),
        .sc_clr        (1'b0),
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
        .clk       (clk),     .rst_n     (rst_n),
        .iq_valid  (dcr_valid),
        .raw_i0    (dcr_i0),  .raw_i1    (dcr_i1),
        .raw_i2    (dcr_i2),  .raw_i3    (dcr_i3),
        .raw_q0    (dcr_q0),  .raw_q1    (dcr_q1),
        .raw_q2    (dcr_q2),  .raw_q3    (dcr_q3),
        .sc_lock      (sc_lock),
        .timing_ref   (timing_ref),
        .sf           (sf_cur),
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
    // Firmware weight emulator (eigenvector MRC)
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
        longint raw_re   [0:3][0:3];
        longint raw_im   [0:3][0:3];
        longint raw_diag [0:3];
        longint max_abs, tmp_ma;
        int     sh, sh2, tmp_sh;
        int     m_re   [0:3][0:3];
        int     m_im   [0:3][0:3];
        int     diag_m [0:3];
        longint vr [0:3], vi [0:3], wr [0:3], wi [0:3];
        longint acc_r, acc_i, wmx, vmx;
        longint zdiag_max, e_max;
        int     a_est, y_pre_max, pgs_v, w_max_v, denom;
        integer iter_i, k_i, l_i;

        @(posedge clk);

        // Build Hermitian matrix
        raw_re[0][1]=longint'($signed(Zpair_i0)); raw_im[0][1]=longint'($signed(Zpair_q0));
        raw_re[0][2]=longint'($signed(Zpair_i1)); raw_im[0][2]=longint'($signed(Zpair_q1));
        raw_re[0][3]=longint'($signed(Zpair_i2)); raw_im[0][3]=longint'($signed(Zpair_q2));
        raw_re[1][2]=longint'($signed(Zpair_i3)); raw_im[1][2]=longint'($signed(Zpair_q3));
        raw_re[1][3]=longint'($signed(Zpair_i4)); raw_im[1][3]=longint'($signed(Zpair_q4));
        raw_re[2][3]=longint'($signed(Zpair_i5)); raw_im[2][3]=longint'($signed(Zpair_q5));
        raw_re[1][0]= raw_re[0][1]; raw_im[1][0]=-raw_im[0][1];
        raw_re[2][0]= raw_re[0][2]; raw_im[2][0]=-raw_im[0][2];
        raw_re[3][0]= raw_re[0][3]; raw_im[3][0]=-raw_im[0][3];
        raw_re[2][1]= raw_re[1][2]; raw_im[2][1]=-raw_im[1][2];
        raw_re[3][1]= raw_re[1][3]; raw_im[3][1]=-raw_im[1][3];
        raw_re[3][2]= raw_re[2][3]; raw_im[3][2]=-raw_im[2][3];
        raw_diag[0]=longint'(Zdiag_0); raw_diag[1]=longint'(Zdiag_1);
        raw_diag[2]=longint'(Zdiag_2); raw_diag[3]=longint'(Zdiag_3);

        // Normalise to ≤ 4095 (int12)
        max_abs = 1;
        for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
            for (l_i = k_i+1; l_i < 4; l_i = l_i + 1) begin
                tmp_ma=(raw_re[k_i][l_i]<0)?-raw_re[k_i][l_i]:raw_re[k_i][l_i];
                if (tmp_ma > max_abs) max_abs = tmp_ma;
                tmp_ma=(raw_im[k_i][l_i]<0)?-raw_im[k_i][l_i]:raw_im[k_i][l_i];
                if (tmp_ma > max_abs) max_abs = tmp_ma;
            end
            if (raw_diag[k_i] > max_abs) max_abs = raw_diag[k_i];
        end
        sh = 0; tmp_sh = int'(max_abs);
        while (tmp_sh > 4095) begin tmp_sh >>>= 1; sh = sh + 1; end
        for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
            diag_m[k_i] = int'(raw_diag[k_i] >>> sh);
            for (l_i = 0; l_i < 4; l_i = l_i + 1)
                if (l_i != k_i) begin
                    m_re[k_i][l_i] = int'(raw_re[k_i][l_i] >>> sh);
                    m_im[k_i][l_i] = int'(raw_im[k_i][l_i] >>> sh);
                end
        end

        // Power iteration (8 iterations)
        vr[0]=4096; vr[1]=0; vr[2]=0; vr[3]=0;
        vi[0]=0;    vi[1]=0; vi[2]=0; vi[3]=0;
        for (iter_i = 0; iter_i < 8; iter_i = iter_i + 1) begin
            for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
                acc_r = longint'(diag_m[k_i]) * vr[k_i];
                acc_i = longint'(diag_m[k_i]) * vi[k_i];
                for (l_i = 0; l_i < 4; l_i = l_i + 1)
                    if (l_i != k_i) begin
                        acc_r += longint'(m_re[k_i][l_i])*vr[l_i]
                               - longint'(m_im[k_i][l_i])*vi[l_i];
                        acc_i += longint'(m_re[k_i][l_i])*vi[l_i]
                               + longint'(m_im[k_i][l_i])*vr[l_i];
                    end
                wr[k_i] = acc_r; wi[k_i] = acc_i;
            end
            wmx = 1;
            for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
                tmp_ma=(wr[k_i]<0)?-wr[k_i]:wr[k_i]; if(tmp_ma>wmx) wmx=tmp_ma;
                tmp_ma=(wi[k_i]<0)?-wi[k_i]:wi[k_i]; if(tmp_ma>wmx) wmx=tmp_ma;
            end
            sh2 = 0; tmp_sh = int'(wmx);
            while (tmp_sh > 4096) begin tmp_sh >>>= 1; sh2 = sh2 + 1; end
            for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
                vr[k_i] = wr[k_i] >>> sh2;
                vi[k_i] = wi[k_i] >>> sh2;
            end
        end

        // pgs / W_max
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
            if      (y_pre_max >= 90) pgs_v = 0;
            else if (y_pre_max == 0)  pgs_v = 7;
            else begin
                pgs_v = floor_log2_fn(90 / y_pre_max);
                if (pgs_v > 7) pgs_v = 7;
            end
            denom   = a_est * (1 << pgs_v);
            w_max_v = (denom > 0) ? (8128 / denom) : 120;
            if (w_max_v > 120) w_max_v = 120;
        end

        // Convert eigenvector → conjugate weights (top byte of Q1.15)
        vmx = 1;
        for (k_i = 0; k_i < 4; k_i = k_i + 1) begin
            tmp_ma=(vr[k_i]<0)?-vr[k_i]:vr[k_i]; if(tmp_ma>vmx) vmx=tmp_ma;
            tmp_ma=(vi[k_i]<0)?-vi[k_i]:vi[k_i]; if(tmp_ma>vmx) vmx=tmp_ma;
        end
        fw_W_re0=8'(int'( vr[0]*longint'(w_max_v)*256/vmx)>>>8);
        fw_W_im0=8'(int'(-vi[0]*longint'(w_max_v)*256/vmx)>>>8);
        fw_W_re1=8'(int'( vr[1]*longint'(w_max_v)*256/vmx)>>>8);
        fw_W_im1=8'(int'(-vi[1]*longint'(w_max_v)*256/vmx)>>>8);
        fw_W_re2=8'(int'( vr[2]*longint'(w_max_v)*256/vmx)>>>8);
        fw_W_im2=8'(int'(-vi[2]*longint'(w_max_v)*256/vmx)>>>8);
        fw_W_re3=8'(int'( vr[3]*longint'(w_max_v)*256/vmx)>>>8);
        fw_W_im3=8'(int'(-vi[3]*longint'(w_max_v)*256/vmx)>>>8);
        fw_pgs  = pgs_v[2:0];

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
        .clk_16m         (clk),    .rst_n (rst_n),
        .x_i0 (dcr_i0),  .x_q0 (dcr_q0),
        .x_i1 (dcr_i1),  .x_q1 (dcr_q1),
        .x_i2 (dcr_i2),  .x_q2 (dcr_q2),
        .x_i3 (dcr_i3),  .x_q3 (dcr_q3),
        .x_valid         (dcr_valid),
        .W_re0 (fw_W_re0), .W_im0 (fw_W_im0),
        .W_re1 (fw_W_re1), .W_im1 (fw_W_im1),
        .W_re2 (fw_W_re2), .W_im2 (fw_W_im2),
        .W_re3 (fw_W_re3), .W_im3 (fw_W_im3),
        .W_valid         (fw_W_valid),
        .mode            (1'b0),
        .bypass_ant      (2'd0),
        .post_gain_shift (fw_pgs),
        .y_i (y_i), .y_q (y_q), .y_valid (y_valid)
    );

    wire out_i, out_q;
    wire signed [7:0] remod_in_i = u_mrc.use_mrc_r ? ($signed(y_i) >>> 1) : y_i;
    wire signed [7:0] remod_in_q = u_mrc.use_mrc_r ? ($signed(y_q) >>> 1) : y_q;
    sd_remod u_remod (
        .clk_32m (clk), .rst_n (rst_n),
        .in_i    (remod_in_i), .in_q (remod_in_q),
        .in_valid(y_valid),    .en   (1'b1),
        .out_i   (out_i),      .out_q(out_q)
    );

    // -----------------------------------------------------------------------
    // Main test loop
    // -----------------------------------------------------------------------
    integer bw_i, sf_i, ii, pass_count, fail_count, sf_pass, sf_fail;
    integer cyc_sc, cyc_tr, cyc_yv;
    integer cycle_count, sc_cyc_start;
    integer timeout_sc, timeout_tr;
    integer fail_this;
    string  bw_label;

    always @(posedge clk) if (rst_n) cycle_count <= cycle_count + 1;
    initial cycle_count = 0;

    initial begin
        pass_count = 0;
        fail_count = 0;

        rst_n = 1'b0;
        repeat(8) @(posedge clk);
        rst_n = 1'b1;
        repeat(4) @(posedge clk);

        for (bw_i = 0; bw_i < N_BW; bw_i = bw_i + 1) begin
            // Set noise level to model CIC noise bandwidth per BW mode
            if (bw_i == 0) begin
                noise_sigma = 3;   // 125 kHz BW: R=256 → narrower noise BW
                bw_label  = "125k";
            end else begin
                noise_sigma = 5;   // 250 kHz BW: R=128 → ~4 dB more noise
                bw_label  = "250k";
            end

            $display("############################################################");
            $display("BW=%s  noise_sigma=%0d", bw_label, noise_sigma);
            $display("############################################################");

            for (sf_i = SF_MIN; sf_i <= SF_MAX; sf_i = sf_i + 1) begin
                sf_cur      = sf_i[3:0];
                stim_period = 1 << sf_i;
                timeout_sc  = 600 * stim_period;
                timeout_tr  = 640 * stim_period;
                sf_pass     = 0;
                sf_fail     = 0;

                $display("=== BW=%s SF%0d  sym_len=%0d  to_sc=%0d  to_tr=%0d ===",
                         bw_label, sf_i, stim_period, timeout_sc, timeout_tr);

                for (ii = 0; ii < N_CASES_PER_SF; ii = ii + 1) begin
                    fail_this = 0;

                    A_k[0] = 20 + ($urandom() % 41); ph_k[0] = $urandom() % stim_period;
                    A_k[1] = 10 + ($urandom() % 51); ph_k[1] = $urandom() % stim_period;
                    A_k[2] = 10 + ($urandom() % 51); ph_k[2] = $urandom() % stim_period;
                    A_k[3] = 10 + ($urandom() % 51); ph_k[3] = $urandom() % stim_period;
                    rebuild_stim(sf_i);

                    $display("  CASE %0d: A=[%.0f,%.0f,%.0f,%.0f] ph=[%0d,%0d,%0d,%0d]",
                             ii, A_k[0],A_k[1],A_k[2],A_k[3],
                             ph_k[0],ph_k[1],ph_k[2],ph_k[3]);

                    fw_W_valid=0; fw_W_commit=0;
                    fw_W_re0=0; fw_W_im0=0; fw_W_re1=0; fw_W_im1=0;
                    fw_W_re2=0; fw_W_im2=0; fw_W_re3=0; fw_W_im3=0;
                    fw_pgs=0;

                    rst_n = 1'b0;
                    repeat(8) @(posedge clk);
                    rst_n = 1'b1;
                    sc_cyc_start = cycle_count;

                    // Wait sc_lock
                    cyc_sc = -1;
                    fork
                        begin : blk_sc
                            @(posedge sc_lock);
                            cyc_sc = cycle_count - sc_cyc_start;
                        end
                        begin : blk_sc_to
                            repeat(timeout_sc) @(posedge clk);
                        end
                    join_any
                    disable fork;

                    if (cyc_sc < 0) begin
                        $display("    FAIL sc_lock timeout (%0d cycles)", timeout_sc);
                        fail_this = 1;
                    end else
                        $display("    sc_lock +%0d cyc", cyc_sc);

                    if (!fail_this) begin
                        // Wait training_done
                        cyc_tr = -1;
                        fork
                            begin : blk_tr
                                @(posedge training_done);
                                cyc_tr = cycle_count - sc_cyc_start - cyc_sc;
                            end
                            begin : blk_tr_to
                                repeat(timeout_tr) @(posedge clk);
                            end
                        join_any
                        disable fork;

                        if (cyc_tr < 0) begin
                            $display("    FAIL training_done timeout (%0d cycles)", timeout_tr);
                            fail_this = 1;
                        end else
                            $display("    training_done +%0d cyc  n_acc=%0d", cyc_tr, n_acc);
                    end

                    if (!fail_this) begin
                        fw_compute_and_commit();
                        if (fw_W_re0===8'h00 && fw_W_im0===8'h00 &&
                            fw_W_re1===8'h00 && fw_W_im1===8'h00) begin
                            $display("    FAIL all weights zero");
                            fail_this = 1;
                        end else
                            $display("    fw_commit pgs=%0d W=[%0d+%0dj,%0d+%0dj,%0d+%0dj,%0d+%0dj]",
                                     fw_pgs,
                                     $signed(fw_W_re0),$signed(fw_W_im0),
                                     $signed(fw_W_re1),$signed(fw_W_im1),
                                     $signed(fw_W_re2),$signed(fw_W_im2),
                                     $signed(fw_W_re3),$signed(fw_W_im3));
                    end

                    if (!fail_this) begin
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
                            $display("    FAIL y_valid timeout");
                            fail_this = 1;
                        end else begin
                            @(posedge y_valid);
                            if ($signed(y_i) < -127 || $signed(y_i) > 127) begin
                                $display("    FAIL y_i=%0d out of [-127,127]", $signed(y_i));
                                fail_this = 1;
                            end else
                                $display("    y_valid y_i=%0d y_q=%0d", $signed(y_i), $signed(y_q));
                        end
                    end

                    if (fail_this) begin
                        $display("    => FAIL"); sf_fail++; fail_count++;
                    end else begin
                        $display("    => PASS"); sf_pass++; pass_count++;
                    end
                end

                $display("  BW=%s SF%0d: %0d PASSED  %0d FAILED",
                         bw_label, sf_i, sf_pass, sf_fail);
            end
        end

        $display("============================================================");
        $display("Overall: %0d PASSED, %0d FAILED  (of %0d)",
                 pass_count, fail_count,
                 N_BW * (SF_MAX - SF_MIN + 1) * N_CASES_PER_SF);
        $display("============================================================");
        $finish;
    end

    // Global watchdog
    initial begin
        repeat(2 * N_BW * N_CASES_PER_SF * (SF_MAX - SF_MIN + 1) * (600 + 640) * MAX_SYMS)
            @(posedge clk);
        $display("GLOBAL TIMEOUT — %0d PASSED  %0d FAILED so far",
                 pass_count, fail_count);
        $finish;
    end

endmodule
