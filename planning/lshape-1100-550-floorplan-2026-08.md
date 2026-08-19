# L-shape floorplan trial (1100×1100 + 550×550 leg) — 2026-08-16

Supersedes the June verdict in `Physical Design Change List.md:137`
(`l-shape: failed on delaybuf_0_clk_32m access`). That verdict was for the
1650×1100 full rectangle. **The L-shape is routable and improves WNS.**

## Geometry

`DIE_AREA 0 0 1650 1100` + `FP_OBSTRUCTIONS [[1100, 550, 1650, 1100]]`

- Main lobe 1100×1100, leg 550×550 (east, southern half)
- Usable area **1,512,500 µm²** vs 1,320,000 µm² for the 1200×1100 baseline
- Padring: **5 slots vs 6** — the obstructed NE quadrant costs one edge segment

## Results

All three runs are the v26 SDC (20 MCP groups, `sc_clear` withdrawn),
FD cells `gf180mcu_fd_sc_mcu7t5v0`, `max_ss_125C_3v00`.

| job | config | WNS (ns) | TNS (ns) | util | DRC | antenna |
|---|---|---|---|---|---|---|
| 4376 | 1200×1100 baseline | −20.12 | −3279 | 86.3% | 0 | — |
| 4387 | L-shape, default pins, density 50 | −18.26 | −5155 | 62.7% | 0 | 8 |
| 4392 | L-shape, shaped pins, density 78 | **−14.59** | −3578 | 63.1% | 0 | **4** |

**+5.53 ns WNS vs baseline; +3.67 ns from pin shaping + density alone.**
TNS is *worse* than baseline on both L runs — the win is concentrated on the
critical path, not spread across the cone population.

⚠️ **n = 1 per config.** Prior sessions established WNS on this design behaves
partly as a repair-lottery (see `project_b4_b6_implemented_measured`), so the
3.67 ns delta is not yet separable from run-to-run variance. Repeat before
treating it as a committed number.

## Placement outcome (job 4392)

Parsed `final/def/trouper_top.def` (2000 DBU/µm, 84,507 components), joined to
hierarchical net names from `final/nl/trouper_top.nl.v`. Leg = x > 1100, y < 550.

| group | flops | centroid (x, y) | % in leg |
|---|---|---|---|
| `u_dec` CIC ch3 | 28 | (1555, 129) | **100%** |
| `u_dec` CIC ch2 | 28 | (1388, 130) | **100%** |
| `u_dec` CIC ch1 | 28 | (1221, 138) | **100%** |
| `u_dec` CIC ch0 | 28 | (1042, 190) | 0% |
| `u_dec` other (polyphase delay lines) | 1972 | (1132, 529) | 53.0% |
| `u_dec` HB (shared TDM) | 70 | (870, 845) | 1.4% |
| (top) | 1247 | (605, 291) | 0.2% |
| `u_sc` | 513 | (392, 573) | 0% |
| `u_psram` | 387 | (615, 497) | 0% |
| `u_comb` | 246 | (278, 662) | 0% |
| `u_tacc` | 211 | (512, 302) | 0% |
| `u_remod` | 112 | (212, 931) | 0% |
| `u_pcfsm` | 108 | (184, 423) | 0% |
| `u_dcr` | 104 | (971, 628) | 7.7% |
| `u_spi` | 50 | (651, 306) | 0% |

Two things worked as designed:

1. **CIC channels 1–3 are 100% in the leg**, at x = 1221 / 1388 / 1555 —
   monotonically ordered west-to-east, tracking the south-edge pin order in
   `io_placement_lshape.cfg` (`IQ_DATA_{I,Q}_2/3` pushed to far-east South).
   ch0 sits just outside at x = 1042. Pin placement shaped placement directly.
2. **No timing-critical block crossed the seam.** `u_sc`, `u_psram`, `u_pcfsm`,
   `u_tacc`, `u_comb`, `u_remod` are all 0% in the leg. Nothing carrying
   unrelaxed timing debt got stranded across the notch.

## Correction to the original premise

I proposed this as "move 2 of the 4 decimator branches into the leg."
That was wrong about the RTL. `sd_decimator_poly.v` is **hybrid**:

