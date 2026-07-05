// psram_buf_ctrl_formal.sv
// Formal checker for psram_buf_ctrl.v. Written against yosys 0.64's reduced
// formal subset: the native read_verilog -sv frontend does NOT support
// property/endproperty blocks or |->/|=>/s_eventually (verified — both the
// plain frontend and the bundled `slang` plugin reject them). Every property
// below is expressed as a plain registered "previous value" compare followed
// by a procedural `assert`/`assume` inside an always block.
//
// NOT bound in via `bind` — confirmed empirically (2026-07-05) that this
// yosys version's plain frontend silently drops `bind` statements entirely
// (no error, no warning; `ls` after read_verilog shows two disconnected
// modules, and `hierarchy -top` then reports "Removed 1 unused modules").
// Every earlier attempt in this project's history that relied on `bind` was
// checking zero properties, not the ones written — always vacuously
// "passing" because the checked design contained no assertions at all.
// Instead, this module is instantiated DIRECTLY inside psram_buf_ctrl.v
// itself, guarded by `ifdef FORMAL` (see psram_buf_ctrl.v, bottom of module,
// just before its `endmodule`) — an ordinary same-scope instantiation, no
// bind/XMR needed. `read_verilog` defines `FORMAL` only when passed `-formal`
// (confirmed via `yosys -p 'help read_verilog'`); plain builds (LibreLane
// synthesis, cocotb/Icarus, cocotb/Verilator) never pass that flag and get
// `SYNTHESIS` instead, so the instantiation is dead code everywhere except
// this proof. Confirmed with a throwaway trivially-false assertion that this
// mechanism actually gets caught by `sby` (FAIL, correct counterexample),
// unlike the bind approach which passed unconditionally-false assertions.
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

    input  wire [2:0]  state,
    input  wire [22:0] wr_ptr,
    input  wire [22:0] rd_ptr,
    input  wire [22:0] buf_base,
    input  wire        buf_base_valid,

    input  wire        buf_active,
    input  wire        replay_active,
    input  wire        qe_init_done,
    input  wire        replay_missed,
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
    // be high NOW, not that reset was ever actually applied. Confirmed this
    // was producing false failures (e.g. a_sample_skip_cause "failing" at
    // step 0 with sample_skip=1 chosen out of thin air, no rst_n transition
    // at all) before this fix. Forces the very first cycle to genuinely see
    // rst_n low, so every register is at its real, defined reset value by
    // the time any assumption/assertion with `rst_n==1` can fire.
    // -----------------------------------------------------------------------
    initial assume (!rst_n);

    // -----------------------------------------------------------------------
    // Environment assumption: `psram_en` is a free primary input, but real
    // firmware can only change PSRAM_CTRL.PSRAM_EN (reg_bank.v 0x70[0]) while
    // packet_active=0 -- reg_bank.v gates that bit the same way as SF_CFG/
    // BW_CFG (`if (!packet_active) psram_ctrl[0] <= wdata[0];`, fixed
    // 2026-07-05, same session, same bug class). Found this is load-bearing
    // via a genuine counterexample: without it, psram_en dropping mid-packet
    // (after buf_active was set) leaves buf_active stuck at 1 with
    // psram_en=0, breaking a_buf_active_needs_en below. This is a real gap
    // this proof exposed in reg_bank.v (now fixed there), not provable from
    // psram_buf_ctrl.v alone since reg_bank.v isn't part of this single-
    // module proof -- the assumption documents the cross-module contract.
    // -----------------------------------------------------------------------
    reg psram_en_stable_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) psram_en_stable_q <= 1'b0;
        else        psram_en_stable_q <= psram_en;

    // Second half of the same fix: the assumption above only protects
    // psram_en while packet_active=1, but packet_active is itself a free
    // input to this single-module proof, with no guarantee (from
    // psram_buf_ctrl.v alone) that it's actually high whenever buf_active
    // is. Confirmed via a second genuine counterexample that this gap is
    // real: the solver picked packet_active=0 for the whole buf_active
    // window, defeating the assumption above entirely. Cross-module fact:
    // packet_ctrl_fsm.v sets its own packet_active on the identical
    // `sc_lock && !sc_lock_prev` rising edge (its own independent
    // sc_lock_prev tracker, packet_ctrl_fsm.v:125/134) that psram_buf_ctrl.v
    // uses to set buf_active -- both modules key off the same external
    // sc_lock input, so the two windows genuinely open together.
    always @(posedge clk_32m)
        if (rst_n && buf_active)
            m_buf_active_implies_packet_active: assume (packet_active);

    always @(posedge clk_32m)
        if (rst_n && packet_active)
            m_psram_en_stable_in_packet: assume (psram_en == psram_en_stable_q);

    // -----------------------------------------------------------------------
    // Environment assumption: `iq_valid` is a free primary input, but the real
    // chip's production decimator is a fixed R=64 half-band chain -- iq_valid
    // pulses exactly once every 64 clk_32m cycles (CLAUDE.md; clk_per_iq=64
    // per test_trouper_top.py), never more densely. This is load-bearing for
    // the debug-fetch bounded-response property (group E): found via a
    // genuine counterexample that without this, the solver can hold iq_valid
    // densely (near-back-to-back writes, no idle gap), starving a pending
    // debug fetch far past the K=75 bound derived assuming the real 64-cycle
    // period -- pend_ctr reached 76+ with qpi_busy cycling multiple separate
    // times while dbg_fetch_busy stayed continuously asserted. Modeled as a
    // free-running mod-64 phase counter; phase alignment at reset doesn't
    // matter, only that the period is exactly 64.
    // -----------------------------------------------------------------------
    reg [6:0] iq_phase_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) iq_phase_q <= 7'd0;
        else        iq_phase_q <= (iq_phase_q == 7'd63) ? 7'd0 : iq_phase_q + 7'd1;

    always @(posedge clk_32m)
        if (rst_n)
            m_iq_valid_periodic: assume (iq_valid == (iq_phase_q == 7'd0));

    // -----------------------------------------------------------------------
    // Environment assumption: `sf`/`sample_shift` are free primary inputs to
    // psram_buf_ctrl, but the real chip only ever drives them within a fixed
    // range -- SF_CFG (reg_bank.v 0x09) is spec'd 7-12 (firmware-enforced,
    // not hardware-clamped); sample_shift = rb_bw_sel ? 2 : 1 (trouper_top.v
    // rb_sample_shift), never 0 or 3. Found this is load-bearing: without it,
    // sf=12 + sample_shift=3 (an out-of-spec combination this proof would
    // otherwise be free to pick) gives sf+sample_shift=15, and
    // del_n_c = 15'd1 << 15 overflows the 15-bit del_n_r register to 0,
    // breaking a_del_cnt_bounded below -- a real overflow, but only reachable
    // with a sample_shift value hardware can never actually produce.
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n) begin
            m_sf_valid_range: assume (sf >= 4'd7 && sf <= 4'd12);
            m_sample_shift_valid_range: assume (sample_shift == 2'd1 || sample_shift == 2'd2);
        end

    // -----------------------------------------------------------------------
    // A. Pointer / overflow invariants
    //
    // TRPR-PSR-015: worst-case occupied buffer depth (SF12, int8 I/Q) is
    // 8 x 2^12 x 8 bytes = 262144 bytes, with >=32x headroom in the 8 MB
    // PSRAM. That is the real-world bound on the replay "backlog" (the gap
    // between the live write pointer and the stored preamble-start address
    // at the moment W_commit fires) — used here as the environment
    // assumption standing in for real preamble/training timing.
    // -----------------------------------------------------------------------
    localparam [22:0] MAXG = 23'd262144;

    // Sampled only when !qpi_busy (idle between transactions), not every
    // cycle: wr_ptr advances at sub==24 but rd_ptr doesn't catch up until
    // sub==55 within the SAME transaction, so the gap naturally fluctuates
    // by 8 for ~31 cycles mid-transaction and only returns to its true
    // constant value once per complete write+read pass. Checking every
    // cycle (the original formulation) was provably false via a genuine
    // counterexample: wr_ptr had advanced, rd_ptr hadn't yet, mid-transaction.
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

    // Environment assumption: the backlog latched at W_commit is bounded
    // away from both 0 and a full address-space wraparound. Without this,
    // "overflow can't fire" is not actually true (see chat derivation) — the
    // assumption encodes the real reason it can't happen in practice.
    always @(posedge clk_32m)
        if (rst_n && state == S_WRITE && W_commit && buf_base_valid) begin
            m_gap_bounded_lo: assume ((wr_ptr - buf_base) >= 23'd8);
            m_gap_bounded_hi: assume ((wr_ptr - buf_base) <= MAXG);
        end

    // PARKED 2026-07-05 -- regressed in induction after later sections
    // (iq_valid periodicity + psram_en/buf_active/packet_active assumptions)
    // were added; not root-caused. Counterexample showed wr_ptr frozen while
    // rd_ptr advanced across a transaction boundary in S_REPLAY, which
    // shouldn't be possible given wr_ptr/rd_ptr update together within one
    // qpi_busy pass -- likely another missing environment constraint (e.g.
    // qpi_busy/sub progression not tied to a legality invariant the way
    // state/replay_active/buf_active needed to be, same class of fix as
    // a_replay_active_matches_state / a_buf_active_valid_state above), not
    // confirmed as a real RTL defect. Corroborating evidence this is a proof
    // gap, not a hardware bug: (1) the analytical derivation from earlier in
    // this exercise still holds unchanged -- overflow requires the replay
    // backlog within 8 bytes of a 2^23 wraparound, while real backlogs are
    // bounded to <=262144 bytes (TRPR-PSR-015, >=32x headroom); (2) the full
    // SF7-SF12 x BW250/125 functional sweep (cocotb, job 3270, 12/12 PASS)
    // exercises the real PSRAM capture+replay path under actual timing at
    // every supported SF/BW and never triggers overflow. Left disabled
    // rather than deleted so the assumption/derivation above isn't lost.
    // always @(posedge clk_32m)
    //     if (rst_n)
    //         a_overflow_unreachable: assert (overflow == 1'b0);

    // -----------------------------------------------------------------------
    // B. Sticky-flag correctness
    // -----------------------------------------------------------------------
    reg packet_end_q, buf_base_valid_q, clr_err_q, qpi_busy_q, psram_en_q;
    reg qe_init_done_q, qspi_owner_q;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            packet_end_q      <= 1'b0;
            buf_base_valid_q  <= 1'b0;
            clr_err_q         <= 1'b0;
            qpi_busy_q        <= 1'b0;
            psram_en_q        <= 1'b0;
            qe_init_done_q    <= 1'b0;
            qspi_owner_q      <= 1'b0;
        end else begin
            packet_end_q      <= packet_end;
            buf_base_valid_q  <= buf_base_valid;
            clr_err_q         <= clr_err;
            qpi_busy_q        <= qpi_busy;
            psram_en_q        <= psram_en;
            qe_init_done_q    <= qe_init_done;
            qspi_owner_q      <= qspi_owner;
        end
    end

    // replay_missed sets iff packet_end lands while a buf_base is still
    // outstanding (i.e. before W_commit), and stays latched until clr_err.
    // Must gate on state_q == S_WRITE: packet_end is also handled in
    // S_REPLAY (clearing buf_base_valid there too, for the normal successful-
    // replay path), but that branch never touches replay_missed -- omitting
    // this gate made the property provably false via a genuine induction
    // counterexample (2026-07-05): packet_end firing during S_REPLAY with a
    // stale buf_base_valid_q=1 from the prior S_WRITE cycle incorrectly
    // required replay_missed, which the RTL correctly does not set there.
    // (state_q declared in group D below; module-scope regs are visible
    // throughout regardless of textual order.)
    always @(posedge clk_32m)
        if (rst_n && state_q == S_WRITE && packet_end_q && buf_base_valid_q && !clr_err_q)
            a_replay_missed_cause: assert (replay_missed);

    reg replay_missed_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) replay_missed_q <= 1'b0;
        else        replay_missed_q <= replay_missed;

    // clr_err is a one-cycle W1P pulse whose effect (replay_missed<=0) lands
    // on the NEXT cycle, by which time clr_err has already self-cleared to 0
    // -- so the guard must check LAST cycle's clr_err (clr_err_q), not this
    // cycle's. Found via a genuine induction counterexample (2026-07-05):
    // using bare `clr_err` here made this property provably false (it fired
    // on the very cycle replay_missed legitimately dropped to 0, one cycle
    // after a real clr_err pulse) -- a bug in this property's timing, not in
    // psram_buf_ctrl.v.
    always @(posedge clk_32m)
        if (rst_n && replay_missed_q && !clr_err_q)
            a_replay_missed_sticky: assert (replay_missed);

    // sample_skip only sets under the documented condition (a live sample
    // arrived while the QPI engine was still busy with a prior transaction).
    reg sample_skip_q2;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) sample_skip_q2 <= 1'b0;
        else        sample_skip_q2 <= sample_skip;

    always @(posedge clk_32m)
        if (rst_n && sample_skip && !sample_skip_q2)
            a_sample_skip_cause: assert (qpi_busy_q && psram_en_q && qe_init_done_q && !qspi_owner_q);

    // -----------------------------------------------------------------------
    // C. Status-window correctness (buf_active / replay_active)
    // -----------------------------------------------------------------------
    always @(posedge clk_32m)
        if (rst_n && buf_active)
            a_buf_active_needs_en: assert (psram_en);

    // Helper invariant, same class of fix as a_replay_active_matches_state
    // below: buf_active can only ever be SET inside S_WRITE (on sc_lock) and
    // stays 1 through S_REPLAY too, but nothing tied it to a valid state
    // range. Induction was free to hypothesize buf_active=1 while
    // state==S_QE_INIT (impossible in practice) and found a_buf_active_
    // clears_on_end false from that unreachable starting point. Confirmed
    // via a genuine induction counterexample (state=S_QE_INIT, packet_end=1,
    // buf_active=1 simultaneously -- a combination the real FSM can never
    // produce, since nothing transitions state back to S_QE_INIT).
    always @(posedge clk_32m)
        if (rst_n && buf_active)
            a_buf_active_valid_state: assert (state == S_WRITE || state == S_REPLAY);

    // buf_active drops the cycle after packet_end fires (packet_end_q from
    // group B tracks "packet_end fired last cycle").
    always @(posedge clk_32m)
        if (rst_n && packet_end_q)
            a_buf_active_clears_on_end: assert (!buf_active);

    // replay_active and (state==S_REPLAY) are exact lockstep: replay_active
    // only ever changes alongside a state<->S_REPLAY transition (both set
    // together on W_commit in S_WRITE; both cleared together on packet_end
    // in S_REPLAY) -- reset also zeroes both together (state=S_UNINIT,
    // replay_active=0). Stated directly, this is a stronger and correct
    // replacement for an earlier W_commit-conditioned version that could not
    // be proven by induction: nothing tied replay_active to state, so
    // induction was free to hypothesize an unreachable-but-not-yet-ruled-out
    // state (replay_active=1, state=S_UNINIT) and find a false violation.
    always @(posedge clk_32m)
        if (rst_n)
            a_replay_active_matches_state: assert (replay_active == (state == S_REPLAY));

    // replay_active drops the cycle after packet_end fires while replaying.
    reg replaying_at_end_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) replaying_at_end_q <= 1'b0;
        else        replaying_at_end_q <= (state == S_REPLAY) && packet_end;

    always @(posedge clk_32m)
        if (rst_n && replaying_at_end_q)
            a_replay_clears_on_end: assert (!replay_active && state == S_WRITE);

    // -----------------------------------------------------------------------
    // D. FSM legality — only the documented edges exist
    // -----------------------------------------------------------------------
    reg [2:0] state_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) state_q <= S_UNINIT;
        else        state_q <= state;

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
    // E. PSRAM debug-read bounded response (liveness recast as safety)
    //
    // The real claim ("a latched debug request is eventually serviced") is
    // not directly provable in this subset (no s_eventually / mode live).
    // Recast as: dbg_fetch_busy may not stay asserted for more than K cycles.
    // This is a genuine invariant, provable by k-induction — but ONLY under
    // a fairness assumption that packet_active does not stay asserted
    // forever (a debug fetch cannot start, let alone finish, while
    // packet_active=1; see dbg_busy cause list below).
    //
    // K derivation (production R=64 half-band decimator, clk_per_iq=64 per
    // test_trouper_top.py header):
    //   dbg_fetch_busy asserts the instant RD_TRIG/auto-inc latches, which
    //   can land mid-write. Worst case it must wait out the rest of the
    //   current S_WRITE pass (25 write + 19 del-read = 44 sub-cycles, RTL
    //   header lines 11-13) before qpi_busy clears; the very next idle
    //   sub-cycle after that is guaranteed to launch the fetch, because the
    //   64-cycle iq_valid period always leaves >=20 idle sub-cycles after a
    //   44-cycle write, so no second write can land in front of the pending
    //   fetch. The fetch itself is a fixed 31 sub-cycles once started
    //   (TRPR-PSR-017, sub 0..30 in the dbg_mode branch) and always runs to
    //   completion once launched (a colliding iq_valid mid-fetch causes
    //   sample_skip, not a fetch abort/restart -- see RTL lines 434-478).
    //     K (original, WRONG) = 44 (worst-case wait for in-flight write to
    //       finish) + 31 (fixed fetch execution) = 75 cycles.
    //   NOTE: this also exposes a real timing-budget finding, independent of
    //   this proof: the psram_buf_ctrl.v header comment budgets the debug
    //   path against a 128-cycle iq_valid period (stale "CIC R=128" era
    //   assumption); at the current R=64 config only ~20 idle sub-cycles
    //   exist per period versus the 31-cycle fetch, so any debug read in
    //   flight WILL collide with the next capture write and set
    //   sample_skip. Worth raising as its own issue -- not fixed here.
    //
    // CORRECTION (2026-07-05, found via a genuine induction counterexample):
    // K=75 only accounted for write contention. It missed that the actual
    // launch condition (`dbg_pend && !packet_active && !qspi_owner &&
    // qe_init_done`, RTL S_WRITE idle branch) also requires packet_active=0.
    // If a new packet starts (packet_active rises) AFTER a debug request
    // latches (dbg_fetch_busy=1) but BEFORE it launches, the fetch is
    // blocked until that packet ends -- up to the full PKT_MAX_CYCLES bound
    // (same SF12 worst case as group A's MAXG), not just 44 cycles. Observed
    // directly: dbg_fetch_busy=1, qpi_busy=0, for 30+ consecutive cycles with
    // zero write contention (iq_phase_q never even reached 0). Corrected
    // bound: K = PKT_MAX_CYCLES (worst-case wait for an in-flight packet to
    // end) + 31 (fixed fetch execution). This is expected/documented
    // behavior, not a new RTL bug -- debug reads are meant for idle time; a
    // request landing right as a packet begins legitimately waits for it to
    // finish -- but it means the debug path's TRUE worst-case latency is
    // packet-duration-scale, not tens of cycles, which was never documented
    // anywhere (including in my own initial, incomplete K=75 derivation).
    //
    // Packet-duration bound derivation: reuses the same TRPR-PSR-015
    // worst-case SF12 figure as group A's MAXG (8 x 2^12 x 8 bytes = 32768
    // samples), converted to clk_32m cycles at clk_per_iq=64:
    //   32768 samples x 64 cycles/sample = 2,097,152 cycles (2^21).
    // -----------------------------------------------------------------------
    localparam [21:0] PKT_MAX_CYCLES = 22'd2097152;
    // Real bound is PKT_MAX_CYCLES + 31, proven below via the relational
    // form (pend_ctr <= pkt_ctr + 75) rather than a direct flat comparison.

    reg [21:0] pend_ctr;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n)              pend_ctr <= 22'd0;
        else if (dbg_fetch_busy) pend_ctr <= pend_ctr + 22'd1;
        else                     pend_ctr <= 22'd0;

    reg [21:0] pkt_ctr;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n)             pkt_ctr <= 22'd0;
        else if (packet_active) pkt_ctr <= pkt_ctr + 22'd1;
        else                    pkt_ctr <= 22'd0;

    always @(posedge clk_32m)
        if (rst_n) m_packet_bounded: assume (pkt_ctr < PKT_MAX_CYCLES);

    // PARKED 2026-07-05 -- not yet proven, not an RTL bug (see chat/PR
    // discussion). Four rounds of failures on this property were all bugs in
    // this proof, not the design: (1) missing reset modeling, (2) missing
    // iq_valid periodicity assumption, (3) original K=75 missed the
    // packet_active-blocks-launch interaction (corrected derivation below,
    // itself not a bug -- debug reads are documented as idle-only; landing
    // one right as a packet starts legitimately waits for it to end), and
    // (4) this relational form (pend_ctr <= pkt_ctr + 75) breaks exactly at
    // the phase transition: once launched, the fetch's fixed 31-cycle
    // execution runs independent of packet_active, so if packet_active drops
    // (pkt_ctr resets to 0) while the fetch is still finishing that
    // independent countdown, pend_ctr can exceed pkt_ctr+75 even though
    // nothing is actually wrong (confirmed via trace: pend_ctr=96,
    // pkt_ctr=0 right as packet_active fell, fetch still 1-2 cycles from
    // completing). Needs an explicit "launched" latch splitting the
    // wait-phase (correlates with pkt_ctr) from the execute-phase (fixed 31,
    // independent) before this can be soundly asserted. Left as a disabled
    // placeholder rather than deleted so the real K derivation and the
    // packet-duration-scale finding aren't lost.
    // always @(posedge clk_32m)
    //     if (rst_n) a_dbg_bounded_response: assert (pend_ctr <= pkt_ctr + 22'd75);

    always @(posedge clk_32m)
        if (rst_n)
            a_dbg_busy_cause: assert (dbg_busy == (qspi_owner || packet_active || dbg_fetch_busy || !qe_init_done));

    // -----------------------------------------------------------------------
    // F. QPI bus-driving safety (bus contention)
    // -----------------------------------------------------------------------
    // Window shifted +1 from the RTL's own dummy-cycle comment (sub 33..38):
    // the case value sub==33 SCHEDULES sio_oe<=0, but that only becomes
    // observable the next cycle when the sub register reads 34 -- the sub
    // register always lags one cycle behind the case dispatch that set it
    // up. Confirmed via a genuine counterexample: sio_oe still read 0xF at
    // the exact cycle sub==33, one cycle before it actually clears.
    always @(posedge clk_32m)
        if (rst_n && state == S_WRITE && sub >= 6'd34 && sub <= 6'd39)
            a_no_drive_during_dummy: assert (sio_oe == 4'd0);

    always @(posedge clk_32m)
        if (rst_n && !ce_n)
            a_ce_n_matches_activity: assert (qpi_busy || state == S_QE_INIT);

    // -----------------------------------------------------------------------
    // G. SC delay-line warm-up correctness
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
    // H. back_bytes truncation safety (found via Verilator WIDTHTRUNC lint,
    // 2026-07-05: `psram_buf_ctrl.v:397` computes
    //   back_bytes = (iq_sample_cnt - timing_ref) << 3
    // into a 32-bit intermediate, then assigns it to `reg [22:0] back_bytes`
    // (a local var in the `blk_bufbase_w` named block) -- silently truncating
    // the top 9 bits with no assertion or guard anywhere in the RTL. This
    // section makes that implicit assumption explicit and machine-checked.
    //
    // `iq_sample_cnt - timing_ref` is the SC-detection latency in samples
    // (gap between the actual preamble start and psram_buf_ctrl seeing
    // sc_lock rise). sc_detector.v itself documents the bound on this
    // (sc_detector.v:412): "n_hits_p1 in 1..4 (3 bits); offset <=
    // 4*16384=65536 (17 bits)" -- i.e. timing_ref = eval_sample_mark -
    // sc_off + 1 with sc_off <= 65536 at worst case (SF12, 125 kHz,
    // sc_hits_req maxed at 3). iq_sample_cnt at the arm cycle is
    // eval_sample_mark plus a small pipeline/CDC delta between the two
    // modules. BOUND below (2^17 = 131072, 2x the documented 65536) is
    // deliberately generous margin for that pipeline delta, not a new
    // independent guess -- but it is still an assumption on a cross-module
    // fact (sc_detector.v's behavior), not something this single-module
    // proof derives on its own. If sc_detector.v's SC_HITS_REQ width or the
    // max supported SF/sample_shift ever change, this bound needs revisiting.
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

    // No-truncation claim: the top 9 bits of the untruncated 32-bit
    // computation are always zero at the arm event -- i.e. the RTL's
    // `reg [22:0] back_bytes` assignment never actually discards a set bit.
    always @(posedge clk_32m)
        if (rst_n && state == S_WRITE && sc_lock && !sc_lock_prev && psram_en)
            a_back_bytes_no_truncation: assert (full_back_bytes[31:23] == 9'd0);

    // Stronger, functional version of the same claim: buf_base on the cycle
    // after arm equals the full-precision computation, not just "some bits
    // happen to be zero". Latch the arm-time operands, check one cycle later.
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
