# trouper_top — Final P&R Outputs

Signoff-flow output for `trouper_top`, full 1650×1100 µm rectangular die
(NE 550×550 notch reclaimed — see `rtl-test/ol_trouper_top/config_1650x1100_full_rect.json`,
SGE job 4780, 2026-08-23). GDS/DEF are tracked via Git LFS (`.gitattributes`).

## Results summary

- **DRC:** 0 errors (Magic)
- **LVS:** 0 mismatches (netgen)
- **Timing (WNS, setup):**
  - `nom_tt_025C_3v30`: 0.0 ns (met)
  - `max_ff_n40C_3v60`: 0.0 ns (met)
  - `max_ss_125C_3v00`: −16.97 ns (known chronic gap — `gf180mcu_fd_sc_mcu7t5v0`
    is 5V-characterized cells run at 3.0–3.3V core; see `planning/` for the
    voltage-headroom discussion)
- **IR drop:** worst 2.75 mV on VDD
- Full metrics: `metrics.json` / `metrics.csv`

## Contents

| Path | What it is |
|---|---|
| `gds/trouper_top.gds` | Final tapeout-ready layout |
| `def/trouper_top.def` | Final placed-and-routed DEF |
| `lef/trouper_top.lef` | Abstract view (pins + blockages) |
| `pnl/trouper_top.pnl.v` | Post-layout gate-level netlist (physical-cells included: taps/decap/fill) |
| `nl/trouper_top.nl.v` | Post-layout gate-level netlist (logical cells only) |
| `spice/trouper_top.spice` | SPICE netlist |
| `vh/trouper_top.vh` | Verilog header (port list) |
| `sdc/trouper_top.sdc` | Signoff SDC (timing constraints) |
| `lib/<corner>/trouper_top__<corner>.lib` | Per-corner timing library views (nom_tt/max_ss/max_ff) |
| `json_h/trouper_top.h.json` | Yosys JSON header (port/bit-width metadata) |
| `render/trouper_top.png` | Layout render |
| `metrics.json`, `metrics.csv` | Cell count/area/utilization + full signoff metric dump |
| `reports/sta/<corner>/{max,min,checks}.rpt` | Post-P&R STA reports per corner (setup/hold paths + constraint checks) |
| `reports/drc/drc.magic.rpt` | Magic DRC report (0 errors) |
| `reports/lvs/lvs.netgen.rpt` | netgen LVS report (circuits match uniquely, 0 mismatches) |
| `reports/irdrop/irdrop.rpt` | IR-drop summary (worst 2.75 mV on VDD) |

**Note:** `gds/` and `def/` are plain git blobs in this directory, *not* Git LFS
(unlike `/gds/*.gds` at the repo root, which is LFS-tracked) — LFS is skipped
here specifically because of tooling issues on the reviewer's side.

## Files intentionally removed from the full LibreLane `final/` output

To keep this directory small enough for a normal git commit, the following
were dropped (still available on request from the full run — NFS-primary,
see project convention in `CLAUDE.md`):

| Removed | Size (this run) | Why it's safe to drop |
|---|---|---|
| `spef/` | 78M | Post-route parasitics per corner — only needed to *re-run* STA yourself; the signed-off timing numbers are already summarized above and in `metrics.json` |
| `sdf/` | 23M | Timing back-annotation for gate-level simulation — regenerable from `pnl.v` + P&R run, not needed for layout/timing review |
| `odb/` | 32M | OpenROAD native database — regenerable from `def`, only useful for resuming/re-editing the P&R flow itself |
| `mag/`, `mag_gds/` | 47M combined | Magic-native layout + its GDS re-export — redundant with `gds/trouper_top.gds`, the actual signoff GDS |
| `klayout_gds/` | 9.5M | Another GDS re-export (KLayout-normalized) — also redundant with `gds/trouper_top.gds` |

The signoff reports under `reports/` above are *not* part of LibreLane's
own `final/` output — they live in the P&R run's numbered stage
subdirectories (`56-openroad-stapostpnr/`, `65-magic-drc/`, `71-netgen-lvs/`,
`57-openroad-irdropreport/`) and were copied in here separately alongside
the `final/` tree, since a reviewer needs them next to the GDS.
