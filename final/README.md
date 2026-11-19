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

**Bridged-GDS LVS (job 5732, 2026-09-07).** The flow's Netgen LVS
(`reports/lvs/lvs.netgen.rpt`) extracts from the **DEF** (`MAGIC_EXT_USE_GDS=0`),
so it never sees the post-flow bridges. Re-run against the **bridged GDS**
(md5 `c308505a…`) — Magic extraction with std cells LEF-abstracted (same
top-level-interconnect class as the flow LVS) then Netgen `-blackbox` vs
`pnl/trouper_top.pnl.v`: **`Circuits match uniquely`** — 39836 devices / 39823
nets on both sides, identical; VDD, VSS and every signal pin match; 7 disconnected
pins (benign tie/fill, as in the base run). The extracted device/instance/RC
line set is byte-identical to the base-DEF extraction (127081 lines) — i.e. the
bridges added **zero** connectivity (redundant metal on already-joined VDD/VSS),
which is the correct signature of healthy bridges and rules out a short or a
stray net (either would perturb the count). It does **not** by itself prove the
bridges *connect* — that is the seam trace below + the DEF ring-continuity check
above.

*Negative control (job 5733):* a deliberate M1 VDD↔VSS box injected into the
bridged GDS makes Magic emit `Ports "VSS" and "VDD" are electrically shorted`,
the net count drop to 39821, and Netgen report `Netlists do not match / Top
level cell failed pin matching` — so the harness demonstrably catches a real
short, and 5732's clean pass is meaningful.
Report + repro: `reports/bridged_macro_lvs/` (incl. `negctl_*`).

**Tile-context seam check (job 5719, 2026-09-06).** For the A40 ↔ `SSCS_2026_01`
padring boundary (not in the macro): the bridged A40 was swapped into the v6 tile
GDS and a KLayout connectivity trace run over the whole die. A40 core VDD/VSS each
extract as one net equal to the chip `A40_VDD` / shared `VSS` net (no open),
distinct from each other (no rail short), carrying only power labels (no
bridge/PDN-to-signal short over 25 signal nets), all 12 bridge stacks integral
M2-foot→M5/M4-top; XOR confirms the swap perturbs nothing outside A40. Full
device-level LVS of the A40-only tile is integrator scope. See
`planning/a40-bridge-tile-lvs-selfcheck.md`.

## GDS

`gds/trouper_top.gds` is the job-5682 flow streamout with the 12 A40 power
bridges inserted (`tools/build_a40_pdn_bridges.py`, unchanged). Adds geometry
only — every standard-cell/macro coordinate is preserved. Layer deltas
top-cell: M2 +24, Via2 +1152, M3 +24, Via3 +1152, M4 +18, Via4 +576, M5 +6.

**md5 of `gds/trouper_top.gds`: `c308505a425acdce2e6704273c5c524a`**
(streamout `f6b769928c72c65913872e6e2d980b34`).

## KLayout 63-table DRC — job 5684

Full guarded run (`rtl-test/scripts/klayout_drc_guarded.sh`) against the exact
bridged GDS above (md5 `c308505a…`, asserted in the job log). **63/63 tables
ran, 0 violations** — `reports missing 0`, `truncated 0`, `exceptions 0`,
`RESULT: PASS`, guard exit 0. Every table that could carry bridge geometry is
zero: `metal3` (was 12× M3.2a) 0, `via2` (was 4× V2.1) 0,
`metal4` / `metal5` / `via4` 0; `contact` (58 min) and `metal1` (40 min) also
clean. First full genuine KLayout DRC pass on the shipped bridged GDS.

## Signoff summary

| Check | Result |
|---|---:|
| Antenna violations | 0 nets / 0 pins |
| Route DRC | 0 |
| Magic DRC | 0 |
| LVS (flow, base streamout / DEF) | 0 errors; circuits match uniquely |
| LVS (bridged GDS, job 5732) | circuits match uniquely — 39836 dev / 39823 net both sides |
| XOR (GDS vs flow) | 0 differences |
| PDN power-grid violations | 0 (VDD, VSS) |
| KLayout 63-table DRC (bridged GDS, job 5684) | 63/63 ran, 0 violations |
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

