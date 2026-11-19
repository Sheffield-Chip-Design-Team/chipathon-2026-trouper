# MRC Combiner (`mrc_combiner`) — Verification Plan

**DUT:** `src/combiner/mrc_combiner.v`. The `rtl-test/rtl/mrc_combiner.v` copy
is **stale** (differs from `src/`); legacy `rtl-test/tb/tb_mrc_combiner.v`,
`tb_mrc_fw_rand.v`, `tb_mrc_fw_precision.v` build from `rtl-test/` Makefile
targets outside the cocotb regression.

**Scope:** the serialised 2-multiplier complex MAC (`ŷ = Σ w_k·x_k`), the
17-bit product / 19-bit accumulator, the combined `>>> (8 − pgs)` shift and
int8 saturation, input latching at `x_valid`, the bypass path (`mode`,
`W_valid`, `bypass_ant`), the burst-aligned `use_mrc` flag, the 31-clock paced
burst inside the 64-clock window, and the live W-shadow consumption contract.

**Inputs reviewed:** `planning/Trouper Chip Specification.md`
(TRPR-MRC-001..011), `planning/Traceability.md` §MRC, `planning/Open Risks.md`
(#13, #24, #65), `planning/Register Map.md` (0x0F, 0x1E, 0x30–0x3F),
`sim/models/receiver.py` (`nonfft_combine_rtl_int8w`), `src/top/trouper_top.v`
(u_comb and the W/bypass wiring), the cocotb tests named in §2, and the
current RTL.

This is the block-level closure tracker for `mrc_combiner`. W-shadow
write-locking and `WGT_CTRL` live in `reg_bank`; W_VALID/mode/antenna
latching per packet lives in `packet_ctrl_fsm`; "lowest-enabled antenna"
selection is computed in `trouper_top`.

---

## 1. Current methodology, and the path to constrained random

**Today:** the standalone block is bit-exact against the integer contract
under full-range random inputs at every `pgs`, at the arithmetic endpoints,
and in all bypass configurations, with input-latch isolation and one-output-
per-strobe checked; the system path is bit-exact against the numpy model on
real captures. Open: two spec wording conflicts (accumulator width, weight
format) and RTL-level SNR-gain evidence.

- **Constrained-random differential (cocotb, standalone)** —
  `cocotb/mrc_golden` (4 tests): 320 random vectors cycling pgs 0..7 (≥20
  rail hits required), 64 vectors cross-checked against
  `nonfft_combine_rtl_int8w`, 7 arithmetic corners × 8 pgs, bypass for
  mode/W_valid × 4 antennas; `x_*` scrambled every non-strobe clock.
  Mutation-checked (ant0 Q-sign, shift off-by-one, SGE job 5854).
- **MCP settle (standalone)** — `cocotb/mcp_mrc_settle`.
- **Full-top** — `weight_gen_spi_flow` (bit-exact vs numpy on real capture),
  `mrc_absent_branch`, `bypass_e2e`, `bypass_antenna`, `bypass_backoff`,
  `w_valid_split`, `w_shadow_lock`, `replay_delay` (mid-stream upgrade).
- **Coverage gap** — no code/functional coverage; W is held constant within
  a burst by construction of the bench (the contract), so a W change
  mid-burst is untested (it is illegal while W_VALID=1 — see row #11).

The active order is:

1. Resolve the spec wording conflicts (rows #3, #9).
2. Add row #11 (W_valid/mode toggling at burst boundaries) and coverage.
3. Optional RTL-level SNR-gain measurement (row #12).

### 1a. Coverage model

At minimum, collect:

- pgs 0..7 × (output in range / clipped high / clipped low) × I/Q;
- accumulator sign and the ±2¹⁷ endpoint region;
- mode ∈ {0,1} × W_valid ∈ {0,1} × bypass_ant 0..3;
- `x_valid` arriving while a burst is in progress (must be ignored — the FSM
  only samples in state 0);
- W_valid / mode changes between consecutive strobes.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test; **EDGE-SIM** =
robustness case from RTL review; **DIFF** = bit-exact differential;
**INTERFACE** = owned by an adjacent block.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | ŷ = Σ w_k·x_k (plain complex MAC; firmware pre-conjugates) exact for random full-range int8 x, W | DIFF | `cocotb/mrc_golden` → `test_mrc_random_bit_exact` | TRPR-MRC-001 | ✅ done (job 5851) |
| 2 | RTL == `nonfft_combine_rtl_int8w` (system model) at weight peak 120 | DIFF | `test_mrc_model_crosscheck`; `weight_gen_spi_flow` (real capture) | TRPR-MRC-001/010 | ✅ done |
| 3 | Product/accumulator endpoints: all −128 → acc_q = +131072; mixed rails; −1 >>> s = −1 | DIFF | `test_mrc_arithmetic_extremes` | TRPR-MRC-002 | ✅ done (spec re-worded to 17-bit product / 19-bit acc, 2026-10-10) |
| 4 | `>>> (8 − pgs)` then int8 saturation, every pgs, both rails | DIFF | `test_mrc_random_bit_exact` (rail hits asserted) | TRPR-MRC-002/007 | ✅ done |
| 5 | One `y_valid` per `x_valid`, inside the 64-clock window | SPEC-SIM | all `mrc_golden` tests | TRPR-MRC-003 | ✅ done |
| 6 | Input latch: `x_*` changes after the strobe do not affect the result | EDGE-SIM | all `mrc_golden` tests (scramble every clock) | RTL review (live/replay mux flip) | ✅ done |
| 7 | Bypass: mode=1 or W_valid=0 → y = latched x[bypass_ant], `use_mrc`=0 | SPEC-SIM | `test_bypass_routing` | TRPR-MRC-005, TRPR-PCF-011 | ✅ done |
| 8 | Lowest-enabled-antenna selection reaches `bypass_ant` | INTERFACE | `cocotb/bypass_antenna` (4 tests), `bypass_e2e` | TRPR-MRC-005 (top) | ✅ done |
| 9 | Weight format: high byte of each 16-bit shadow field as int8 Q0.7 | INTERFACE | `test_weight_gen_spi_flow.py`, `w_shadow_lock` | TRPR-MRC-006 | ✅ behaviour verified; Traceability still flags the int16 Q1.15 wording (Open Risk #24) ⚠️ spec wording |
| 10 | Live W bank consumed only under W_VALID; writes rejected while valid (`W_WR_REJECTED`) | INTERFACE | `cocotb/w_shadow_lock`, `weight_gen_spi_flow` | TRPR-MRC-004/011 | ✅ done |
| 11 | W_valid / mode / bypass_ant changing between consecutive strobes: each burst uses the values sampled at its own state-0 (`use_mrc_r`) | EDGE-SIM | extend `mrc_golden` | Open Risk #65 burst alignment | 🟨 partial — `replay_delay` covers the mid-stream bypass→MRC upgrade at system level; no cycle-targeted standalone test |
| 12 | Post-combining SNR gain ≥ 5 dB on flat equal-power branches | SPEC-SIM | Python `sim/tests/run_ber.py`; optional RTL measurement via `mrc_golden` | TRPR-MRC-008 | ANALYSIS/Python ✅; RTL ⬜ optional |
| 13 | AGC keeps branches ≤ 90 counts | INTERFACE | — | TRPR-MRC-009 | n/a at RTL (AGC is external, `P`) |
| 14 | MAC consumed only after the MCP settle; reset mid-burst | EDGE-SIM | `cocotb/mcp_mrc_settle` | Open Risk #43 | ✅ done |
| 15 | Dead/absent branches (x=0) combine correctly | SPEC-SIM | `cocotb/mrc_absent_branch` (2 tests) | robustness | ✅ done |

### 2a. Directed closure order

1. Row #9: specification edit only (int8 high-byte weights) — closes Open
   Risk #24's MRC half.
2. Row #11: add a burst-boundary toggling test to `mrc_golden`.
3. Coverage instrumentation; row #12 optional.

---

## 3. Regression commands

```bash
# SGE job script (hqsub --project lora-mimo --cpus 2 --mem 8G)
export SUITES="mrc_golden mcp_mrc_settle bypass_antenna bypass_e2e bypass_backoff w_valid_split w_shadow_lock replay_delay"
exec /foss/designs/cocotb/run_toplevel_regression_sge.sh
```

`weight_gen_spi_flow` and `mrc_absent_branch` run under
`SUITE_GROUPS=capture`. `mrc_golden` imports `sim/models/receiver.py`.

**Last run:** `mrc_golden` 4/4, SGE job 5851, 2026-10-10; the others passed
in the full regression job 5845.

---

## 4. Explicit non-goals and interface boundaries

- Weight computation and conjugation are firmware.
- W-shadow storage, write-lock and `WGT_CTRL` are `reg_bank`.
- Per-packet mode/antenna latching and W_VALID lifetime are
  `packet_ctrl_fsm`; lowest-enabled-antenna selection is `trouper_top`.
- `REMOD_BACKOFF_SHIFT` applied to MRC output is `trouper_top`/`sd_remod`
  (`remod_backoff`, `bypass_backoff`).
