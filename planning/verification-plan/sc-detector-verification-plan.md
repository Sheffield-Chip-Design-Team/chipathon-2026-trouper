# Schmidl-Cox Detector (`sc_detector`) — Verification Plan

**DUT:** `src/frontend/sc_detector.v` (`sc_detector` + `serial_mul13`). The
`rtl-test/rtl/sc_detector.v` copy is **stale** (differs from `src/`); do not use
it as evidence.

**Scope:** the single-branch per-symbol autocorrelator (`cur`/`del` from the
PSRAM delay line), the 32-bit symbol accumulators and M-scaled saturating
snapshot, the serial-multiplier metric engine, the e_slice guard and divider-free
threshold test, hit counting / `sc_lock` / `timing_ref`, the `sample_count`
deferral, re-arm on `sc_clr`, the `sc_lock_force` and `sc_lock_sync`
overrides, and the debug/telemetry outputs.

**Inputs reviewed:** `planning/Trouper Chip Specification.md`
(TRPR-SCD-001..016), `planning/Traceability.md` §SCD, `planning/Open Risks.md`
(#9 deferred, #36/#61/#66 closed, **#74 open**, **#81 open**),
`planning/sc-detector-ant0-fading-risk.md`,
`planning/sc-timing-ref-replay-backdate-2026-10-03.md`,
`planning/array-acquisition-sync.md`, `sim/models/sc_rtl.py`,
`src/top/trouper_top.v` (u_sc), the cocotb tests named in §2, and the current RTL.

This is the block-level closure tracker for `sc_detector`. Which antenna feeds
`cur_i0/q0` and `del_i0/q0` (`SC_ANT_SEL`) and when `delayed_valid` starts
(`del_rdy` warm-up) are `psram_buf_ctrl` behaviour, tracked in its plan.

---

## 1. Current methodology, and the path to constrained random

**Today:** the lock decision and `timing_ref` are bit-exact against the
integer model `sc_rtl.py` over randomized packets (random guard, Rayleigh tap,
SNR −5..20 dB) at M=64/256; the #61 accumulator/snapshot fix is regression-
tested to SF10; debug readback, low-energy suppression, force-lock, antenna
select, warm-up re-arm and array sync are directly tested. Open: Open Risk
#74 (`sc_clr` drops a pending `sample_count` increment — code inspection,
not reproduced), golden coverage above M=256, and the spec's stale
"antenna 0 only" wording.

- **Bit-exact differential (cocotb, standalone)** — `cocotb/sc_timing_golden`
  drives `sc_detector` at production cadence (`iq_valid` / 64 clocks, `del`
  44 clocks later) and compares lock + `timing_ref` against `sc_rtl_detect`
  packet by packet: SF6 (M=64), SF7/BW125, and non-default
  `SC_THR`/`SC_HITS_REQ` at M=256.
