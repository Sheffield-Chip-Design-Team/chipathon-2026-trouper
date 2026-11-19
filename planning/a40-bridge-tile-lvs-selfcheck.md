# A40 PDN-bridge + padframe LVS self-check (pre-integration)

**Purpose.** The 12 A40 PDN bridges (`tools/build_a40_pdn_bridges.py`) are
inserted into `final/gds/trouper_top.gds` *after* LibreLane, so the flow's
Netgen LVS never sees them (`final/README.md`: "LVS runs on the base streamout").
The bridges also only make sense in the full tile — they land on the
`SSCS_2026_01` padring's VDD/VSS straps, which are not in the Trouper macro at
all. Running our own LVS-class check on the **assembled tile with the bridged
A40 swapped in**, before handing off, catches any bridge-introduced short or
open ourselves and reduces the integrator's triage load. Integrator-owned
assembled-die LVS still happens; this is a pre-flight, not a replacement (see
Open Risk #53).

Two phases: (1) a fast label-driven connectivity trace of the A40 ↔ padring
power seam; (2) a full KLayout `run_lvs.py` of the A40-only tile.

Working tree (NFS, not git): `/srv/eda/designs/timothyn-dev/SSCS_2026/a40_lvs_selfcheck/`
— `swap_a40.py`, `xor_check.py`, `seam_trace.py`, `run_seam*.sh`, staged
`trouper_top_job5682_bridged.gds`, and the JSON reports.

---

## Inputs

| | |
|---|---|
| Tile | `SSCS_2026` snapshot `2026-09-06T0001Z` (v6) `gds/SSCS_2026_01.gds`, md5 `489d8741550715f64275c8ef7d3a8540`, dbu 5 nm, 2935×2935 µm |
| Tile contents | `SSCS_2026_01_padring` + 4 hardened blocks: **A40** = `A40_trouper_top` (ours), `A09_BV`, `A30_qspi_chip_top`, `B18_Probton` |
| A40 placement | instance disp (350, 1475) µm, mag 1.0, rot 0 → bbox x[349,2025] y[1475,2586] µm (NW quadrant) |
| A40 supply pads | N `gf180mcu_fd_io__dvdd` x≈1680–1755 ; W `gf180mcu_fd_io__dvss` y≈1380–1555 (matches VDD-bridges-go-north, VSS-bridges-go-west) |
| Bridged A40 | `final/gds/trouper_top.gds` = P&R job 5682 streamout + 12 bridges, md5 `c308505a425acdce2e6704273c5c524a`, dbu 1 nm |
| Swapped tile | `SSCS_2026_01_a40j5682.gds`, md5 `20764ba4b0ccf589ebcf75a2b47ebeb8` |

The tile carries per-net metal **text labels**: `A40_VDD`/`A40_VSS` (+ per-block
`A09_VDD` …) on M2 (36/10) and M5 (81/10); the A40-internal core PDN is labelled
`VDD`/`VSS` on M3/M4 (42/10, 46/10); IO ring is `DVDD`/`DVSS`; padframe power
slots are `N14`/`E11`/`E12`/`W11`/`W12`. This is what makes a label-driven trace
possible without a reference netlist.

---

## Phase 1 — power-seam connectivity trace — **PASS** (2026-09-06)

Jobs: swap + XOR **5714**, connectivity trace **5719** (`--project SSCS_2026`,
KLayout 0.30.8, `hpretl/iic-osic-tools:chipathon26`).

### Method
`swap_a40.py` re-points the single `A40_trouper_top` instance at the bridged
macro (imported cells prefixed `A40_J5682__`, placement preserved via mag 0.2:
1 nm macro into 5 nm tile), prunes the original A40 cell.

`xor_check.py` — per-routing-layer XOR of swapped vs original tile, split by the
A40 box + halo (−60 µm sides, +200 µm north).

`seam_trace.py` — KLayout `LayoutToNetlist` connectivity extraction over the
whole tile: polygons `contact/M1..M5 + V1..V4` (datatype 0), `connect` chain
`cont‑m1‑v1‑m2‑v2‑m3‑v3‑m4‑v4‑m5`, net names attached from text layers
36/10 · 42/10 · 46/10 · 81/10. Nets are then resolved by `probe_net` at label
coordinates.

### Result

**XOR (job 5714):** every changed polygon on every layer
(cont/m1/v1/m2/v2/m3/v3/m4/v4/m5) lies inside the A40 box+halo — **0 polygons
changed anywhere else on the die**. The swap is geometrically clean.

**Connectivity (job 5719) — 12/12 scored checks PASS:**

| Check | Meaning |
|---|---|
| A40 core `VDD` (label inside A40) == chip `A40_VDD` net — one extracted net | **no VDD open** at the seam |
| A40 core `VSS` == chip shared VSS net (`A09/A30/A40/B18_VSS` merged) | **no VSS open** |
| VDD net id ≠ VSS net id | **no rail short** |
| VDD net label set = `{A40_VDD, VDD, DVDD, N14}` (power + power-slot only) | nothing foreign merged into VDD |
| VSS net label set = `{A40_VSS, A09_VSS, A30_VSS, B18_VSS, VSS, DVSS, E11, E12, W11, W12}` | nothing foreign merged into VSS |
| all 6 VDD bridge stacks: M2 foot **and** M5 top both resolve to `A40_VDD` | every VDD bridge electrically integral end-to-end |
| all 6 VSS bridge stacks: M2 foot **and** M4 top both resolve to the VSS net | every VSS bridge electrically integral end-to-end |
| 25 `A40_<signal>` pad nets vs VDD / VSS | **no bridge/PDN-to-signal short** |

Bridge stack centres used (tile µm): VDD x =
1686.11 / 1698.885 / 1710.735 / 1724.265 / 1736.115 / 1748.89 at via-y 2573.18;
VSS via-x 353.62 at y =
1486.11 / 1498.885 / 1510.735 / 1524.265 / 1536.115 / 1548.89.
(map: tile µm = 350 + macro-nm/1000 in x, 1475 + macro-nm/1000 in y.)

### Not scored (documented artifacts)
* `shapes_of_net` flattened to a 2-D M2..M5 region reports 10828 VDD/VSS
  "overlaps" and every dvdd/dvss pad as touching VSS. Artifact: VSS extracts as
  one die-wide common-ground region, so a VSS-on-M2 strap crossing a VDD-on-M4
  strap is a 2-D overlap without the metals touching. `probe_net` identity + the
  label census are the authoritative short test and are both clean.
* Two hard-coded single-point pad probes land on the perimeter VSS ring near the
  A40 edge — kept as `(legacy)` prints only.

### Bottom line
The 12 bridges add no short and no open at the A40 ↔ padring seam on the v6
tile, and the swap perturbs nothing outside A40.

---

## Phase 2 — full KLayout LVS of the A40-only tile — *infra done; not a clean match; parked as integrator scope*

**Outcome 2026-09-07 (jobs 5723 cancelled, 5724 / 5727 done):** the whole
machinery works — prune → A40 upper-metal abstract → `blank_circuit`'d GF180
deck → `run_lvs.py`-equivalent invocation. With A40 abstracted the run is **~25 s**
(job 5724 deep/simplify/combine/purge; job 5727 with those off). Both report
**`ERROR : Netlists don't match`**.

**The mismatch is structural noise, not seam findings.** The source SPICE is a
literal transcription of the integrator's `SSCS_2026_01.v` (77-pin top, 577-pin
padring, 552 IO-cell `X` lines); KLayout's extraction produces a *canonicalised*
netlist that diverges from it in ways unrelated to the bridges:
* top-level pin discovery — extracted `SSCS_2026_01` came back with 3 pins
  (`top_lvl_pins=true`) / a different set (`false`), vs 77 in the source;
