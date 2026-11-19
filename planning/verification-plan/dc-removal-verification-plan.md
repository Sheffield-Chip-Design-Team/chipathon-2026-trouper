# DC Removal (`dc_removal`) — Verification Plan

**DUT:** `src/frontend/dc_removal.v` (`dc_removal` wrapper + 8 ×
`dc_removal_chan`; byte-identical mirror at `rtl-test/rtl/dc_removal.v`)

**Scope:** the per-channel first-order IIR DC blocker (α = 2⁻⁵, 13-bit Q8.5
accumulator, full-difference update, pre-update-estimate output), the
`sample_valid` gating, the one-cycle `sample_out_valid` delay, reset, and the
int8 output range on transients.

**Inputs reviewed:** `planning/Trouper Chip Specification.md`
(TRPR-DCR-001..015), `planning/Traceability.md` §DCR, `planning/Open Risks.md`
(#10, #75 closed), `sim/models/dc_removal.py` (`DCRemovalRTL`),
`src/top/trouper_top.v` (u_dcr), `cocotb/tests/test_dc_removal.py`,
`cocotb/tests/test_startup.py`, and the current RTL.

This is the block-level closure tracker for `dc_removal`. The SC hold-off
after reset (TRPR-DCR-015) is provided by `psram_buf_ctrl`'s delay-line
warm-up and is tracked there and in `test_startup.py`.

---

## 1. Current methodology, and the path to constrained random

**Today:** directed settling tests plus a bit-exact `DCRemovalRTL` differential
with 8 distinct streams, irregular `sample_valid` gaps and output-valid timing.
The int8 output saturates (Open Risk #75 fixed 2026-10-10). Remaining: a
mid-stream reset check, the full +1..+31 deadband sweep, and coverage.

- **Directed standalone (cocotb)** — `cocotb/dc_removal`: DC ∈
  {±127, ±64, ±8, ±1} → residual 0 after 256 samples on all 8 paths
  (TRPR-DCR-006); ±127 from reset → |residual| ≤ 13 after 74 samples
  (TRPR-DCR-013).
- **System use** — every `trouper_top` suite passes data through the block
  and times downstream from `sample_out_valid`.
- **Coverage gap** — no code/functional coverage; no random stimulus; no
  model differential.

The active order is:

1. Directed edge cases (rows #3/#6).
2. Coverage instrumentation, then constrained-random (row #14).

### 1a. Coverage model

At minimum, collect:

- `diff` (9-bit) at each sign and at the int8 overflow boundary (|diff| > 127);
- `dc_est_acc` sign and magnitude band (incl. near ±4064);
- `sample_valid` gaps of 1, 63 (production) and irregular lengths;
- DC step sizes and signs, per path;
- reset asserted mid-stream with a non-zero accumulator.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test; **EDGE-SIM** =
robustness case from RTL review; **DIFF** = bit-exact differential;
**ANALYSIS/INSPECTION** = satisfied by analysis or construction.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | Residual = 0 on all 8 paths after 256 samples of constant DC (±1..±127) | SPEC-SIM | `cocotb/dc_removal` → `test_constant_dc_is_zero_within_256_samples` | TRPR-DCR-006 | ✅ done |
| 2 | Full-scale ±127 DC from reset: \|residual\| ≤ 13 after 74 samples | SPEC-SIM | `test_reset_dc_settles_by_one_time_constant` | TRPR-DCR-013 | ✅ done |
| 3 | Reset clears all 8 accumulators and outputs | SPEC-SIM | new: reset mid-stream with non-zero acc, then output == input on first valid | TRPR-DCR-012 | 🟨 partial — only implied by every suite resetting first |
| 4 | Bit-exact vs `DCRemovalRTL` for random in-range signals + DC (no transient overflow) | DIFF | `test_bit_exact_vs_model_distinct_paths` | TRPR-DCR-002/003 | ✅ done (job 5858) |
| 5 | Per-path independence: 8 distinct DC/signal streams, each matches its own model | DIFF | `test_bit_exact_vs_model_distinct_paths` | TRPR-DCR-001/009 | ✅ done (job 5858) |
| 6 | Full-difference update has no deadband: DC = +1..+31 converges (residual 0) | SPEC-SIM | covered for +1/+8 by row #1; extend to the full 1..31 band | TRPR-DCR-003 | 🟨 partial |
| 7 | Accumulator and output hold when `sample_valid`=0 (64-clock production gaps and irregular gaps) | EDGE-SIM | `test_bit_exact_vs_model_distinct_paths` | TRPR-DCR-001 | ✅ done (job 5858) — gaps of 1/3/62 clocks, output held |
| 8 | `sample_out_valid` = `sample_valid` delayed exactly 1 clock; output data aligned with it | SPEC-SIM | `test_bit_exact_vs_model_distinct_paths` | TRPR-DCR-011 | ✅ done (job 5858) |
| 9 | Transient overflow: input 127 with dc_est = −20 → RTL gives −109 (wrap); spec TRPR-DCR-007 documents "no saturation, gated on AFE DC data"; Open Risk #75 and `DCRemovalRTL` clip to +127 | EDGE-SIM | `test_transient_saturates_not_wraps` + row #4 differential (overflow diffs asserted exercised) | Open Risk #75, TRPR-DCR-007 | ✅ done 2026-10-10 — RTL saturates; pre-fix RTL fails with −109 (job 5859); Open Risk #75 closed |
| 10 | Max accumulator 4064 at sustained +127, no 13-bit overflow; sustained −128 likewise | SPEC-SIM | new (cheap, also corroborates the `A` row) | TRPR-DCR-008 | ANALYSIS ✅; sim ⬜ optional |
| 11 | τ = 32 samples / AC droop < 0.1 dB in band | ANALYSIS | spec arithmetic | TRPR-DCR-005/010 | ✅ (analysis) |
| 12 | No bypass port | INSPECTION | — | TRPR-DCR-014 | ✅ (by construction) |
| 13 | SC hold-off ≥ 64 samples after reset | INTERFACE | `cocotb/tests/test_startup.py::test_sc_correlator_idle_until_del_rdy` | TRPR-DCR-015 (owned by `psram_buf_ctrl`) | ✅ done |
| 14 | Constrained-random DC steps + LoRa-like signal at AGC levels, model differential | DIFF | extend row #4 | coverage | ⬜ planned (after #9) |

### 2a. Directed closure order

1. Rows #3/#6 directed edge cases.
2. Row #14 + coverage.

Stale comment to fix while there: `trouper_top.v` (Stage 2 banner) still says
"α=2^{-4}, 12-bit Q8.4"; the RTL is α=2⁻⁵, 13-bit Q8.5.

---

## 3. Regression commands

```bash
# SGE job script (hqsub --project lora-mimo --cpus 2 --mem 8G)
export SUITES="dc_removal"
exec /foss/designs/cocotb/run_toplevel_regression_sge.sh
```

Or in the container: `(cd cocotb/dc_removal && make)`. `test_startup.py`
runs inside the `trouper_top` suite.

**Last run:** full core regression job 5845, 2026-10-10 — `dc_removal` 2/2.

---

## 4. Explicit non-goals and interface boundaries

- The SC startup hold-off (TRPR-DCR-015) is a `psram_buf_ctrl` delay-line
  property; this block only has to settle within it.
- The decimator's int8 output range and saturation are upstream
  (`sd_decimator_poly` plan).
- Real AFE DC levels (the input to the row #9 decision) come from the AFE
  PCB characterisation, not RTL simulation.
