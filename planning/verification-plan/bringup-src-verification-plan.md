# Bring-up Sample Source (`bringup_src`) — Verification Plan

**DUT:** `src/debug/bringup_src.v` (no `rtl-test/rtl/` mirror), plus its
`trouper_top` integration: the qualified enable
(`BRINGUP_CTRL[0] && rx_hold && !packet_active`) and the absolute-priority
mux at the `sd_remod` input.

**Scope:** the four generator modes (zero, signed DC, fs/4 complex tone,
x⁹+x⁵+1 PRBS), the ±64 amplitude clamp, the self-owned 500 kS/s valid
cadence, reset/restart determinism, arming barriers and
`CFG_WR_REJECTED`, mux priority over `psram_silence` and
`REMOD_BACKOFF_SHIFT`, and debug-probe visibility.

**Inputs reviewed:** `planning/foundational-block-bringup-plan.md` (source of
TRPR-BRU-001..013; these IDs are not in the Chip Specification),
`planning/Traceability.md` §BRU, `planning/Open Risks.md` (BRINGUP_SRC P&R
entry), `planning/Register Map.md` (`BRINGUP_CTRL`/`AMPL`),
`formal/bringup_src_formal.sv` + `formal/bringup_src.sby`,
`cocotb/tests/test_bringup_src.py` (23 tests), `src/top/trouper_top.v`
(u_bringup_src and the remod-input mux), and the current RTL.

This is the block-level closure tracker for `bringup_src`. Re-modulator
behaviour on the injected stream is `sd_remod`'s; this plan only requires
that the stream reaches it intact.

---

## 1. Current methodology, and the path to constrained random

**Today:** functionally closed. 23 full-top cocotb tests cover every
TRPR-BRU `T` row, and a formal proof covers the amplitude clamp over all 256
`ampl` values plus the cadence. The only open item is the area/timing cost
measurement (TRPR-BRU-009). Its recorded ❌ ("does not route") is stale: the
current reference P&R builds include the block and route clean.

- **Full-top cocotb** — `cocotb/bringup_src` (23 tests): reset path,
  disabled-source non-perturbation (3000 cycles bit-identical), arming
  barriers, enable drop on `RX_HOLD` release, every mode incl. golden LFSR,
  clamp, restart, mux priority over backoff and silence, combiner
  out-of-path, 1-bit output signatures (DC density, tone), cadence, debug
  probe.
- **Formal** — `formal/bringup_src.sby` `prove` (k-induction, depth 40) and
  `cover` (depth 200): clamp (group A) and cadence (group C); both PASS on
  SGE job 5844 (2026-10-10).
- **Coverage gap** — no code coverage; the suite is directed (fixed
  stimulus).

The active order is:

1. Re-measure TRPR-BRU-009 against an identical build without the block, on
   the current canonical P&R config.
2. Optional code-coverage instrumentation.

### 1a. Coverage model

At minimum, collect:

