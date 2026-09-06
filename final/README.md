# trouper_top — Final P&R Outputs

Curated P&R outputs from **SGE job 5674**
(`pnr_a40_tapeout_candidate_v33_keepout`, 2026-09-06), produced from the
canonical `src/config/trouper_top.json` (signoff SDC v33) on the
1675 × 1110 µm A40 die. They supersede the job-5511 collateral.

This run adds two **routing-only PDN-bridge keepouts** (`pdn_cfg.tcl`,
guarded on `DIE_AREA`; see `src/config/trouper_top.json`
`_comment_pdn_bridge_keepouts`): `create_obstruction` on Metal2–Metal5 over
the north VDD and west VSS A40 PDN-bridge landing zones. They exist because
job 5650's bridged GDS failed the guarded 63-table KLayout DRC (job 5653)
with 12× M3.2a + 4× V2.1, all in the north bridge geometry — the router had
run two long high-fanout signal nets (`_20360_`, `_20338_`) along the sparse
top edge, straight through the fixed-coordinate bridge via-enclosure band.
The obstructions keep the router out of the bridge footprints; job 5674's
routed DEF has zero Metal2–Metal5 wires (signal or PG) in either box.
Cost: SS setup WNS −12.99 → −14.02 ns (the two evicted nets take longer
paths); GRT congestion and DRC/LVS/antenna unchanged; nom_tt/max_ff DRV
actually improved.

`gds/trouper_top.gds` is the job-5674 flow streamout with the reviewed 12
A40 power bridges inserted (six VDD M2→M5 at the north edge, six VSS M2→M4
at the west edge), by `tools/build_a40_pdn_bridges.py` (KLayout batch,
unchanged). It keeps the macro's native 0.001 µm database unit and adds
geometry only — every standard-cell and macro coordinate from the run is
preserved. Verified layer-by-layer: added top-cell shapes M2 +24, Via2
+1152, M3 +24, Via3 +1152, M4 +18, Via4 +576, M5 +6. The other views and
reports under `final/` are the unmodified job-5674 flow outputs, so the
Magic DRC / LVS numbers below describe the **base streamout**, not the added
bridge geometry.

**md5 of `gds/trouper_top.gds`: `050c2734fd5ada755c92717782e0abdd`**
(streamout `24c3e95c25f94367a7e876a16574aca5`).