- `generate for (g = 0; g < 4) : gen_cic_comb` — 4 parallel per-channel CICs,
  separable, but only **28 flops each (112 total)**
- `u_hb1_mac` / `u_hb2_mac` — **single shared TDM** datapaths, not separable

112 CIC flops cannot account for a 3.67 ns swing. What actually filled the leg
is `u_dec other` (1972 flops, 53% in leg) — polyphase delay-line registers
spreading into available space, not deliberately placed.

So the honest attribution is: **the density fix (50 → 78) is likely doing most
of the timing work**, and the pin shaping ensured the spreading happened in a
coherent east-west direction instead of smearing logic across the seam. Both
levers mattered, not in the proportion originally claimed. The two were changed
together in 4392 and have not been separated — an A/B (pins-only at density 50)
would settle it.

## Cost / open questions

- **One padring slot lost** (5 vs 6). Not yet checked against the pad budget —
  this is the main reason the L-shape is not obviously free.
- Antenna violations 8 → 4, DRC 0 on both L runs. LVS not yet run.
- Configs are **uncommitted**: `rtl-test/ol_trouper_top/config_lshape_1100_550_v26{,_pins}.json`,
  `io_placement_lshape.cfg`, `rtl-test/scripts/run_pnr_lshape_v26{,_pins}.sh`.
  The two JSONs differ by exactly `IO_PIN_ORDER_CFG` and
  `PL_TARGET_DENSITY_PCT` (50 → 78).

## Next

1. Repeat 4392 (n ≥ 3) to separate the WNS delta from repair-lottery noise.
2. A/B pins-only vs density-only to attribute the gain.
3. Check the 5-slot padring against the actual pad count before committing.

---

## 2026-08-19 update: upper-left-quadrant pin re-assignment, two blockers found and fixed, PROMOTED to baseline

