// psram_buf_ctrl_formal.sv
// Formal checker for psram_buf_ctrl.v — rewritten 2026-07-19 for the
// continuous-delay replay contract (TRPR-RMD-009, commit 46e1cdf): replay is
// started by the training_done-armed margin wait (wait_armed/wait_cnt), NOT
// by W_commit. Covers RPV-F1..F6 from planning/psram-replay-verification-plan.md
// plus the still-valid properties carried over from the 2026-07-05 harness.
//
// Written against yosys 0.64's reduced formal subset: the native
// read_verilog -sv frontend does NOT support property/endproperty blocks or
// |->/|=>/s_eventually (verified — both the plain frontend and the bundled
// `slang` plugin reject them). Every property below is expressed as a plain
// registered "previous value" compare followed by a procedural
// `assert`/`assume` inside an always block.
//
// NOT bound in via `bind` — confirmed empirically (2026-07-05) that this
// yosys version's plain frontend silently drops `bind` statements entirely
// (no error, no warning). Instead, this module is instantiated DIRECTLY
// inside psram_buf_ctrl.v itself, guarded by `ifdef FORMAL (bottom of the
// module, just before its `endmodule`) — an ordinary same-scope
// instantiation, no bind/XMR needed. `read_verilog` defines `FORMAL` only
// when passed `-formal`; plain builds (LibreLane synthesis, cocotb/Icarus,
// cocotb/Verilator) never pass that flag and get `SYNTHESIS` instead, so the
// instantiation is dead code everywhere except this proof.
// NOTE: that `ifdef FORMAL block was deleted from psram_buf_ctrl.v by commit
// 0c0171a, silently making any later sby run vacuous (zero assertions in the
// elaborated design). Restored 2026-07-19 — if it ever goes missing again,
// `sby` will still report PASS but proves nothing; check for the
// u_psram_formal instance before trusting a green run.
//
// State encoding (from psram_buf_ctrl.v, hardcoded here rather than referenced
// by name — localparams are not reliably visible across the module boundary):
//   S_UNINIT=0  S_QE_INIT=1  S_WRITE=2  S_REPLAY=3
//
// Run: cd formal && (inside chipathon26 container) sby -f psram_buf_ctrl.sby

