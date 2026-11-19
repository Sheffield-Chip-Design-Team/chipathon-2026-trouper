# trouper_top — Final P&R Outputs

Curated P&R outputs from **SGE job 5861**
(`pnr_a40_irqsetwins_dcrsat`, 2026-10-10), produced from the canonical
`src/config/trouper_top.json` (`CTS_APPLY_NDR=none`, `MAX_WIRE_LENGTH` 450,
signoff SDC v33) on the 1675 × 1110 µm A40 die. They supersede the job-5682
collateral.

The run's `src/` snapshot is byte-identical to branch
`rtl/psram-trim-backdate-ciff3` (PR #57). Since 5682 it adds: the PSRAM QPI
read-capture split + `PSRAM_RD_TRIM` (0x7A) + falling-edge SIO capture
(Open Risk #72), replay backdate `REPLAY_BACKDATE_SYMS` (0x7B, #81), the
reg_bank IRQ set-wins fix, the `sd_remod` CIFF3 redesign, and `dc_removal`
int8 saturation (#75).

All out-of-flow gates below ran on `hpretl/iic-osic-tools:chipathon26`
(asserted per job in its `manifest.json` `tool_image`).

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

**M2/M3-only** (unchanged since job 5682) evicts signal M3/via2 from the
bridge zones while leaving M4/M5 free for the core ring. **Re-verified on job
5861's routed DEF:** VDD M5 north ring one continuous segment
`x[8.12, 1666.84]`, VSS M4 west ring one segment `y[1.68, 1107.68]`, and
**zero signal M4/M5 wires in either bridge zone**.

## GDS

`gds/trouper_top.gds` is the job-5861 flow streamout with the 12 A40 power
bridges inserted (`tools/build_a40_pdn_bridges.py`, unchanged; SGE job 8472).
Adds geometry only — every standard-cell/macro coordinate is preserved. Layer
deltas top-cell: M2 +24, Via2 +1152, M3 +24, Via3 +1152, M4 +18, Via4 +576,
M5 +6 (identical to every previous promote).

**md5 of `gds/trouper_top.gds`: `fd26d3cd6c3c8a55dc1930b46338fce1`**
(streamout `7b779f66bcd75eddd135fed3e868ea35`).

## KLayout 63-table DRC — job 8475

Full guarded run (`rtl-test/scripts/klayout_drc_guarded.sh`, per-job copy)
against the exact bridged GDS above (md5 `fd26d3cd…`, staged and checked before
submit). **63/63 tables ran, 0 violations** — `reports missing 0`,
`truncated 0`, `exceptions 0`, `RESULT: PASS`, guard exit 0.

An earlier attempt (job 8468) landed on the scheduler's `2026.10` default
image, whose PDK no longer has `rule_decks/layers_def.drc`; the guard refused
to run (exit 1), as designed. The 2026.10 bridge/MCP/GLS jobs (8464–8467) were
discarded and rerun on `chipathon26`.

## Signoff summary

| Check | Result |
|---|---:|
| Antenna violations | 0 nets / 0 pins |
| Route DRC | 0 |
| Magic DRC | 0 |
| LVS (flow, base streamout / DEF) | 0 errors; circuits match uniquely |
| XOR (GDS vs flow) | 0 differences |
| PDN power-grid violations | 0 (VDD, VSS); worst IR drop 1.53 mV (0.05 %) |
| KLayout 63-table DRC (bridged GDS, job 8475) | 63/63 ran, 0 violations |
| Hold (flow STA corners) | MET (WNS 0, TNS 0); worst slack +0.106 ns at `max_ff` |
| MCP scoped-exception audit (synth 8474 + route 8476) | PASS — 14 groups each; baseline re-approved (see below) |
| Host-SPI post-route GLS/SDF (nom_tt, job 8473) | PASS |

**MCP baseline re-approval.** Both stages first failed "resolved MCP object
set changed". Reviewed before `--update-baseline`: per group, endpoint
counts, `-through` object names and setup/hold multipliers are identical to
the job-5682 baseline in both stages, and the endpoint registers (mapped
through their Q nets) are the same set. The only change is the anonymised
`_NNNNN_` instance numbering of the new netlist.

**GLS (job 8473)** — netlist md5 `d6fbf31e…`, nom_tt SDF `fef61619…`: reset
release, CHIP_ID `0xA7` / CHIP_REV `0x01`, MISO low after read, min-CS-hold
write + readback, min CS-high gap, 8-byte W-bank burst + auto-inc readback,
read-byte snapshot stability — all pass.

## Post-P&R timing

| Corner | Setup WNS | Setup TNS | Hold WS |
|---|---:|---:|---:|
| `nom_tt_025C_3v30` | +5.447 ns | 0 | +0.575 ns |
| `max_ff_n40C_3v60` | +8.479 ns | 0 | +0.106 ns |
| `max_ss_125C_3v00` | **−19.062 ns** | −1199.1 ns | +1.521 ns |

The `max_ss_125C_3v00` corner is the FD 5 V-cell voltage problem (#1/#40),
pursued as a waiver — not a closure claim. The worst SS path is in `u_remod`
(CIFF3).

## Not re-run for this netlist

These were established on the job-5682 GDS/netlist and have **not** been
repeated against job 5861. Treat them as owed, not carried:

- **Bridged-GDS LVS** (job 5732 + negative control 5733,
  `reports/bridged_macro_lvs/`): the flow LVS above extracts from the DEF and
  never sees the bridges. The bridge geometry and the keepout are unchanged,
  and the DEF ring check above passes, but the bridged-GDS extraction itself
  has not been rerun.
- **A40 tile seam trace** (job 5719, `planning/a40-bridge-tile-lvs-selfcheck.md`).
- **Standalone `min_ff` hold STA** (min-RC SPEF + `ff_n40C_3v60`; job 5687
  gave +0.12 ns on 5682). The flow corners above are not a min-RC fast corner
  (Open Risks #41/#54).
- **SS at the raised rail** (`ss_125C_4v50` liberty swap; job 5742 gave
  +3.39 ns on 5682).

## Known gaps (carried, not signed off)

- **SS setup WNS/TNS** at `max_ss_125C_3v00`: −19.06 ns / −1199 ns, a
  **regression from −12.90 ns / −1175 ns** on job 5682. Job 5842 (same PSRAM
  RTL, older `reg_bank`) reached −15.21 ns, so the RTL since 5682 accounts for
  the gap. The worst path is `u_remod`. The #1/#40 voltage waiver applies.
- **Max slew / max cap**, flow STA:

  | Corner | Max slew | Max cap |
  |---|---:|---:|
  | `nom_tt_025C_3v30` | 4 | 3 |
  | `max_ff_n40C_3v60` | 4 | 3 |
  | `max_ss_125C_3v00` | 9 | 5 |

  Job 5682 had 0/0 at nom_tt and max_ff. The violators are three
  `nor4_1` → `and3/and4` drivers in the `reg_bank` SPI read mux feeding
  `u_spi.miso_shreg[4]`, `[6]` and the MISO output flop: worst slew −1.06 ns
  at nom_tt and −6.13 ns at SS. A fourth, at SS only, is the `rpl_valid`
  D-input cone (−0.75 ns). This is Open Risk #82. The read mux is a
  2 MHz SPI-domain path with ample setup margin, but the DRV is not waived.

## Contents

| Path | Contents |
|---|---|
| `gds/`, `def/`, `lef/` | Final layout (bridged GDS), routed DEF, abstract view |
| `nl/`, `pnl/`, `spice/`, `vh/`, `json_h/` | Post-layout netlist views |
| `sdc/trouper_top.sdc` | Flow-emitted SDC, including the 2 MHz SPI clock |
| `lib/<corner>/` | Per-corner timing libraries |
| `reports/sta/` | Post-P&R STA reports for all three corners |
| `reports/drc/`, `reports/lvs/`, `reports/irdrop/` | Flow signoff reports (base streamout / DEF) |
| `metrics.json`, `metrics.csv` | Full flow metrics |
| `render/trouper_top.png` | Layout render |

Regenerable `spef/`, `sdf/`, `odb/`, `mag/`, `mag_gds/`, `klayout_gds/`
outputs stay with the P&R run on NFS. `gds/` and `def/` are ordinary Git
blobs, not Git LFS objects.
