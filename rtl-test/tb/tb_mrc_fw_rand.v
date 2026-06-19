// tb_mrc_fw_rand.v
// Randomised MRC precision testbench — measures quantisation loss vs
// float-optimal MRC and MRC combining gain vs single-antenna.
//
// Metrics reported per pgs tier and overall:
//   quant_loss_dB  = 20*log10(y_float / y_int)
//                    loss from integer weight rounding + >>8 guard-shift
//                    truncation (amplified by 2^pgs left-shift)
//   mrc_gain_dB    = 20*log10(y_float / y_single_ant)
//                    diversity gain from combining 4 branches vs best 1
//
// Tier boundaries (n_acc=65536 → Zdiag_k = A_k^2):
//   pgs=4: A_max in [2,  3]
//   pgs=3: A_max in [4,  6]
//   pgs=2: A_max in [7, 12]
//   pgs=1: A_max in [13,24]
//   pgs=0: A_max in [25,90]
//
// Phases:
//   1. 14 fixed boundary cases (tier transitions + extreme spread)
//      — print per-case float metrics
//   2. N_CASES stratified random cases (N_CASES/5 per tier, round-robin)
//      — accumulate statistics, print on FAIL only
//   3. Print per-tier and overall summary
//
// Seed: +seed=<N>  (default 42)

