# Packet Control FSM — Verification Plan

**DUT:** `src/control/packet_ctrl_fsm.v` (mirrored to
`rtl-test/rtl/packet_ctrl_fsm.v`)

**Scope:** packet-phase sequencing, the three sample-ticked deadlines, weight-commit
handling, missed-weight degradation, per-packet mode/antenna latching, status outputs,
and the interfaces from the FSM into the combiner, PSRAM controller, and IRQ path.

**Inputs reviewed:** `planning/blocks/Packet Control FSM.md`,
`planning/Trouper Chip Specification.md` (§4.7 TRPR-PCF-001..011),
`planning/Traceability.md`, `planning/Open Risks.md` (#25, #39, #42),
`planning/b4-b6-area-cuts-2026-07.md`, `formal/packet_ctrl_fsm_formal.sv`,
`rtl-test/tb/tb_pcfsm_b6_equiv.v`, the current RTL, and the existing cocotb/legacy
testbenches named in §2.

This is the block-level closure tracker for `packet_ctrl_fsm`. It does not supersede
the system test plan or the PSRAM controller's separate verification plan.

---

## 1. Current methodology, and the path to constrained random

**Today:** the main requirement paths have integration coverage, and a non-vacuous
formal checker proves the FSM's structural invariants. Directed coverage is not yet
fully closed: Open Risk #42's acquisition-timeout and mid-payload-commit tests are now
closed (rows #7/#8), but row #14's packet-deadline-precedence spec/RTL question remains
open, and RTL review's boundary-precedence and deadline-extreme cases (rows #9–#12/
#18–#20) are closed but not yet coverage-instrumented.

- **Full-top cocotb simulation** — `cocotb/w_missed`, `cocotb/bypass_e2e`,
  `cocotb/sc_force_lock`, `cocotb/trouper_top`, and PSRAM/capture suites instantiate
  `trouper_top`, so they exercise register readback, IRQ stretching, the combiner gate,
  and the SC/PSRAM handshakes as well as this FSM. These are directed tests with fixed
  timing and configuration.
- **Standalone cocotb simulation** — `cocotb/packet_ctrl_fsm` instantiates the DUT
  directly and compares every sampled state/output/internal register against
  `cocotb/tests/packet_ctrl_fsm_model.py`. Rows #1/#2 are closed; the same complete
  cycle-accurate model is the base for the remaining event-precedence and counter tests.
- **Legacy full-chain/real-capture tests** —
  `rtl-test/tb/test_weight_gen_spi_flow.py` and
  `rtl-test/tb/test_capture_two_packet.py` cover the successful firmware weight path
  and two-packet re-arm using measured IQ data.
- **Formal (SymbiYosys k-induction)** —
  `formal/packet_ctrl_fsm_formal.sv`, depth 40, is instantiated directly under
  `ifdef FORMAL` so the proof is not vacuous. It proves legal state transitions,
  one-cycle `ST_ACQ_SETUP`, exactness of the 20-bit elapsed calculation under the
  SC-latency assumption, counter update discipline, `packet_active`/phase lockstep,
  the `packet_active_ps` mirror, and missed-weight pulse/sticky causality.
- **Randomized differential simulation** —
  `rtl-test/tb/tb_pcfsm_b6_equiv.v` compares all outputs every cycle against the frozen
  pre-B6 absolute-deadline FSM over 40 randomized packets. It covers clean commit,
  acquisition timeout, W-pending timeout, pending-from-IDLE commit, randomized tick
  phase, and already-expired counter loads. Its ranges are deliberately shortened and
  it proves equivalence to the old implementation, not correctness against the current
  requirements.

There is no code-coverage merge, no functional-coverage model, and no
coverage-directed constrained-random cocotb test. The active order is:

1. ~~Close the directed gaps in rows #7–#12 and #18–#20 before broad randomization.
   These cases have crisp expected results and include requirement-boundary behavior.~~
   ✅ Done — rows #9–#12/#18–#20 in SGE job 3719, rows #7/#8 in SGE job 3893.
2. Instrument Verilator line/toggle/branch coverage and measure the existing regression
   as a baseline.
3. Add functional coverpoints for state transitions, event/state crossings, deadline
   boundaries, and configuration extremes described in §1a.
4. Add a standalone constrained-random cocotb layer with a cycle-accurate Python
   reference model. Keep the full-top directed tests for register, IRQ, combiner, and
   PSRAM interface behavior.
5. Close on functional coverage (or documented waivers), not a fixed seed count.

### 1a. Coverage model

At minimum, collect:

- every legal state transition, including
  `PREAMBLE_ACQ → PAYLOAD_ACTIVE` on acquisition timeout;
- `{state when W_commit arrives} × {pending consumed in IDLE, W_PENDING, PAYLOAD}`;
- `{training_done, acq_cnt==0}` and
  `{W_commit_pending, wpend_cnt==0, W_valid}` precedence crosses;
- `sf` 7–12 × `sample_shift` 1–2, including SF12/shift2 (`M=16384`);
- `tacc_window_syms` raw 0, minimum legal 8, and maximum 15;
- `pkt_timeout_syms` 0, below acquisition span, equal to a phase boundary, normal,
  and maximum 255;
- `iq_tick` relative to the lock edge and `ST_ACQ_SETUP` load edge;
- `sample_count`/`timing_ref` near the 32-bit wrap and low-20-bit wrap;
- `W_missed_packet` pulse count and `W_missed_q` set/hold/clear;
- all `PACKET_STATUS` phase encodings with both `W_VALID=0` and `W_VALID=1`;
- mode 0/1 and every meaningful antenna-mask class, crossed with a mid-packet shadow
  write and next-packet latch.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed test of a numbered requirement; **EDGE-SIM** =
directed robustness or precedence test found by RTL review; **FORMAL** =
k-induction property; **DIFF-SIM** = cycle-by-cycle comparison with the frozen
pre-B6 reference; **INTERFACE/SYSTEM** = behavior owned partly outside this block.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | Reset values and idle quiescence | SPEC-SIM | `cocotb/packet_ctrl_fsm` → `test_reset_values_and_idle_quiescence` | reset contract; TRPR-PCF-001/008 | ✅ done — synchronous hold and asynchronous re-assertion with all event inputs high; every modeled register checked cycle-by-cycle (SGE job 3710) |
| 2 | Lock edge, parameter latch, and one-cycle setup residency | SPEC-SIM + FORMAL | `cocotb/packet_ctrl_fsm` → `test_lock_setup_and_parameter_latching`; formal `a_setup_entry_cause`, legal-transition/phase assertions | TRPR-PCF-001/002; Open Risk #39 | ✅ done — directly observes IDLE→ACQ_SETUP→PREAMBLE_ACQ on consecutive clocks, registered `timing_ref`, mode/mask packet latches, counter loads from the registered reference, and ignored active-packet lock re-edge; cycle-by-cycle model comparison (SGE job 3710) |
| 3 | Normal lock → training → on-time commit → payload → idle | SPEC-SIM | `rtl-test/tb/test_weight_gen_spi_flow.py`; PSRAM capture tests | TRPR-PCF-001/003/004/007/008 | ✅ done (job 3286 for the weight-flow test) |
| 4 | `training_done` transition and IRQ | SPEC-SIM / INTERFACE | `test_weight_gen_spi_flow.py` | TRPR-PCF-003 | ✅ done — W_PENDING ordering inferred from event/readback flow; row #2/#16 close the cycle/state detail |
| 5 | On-time `W_commit` in W_PENDING | SPEC-SIM | `test_weight_gen_spi_flow.py`, `test_capture_playback.py` | TRPR-PCF-004 | ✅ done — `W_VALID` and combined output observed |
| 6 | No commit: W-pending timeout, bypass, miss IRQ/sticky, packet done | SPEC-SIM | `cocotb/w_missed` → `test_w_missed_packet.py` | TRPR-PCF-005/007/008/009/010 | ✅ done (jobs 3305/3310) |
| 7 | Acquisition timeout with no `training_done` | SPEC-SIM | extend `cocotb/w_missed` → `test_w_missed_on_acq_timeout` | TRPR-PCF-001/005/010; Open Risk #42 | ✅ done — `u_tacc.training_done` forced low every clock so the only exit from `ST_PREAMBLE_ACQ` is the `acq_cnt==0` branch; a clock-accurate watch (after a 7-symbol coarse wait) directly observes the transition never passing through `packet_phase==2`/W_PENDING and `W_missed_packet` pulsing for exactly 1 clock, then confirms sticky `PACKET_STATUS[7]`/`WGT_CTRL[3]` readback, `PACKET_STATUS.TRAINING_DONE`/`IRQ_STATUS.TRAINING_DONE` staying clear, bypass payload output, `PACKET_DONE`, and sticky-bit clear at the next lock (SGE job 3893; full-block regression re-confirmation job 3895) |
| 8 | Late `W_commit` during PAYLOAD_ACTIVE | EDGE-SIM | extend `cocotb/w_missed` → `test_w_commit_late_during_payload` | Open Risk #42; documented W-commit behavior | ✅ done — enters `ST_PAYLOAD_ACTIVE` via the same W-pending-timeout miss as row #6, then commits weights mid-payload; confirms `WGT_CTRL.W_VALID`/`PACKET_STATUS.W_VALID` assert, the sticky `W_MISSED_PACKET` mirror stays set (historical, not cleared by the late commit), and a clock-accurate watch of `u_comb.use_mrc_r`/`u_comb.state` shows exactly one bypass→MRC transition coincident with `state==1` (i.e. immediately following a `state==0` `x_valid` burst start — burst-atomic, no mid-burst glitch); only the post-commit pairings then diverge from the raw antenna sample (20/20 differed) while the pre-commit pairings stayed bit-exact bypass (SGE job 3893; full-block regression re-confirmation job 3895) |
| 9 | Commit before packet / in IDLE | EDGE-SIM | `cocotb/packet_ctrl_fsm` → `test_commit_before_packet_in_idle`; corroborated by `tb_pcfsm_b6_equiv.v` scenario 3 | W-commit state table | ✅ done — exactly one `W_valid_set` pulse, pending clear, no next-packet miss, and `W_valid` clear at packet end checked cycle-by-cycle (SGE job 3719) |
| 10 | Commit during ACQ_SETUP or PREAMBLE_ACQ | EDGE-SIM | `cocotb/packet_ctrl_fsm` → `test_commit_during_acquisition_is_deferred` | sticky `W_commit_pending` protocol | ✅ done — separate ACQ_SETUP and PREAMBLE injections remain pending without skipping acquisition and are consumed only after W_PENDING entry (SGE job 3719) |
| 11 | Same-cycle precedence at acquisition deadline | EDGE-SIM | `cocotb/packet_ctrl_fsm` → `test_training_done_wins_at_acquisition_deadline` | RTL branch priority | ✅ done — `training_done` with `acq_cnt==0` enters W_PENDING and suppresses pulse/sticky miss (SGE job 3719) |
| 12 | Same-cycle precedence at weight deadline | EDGE-SIM + FORMAL | `cocotb/packet_ctrl_fsm` → `test_pending_commit_wins_at_weight_deadline`; formal missed-cause property | RTL branch priority | ✅ done — a previously captured pending commit with `wpend_cnt==0` sets valid, enters payload, clears pending, and suppresses pulse/sticky miss (SGE job 3719) |
| 13 | Packet timeout, IDLE return, PACKET_DONE, and re-arm | SPEC-SIM | `cocotb/w_missed`; `test_capture_two_packet.py` | TRPR-PCF-007/008/010 | ✅ done for a normal deadline later than acquisition/weight deadlines |
| 14 | Packet deadline earlier than acquisition or W-pending deadline | ANALYSIS | `cocotb/pkt_timeout_states/` (job 5474, characterisation) | TRPR-PCF-007 | ✅ resolved 2026-09-04 by spec clarification, no RTL change — TRPR-PCF-007 and Register Map `0x0B` redefined as a **payload-phase** deadline. `PREAMBLE_ACQ` and `W_PENDING` are bounded independently by `TACC_WINDOW_SYMS`-derived deadlines (`acq_cnt`/`wpend_cnt`), so `packet_active` is finite for every legal register value; `PKT_TIMEOUT_SYMS` is documented as not a global watchdog (Open Risks #64). Bench keeps `test_payload_timeout_forces_idle` as the TRPR-PCF-007 regression; the ACQ/W_PENDING cases are documented expected behaviour, not failures |
| 15 | Back-to-back packets and sticky clear at next lock | SPEC-SIM | `test_capture_two_packet.py`; `cocotb/w_missed` | TRPR-PCF-002/008/010 | ✅ done (real-capture job 3273; sticky re-lock path in jobs 3305/3310) |
| 16 | `packet_phase`, active outputs, and legal-state lockstep | FORMAL + SPEC-SIM | formal phase/active assertions; `cocotb/packet_ctrl_fsm`, `cocotb/w_missed`, `cocotb/sc_force_lock` | TRPR-PCF-001/002/008/009 | ✅ done — formal proves lockstep globally; standalone simulation directly observes internal ACQ_SETUP with public phase 1, and integration tests read phases 0/1/2/3 |
| 17 | `packet_active_ps` mirrors `packet_active` | FORMAL + DIFF-SIM | formal `a_ps_mirror`; `tb_pcfsm_b6_equiv.v` | physical fanout split | ✅ done |
| 18 | Counter formula and tick-edge checks at representative configurations | SPEC-SIM | `cocotb/packet_ctrl_fsm` → `test_counter_formula_tick_and_fire_edges` | TRPR-PCF-001/007; B6 behavior | ✅ done — independently calculated exact loads, setup-edge tick correction, no-tick holds, tick decrements, and zero-fire edges for all three counters at representative configurations (SGE job 3719) |
| 19 | Counter/configuration extremes | EDGE-SIM | `cocotb/packet_ctrl_fsm` → `test_counter_configuration_extremes` | width/clamp review | ✅ done — raw `tacc_window_syms=0`, 8, 15; `pkt_timeout_syms=0/255`; SF7/shift1 and SF12/shift2; setup tick; maximum spans; and already-expired clamp-to-zero loads (SGE job 3719) |
| 20 | `sample_count` wrap and low-20-bit elapsed wrap | EDGE-SIM + FORMAL | `cocotb/packet_ctrl_fsm` → `test_sample_count_and_elapsed_wrap`; formal elapsed proof | B6 wrap-immunity claim | ✅ done — exact loads and first post-load tick checked across a low-20-bit wrap and a full-32-bit `sample_count` wrap (SGE job 3719) |
| 21 | B6 equivalence to absolute-deadline reference | DIFF-SIM | `rtl-test/tb/tb_pcfsm_b6_equiv.v` | B6 area cut | ✅ done — 40 randomized packets, all outputs compared every clock (jobs 3463/3471, re-run job 3712); harness hardened 2026-07-31 to keep randomized `timing_ref` inside the frozen reference's non-wrap-safe validity domain and use `$fatal` for a nonzero failure exit; retain as a change detector, not the golden requirements oracle |
| 22 | Mode/antenna latch is packet-atomic | SPEC-SIM | `cocotb/bypass_e2e` → `test_mimo_ctrl_deferred_latch` | TRPR-PCF-006 | ✅ done (job 3315) |
| 23 | Mode 1 lowest-enabled-antenna passthrough | INTERFACE/SYSTEM | `cocotb/bypass_e2e` mode-1 cases | TRPR-PCF-011 | ✅ done (job 3304) — routing is top-level/combiner behavior; the FSM only supplies the latched mode/mask |
| 24 | Firmware absent: no deadlock | SPEC-SIM | `cocotb/w_missed`, two-packet tests | TRPR-PCF-010 | ✅ done — W_PENDING-timeout path plus the row #7 no-training acquisition-timeout path (SGE job 3893), both reach `PACKET_DONE` and re-arm |
| 25 | Miss pulse causality and sticky lifetime | FORMAL + SPEC-SIM | formal `a_wmissed_*`; `cocotb/w_missed` | TRPR-PCF-005/009 | ✅ done — W-pending miss plus row #7's direct clock-accurate 1-cycle-pulse observation of the acquisition-miss source (SGE job 3893) |
| 26 | `PACKET_STATUS`/`WGT_CTRL` live readback | INTERFACE | `cocotb/w_missed`, weight-flow test | TRPR-PCF-009 | 🟨 partial — active, phases 0/2/3, pending, training, missed and W_VALID=0 are direct; add `PACKET_STATUS.W_VALID=1` and phase-1 reads to the successful-commit test |
| 27 | Mid-packet forced/repeated lock cannot re-latch or glitch phase | INTERFACE/SYSTEM | `cocotb/sc_force_lock` → `test_sc_force_lock_blocked_during_packet` | Open Risk #25 structural contract | ✅ done at the register interface; `sc_detector` owns the level-held-lock guarantee |
| 28 | Full formal property set, non-vacuous | FORMAL | `formal/packet_ctrl_fsm_formal.sv` + `.sby` | TRPR-PCF-001/002/005/008/009; B6 invariants | ✅ done (depth 40, reported job 3487); re-run after any RTL or assumption change and confirm checker cells/properties remain in the prepared design |

### 2a. Directed closure order

1. ~~Implement one standalone block-level cocotb harness and Python reference model,
   then close rows #9–#12/#18–#20 on it.~~
   ✅ Done (`cocotb/packet_ctrl_fsm`: rows #1/#2 in SGE job 3710 and rows
   #9–#12/#18–#20 in SGE job 3719). Direct ports avoid the long decimator/SC
   latency and allow exact same-cycle event placement.
2. ~~Extend `cocotb/w_missed` for acquisition timeout (#7) and late mid-payload commit
   (#8), because those cases need observable top-level bypass/MRC, sticky register, and
   IRQ behavior.~~
   ✅ Done (`cocotb/w_missed` → `test_w_missed_on_acq_timeout` / `test_w_commit_late_during_payload`,
   SGE job 3893; full-block regression re-confirmation job 3895).
3. Row #14 resolved 2026-09-04 by spec clarification (payload-phase semantics), not RTL —
   TRPR-PCF-007 and Register Map `0x0B` now match the RTL for all legal register values;
   `PKT_TIMEOUT_SYMS` is documented as not a global watchdog (Open Risks #64).
4. Add the successful-path `PACKET_STATUS.W_VALID=1` read in row #26.
5. Run the complete directed, differential, and formal regression, then instrument the
   baseline coverage and begin constrained-random closure.

---

## 3. Regression commands

Run inside the chipathon26 EDA container with the repository mounted at
`/foss/designs/lora-mimo` (or override `DESIGN_ROOT` consistently):

```bash
# Standalone cycle-accurate DUT/model checks
(cd cocotb/packet_ctrl_fsm && make)

# Self-contained full-top cocotb suites that directly own PCFSM requirements
for d in w_missed bypass_e2e sc_force_lock trouper_top; do
  (cd cocotb/$d && make) || echo "FAILED: $d"
done

# Formal proof
(cd formal && sby -f packet_ctrl_fsm.sby)

# B6 differential regression (compile/run with the repository's preferred
# Verilator flow; the two design sources are intentionally src mirror + frozen ref)
(cd rtl-test && \
  verilator --binary --timing -Wno-fatal -sv \
    --top-module tb_pcfsm_b6_equiv \
    tb/tb_pcfsm_b6_equiv.v tb/packet_ctrl_fsm_ref.v rtl/packet_ctrl_fsm.v && \
  ./obj_dir/Vtb_pcfsm_b6_equiv)
```

Also run the real-capture `test_weight_gen_spi_flow.py` and
`test_capture_two_packet.py` jobs when the capture dataset is available. Their capture
files and launch environment are external to this block and are not replaced by the
self-contained suites above.

Any change to the PCFSM port list must be mirrored in
`rtl-test/rtl/packet_ctrl_fsm.v`, `formal/packet_ctrl_fsm_formal.sv`, and both instances
in `rtl-test/tb/tb_pcfsm_b6_equiv.v`. The frozen
`rtl-test/tb/packet_ctrl_fsm_ref.v` should otherwise remain unchanged.

**Last full run:** SGE job 3895, 2026-08-04 — all targets passed:
standalone 9/9, `w_missed` 3/3 (now including rows #7/#8's
`test_w_missed_on_acq_timeout` / `test_w_commit_late_during_payload`,
SGE job 3893), `bypass_e2e` 5/5, `sc_force_lock` 2/2, `trouper_top` 18/18,
formal k-induction PASS with the checker instance confirmed present in the
prepared design, and B6 differential simulation PASS for 40 randomized
packets. The real-capture legacy tests (`test_weight_gen_spi_flow.py`,
`test_capture_two_packet.py`) were not re-run this session — unaffected by
the rows #7/#8 change and already closed against jobs 3286/3273; their
capture dataset is external to the self-contained regression above.

**Last targeted standalone run:** SGE job 3719, 2026-07-31 — all 9 tests passed,
including directed closure of rows #9–#12/#18–#20.

---

## 4. Explicit non-goals and interface boundaries

- SC correlation quality, `timing_ref` generation, and the guarantee that `sc_lock`
  remains level-held until `sc_clr` belong to `sc_detector`; this plan verifies only
  the FSM's response and the formal latency assumption it consumes.
- Training arithmetic and `training_done` generation belong to `training_acc`; this plan
  treats `training_done` as an event and verifies sequencing/IRQ consequences.
- Weight computation correctness and SPI/Grouper firmware latency are outside this
  block. This plan verifies only `W_commit` capture/application and the resulting
  valid/bypass policy.
- PSRAM replay timing and QPI data integrity belong to
  `psram-buf-ctrl-verification-plan.md`. Here, only the shared
  `packet_active`/packet-end interface is in scope.
- Mode-1 antenna selection and MRC arithmetic are system/combiner checks. They remain in
  the regression because they make the FSM's latched controls observable end-to-end,
  but failures must be localized before assigning them to this block.
- CE-gating/SDC timing closure is a physical-design/signoff concern. Functional tests
  run on the logical clock; they do not prove the quasi-static multicycle constraint.
