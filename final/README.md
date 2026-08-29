# trouper_top — Final P&R Outputs

Curated signoff outputs from **SGE job 5214** (2026-08-29), using
`src/config/trouper_top_antenna_b.json`.

This is the first clean full P&R result combining the A40 padframe port names,
the 2 MHz SPI signoff constraint, and antenna repair on the 1675 × 1110 µm
die. It supersedes job 5198.

## Configuration and closure result

- **Die / core:** 1675 × 1110 µm / 1661.52 × 1078.00 µm
- **Floorplan:** A40 `FP_DEF_TEMPLATE` (`A40_ACV_rtlnames.def`); the final
  netlist uses the A40 `<pad>_<terminal>` port names.
- **SPI timing:** `SPI_SCK` is a 500 ns (2 MHz) clock in the emitted signoff
  SDC, asynchronous to `IQ_CLK`. Job 5198 did **not** contain this clock.
- **Antenna repair:** `DIODE_PADDING: 4`, `DPL_CELL_PADDING: 2`, and mixed
  GRT/DRT repair (not jumper-only).
- **Placement density:** 65%. The companion 72% run, job 5213, failed in
  detailed routing with DRT-0073 pin-access errors on the newly-created
  SPI_SCK CTS tree; 65% provides the routing room required by that tree and
  the antenna diodes.

The configuration trail is retained in `src/config/`:

| File | Purpose |
|---|---|
| `trouper_top_antenna.json` | Initial A40 antenna port (72% density; margin 90) |
| `trouper_top_antenna_a.json` | Variant A: removes the margin that caused the antenna-router crash |
| `trouper_top_antenna_b.json` | Variant B / job 5214: Variant A at 65% density |

## Signoff summary

| Check | Result |
|---|---:|
| Antenna violations | 0 nets / 0 pins |
| Route DRC | 0 |
| Magic DRC | 0 |
| LVS | 0 errors; no unmatched pins, nets, or devices |
| IR drop, worst VDD | 5.83 mV |
| Standard-cell utilization | 65.033% |
| Standard-cell count | 48,709 |

Post-P&R timing is clean at nominal and fast corners. The slow 3.0 V corner
remains an open project risk for the FD 5 V-characterized cell library; the
newly timed SPI domain and lower density make its WNS worse than job 5198, so
this is explicitly **not** a 3.0 V SS timing closure claim.

| Corner | Setup WNS | Setup TNS | Hold worst slack |
|---|---:|---:|---:|
| `nom_tt_025C_3v30` | +8.694 ns | 0 | +0.705 ns |
| `max_ff_n40C_3v60` | +11.766 ns | 0 | +0.194 ns |
| `max_ss_125C_3v00` | −16.260 ns | −379.508 ns | +1.818 ns |

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
