# Continuous-Delay PSRAM Replay — Verification Plan

**Status:** PLANNED 2026-07-12. Covers the remaining verification for the
implemented continuous-delay replay
(`planning/psram-replay-continuous-delay-redesign.md`, branch
`psram-replay-continuous-delay`).
**DUT scope:** `psram_buf_ctrl.v` margin-gated `S_REPLAY` +
`reg_bank.v` `REPLAY_DELAY_SAMPLES`/`WGT_CTRL[4]` + `trouper_top.v`
silence/mux wiring.
**Requirements:** `TRPR-RMD-009` (no backward time-index jump), Open Risks
#5 (closed — keep closed), #14 residual (deterministic trailing gap).

## 1. Coverage already in place (SGE jobs 3347/3350, all PASS)

| Behaviour | Test |
|---|---|
| Rung 3: no commit → replay runs in bypass, `W_MISSED_PACKET`, **no** `REPLAY_MISSED`, slot handback (re-lock) | `test_replay_delay.test_timeout_replay_without_commit` |
| Rung 2: late commit → mid-stream MRC upgrade, `W_COMMIT_LATE` sticky through IDLE, cleared at next lock | `test_replay_delay.test_commit_late_sets_late_flag` |
| Rung 1: on-time commit → MRC replay, no flags | `test_replay_delay.test_commit_on_time_no_flags` |
| `rd_ptr` strictly +8/`rpl_valid`, never rewinds (60-sample window) | `_watch_monotonic_replay` (in rung-3 test) |
| Margin never met → no replay, `REPLAY_MISSED` at `packet_end`; idle commit inert; `PSRAM_CLR_ERR` | `test_psram_ops.test_replay_missed_late_commit` |
| Silence = **modulated** zeros (`in_valid` pulses, data (0,0)) | `_watch_bypass(expect_silenced=True)` in bypass_e2e / w_missed |
| Replay handover under `QSPI_OWNER` (buffering + mid-replay) | `test_qspi_owner` |
| 0x77/0x78 reset values + dirty/reset sweep | `test_reg_reset_sweep` |

## 2. Batch 1 — DONE 2026-07-12 (SGE job 3354, 8/8 PASS)

