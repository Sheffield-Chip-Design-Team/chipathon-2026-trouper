# `rtl-test` trial synthesis

This directory contains trial Yosys synthesis flows for the standalone `trouper_top` top level and the legacy `mimo_rx_top` compatibility wrapper against the GF180MCU standard-cell library inside the OSIC Docker image.

## What this flow does

- Synthesises the top-level RTL with Yosys. New work should target `trouper_top`; `mimo_rx_top` remains as a compatibility wrapper.
- The standalone implementation now lives in [`trouper_top.v`](./rtl/trouper_top.v); [`mimo_rx_top.v`](./rtl/mimo_rx_top.v) is a thin legacy wrapper.
- The active `trouper_top` boundary is radio-only: no embedded PicoRV32, SPI slave, or AHB-Lite control fabric. Control enters through the external `CFG_*` byte interface.
- Recent area cuts removed the dead `W_k` path from `training_acc` and removed the standalone `noise_est` block in favour of `training_acc` noise-mode windows plus SC-contamination gating.

## Prerequisites

- Docker installed locally.
- OSIC image available locally. For chipathon work, use `hpretl/iic-osic-tools:chipathon26`.

## Run

From the repo root:

```bash
bash rtl-test/run_synth_gf180_docker.sh
```

Or from inside `rtl-test`:

```bash
./run_synth_gf180_docker.sh
```

## Outputs

The run writes:

- `rtl-test/out/netlist_<top>.v` (for example `netlist_trouper_top.v` or legacy `netlist_mimo_rx_top.v`)
- `rtl-test/out/stat.txt`

## Optional override

```bash
OSIC_IMAGE=hpretl/iic-osic-tools:chipathon26 bash rtl-test/run_synth_gf180_docker.sh
```
