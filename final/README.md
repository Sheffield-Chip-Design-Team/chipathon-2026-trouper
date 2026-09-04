# trouper_top — Final P&R Outputs

Curated P&R outputs from **SGE job 5511** (`a40_or66rebase`, 2026-09-04),
produced from the canonical `src/config/trouper_top.json` on the
1675 × 1110 µm A40 die. They supersede the earlier job-5413 collateral.

This run is the first against the **27-pad** padframe (regenerated
`A40_ACV_rtlnames.def`, repo commit `224c151`) **and** the merged
`rtl/open-risk-fixes` RTL (Open Risks #61/#62/#63/#65/#66/#68 plus the
#69/#70 PSRAM-QPI / SX1257-IQ boundary rework). The flow reads `src/`
directly, so those edits are exercised in this layout.

**Integration status:** promoted deliberately so the integrator has a
27-pad, merged-RTL database that is physically clean (Magic DRC / LVS /
XOR / antenna / PDN all 0). It is **not** a timing- or DRV-clean signoff —
see "Known gaps" below. A follow-up P&R (DRV repair-margin change,
re-verified against this netlist; and the SS `training_armed` path) is
tracked separately.

`gds/trouper_top.gds` is deliberately one step newer than the flow
streamout: it is the job-5511 GDS with the reviewed 12 A40 power bridges
inserted (six VDD M2→M5 at the north edge, six VSS M2→M4 at the west edge,
meeting A40's M2 landings). It keeps the macro's native 0.001 µm database
unit. The bridges are inserted by `tools/build_a40_pdn_bridges.py` (KLayout
batch script), which only adds geometry — every standard-cell and macro
coordinate from the run is preserved. Verified layer-by-layer: added
top-cell shapes M2 +24, Via2 +1152, M3 +24, Via3 +1152, M4 +18, Via4 +576,
M5 +6. The other views and reports under `final/` are the unmodified
job-5511 flow outputs, so the Magic DRC / LVS numbers below describe the
**base streamout**, not the added bridge geometry.

**KLayout 63-table DRC: PENDING.** The full guarded run
(`rtl-test/scripts/klayout_drc_guarded.sh`) is a manual gate and applied
only to the previous shipped GDS (job 5415, md5
`f0e740b4930a9ac2c6534949f9bd3e99`). That claim **lapsed** when this file
was regenerated from job 5511. A fresh full KLayout DRC against the new
md5 (below) is owed before tapeout signoff. See Open Risks #58.

## Configuration and closure result

- **Die:** 1675 × 1110 µm (A40 `FP_DEF_TEMPLATE`, `A40_ACV_rtlnames.def`,
  27 pads; final netlist uses the A40 `<pad>_<terminal>` port names).
- **Standard-cell utilization:** 68.70 % (127,200 instances).
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
| KLayout 63-table DRC | **PENDING** (bridged GDS regenerated) |

## Post-P&R timing

Setup is met at the nominal and fast corners. The slow 3.0 V corner remains
an open project risk for the FD 5 V-characterised cell library — and this
run regressed there versus job 5413 (−10.13 → −14.44 ns WNS,
−383.5 → −1008.7 ns TNS), tracking to the #66/#68 `training_acc` /
`sc_detector` rework. This is **not** a 3.0 V SS timing-closure claim.

| Corner | Setup WNS | Setup TNS |
|---|---:|---:|
| `nom_tt_025C_3v30` | +3.343 ns | 0 |
| `max_ff_n40C_3v60` | +5.935 ns | 0 |
| `max_ss_125C_3v00` | −14.436 ns | −1008.726 ns |

Hold is met at all three corners.

## Known gaps (carried, not signed off)

- **Max-slew / max-cap violations** (flow STA, base streamout):

  | Corner | Max slew | Max cap |
  |---|---:|---:|
  | `nom_tt_025C_3v30` | 2 | 2 |
  | `max_ff_n40C_3v60` | 4 | 2 |
  | `max_ss_125C_3v00` | 9 | 3 |

  The recommended fix (`GRT_DESIGN_REPAIR_MAX_{SLEW,CAP}_PCT` 65 → 50, see
  `planning/drv-margin-sweep-2026-09-03.md` and
  `src/config/trouper_top_drvp1.json`) is not applied here — it needs
  re-verification against this merged netlist.
- **SS setup WNS/TNS regression** versus job 5413 (above).
- **KLayout 63-table DRC re-run** against the new bridged GDS.

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