`default_nettype none

module psram_buf_ctrl_formal (
    input  wire        clk_32m,
    input  wire        rst_n,

    input  wire        psram_en,
    input  wire        qspi_owner,
    input  wire        packet_active,
    input  wire [3:0]  sf,
    input  wire [1:0]  sample_shift,
    input  wire        iq_valid,
    input  wire        clr_err,
    input  wire        W_commit,
    input  wire        packet_end,
    input  wire        sc_lock,
    input  wire        sc_lock_prev,
    input  wire [31:0] iq_sample_cnt,
    input  wire [31:0] timing_ref,
    input  wire        training_done,

    input  wire [2:0]  state,
    input  wire [22:0] wr_ptr,
    input  wire [22:0] rd_ptr,
    input  wire [22:0] buf_base,
    input  wire        buf_base_valid,
    input  wire        wait_armed,
    input  wire [15:0] wait_cnt,

    input  wire        buf_active,
    input  wire        replay_active,
    input  wire        qe_init_done,
    input  wire        replay_missed,
    input  wire        w_commit_late,
    input  wire        overflow,
    input  wire        sample_skip,

    input  wire        dbg_busy,
    input  wire        dbg_fetch_busy,
    input  wire        dbg_pend,
    input  wire        dbg_rd_trig,
    input  wire        qpi_busy,

    input  wire        del_rdy,
    input  wire        del_valid,
    input  wire [14:0] del_cnt,
    input  wire [14:0] del_n_r,

    input  wire [3:0]  sio_oe,
    input  wire [5:0]  sub,
    input  wire        ce_n
);

    localparam S_UNINIT  = 3'd0;
    localparam S_QE_INIT = 3'd1;
    localparam S_WRITE   = 3'd2;
    localparam S_REPLAY  = 3'd3;

    // -----------------------------------------------------------------------
    // Reset modeling. `rst_n` is a free primary input to psram_buf_ctrl (not
    // driven by this checker), so without this, step 0 of BMC/k-induction can
    // pick rst_n=1 with every register at an arbitrary/uninitialized value —
    // `if (rst_n && ...)` guards elsewhere in this file only require rst_n to
    // be high NOW, not that reset was ever actually applied. Confirmed
    // (2026-07-05) this was producing false failures before this fix. Forces
    // the very first cycle to genuinely see rst_n low, so every register is
    // at its real, defined reset value by the time any assumption/assertion
    // with `rst_n==1` can fire.
    // -----------------------------------------------------------------------
    initial assume (!rst_n);

    // -----------------------------------------------------------------------
    // Environment assumption: `psram_en` is a free primary input, but real
    // firmware can only change PSRAM_CTRL.PSRAM_EN (reg_bank.v 0x70[0]) while
    // packet_active=0 — reg_bank.v gates that bit the same way as SF_CFG/
    // BW_CFG (fixed 2026-07-05; the gap was found BY this proof). The paired
    // buf_active⇒packet_active assumption documents the cross-module fact
    // that packet_ctrl_fsm.v raises its packet_active on the identical
    // `sc_lock && !sc_lock_prev` rising edge psram_buf_ctrl.v uses to set
    // buf_active — both key off the same external sc_lock input.
    // -----------------------------------------------------------------------
    reg psram_en_stable_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) psram_en_stable_q <= 1'b0;
        else        psram_en_stable_q <= psram_en;

    always @(posedge clk_32m)
        if (rst_n && buf_active)
            m_buf_active_implies_packet_active: assume (packet_active);

    always @(posedge clk_32m)
        if (rst_n && packet_active)
            m_psram_en_stable_in_packet: assume (psram_en == psram_en_stable_q);

    // -----------------------------------------------------------------------
    // Environment assumption: `iq_valid` pulses exactly once every 64 clk_32m
    // cycles (production R=64 half-band decimator; clk_per_iq=64 per
    // test_trouper_top.py). Load-bearing for the debug-fetch bounded-response
    // derivation (group E) — found 2026-07-05 via a genuine counterexample
    // that dense iq_valid starves a pending debug fetch past any fixed bound.
    // Modeled as a free-running mod-64 phase counter; phase alignment at
    // reset doesn't matter, only that the period is exactly 64.
    // -----------------------------------------------------------------------
    reg [6:0] iq_phase_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) iq_phase_q <= 7'd0;
        else        iq_phase_q <= (iq_phase_q == 7'd63) ? 7'd0 : iq_phase_q + 7'd1;

    always @(posedge clk_32m)
        if (rst_n)
            m_iq_valid_periodic: assume (iq_valid == (iq_phase_q == 7'd0));

    // -----------------------------------------------------------------------
    // Environment assumption: sc_lock is LEVEL-HELD by sc_detector from lock
    // until sc_clr (= packet_end) — a new rising edge cannot occur while a
    // packet window is still open (verified 2026-07-12, Open Risks #25; the
    // same fact the RTL's S_REPLAY exit comment and packet_ctrl_fsm's
    // removed re-lock branch rely on). Load-bearing: found via a genuine
    // basecase counterexample (2026-07-19, a_rd_ptr_frame) where a free
    // sc_lock re-edge landed on the same cycle as the margin-met S_REPLAY
    // entry, recomputing buf_base in the very cycle rd_ptr loaded the old
    // value — a coincidence the real detector can never produce, since
    // buf_base_valid is only high between lock and packet_end.
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && buf_base_valid)
            m_sc_lock_level_held: assume (!(sc_lock && !sc_lock_prev));

    // -----------------------------------------------------------------------
    // Environment assumption: sf ∈ [7,12] (SF_CFG spec range) and
    // sample_shift ∈ {1,2} (trouper_top.v: rb_bw_sel ? 2 : 1, never 0/3).
    // Load-bearing (2026-07-05): sf=12 + sample_shift=3 overflows the 15-bit
    // del_n_r to 0 — real overflow, but only with a sample_shift value the
    // hardware can never produce.
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n) begin
            m_sf_valid_range: assume (sf >= 4'd7 && sf <= 4'd12);
            m_sample_shift_valid_range: assume (sample_shift == 2'd1 || sample_shift == 2'd2);
        end

    // -----------------------------------------------------------------------
    // Shared "previous value" trackers used across groups
    // -----------------------------------------------------------------------
    reg [2:0]  state_q;
    reg        packet_end_q, buf_base_valid_q, clr_err_q, qpi_busy_q, psram_en_q;
    reg        qe_init_done_q, qspi_owner_q, W_commit_q, replay_active_q;
    reg        wait_armed_q;
    reg [15:0] wait_cnt_q;
    reg [22:0] rd_ptr_q;
    reg [5:0]  sub_q;
    reg        lock_edge_q;      // S_WRITE sc_lock rising edge (packet start)
    reg        td_edge_q;        // training_done rising edge (own tracker —
                                 // resets to 0 like the RTL's training_done_prev,
                                 // so the two stay in lockstep after reset)
    reg        td_prev_m;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            state_q           <= S_UNINIT;
            packet_end_q      <= 1'b0;
            buf_base_valid_q  <= 1'b0;
            clr_err_q         <= 1'b0;
            qpi_busy_q        <= 1'b0;
            psram_en_q        <= 1'b0;
            qe_init_done_q    <= 1'b0;
            qspi_owner_q      <= 1'b0;
            W_commit_q        <= 1'b0;
            replay_active_q   <= 1'b0;
            wait_armed_q      <= 1'b0;
            wait_cnt_q        <= 16'd0;
            rd_ptr_q          <= 23'd0;
            sub_q             <= 6'd0;
            lock_edge_q       <= 1'b0;
            td_edge_q         <= 1'b0;
            td_prev_m         <= 1'b0;
        end else begin
            state_q           <= state;
            packet_end_q      <= packet_end;
            buf_base_valid_q  <= buf_base_valid;
            clr_err_q         <= clr_err;
            qpi_busy_q        <= qpi_busy;
            psram_en_q        <= psram_en;
            qe_init_done_q    <= qe_init_done;
            qspi_owner_q      <= qspi_owner;
            W_commit_q        <= W_commit;
            replay_active_q   <= replay_active;
            wait_armed_q      <= wait_armed;
            wait_cnt_q        <= wait_cnt;
            rd_ptr_q          <= rd_ptr;
            sub_q             <= sub;
            lock_edge_q       <= (state == S_WRITE && sc_lock && !sc_lock_prev && psram_en);
            td_edge_q         <= (training_done && !td_prev_m);
            td_prev_m         <= training_done;
        end
    end

    // -----------------------------------------------------------------------
    // RPV-F1. S_REPLAY entry cause — the ONLY way in is the margin-met
    // condition (wait_armed && wait_cnt==0 && !qpi_busy && psram_en &&
    // !packet_end, evaluated in S_WRITE). Asserting the exact enabling
    // condition also proves the "never from W_commit" half of the plan item:
    // W_commit appears nowhere in it.
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && state == S_REPLAY && state_q == S_WRITE)
            a_replay_entry_cause: assert (wait_armed_q && wait_cnt_q == 16'd0 &&
                                          !qpi_busy_q && psram_en_q && !packet_end_q);

    // -----------------------------------------------------------------------
    // RPV-F2. Margin-wait scope: wait_armed exists only inside an S_WRITE
    // packet window (armed at the training_done edge with buf_base_valid,
    // cleared by S_REPLAY entry and by packet_end — a same-cycle packet_end
    // wins over a same-cycle arm because the packet_end block is textually
    // after the arm block and nonblocking last-write-wins). It can therefore
    // never survive into the idle period or into S_REPLAY.
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && wait_armed)
            a_wait_armed_scope: assert (state == S_WRITE && buf_base_valid);

    always @(posedge clk_32m)
        if (rst_n && packet_end_q)
            a_wait_cleared_on_end: assert (!wait_armed);

    // wait_cnt frame: only the arm-event load (training_done edge in S_WRITE)
    // or a single armed decrement (at write-done, never below 0) may change it.
    always @(posedge clk_32m)
        if (rst_n && wait_cnt != wait_cnt_q)
            a_wait_cnt_frame: assert (
                (state_q == S_WRITE && td_edge_q) ||
                (wait_armed_q && wait_cnt_q != 16'd0 && wait_cnt == wait_cnt_q - 16'd1)
            );

    // -----------------------------------------------------------------------
    // RPV-F3. rd_ptr frame: rd_ptr changes exactly twice per life-cycle —
    // the buf_base load on the S_WRITE→S_REPLAY transition, and the +8
    // advance at replay-read-done (sub==55 dispatch). This is the mechanised
    // "delay line never rewinds" claim of TRPR-RMD-009.
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && rd_ptr != rd_ptr_q)
            a_rd_ptr_frame: assert (
                (state == S_REPLAY && state_q == S_WRITE && rd_ptr == buf_base) ||
                (state_q == S_REPLAY && qpi_busy_q && sub_q == 6'd55 &&
                 rd_ptr == ((rd_ptr_q + 23'd8) & 23'h7FFFFF))
            );

    // -----------------------------------------------------------------------
    // RPV-F4. w_commit_late: set only when a W_commit lands while the replay
    // is already running; sticky until clr_err or the next packet start
    // (S_WRITE sc_lock rising edge clears the per-packet flag).
    // -----------------------------------------------------------------------
    reg w_commit_late_q2;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) w_commit_late_q2 <= 1'b0;
        else        w_commit_late_q2 <= w_commit_late;

    always @(posedge clk_32m)
        if (rst_n && w_commit_late && !w_commit_late_q2)
            a_wcl_cause: assert (W_commit_q && replay_active_q);

    always @(posedge clk_32m)
        if (rst_n && w_commit_late_q2 && !clr_err_q && !lock_edge_q)
            a_wcl_sticky: assert (w_commit_late);

    // -----------------------------------------------------------------------
    // RPV-F5. Overflow unreachability. The 2026-07-05 attempt was PARKED
    // (induction regressed on pointer motion across transaction boundaries,
    // never root-caused). The continuous-delay design makes this provable:
    // the write/read gap is a compile-time-fixed delay distance set at
    // S_REPLAY entry and preserved by the interleaved +8/+8 advances. The
    // proof splits each transaction into its two pointer phases, with
    // explicit sub-range legality so induction cannot start from an
    // unreachable sub value:
    //   phase 1 (idle, or sub<=24: before the write advance): gap == G
    //   phase 2 (sub 25..55: wr advanced, rd not yet):          gap == G+8
    // with G ∈ [8, MAXG] pinned by the entry assumption below. rd_ptr ==
    // wr_ptr at the sub==55 dispatch (the RTL's overflow set condition)
    // would need gap == 0 in phase 2 — excluded by the [16, MAXG+8] bound.
    //
    // MAXG = 2^22 (4 MB): generous cover for the true worst-case entry gap =
    // SC-latency backlog (≤ 2^20 bytes, group H bound) + training window
    // (≤ 15 syms × 16384 samples × 8 = 1.9 MB, SF12/BW125) + margin
    // (≤ 65535 samples × 8 = 0.5 MB) ≈ 3.5 MB — still < 2^23−8, which is
    // all the overflow argument needs.
    // -----------------------------------------------------------------------
    localparam [22:0] MAXG = 23'd4194304; // 2^22

    wire [22:0] gap_now = (wr_ptr - rd_ptr) & 23'h7FFFFF;

    // Entry assumption: at the margin-met cycle the preamble backlog is at
    // least one sample and bounded by MAXG. Stands in for the cross-module
    // timing_ref/training_acc timing relationship (same role the old
    // W_commit-conditioned m_gap_bounded_lo/hi played).
    always @(posedge clk_32m)
        if (rst_n && state == S_WRITE && wait_armed && wait_cnt == 16'd0 &&
            !qpi_busy && psram_en && !packet_end) begin
            m_entry_gap_lo: assume (((wr_ptr - buf_base) & 23'h7FFFFF) >= 23'd8);
            m_entry_gap_hi: assume (((wr_ptr - buf_base) & 23'h7FFFFF) <= MAXG);
        end

    // sub legality in S_REPLAY: the engine never runs past the read-done
    // dispatch. Blocks induction from hypothesizing sub∈[56,63] states whose
    // default-arm recovery would smear the phase invariants.
    always @(posedge clk_32m)
        if (rst_n && state == S_REPLAY && qpi_busy)
            a_replay_sub_bound: assert (sub <= 6'd55);

    always @(posedge clk_32m)
        if (rst_n && state == S_REPLAY && (!qpi_busy || sub <= 6'd24))
            a_replay_gap_phase1: assert (gap_now >= 23'd8 && gap_now <= MAXG);

    always @(posedge clk_32m)
        if (rst_n && state == S_REPLAY && qpi_busy && sub >= 6'd25)
            a_replay_gap_phase2: assert (gap_now >= 23'd16 && gap_now <= MAXG + 23'd8);

    // The payoff: the old sticky can never set (RPV-F5 proper).
    always @(posedge clk_32m)
        if (rst_n)
            a_overflow_unreachable: assert (!overflow);

    // Carried over unchanged (still holds — between transactions the gap is
    // constant across the whole S_REPLAY residency). Sampled only when
    // !qpi_busy: wr_ptr advances at sub==24 but rd_ptr doesn't catch up until
    // sub==55 within the SAME transaction (2026-07-05 counterexample).
    reg [22:0] gap_q;
    reg        gap_valid_q;

    always @(posedge clk_32m)
        if (rst_n && state == S_REPLAY && !qpi_busy && gap_valid_q)
            a_gap_invariant: assert (gap_q == (wr_ptr - rd_ptr));

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            gap_q       <= 23'd0;
            gap_valid_q <= 1'b0;
        end else if (state == S_REPLAY && !qpi_busy) begin
            gap_q       <= wr_ptr - rd_ptr;
            gap_valid_q <= 1'b1;
        end else if (state != S_REPLAY) begin
            gap_valid_q <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // B. Sticky-flag correctness (RPV-F6 carry-over; replay_missed semantics
    // updated: it now means "packet ended before the margin was ever met" —
    // structurally the same trigger as before (packet_end in S_WRITE with
    // buf_base_valid still outstanding), so the property shape is unchanged.
    // Must gate on state_q == S_WRITE: packet_end is also handled in S_REPLAY
    // (normal successful-replay teardown) without touching replay_missed
    // (2026-07-05 counterexample).
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && state_q == S_WRITE && packet_end_q && buf_base_valid_q && !clr_err_q)
            a_replay_missed_cause: assert (replay_missed);

    reg replay_missed_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) replay_missed_q <= 1'b0;
        else        replay_missed_q <= replay_missed;

    // clr_err is a one-cycle W1P pulse whose effect lands on the NEXT cycle —
    // the guard must check LAST cycle's clr_err (2026-07-05 counterexample).
    always @(posedge clk_32m)
        if (rst_n && replay_missed_q && !clr_err_q)
            a_replay_missed_sticky: assert (replay_missed);

    // sample_skip only sets under the documented condition.
    reg sample_skip_q2;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) sample_skip_q2 <= 1'b0;
        else        sample_skip_q2 <= sample_skip;

    always @(posedge clk_32m)
        if (rst_n && sample_skip && !sample_skip_q2)
            a_sample_skip_cause: assert (qpi_busy_q && psram_en_q && qe_init_done_q && !qspi_owner_q);

    // -----------------------------------------------------------------------
    // C. Status-window correctness (RPV-F6 carry-over, plus the new
    // buf_base_valid == buf_active lockstep the continuous-delay RTL
    // maintains: both set on the S_WRITE lock edge, both cleared together on
    // packet_end in either state).
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && buf_active)
            a_buf_active_needs_en: assert (psram_en);

    always @(posedge clk_32m)
        if (rst_n && buf_active)
            a_buf_active_valid_state: assert (state == S_WRITE || state == S_REPLAY);

    always @(posedge clk_32m)
        if (rst_n)
            a_buf_base_valid_matches_active: assert (buf_base_valid == buf_active);

    always @(posedge clk_32m)
        if (rst_n && packet_end_q)
            a_buf_active_clears_on_end: assert (!buf_active);

    // replay_active and (state==S_REPLAY) are exact lockstep — both set
    // together on the margin-met cycle, both cleared together on packet_end.
    always @(posedge clk_32m)
        if (rst_n)
            a_replay_active_matches_state: assert (replay_active == (state == S_REPLAY));

    reg replaying_at_end_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) replaying_at_end_q <= 1'b0;
        else        replaying_at_end_q <= (state == S_REPLAY) && packet_end;

    always @(posedge clk_32m)
        if (rst_n && replaying_at_end_q)
            a_replay_clears_on_end: assert (!replay_active && state == S_WRITE);

    // -----------------------------------------------------------------------
    // D. FSM legality — only the documented edges exist (RPV-F6 carry-over)
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n) begin
            case (state_q)
                S_UNINIT:  a_legal_from_uninit:  assert (state == S_UNINIT  || state == S_QE_INIT);
                S_QE_INIT: a_legal_from_qeinit:  assert (state == S_QE_INIT || state == S_WRITE);
                S_WRITE:   a_legal_from_write:   assert (state == S_WRITE   || state == S_REPLAY);
                S_REPLAY:  a_legal_from_replay:  assert (state == S_REPLAY  || state == S_WRITE);
                default:   a_legal_from_default: assert (state == S_UNINIT);
            endcase
        end

    // -----------------------------------------------------------------------
    // E. Debug-read plumbing (RPV-F6 carry-over). The bounded-response
    // property remains PARKED — the K derivation and the packet-duration-
    // scale latency finding are preserved in git history (2026-07-05
    // harness); the dbg_busy cause equality below is the live remnant.
    // -----------------------------------------------------------------------
    localparam [21:0] PKT_MAX_CYCLES = 22'd2097152;

    reg [21:0] pkt_ctr;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n)             pkt_ctr <= 22'd0;
        else if (packet_active) pkt_ctr <= pkt_ctr + 22'd1;
        else                    pkt_ctr <= 22'd0;

    always @(posedge clk_32m)
        if (rst_n) m_packet_bounded: assume (pkt_ctr < PKT_MAX_CYCLES);

    always @(posedge clk_32m)
        if (rst_n)
            a_dbg_busy_cause: assert (dbg_busy == (qspi_owner || packet_active || dbg_fetch_busy || !qe_init_done));

    // -----------------------------------------------------------------------
    // F. QPI bus-driving safety (RPV-F6 carry-over). Window shifted +1 from
    // the RTL's dummy-cycle comment: the sub register lags the case dispatch
    // that scheduled sio_oe<=0 by one cycle (2026-07-05 counterexample).
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && state == S_WRITE && sub >= 6'd34 && sub <= 6'd39)
            a_no_drive_during_dummy: assert (sio_oe == 4'd0);

    always @(posedge clk_32m)
        if (rst_n && !ce_n)
            a_ce_n_matches_activity: assert (qpi_busy || state == S_QE_INIT);

    // -----------------------------------------------------------------------
    // G. SC delay-line warm-up correctness (RPV-F6 carry-over)
    // -----------------------------------------------------------------------
    reg del_rdy_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) del_rdy_q <= 1'b0;
        else        del_rdy_q <= del_rdy;

    always @(posedge clk_32m)
        if (rst_n && del_valid)
            a_del_valid_needs_rdy: assert (del_rdy_q);

    always @(posedge clk_32m)
        if (rst_n)
            a_del_cnt_bounded: assert (del_rdy || del_cnt < del_n_r);

    // -----------------------------------------------------------------------
    // H. back_bytes truncation safety (RPV-F6 carry-over, unchanged — the
    // buf_base computation at the lock edge is identical in the continuous-
    // delay design). BOUND = 2^17 = 2× sc_detector.v's documented worst-case
    // SC-detection latency (sc_off ≤ 4×16384 = 65536), generous margin for
    // the inter-module pipeline delta. If sc_detector.v's SC_HITS_REQ width
    // or the max supported SF/sample_shift ever change, revisit this bound.
    // -----------------------------------------------------------------------
    localparam [31:0] BACK_BYTES_DELTA_BOUND = 32'd131072; // 2^17

    wire [31:0] tacc_delta          = iq_sample_cnt - timing_ref;
    wire [31:0] full_back_bytes     = tacc_delta << 3; // untruncated, 32-bit
    reg  [22:0] wr_ptr_at_arm_q;
    reg  [31:0] full_back_bytes_at_arm_q;
    reg         arm_pending_q;

    always @(posedge clk_32m)
        if (rst_n && state == S_WRITE && sc_lock && !sc_lock_prev && psram_en)
            m_back_bytes_delta_bounded: assume (tacc_delta <= BACK_BYTES_DELTA_BOUND);

    always @(posedge clk_32m)
        if (rst_n && state == S_WRITE && sc_lock && !sc_lock_prev && psram_en)
            a_back_bytes_no_truncation: assert (full_back_bytes[31:23] == 9'd0);

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_at_arm_q          <= 23'd0;
            full_back_bytes_at_arm_q <= 32'd0;
            arm_pending_q            <= 1'b0;
        end else begin
            arm_pending_q <= (state == S_WRITE && sc_lock && !sc_lock_prev && psram_en);
            if (state == S_WRITE && sc_lock && !sc_lock_prev && psram_en) begin
                wr_ptr_at_arm_q          <= wr_ptr;
                full_back_bytes_at_arm_q <= full_back_bytes;
            end
        end
    end

    always @(posedge clk_32m)
        if (rst_n && arm_pending_q)
            a_buf_base_matches_full_precision: assert (
                buf_base == ((wr_ptr_at_arm_q - full_back_bytes_at_arm_q[22:0]) & 23'h7FFFFF)
            );

endmodule
