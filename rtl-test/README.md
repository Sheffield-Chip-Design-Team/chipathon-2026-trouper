# `rtl-test` trial synthesis

This directory contains trial synthesis and P&R collateral for the standalone
`trouper_top` top level, plus archived legacy collateral for the deprecated
`mimo_rx_top` compatibility wrapper.

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
