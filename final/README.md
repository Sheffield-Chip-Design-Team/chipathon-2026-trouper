# trouper_top — Final P&R Outputs

Curated P&R outputs from **SGE job 5413** (`dbgpins`, 2026-09-02), produced
from the canonical `src/config/trouper_top.json` on the 1675 × 1110 µm die.
They supersede the earlier job-5214 collateral.

`gds/trouper_top.gds` is deliberately one step newer than the flow streamout:
it is the job-5413 GDS with the reviewed A40 power bridges inserted. It keeps
the macro's native 0.001 µm database unit and adds six VDD and six VSS bridge
stacks between the A40 M2 landings and its M5/M4 PDN rings. The other views
and reports are the unmodified job-5413 flow outputs. Consequently, the flow
DRC/LVS results below apply to the base job-5413 streamout, not to the added
bridge geometry. That geometry was checked two ways: layer-by-layer continuity
across all 12 paths before promotion, and — since 2026-09-03 — a full KLayout
DRC run against this exact file (job 5415: 63/63 tables, 0 violations; see
Open Risks #58). Note the Magic DRC and LVS numbers in the table below still
describe the base streamout only.

The bridges are inserted by `tools/build_a40_pdn_bridges.py` (KLayout batch
script; see its docstring for the invocation), which only adds geometry and so
leaves every standard-cell and macro coordinate from the run untouched.

## Configuration and closure result

- **Die:** 1675 × 1110 µm
- **Floorplan:** A40 `FP_DEF_TEMPLATE` (`A40_ACV_rtlnames.def`); the final
  netlist uses the A40 `<pad>_<terminal>` port names.
- **SPI timing:** `SPI_SCK` is a 500 ns (2 MHz) clock in the emitted signoff
  SDC, asynchronous to `IQ_CLK`. Job 5198 did **not** contain this clock.
- **Antenna repair:** 0 violating nets / pins in the final antenna check.
- **Standard-cell utilization:** 66.074% (124,857 instances).

The configuration trail that led here is no longer kept as separate files —
`src/config/` now holds one canonical `trouper_top.json`, and the reasoning
each variant carried is preserved in its `_comment_*` fields. For the record,
the chain was:

| Step | Purpose |
|---|---|
| `trouper_top.json` (pre-2026-09-01) | Baseline: 72% density, `DPL_CELL_PADDING` 3, jumper-only antenna repair, `GRT_ANTENNA_REPAIR_MARGIN` 90 |
| `trouper_top_antenna.json` | Initial A40 antenna port (72% density; margin 90) |
| `trouper_top_antenna_a.json` | Variant A: removes the margin that caused the antenna-router crash (job 5212) |
| `trouper_top_antenna_b.json` | Variant B / job 5214: Variant A at 65% density |
| `trouper_top_dbgpins.json` | Variant B + the `ARRAY_ACQ_N` / `DBG0_OUT` / `DBG1_OUT` floorplan template (jobs 5279/5284/5286) |
| → `trouper_top.json` | Collapsed canonical config; used by job 5413 — **these flow outputs** |

Recover any of them with `git show <rev>:src/config/<file>`.

## Signoff summary

| Check | Result |
|---|---:|
| Antenna violations | 0 nets / 0 pins |
| Route DRC | 0 |
| Magic DRC | 0 |
| LVS | 0 errors; no unmatched pins, nets, or devices |
| IR drop, worst VDD | 3.61 mV |
| IR drop, worst VSS | 2.15 mV |
| Standard-cell utilization | 66.074% |
| Standard-cell count | 124,857 |

Post-P&R timing is clean at nominal and fast corners. The slow 3.0 V corner
remains an open project risk for the FD 5 V-characterized cell library; the
newly timed SPI domain and lower density make its WNS worse than job 5198, so
this is explicitly **not** a 3.0 V SS timing closure claim.

| Corner | Setup WNS | Setup TNS | Hold worst slack |
|---|---:|---:|---:|
| `nom_tt_025C_3v30` | +10.722 ns | 0 | +0.286 ns |
| `max_ff_n40C_3v60` | +11.745 ns | 0 | +0.116 ns |
| `max_ss_125C_3v00` | −10.130 ns | −383.510 ns | +0.318 ns |

For the background on the SS voltage limitation and the associated signoff
strategy, see `planning/antenna-closure-investigation-2026-08.md` and the
project timing-risk documentation.

## Contents

| Path | Contents |
|---|---|
| `gds/`, `def/`, `lef/` | Final layout, routed DEF, and abstract view |
| `nl/`, `pnl/`, `spice/`, `vh/` | Post-layout netlist views |
| `sdc/trouper_top.sdc` | Flow-emitted SDC, including the 2 MHz SPI clock |
| `lib/<corner>/` | Per-corner timing libraries |
| `reports/sta/` | Post-P&R STA reports for all three corners |
| `reports/drc/`, `reports/lvs/`, `reports/irdrop/` | Signoff reports |
| `metrics.json`, `metrics.csv` | Full flow metrics |
| `render/trouper_top.png` | Layout render |

The repo deliberately tracks this curated subset. Regenerable `spef/`, `sdf/`,
`odb/`, `mag/`, `mag_gds/`, and `klayout_gds/` outputs remain with the P&R run
on NFS. `gds/` and `def/` are ordinary Git blobs, not Git LFS objects.
