// tb_pcfsm_b6_equiv.v
// B6 equivalence: old absolute-deadline packet_ctrl_fsm (packet_ctrl_fsm_ref,
// extracted from main) vs new down-counter version, driven with identical
// stimulus, ALL outputs compared every clock.  The B6 claim is that every
// timeout fires on the bit-identical clock edge; this TB is the proof, same
// pattern as tb_tacc_resetless_equiv.v.
//
// Stimulus per packet (randomized):
//   - sf 7..12, sample_shift 1..2, tacc_window_syms 1..3 (short, direct-drive:
//     the reg_bank >=8 clamp is upstream, pcfsm itself only maps 0->1),
//     pkt_timeout_syms 2..6
//   - timing_ref = current sample_count - back_off, back_off in 0..2*M
//     (models the (sc_hits_req+1)-symbol-in-the-past preamble anchor)
//   - scenario mix: training_done then W_commit (clean), training_done and
//     no commit (WPEND timeout), no training_done (ACQ timeout), commit
//     before lock (pending applied in IDLE)
//   - iq ticks every TICK_P clocks with random initial phase per packet, so
//     the ST_ACQ_SETUP load-edge tick correction gets hit
//
// TICK_P=8 (not the real 64): pcfsm semantics only depend on tick ordering,
// and 8x shortens the sim.  Ref compares sample_count, DUT counts ticks.