**SS setup closes at the raised core rail — this exact netlist (job 5742,
2026-09-07).** Liberty-swap STA reload of `nl/trouper_top.nl.v` (md5
`d3cdcb86…`) + this run's `max` SPEF + signoff SDC v33
(`src/config/pnr_32m_scoped_v25_b6_signoff.sdc`, md5 `740e1b15…`), only the
SS liberty changed:

| SS liberty | Setup WNS | Setup TNS | Hold WNS (max SPEF) |
|---|---:|---:|---:|
| `ss_125C_3v00` (control) | −12.888 ns | −1166.2 ns | +1.74 ns |
| `ss_125C_4v50` | **+3.390 ns** | **0.0** | +0.88 ns |

The `3v00` control reproduces the flow's post-PnR −12.899 ns / −1175.1 ns to
0.011 ns (WNS) / ~0.8 % (TNS) — harness faithful. At `ss_125C_4v50` the same
placed-and-routed netlist meets 32 MHz setup outright, +3.39 ns, zero
violating endpoints. Consistent with the prior finding on predecessor
netlists (`project_vdd_closes_ss_timing`: +0.52 / +1.17 / +2.70 ns at
jobs 2201 / B1 / 5200).

Caveats: (a) STA liberty swap of the 3.0 V-optimised netlist, **not** a
re-P&R targeting 4.5 V — a bare 4.5 V-targeted run under-drives to ≈ −7…−8 ns
without a ~9 ns resizer setup margin (`area-reduction-roadmap.md` "RAISE SS
ONLY"). (b) `ss_125C_4v50` is the only PDK SS corner above `3v00` (others:
`1v62`, `3v00`) — there is no `3v60` / lower-`T_j` liberty, so a smaller rail
bump cannot be signed off, only interpolated. (c) The core stdcell library
`gf180mcu_fd_sc_mcu7t5v0` is 5 V-designed ("5v0") run under-voltage at 3.0 V,
so 4.5 V is within its device ratings; the IO ring and the external
SX1257 (3.9 V abs-max) / APS6404L (4.0 V) / RPi interfaces stay on a
separate 3.3 V rail — dual-rail, Open Risks #27. (d) Hold WNS above is with
the slow (`max`) SPEF, not the true fast/min-RC corner; a proper hold
re-check at the raised rail is still owed (Open Risks #41/#54), though the
flow hold signoff is already clean at 3.3 V (below).
Job log: `/srv/eda/logs/timothyn-dev/job-5742.o`.

Hold is met at the three **flow** STA corners (`nom_tt`, `max_ss`, `max_ff`).
None is a min-RC fast corner, so that is not the true hold sign-off; the real
fast/hold corner is checked out of flow — standalone OpenROAD STA on this
run's routed ODB + min-RC SPEF + `ff_n40C_3v60` liberty (job 5687): **worst
hold slack +0.12 ns, hold TNS 0.00**. `STA_CORNERS` cannot host `min_ff`
directly (Open Risks #41/#54).

## Known gaps (carried, not signed off)

- **SS setup WNS/TNS** at `max_ss_125C_3v00` (above) — the #1/#40 voltage
  problem; pursued as a waiver. This netlist meets SS setup outright at
  `ss_125C_4v50` (+3.39 ns, job 5742 — see "Post-P&R timing" above).
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
| `reports/drc/`, `reports/lvs/`, `reports/irdrop/` | Flow signoff reports (base streamout / DEF) |
| `reports/bridged_macro_lvs/` | Netgen LVS of the **bridged** GDS vs `pnl/` (job 5732) — match uniquely |
| `metrics.json`, `metrics.csv` | Full flow metrics |
| `render/trouper_top.png` | Layout render |

Regenerable `spef/`, `sdf/`, `odb/`, `mag/`, `mag_gds/`, `klayout_gds/`
outputs stay with the P&R run on NFS. `gds/` and `def/` are ordinary Git
blobs, not Git LFS objects.
