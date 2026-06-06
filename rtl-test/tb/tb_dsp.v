`timescale 1ns/1ps
// tb_dsp.v
// Simulation testbench: energy_meas → noise_floor_est chain.
// Tool: iverilog -g2001 + vvp (iic-osic-tools Docker)
// Checks: Σ|x|² accumulation, 16-bit saturation, NFE cold-start seed,
//         EMA stability under constant input, SW override, AGC invalidation.

module tb_dsp;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;
    initial clk = 0;
    always #16 clk = ~clk;   // 32 MHz (period 32 ns)

    // -----------------------------------------------------------------------
    // energy_meas DUT
    // -----------------------------------------------------------------------
    reg signed [7:0] iq_i_0, iq_i_1, iq_i_2, iq_i_3;
    reg signed [7:0] iq_q_0, iq_q_1, iq_q_2, iq_q_3;
    reg        iq_valid, sc_lock;
    reg [3:0]  sf;

    wire [31:0] energy_sum_0, energy_sum_1, energy_sum_2, energy_sum_3;
    wire [15:0] energy_0, energy_1, energy_2, energy_3;
    wire        energy_valid, energy_snapshot_valid;

    energy_meas u_em (
        .clk_32m(clk), .rst_n(rst_n),
        .iq_i_0(iq_i_0), .iq_i_1(iq_i_1), .iq_i_2(iq_i_2), .iq_i_3(iq_i_3),
        .iq_q_0(iq_q_0), .iq_q_1(iq_q_1), .iq_q_2(iq_q_2), .iq_q_3(iq_q_3),
        .iq_valid(iq_valid), .sf(sf), .sc_lock(sc_lock),
        .energy_sum_0(energy_sum_0), .energy_sum_1(energy_sum_1),
        .energy_sum_2(energy_sum_2), .energy_sum_3(energy_sum_3),
        .energy_0(energy_0), .energy_1(energy_1), .energy_2(energy_2), .energy_3(energy_3),
        .energy_valid(energy_valid), .energy_snapshot_valid(energy_snapshot_valid)
    );

    // -----------------------------------------------------------------------
    // noise_floor_est DUT — wired directly to energy_meas outputs
    // -----------------------------------------------------------------------
    reg        noise_sample_en;
    reg [2:0]  noise_alpha_shift;
    reg [15:0] sigma2_sw_0, sigma2_sw_1, sigma2_sw_2, sigma2_sw_3;
    reg        sigma2_commit, sigma2_src, agc_gain_changed;

    wire [15:0] sigma2_hw_0, sigma2_hw_1, sigma2_hw_2, sigma2_hw_3;
    wire [15:0] sigma2_active_0, sigma2_active_1, sigma2_active_2, sigma2_active_3;
    wire        sigma2_valid;
    wire [7:0]  n_updates;

    noise_floor_est u_nfe (
        .clk_32m(clk), .rst_n(rst_n),
        .energy_sum_0(energy_sum_0), .energy_sum_1(energy_sum_1),
        .energy_sum_2(energy_sum_2), .energy_sum_3(energy_sum_3),
        .noise_sample_en(noise_sample_en), .sf(sf), .noise_alpha_shift(noise_alpha_shift),
        .sigma2_sw_0(sigma2_sw_0), .sigma2_sw_1(sigma2_sw_1),
        .sigma2_sw_2(sigma2_sw_2), .sigma2_sw_3(sigma2_sw_3),
        .sigma2_commit(sigma2_commit), .sigma2_src(sigma2_src),
        .agc_gain_changed(agc_gain_changed),
        .sigma2_hw_0(sigma2_hw_0), .sigma2_hw_1(sigma2_hw_1),
        .sigma2_hw_2(sigma2_hw_2), .sigma2_hw_3(sigma2_hw_3),
        .sigma2_active_0(sigma2_active_0), .sigma2_active_1(sigma2_active_1),
        .sigma2_active_2(sigma2_active_2), .sigma2_active_3(sigma2_active_3),
        .sigma2_valid(sigma2_valid), .n_updates(n_updates)
    );

    // -----------------------------------------------------------------------
    // Test infrastructure
    // -----------------------------------------------------------------------
    integer errors;

    // Drive iq_valid=1 for N samples (after the clock edge to avoid races),
    // then turn it off and pulse noise_sample_en so the NFE can update.
    task run_window;
        input integer n_samples;
        integer j;
        begin
            for (j = 0; j < n_samples; j = j + 1) begin
                @(posedge clk); #1;
                iq_valid = 1;
            end
            @(posedge clk); #1; iq_valid         = 0;
            @(posedge clk); #1; noise_sample_en  = 1;
            @(posedge clk); #1; noise_sample_en  = 0;
            @(posedge clk); #1;  // wait for NFE register update
        end
    endtask

    integer k;

    initial begin
        $dumpfile("/work/tb_dsp.vcd");
        $dumpvars(0, tb_dsp);

        errors          = 0;
        rst_n           = 0;
        iq_valid        = 0;
        sc_lock         = 0;
        sf              = 4'd7;   // SF7: window = 128 samples
        iq_i_0 = 0; iq_q_0 = 0;
        iq_i_1 = 0; iq_q_1 = 0;
        iq_i_2 = 0; iq_q_2 = 0;
        iq_i_3 = 0; iq_q_3 = 0;
        noise_sample_en   = 0;
        noise_alpha_shift = 3'd4;
        sigma2_sw_0 = 0; sigma2_sw_1 = 0; sigma2_sw_2 = 0; sigma2_sw_3 = 0;
        sigma2_commit     = 0;
        sigma2_src        = 0;
        agc_gain_changed  = 0;

        repeat(4) @(posedge clk); #1;
        rst_n = 1;

        // ================================================================
        // TEST 1 — energy_meas: Σ|x|² per antenna (SF7, 128 samples)
        //
        //  ant0: i=127 q=0  → 128 × 127² = 2 064 512
        //  ant1: i= 64 q=0  → 128 ×  64² =   524 288
        //  ant2: i= 32 q=0  → 128 ×  32² =   131 072
        //  ant3: i= 10 q=0  → 128 ×  10² =    12 800
        // ================================================================
        $display("\n--- TEST 1: energy_meas accumulation (SF7, 128 samples) ---");
        iq_i_0 = 8'd127; iq_q_0 = 8'd0;
        iq_i_1 = 8'd64;  iq_q_1 = 8'd0;
        iq_i_2 = 8'd32;  iq_q_2 = 8'd0;
        iq_i_3 = 8'd10;  iq_q_3 = 8'd0;

        for (k = 0; k < 128; k = k + 1) begin @(posedge clk); #1; iq_valid = 1; end
        @(posedge clk); #1; iq_valid = 0;
        @(posedge clk); #1;  // settle

        if (energy_sum_0 !== 32'd2064512) begin
            $display("FAIL energy_sum_0: got=%0d exp=2064512", energy_sum_0); errors=errors+1;
        end else $display("PASS energy_sum_0 = %0d", energy_sum_0);

        if (energy_sum_1 !== 32'd524288) begin
            $display("FAIL energy_sum_1: got=%0d exp=524288",  energy_sum_1); errors=errors+1;
        end else $display("PASS energy_sum_1 = %0d", energy_sum_1);

        if (energy_sum_2 !== 32'd131072) begin
            $display("FAIL energy_sum_2: got=%0d exp=131072",  energy_sum_2); errors=errors+1;
        end else $display("PASS energy_sum_2 = %0d", energy_sum_2);

        if (energy_sum_3 !== 32'd12800) begin
            $display("FAIL energy_sum_3: got=%0d exp=12800",   energy_sum_3); errors=errors+1;
        end else $display("PASS energy_sum_3 = %0d", energy_sum_3);

        // ================================================================
        // TEST 2 — energy_meas: 16-bit saturated output
        //  ant0..2 sums exceed 65535 → 0xFFFF
        //  ant3 = 12800 fits → 12800
        // ================================================================
        $display("\n--- TEST 2: energy_meas 16-bit saturation ---");
        if (energy_0 !== 16'hFFFF) begin
            $display("FAIL energy_0: got=%0d exp=65535", energy_0); errors=errors+1;
        end else $display("PASS energy_0 saturated = 0xFFFF");

        if (energy_1 !== 16'hFFFF) begin
            $display("FAIL energy_1: got=%0d exp=65535", energy_1); errors=errors+1;
        end else $display("PASS energy_1 saturated = 0xFFFF");

        if (energy_2 !== 16'hFFFF) begin
            $display("FAIL energy_2: got=%0d exp=65535", energy_2); errors=errors+1;
        end else $display("PASS energy_2 saturated = 0xFFFF");

        if (energy_3 !== 16'd12800) begin
            $display("FAIL energy_3: got=%0d exp=12800", energy_3); errors=errors+1;
        end else $display("PASS energy_3 = %0d", energy_3);

        // ================================================================
        // TEST 3 — NFE cold-start seed
        //  sigma2_hw_N = acc[22:7]  where  acc = xacc = eps << 7
        //  eps = energy_sum_N >> 7  (per-sample energy)
        //  ⟹ sigma2_hw_N = energy_sum_N >> 7
        //  ant0: 2064512>>7=16129  ant1: 524288>>7=4096
        //  ant2: 131072>>7=1024    ant3: 12800>>7=100
        // ================================================================
        $display("\n--- TEST 3: NFE cold-start seed ---");
        @(posedge clk); #1; noise_sample_en = 1;
        @(posedge clk); #1; noise_sample_en = 0;
        @(posedge clk); #1;

        if (sigma2_hw_0 !== 16'd16129) begin
            $display("FAIL sigma2_hw_0: got=%0d exp=16129", sigma2_hw_0); errors=errors+1;
        end else $display("PASS sigma2_hw_0 = %0d", sigma2_hw_0);

        if (sigma2_hw_1 !== 16'd4096) begin
            $display("FAIL sigma2_hw_1: got=%0d exp=4096",  sigma2_hw_1); errors=errors+1;
        end else $display("PASS sigma2_hw_1 = %0d", sigma2_hw_1);

        if (sigma2_hw_2 !== 16'd1024) begin
            $display("FAIL sigma2_hw_2: got=%0d exp=1024",  sigma2_hw_2); errors=errors+1;
        end else $display("PASS sigma2_hw_2 = %0d", sigma2_hw_2);

        if (sigma2_hw_3 !== 16'd100) begin
            $display("FAIL sigma2_hw_3: got=%0d exp=100",   sigma2_hw_3); errors=errors+1;
        end else $display("PASS sigma2_hw_3 = %0d", sigma2_hw_3);

        if (!sigma2_valid) begin
            $display("FAIL sigma2_valid not set after seed"); errors=errors+1;
        end else $display("PASS sigma2_valid = 1");

        if (n_updates !== 8'd1) begin
            $display("FAIL n_updates: got=%0d exp=1", n_updates); errors=errors+1;
        end else $display("PASS n_updates = %0d", n_updates);

        // ================================================================
        // TEST 4 — NFE EMA stability: constant input equal to estimate
        //  diff = xacc − acc = 0  ⟹  delta = 0  ⟹  acc unchanged
        //  Run 20 more windows; verify no drift and n_updates increments.
        // ================================================================
        $display("\n--- TEST 4: NFE EMA stability (20 windows, constant amplitude) ---");
        for (k = 0; k < 20; k = k + 1)
            run_window(128);

        if (n_updates !== 8'd21) begin
            $display("FAIL n_updates: got=%0d exp=21", n_updates); errors=errors+1;
        end else $display("PASS n_updates = %0d", n_updates);

        if (sigma2_hw_0 !== 16'd16129) begin
            $display("FAIL sigma2_hw_0 drifted: got=%0d exp=16129", sigma2_hw_0); errors=errors+1;
        end else $display("PASS sigma2_hw_0 stable = %0d", sigma2_hw_0);

        if (sigma2_hw_1 !== 16'd4096) begin
            $display("FAIL sigma2_hw_1 drifted: got=%0d exp=4096",  sigma2_hw_1); errors=errors+1;
        end else $display("PASS sigma2_hw_1 stable = %0d", sigma2_hw_1);

        if (sigma2_hw_2 !== 16'd1024) begin
            $display("FAIL sigma2_hw_2 drifted: got=%0d exp=1024",  sigma2_hw_2); errors=errors+1;
        end else $display("PASS sigma2_hw_2 stable = %0d", sigma2_hw_2);

        if (sigma2_hw_3 !== 16'd100) begin
            $display("FAIL sigma2_hw_3 drifted: got=%0d exp=100",   sigma2_hw_3); errors=errors+1;
        end else $display("PASS sigma2_hw_3 stable = %0d", sigma2_hw_3);

        // ================================================================
        // TEST 5 — NFE SW override commit and source select
        // ================================================================
        $display("\n--- TEST 5: NFE SW override ---");
        sigma2_sw_0 = 16'hABCD;
        @(posedge clk); #1; sigma2_commit = 1;
        @(posedge clk); #1; sigma2_commit = 0;
        sigma2_src = 1;
        @(posedge clk); #1;

        if (sigma2_active_0 !== 16'hABCD) begin
            $display("FAIL sigma2_active_0(SW): got=%04h exp=ABCD", sigma2_active_0); errors=errors+1;
        end else $display("PASS sigma2_active_0(SW) = 0x%04h", sigma2_active_0);

        // Switch back to HW — combinatorial mux, no clock edge needed
        sigma2_src = 0; #1;
        if (sigma2_active_0 !== 16'd16129) begin
            $display("FAIL sigma2_active_0(HW): got=%0d exp=16129", sigma2_active_0); errors=errors+1;
        end else $display("PASS sigma2_active_0(HW) = %0d", sigma2_active_0);

        // ================================================================
        // TEST 6 — NFE AGC invalidation and re-seed
        // ================================================================
        $display("\n--- TEST 6: AGC invalidation ---");
        @(posedge clk); #1; agc_gain_changed = 1;
        @(posedge clk); #1; agc_gain_changed = 0;
        @(posedge clk); #1;

        if (sigma2_valid) begin
            $display("FAIL sigma2_valid not cleared after AGC reset"); errors=errors+1;
        end else $display("PASS sigma2_valid = 0 after AGC reset");

        if (n_updates !== 8'd0) begin
            $display("FAIL n_updates not cleared: got=%0d", n_updates); errors=errors+1;
        end else $display("PASS n_updates = 0 after AGC reset");

        // Next noise_sample_en should re-seed (cold-start path)
        @(posedge clk); #1; noise_sample_en = 1;
        @(posedge clk); #1; noise_sample_en = 0;
        @(posedge clk); #1;

        if (!sigma2_valid) begin
            $display("FAIL sigma2_valid not set after re-seed"); errors=errors+1;
        end else $display("PASS sigma2_valid = 1 after re-seed");

        if (sigma2_hw_0 !== 16'd16129) begin
            $display("FAIL sigma2_hw_0 re-seed: got=%0d exp=16129", sigma2_hw_0); errors=errors+1;
        end else $display("PASS sigma2_hw_0 re-seeded = %0d", sigma2_hw_0);

        $display("\n=== DONE: %0d error(s) ===\n", errors);
        $finish;
    end

    // Watchdog: 20 ms is more than enough for 21 × 128-sample windows at 32 ns/cycle
    initial begin
        #2000000;
        $display("WATCHDOG TIMEOUT — simulation hung");
        $finish;
    end

endmodule