* IO-cell subckt pin **order** — extracted `bi_24t` = `CS PU PD IE SL A OE Y VDD
  DVSS DVDD PAD VSS` vs PDK `.spice` `A CS DVDD DVSS IE OE PAD PD PU SL VDD VSS Y`;
* fill / decap cells — extracted `fill5` = `VSS VDD` (2 pins) vs PDK 4; `dvdd` = 2
  vs 3 — rails that float in isolation get reduced;
* the 3 pruned blocks' padframe slots dangle on the layout side but are still
  wired in the source.

Reaching a genuine "match uniquely" from here is real LVS bring-up — iterate the
source-netlist construction, reconcile pin sets, model the fills, handle the
pruned slots — several more rounds, and it re-verifies the **padring** (the
integrator's IP), not the bridges. **Parked.** The assembled-die LVS is
integrator-owned (Open Risk #53); phase 1 already answers the bridge shorts/opens
question. Infra + artifacts kept under `a40_lvs_selfcheck/` (`prune_tile.py`,
`v2spice.py`, `abstract_a40.py`, `run_tile_lvs*.sh`, `lvsdb_summary.py`,
`src_a40only.spice`, `a40abs*.lvsdb`, `a40abs*_extracted.cir`) for whoever picks
it up.

## Bridged-`trouper_top` macro LVS — **PASS** (job 5732, 2026-09-07)

The flow's Netgen LVS extracts from the **DEF** (`MAGIC_EXT_USE_GDS=0`), so the
post-flow bridges are invisible to it. Re-ran the extraction against the
**bridged GDS** (`final/gds/trouper_top.gds`, md5 `c308505a…`):

* self-contained Magic script (`reports/bridged_macro_lvs/extract_bridged.tcl`):
  `gds read` the bridged GDS, `readspice` the SC library for port order, force
  every `gf180mcu_fd_sc_mcu7t5v0__*` cell to `property LEFview true` (LEF
  abstract → top-level-interconnect extraction, same class as the flow LVS),
  `extract` / `ext2spice lvs`;
* Netgen `-blackbox` vs `final/pnl/trouper_top.pnl.v` + the SC spice — the
  verbatim LibreLane step-70 `lvs_script.lvs` shape.

**Result: `Circuits match uniquely`** — Circuit 1 (bridged layout) and Circuit 2
(netlist) each **39836 devices / 39823 nets**, identical; `VDD`, `VSS` and every
signal pin match L↔R; "Device classes trouper_top and trouper_top are
equivalent"; 7 disconnected pins (benign tie/fill, same as the base-flow run).

**What this proves, precisely.** The extracted `X`/`R`/`C` line set is
byte-identical to the base-DEF extraction (**127081 lines each, 0 lines unique
to either side**) — the 12 bridges add *zero* connectivity: redundant metal on
nets already joined by the ring (VDD↔VDD, VSS↔VSS). That is the correct
signature of a healthy bridge, and it excludes:
* a **short** — a bridge touching a signal or the opposite rail would *merge*
  two nets → net/device-count divergence → Netgen "do not match";
* a **stray net** — an isolated fragment would add a node → count delta
  (and XOR job 5714 already confirmed only the 12 deterministic stacks were added).
It does **not** independently prove the bridges *connect* — a non-landing bridge
also adds nothing, since the macro's rings are already continuous. The connection
side is job 5719 (tile seam: all 12 stacks probed on-net at M2 foot **and**
M5/M4 top) + the routed-DEF ring-merge check in `final/README`.

**Negative control (job 5733) — the harness has teeth.** A 0.5 × 45 µm M1 box
painted over the core (crossing several VDD/VSS follow-pin rails) run through the
*same* extract+LVS: Magic prints `Ports "VSS" and "VDD" are electrically shorted`
×18, the extracted net count drops 39823 → 39821, Netgen reports
`Netlists do not match / Top level cell failed pin matching`. So a real short in
the bridged GDS is caught — Magic warns, counts diverge, LVS fails — and 5732's
clean pass on the actual bridged GDS is therefore meaningful.

Report + repro: `reports/bridged_macro_lvs/` — `lvs.netgen.rpt` / `.json`,
`lvs_script.lvs`, `extract_bridged.tcl`, `run_bridged_lvs.sh`, and the negative
control `negctl_lvs.netgen.rpt` / `negctl_netgen.log` / `inject_short.py` /
`run_negctl.sh`. Staging tree:
`/srv/eda/designs/timothyn-dev/lora-mimo/pd/bridged_lvs/`.

---

### Coverage summary

| Question | Check | Verdict |
|---|---|---|
| Bridge **short** / stray net inside `trouper_top` | Netgen LVS, bridged GDS (job 5732) + negative control (5733) | **none** — match uniquely, harness proven to catch a real short |
| Bridge geometry DRC-clean | KLayout 63-table, bridged GDS (job 5684) | **63/63, 0** |
| Bridges short/open at the **A40 ↔ padring seam** | KLayout connectivity trace, v6 tile (job 5719) | **PASS** — 12/12 |
| Swap disturbs nothing outside A40 | per-layer XOR (job 5714) | **0 polys** |
| Full device LVS of the assembled tile | — | integrator scope (Open Risk #53); infra parked |

---
### (historical) original phase-2 plan / build notes

**Built (all in `a40_lvs_selfcheck/`):**
* `prune_tile.py` (job 5720) → `SSCS_2026_01_a40only.gds`
  md5 `1175e2e6097e7e0eb24c17eb54550ad6` — A09_BV / A30_qspi_chip_top /
  B18_Probton instances + cell trees removed; `PADRING` + `A40_J5682__trouper_top`
  kept. Pruned blocks' padframe slots stay (their core nets dangle — filter).
* `v2spice.py` → `src_a40only.spice`: `.SUBCKT SSCS_2026_01` = `X_A40_PROJECT`
  (159 pins, black box) + `X_PADRING` (577 pins); `.SUBCKT SSCS_2026_01_padring`
  = 552 IO-cell `X` lines (`bi_t`×31, `bi_24t`×13, `in_c`×16, `in_s`×9,
  `asig_5p0`×11, `dvdd`×4, `dvss`×4, `cor`×4, `brk5`×30, `fill5`×430) in PDK
  subckt pin order; `.include` `gf180mcu_fd_io.spice`. All connections named in
  the source `.v` — no positional parsing. Padring power nets are `N14`(VDD-ish) /
  `E11`(VSS-ish) etc., matching the phase-1 label census.
* `run_tile_lvs.sh` (job 5723): copies the PDK `lvs/` deck to a writable dir and
  inserts `netlist.blank_circuit / schematic.blank_circuit("A40_J5682__trouper_top")`
  immediately before `result = compare` (the GF180 deck + `run_lvs.py` expose no
  blackbox flag). Invokes `klayout -b -r <patched>/gf180mcu.lvs` directly with
  variant-D switches (`metal_top=11K mim_option=B metal_level=5LM poly_res=1K
  mim_cap=2`), source subckt renamed `A40_trouper_top`→`A40_J5682__trouper_top`
  to align with the GDS cell name.

**Expected residue** to filter, not chase: the 3 pruned blocks' padframe slots
unconnected; asig `FLOAT_VDD_*` nets. **Signal:** zero shorts on `N14`/`E11`/VDD/
VSS/bridge nets; A40 power continuous bridge-landing → padring strap → dvdd/dvss.

Deck: `/foss/pdks/gf180mcuD/libs.tech/klayout/tech/lvs/gf180mcu.lvs` (+ `run_lvs.py`);
`netgen` + `gf180mcuD_setup.tcl` fallback.

**Risk / open:** black-box hard-macro LVS in a partial tile is genuinely
integrator-flow territory — `blank_circuit` on both sides is the key trick; if
the deep extraction of the full A40 interior is too slow / the compare is
dominated by pruned-block noise, the tractable substitute is LVS of the
**bridged `trouper_top` macro alone** vs its netlist (pnr-post step 68+70 with
the bridged GDS instead of the base streamout) — closes the `final/README`
"LVS on base streamout" gap in ~1 job.

---

## Reproduce

```
# under --project SSCS_2026 on homelab-sge
bash /foss/designs/a40_lvs_selfcheck/run_seam.sh        # full: swap + XOR + trace
bash /foss/designs/a40_lvs_selfcheck/run_seam_only.sh   # trace only vs staged swapped GDS
```

**Staleness key:** all of this is against bridged-A40 md5 `c308505a…` and tile
md5 `489d8741…`. A new P&R, a re-run of `build_a40_pdn_bridges.py`, or a new
tile snapshot invalidates it — re-run.
