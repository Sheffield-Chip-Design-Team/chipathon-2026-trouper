// tb_mrc_combiner.v
// Self-checking unit tests for mrc_combiner.v (Q0.7 guard shift, adaptive pgs).
//
// Tests:
//   1. Q0.7 arithmetic — coherent I-only, 4 equal branches, A=64 W_max=120 pgs=0
//      → output ≤ 127, no clip; exact expected value checked
//   2. Complex MAC — x complex, W complex, 4 equal branches, pgs=0
//      → both I and Q checked against reference arithmetic
//   3. 20 dB spread — x_i=90 on all, W varies (90/28/9/3), pgs=1
//      → weighted sum correct, left-shift applied
//   4. Pgs clip boundary (strong) — A=90, W_max=90, pgs=0
//      → output ≈ 127 (full-scale), no 2's-complement wrap
//   5. Pgs clip boundary (weak)   — A=4, W_max=120, pgs=3
//      → output = 60 (combined shift: 1920>>>5=60)
//   6. Bypass mode — mode=1, bypass_ant=2, W ignored
//      → y_i = x_i2, y_q = x_q2 exactly

`timescale 1ns/100ps

module tb_mrc_combiner;

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
    // Helpers
    // -----------------------------------------------------------------------
    integer fail_count;

    // Drive one sample and return after y_valid. Call from @(posedge clk).
    // Caller must set all inputs before calling.
    task drive_sample;
        integer timeout;
        begin
            @(posedge clk);
            x_valid = 1'b1;
            @(posedge clk);
            x_valid = 1'b0;
            timeout = 0;
            while (!y_valid && timeout < 20) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 20) begin
                $display("FAIL: y_valid timeout");
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_iq;
        input signed [7:0] expected_i, expected_q;
        input [63:0]       test_num;
        begin
            if (y_i !== expected_i || y_q !== expected_q) begin
                $display("FAIL test %0d: expected y_i=%0d y_q=%0d, got y_i=%0d y_q=%0d",
                    test_num, expected_i, expected_q, y_i, y_q);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS test %0d: y_i=%0d y_q=%0d", test_num, y_i, y_q);
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
        // Default inputs (all zero)
        x_i0=0; x_q0=0; x_i1=0; x_q1=0;
        x_i2=0; x_q2=0; x_i3=0; x_q3=0;
        W_re0=0; W_im0=0; W_re1=0; W_im1=0;
        W_re2=0; W_im2=0; W_re3=0; W_im3=0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // -------------------------------------------------------------------
        // Test 1: coherent I-only, 4 equal branches, A=64, W_max=120, pgs=0
        //   acc_i = 4 × 120 × 64 = 30720
        //   guarded = 30720 >>> 8 = 120 (exact)
        //   expected y_i = 120, y_q = 0
        // -------------------------------------------------------------------
        mode = 0; W_valid = 1; post_gain_shift = 0;
        x_i0=64; x_q0=0; x_i1=64; x_q1=0; x_i2=64; x_q2=0; x_i3=64; x_q3=0;
        W_re0=120; W_im0=0; W_re1=120; W_im1=0;
        W_re2=120; W_im2=0; W_re3=120; W_im3=0;
        drive_sample;
        check_iq(8'sd120, 8'sd0, 1);

        // -------------------------------------------------------------------
        // Test 2: complex weight MAC, 4 equal branches, pgs=0
        //   x_i=60, x_q=40; W_re=80, W_im=60
        //   prod_i = 80×60 − 60×40 = 4800 − 2400 = 2400
        //   prod_q = 80×40 + 60×60 = 3200 + 3600 = 6800
        //   acc_i  = 4×2400 = 9600   → guarded_i = 9600>>>8 = 37
        //   acc_q  = 4×6800 = 27200  → guarded_q = 27200>>>8 = 106
        //   expected y_i = 37, y_q = 106
        // -------------------------------------------------------------------
        post_gain_shift = 0;
        x_i0=60; x_q0=40; x_i1=60; x_q1=40; x_i2=60; x_q2=40; x_i3=60; x_q3=40;
        W_re0=80; W_im0=60; W_re1=80; W_im1=60;
        W_re2=80; W_im2=60; W_re3=80; W_im3=60;
        drive_sample;
        check_iq(8'sd37, 8'sd106, 2);

        // -------------------------------------------------------------------
        // Test 3: 20 dB spread, x_i=90 all branches, pgs=1
        //   W: 90, 28, 9, 3  (each ~10 dB below previous)
        //   prod_i: 90×90=8100, 28×90=2520, 9×90=810, 3×90=270
        //   acc_i  = 11700  → combined: 11700 >>> (8-1) = 11700>>>7 = 91
        //   expected y_i = 91, y_q = 0
        // -------------------------------------------------------------------
        post_gain_shift = 1;
        x_i0=90; x_q0=0; x_i1=90; x_q1=0; x_i2=90; x_q2=0; x_i3=90; x_q3=0;
        W_re0=90; W_im0=0; W_re1=28; W_im1=0;
        W_re2=9;  W_im2=0; W_re3=3;  W_im3=0;
        drive_sample;
        check_iq(8'sd91, 8'sd0, 3);

        // -------------------------------------------------------------------
        // Test 4: pgs clip boundary — strong signal
        //   A=90, W_max=90, pgs=0 (firmware adaptive: c≈0.71, W_max≈90)
        //   acc_i = 4×90×90 = 32400
        //   guarded = 32400>>>8 = 126 (truncated from 126.5625)
        //   expected y_i = 126 (≈full-scale, no wrap)
        // -------------------------------------------------------------------
        post_gain_shift = 0;
        x_i0=90; x_q0=0; x_i1=90; x_q1=0; x_i2=90; x_q2=0; x_i3=90; x_q3=0;
        W_re0=90; W_im0=0; W_re1=90; W_im1=0;
        W_re2=90; W_im2=0; W_re3=90; W_im3=0;
        drive_sample;
        // Check no wrap (positive, ≥ 120) and ≤ 127
        if (y_i < 8'sd120 || y_i > 8'sd127 || y_q !== 8'sd0) begin
            $display("FAIL test 4: expected 120<=y_i<=127 y_q=0, got y_i=%0d y_q=%0d",
                $signed(y_i), $signed(y_q));
            fail_count = fail_count + 1;
        end else begin
            $display("PASS test 4: y_i=%0d y_q=%0d (strong signal, no wrap)",
                $signed(y_i), $signed(y_q));
        end

        // -------------------------------------------------------------------
        // Test 5: pgs clip boundary — weak signal
        //   A=4, W_max=120, pgs=3
        //   acc_i = 4×4×120 = 1920
        //   combined: 1920 >>> (8-3) = 1920>>>5 = 60
        //   expected y_i = 60
        // -------------------------------------------------------------------
        post_gain_shift = 3;
        x_i0=4; x_q0=0; x_i1=4; x_q1=0; x_i2=4; x_q2=0; x_i3=4; x_q3=0;
        W_re0=120; W_im0=0; W_re1=120; W_im1=0;
        W_re2=120; W_im2=0; W_re3=120; W_im3=0;
        drive_sample;
        check_iq(8'sd60, 8'sd0, 5);

        // -------------------------------------------------------------------
        // Test 6: bypass mode — mode=1, bypass_ant=2
        //   x_i2=77, x_q2=-33; W ignored
        //   expected y_i = 77, y_q = -33
        // -------------------------------------------------------------------
        mode = 1; bypass_ant = 2'd2; post_gain_shift = 0;
        x_i0=10; x_q0=20; x_i1=30; x_q1=40;
        x_i2=77; x_q2=-33; x_i3=50; x_q3=60;
        W_re0=120; W_im0=0; W_re1=120; W_im1=0;
        W_re2=120; W_im2=0; W_re3=120; W_im3=0;
        drive_sample;
        check_iq(8'sd77, -8'sd33, 6);

        // -------------------------------------------------------------------
        // Done
        // -------------------------------------------------------------------
        repeat(4) @(posedge clk);
        if (fail_count == 0) begin
            $display("ALL PASS (%0d tests)", 6);
        end else begin
            $display("FAILED: %0d test(s)", fail_count);
            $finish(1);
        end
        $finish;
    end

    // Timeout safety net
    initial begin
        #500000;
        $display("TIMEOUT");
        $finish(1);
    end

endmodule
