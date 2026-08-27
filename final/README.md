# trouper_top — Final P&R Outputs

Signoff-flow output for `trouper_top`, full 1650×1100 µm rectangular die
(NE 550×550 notch reclaimed — see `rtl-test/ol_trouper_top/config_1650x1100_full_rect.json`,
**SGE job 5105, 2026-08-27**). Supersedes job 4780 (2026-08-23): same RTL, same
floorplan, same SDC — the only change is the DRV-closure flow settings folded
into the config (see "DRV closure" below). GDS/DEF are plain git blobs here (see
note near the bottom), not Git LFS.

## Results summary

- **DRC:** 0 errors (Magic)
- **LVS:** 0 mismatches (netgen — circuits match uniquely)
- **Max fanout:** 0 violations (all corners)
- **Max slew / max cap violations:** 10 / 4 (nom_tt), 15 / 6 (max_ss), 10 / 4 (max_ff).
  Down from 1060 / 115 (nom_tt) and 1963 / 160 (max_ss) in job 4780. The ~15
  residual pins are a documented waiver — see "DRV closure".
- **Timing (WNS, setup):**
  - `nom_tt_025C_3v30`: 0.0 ns (met)
  - `max_ff_n40C_3v60`: 0.0 ns (met)
  - `max_ss_125C_3v00`: −15.71 ns (was −16.97 ns in job 4780; the DRV buffering
    reached the `packet_done_pulse` critical cluster. Still the known chronic
    gap — `gf180mcu_fd_sc_mcu7t5v0` is 5V-characterized cells run at 3.0–3.3V
    core; the −13 ns floor underneath is DRV-clean and voltage-bound. See
    `planning/` for the voltage-headroom discussion.)
- **IR drop:** worst 3.85 mV on VDD (0.12 %), 3.64 mV on VSS
- Full metrics: `metrics.json` / `metrics.csv`

## DRV closure (job 5105 vs job 4780)

Job 4780 signed off with 1060 max-slew + 115 max-cap violations at nom_tt (1963
+ 160 at SS), in every corner. Root cause: the only DRV repair passes ran on
*estimated* placement/GRT parasitics and saw an essentially clean design
(3 slew / 6 cap); OpenRCX extraction then exposed the real loads and there was
no post-extraction repair.

Fix — pure LibreLane flow config, **no RTL and no SDC change**, folded into
`config_1650x1100_full_rect.json`:

| Var | 4780 | 5105 |
|---|---|---|
| `RUN_POST_GRT_RESIZER_TIMING` | false | **true** |
| `DESIGN_REPAIR_MAX_SLEW_PCT` / `_CAP_PCT` | 20 | **65** |
| `GRT_DESIGN_REPAIR_MAX_SLEW_PCT` / `_CAP_PCT` | 10 | **65** |

Cost: core utilization 0.633 → 0.660, routed wirelength +17 % (extra buffers),
die unchanged, DRC/LVS still clean.

**Do not** add `set_max_transition` / `set_max_capacitance` to the SDC to chase
the residual: any design-wide value stalls `repair_design` on this netlist for
70+ min (trials t3/t5/t6, 2026-08-27).

**Residual waiver (~15 pins, worst −4.3 ns / 19.9 ns edge at SS):** five root
nets in the `sc_detector` SF/BW symbol-period decode (`_34304/07/18`) and the
`training_acc` `Zpair_q` cross-correlator cone (`_37004/05`, `_46587/88`,
`_46684/85`, `_51034/35`), plus two output-path buffers (`output44/I`,
`_63973_/I`) driving pad loads. The decode/`Zpair` cones are quasi-static,
MCP-relaxed, and read cycles-to-seconds later by firmware; slow edges there are
functionally immaterial. See `reports/sta/*/checks.rpt` for the full list.

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
| `render/trouper_top.png` | Layout render — **carried over from job 4780, not regenerated for 5105.** The t4b change only adds ~800 timing-repair buffers among ~47k cells; at full-die zoom the routing image is visually identical. Regenerate from `gds/trouper_top.gds` with the `gds-plot` skill if a current image is needed. |
| `metrics.json`, `metrics.csv` | Cell count/area/utilization + full signoff metric dump |
| `reports/sta/<corner>/{max,min,checks}.rpt` | Post-P&R STA reports per corner (setup/hold paths + constraint checks) |
| `reports/drc/drc.magic.rpt` | Magic DRC report (0 errors) |
| `reports/lvs/lvs.netgen.rpt` | netgen LVS report (circuits match uniquely, 0 mismatches) |
| `reports/irdrop/irdrop.rpt` | IR-drop summary (worst 3.85 mV on VDD) |

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
subdirectories (job 5105: `57-openroad-stapostpnr/`, `66-magic-drc/`,
`72-netgen-lvs/`, `58-openroad-irdropreport/`) and were copied in here
separately alongside the `final/` tree, since a reviewer needs them next to
the GDS. (Stage numbers shifted from job 4780 because
`RUN_POST_GRT_RESIZER_TIMING` adds steps.)
