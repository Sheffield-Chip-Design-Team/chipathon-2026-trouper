# `rtl-test` trial synthesis

This directory contains trial synthesis and P&R collateral for the standalone
`trouper_top` top level, plus archived legacy collateral for the deprecated
`mimo_rx_top` compatibility wrapper.

## Notes

- [Trouper top P&R characterization — 2026-06-14](./trouper_top_pnr_2026-06-14.md)
- [Trouper top P&R characterization — 2026-06-11](../characterization/trouper_top_pnr_2026-06-11.md)

## What this flow does

- New work should target `trouper_top` only.
- [`trouper_top.v`](./rtl/trouper_top.v) is the canonical hardened-macro RTL.
- [`mimo_rx_top.v`](./rtl/mimo_rx_top.v) is deprecated and retained only as a
  legacy compatibility wrapper for archived experiments.
- Active implementation collateral lives under [`ol_trouper_top/`](./ol_trouper_top/).
- Legacy wrapper collateral under [`ol_mimo_rx_top/`](./ol_mimo_rx_top/) is archived only.
- The active `trouper_top` boundary is DSP-only with no embedded PicoRV32 or on-chip AHB-Lite control fabric.
- Host control still enters through the embedded `spi_slave` plus the `GRP_*` register-bus interface in [`trouper_top.v`](./rtl/trouper_top.v).
- Recent area cuts removed the dead `W_k` path from `training_acc` and removed the standalone `noise_est` block in favour of `training_acc` noise-mode windows plus SC-contamination gating.

## Prerequisites

- Docker installed locally.
- OSIC image available locally. For chipathon work, use `hpretl/iic-osic-tools:chipathon26`.

## Run

From the repo root:

```bash
bash rtl-test/scripts/run_synth_gf180_docker.sh
```

Or from inside `rtl-test`:

```bash
./scripts/run_synth_gf180_docker.sh
```

This script is a lightweight trial flow. Treat any `mimo_rx_top` artifacts as
archival only; active implementation work should be driven from `trouper_top`
and `ol_trouper_top`.

## Outputs

The run writes:

- `rtl-test/out/netlist_<top>.v` (for example `netlist_trouper_top.v`; any
  `netlist_mimo_rx_top.v` output is legacy-only)
- `rtl-test/out/stat.txt`

## Optional override

```bash
OSIC_IMAGE=hpretl/iic-osic-tools:chipathon26 bash rtl-test/scripts/run_synth_gf180_docker.sh
```

---

## Simulation testbenches (`tb/`)

All simulation targets run from `rtl-test/` via `make`. The simulator is **iverilog** for legacy targets and **Verilator** for the primary DSP chain.

### Primary DSP chain testbenches

| Make target | Testbench | Description |
|---|---|---|
| `sim_dsp_chain` | `tb_dsp_chain.v` | Historical fixed single-case end-to-end test for the older HW-`weight_gen` integration path. Useful as legacy coverage, but not representative of the current active software-weighted `trouper_top`. |
| `sim_dsp_chain_rand` | `tb_dsp_chain_rand.v` | 20-case randomised test: varies per-branch amplitude A_k ∈ [10,60] and phase offset, runs the full pipeline with firmware eigenvector MRC weight computation. Pass criteria: SC lock, training done, non-zero weights, y_i ∈ [−127,127]. |

#### `tb_dsp_chain_rand.v` — design intent

The randomised testbench exercises the eigenvector MRC path that the actual PicoRV32 firmware runs. After `training_done`, it:

1. Reads the 4×4 Hermitian correlation matrix from RTL (`Zpair_i/q0–5`, `Zdiag_0–3`).
2. Normalises to int12 and runs 8 iterations of power iteration to find the dominant eigenvector.
3. Converts the eigenvector to Q1.15 conjugate weights with a post-gain-shift (`pgs`) so the combiner output stays in range.
4. Commits the weights to the `mrc_combiner` and checks `y_valid`.

A clean run prints `Results: 20 PASSED, 0 FAILED`.

### Other testbenches

| Make target | Testbench | Description |
|---|---|---|
| `sim_dsp_chain_real_probe` | `tb_dsp_chain_real_probe.v` | Drives the chain with real captured IQ data through the ΣΔ decimator. |
| `sim_sqnr` | `tb_sqnr_4ch.v` | Measures SQNR across all four CIC decimator branches. |
| `sim_dsp` | `tb_dsp.v` | Legacy energy / noise-floor testbench (iverilog). |

---

## Bug fixed: `training_acc.v` multiplier pipeline (2026-06-14)

Discovered during `tb_dsp_chain_rand` development. `Zdiag_0` (branch 0 power) was inflated by ~300× regardless of actual signal amplitude, causing branch 0 to always appear dominant in the eigenvector.

**Root cause:** `op_a` and `op_b` were registered (1-cycle delay) before feeding into `mul_out <= op_a * op_b` (a second register). This created a 2-cycle multiplier pipeline. However, `acc_pair` (which controls which accumulator receives `mul_out`) only lagged `tdm_pair` by 1 cycle. At diagonal sub-step 0, `p_latch` captured the cross-pair product from the previous TDM slot (often negative) instead of I_k². Zero-extending a negative 16-bit value to 32 bits inflated `Zdiag_0`.

**Fix:** Made `op_a` and `op_b` combinational wires. `mul_out` now has 1-cycle latency, matching `acc_pair`. The diagonal accumulation correctly latches I_k² then adds Q_k².

**Verification:** `make sim_dsp_chain_rand` — 20 randomised cases, all PASS. `Zdiag` values now correctly order branches by actual signal power.