**KLayout 63-table DRC: PASS.** The full guarded run
(`rtl-test/scripts/klayout_drc_guarded.sh`, a manual out-of-flow gate — see
Open Risks #58) ran against the exact bridged GDS above on SGE job 5676:
**all 63 tables ran, 0 reports missing, 0 truncated, 0 exceptions, 0
violations**, guard exit 0. This supersedes the job-5415 pass (md5
`f0e740b4…`, job-5511 GDS), which lapsed when this file was regenerated.
Any change to the GDS re-arms this gate.

## Configuration and closure result

- **Die:** 1675 × 1110 µm (A40 `FP_DEF_TEMPLATE`, `A40_ACV_rtlnames.def`,
  27 pads; final netlist uses the A40 `<pad>_<terminal>` port names).
- **Standard-cell utilization:** 70.96 % (127,171 instances).
- **PDN-bridge keepouts:** M2–M5 `create_obstruction` over
  `x[1330,1405] y[1094,1110]` (north VDD) and `x[0,8] y[4,82]` (west VSS) µm.
- **SPI timing:** `SPI_SCK` is a 500 ns (2 MHz) clock in the emitted signoff
  SDC, asynchronous to `IQ_CLK`.

## Signoff summary

| Check | Result |
|---|---:|
| Antenna violations | 0 nets / 0 pins |
| Route DRC | 0 |
| Magic DRC | 0 |
| LVS | 0 errors; circuits match uniquely |
| XOR (GDS vs flow) | 0 differences |
| PDN power-grid violations | 0 (VDD, VSS) |
| KLayout 63-table DRC (bridged GDS, job 5676) | **PASS — 63/63, 0 violations** |
| Hold (flow STA corners) | MET (WNS 0, TNS 0) — but see note below |
| MCP scoped-exception audit (synth + route, jobs 5677/5679) | PASS — 14 groups each, no baseline delta |
| Host-SPI post-route GLS/SDF (nom_tt, job 5678) | PASS |

## Post-P&R timing

Setup is met at the nominal and fast corners. The slow 3.0 V corner
(`max_ss_125C_3v00`) remains an open project risk for the FD 5 V-characterised
cell library and is pursued as a waiver, **not** a closure claim. This run
regressed there versus job 5650 (−12.99 → −14.02 ns WNS, −1297 → −1263 ns
TNS) — the ~1 ns is the two nets the keepout evicted from the top-edge
channel taking longer paths; it sits inside this design's normal repair-
lottery spread.

| Corner | Setup WNS | Setup TNS |
|---|---:|---:|
| `nom_tt_025C_3v30` | MET | 0 |
| `max_ff_n40C_3v60` | MET | 0 |
| `max_ss_125C_3v00` | −14.024 ns | −1263.455 ns |

Hold is met at the three **flow** STA corners (`nom_tt`, `max_ss`, `max_ff`).
**None of them is a min-RC fast corner**, so this is not the true hold
sign-off: hold is worst at fast cells + minimum extracted RC. The config's
`STA_CORNERS` cannot host `min_ff_n40C_3v60` directly (LibreLane logs
`Skipping corner …`, and the RCX-deck rename breaks GRT routing at this
density — Open Risks #41/#54). The real fast/hold corner is checked
**out of flow**: standalone OpenROAD STA on this run's routed ODB + min-RC
SPEF + `ff_n40C_3v60` liberty, SGE job 5680 — **worst hold slack +0.11 ns,
hold TNS 0.00** (whole design; job 5630 was +0.12 ns). Hold holds at
`min_ff`. To be re-run whenever this netlist changes.

## Known gaps (carried, not signed off)

- **SS setup WNS/TNS** at `max_ss_125C_3v00` (above) — the #1/#40 voltage
  problem; being pursued as a waiver.
- **Max-slew / max-cap violations** (flow STA, base streamout):

  | Corner | Max slew | Max cap |
  |---|---:|---:|
  | `nom_tt_025C_3v30` | 0 | 0 |
  | `max_ff_n40C_3v60` | 0 | 1 |
  | `max_ss_125C_3v00` | 13 | 4 |

  nom_tt and max_ff are clean on this run (job 5650 was 2/1 and 2/1); SS is
  slightly worse (11/2 → 13/4). The `GRT_DESIGN_REPAIR_MAX_{SLEW,CAP}_PCT`
  65 → 50 lever (`planning/drv-margin-sweep-2026-09-03.md`) is not applied.

## Contents

| Path | Contents |
|---|---|
| `gds/`, `def/`, `lef/` | Final layout (bridged GDS), routed DEF, abstract view |
| `nl/`, `pnl/`, `spice/`, `vh/`, `json_h/` | Post-layout netlist views |
| `sdc/trouper_top.sdc` | Flow-emitted SDC, including the 2 MHz SPI clock |
| `lib/<corner>/` | Per-corner timing libraries |
| `reports/sta/` | Post-P&R STA reports for all three corners |
| `reports/drc/`, `reports/lvs/`, `reports/irdrop/` | Signoff reports (base streamout) |
| `metrics.json`, `metrics.csv` | Full flow metrics |
| `render/trouper_top.png` | Layout render |

The repo deliberately tracks this curated subset. Regenerable `spef/`,
`sdf/`, `odb/`, `mag/`, `mag_gds/`, and `klayout_gds/` outputs remain with
the P&R run on NFS. `gds/` and `def/` are ordinary Git blobs, not Git LFS
objects.