- **Overflow regression (standalone)** — `cocotb/sc_acc_overflow`: SF7
  baseline, SF9 snapshot sign, SF9 amplitude-64 lock, boundary-sample
  `E0del`, SF10 true wrap (all pass post-#61).
- **MCP settle (standalone)** — `cocotb/mcp_sc_settle`.
- **Full-top** — `sc_dbg`, `sc_force_lock`, `sc_ant_sel`, `warmup_rearm`,
  `array_sync`, `noise_window_edge`, `trouper_top` (SF7–12 × BW sweep),
  and the capture suites (real IQ, two-packet re-arm).
- **Coverage gap** — no code/functional coverage; the golden differential
  stops at M=256, so SF8–SF12 lock/`timing_ref` exactness rests on the
  full-top sweep (functional lock, not exact `timing_ref`).

The active order is:

1. Reproduce Open Risk #74 (row #14) in a standalone bench; it is the one
   open functional defect.
2. Extend `sc_timing_golden` to SF9/SF12 at both BWs (row #5).
3. Coverage instrumentation, then constrained-random packet streams with
   back-to-back packets and `sc_clr` at random phases.

### 1a. Coverage model

At minimum, collect:

- SF 6..12 × `sample_shift` 1..2 (M = 64 … 16384);
- `SC_HITS_REQ` 0..3 and `SC_THR` low / reset / high;
- hit-run patterns: run broken at each position, run reaching lock;
- e_slice guard true/false with the threshold comparison true/false;
- snapshot saturation (`sat13`) hit, each operand, each sign;
- `sc_clr`, `sc_lock_force`, `sc_lock_sync` arriving: idle, mid-symbol,
  mid-TDM-burst (the `iq_inc_pending` window), mid-eval;
- `iq_valid` landing during a TDM burst (deferral path).

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test; **EDGE-SIM** =
robustness case from RTL review; **DIFF** = bit-exact differential;
**INTERFACE** = owned or observed at the top level.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | Per-symbol complex autocorrelation and energy terms feed a correct hit decision | DIFF | `cocotb/sc_timing_golden` (decision exact vs model) | TRPR-SCD-001/002 | ✅ done (job 5810) |
| 2 | One hit decision per completed symbol, full-M delayed samples | DIFF | same; `cocotb/trouper_capture` (real IQ) | TRPR-SCD-003 | ✅ done |
| 3 | `sc_lock` after `SC_HITS_REQ+1` consecutive hits; a miss resets the run | DIFF | `sc_timing_golden::test_sc_timing_other_cfg` + model | TRPR-SCD-004 | ✅ done |
| 4 | `timing_ref = lock_sample − (SC_HITS_REQ+1)·M + 1` exactly | DIFF | `sc_timing_golden` (model closed form) | TRPR-SCD-005 | ✅ done |
| 5 | Same exactness at SF9 and SF12, both BWs (M up to 16384) | DIFF | extend `sc_timing_golden` | TRPR-SCD-001..005 at high M | ⬜ new — today M ≤ 256 |
| 6 | 32-bit accumulators never wrap and snapshots stay sign-correct at legal SF/amplitude; `E0del` includes the boundary sample | EDGE-SIM | `cocotb/sc_acc_overflow` (5 tests) | Open Risk #61 | ✅ done |
| 7 | e_slice guard suppresses hits at negligible energy | SPEC-SIM | `cocotb/sc_dbg` → `test_low_energy_hit_suppression` | TRPR-SCD-016 | ✅ done — spec text still quotes the pre-#61 `eval_e_acc[25:13]` slice; the RTL still uses that slice of the *M-scaled* product, so the meaning changed with #61 (re-word the row) |
| 8 | `SC_THR` low 12 bits consumed, reset 0x01CC | INTERFACE | `cocotb/reg_reset_sweep`, `trouper_top` | TRPR-SCD-007 | ✅ done |
| 9 | `SC_HITS_REQ` = 0 (diagnostic one-hit) locks on the first hit | SPEC-SIM | add to `sc_timing_golden` | TRPR-SCD-008 | ⬜ new — values 1–3 covered, 0 not |
| 10 | `SC_STAT`, `SC_DBG_FLAGS`, `SC_FIRST_HIT`, `SC_LOCK_SNAP` readback | INTERFACE | `cocotb/sc_dbg` → `test_sc_dbg_flags_readback` | TRPR-SCD-009/010 | ✅ done |
| 11 | Lock within ±1 symbol of the Python model at SF7/125 kHz/0 dB | DIFF | `sc_timing_golden` (exact) | TRPR-SCD-013 | ✅ done |
| 12 | `sc_lock` de-asserts and re-arms on PCFSM → IDLE; next packet acquired | SPEC-SIM | `cocotb/capture_two_packet`, `cocotb/warmup_rearm`, `tb_trouper_two_packet.v` | TRPR-SCD-014 | ✅ done |
| 13 | `sc_clr` clears hit counter, accumulators and metric state | EDGE-SIM | standalone, `sc_clr` at idle / mid-symbol / mid-eval, then a clean packet must match the model | TRPR-SCD-014 (cycle level) | 🟨 partial — system re-arm proven, state-clear not directly asserted |
| 14 | `sc_clr` during the `iq_inc_pending` window must not lose a `sample_count` increment (`timing_ref` stays aligned with `iq_samp_cnt`) | EDGE-SIM | new standalone bench: `sc_clr` swept across the 64-clock period, compare `sample_count` with a strobe counter | **Open Risk #74** | ⬜ new — expected to FAIL on current RTL (line 637); goes to `xfail` until fixed |
| 15 | `sc_lock_force` from idle locks; blocked during a packet | INTERFACE | `cocotb/sc_force_lock` (2 tests) | Register Map 0x19 | ✅ done |
| 16 | `sc_lock_sync` peer acquisition: idle-only, suppresses local detector, releases/re-arms | INTERFACE | `cocotb/array_sync` (9 tests) | `planning/array-acquisition-sync.md` | ✅ done |
| 17 | TDM/eval results consumed only after the MCP settle | EDGE-SIM | `cocotb/mcp_sc_settle` | Open Risk #43 | ✅ done |
| 18 | Spec says branch 0 only; RTL correlates whichever branch `SC_ANT_SEL` routes into `cur_i0/del_i0` | INTERFACE | `cocotb/sc_ant_sel` (mux + delay offset) | TRPR-SCD-001/006 vs Open Risk #9 mitigation | ✅ done (spec re-worded 2026-10-10) |
| 19 | Noise-window clean verdict vs SC hits (fixed drain, eval boundary) | INTERFACE | `cocotb/noise_window_edge` (10 tests) | Open Risk #66 | ✅ done |
| 20 | `timing_ref` late bias quantified (never early, ≈0.6 sym high SNR, up to 4–5 low SNR) | ANALYSIS | `sc_timing_golden` + model | Open Risk #81 | ✅ characterised — system impact (SX1302 preamble tolerance) is open under #81 |
| 21 | Constrained-random back-to-back packets with random `sc_clr`/force/sync timing | DIFF | extend `sc_timing_golden` | coverage | ⬜ planned (after #14) |

### 2a. Directed closure order

1. Row #14: standalone bench reproducing #74; file the result in Open Risks;
   keep the bench in `SUITES_XFAIL` until the one-line RTL fix lands, then
   move it to core.
2. Row #13 alongside #14 (same bench, same `sc_clr` sweep).
3. Rows #5/#9: extend `sc_timing_golden` (longer runtime — consider a
   separate `sc_timing_golden_hi` suite).
4. Row #7: specification wording (no RTL change).
5. Row #21 + coverage.

---

## 3. Regression commands

```bash
# SGE job script (hqsub --project lora-mimo --cpus 2 --mem 8G)
export SUITES="sc_timing_golden sc_acc_overflow mcp_sc_settle sc_dbg sc_force_lock sc_ant_sel warmup_rearm array_sync noise_window_edge"
exec /foss/designs/cocotb/run_toplevel_regression_sge.sh
```

Single suite: `cocotb/run_sc_timing_golden_sge.sh`. The capture suites
(`trouper_capture`, `capture_two_packet`) need `SUITE_GROUPS=capture` and
the `$SHARED_DIR` capture mount.

**Last run:** full regression job 5845, 2026-10-10 (`SUITE_GROUPS=all`),
all listed suites pass.

---

## 4. Explicit non-goals and interface boundaries

- Antenna selection and the `del` delay line (`SC_ANT_SEL`, `del_rdy`) are
  `psram_buf_ctrl` behaviour.
- Single-antenna acquisition (no diversity at lock time) is a deferred
  architectural limitation (Open Risk #9), not a test gap.
- Detection probability vs SNR is a system/Python study
  (`sim/notebooks/12_sc_detector.ipynb`); this plan verifies exactness
  against the integer model, not sensitivity.
- SS timing of the TDM/eval engine is signoff (Open Risk #1).