Measured replay-start gap is exactly `REPLAY_DELAY_SAMPLES + 1` sample
(33/301/1 for margins 32/300/0 — the +1 is the first replay read
completing on the following sample's burst). Note: job 3353's first run of
this batch failed spuriously — a concurrent worktree session clobbered the
shared NFS `src/` mirror with stale main-branch RTL; batch reruns use the
isolated `lora-mimo-replay-wt` NFS copy with `DESIGN_ROOT` overridden
(remove that dir when this branch merges).

| ID | Test | Method | Pass criterion |
|---|---|---|---|
| RPV-1 | Noise-mode must not arm replay | Idle (no lock), pulse `TACC_NOISE_TRIG` (0x1F), wait noise `training_done` | `REPLAY_ACTIVE` stays 0 for ≥ margin + slack; no `REPLAY_MISSED` |
| RPV-2 | Replay-start instant bit-exact | Count `iq_valid` pulses between `training_done` rising edge and first `rpl_valid` | count == `REPLAY_DELAY_SAMPLES` + delay-line lag ± 1 burst (the `!qpi_busy` entry skew); run at two margin values (e.g. 32, 300) |
| RPV-3 | `REPLAY_DELAY_SAMPLES = 0` | Rung-3 flow with 0x77/0x78 = 0 | Replay starts immediately after `training_done` (same instant check as RPV-2 with N=0); no flags beyond the expected `W_MISSED_PACKET` |
| RPV-4 | 0x77/0x78 write-gate during packet | Mid-packet write attempt, readback (BW_CFG-lock pattern from `test_trouper_top`) | Readback unchanged during packet; write lands after `packet_end` |

Home: RPV-1..3 in `cocotb/tests/test_replay_delay.py`; RPV-4 alongside the
BW_CFG lock check.

## 3. Batch 2 — DONE 2026-07-12 (SGE job 3355, 3/3 PASS; `cocotb/replay_data/`)

RPV-5: 512 replayed samples bit-exact against the recorded live stream,
anchored at `timing_ref` (offset −1 within the ±3 skew band). RPV-6: packet
2 anchors at its own `timing_ref` (274→5396); caveat — the settled CW
stimulus is exactly periodic, so the *negative* staleness probe cannot
discriminate packet 1 from packet 2 by value (logged as a warning; the
positive anchor check carries the requirement — a noise-dithered stimulus
would be needed to make the negative probe binding). RPV-7: wait frozen
under `QSPI_OWNER` (no replay for ~3 syms past a 600-sample margin),
replay resumed after release, pre-pause prefix bit-exact, no
`REPLAY_MISSED`/`SAMPLE_SKIP`.

| ID | Test | Method | Pass criterion |
|---|---|---|---|
| RPV-5 | Replay data bit-exact vs captured stream | Record `dcr_i/q[0:3]` per `dcr_valid` from lock onward (Python-side history); compare `rpl_*` stream against it | `rpl[n] == dcr[n]` from n=0 (packet start = backdated `buf_base`) for ≥ 2 symbols; constant live-vs-replay lag == `tacc_window·M + REPLAY_DELAY_SAMPLES` ± detection skew. Catches wrong `buf_base` backdate / address off-by-8 that pointer checks miss |
| RPV-6 | Second packet's replay is fresh | Extend rung-3 test past re-lock: wait packet 2's `REPLAY_ACTIVE` | Packet 2 replays; its first `rpl_*` samples match packet 2's recorded stream (RPV-5 compare), not packet 1's (stale `buf_base` detector) |
| RPV-7 | `QSPI_OWNER` across the margin wait | owner=1 after `training_done`, hold ≳ margin, release | No replay start while owner=1 (`wait_cnt` frozen — writes suspended); replay starts after release; RPV-5-style data compare still passes |

## 4. Formal (`formal/psram_buf_ctrl_formal.sv` rewrite) — **DONE 2026-07-19**

RPV-F1..F6 all PASS (k-induction depth 90, SGE job 3487; 33 assertions in the
elaborated model — non-vacuous). Harness rewritten for the margin-gated FSM;
`ifdef FORMAL` instantiation reinstated in `psram_buf_ctrl.v` (it had been
deleted by 0c0171a, making any sby run vacuous). New load-bearing environment
assumption `m_sc_lock_level_held` (sc_lock cannot re-edge while
`buf_base_valid` — Open Risks #25 contract). RPV-F5's overflow-unreachability,
parked in the old harness, is now proven via two-phase transaction gap
invariants. Bonus: new `formal/packet_ctrl_fsm.sby` proof (26 assertions,
PASS same job): B6 20-bit modular-subtract exactness, #39 single-cycle
ST_ACQ_SETUP structure, packet_active_ps mirror, W_missed protocol.

| ID | Property |
|---|---|
| RPV-F1 | `S_REPLAY` entry only with `wait_armed && wait_cnt==0` in the prior cycle (no other entry path; in particular never from `W_commit`) |
| RPV-F2 | `wait_armed` is always cleared by `packet_end` and by `S_REPLAY` entry; never survives into IDLE |
| RPV-F3 | `rd_ptr` changes only in `S_REPLAY` at read-done, always by +8 mod 2^23 after its `buf_base` load (the mechanised `TRPR-RMD-009`) |
| RPV-F4 | `w_commit_late` set ⇒ `replay_active` held in the same cycle; cleared only by lock-edge or `clr_err` |
| RPV-F5 | Overflow unreachability: with the fixed-gap delay line, `rd_ptr == wr_ptr` in `S_REPLAY` is unreachable for any `replay_delay_samples ≥ 0` and any training window (simulation cannot show this; the old `overflow` sticky becomes a can't-happen assertion) |
| RPV-F6 | Carry over the still-valid old properties: `replay_active ⟺ state==S_REPLAY`, `replay_missed` cause/stickiness, owner-suspend pad safety |

## 5. Planned — system level

| ID | Test | Notes |
|---|---|---|
| RPV-8 | Real-capture replay stage in `cocotb_trouper_capture` | Measured-IQ playback with small margin + EGC commit; sanity on replayed MRC output. Include one SF12/BW125 point: training window 131k samples ≈ 1 MB PSRAM depth — exercises the address math at the deep end |
| RPV-9 | FPGA emul bring-up check | `fpga_dsp_wrap` instantiates `trouper_top` unchanged, but the ext-PSRAM board path should re-run `sim_inject` once the Vivado regen lands (see fpga-emul re-pin TODO) |

## 6. Explicit non-goals

- `packet_end` before `training_done`: unreachable from register config
  with a live stimulus (`packet_ctrl_fsm` checks `PKT_TIMEOUT_SYMS` only in
  `PAYLOAD_ACTIVE`; `training_acc` completes its window regardless), and
  the margin-unmet fallback is already covered. Revisit only if the FSM
  timeout structure changes.
- Commit landing on the exact `S_REPLAY`-entry cycle (late-flag boundary):
  not reliably reachable over bit-banged SPI; RPV-F4 covers the register
  semantics — the boundary cycle itself is a formal concern, not cocotb.
- Open Risks #14 residual (tail truncation): a *documentation/firmware*
  item (PKT_TIMEOUT budgeting rule or drain-then-exit RTL change), tracked
  there, not a test gap here.

## 7. Suggested order

Batch 1 (RPV-1..4) — one SGE job, additions to existing suites.
Batch 2 (RPV-5..7) — second job; RPV-5's recorder is the only new
infrastructure and RPV-6/7 reuse it.
Formal (RPV-F1..F6) — own task; blocked on nothing, benefits from RPV-5
landing first so counterexamples can be cross-checked in cocotb.
System (RPV-8..9) — opportunistic, alongside the next capture-harness or
FPGA session.
