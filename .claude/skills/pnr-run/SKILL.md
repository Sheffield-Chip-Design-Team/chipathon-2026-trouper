---
name: pnr-run
description: Use when running or troubleshooting LibreLane/OpenLane place-and-route or synthesis for a block in rtl-test/ (FD or AS standard cells), or when reading post-PNR timing (WNS) or Magic DRC results. Triggers on "run P&R", "run librelane", "synth this block", "check WNS", "DRC errors", "gf180mcu_fd_sc_mcu7t5v0", "gf180mcu_as_sc_mcu7t3v3".
---

# Running LibreLane (P&R)

Use the `hpretl/iic-osic-tools:chipathon26` Docker image. LibreLane is at `/foss/tools/bin/librelane` inside the container. Do **not** use `hpretl/iic-osic-tools:latest` or `hpretl/iic-osic-tools:2026.04` for chipathon tapeout work — use `chipathon26` only.

Per-block entry points already exist as scripts in `rtl-test/scripts/` (e.g. `run_pnr_1150_packed.sh`, `run_pnr_1250_iqsouth.sh`, `run_synth_gf180_docker.sh`, `run_synth_trouper_top_breakdown.sh`) — prefer running/adapting one of these over hand-rolling a new docker invocation.

## Standard cells: `gf180mcu_fd_sc_mcu7t5v0` (default)

```bash
docker run --rm \
  --user $(id -u):$(id -g) \
  -v $(pwd):/foss/designs/lora-mimo \
  hpretl/iic-osic-tools:chipathon26 \
  --skip bash -c "cd /foss/designs/lora-mimo/rtl-test && librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 <block_dir>/config.json"
```

Replace `<block_dir>` with e.g. `ol_mrc_combiner`, `ol_picorv32`, `ol_sd_decimator`, `ol_nr_outer`.

## Native 3.3 V cells: `gf180mcu_as_sc_mcu7t3v3` — **not the current tapeout plan**

> AS cells are unlikely to be used. The library is unproven (community-maintained, not a GF-qualified foundry library). Retain configs for reference; prefer FD cells + MCP for new work.

The AS cells are not in the container's PDK. A pre-built overlay at
`/foss/designs/pdk_overlay_as` (NFS-persistent) adds them alongside the
standard foundry cells. Use `--pdk-root` to point LibreLane at the overlay:

```bash
librelane --pdk-root /foss/designs/pdk_overlay_as \
          --pdk gf180mcuD --scl gf180mcu_as_sc_mcu7t3v3 \
          <block_dir>/config_as_mcu7t3v3.json
```

Config files that use AS cells must set `LIB` to
`dir::../../ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/*.lib`
and use the dedicated **`clkbuff_*`** cells for CTS (not `buff_*` — those cause DRT-0073):

```json
"CTS_ROOT_BUFFER": "gf180mcu_as_sc_mcu7t3v3__clkbuff_12",
"CTS_CLK_BUFFERS": [
    "gf180mcu_as_sc_mcu7t3v3__clkbuff_4",
    "gf180mcu_as_sc_mcu7t3v3__clkbuff_8",
    "gf180mcu_as_sc_mcu7t3v3__clkbuff_12"
]
```

Also set `FP_CORE_UTIL` to **50** minimum (not the old FD default of 15–20%). Below ~50% util the
CTS root buffer lands in a sparse dead zone and DRT-0073 recurs even with correct clkbuff cells.
Above ~60% util the density wall kicks in (DRT-0073 from congestion). Safe window: **50–60% util / 55–65% density**.

See `ol_sd_decimator_cic_only/config_as_mcu7t3v3.json` for a working example.

**If the overlay is missing or broken**, rebuild it once via SGE (see the `sge-job` skill for submission details):
```bash
hqsub --name rebuild-as-overlay --cpus 1 --mem 1G -- bash -c \
  "cd /foss/designs/lora-mimo/rtl-test && ./stage_as_scl.sh /foss/designs/pdk_overlay_as"
```

**Why AS cells were explored:** `fd_sc_mcu7t5v0` is characterised at 3 V (SS corner) but designed for 5 V — it fails 32 MHz SS timing across all blocks. AS cells are native 3.3 V and close timing correctly (~16% larger die area). However, the library is unproven and tapeout risk is high; the preferred approach is FD cells with MCP or clock-domain partitioning.

## Reading results

Run outputs live on NFS and are referenced via symlinks at `rtl-test/ol_<block>/runs` (see the `sge-job` skill for how those symlinks are set up).

```bash
# Latest run for a block
ls -t rtl-test/ol_weight_gen/runs/ | head -1

# Post-PNR SS timing WNS
cat rtl-test/ol_weight_gen/runs/RUN_*/56-openroad-stapostpnr/max_ss_125C_3v00/wns.max.rpt

# Magic DRC error count
python3 -c "
import json, glob
state = glob.glob('rtl-test/ol_weight_gen/runs/RUN_*/66-checker-magicdrc/state_out.json')
d = json.load(open(sorted(state)[-1]))
print(d.get('metrics', {}).get('magic__drc_error__count', 'not found'))
"
```