`timescale 1ns/100ps

module tb_mrc_fw_rand;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    parameter int N_CASES = 1000;   // stratified random cases (200 per tier)
    parameter int N_ACC   = 65536;  // Zdiag_k = A_k^2 exactly at this n_acc
    parameter int A_MIN   = 2;
    parameter int TOL     = 1;

    localparam int TIER_LO [5] = '{ 25, 13,  7,  4,  2 }; // pgs=0..4
    localparam int TIER_HI [5] = '{ 90, 24, 12,  6,  3 };

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #31.25 clk = ~clk;   // 16 MHz

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    reg signed [7:0]  x_i0, x_q0, x_i1, x_q1, x_i2, x_q2, x_i3, x_q3;
    reg               x_valid;
    reg signed [7:0]  W_re0, W_im0, W_re1, W_im1;
    reg signed [7:0]  W_re2, W_im2, W_re3, W_im3;
    reg               W_valid;
    reg               mode;
    reg  [1:0]        bypass_ant;
    reg  [2:0]        post_gain_shift;
    wire signed [7:0] y_i, y_q;
    wire              y_valid;

    mrc_combiner u_dut (
        .clk_16m        (clk),
        .rst_n          (rst_n),
        .x_i0 (x_i0), .x_q0 (x_q0), .x_i1 (x_i1), .x_q1 (x_q1),
        .x_i2 (x_i2), .x_q2 (x_q2), .x_i3 (x_i3), .x_q3 (x_q3),
        .x_valid        (x_valid),
        .W_re0 (W_re0), .W_im0 (W_im0), .W_re1 (W_re1), .W_im1 (W_im1),
        .W_re2 (W_re2), .W_im2 (W_im2), .W_re3 (W_re3), .W_im3 (W_im3),
        .W_valid        (W_valid),
        .mode           (mode),
        .bypass_ant     (bypass_ant),
        .post_gain_shift(post_gain_shift),
        .y_i            (y_i),
        .y_q            (y_q),
        .y_valid        (y_valid)
    );

    // -----------------------------------------------------------------------
    // Firmware integer model
    // -----------------------------------------------------------------------
    function automatic int isqrt_fn(input longint n);
        longint x, x1;
        if (n <= 0) return 0;
        x = n; x1 = (n + 1) / 2;
        while (x1 < x) begin x = x1; x1 = (x + n/x) / 2; end
        return int'(x);
    endfunction

    function automatic int floor_log2_fn(input int n);
        int k, tmp;
        if (n <= 1) return 0;
        tmp = n; k = 0;
        while (tmp > 1) begin tmp = tmp >> 1; k = k + 1; end
        return k;
    endfunction

    // -----------------------------------------------------------------------
    // Per-tier statistics (indexed by pgs value 0..4)
    // -----------------------------------------------------------------------
    real    tier_max_ql  [5];   // max quantisation loss (dB)
    real    tier_sum_ql  [5];   // sum for mean
    real    tier_min_mg  [5];   // min MRC gain (dB)
    real    tier_max_mg  [5];   // max MRC gain (dB)
    real    tier_sum_mg  [5];   // sum for mean
    integer tier_cnt     [5];   // case count
    integer tier_gt050   [5];   // loss > 0.5 dB
    integer tier_gt100   [5];   // loss > 1.0 dB

    integer fail_count, pass_count;

    // -----------------------------------------------------------------------
    // Drive helper
    // -----------------------------------------------------------------------
    task drive_sample;
        integer timeout;
        begin
            @(posedge clk); x_valid = 1'b1;
            @(posedge clk); x_valid = 1'b0;
            timeout = 0;
            while (!y_valid && timeout < 20) begin @(posedge clk); timeout++; end
            if (timeout >= 20) begin
                $display("FAIL: y_valid timeout");
                fail_count++;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Core case runner
    // boundary=1 → print per-case detail; =0 → accumulate stats silently
    // -----------------------------------------------------------------------
    task automatic run_case;
        input int  case_num;
        input int  a0_in, a1_in, a2_in, a3_in;
        input bit  boundary;

        longint zd0, zd1, zd2, zd3, zd_max, e_max;
        int     a0, a1, a2, a3, a_max, a_est;
        int     y_pre_max, pgs_v, w_max_v, denom;
        int     w0, w1, w2, w3;
        longint acc_i_expected;
        int     expected_y_i, err;

        real    wf0, wf1, wf2, wf3, acc_float;
        real    y_float_r, y_sa_r, y_int_r;
        real    ql_db, mg_db;   // quant loss, mrc gain
        begin
            // Synthetic Zdiag (N_ACC=65536 → Zdiag_k = A_k^2)
            zd0 = longint'(a0_in) * a0_in;
            zd1 = longint'(a1_in) * a1_in;
            zd2 = longint'(a2_in) * a2_in;
            zd3 = longint'(a3_in) * a3_in;

            a0 = isqrt_fn((zd0 << 16) / N_ACC);
            a1 = isqrt_fn((zd1 << 16) / N_ACC);
            a2 = isqrt_fn((zd2 << 16) / N_ACC);
            a3 = isqrt_fn((zd3 << 16) / N_ACC);

            zd_max = zd0;
            if (zd1 > zd_max) zd_max = zd1;
            if (zd2 > zd_max) zd_max = zd2;
            if (zd3 > zd_max) zd_max = zd3;
            e_max  = (zd_max << 16) / N_ACC;
            a_est  = isqrt_fn(e_max);

            y_pre_max = (120 * 4 * a_est) / 256;
            if (y_pre_max >= 90) pgs_v = 0;
            else if (y_pre_max == 0) pgs_v = 7;
            else pgs_v = floor_log2_fn(90 / y_pre_max);

            denom   = a_est * (1 << pgs_v);
            w_max_v = (denom > 0) ? (8128 / denom) : 120;
            if (w_max_v > 120) w_max_v = 120;

            a_max = a0;
            if (a1 > a_max) a_max = a1;
            if (a2 > a_max) a_max = a2;
            if (a3 > a_max) a_max = a3;
            if (a_max == 0) a_max = 1;

            w0 = (w_max_v * a0) / a_max;
            w1 = (w_max_v * a1) / a_max;
            w2 = (w_max_v * a2) / a_max;
            w3 = (w_max_v * a3) / a_max;

            // Integer expected output (combined shift, matches RTL)
            acc_i_expected = longint'(w0)*longint'(a0) + longint'(w1)*longint'(a1)
                           + longint'(w2)*longint'(a2) + longint'(w3)*longint'(a3);
            expected_y_i = int'(acc_i_expected >> (8 - pgs_v));
            if (expected_y_i > 127) expected_y_i = 127;

            // Float-optimal reference (exact weights, no floor)
            wf0 = (1.0 * w_max_v * a0) / a_max;
            wf1 = (1.0 * w_max_v * a1) / a_max;
            wf2 = (1.0 * w_max_v * a2) / a_max;
            wf3 = (1.0 * w_max_v * a3) / a_max;
            acc_float = wf0*a0 + wf1*a1 + wf2*a2 + wf3*a3;
            y_float_r = (acc_float / 256.0) * (1 << pgs_v);
            if (y_float_r > 127.0) y_float_r = 127.0;

            // Single-antenna reference (best branch only, W=w_max)
            y_sa_r = (1.0 * w_max_v * a_max / 256.0) * (1 << pgs_v);
            if (y_sa_r > 127.0) y_sa_r = 127.0;

            // Drive DUT
            post_gain_shift = pgs_v[2:0];
            W_re0 = w0[7:0]; W_im0 = 0;
            W_re1 = w1[7:0]; W_im1 = 0;
            W_re2 = w2[7:0]; W_im2 = 0;
            W_re3 = w3[7:0]; W_im3 = 0;
            x_i0  = a0[7:0]; x_q0  = 0;
            x_i1  = a1[7:0]; x_q1  = 0;
            x_i2  = a2[7:0]; x_q2  = 0;
            x_i3  = a3[7:0]; x_q3  = 0;
            drive_sample;

            y_int_r = $signed(y_i);
            err = int'(y_int_r) - expected_y_i;
            if (err < 0) err = -err;

            // RTL self-consistency check
            if (err > TOL || y_q !== 8'sd0) begin
                $display("FAIL %s%0d: a=[%0d,%0d,%0d,%0d] pgs=%0d w_max=%0d y_i=%0d expected=%0d err=%0d",
                    boundary ? "bnd" : "rnd", case_num,
                    a0, a1, a2, a3, pgs_v, w_max_v, $signed(y_i), expected_y_i, err);
                fail_count++;
            end else begin
                pass_count++;
            end

            // Float precision metrics
            if (y_float_r > 0.0 && y_int_r > 0.0 && y_sa_r > 0.0) begin
                ql_db = 20.0 * $log10(y_float_r / y_int_r);
                mg_db = 20.0 * $log10(y_float_r / y_sa_r);
            end else begin
                ql_db = 0.0; mg_db = 0.0;
            end

            if (boundary) begin
                $display("  bnd%0d: a=[%0d,%0d,%0d,%0d] pgs=%0d wmax=%0d y_int=%0d y_f=%.1f loss=%.3fdB mrc_gain=%.2fdB",
                    case_num, a0, a1, a2, a3, pgs_v, w_max_v, $signed(y_i), y_float_r, ql_db, mg_db);
            end

            // Accumulate per-tier stats (pgs capped at 4 for array bounds)
            if (!boundary && pgs_v <= 4) begin
                tier_cnt[pgs_v]++;
                tier_sum_ql[pgs_v] += ql_db;
                if (ql_db > tier_max_ql[pgs_v]) tier_max_ql[pgs_v] = ql_db;
                if (ql_db > 0.5) tier_gt050[pgs_v]++;
                if (ql_db > 1.0) tier_gt100[pgs_v]++;
                tier_sum_mg[pgs_v] += mg_db;
                if (mg_db < tier_min_mg[pgs_v]) tier_min_mg[pgs_v] = mg_db;
                if (mg_db > tier_max_mg[pgs_v]) tier_max_mg[pgs_v] = mg_db;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    integer seed, ii, tier, ti, span;
    integer a_max_r, a1_r, a2_r, a3_r;

    initial begin
        // Init statistics
        for (ti = 0; ti < 5; ti++) begin
            tier_cnt[ti]    = 0;
            tier_sum_ql[ti] = 0.0; tier_max_ql[ti] = 0.0;
            tier_gt050[ti]  = 0;   tier_gt100[ti]  = 0;
            tier_sum_mg[ti] = 0.0;
            tier_min_mg[ti] = 999.0; tier_max_mg[ti] = 0.0;
        end
        fail_count = 0; pass_count = 0;
        if (!$value$plusargs("seed=%d", seed)) seed = 42;

        rst_n = 0; x_valid = 0; W_valid = 1; mode = 0; bypass_ant = 0;
        post_gain_shift = 0;
        x_i0=0; x_q0=0; x_i1=0; x_q1=0; x_i2=0; x_q2=0; x_i3=0; x_q3=0;
        W_re0=0; W_im0=0; W_re1=0; W_im1=0; W_re2=0; W_im2=0; W_re3=0; W_im3=0;
        repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        // -------------------------------------------------------------------
        // Phase 1: fixed boundary cases
        // -------------------------------------------------------------------
        $display("=== Phase 1: boundary cases ===");
        run_case( 0,  2,  2,  2,  2, 1);  // pgs=4 min
        run_case( 1,  3,  3,  3,  3, 1);  // pgs=4 max
        run_case( 2,  4,  4,  4,  4, 1);  // pgs=3 min
        run_case( 3,  6,  6,  6,  6, 1);  // pgs=3 max
        run_case( 4,  7,  7,  7,  7, 1);  // pgs=2 min
        run_case( 5, 12, 12, 12, 12, 1);  // pgs=2 max
        run_case( 6, 13, 13, 13, 13, 1);  // pgs=1 min
        run_case( 7, 24, 24, 24, 24, 1);  // pgs=1 max
        run_case( 8, 25, 25, 25, 25, 1);  // pgs=0 min
        run_case( 9, 90, 90, 90, 90, 1);  // pgs=0 max, W_max cap
        run_case(10, 90,  2,  2,  2, 1);  // extreme spread
        run_case(11, 24, 12,  6,  3, 1);  // cross-tier A_max in pgs=1
        run_case(12, 25, 24, 12,  7, 1);  // cross-tier A_max in pgs=0
        run_case(13, 90, 45, 13,  7, 1);  // moderate spread pgs=0

        // -------------------------------------------------------------------
        // Phase 2: stratified random (N_CASES cases, N_CASES/5 per tier)
        // Tier assigned round-robin so every run covers all pgs levels equally
        // -------------------------------------------------------------------
        $display("=== Phase 2: stratified random (seed=%0d, N=%0d) ===", seed, N_CASES);
        for (ii = 0; ii < N_CASES; ii++) begin
            tier = ii % 5;   // 0=pgs0, 1=pgs1, 2=pgs2, 3=pgs3, 4=pgs4
            span = TIER_HI[tier] - TIER_LO[tier] + 1;

            if (ii == 0)
                a_max_r = ($urandom(seed) % span) + TIER_LO[tier];
            else
                a_max_r = ($urandom % span) + TIER_LO[tier];

            if (a_max_r > A_MIN) begin
                a1_r = ($urandom % (a_max_r - A_MIN + 1)) + A_MIN;
                a2_r = ($urandom % (a_max_r - A_MIN + 1)) + A_MIN;
                a3_r = ($urandom % (a_max_r - A_MIN + 1)) + A_MIN;
            end else begin
                a1_r = A_MIN; a2_r = A_MIN; a3_r = A_MIN;
            end

            run_case(ii, a_max_r, a1_r, a2_r, a3_r, 0);
        end

        // -------------------------------------------------------------------
        // Summary report
        // -------------------------------------------------------------------
        $display("");
        $display("=== Quantisation precision report (%0d random cases) ===", N_CASES);
        $display("  tier  | pgs | cases | max_loss | mean_loss | >0.5dB | >1.0dB | min_gain | mean_gain | max_gain");
        for (ti = 4; ti >= 0; ti--) begin   // print pgs=4 first (weakest)
            if (tier_cnt[ti] > 0)
                $display("  [%2d-%2d] | %0d   | %5d | %7.3fdB | %7.3fdB   | %6d | %6d | %6.2fdB | %7.2fdB  | %6.2fdB",
                    TIER_LO[ti], TIER_HI[ti], ti,
                    tier_cnt[ti],
                    tier_max_ql[ti],
                    tier_sum_ql[ti] / tier_cnt[ti],
                    tier_gt050[ti], tier_gt100[ti],
                    tier_min_mg[ti],
                    tier_sum_mg[ti] / tier_cnt[ti],
                    tier_max_mg[ti]);
        end
        $display("");
        $display("=== Self-consistency check: %0d/%0d PASS ===",
            pass_count, pass_count + fail_count);
        if (fail_count > 0)
            $display("FAILED: %0d", fail_count);
        else
            $display("ALL PASS");
        $finish(fail_count != 0);
    end

    initial begin #20000000; $display("TIMEOUT"); $finish(1); end

endmodule
