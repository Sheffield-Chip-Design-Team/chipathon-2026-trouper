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
closed: Open Risk #42 correctly identifies the missing acquisition-timeout and
mid-payload-commit tests, and RTL review adds boundary-precedence and deadline-extreme
cases that the existing tests do not isolate.

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

1. Close the directed gaps in rows #7–#12 and #18–#20 before broad randomization.
   These cases have crisp expected results and include requirement-boundary behavior.
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
| 7 | Acquisition timeout with no `training_done` | SPEC-SIM | extend `cocotb/w_missed` or new standalone suite | TRPR-PCF-001/005/010; Open Risk #42 | ⬜ new — prove direct ACQ→PAYLOAD transition, one-cycle miss pulse, sticky readback, bypass behavior, no TRAINING_DONE IRQ, and eventual packet done |
| 8 | Late `W_commit` during PAYLOAD_ACTIVE | EDGE-SIM | extend `cocotb/w_missed` | Open Risk #42; documented W-commit behavior | ⬜ new — first enter payload through a miss, then write weights/commit; prove `W_VALID` asserts, sticky miss remains historical for that packet, bypass→MRC switch is burst-atomic, and only the remainder combines |
| 9 | Commit before packet / in IDLE | EDGE-SIM | standalone test; corroborate `tb_pcfsm_b6_equiv.v` scenario 3 | W-commit state table | 🟨 partial — differential test covers it; add requirement-level checks for one `W_valid_set` pulse, pending clear, use on the next packet, and clear at packet end |
| 10 | Commit during ACQ_SETUP or PREAMBLE_ACQ | EDGE-SIM | standalone test | sticky `W_commit_pending` protocol | ⬜ new — commit must remain pending, must not skip acquisition, and must be consumed after entry to W_PENDING |
| 11 | Same-cycle precedence at acquisition deadline | EDGE-SIM | standalone test | RTL branch priority | ⬜ new — `training_done` on the cycle `acq_cnt==0` must win over the acquisition-timeout/miss branch |
| 12 | Same-cycle precedence at weight deadline | EDGE-SIM + FORMAL | standalone test; formal missed-cause property | RTL branch priority | ⬜ new — a pending commit on the cycle `wpend_cnt==0` must win, set valid, and suppress the miss pulse |
| 13 | Packet timeout, IDLE return, PACKET_DONE, and re-arm | SPEC-SIM | `cocotb/w_missed`; `test_capture_two_packet.py` | TRPR-PCF-007/008/010 | ✅ done for a normal deadline later than acquisition/weight deadlines |
| 14 | Packet deadline earlier than acquisition or W-pending deadline | SPEC-SIM / ANALYSIS | standalone test | TRPR-PCF-007 | ⚠️ spec/RTL issue — the RTL tests `pkt_cnt==0` only in PAYLOAD_ACTIVE, so a short `PKT_TIMEOUT_SYMS` cannot force IDLE while still in ACQ/W_PENDING; define whether the requirement or RTL must change, then lock the decision with a regression |
| 15 | Back-to-back packets and sticky clear at next lock | SPEC-SIM | `test_capture_two_packet.py`; `cocotb/w_missed` | TRPR-PCF-002/008/010 | ✅ done (real-capture job 3273; sticky re-lock path in jobs 3305/3310) |
| 16 | `packet_phase`, active outputs, and legal-state lockstep | FORMAL + SPEC-SIM | formal phase/active assertions; `cocotb/packet_ctrl_fsm`, `cocotb/w_missed`, `cocotb/sc_force_lock` | TRPR-PCF-001/002/008/009 | ✅ done — formal proves lockstep globally; standalone simulation directly observes internal ACQ_SETUP with public phase 1, and integration tests read phases 0/1/2/3 |
| 17 | `packet_active_ps` mirrors `packet_active` | FORMAL + DIFF-SIM | formal `a_ps_mirror`; `tb_pcfsm_b6_equiv.v` | physical fanout split | ✅ done |
| 18 | Counter formula and tick-edge checks at representative configurations | SPEC-SIM | new standalone test with Python model | TRPR-PCF-001/007; B6 behavior | ⬜ new — compare exact `acq_cnt`, `wpend_cnt`, and `pkt_cnt` loads/decrements/fire edges, including `iq_tick` on setup and long gaps without ticks |
| 19 | Counter/configuration extremes | EDGE-SIM | standalone constrained-directed test | width/clamp review | ⬜ new — raw `tacc_window_syms=0`, 8, 15; `pkt_timeout_syms=0/255`; SF7/shift1 and SF12/shift2; already-expired loads |
| 20 | `sample_count` wrap and low-20-bit elapsed wrap | EDGE-SIM + FORMAL | standalone test; formal elapsed proof | B6 wrap-immunity claim | ⬜ new simulation — formal proves the bounded modular subtraction, but no directed regression crosses either wrap boundary |
| 21 | B6 equivalence to absolute-deadline reference | DIFF-SIM | `rtl-test/tb/tb_pcfsm_b6_equiv.v` | B6 area cut | ✅ done — 40 randomized packets, all outputs compared every clock (jobs 3463/3471, re-run job 3712); harness hardened 2026-07-31 to keep randomized `timing_ref` inside the frozen reference's non-wrap-safe validity domain and use `$fatal` for a nonzero failure exit; retain as a change detector, not the golden requirements oracle |
| 22 | Mode/antenna latch is packet-atomic | SPEC-SIM | `cocotb/bypass_e2e` → `test_mimo_ctrl_deferred_latch` | TRPR-PCF-006 | ✅ done (job 3315) |
| 23 | Mode 1 lowest-enabled-antenna passthrough | INTERFACE/SYSTEM | `cocotb/bypass_e2e` mode-1 cases | TRPR-PCF-011 | ✅ done (job 3304) — routing is top-level/combiner behavior; the FSM only supplies the latched mode/mask |
| 24 | Firmware absent: no deadlock | SPEC-SIM | `cocotb/w_missed`, two-packet tests | TRPR-PCF-010 | ✅ done for the W_PENDING-timeout path; row #7 closes the no-training path |
| 25 | Miss pulse causality and sticky lifetime | FORMAL + SPEC-SIM | formal `a_wmissed_*`; `cocotb/w_missed` | TRPR-PCF-005/009 | ✅ done for W-pending miss; row #7 must corroborate the acquisition-miss source |
| 26 | `PACKET_STATUS`/`WGT_CTRL` live readback | INTERFACE | `cocotb/w_missed`, weight-flow test | TRPR-PCF-009 | 🟨 partial — active, phases 0/2/3, pending, training, missed and W_VALID=0 are direct; add `PACKET_STATUS.W_VALID=1` and phase-1 reads to the successful-commit test |
| 27 | Mid-packet forced/repeated lock cannot re-latch or glitch phase | INTERFACE/SYSTEM | `cocotb/sc_force_lock` → `test_sc_force_lock_blocked_during_packet` | Open Risk #25 structural contract | ✅ done at the register interface; `sc_detector` owns the level-held-lock guarantee |
| 28 | Full formal property set, non-vacuous | FORMAL | `formal/packet_ctrl_fsm_formal.sv` + `.sby` | TRPR-PCF-001/002/005/008/009; B6 invariants | ✅ done (depth 40, reported job 3487); re-run after any RTL or assumption change and confirm checker cells/properties remain in the prepared design |

### 2a. Directed closure order

1. ~~Implement one standalone block-level cocotb harness and Python reference model.~~
   ✅ Done for rows #1/#2 (`cocotb/packet_ctrl_fsm`, SGE job 3710). Reuse it for
   rows #9–#12/#18–#20; direct ports avoid the long decimator/SC latency and allow
   exact same-cycle event placement.
2. Extend `cocotb/w_missed` for acquisition timeout (#7) and late mid-payload commit
   (#8), because those cases need observable top-level bypass/MRC, sticky register, and
   IRQ behavior.
3. Resolve row #14 before declaring TRPR-PCF-007 closed for all legal register values.
   A test written to the current SHALL will fail the present RTL when the packet deadline
   expires before the FSM reaches PAYLOAD_ACTIVE.
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

**Last full run:** SGE job 3712, 2026-07-31 — all targets passed:
standalone 2/2, `w_missed` 1/1, `bypass_e2e` 5/5, `sc_force_lock` 2/2,
`trouper_top` 18/18, formal k-induction PASS, and B6 differential simulation
PASS for 40 randomized packets.

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
