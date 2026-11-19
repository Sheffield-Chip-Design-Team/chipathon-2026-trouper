# ΣΔ Decimator (`sd_decimator_poly`) — Verification Plan

**DUT:** `src/decimator/sd_decimator_poly.v` (byte-identical mirror at
`rtl-test/rtl/sd_decimator_poly.v`; frozen pre-polyphase reference
`rtl-test/tb/sd_decimator_poly_ref.v`)

**Scope:** the 4-branch TDM 1-bit → int8 decimator — CIC-3 R=16 with 14-bit
modulo integrators, polyphase HB1 (11-tap) and HB2 (15-tap) half-band ÷2
stages, int8 saturation at each stage output, the paced (MAC_WAIT=2) HB MAC
bursts, and the packed `iq_out_i/q` + `iq_valid` output contract consumed by
`dc_removal`.

**Inputs reviewed:** `planning/Trouper Chip Specification.md` (TRPR-DEC-001..009),
`planning/Traceability.md` §DEC, `planning/Open Risks.md` (#1 SS closure, #43
MCP audit), `planning/decimator-hb-migration-impact-plan.md`,
`planning/decimator-hb-redesign.md`, `planning/decimator-hb-area-reduction.md`,
`sim/models/decimator.py`, `src/top/trouper_top.v` (u_dec instantiation),
`cocotb/tests/test_decimator_golden.py`, `cocotb/tests/test_mcp_decimator_settle.py`,
`rtl-test/tb/tb_decimator_poly_equiv.v`, and the current RTL.

This is the block-level closure tracker for `sd_decimator_poly`. The IQ input
pad sampling and array synchronisation in front of it belong to `trouper_top`
(`cocotb/array_sync`) and are out of scope.

---

## 1. Current methodology, and the path to constrained random

**Today:** the datapath is bit-exact against the Python model on all 8 TDM
streams after FIR warm-up, saturation and the R=64 cadence are directly
checked, and the paced-MAC hold protocol is proven by a settle monitor. The
open gaps are a current-RTL SQNR measurement (TRPR-DEC-003), the post-reset
warm-up transient, and simulation corroboration of the analysis-only filter
requirements.

- **Bit-exact differential (cocotb, standalone)** — `cocotb/decimator_golden`
  drives the DUT directly with 8 independent first-order ΣΔ tone streams and
  compares every output after `WARMUP=12` against
  `sim/models/decimator.py` with a pinned alignment (`LEAD_BITS=3`, the
  registered-integrator lag; a change is a latency change and fails). Also
  full-scale DC (+124/−125 closed form), a near-full-scale tone, random bits,
  and the `iq_valid` spacing. Mutation-checked: an HB2 coefficient ±1 and an
  I/Q output swap each fail 2/3 tests (SGE job 5850).
- **MCP settle proof (cocotb, standalone)** — `cocotb/mcp_decimator_settle`
  asserts every cycle that `hb1_hold_*` / `iq_out_*` change only on the edge
  after `hb*_wait == MAC_WAIT`, plus reset mid-burst re-arm.
- **System use** — every `trouper_top` suite consumes the decimator output;
  timing math assumes 64 clocks/sample, so a cadence error fails lock.
- **Legacy differential** — `rtl-test/tb/tb_decimator_poly_equiv.v` compares
  against the frozen `sd_decimator_poly_ref.v`, but has **no Makefile target
  or runner**; treat it as historical, not current evidence.
- **Coverage gap** — no code coverage is collected; stimulus is directed
  (fixed seeds), not constrained-random; the first `WARMUP` outputs after
  reset are not compared.

The active order is:

