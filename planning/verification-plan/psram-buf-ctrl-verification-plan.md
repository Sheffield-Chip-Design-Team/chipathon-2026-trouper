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

**Today:** two methods, both fully directed.

- **cocotb simulation** — every suite instantiates the full `trouper_top.v` (not
  `psram_buf_ctrl.v` standalone) via the shared harness `cocotb/hdl/tb_trouper_cocotb.v` and
  behavioural model `cocotb/hdl/psram_model.v`. Each test is a hand-picked scenario with a
  fixed SF/BW/margin/timing, asserted bit-exact against a Python or model reference. No
  randomization of any kind.
- **Formal (SymbiYosys k-induction)** — `formal/psram_buf_ctrl_formal.sv`, a curated set of
  hand-written safety/liveness properties, depth 90. Currently **not wired into the RTL**
  (`ifdef FORMAL` instantiation missing from `psram_buf_ctrl.v` — G1 below), so it is producing a
  vacuous pass, not real coverage, until that's fixed.

There is no code coverage (no `verilator --coverage`), no functional-coverage model (no
`cocotb-coverage`, no SVA `covergroup`/`cover`), and no constrained-random stimulus anywhere in
this flow. Confidence today comes entirely from the tests below actually existing and passing,
not from any measurement of how much of the design's state space they exercise.

**Steps to move toward constrained random (future, not in this plan's scope):**

1. **Instrument coverage first** — add `--coverage` to the Verilator suites' `EXTRA_ARGS`
   (`cocotb/*/Makefile`) and merge `.dat` files across suites. Without this, constrained-random
   has no closure signal and just becomes "run longer and hope."
2. **Define a coverage model off §2** — turn each requirement row below into one or more
   coverpoints/crosses (e.g. `{state, sub, dbg_mode, qspi_owner_eff}`, `{sf, sample_shift}` pairs,
   debug-fetch phase relative to `iq_valid`) using `cocotb-coverage`. PBV-1's "sweep all 64 phase
   offsets" (§3) is exactly the kind of thing a `phase` coverpoint would close automatically
   instead of by hand.
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
| 9 | `PSRAM_STATUS` bit readback (`INIT_DONE`, `REPLAY_ACTIVE`, `REPLAY_MISSED`, `SAMPLE_SKIP`) | INTERFACE | `cocotb/trouper_top`, `cocotb/bypass_e2e` → `test_trouper_top.py`, `test_bypass_e2e.py` | TRPR-PSR-006 | ⚠️ partial — `state`/`OVERFLOW`/`BUF_ACTIVE` bits not covered in sim |
| 10 | Sticky-flag clear mechanics (`PSRAM_CLR_ERR`) | INTERFACE | `rtl-test/` `tb_trouper_spi.v` (legacy iverilog) | TRPR-PSR-007 | ✅ done (mechanics only) |
| 11 | Sustained `SAMPLE_SKIP` clean under normal packet-active load | SPEC-SIM | `cocotb/trouper_top` → `test_trouper_top.py` SF7 BW250/BW125 | TRPR-PSR-020 | ✅ done (job 3310) — packet-active case only, see #16 |
| 12 | 0x77/0x78 reset values + dirty/reset sweep | SPEC-SIM | `cocotb/reg_reset_sweep` → `test_reg_reset_sweep.py` | TRPR-PSR-022 (register defaults) | ✅ done |
| 13 | Noise-mode (`TACC_NOISE_TRIG`) must not arm replay | SPEC-SIM | `cocotb/noise_trig` → `test_noise_trig.py` | replay margin gating | ✅ done |
| 14 | All k-induction properties (pointer/gap invariants, sticky-flag causality, legal-state transitions) | FORMAL | `formal/psram_buf_ctrl_formal.sv` + `.sby` | TRPR-PSR-002/003/004/007/009/014/015/016 (formal halves) | ❌ **dead** — `ifdef FORMAL` not instantiated (G1). Fix before trusting any "formal ✅" elsewhere in this table |
| 15 | `PSRAM_EN=0` idle: no QSPI pad assertion | FORMAL only today | `formal/psram_buf_ctrl_formal.sv` (`a_buf_active_needs_en`) | TRPR-PSR-009 | ❌ **no running coverage at all** — sole claim is #14, which is dead. Highest-priority new test (below) |
| 16 | Debug-fetch vs. capture-write collision at the real R=64 rate | — (new) | not written | Open Risks #30; extends TRPR-PSR-020 | ⬜ **to write** — RTL header comment still budgets against the old R=128 rate; #11 only tests the packet-active case, not idle-mode debug reads against the tighter ~20-cycle margin |
| 17 | Warm-up re-arm when `sf`/`sample_shift` changes mid-session | — (new) | not written | TRPR-PSR-019 (untested clause) | ⬜ **to write** — only fixed-config warm-up latency is tested today; formal assumes SF/shift constant so can't cover this either |
| 18 | `AUTO_INC` multi-sample streaming drain (3+ samples back-to-back) | — (new) | not written | TRPR-PSR-017 (deepens #7) | ⬜ **to write** — `dbg_idx==7`→refetch is a distinct path from the initial `RD_TRIG` latch, untested in isolation |
| 19 | `PSRAM_EN` dropped mid-transaction (`state==S_REPLAY`, port driven directly) | — (new) | not written | TRPR-PSR-009 — closes gap #15 | ⬜ **to write** |
| 20 | Overflow-unreachability stress (SF12/125 kHz, extreme `REPLAY_DELAY_SAMPLES`) | — (new) | not written | corroborates formal (once #14 is alive) | ⬜ **to write** |
| 21 | Debug address wraparound at the 8 MB boundary (`AMASK`) | — (new) | not written | Open Risks #25 (same bug class) | ⬜ **to write** |
| 22 | Replay-FSM entry/exit formal properties rewritten for the margin-gated design | FORMAL | `formal/psram_buf_ctrl_formal.sv` (rewrite) | TRPR-RMD-009, TRPR-PSR-003/024 formal halves | ⬜ **to write** — existing properties encode the old W_COMMIT-triggered contract |
| 23 | Real-capture replay at SF12/BW125 (deep address, ~1 MB depth) | SPEC-SIM | `cocotb/trouper_capture` | system-level corroboration | ⬜ planned |
| 24 | FPGA emulation bring-up re-check | — | `fpga-emul/` `sim_inject` | system-level corroboration | ⬜ planned, blocked on Vivado regen |

### Run order for the 8 new tests (16–21 primarily; 22 depends on 14; 23/24 opportunistic)

1. Fix #14 (formal re-wire) — free, unblocks #15/22 and revalidates 8 other requirement IDs.
2. Write #19 — #15 currently has zero running coverage, the single biggest hole in this table.
3. Write #16 — resolves whether Open Risks #30 is a live bug.
4. Write #17, #21 — one job, no new infrastructure.
5. Write #18, #20 — second job, reuses #7/#5 infrastructure.
6. Write #22 — once #14 is alive.
7. #23/#24 — opportunistic, next capture-harness or FPGA session.

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