`timescale 1ns/100ps

module tb_pcfsm_b6_equiv;

    reg clk = 0;
    always #15.625 clk = ~clk;

    reg         rst_n = 0;
    reg  [31:0] sample_count = 0;
    reg         iq_tick = 0;
    reg  [3:0]  sf = 7;
    reg  [1:0]  sample_shift = 1;
    reg         sc_lock = 0;
    reg  [31:0] timing_ref = 0;
    reg         training_done = 0;
    reg         W_commit = 0;
    reg  [1:0]  mode_shadow = 0;
    reg  [3:0]  antenna_en_shadow = 4'hF;
    reg  [7:0]  pkt_timeout_syms = 4;
    reg  [3:0]  tacc_window_syms = 2;

    // ---- reference (old absolute-deadline) ----
    wire        r_W_valid_set, r_W_missed_packet, r_W_missed_q;
    wire [2:0]  r_packet_phase;
    wire        r_packet_active;
    wire [1:0]  r_active_mode;
    wire [3:0]  r_active_antenna_en;

    packet_ctrl_fsm_ref u_ref (
        .clk(clk), .rst_n(rst_n),
        .sample_count(sample_count), .sf(sf), .sample_shift(sample_shift),
        .sc_lock(sc_lock), .timing_ref(timing_ref),
        .training_done(training_done), .W_commit(W_commit),
        .mode_shadow(mode_shadow), .antenna_en_shadow(antenna_en_shadow),
        .pkt_timeout_syms(pkt_timeout_syms), .tacc_window_syms(tacc_window_syms),
        .W_valid_set(r_W_valid_set), .W_missed_packet(r_W_missed_packet),
        .W_missed_q(r_W_missed_q),  // ref's buf_freeze output left unconnected
                                    // (deleted from the DUT 2026-07-26; ref is a frozen snapshot)
        .packet_phase(r_packet_phase), .packet_active(r_packet_active),
        .active_mode(r_active_mode), .active_antenna_en(r_active_antenna_en));

    // ---- DUT (new down-counter) ----
    wire        d_W_valid_set, d_W_missed_packet, d_W_missed_q;
    wire [2:0]  d_packet_phase;
    wire        d_packet_active;
    wire        d_packet_active_ps;  // fanout-split duplicate: must mirror packet_active exactly
    wire [1:0]  d_active_mode;
    wire [3:0]  d_active_antenna_en;

    packet_ctrl_fsm u_dut (
        .clk(clk), .rst_n(rst_n),
        .sample_count(sample_count), .iq_tick(iq_tick),
        .sf(sf), .sample_shift(sample_shift),
        .sc_lock(sc_lock), .timing_ref(timing_ref),
        .training_done(training_done), .W_commit(W_commit),
        .mode_shadow(mode_shadow), .antenna_en_shadow(antenna_en_shadow),
        .pkt_timeout_syms(pkt_timeout_syms), .tacc_window_syms(tacc_window_syms),
        .packet_active_ps(d_packet_active_ps),
        .W_valid_set(d_W_valid_set), .W_missed_packet(d_W_missed_packet),
        .W_missed_q(d_W_missed_q),
        .packet_phase(d_packet_phase), .packet_active(d_packet_active),
        .active_mode(d_active_mode), .active_antenna_en(d_active_antenna_en));

    // ---- iq tick generator: TICK_P clocks per tick, random phase per packet
    integer TICK_P = 8;
    integer tick_phase = 0;
    integer tick_cnt = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            iq_tick <= 0;
            tick_cnt <= 0;
        end else begin
            if (tick_cnt == TICK_P-1) begin
                tick_cnt <= 0;
                iq_tick <= 1;
            end else begin
                tick_cnt <= tick_cnt + 1;
                iq_tick <= 0;
            end
        end
    end
    // sample_count increments at the same edge iq_tick is high (mirrors
    // trouper_top: iq_samp_cnt <= +1 when dcr_valid)
    always @(posedge clk)
        if (!rst_n) sample_count <= 0;
        else if (iq_tick) sample_count <= sample_count + 1;

    // ---- per-cycle output compare ----
    integer errors = 0;
    always @(posedge clk) if (rst_n) begin
        if ({r_W_valid_set, r_W_missed_packet, r_W_missed_q,
             r_packet_phase, r_packet_active, r_packet_active, r_active_mode, r_active_antenna_en}
         !== {d_W_valid_set, d_W_missed_packet, d_W_missed_q,
             d_packet_phase, d_packet_active, d_packet_active_ps, d_active_mode, d_active_antenna_en}) begin
            errors = errors + 1;
            $display("MISMATCH @%0t sc=%0d ref{vs=%b mp=%b mq=%b ph=%0d pa=%b} dut{vs=%b mp=%b mq=%b ph=%0d pa=%b}",
                $time, sample_count,
                r_W_valid_set, r_W_missed_packet, r_W_missed_q, r_packet_phase, r_packet_active,
                d_W_valid_set, d_W_missed_packet, d_W_missed_q, d_packet_phase, d_packet_active);
            if (errors > 20) begin
                $display("TB: FAIL (too many mismatches)");
                $finish;
            end
        end
    end

    // ---- packet driver ----
    integer seed = 32'hB6B6_0007;
    integer pkt, scen, M, back_off, guard;
    integer n_pkts = 0;

    task wait_ticks(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (!iq_tick) @(posedge clk);
            end
        end
    endtask

    task run_packet;
        begin
            // random per-packet config (only while IDLE — write-lock modeled)
            sf               = 7 + ($unsigned($random(seed)) % 6);      // 7..12
            sample_shift     = 1 + ($unsigned($random(seed)) % 2);      // 1..2
            if (sf >= 11) sample_shift = 1;   // runtime cap: M <= 8192
            tacc_window_syms = 1 + ($unsigned($random(seed)) % 3);      // 1..3
            pkt_timeout_syms = 2 + ($unsigned($random(seed)) % 5);      // 2..6
            M = 1 << (sf + sample_shift);
            scen = $unsigned($random(seed)) % 4;
            // 1-in-4 packets: back_off beyond every span -> exercises the
            // clamped-to-zero (already-expired) load path on ref AND dut
            if (($unsigned($random(seed)) % 4) == 0)
                back_off = $unsigned($random(seed)) % (8*M);
            else
                back_off = $unsigned($random(seed)) % (2*M);

            // random idle gap (random tick phase vs lock edge)
            repeat (1 + ($unsigned($random(seed)) % 23)) @(posedge clk);

            // scenario 3: commit while idle (pending applied in IDLE first)
            if (scen == 3) begin
                W_commit = 1; @(posedge clk); W_commit = 0;
                repeat (5) @(posedge clk);
            end

            timing_ref = sample_count - back_off;
            sc_lock = 1;

            case (scen)
                0: begin // clean: training_done then W_commit
                    wait_ticks(tacc_window_syms*M/4 + 2);
                    training_done = 1;
                    wait_ticks(1 + ($unsigned($random(seed)) % (2*M > 4 ? 4 : 2)));
                    W_commit = 1; @(posedge clk); W_commit = 0;
                end
                1: begin // ACQ timeout: no training_done ever
                end
                2: begin // WPEND timeout: training_done, never commit
                    wait_ticks(tacc_window_syms*M/4 + 2);
                    training_done = 1;
                end
                3: begin // pending-from-idle then training_done, no new commit
                    wait_ticks(tacc_window_syms*M/4 + 2);
                    training_done = 1;
                end
            endcase

            // wait for packet to complete (both must agree throughout);
            // guard = generous cap in ticks
            guard = (pkt_timeout_syms + tacc_window_syms + 16) * M + 6*M + back_off + 100;
            while (r_packet_active && guard > 0) begin
                wait_ticks(1);
                guard = guard - 1;
            end
            if (guard == 0) begin
                $display("TB: FAIL guard timeout (ref never ended packet) pkt=%0d scen=%0d sf=%0d", pkt, scen, sf);
                errors = errors + 1;
                $finish;
            end

            // drop lock + training_done (sc_clr model), small drain
            sc_lock = 0;
            training_done = 0;
            repeat (10) @(posedge clk);
            n_pkts = n_pkts + 1;
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        for (pkt = 0; pkt < 40; pkt = pkt + 1)
            run_packet;

        if (errors == 0)
            $display("TB: PASS — %0d packets, all outputs bit-identical every cycle", n_pkts);
        else
            $display("TB: FAIL — %0d mismatches over %0d packets", errors, n_pkts);
        $finish;
    end

    // absolute watchdog
    initial begin
        repeat (4000) #1_000_000; // 4 s sim time (SF12 timeout packets are long)
        $display("TB: FAIL watchdog");
        $finish;
    end

endmodule