1. Add the current-RTL SQNR measurement (row #8) — the one `T` requirement
   still resting on pre-migration evidence.
2. Close the warm-up transient (row #6) by modelling reset state explicitly.
3. Instrument Verilator line/toggle coverage on `decimator_golden`.
4. Randomize tone frequency/amplitude/phase per stream across seeds and
   sweep through the stopband (rows #9/#10).

### 1a. Coverage model

At minimum, collect:

- `cic_count` phase at reset release × first input bit;
- `hb1_phase` / `hb2_phase` at every output (both polyphase branches used);
- int8 clip hit at CIC, HB1 and HB2 outputs, each sign;
- CIC integrator wrap events (each of 3 integrators, each sign) per stream;
- HB burst overlap: a CIC insert landing while an HB1 burst is mid-stream
  (the `h1bc_snap` path);
- stream index × MAC_WAIT phase at result store.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed numbered-requirement test; **EDGE-SIM** =
robustness case from RTL review; **DIFF** = bit-exact differential against a
reference model; **ANALYSIS** = satisfied by analysis.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | 1-bit I/Q in → signed int8 out, every stream bit-exact vs model after warm-up | DIFF | `cocotb/decimator_golden` → `test_bit_exact_tones_all_streams` | TRPR-DEC-001 | ✅ done (job 5849) |
| 2 | CIC-3 R=16 → HB1 → HB2 chain bit-true, incl. coefficient/rounding | DIFF | same; coefficient mutant fails (job 5850) | TRPR-DEC-002 | ✅ done |
| 3 | Per-stream independence: 8 distinct stimuli each match their own model run | DIFF | same; I/Q swap mutant fails | TRPR-DEC-004 | ✅ done |
| 4 | `iq_valid` = single-cycle `4'hF` exactly every 64 clocks | SPEC-SIM | `test_output_rate_r64` | TRPR-DEC-006 | ✅ done |
| 5 | Full-scale DC: CIC/HB1 clip at ±127/−128, HB2 settles to +124/−125; 10240-clock DC run forces 14-bit integrator wrap and the output stays exact (modulo cancellation) | DIFF | `test_bit_exact_saturation_and_dc` | TRPR-DEC-001, TRPR-DEC-005 (sim corroboration of an `A` requirement) | ✅ done |
| 6 | Post-reset warm-up: outputs 0..11 match a model seeded with the RTL reset state (zero integrators/delay lines, `cic_count=0`, both `hb*_phase=0`) | DIFF | extend `decimator_golden` | reset contract (no spec row) | ⬜ new |
| 7 | HB MAC results consumed only after `MAC_WAIT` settle; reset mid-burst re-arms cleanly | EDGE-SIM | `cocotb/mcp_decimator_settle` | Open Risk #43 (MCP honesty) | ✅ done |
| 8 | SQNR ≥ 30 dB at R=64 for a −3 dBFS tone through the current RTL (SX1257-representative modulator, `sim/models/sx1257_adc_ref.py`) | SPEC-SIM | new test in `decimator_golden` | TRPR-DEC-003 | ⬜ new — current evidence is the pre-migration `tb_sqnr.v` + migration-plan Python analysis |
| 9 | Stopband: tones above 500 kHz attenuated > 40 dB at the output (RTL tone sweep) | SPEC-SIM | new sweep in `decimator_golden` | TRPR-DEC-007 | ANALYSIS ✅ (migration plan); RTL sweep ⬜ optional |
| 10 | Passband droop ≤ 0.5 dB to 125 kHz (RTL tone sweep) | SPEC-SIM | new sweep | TRPR-DEC-009 | ANALYSIS ✅ (`sim/tests/test_cfo_droop.py`); RTL sweep ⬜ optional |
| 11 | `bw_sel` does not change decimator timing (R fixed) | INTERFACE | `cocotb/trouper_top` SF/BW sweep | TRPR-DEC-008 | ✅ done (structural: no BW input port) |
| 12 | HB1 centre-tap snapshot: a phase-B CIC insert during a paced HB1 burst does not corrupt later streams | EDGE-SIM | covered implicitly by #1 (every burst overlaps an insert at R=64); add a coverage point | RTL review (`h1bc_snap_*`) | 🟨 partial — exercised every burst, not separately asserted |
| 13 | Randomized multi-seed tone/amplitude/phase regression to close §1a | DIFF | extend `decimator_golden` | coverage | ⬜ planned |

### 2a. Directed closure order

1. Row #8: generate the SX1257-model bitstream for a −3 dBFS tone, run it
   through the RTL, and compute SQNR in the decimated band against the ideal
   tone; assert ≥ 30 dB.
2. Row #6: add a reset-state-seeded model path (prepend nothing, model
   `LEAD_BITS` as zero-valued integrator inputs) and compare from output 0.
3. Rows #9/#10: optional RTL sweeps; keep ANALYSIS as the requirement's
   closure method.
4. Row #13 + coverage instrumentation.

---

## 3. Regression commands

Run on the homelab SGE (chipathon26 image) through the unified runner; the
suites are in `SUITES_CORE`:

```bash
# from a job script submitted with: hqsub --project lora-mimo --cpus 2 --mem 8G
export SUITES="decimator_golden mcp_decimator_settle"
exec /foss/designs/cocotb/run_toplevel_regression_sge.sh
```

Or directly in the container: `(cd cocotb/decimator_golden && make)`.
Both suites need `sim/` and `cocotb/tests/` synced with `src/` on NFS
(`decimator_golden` imports `sim/models/decimator.py` and
`cocotb/tests/iq_capture.py`).

**Last run:** SGE job 5849, 2026-10-10 — `decimator_golden` 3/3; full core
regression (incl. `mcp_decimator_settle`) clean on job 5845.

---

## 4. Explicit non-goals and interface boundaries

- IQ pad sampling, negedge capture and the 4-chip array synchronisation
  (`IQ_DATA_I/Q` → `iq_in_*`) belong to `trouper_top` / `cocotb/array_sync`.
- SS-corner timing closure of the HB MAC cones is a signoff item (Open
  Risk #1); RTL simulation at 32 MHz does not prove it. Row #7 proves only
  that the RTL honours the SDC's multicycle relaxation.
- The ΣΔ modulator in the SX1257 is external; tests use model bitstreams.
- DC offset handling is `dc_removal`'s job; the decimator passes DC.
