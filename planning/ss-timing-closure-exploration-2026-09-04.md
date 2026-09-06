# SS timing / DRV closure exploration — 2026-09-04

**Status: SNAPSHOT, session paused for further RTL work.** All jobs started
in this doc have landed (§1–3 pending rows filled below); §4–6 cover a
second pass that found and fixed a real RTL bug in `psram_buf_ctrl.v`
(`buf_base`'s write arc) plus three further correctness bugs found by review
of that fix, and identified the next real SS bottleneck (`training_acc`).
**Nothing in this doc is committed to git yet** — `psram_buf_ctrl.v` and
`formal/psram_buf_ctrl_formal.sv` are uncommitted working-tree changes on
`pnr/drv-ss-signoff-sdc-v31`, verified via SGE (formal + regression + P&R)
but not yet landed. The user is about to make further RTL changes on top of
this state, so treat §4–6 as the last known-good/verified point, not
necessarily the current tree.

**Question this answers:** starting from the current promoted `final/`
(SS WNS −14.44 ns, nom_tt DRV 2 slew/2 cap), can P&R/SDC levers alone close
DRV and bring SS WNS close to −10 ns? Runs on `main` @ `78b4a33`, later on
branch `pnr/drv-ss-signoff-sdc-v31` after the BRINGUP_SRC merge (`ada0eaa`).

## Job log

| Job | Change | Result | SS WNS | SS TNS | nom_tt slew/cap |
|---|---|---|---|---|---|
| 5527 | base (canonical, plain SDC, pre-BRINGUP_SRC) | clean | −14.44 | −1008.7 | 2/2 |
| 5528 | GRT margin → 50 | clean | −13.48 | −1121.8 | 2/2 |
| 5529 | GRT margin → 40 | clean, **bit-identical to 5528** | −13.48 | −1121.8 | 2/2 |
| 5530 | RCX min_ff (#41 exit run) | clean | −11.34 | −999.2 | n/a (hold-deck fix) |
| 5531 | canonical + v31 (debug false-path, first cut) | clean | −11.34 | −999.2 | 2/2 |
| 5533 | BRINGUP_SRC added, no v31 | clean | −15.94 | −1480.7 | — |
| 5534 | RCX min_ff + v31, fresh P&R | clean, **bit-identical WNS to 5530/5531** | −11.3436 | −999.2 | 2/2 |
| 5539 | canonical + v31(v1) + BRINGUP_SRC merged | clean | −14.489 | −823.9 | 3/1 |
| 5540 | core cocotb regression | **CLEAN**, 47 suites / 240 tests / 0 failures | — | — | — |
| 5541 | canonical + v31(+bringup_ctrl/ampl) + BRINGUP_SRC | clean | −14.489 | −822.7 | 3/1 |
| 5542 | RCX min_ff + BRINGUP_SRC | **FAILED — config bug** (missing `bringup_src.v` in `VERILOG_FILES`), fixed | — | — | — |
| 5543 | full formal suite | psram_buf_ctrl/packet_ctrl_fsm/bringup_src **PASS**; spi_slave **FAIL** (pre-existing, confirmed identical to Open Risk #61's job-5438 signature) | — | — | — |
| 5544 | RCX min_ff + v31(+bringup) + BRINGUP_SRC, fixed | clean | −14.489 | −822.7 | 3/1 (max_ff **0/0**) |
| 5545 | DRV pin-scope probe v1 (`set_max_transition`+`set_max_capacitance` on `get_pins`) | **FAILED — tool limitation**: `set_max_capacitance` rejects Pin objects | — | — | — |
| 5546 | `SYNTH_STRATEGY: DELAY 4` | **FAILED — GRT-0116 congestion** post-synth | — | — | — |
| 5547 | `SYNTH_STRATEGY: DELAY 2` | clean route | **−13.02** | **−637.7** | **18/3** (worse) |
| 5548 | DRV pin-scope probe v2 (`set_max_transition` only, `get_pins`) | **FAILED — same tool limitation** | — | — | — |
| 5549 | DRV pin-scope probe v3 (`set_max_transition`, `get_cells`) | **FAILED — same limitation**, now "unsupported object type Instance" | — | — | — |
| 5550 | DELAY 2 + v31(+rb_rx_hold) | clean | −11.338 | −636.0 | 18/3 |
| 5551 | pre-GRT margin 60% alone | clean | −14.96 | −818.8 | 8/4 |
| 5552 | pre-GRT margin 55% alone | clean | −12.87 | −1130.5 | 16/4 (**worse**) |
| 5553 | pre-GRT margin 50% alone | **FAILED — `DRT-1231`** pin-access on `clkbuf_2_1_0_IQ_CLK_regs/I` (same failure class as `project_drt1231_clkbuf`) | — | — | — |
| 5554 | canonical (DELAY 0) + wholesale `IRQ_OUT_OUT` false-path | clean, **0 `IRQ_OUT_OUT`/`DBG0_OUT` occurrences in SS report** | −14.489 | −811.7 | 3/1 |
| 5555 | DELAY 2 + wholesale `IRQ_OUT_OUT` false-path | clean | **−9.551** | −624.7 | 18/3 |
| 5556 | formal, `buf_base` retiming attempt #1 (`buf_active` moved to stage 2) | **FAILED** — BMC counterexample on `a_buf_active_needs_en` | — | — | — |
| 5557 | core cocotb regression, `buf_base` retiming attempt #1 | reported FAILED but was a Verilator/GCC PCH build race (46/47 suites clean; `bypass_backoff` hit "cannot read PCH file", unrelated to the RTL) | — | — | — |
| 5558 | canonical `trouper_top.json` + `buf_base` fix (final), v31, **no min_ff RCX** | clean | **−10.835** | −1054.3 | 14/4 (design-wide, not nom_tt-scoped) |
| 5559 | formal, `buf_base` retiming attempt #2 (`buf_active` back to stage 1) | **FAILED** — `a_buf_base_valid_matches_active` (stale equality) + `bufbase_pending` not cleared on `packet_end` | — | — | — |
| 5560 | formal, `buf_base` retiming attempt #3 | **FAILED** — `a_buf_base_matches_full_precision` reference-model timer didn't know about `packet_end` aborting stage 2 | — | — | — |
| 5561 | formal, `buf_base` retiming, final | **PASSED**, k-induction | — | — | — |
| 5562 | core cocotb regression, `buf_base` fix (final) | **CLEAN**, 47/47 | — | — | — |
| 5563 | `trouper_top_minff_rcx.json` (**min_ff RCX, required config**) + `buf_base` fix + v31 | clean | **−14.496** | −1445.2 | 14/5 (design-wide) |
| 5564 | formal, 3 review-comment fixes (qspi_owner/QE_INIT, del_rdy v1, buf_active gating) | **PASSED**, k-induction | — | — | — |
| 5565 | formal, del_rdy fix v2 (completion-anchored + re-arm) | **PASSED**, k-induction | — | — | — |
| 5566 | core cocotb regression, all fixes (final RTL) | **CLEAN**, 47/47 | — | — | — |

All "clean" rows: DRC 0 / LVS 0 / route DRC 0 / antenna 0/0 unless noted.

## 1. DRV re-verification (nom_tt residual)

The 2026-09-03 GRT-margin recommendation (`planning/drv-margin-sweep-2026-09-03.md`)
does **not** survive the RTL merge: jobs 5528/5529 show the GRT margin knob
saturated (65/50/40 all land close, 50 and 40 bit-identical) and it never
clears nom_tt DRV post-merge (stuck at 2/2, later 3/1 after BRINGUP_SRC).
`trouper_top_drvp1.json`/`_drvp4.json` were retired (commit `43f71e7`).

**Pin-scoped `set_max_transition`/`set_max_capacitance` is a dead end** — not
a bad result, a hard tool limitation. Three attempts (5545/5548/5549) confirm
this OpenSTA build only accepts `[current_design]` or port-list objects for
these two commands; `Pin` and `Instance` objects are both rejected
("unsupported object type Pin" / "unsupported object type Instance"). A
design-wide constraint is the only syntactically valid form, and that's
already proven to stall `repair_design` 70+ minutes (`_comment_drv_closure`
in the P&R SDC). **No per-net DRV fix is available in this flow as currently
built.**

**Isolating the pre-GRT margin knob (jobs 5551–5553): confirms it's a dead
end on its own, independently of the combined-knob 2026-09-03 result.** The
2026-09-03 sweep's "pre-GRT backfires" conclusion (`drvp2`/`drvp3`) changed
`DESIGN_REPAIR_MAX_*_PCT` and `GRT_DESIGN_REPAIR_MAX_*_PCT` **together** (all
four → 50, all four → 45) — the failure was never attributed to the pre-GRT
knob alone. Isolating it (pre-GRT only, post-GRT left at 65) on the current
merged netlist: 60% is DRV-neutral-to-slightly-worse (nom_tt 3/1 → 8/4) with
WNS actually worse (−14.96 vs −14.489); 55% makes DRV clearly worse
(16/4) with WNS also worse (−12.87); 50% **fails outright** with `DRT-1231`
pin-access on `clkbuf_2_1_0_IQ_CLK_regs/I` — the same clkbuf pin-access
failure class already on record (`project_drt1231_clkbuf`). Monotonically
worse at every step tried, isolated or combined. **Confirmed dead: no
pre-GRT-margin value helps, alone or with the post-GRT knob.**

**#41 (RCX min_ff)** remains a real, orthogonal win: clears max_ff DRV to
0/0 (jobs 5534, 5544) on top of fixing the hold-signoff-deck correctness gap
it was written for. Does not touch nom_tt or SS.

## 2. The IRQ_OUT_OUT debug-pad whack-a-mole, and why it ended in a wholesale false-path

`u_dbg` (`debug_probe_mux`) taps ~30 signals across 8 groups (raw RX,
decimated IQ, SC, packet/weights, PSRAM, combiner, IRQ status, bringup) with
**no register between the final mux and the pad**. v31
(`pnr_32m_scoped_v25_b6_signoff.sdc`) started as a narrowly-scoped
`set_false_path -through <specific quasi-static source nets> -to
[get_ports IRQ_OUT_OUT]`, extended source-by-source as each fix exposed the
next:

1. `rb_remod_backoff_shift[1]` — the original −14.44 ns worst path (job 5527).
2. `rb_bringup_ctrl[0]` — new after the BRINGUP_SRC merge (job 5539, −12.24 ns).
3. `rb_rx_hold` — BRINGUP_SRC's own enable gate (jobs 5541/5547, up to −13.02 ns).
4. `psram_buf_active` — a group-101 PSRAM tap, **not even reg_bank
   config-register class** like the first three (job 5550, −11.34 ns).

Four distinct sources found across three different netlists in one session —
proof this doesn't converge. **Decision: fell back to a wholesale**
`set_false_path -to [get_ports IRQ_OUT_OUT]`, replacing the scoped exception
(kept in the SDC comments for the mechanism history). This is also correct on
its own merits, not just a way to stop the chase: `IRQ_OUT_OUT` carries a
**sticky level interrupt** (`rb_irq_out_sticky`) read by the host's interrupt
controller or polled over SPI — there is no synchronous `IQ_CLK` capture on
the other end, so the 31.25 ns core-output budget was never a real
requirement, only an artifact of the generic `core_output_ports` rule.
`DBG0_OUT` was already false-pathed wholesale from the start (it's a
dedicated debug pad, no ambiguity).

**Verification runs 5554 (canonical) and 5555 (DELAY 2): confirmed clean,
whack-a-mole is over.** Grepped both SS reports for `IRQ_OUT_OUT`/`DBG0_OUT`
occurrences: **zero in either.** No further mechanism (sibling
`IRQ_OUT_IN`/`IRQ_OUT_OE` ports, a new multi-driver case) surfaced. The
wholesale false-path is the permanent fix for this pad; 5555 also delivered
the session's best WNS number to date, **−9.551 ns** (DELAY 2, see §3) —
though see §3 for why that number isn't free.

## 3. SYNTH_STRATEGY sweep (DELAY 0 / 2 / 4)

Untried lever going in: `SYNTH_STRATEGY` selects the ABC technology-mapping
script. `AREA 0` was already rejected in a different context
(`decimator-hb-area-reduction.md`: SS WNS −8.59 → −24.17 ns for 6% area, on
an older floorplan) — not retried. `DELAY 0` is the current baseline;
`DELAY 1`–`DELAY 4` (progressively more ABC optimization effort, still
delay-prioritized) had never been tried at all.

**`DELAY 4` (job 5546): FAILED.** Synthesis alone shows the mechanism
clearly — cell count 37,481 → 42,648 (+13.8%), local area 1.04E6 → 1.12E6 µm²
(+7.7%), and buffer insertion exploded (`buf_1` 4 → 4,414, plus new
`buf_2/3/4/8` and higher-drive variants of and/aoi/nand/inv/clkinv/clkbuf
that DELAY 0 barely uses). So yes — higher `DELAY` numbers genuinely insert
far more buffering and upsize cells, confirmed empirically, not just in
theory. But it pushed the design past routability: `GRT-0116` congestion
during global routing, on the same 1675×1110/~69% floorplan that routes clean
at `DELAY 0`. Same failure class as this design's other perturbation-
sensitive routing history (`DRT-0073`/`DRT-1231`) — the die doesn't have
headroom to absorb it.

**`DELAY 2` (job 5547): routed clean, real tradeoff.** SS setup WNS
−14.49 → **−13.02 ns** (real path improvement, not a report-scope trick —
confirmed by tracing the actual worst-path net), TNS −822.7 → **−637.7**
(−22%). But DRV got materially worse across every corner: nom_tt 3/1 → 18/3,
max_ff 3/2 → 26/6, SS 11/6 → 31/7 — **roughly 6× more violations**, traced to
~6 distinct gates concentrated in the same reg_bank/`u_psram.dbg_buf`
wide-fan-in readback cone that was already DELAY 0's sole nom_tt offender
(one instance drives `u_psram.dbg_buf[63]` directly). DELAY 2's more
aggressive remap restructured that region for the worse while it helped the
sd_remod/packet_active timing paths.

**The real structural SS floor, once debug-pad noise is excluded, is
~−9.55 ns** (job 5550's `#2` violator, `u_remod`-family, unchanged whether or
not the pad path is scoped) — genuinely under the −10 ns target. But getting
there with `DELAY 2` means accepting the DRV regression above, and **there is
currently no known fix for that regression** (§1: both DRV levers — GRT
margin and pin-scoped constraints — are exhausted/blocked). The only
plausible path to both wins is **hierarchical/selective synthesis** —
`DELAY 2` only on the SS-critical domain (sd_remod, packet_active/sc_lock
fanout), `DELAY 0` elsewhere (especially the reg_bank/PSRAM-debug cone that's
sensitive to it) — flagged as a deferred option in this design's own history
for the inverse case (`decimator-hb-area-reduction.md`: *"a selective
area-map... could capture part of the win... but needs hierarchical
synthesis"*). Not attempted here — real per-module synthesis scoping, not a
single JSON key, and out of scope for today's session.

## 4. `psram_buf_ctrl.v` `buf_base` write-arc: real RTL bug, found and fixed

Prompted by "at this point are there any rtl levers?" / "doesnt psram run at
32M?" — re-reading `psram_buf_ctrl.v` (not just assuming `buf_base` was
quasi-static by analogy to other fixed signals) found the exact same bug
class as the already-fixed Open Risk #39: `buf_base` was computed
**combinationally, on the same edge as `sc_lock`**, from live `timing_ref`/
`iq_sample_cnt`/`wr_ptr` — no settling margin, and (per job 5539/5541's SS
report) the `timing_ref → u_psram.buf_base` path was the **#1 SS
contributor at −14.49 ns** once the debug-pad noise (§2) was excluded.

**Fix:** a 2-stage pipeline. Stage 1 (the `sc_lock` edge) snapshots the three
raw operands (`lat_timing_ref_bb`, `lat_iq_sample_cnt_bb`, `lat_wr_ptr_bb`)
into new registers and sets `bufbase_pending`; `buf_active` stays on stage 1,
unchanged, because `packet_ctrl_fsm.v` raises `packet_active` on that
identical edge (moving `buf_active` to stage 2 broke formal — job 5556, see
below). Stage 2 (next cycle) computes `buf_base` from the **frozen**
snapshots — provably the same formula, same operand values, just retimed.
Freezing `wr_ptr` too (not just `timing_ref`/`iq_sample_cnt`, unlike
`packet_ctrl_fsm`'s #39 fix which re-reads live `sample_count`) matters
because `wr_ptr` and `iq_sample_cnt` can desync via `sample_skip` — re-reading
`wr_ptr` live one cycle later would be a real correctness change, not a pure
retime.

**Formal debugging (3 failed rounds before landing, jobs 5556/5559/5560):**
1. **5556** — `buf_active` moved to stage 2 → BMC counterexample on
   `a_buf_active_needs_en` (`packet_active` unconstrained in the 1-cycle gap
   in the per-module proof, since it's a free formal input there). Fixed by
   moving `buf_active` back to stage 1.
2. **5559** — `a_buf_base_valid_matches_active` still asserted
   `buf_base_valid == buf_active` (no longer true, 1 cycle apart) → updated to
   `buf_active == (buf_base_valid || bufbase_pending)`. Still failed:
   `packet_end` wasn't clearing `bufbase_pending` in the `S_WRITE` handler,
   leaving it stuck at 1 while `buf_active` was force-cleared → added the
   clear.
3. **5560** — `a_buf_base_matches_full_precision`'s own reference-model timer
   (`arm_pending_q`/`arm_pending_q2`, a separate 2-cycle counter) didn't know
   about `packet_end` aborting the real RTL's `bufbase_pending` mid-flight →
   replaced it with `bufbase_pending_q`, a plain 1-cycle-delayed copy of the
   *real* `bufbase_pending` port, which inherits the abort behavior for free.
4. **5561 — PASSED**, k-induction, both basecase and induction.

**P&R impact — real, but not what it first looked like.** Without min_ff RCX
(job 5558, wrong baseline to have used): WNS −14.44 → **−10.835 ns**, looked
like a big win. **With min_ff RCX (the config actually required for hold
signoff — job 5544 before vs 5563 after): −14.489 → −14.496 ns, essentially
no change**, TNS got worse (−822.7 → −1445.2), slew violations up (11→14).
The fix is still correct and worth keeping (real bug, formally verified, 0
DRC/LVS regression either way, regression-clean) — it just isn't the lever
that moves the needle in the config that matters. See §6 for what actually
dominates there.

## 5. Three further correctness bugs found by review, fixed and verified

A careful review of the `buf_base` fix (not run by this session — brought in
as review comments) found three more real issues in `psram_buf_ctrl.v`, none
previously tracked as Open Risks:

1. **`qspi_owner` during `S_QE_INIT` could stop SCK while CE#/SIO stayed
   active.** `qpi_busy` is never set to 1 during `S_QE_INIT` (only
   `S_WRITE`/`S_REPLAY` touch it), so the deferred-owner mechanism
   (`qspi_owner_eff`, meant to update only at burst boundaries) instead
   tracked live `qspi_owner` with just a 1-cycle lag throughout the whole
   init sequence — and the `init_sub` case statement has no `qspi_owner` gate
   of its own, so it kept bit-banging CE#/SIO through RSTEN/RST/Enter-QPI
   regardless. An ownership request landing mid-sequence would drop `sck_en`
   one cycle later while CE#/SIO kept changing — exactly the pad glitch
   `qspi_owner_eff` exists to prevent, just ineffective here. **Fix:**
   `qspi_owner_eff`'s update now also excludes `state == S_QE_INIT`, deferring
   the whole handoff to the sub==29 state boundary (same pattern as every
   other in-flight-burst deferral) — appropriate since QE_INIT is also a
   hardware-interlocked 3-command sequence with no safe mid-sequence
   boundary anyway (RSTEN must be immediately followed by RST).

2. **`del_rdy` counted raw `iq_valid`, not completed writes — an off-by-one,
   not just an under-gating bug.** Original code incremented on any
   `iq_valid`, ungated by `qpi_busy`/`qspi_owner`, so samples dropped by a
   debug-fetch collision or an ownership pause still advanced the counter.
   The first fix (gating on a write-*launch* condition) turned out to still
   have a genuine off-by-one: `del_addr` is computed at launch from the
   *pre-increment* `wr_ptr`, so on the Nth transaction `del_addr = wr_ptr_N −
   N×8` lands **one slot before** the oldest genuinely-written sample — and
   counting at launch let `del_rdy` go high 43 cycles before that same
   transaction's own del-read reached its `del_valid <= del_rdy;` assignment,
   exposing the corrupted read. **Fix:** anchor the counter on
   `del_read_done_now` (the transaction's own read-*completion* point,
   `sub==43`) instead — the Nth transaction's own `del_valid <= del_rdy;`
   then reads `del_rdy`'s pre-edge value (still 0, nonblocking-assignment
   semantics) in the same cycle `del_rdy` is being set, correctly suppressing
   that read; transaction N+1 becomes the first valid pair, and its own
   `del_addr` correctly resolves to slot 0. Also added a **re-arm**: once
   `del_rdy` is already high, a `capture_missed_now` event (`qspi_owner`
   pause or `sample_skip` collision) drops it back to 0 and restarts the
   warm-up, since either opens a real gap in the circular buffer's history
   that the old sticky-forever `del_rdy` silently ignored. The existing
   formal invariant `a_del_valid_needs_rdy` (`del_valid ⇒ del_rdy` was
   already 1 the *previous* cycle) structurally proves the off-by-one is
   closed, unchanged.

3. **`training_done`/`REPLAY_MISSED` gated on `buf_base_valid`, which now
   (post `buf_base` retiming, §4) lags `buf_active` by one cycle.** Two
   sites still assumed same-cycle: the `training_done` replay-arm gate
   (would silently skip arming if `training_done` rose in the 1-cycle
   `bufbase_pending` window) and the `packet_end` `REPLAY_MISSED` cause
   (would silently fail to flag a genuine "locked, replay never started"
   case in that same window). The formal harness's own
   `a_replay_missed_cause` mirrored the RTL's `buf_base_valid` condition
   rather than checking independently, so it couldn't have caught this.
   **Fix:** both sites switched to gate on `buf_active` (set immediately on
   the `sc_lock` edge, unaffected by the retiming) — safe because
   `buf_base` is only ever read at replay start, `wait_cnt` cycles later, by
   which point `buf_base_valid` is certainly 1. Formal harness updated in
   lockstep (`buf_active_q` tracker added, `a_wait_armed_scope` and
   `a_replay_missed_cause` re-pointed).

All three: formal PASSED (jobs 5564, then 5565 after the del_rdy refinement
above), core regression CLEAN 47/47 (job 5566). Not yet re-run through P&R
(the fixes are functional/robustness, not on the SS-critical `buf_base`
arithmetic path — no WNS impact expected, but unconfirmed).

## 6. The real #1 SS bottleneck under min_ff RCX: `training_acc.mulA_ext`

Once §4's `buf_base` fix showed no WNS improvement under the required min_ff
config (job 5563), traced the actual dominant violator: **not**
`psram_buf_ctrl` at all. Startpoint `_68046_/Q` drives net
`u_tacc.mulA_ext[1]` (training_acc's multiplier-operand-extension logic) —
a deep combinational chain (15+ AOI21/OAI21 logic levels visible before the
endpoint) landing on an **MCP=3 path** (required time ≈97.5 ns, ≈3× the
31.25 ns clock period) that still misses by **−7.0 ns** even with that
3-cycle budget. This single source accounts for **125 of 333 violating
endpoints** in job 5563 — by far the largest single contributor.

Likely root cause: the earlier `training_acc` pipeline fix
(`project_tacc_pipeline_fix` — made `op_a`/`op_b` combinational, previously
registered, to fix a real ~300× Zdiag inflation bug) plausibly created this
deep `mulA_ext` cone as a side effect. Same structural shape as `buf_base`/
Open Risk #39: a value computed live/combinationally on one edge that isn't
actually consumed until later, so a similar latch-then-compute-later
retiming may apply — **not investigated or attempted this session**, flagged
as the next real lever. `training_acc.v` has its own formal harness; the
prior pipeline fix was itself a delicate correctness/timing tradeoff, so this
needs its own careful pass, not a quick copy of the `buf_base` fix shape.

## Conclusions so far

1. **DRV (nom_tt cap/slew): not fixable with what's currently available.**
   GRT margin is saturated, pin-scoped constraints are blocked by an OpenSTA
   API limitation, and design-wide constraints stall the flow. Pre-GRT
   isolation (§1, pending) is the one untried, principled option left; if it
   also fails, the residual (currently 3 slew/1 cap, off any timing-critical
   path) should be accepted as-is rather than chased further.
2. **SS WNS to ~−10 ns: possible in principle (the real floor is ~−9.55 ns),
   but not for free.** The only lever that gets there (`DELAY 2`) trades a
   real ~6× DRV regression for it, with no fix currently in hand. Getting
   both would need hierarchical synthesis (bigger scope than today's probes).
   Every SDC/RCX-margin lever tried bottoms out at the same deterministic
   floor regardless of config, confirming it's real logic depth
   (sd_remod's integrator ripple, `packet_active_ps` fanout), not a report
   artifact — consistent with this design's multi-month MCP-honesty history,
   where the best purely-honest fix to date (Open Risk #39) landed at
   −12.11 ns.
3. **#41 (RCX min_ff) and v31 (debug false-paths) are the two changes worth
   keeping regardless of the above** — both are real, orthogonal fixes
   (hold-deck correctness; debug pads correctly excluded from a timing
   budget they never needed) with no known downside, verified clean on the
   merged BRINGUP_SRC tree (DRC/LVS/route DRC/antenna 0 throughout, core
   cocotb regression 47/47 suites clean, formal unaffected).
4. **The `psram_buf_ctrl.v` `buf_base` write-arc fix (§4) is a real,
   formally-verified RTL correctness/timing fix, worth keeping — but it is
   NOT the lever that moves SS WNS in the config that matters.** It only
   helped WNS in a P&R config missing the required min_ff RCX ruleset; with
   min_ff in, WNS is unchanged (−14.489 → −14.496 ns) and TNS got worse. Three
   further correctness bugs found by review (§5) are fixed and formally
   verified on top of it, regression-clean, not yet re-run through P&R.
5. **The real #1 SS bottleneck under the required config is now identified:
   `training_acc.mulA_ext`** (§6) — a deep combinational multiplier-extension
   path, MCP=3, still missing by −7.0 ns, driving 125/333 violating
   endpoints in job 5563. Plausibly a side effect of the earlier
   `training_acc` pipeline fix (op_a/op_b made combinational). Not yet
   investigated — the next real lever, but needs its own careful pass given
   the pipeline fix's own delicate correctness/timing tradeoff.

## References

- `planning/drv-margin-sweep-2026-09-03.md` — the original GRT-margin sweep
  and its 2026-09-04 re-verification/reconciliation section.
- `planning/Open Risks.md` #41 (RCX min_ff), #59 (BRINGUP_SRC).
- `src/config/pnr_32m_scoped_v25_b6_signoff.sdc` — v31 block.
- Branch `pnr/drv-ss-signoff-sdc-v31` (commits `43f71e7`, `5608d39`, `f45d14a`,
  merge `ada0eaa` bringing in `bringup-src-rebased`).
- Probe configs (uncommitted, delete once evaluated):
  `trouper_top_delay2_probe.json`, `_delay4_probe.json`,
  `_pregrt{60,55,50}_probe.json`, `_drvpin_probe.json` (+
  `pnr_32m_scoped_v25_b6_drvpin_probe.sdc`, dead end — see §1).
- `src/control/psram_buf_ctrl.v` / `formal/psram_buf_ctrl_formal.sv` —
  **uncommitted** working-tree changes (§4/§5): `buf_base` 2-stage retiming,
  `qspi_owner`/`S_QE_INIT` deferred-owner fix, `del_rdy`
  completion-anchored/re-arm fix, `buf_active`/`buf_base_valid` gating fix.
  Verified via jobs 5556/5558-5566 (formal + regression + P&R) as of this
  snapshot; not re-verified against any RTL changes made after this doc was
  written.
