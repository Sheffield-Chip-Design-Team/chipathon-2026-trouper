// tb_mrc_fw_precision.v
// Verifies that Q0.7 weight quantization is sufficient for MRC combining
// across five channel scenarios (varying amplitude spreads and pgs levels).
//
// Instantiates only mrc_combiner — no full chain or sc_lock needed.
// Per-branch weights are computed from synthetic Zdiag values using the
// same integer firmware algorithm as the PicoRV32 Step-3 implementation.
//
// Cases:
//   1. Equal branches A=[40,40,40,40] n_acc=1024  → pgs=0 w_max=120 y_i=75
//   2. 6 dB spread   A=[64,32,32,32] n_acc=4096  → pgs=0 w_max=120 y_i=52
//   3. 20 dB spread  A=[90,28,9,3]   n_acc=65536 → pgs=0 w_max=90  y_i=35
//   4. Weak + pgs    A=[4,4,4,4]     n_acc=8192  → pgs=3 w_max=120 y_i=60
//   5. Strong cap    A=[90,90,90,90] n_acc=512   → pgs=0 w_max=91  y_i=126

`timescale 1ns/100ps

module tb_mrc_fw_precision;

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
    // Integer firmware model (matches planning/blocks/Eigenvector Weight Computation.md Step 3)
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
    // Testbench state
    // -----------------------------------------------------------------------
    integer fail_count;

    task drive_sample;
        integer timeout;
        begin
            // Drive on falling edges and observe after the DUT's NBA update.
            // The old posedge-only task raced x_valid/y_valid, so a case could
            // consume the prior case's output or miss its own one-cycle pulse.
            @(negedge clk);
            x_valid = 1'b1;
            @(negedge clk);
            x_valid = 1'b0;
            timeout = 0;
            // The production combiner is deliberately paced: state 0 catches
            // x_valid in one clock and states 1..10 each hold three clocks,
            // so y_valid arrives after 31 clocks.  Leave margin for the
            // falling-edge observation above.
            while (!y_valid && timeout < 40) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 40) begin
                $display("FAIL: y_valid timeout");
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Precision case runner
    //
    // Algorithm:
    //   1. Reconstruct per-branch A_k = isqrt((Zdiag_k << 8) / n_acc)
    //   2. Derive global pgs and W_max from strongest branch
    //   3. Per-branch weights: W_k = (W_max * A_k) / A_max  (matched filter)
    //   4. Drive combiner with x_i_k = A_k, x_q_k = 0
    //   5. Check |y_i - expected| <= tol and y_q == 0
    //   6. Display MRC vs single-antenna amplitude for visual inspection
    // -----------------------------------------------------------------------
    task run_case;
        input int    case_num;
        input longint zd0, zd1, zd2, zd3;   // ZDIAG_reg values (= Z_kk >> 8)
        input longint n_acc;
        input int    tol;

        longint e0, e1, e2, e3, e_max, zd_max;
        int a0, a1, a2, a3, a_max, a_est;
        int y_pre_max, pgs_v, w_max_v, denom;
        int w0, w1, w2, w3;
        longint acc_i_expected;
        int expected_y_i, single_y_i, err;
        begin
            // Reconstruct per-branch amplitudes
            e0 = (zd0 << 8) / n_acc; a0 = isqrt_fn(e0);
            e1 = (zd1 << 8) / n_acc; a1 = isqrt_fn(e1);
            e2 = (zd2 << 8) / n_acc; a2 = isqrt_fn(e2);
            e3 = (zd3 << 8) / n_acc; a3 = isqrt_fn(e3);

            // Global pgs / W_max from strongest branch
            zd_max = zd0;
            if (zd1 > zd_max) zd_max = zd1;
            if (zd2 > zd_max) zd_max = zd2;
            if (zd3 > zd_max) zd_max = zd3;
            e_max  = (zd_max << 8) / n_acc;
            a_est  = isqrt_fn(e_max);

            y_pre_max = (120 * 4 * a_est) / 256;
            if (y_pre_max >= 90) pgs_v = 0;
            else if (y_pre_max == 0) pgs_v = 7;
            else pgs_v = floor_log2_fn(90 / y_pre_max);

            denom   = a_est * (1 << pgs_v);
            w_max_v = (denom > 0) ? (8128 / denom) : 120;
            if (w_max_v > 120) w_max_v = 120;

            // Per-branch weights (matched filter: W_k ∝ A_k)
            a_max = a0;
            if (a1 > a_max) a_max = a1;
            if (a2 > a_max) a_max = a2;
            if (a3 > a_max) a_max = a3;
            if (a_max == 0) a_max = 1;

            w0 = (w_max_v * a0) / a_max;
            w1 = (w_max_v * a1) / a_max;
            w2 = (w_max_v * a2) / a_max;
            w3 = (w_max_v * a3) / a_max;

            // Expected DUT output (same integer path as RTL: combined shift)
            acc_i_expected = longint'(w0)*longint'(a0) + longint'(w1)*longint'(a1)
                           + longint'(w2)*longint'(a2) + longint'(w3)*longint'(a3);
            expected_y_i = int'(acc_i_expected >> (8 - pgs_v));
            if (expected_y_i > 127) expected_y_i = 127;

            // Single-antenna reference for gain display
            single_y_i = (w_max_v * a_max) >> 8;
            if (single_y_i > 127) single_y_i = 127;

            $display("--- Case %0d: a=[%0d,%0d,%0d,%0d] pgs=%0d w_max=%0d w=[%0d,%0d,%0d,%0d] ---",
                case_num, a0, a1, a2, a3, pgs_v, w_max_v, w0, w1, w2, w3);

            // Program combiner
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

            err = $signed(y_i) - expected_y_i;
            if (err < 0) err = -err;

            $display("  MRC y_i=%0d  expected=%0d  single_ant=%0d  mrc_gain_vs_1ant=%0d%%",
                $signed(y_i), expected_y_i, single_y_i,
                (single_y_i > 0) ? (100 * $signed(y_i) / single_y_i) : 0);

            if (err > tol || y_q !== 8'sd0) begin
                $display("  FAIL: err=%0d > tol=%0d or y_q=%0d", err, tol, $signed(y_q));
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS: err=%0d", err);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        fail_count      = 0;
        rst_n           = 0;
        x_valid         = 0;
        W_valid         = 1;
        mode            = 0;
        bypass_ant      = 2'd0;
        post_gain_shift = 3'd0;
        x_i0=0; x_q0=0; x_i1=0; x_q1=0;
        x_i2=0; x_q2=0; x_i3=0; x_q3=0;
        W_re0=0; W_im0=0; W_re1=0; W_im1=0;
        W_re2=0; W_im2=0; W_re3=0; W_im3=0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // Case 1: Equal branches A=[40,40,40,40], n_acc=1024
        //   Zdiag_k = (1024 * 1600) >> 8 = 6400
        //   Expected: pgs=0 w_max=120 w_k=120 y_i=75
        run_case(1, 6400, 6400, 6400, 6400, 1024, 4);

        // Case 2: 6 dB spread A=[64,32,32,32], n_acc=4096
        //   Zdiag_0=(4096*4096)>>8=65536, Zdiag_1..3=(4096*1024)>>8=16384
        //   Expected: pgs=0 w_max=120 w=[120,60,60,60] y_i=52
        run_case(2, 65536, 16384, 16384, 16384, 4096, 4);

        // Case 3: 20 dB spread A=[90,28,9,3], n_acc=65536
        //   Zdiag_k = (65536 * A^2) >> 8 = 256 * A^2
        //   Expected: pgs=0 w_max=90 w=[90,28,9,3] y_i=35
        run_case(3, 2073600, 200704, 20736, 2304, 65536, 4);

        // Case 4: Weak signal with pgs boost A=[4,4,4,4], n_acc=8192
        //   Zdiag_k = (8192 * 16) >> 8 = 512
        //   Expected: pgs=3 w_max=120 w_k=120 y_i=56
        run_case(4, 512, 512, 512, 512, 8192, 4);

        // Case 5: Strong signal, W_max capped A=[90,90,90,90], n_acc=512
        //   Zdiag_k = (512 * 8100) >> 8 = 16200
        //   Expected: pgs=0 w_max=91 w_k=91 y_i=126
        run_case(5, 16200, 16200, 16200, 16200, 512, 4);

        // -----------------------------------------------------------------------
        repeat(4) @(posedge clk);
        $display("=========================================");
        if (fail_count == 0)
            $display("ALL PASS (5 MRC precision cases)");
        else
            $display("FAILED: %0d case(s)", fail_count);
        $finish(fail_count != 0);
    end

    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish(1);
    end

endmodule
