# `rtl-test` trial synthesis

This directory contains a trial Yosys synthesis flow for `mimo_rx_top` against the GF180MCU standard-cell library inside the OSIC Docker image.

## What this flow does

- Synthesises `mimo_rx_top` with Yosys.
- Blackboxes `picorv32` integration via [`picorv32_stub.v`](./picorv32_stub.v) and [`picorv32_wrap_bb.v`](./picorv32_wrap_bb.v).
- Leaves the two frontend SRAMs in [`mimo_rx_top.v`](./mimo_rx_top.v) as behavioural arrays, so the reported area is an over-estimate until they are replaced with GF180 SRAM macros.

## Prerequisites

- Docker installed locally.
- OSIC image available locally, defaulting to `hpretl/iic-osic-tools:2026.04`.

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

- `rtl-test/out/netlist_mimo_rx_top.v`
- `rtl-test/out/stat.txt`

## Optional override

```bash
OSIC_IMAGE=hpretl/iic-osic-tools:latest bash rtl-test/run_synth_gf180_docker.sh
```
