# trouper_top — Final P&R Outputs

Curated P&R outputs from **SGE job 5682**
(`pnr_a40_v33_keepout_m2m3`, 2026-09-06), produced from the canonical
`src/config/trouper_top.json` (signoff SDC v33) on the 1675 × 1110 µm A40
die. They supersede the job-5674 collateral.

## PDN-bridge routing keepout (`src/config/pdn_cfg.tcl`)

Two `create_obstruction` boxes on **Metal2 + Metal3 only** (`-except_pg`),
guarded on `DIE_AREA`, over the north-VDD and west-VSS A40 PDN-bridge landing
zones (`x[1330,1405] y[1094,1110]`, `x[0,8] y[4,82]` µm).

`tools/build_a40_pdn_bridges.py` inserts the 12 bridges into the GDS by fixed
absolute coordinates with no awareness of the routed result. On job 5650 the
router had run three long/high-fanout **signal** nets (`_20360_`, `_20338_`,
`_18690_`) through the north bridge via-enclosure band → 12× M3.2a + 4× V2.1
in the guarded 63-table KLayout DRC (job 5653).

Two earlier keepout attempts failed and are recorded so they are not retried:

- **M2–M5 obstruction** (job 5674): blocks PG routing too, which **cut
  Trouper's own PDN** where the bridges tap in — the VDD M5 north ring lost
  `x[1329.5,1405.5]` and the VSS M4 west ring `y[4,82.3]`, leaving the
  post-flow bridges electrically floating. LVS runs on the base streamout,
  not the bridged GDS, so it never caught it.
- **M2–M5 obstruction + `-except_pg`** (job 5681): the signal router honours
  except-pg, but the PDN generator (`add_pdn_ring` / `add_pdn_stripe`) carves
  around **any** obstruction regardless of the flag — ring still cut.

**M2/M3-only** (this run) evicts the offending signal M3/via2 (all 16
job-5653 violations were signal, verified per-net) while leaving M4/M5 free
for the core ring. Verified on job 5682's routed DEF: VDD M5 north ring one
continuous segment `x[8.1, 1666.8]`, VSS M4 west ring one segment
`y[1.7, 1107.7]`, and **zero signal M4/M5 in either bridge zone**. After
bridge insertion, the bridge M5 boxes merge with the VDD ring into one
contiguous polygon and the bridge M4 boxes merge with the VSS ring — the
bridges are connected.

## GDS

`gds/trouper_top.gds` is the job-5682 flow streamout with the 12 A40 power
bridges inserted (`tools/build_a40_pdn_bridges.py`, unchanged). Adds geometry
only — every standard-cell/macro coordinate is preserved. Layer deltas
top-cell: M2 +24, Via2 +1152, M3 +24, Via3 +1152, M4 +18, Via4 +576, M5 +6.

**md5 of `gds/trouper_top.gds`: `c308505a425acdce2e6704273c5c524a`**
(streamout `f6b769928c72c65913872e6e2d980b34`).

## KLayout 63-table DRC — job 5684

Full guarded run (`rtl-test/scripts/klayout_drc_guarded.sh`) against the exact
bridged GDS above. **61/63 tables clean at time of writing** — every table
that could carry a bridge-geometry violation is done and zero: `metal3`
(was 12× M3.2a) 0, `via2` (was 4× V2.1) 0, `metal4` / `metal5` / `via4` 0
(no bridge-via-stack clash). `contact` and `metal1` (~68 / 45 min) still
running; the M2–M5 bridges add no poly/contact/M1 geometry, so those see the
same geometry as the base streamout (Magic DRC 0). Update this line with the
full 63/63 verdict when job 5684 finishes.

## Signoff summary

| Check | Result |
|---|---:|
| Antenna violations | 0 nets / 0 pins |
| Route DRC | 0 |
| Magic DRC | 0 |
| LVS | 0 errors; circuits match uniquely |
| XOR (GDS vs flow) | 0 differences |
| PDN power-grid violations | 0 (VDD, VSS) |
| KLayout 63-table DRC (bridged GDS, job 5684) | 61/63 clean; `contact`/`metal1` pending |
| Hold (flow STA corners) | MET (WNS 0, TNS 0) — see note below |
| Hold (`min_ff` out-of-flow, job 5687) | +0.12 ns, TNS 0 |
| MCP scoped-exception audit (synth + route) | PASS — 14 groups each, no baseline delta |
| Host-SPI post-route GLS/SDF (nom_tt, job 5686) | PASS |

## Post-P&R timing

| Corner | Setup WNS | Setup TNS |
|---|---:|---:|
| `nom_tt_025C_3v30` | MET | 0 |
| `max_ff_n40C_3v60` | MET | 0 |
| `max_ss_125C_3v00` | −12.899 ns | −1175.1 ns |

The `max_ss_125C_3v00` corner is the FD 5 V-cell voltage problem (#1/#40),
pursued as a waiver — not a closure claim. This run's SS WNS/TNS/DRV are the
best of the keepout series (5674 was −14.02 / −1263 / 13-4).

Hold is met at the three **flow** STA corners (`nom_tt`, `max_ss`, `max_ff`).
None is a min-RC fast corner, so that is not the true hold sign-off; the real
fast/hold corner is checked out of flow — standalone OpenROAD STA on this
run's routed ODB + min-RC SPEF + `ff_n40C_3v60` liberty (job 5687): **worst
hold slack +0.12 ns, hold TNS 0.00**. `STA_CORNERS` cannot host `min_ff`
directly (Open Risks #41/#54).

## Known gaps (carried, not signed off)

- **SS setup WNS/TNS** at `max_ss_125C_3v00` (above) — the #1/#40 voltage
  problem; pursued as a waiver.
- **Max slew / max cap**, flow STA:

  | Corner | Max slew | Max cap |
  |---|---:|---:|
  | `nom_tt_025C_3v30` | 0 | 0 |
  | `max_ff_n40C_3v60` | 0 | 0 |
  | `max_ss_125C_3v00` | 9 | 2 |

  The 9+2 collapse to **2 nets**: `training_acc.n_acc` update-enable gating
  (slew −1.46 ns / cap −0.018 pF) and the `packet_ctrl_fsm`
  `iq_samp_cnt`↔`lat_timing_ref` replay comparator (slew −0.26 ns / cap
  −0.012 pF). Both MCP-relaxed quasi-static cones with a ≥2-cycle budget.
  Raising Vdd does not help — it tightens the `max_transition` limit faster
  than it speeds the edges (job 5689: 4.5 V limit 7.0 ns vs 3.0 V 15.6 ns,
  slew violations 9 → ~140). Standalone waiver, subset of the ~15-pin
  residual accepted at the job-5105 signoff.

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

Regenerable `spef/`, `sdf/`, `odb/`, `mag/`, `mag_gds/`, `klayout_gds/`
outputs stay with the P&R run on NFS. `gds/` and `def/` are ordinary Git
blobs, not Git LFS objects.
