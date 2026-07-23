# PSRAM Buffer Controller — Verification Plan

**DUT:** `src/control/psram_buf_ctrl.v` (mirrored to `rtl-test/rtl/`)

**Scope:** all four functions in `planning/blocks/PSRAM Buffer Controller.md` — shared QPI
core, SC delay RAM, same-packet capture/replay, host debug readback.

**Inputs reviewed:** `planning/blocks/PSRAM Buffer Controller.md`, `planning/Traceability.md`
(§4.10 TRPR-PSR-001..024, §4.4 TRPR-FBC-001..005), `planning/Open Risks.md` (#5, #7, #9, #14,
#18, #25, #27, #30, #31, #32, #37), `planning/psram-replay-continuous-delay-redesign.md`,
`planning/psram-replay-verification-plan.md` (RPV items, absorbed here), `formal/psram_buf_ctrl_formal.sv`,
`cocotb/*/Makefile` (source of truth for what each testbench actually exercises), current RTL.

This document supersedes `psram-replay-verification-plan.md` as the block-level tracker.

---

## 1. Current methodology, and the path to constrained random

**Today:** the directed pass is essentially closed out. All 22 numbered tests in §2 are
`✅ done` except #23/#24 (system-level corroboration, opportunistic/blocked — not gaps in this
block's own verification). Both methods below remain fully directed; the open work is no longer
"write more directed tests," it's building the coverage/randomization layer described below.

- **cocotb simulation** — every suite instantiates the full `trouper_top.v` (not
  `psram_buf_ctrl.v` standalone) via the shared harness `cocotb/hdl/tb_trouper_cocotb.v` and
  behavioural model `cocotb/hdl/psram_model.v`. Each test is a hand-picked scenario with a
  fixed SF/BW/margin/timing, asserted bit-exact against a Python or model reference. No
  randomization of any kind. 13 suites, all passing (§3).
- **Formal (SymbiYosys k-induction)** — `formal/psram_buf_ctrl_formal.sv`, depth 90. **Wired in
  and non-vacuous** (#14 fixed the `ifdef FORMAL` instantiation gap, job 3494; #22 rewrote the
  replay-FSM entry/exit properties for the margin-gated design and confirmed non-vacuity again,
  job 3567). Two properties remain parked, not counted as coverage: `a_overflow_unreachable`
  (pre-existing, unrelated induction-regression issue, not root-caused) and RPV-F5.

There is still no code coverage (no `verilator --coverage`), no functional-coverage model (no
`cocotb-coverage`, no SVA `covergroup`/`cover`), and no constrained-random stimulus anywhere in
this flow. Confidence today comes from 22 named directed tests + a non-vacuous formal model, not
from any measurement of how much of the design's state space they jointly exercise — with all
directed rows closed, that measurement gap is now the limiting factor on further confidence, so
this plan's active scope moves to §1a below.

### 1a. Coverage / constrained-random work plan (active — see run order in §1b)

1. **Instrument coverage first** — add `--coverage` to the Verilator suites' `EXTRA_ARGS`
   (`cocotb/*/Makefile`) and merge `.dat` files across all 13 suites. Without this,
   constrained-random has no closure signal and just becomes "run longer and hope." Do this
   before writing any new randomized test so the baseline (coverage from the *existing* 22
   directed tests) is measured first — it may already reveal gaps §2 didn't anticipate.
2. **Define a coverage model off §2** — turn each requirement row into one or more
   coverpoints/crosses using `cocotb-coverage`, e.g.:
   - `{state, sub, dbg_mode, qspi_owner_eff}` — FSM × debug-fetch × ownership cross (rows #7/#8/#9/#18)
   - `{sf, sample_shift}` pairs across a session, including mid-session transitions (row #17)
   - debug-fetch phase relative to `iq_valid` / capture-write collision timing (row #16) — PBV-1's
     "sweep all 64 phase offsets" is exactly what this coverpoint closes automatically instead of
     by hand
   - `REPLAY_DELAY_SAMPLES` value bucketed low/mid/high-near-0xFFFF (row #20 only hit one extreme)
   - debug address relative to the 8 MB `AMASK` boundary (row #21 only hit one wrap point)
3. **Randomize the highest-value axes first**: `sf`/`sample_shift` per session, `REPLAY_DELAY_SAMPLES`,
   injection timing of `sc_lock`/`training_done`/`W_commit`/`qspi_owner` relative to QPI burst
   phase, and stimulus amplitude/pattern (the existing CW-stimulus limitation noted in
   `test_replay_data.py` — periodic input can't discriminate stale-vs-fresh replay data — is a
   concrete case where a dithered/random stimulus is required, not optional).
4. **Keep the directed tests** — constrained-random supplements but does not replace the directed
   suite; every `SPEC-SIM`/`EDGE-SIM` row in §2 stays as a named regression even after randomization
   lands, since it encodes a specific documented requirement or a specific known failure mode.
5. **Gate on coverage closure**, not iteration count, once (1)-(3) exist — e.g. "block is done" =
   the coverage model in (2) hits 100% (or a documented waiver list), not "N random seeds ran
   clean."

---

## 2. List of tests

Every test needed to verify this block — existing (run it, don't re-derive it) and new (write it).
`Type`: **SPEC-SIM** = directed cocotb test tracing a numbered `Traceability.md` requirement;
**FORMAL** = k-induction property; **EDGE-SIM** = directed robustness test found by RTL review, not
tied to a numbered requirement; **ANALYSIS/INTERFACE** = no test target, satisfied by
construction or register mechanics per `Traceability.md`'s own `Verif` column.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | QE init + tRST timing | SPEC-SIM | `cocotb/trouper_top` → `test_startup.py::test_qe_init_trst_margin` | TRPR-PSR-001 | ✅ done |
| 2 | Capture + SC delay-read correctness (full-chain via `sc_lock`) | SPEC-SIM | `cocotb/trouper_capture` → `test_capture_playback.py` | TRPR-PSR-002/016, TRPR-FBC-001/002/003 | ✅ done |
| 3 | `sc_ant_sel` branch routing + packet write-lock | SPEC-SIM | `cocotb/sc_ant_sel` → `test_sc_ant_sel.py` | TRPR-PSR-021 | ✅ done |
| 4 | Continuous-delay replay: margin timing, timeout ladder, monotonic `rd_ptr` | SPEC-SIM | `cocotb/replay_delay` → `test_replay_delay.py` | TRPR-PSR-022/024 | ✅ done (job 3347) |
| 5 | Replay data bit-exactness, second-packet freshness, owner-pause | SPEC-SIM | `cocotb/replay_data` → `test_replay_data.py` | TRPR-PSR-023/024 | ✅ done (job 3350) |
| 6 | `REPLAY_MISSED`/late-commit sticky, clear, recovery | SPEC-SIM | `cocotb/psram_ops` → `test_psram_ops.py::test_replay_missed_late_commit` | TRPR-PSR-004 | ✅ done (job 3313) |
| 7 | Debug readback bit-exactness vs. model memory | SPEC-SIM | `cocotb/psram_ops` → `test_psram_ops.py::test_dbg_readback_content` | TRPR-PSR-017 | ✅ done (job 3313) |
| 8 | `QSPI_OWNER` handover: burst-boundary effect, no pad glitch, resume | SPEC-SIM | `cocotb/qspi_owner` → `test_qspi_owner.py` | TRPR-PSR-010/011 | ✅ done (job 3314) |
| 9 | `PSRAM_STATUS` bit readback (`INIT_DONE`, `REPLAY_ACTIVE`, `REPLAY_MISSED`, `SAMPLE_SKIP`) | INTERFACE | `cocotb/trouper_top`, `cocotb/bypass_e2e` → `test_trouper_top.py`, `test_bypass_e2e.py` | TRPR-PSR-006 | ✅ done — `state`/`OVERFLOW`/`BUF_ACTIVE` bits now covered in sim (job 3570 standalone, job 3571 full 9-suite block regression clean): `test_bypass_e2e.py::_reset_and_lock` checks `state`[1:0]==S_WRITE / `BUF_ACTIVE`==0 pre-lock and `state`==S_WRITE / `BUF_ACTIVE`==1 post-lock; `_train_commit_replay` checks `state`==S_REPLAY / `BUF_ACTIVE`==1 / `OVERFLOW`==0 during normal replay; new `test_psram_status_overflow_bit_wiring` force-sets the internal sticky `overflow` register directly (a real `rd_ptr==wr_ptr` overflow is unreachable in sim per test #20) to prove `PSRAM_STATUS[6]` wiring and `PSRAM_CLR_ERR` clear-back |
| 10 | Sticky-flag clear mechanics (`PSRAM_CLR_ERR`) | INTERFACE | `rtl-test/` `tb_trouper_spi.v` (legacy iverilog) | TRPR-PSR-007 | ✅ done (mechanics only) |
| 11 | Sustained `SAMPLE_SKIP` clean under normal packet-active load | SPEC-SIM | `cocotb/trouper_top` → `test_trouper_top.py` SF7 BW250/BW125 | TRPR-PSR-020 | ✅ done (job 3310) — packet-active case only, see #16 |
| 12 | 0x77/0x78 reset values + dirty/reset sweep | SPEC-SIM | `cocotb/reg_reset_sweep` → `test_reg_reset_sweep.py` | TRPR-PSR-022 (register defaults) | ✅ done |
| 13 | Noise-mode (`TACC_NOISE_TRIG`) must not arm replay | SPEC-SIM | `cocotb/noise_trig` → `test_noise_trig.py` | replay margin gating | ✅ done |
| 14 | All k-induction properties (pointer/gap invariants, sticky-flag causality, legal-state transitions) | FORMAL | `formal/psram_buf_ctrl_formal.sv` + `.sby` | TRPR-PSR-002/003/004/007/009/014/015/016 (formal halves) | ✅ **done** — G1 fixed: `ifdef FORMAL` instantiation wired into `psram_buf_ctrl.v` (both `src/control/` and `rtl-test/rtl/`); `sby -f psram_buf_ctrl.sby` k-induction depth 90 PASS (job 3494), confirmed non-vacuous (checker cells merged into design in prep log, not dropped) |
| 15 | `PSRAM_EN=0` idle: no QSPI pad assertion | FORMAL only today | `formal/psram_buf_ctrl_formal.sv` (`a_buf_active_needs_en`) | TRPR-PSR-009 | ✅ **done** — covered via #14, now alive (job 3494) |
| 16 | Debug-fetch vs. capture-write collision at the real R=64 rate | EDGE-SIM | `cocotb/dbg_write_collision` → `test_dbg_write_collision.py` | Open Risks #30; extends TRPR-PSR-020 | ✅ **done** — confirmed the collision is real and deterministic at R=64 (fixed 31-cycle fetch > 20-cycle idle margin): `SAMPLE_SKIP` sets correctly, debug-fetch data stays intact, the dropped capture write is clean (no corruption), capture resumes normally, `CLR_ERR` works. Not a bug — the documented Open Risks #30 tradeoff holds exactly. PASS (job 3550); full 11-suite block regression also clean (job 3551). Also fixed the stale "CIC R=128" header comment in `psram_buf_ctrl.v` (both `src/control/` and `rtl-test/rtl/`) to the real R=64 numbers, documenting this finding inline |
| 17 | Warm-up re-arm when `sf`/`sample_shift` changes mid-session | EDGE-SIM/SPEC-SIM | `cocotb/warmup_rearm` → `test_warmup_rearm.py` | TRPR-PSR-019 (untested clause) | ✅ **done** — two cases, each exercising one disjunct of the `sf != sf_prev \|\| sample_shift != sample_shift_prev` re-arm condition in isolation (`test_warmup_rearm_sf_change`: SF7→SF9, BW250 constant; `test_warmup_rearm_sample_shift_change`: SF7 constant, BW250→BW125): lock+complete a first packet, change SF/BW between packets via the normal register-write path, confirm `del_rdy`/`del_cnt` genuinely reset (not stale carryover), `sc_detector.tdm_busy` never goes active on stale/pre-change data before the re-armed `del_rdy` fires, the measured re-arm warm-up latency matches the NEW config's `M = 2^(SF+shift)` prediction, and the receiver cleanly re-locks afterward. No RTL bug found — TRPR-PSR-019's re-arm clause holds exactly as documented for both the SF-only and sample_shift-only cases. PASS (job 3560); full 13-suite block regression also clean (job 3563) |
| 18 | `AUTO_INC` multi-sample streaming drain (3+ samples back-to-back) | — (new) | `cocotb/psram_ops` → `test_psram_ops.py::test_dbg_readback_multisample_stream` | TRPR-PSR-017 (deepens #7) | ✅ **done** — single `RD_TRIG`+`AUTO_INC` arm streams 4 samples (32 bytes) back-to-back with no further host writes: the initial `RD_TRIG`-triggered fetch plus 3 consecutive `dbg_idx==7`→refetch wraparounds, all bit-exact vs the behavioural model's stored PSRAM content. No RTL bug found — the refetch path is stable under repetition. PASS (job 3558); full 11-suite block regression also clean (job 3562) |
| 19 | `PSRAM_EN` dropped mid-transaction (`state==S_REPLAY`, port driven directly) | EDGE-SIM | `cocotb/psram_en_glitch` → `test_psram_en_glitch.py` | TRPR-PSR-009 — closes gap #15 | ✅ **done** — formal reachability probe first (temporary `cover` in `psram_buf_ctrl_formal.sv`, `mode cover` depth 90, reverted after): the scenario is formally **unreachable** under `m_buf_active_implies_packet_active`/`m_psram_en_stable_in_packet` — correct, since reg_bank.v gates PSRAM_EN writes on `!packet_active` and buf_active/packet_active hold throughout S_REPLAY, so firmware genuinely cannot cause this. Row asks for the port driven directly (bypassing that contract, e.g. an SEU/glitch), so covered instead by a cocotb EDGE-SIM test that forces the `psram_ctrl[0]` register bit straight (not via `spi_write`) mid-burst in S_REPLAY: no pad glitch, no new QPI burst launches while forced low, `wr_ptr`/`rd_ptr` freeze, `packet_end` still returns the FSM to `S_WRITE` cleanly (no deadlock), full recovery on the next packet after release. PASS (job 3500); full 10-suite block regression incl. this new test also clean (job 3501). No RTL bug found — behavior is safe by construction (PSRAM_EN only gates new-burst *launch*, never aborts an in-flight one). |
| 20 | Overflow-unreachability stress (SF12/125 kHz, extreme `REPLAY_DELAY_SAMPLES`) | — (new) | `cocotb/replay_data` → `test_replay_data.py::test_overflow_unreachable_stress_sf12_bw125` | corroborates formal (once #14 is alive) | ✅ **done** — SF12/BW125 (M=1<<14=16384, deepest symbol period) + `REPLAY_DELAY_SAMPLES`=`0xFFFF` (16-bit register max): measured wr_ptr/rd_ptr gap at replay start = 0x180000 (1,572,864 bytes), matching the training-window+margin calculation and well under the 8 MB/1,048,576-sample buffer depth. `OVERFLOW` stayed clear throughout the margin wait and across 300 watched replay samples with the gap holding perfectly constant (rd_ptr advancing exactly +8 bytes/pulse in lockstep with wr_ptr); replayed payload still bit-exact vs the recorded stream at this extreme config (reused #5's `_StreamRecorder`/`_compare_anchored` infra). Corroborates test #14's formal OVERFLOW/pointer-gap invariants under a real worst-case simulated stimulus. No RTL bug found. PASS (job 3558); full 11-suite block regression also clean (job 3562) |
| 21 | Debug address wraparound at the 8 MB boundary (`AMASK`) | EDGE-SIM | `cocotb/dbg_amask_wrap` → `test_dbg_amask_wrap.py` | Open Risks #25 (same bug class) | ✅ **done** — drove a debug-fetch `AUTO_INC` past the last 8-byte-aligned sample below the 8 MB boundary (0x7FFFF8 → 0x000000), with distinct known patterns pre-loaded at both (model-masked) addresses so a wrong-address read couldn't accidentally pass. Confirmed `dbg_addr_cur` wraps to exactly 0x000000 (not the unrepresentable 0x800000, not stuck), holds stable for the whole burst, both fetches take the same fixed 31-sub-cycle QPI burst (no bogus/short/extra burst around the wrap), and content reads back bit-exact on both sides of the boundary. No RTL bug found — the `& AMASK` masking on every `dbg_addr_cur` advance is correct at the boundary. Note: cross-checked the row's "Open Risks #25" citation against `planning/Open Risks.md` — item #25 (~857-897, dead-FSM-logic hygiene) is unrelated to addressing; the actual 2^23/AMASK wraparound material lives under Open Risks item #32's formal-effort note (~1069-1143). Likely a stale cross-reference in this row, flagged but not otherwise acted on (test itself unaffected). PASS (job 3561); full 13-suite block regression also clean (job 3563) |
| 22 | Replay-FSM entry/exit formal properties rewritten for the margin-gated design | FORMAL | `formal/psram_buf_ctrl_formal.sv` (rewrite) | TRPR-RMD-009, TRPR-PSR-003/024 formal halves | ✅ **done** — the one real staleness found was the group-A pointer-gap environment assumption (`m_gap_bounded_lo`/`_hi`), which sampled the replay backlog at `W_commit` (a leftover from the removed W_commit-triggered design, no longer tied to when S_REPLAY actually starts); rekeyed to the real margin-expiry trigger (`wait_armed && wait_cnt==0 && !qpi_busy && psram_en && !packet_end`). The carried-over lockstep/sticky properties (`a_replay_active_matches_state`, `a_replay_missed_cause`/`_sticky`) needed only comment fixes — their logic never actually referenced `W_commit`. Added 4 new property groups per RPV-F1..F4 (`planning/psram-replay-verification-plan.md`): `a_replay_entry_iff_margin` (S_REPLAY entered iff-and-only-if the margin-met trigger held the prior cycle — the formal replacement for the old "REPLAY_ACTIVE on W_commit" claim, TRPR-PSR-003), `a_wait_armed_only_in_write`/`a_wait_armed_clears_on_end`, `a_rd_ptr_loads_buf_base`/`a_rd_ptr_advances_replay_readdone`/`a_rd_ptr_stable` (rd_ptr's entire update rule pinned down — the formal half of TRPR-PSR-024/mechanised TRPR-RMD-009), and `a_w_commit_late_cause`/`_sticky`. New `training_done`/`wait_armed`/`wait_cnt`/`w_commit_late` ports wired into the `ifdef FORMAL` instantiation (`src/control/psram_buf_ctrl.v` and `rtl-test/rtl/` mirror). Two genuine induction counterexamples found and fixed during development (not RTL bugs, proof-timing gaps): `a_rd_ptr_advances_replay_readdone` initially didn't exclude a same-cycle `packet_end` (S_REPLAY's `if(packet_end)` exit check takes priority over the sub==55 read-done case, so rd_ptr doesn't advance on that boundary cycle), and didn't require `qpi_busy_q` (a stale `sub==55` left over with no transaction in flight doesn't advance rd_ptr either). `sby -f psram_buf_ctrl.sby` k-induction depth 90 PASS (job 3567); confirmed non-vacuous — all 8 new/rewritten assertion labels present in the final SMT2 model (`grep` on `design_smt2.smt2`), and `psram_buf_ctrl_formal`'s "keep" attribute forced by yosys because it "directly or indirectly contains formal properties" (`design.log`), same non-optimized-away check used for #14. Full 10-suite block regression (9 self-contained + `trouper_capture`) also clean (jobs 3568/3569). RPV-F5 (overflow unreachability) intentionally not attempted — inherits the same pre-existing PARKED status as `a_overflow_unreachable` in group A (unrelated induction regression, not root-caused, predates this row). RPV-F6 (carry-over of still-valid old properties) confirmed as noted above. |
| 23 | Real-capture replay at SF12/BW125 (deep address, ~1 MB depth) | SPEC-SIM | `cocotb/trouper_capture` | system-level corroboration | ⬜ planned |
| 24 | FPGA emulation bring-up re-check | — | `fpga-emul/` `sim_inject` | system-level corroboration | ⬜ planned, blocked on Vivado regen |

### 1b. Run order — completed directed pass, then coverage/constrained-random (active)

**Directed pass (closed):**

1. ~~Fix #14 (formal re-wire)~~ — ✅ done, unblocked #15/22 and revalidated 8 other requirement IDs.
2. ~~Write #19~~ — ✅ done (cocotb EDGE-SIM, job 3500; formal reachability probe first showed the scenario unreachable via firmware, so covered as a port-level fault-injection test instead).
3. ~~Write #16~~ — ✅ done (cocotb EDGE-SIM, job 3550; confirmed Open Risks #30 is a documented tradeoff, not a live bug — also fixed the stale R=128 header comment).
4. ~~Write #17, #21~~ — ✅ done (cocotb EDGE-SIM/SPEC-SIM, jobs 3560/3561; full 13-suite block regression clean, job 3563). #17: two new-infrastructure cases (`cocotb/warmup_rearm`) proving the SF-only and sample_shift-only re-arm disjuncts independently. #21: one new-infrastructure case (`cocotb/dbg_amask_wrap`) proving the debug-fetch `AUTO_INC` address wraps cleanly at the 8 MB `AMASK` boundary. No RTL bugs found in either; also flagged that the row's "Open Risks #25" citation looks stale (the actual 2^23-wraparound material is under Open Risks #32, not #25).
5. ~~Write #18, #20~~ — ✅ done (cocotb SPEC-SIM/EDGE-SIM, job 3558; full 11-suite block regression clean, job 3562). #18 reused #7's `test_psram_ops.py` infra (streamed 4 samples/3 refetch wraps over one `RD_TRIG`+`AUTO_INC` arm); #20 reused #5's `test_replay_data.py` infra (`_StreamRecorder`/`_compare_anchored`) at SF12/BW125 + max `REPLAY_DELAY_SAMPLES`, confirming `OVERFLOW` unreachability in sim. No RTL bugs found in either.
6. ~~Write #22~~ — ✅ done (formal rewrite, job 3567 PASS depth 90, confirmed non-vacuous; full 10-suite block regression clean, jobs 3568/3569). Rekeyed the one real stale piece (the group-A pointer-gap assumption, previously keyed off `W_commit`) to the actual margin-expiry trigger, and added RPV-F1..F4 as new properties; RPV-F5 stays parked (pre-existing, unrelated), RPV-F6's carry-over confirmed.
7. ~~Improve #9~~ — ✅ done (`state`/`OVERFLOW`/`BUF_ACTIVE` closed, jobs 3570/3571; full 9-suite block regression clean).
8. #23/#24 — opportunistic, next capture-harness or FPGA session (not blocking the coverage work below).

**Coverage / constrained-random (next, per §1a):**

9. **Instrument coverage** (§1a step 1) — add `--coverage` to `cocotb/*/Makefile` `EXTRA_ARGS` for
   all 13 suites, merge `.dat` output, and run the existing directed regression once under
   instrumentation to get a *baseline* coverage number before any new test is written. This baseline
   is the first real evidence of how much of the state space 22 directed tests actually reach.
10. **Build the coverage model** (§1a step 2) — implement the coverpoints/crosses listed there with
    `cocotb-coverage`, scored against the baseline from step 9. Treat any coverpoint the directed
    suite already hits at ~100% as evidence that axis doesn't need randomization; prioritize the
    ones the baseline shows as sparse (expected candidates: `REPLAY_DELAY_SAMPLES` bucket coverage,
    `AMASK`-boundary proximity, mid-session `sf`/`sample_shift` transition coverage).
11. **Randomize the sparse axes** (§1a step 3) — write constrained-random layers on top of the
    highest-value axes identified in step 10, gated by the coverage model, not a fixed seed count.
12. **Re-run full regression + coverage merge** after each new randomized layer lands, and update
    this section with the resulting coverage percentage and any newly-found gaps or bugs.

---

## 3. Regression command

Every suite above lives under `cocotb/<dir>`, one `make` per directory, no aggregate runner exists:

```bash
# Inside the hpretl/iic-osic-tools:chipathon26 container, repo at /foss/designs/lora-mimo

# trouper_capture is not self-contained — it replays a real captured .npy IQ file and
# asserts immediately if CAPTURE_NPY is unset (see cocotb/trouper_capture/Makefile,
# cocotb/README.md). Defaults (CAPTURE_START=0, CAPTURE_NSAMP=60000) do NOT reliably land
# on the packet burst — confirmed by running it (job 3492: "sc_lock never fired over the
# capture window"). Compute the real burst window first:
python3 cocotb/tests/sweep_captures.py lora-capture/captures
#   -> prints one TSV row per (SF,BW) capture found: <npy> <sf> <bw> <start> <nsamp> <stage>
#   use that row's start/nsamp verbatim, e.g. (job 3493, confirmed PASS):
(cd cocotb/trouper_capture && \
  make CAPTURE_NPY=/foss/designs/lora-mimo/lora-capture/captures/<file>.npy \
       CAPTURE_SF=7 CAPTURE_BW=250 CAPTURE_START=562185 CAPTURE_NSAMP=24576 \
       CAPTURE_STAGE=full) || echo "FAILED: trouper_capture"

# The remaining 9 suites are self-contained, plain `make`:
for d in replay_delay replay_data psram_ops qspi_owner sc_ant_sel \
         noise_trig reg_reset_sweep trouper_top bypass_e2e; do
  echo "=== cocotb/$d ==="
  (cd cocotb/$d && make) || echo "FAILED: $d"
done
sby -f formal/psram_buf_ctrl.sby   # separate — currently vacuous, see test #14
```

Run this full list before merging any change to `psram_buf_ctrl.v` (or `reg_bank.v`/
`packet_ctrl_fsm.v`/`trouper_top.v` where it touches PSRAM wiring) — every suite above shares the
same top-level instantiation of this block, so a regression can surface in a suite that doesn't
look PSRAM-specific at a glance. Capture `.npy` files aren't checked into git (binary/large,
`lora-capture/captures/` is data-only) — pull one from an existing NFS designs checkout
(e.g. `/srv/eda/designs/<user>/lora-mimo/lora-capture/captures/`) or `lora-capture/`'s own capture
tooling if none is available in your `designs_dir`.

---

## 4. Explicit non-goals

- `packet_end` before `training_done`: unreachable from register config with live stimulus.
- Commit landing on the exact `S_REPLAY`-entry cycle: not reachable over bit-banged SPI — test #22
  covers the register semantics, not this cocotb-unreachable boundary.
- Open Risks #14 residual (tail truncation): firmware/documentation item (`PKT_TIMEOUT_SYMS`
  budgeting), not an RTL test gap.
- tPU (150 µs post-power-up) enforcement: out of RTL scope (Open Risks #27) — host/board
  discipline only.