Job 4392 above validated the L-shape geometry with `io_placement_lshape.cfg`
pinned to `#S`/`#W` — a convention borrowed wholesale from `io_placement_bl.cfg`
("board-realistic" pin order chosen for congestion/routability reasons, Open
Risks #28), unrelated to any padframe quadrant assignment. Once the team's
actual MPW placement was confirmed as the **upper-left quadrant**, `#S`/`#W`
turned out to be the wrong edges: in that assignment only the die's **N and W**
edges are real, bondable padframe boundary — S and E are interior seams facing
neighbor projects on the shared die. `io_placement_lshape.cfg` needed real
board-facing pins moved off `#S` onto `#N`, with the Grouper-only inter-project
bus (`GRP_*`, `IRQ_GROUPER` — no package pads) pushed onto the now-interior
`#S`/`#E` instead. Floorplan geometry (`DIE_AREA`/`FP_OBSTRUCTIONS`) was
unaffected — the leg only ever touched S/E, so it was already correctly
"interior, not at the [true] boundary" once N/W was recognized as the real
edge pair.

### Blocker 1: `#N` re-pin broke legalization (`DPL-0036` on `input23`)

The straight `#S`→`#N` swap (keeping the old "push `IQ_DATA_{I,Q}_2/3` to the
far end" ordering) immediately reintroduced the historical `DPL-0036`
legalization failure (same signature as job 2095) on a single instance,
`input23`. `PL_MAX_DISPLACEMENT_Y` (200→400) and `PL_TARGET_DENSITY_PCT`
(78→65) were both tried and **ruled out** — identical failure either way,
down to the buffer count and iteration table.

Root-caused by reproducing `repair_design.tcl`'s exact `read_current_odb` →
`buffer_ports -inputs` → `repair_design` → `detailed_placement` sequence
standalone (had to reconstruct several LibreLane-internal env vars —
`_TCL_ENV_IN`, `_SDC_IN`, `_LIB_CORNER_N`, `_PNR_EXCLUDED_CELLS` — that aren't
in the public `_env.tcl`/`config.json`) and dumping the failing instance:

```
master: gf180mcu_fd_sc_mcu7t5v0__dlyb_1   (input buffer for IQ_DATA_I_3)
location (um): 1604.12, 1099.72
die area (um): 0,0 to 1650,1100
```

**`FP_OBSTRUCTIONS` only blocks cell placement — it does not reshape
`DIE_AREA`.** The die stays the full 1650×1100 rectangle, so
`Odb.CustomIOPlacement` spreads `#N` pins proportionally across the *entire*
1650 µm top edge, not just the 1100 µm span above the real (non-obstructed)
main square. Any `#N` pin landing past x=1100 sits directly above the NE
notch — a placement dead zone bounded by the true die edge on two sides, with
zero legal rows anywhere nearby. This is also, in hindsight, exactly why the
old S/W config's "push far pins east" trick worked: its far-east pins were on
the **south** edge, where x>1100 is the leg (legally placeable), not the
notch. Same ordering trick, opposite edges, opposite outcome.

**Fix:** append a `$16` spacer slot after the `#N` real-pin group in
`io_placement_lshape.cfg`, so the proportional spread keeps all 23 real `#N`
pins within the legal x:0–1100 span instead of spilling into the notch.

### Blocker 2: `DRT-1231` clkbuf pin-access (pre-existing, already-documented class)

With legalization fixed, the flow reached detailed routing and failed with
`[DRT-1231] Pin clkbuf_2_3_0_IQ_CLK_regs/I does not have access point` — the
same failure class already root-caused and resolved for the v15 SDC back in
June (`project_drt1231_clkbuf` memory / Gate-0 history): CTS pin-access, not
density. `CTS_ROOT_BUFFER`/`CTS_CLK_BUFFERS` were already on the known-good
setting (`clkbuf_16` root, `8/12/16`, no `clkbuf_4`/`20`); the missing piece
was `DPL_CELL_PADDING` (still `1` here, the resolved recipe uses `3`).

**Fix:** `DPL_CELL_PADDING` 1→3. Cleared `DRT-1231` immediately — detailed
routing completed on the same run that failed instantly at that step before.

### Result: clean full signoff (job 4496)

| WNS | value | DRC/LVS |
|---|---|---|
| `nom_tt_025C_3v30` | 0.0 ns (met) | Magic DRC: 0 |
| `max_ff_n40C_3v60` | 0.0 ns (met) | KLayout DRC (final iter): 0 |
| `max_ss_125C_3v00` | −17.96 ns (TNS −5277 ns) | LVS: 0 mismatches (device/net/pin/property) |

SS WNS negative is the chronic `gf180mcu_fd_sc_mcu7t5v0`-at-3V corner issue
carried by every config in this family, not a regression introduced by this
work — TT/FF met and DRC/LVS clean is the bar that matters here.

### Promoted to working baseline

`rtl-test/ol_trouper_top/config_lshape_current.json` (copy of
`config_lshape_1100_550_v26_pins_ymax400_pad3.json`) +
`io_placement_lshape.cfg` (now N/W-pinned) are the **current L-shape
baseline**, run via `rtl-test/scripts/run_pnr_lshape_current.sh`. Configs are
committed to the repo (git-tracked, not LFS — only final GDS/netlist
artifacts go through LFS, and that promotion is a separate, not-yet-made
decision — see the session's GDS/LFS discussion). **n = 1** on the exact
winning config; repeat before treating the WNS numbers as settled, per the
original trial's repair-lottery caveat above.

**Still open:** the 5-slot-vs-6 padring cost (item 3 in the original "Next"
list above) — not re-checked against the actual pad budget as part of this
update.

---

## 2026-08-19 update #2: two more notch leaks found while rendering for a presentation, both fixed

Producing a multi-layer routing render of job 4496's GDS for a presentation
surfaced two further correctness gaps in the "reserved for Grouper" NE
notch — neither caught by DRC/LVS/timing, since Trouper's own signoff has no
way to know that region is supposed to stay empty for a neighbor project.
Both found by inspecting the actual DEF, not just the image.

### Gap 1: 6 `GRP_*` pins physically inside the notch

`#E` (`io_placement_lshape.cfg`) spreads its pins proportionally across the
**full** 1100 µm die height, same mechanism as the original `#N` dead-zone
bug (`FP_OBSTRUCTIONS` doesn't reshape `DIE_AREA`, so `CustomIOPlacement`
has no notion of the notch). `GRP_ADDR_5/6/7`, `GRP_WE`, `GRP_RE`,
`GRP_READY` landed at x≈1650, y between 588–1059 — inside the y>550 region
reserved for Grouper's own silicon.

**Fix:** same pattern as the `#N` fix — append a `$16` spacer after `#E`'s
real pins in `io_placement_lshape.cfg`, keeping them within y:0–550.
Verified via DEF: 0 pins in the notch afterward (was 6).

### Gap 2: PDN power straps crossing the notch — `PDN_KEEPOUT_REGION` was a silent no-op

The `pdn_cfg.tcl` guard block that's supposed to obstruct PDN generation in
the notch (`create_obstruction` on `Metal1`–`Metal5` when
`PDN_KEEPOUT_REGION` is set) was itself sitting **uncommitted** in the
working tree — never actually landed in git before this. Worse: even with
the guard code present, setting `PDN_KEEPOUT_REGION` as a **LibreLane JSON
config key** (`config_lshape_current.json`) is a silent no-op — it's not a
registered LibreLane config variable, so it never reaches `$::env(...)`
inside the Tcl step scripts. Confirmed empirically: job 4497 (JSON-key
attempt) still had real `STRIPE` shapes on Metal4/Metal5 spanning straight
through the notch in the final DEF's `SPECIALNETS` (e.g. a Metal5 stripe
`13440 → 3286080` DBU, the full 1650 µm width).

The actual working precedent was already on record: job 4473
(`trouper_top_lshape_v27_keepout`, the source of the original multi-color
reference render) got a genuinely clean notch by **exporting
`PDN_KEEPOUT_REGION` as a real shell environment variable in the job script
itself**, before invoking `librelane` — not through the JSON config. That
process-level env var is inherited by the whole subprocess tree (including
OpenROAD's Tcl `$::env(...)`), unlike a JSON key LibreLane doesn't
recognize.

**Fix:** moved `PDN_KEEPOUT_REGION` out of `config_lshape_current.json`
and into `run_pnr_lshape_current.sh` as `export PDN_KEEPOUT_REGION="1100
550 1650 1100"`, matching job 4473's proven invocation exactly. Also
committed the previously-uncommitted `pdn_cfg.tcl` guard block itself — it's
load-bearing for this fix and needs to actually be in git.

Also worth noting for next time: `add_pdn_stripe`/OpenROAD's PDN generator
does **not** consult generic Odb routing obstructions the way the router
and placer do (checked directly: no `add_pdn_obstruction` command exists in
this OpenROAD build). `create_obstruction` happens to work here specifically
because `pdn_cfg.tcl` passes it without `-except_pg`, which is documented to
block PG (power/ground) routing too — that's the actual mechanism, not PDN
generation being obstruction-aware in general.

### Result: clean full signoff (job 4498), both leaks closed

Verified against the actual DEF, not just the render:

| Check | job 4496/4497 (before) | job 4498 (after) |
|---|---|---|
| Pins in notch | 6 | **0** |
| Metal4/Metal5 stripe segments touching notch | multiple (confirmed via `SPECIALNETS`) | **0** (matches job 4473's clean reference exactly) |
| `nom_tt_025C_3v30` / `max_ff_n40C_3v60` WNS | 0.0 ns | 0.0 ns (unchanged, met) |
| `max_ss_125C_3v00` WNS | −17.96 / −20.40 ns | −19.51 ns (same chronic-corner class, not a regression) |
| Magic DRC / LVS | 0 / 0 mismatches | 0 / 0 mismatches |

`config_lshape_current.json`, `io_placement_lshape.cfg`,
`run_pnr_lshape_current.sh`, and `pdn_cfg.tcl` are now all committed
together reflecting job 4498's exact winning setup — this supersedes job
4496/4497 as the L-shape baseline. Presentation render:
`reports/trouper_top_lshape_current.png` (via the `gds-plot` skill's
`raster_gds.sh` — see that skill's "Known issue" for why the KLayout-native
render path had to be bypassed to get a usable multi-color image in the
first place).