- mode 0..3 × `ampl` bands {0, ±1..±63, ±64, beyond-clamp incl. 0x80};
- enable rise/fall relative to the internal cadence counter;
- `RX_HOLD` release and packet start while armed;
- mode/amplitude change while running.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test; **FORMAL** =
property proof; **ANALYSIS** = P&R measurement.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | Reset selects the normal path; `BRINGUP_CTRL`/`AMPL` reset to 0 | SPEC-SIM | `test_reset_selects_the_normal_path` | TRPR-BRU-001 | ✅ done |
| 2 | Disabled source is bit-invisible at `remod_in_*` | SPEC-SIM | `test_disabled_source_does_not_perturb_the_path` | TRPR-BRU-002 | ✅ done |
| 3 | Arming refused unless `RX_HOLD=1 && !PACKET_ACTIVE`; sets `CFG_WR_REJECTED`; level term holds if forced mid-packet | SPEC-SIM | `test_arming_is_refused_unless_rx_hold`, `test_arming_is_refused_during_a_live_packet`, `test_level_term_holds_if_the_bit_is_forced_during_a_packet` | TRPR-BRU-003 | ✅ done |
| 4 | Enable drops continuously on `RX_HOLD` release | SPEC-SIM | `test_enable_drops_when_rx_hold_is_released` | TRPR-BRU-004 | ✅ done |
| 5 | Each mode emits its stream; PRBS matches the golden LFSR sample for sample | SPEC-SIM | `test_zero_mode`, `test_dc_mode_polarity`, `test_tone_mode_is_a_quadrature_rotation`, `test_prbs_mode_switches_and_stays_bounded`, `test_prbs_matches_the_golden_lfsr` | TRPR-BRU-005 | ✅ done |
| 6 | Amplitude clamped to ±64 for all 256 `ampl` values | SPEC-SIM + FORMAL | `test_amplitude_is_clamped`; formal group A | TRPR-BRU-006 | ✅ done (formal PASS job 5844) |
| 7 | Deterministic restart after reset in every mode | SPEC-SIM | `test_deterministic_restart_after_reset` | TRPR-BRU-007 | ✅ done |
| 8 | Samples reach `sd_remod` unmodified; combiner out of path; priority over backoff and `psram_silence` | SPEC-SIM | `test_samples_reach_the_remod_input`, `test_combiner_is_out_of_the_path_while_armed`, `test_armed_source_overrides_the_backoff_shift`, `test_armed_source_overrides_psram_silence` | TRPR-BRU-008 | ✅ done |
| 9 | Area and SS/hold cost vs an identical build without the block | ANALYSIS | P&R A/B on the current canonical config | TRPR-BRU-009 | 🟨 stale — recorded ❌ (DRT-0073, jobs 5425/5436) predates the CTS change; current builds that include the block route clean (reference job 5842). The A/B cost delta has not been re-measured |
| 10 | 1-bit output signatures: DC density = level/127; tone after R=64 decimation | SPEC-SIM | `test_dc_signature_at_the_remod_output`, `test_tone_signature_at_the_remod_output` | TRPR-BRU-010 | ✅ done |
| 11 | Board bring-up procedure documented | ANALYSIS | `planning/Register Map.md` | TRPR-BRU-011 | ✅ done |
| 12 | Cadence exactly one valid per 64 clocks, no drift | SPEC-SIM + FORMAL | `test_sample_cadence_is_500ksps`; formal group C | TRPR-BRU-012 | ✅ done |
| 13 | Debug probe COMB group shows the injected sample | SPEC-SIM | `test_debug_probe_comb_group_shows_the_injected_sample` | TRPR-BRU-013 | ✅ done |

### 2a. Directed closure order

1. Row #9: run the A/B P&R pair (with/without `bringup_src`) on the current
   canonical config, record area, SS WNS/TNS and hold. Then update
   TRPR-BRU-009 and the Open Risks entry.

---

## 3. Regression commands

```bash
# SGE job script (hqsub --project lora-mimo --cpus 2 --mem 8G)
export SUITES="bringup_src"
exec /foss/designs/cocotb/run_toplevel_regression_sge.sh

# formal (hqsub --project lora-mimo --cpus 4 --mem 4G); copies formal/ + src/
# to $RUN_DIR because /foss/designs is read-only -- see formal/run_formal_both.sh
cd formal && sby -f bringup_src.sby
```

**Last run:** `bringup_src` 23/23 in full regression job 5845; formal
`bringup_src_prove` and `_cover` PASS on job 5844 (2026-10-10).

---

## 4. Explicit non-goals and interface boundaries

- Re-modulator fidelity on the injected stream is `sd_remod`'s plan.
- `BRINGUP_CTRL`/`AMPL` register decode and `CFG_WR_REJECTED` storage are
  `reg_bank`'s; this plan checks the behaviour they produce.
- Combiner-side injection (the superseded insertion point) is out of scope.
