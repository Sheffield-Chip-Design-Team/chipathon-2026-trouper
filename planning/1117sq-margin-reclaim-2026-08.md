# 1117.5×1117.5 square die — margin reclaim reopens NR=4 (2026-08-19)

Records why the 1117.5×1117.5 µm square die target (Open Risks #46, `planning/Pinout.md`)
looked like a hard NR=4 dead-end and then wasn't: a LibreLane floorplan default was quietly
costing ~4% of the die, and reclaiming it turned a placement/routing failure into a clean
physical signoff with only ordinary timing work left. Also records that a 5V-core retry on
top of the fix does NOT help, closing that lever for this die size.

**Related:** [Pinout](Pinout.md), [Open Risks](Open%20Risks.md) #46,
`planning/nr3-fallback-2026-08.md`, `planning/area-reduction-roadmap.md`.

---

## 1. Baseline: NR=4 fails at 1117.5² with default floorplan margins

Job 4480, config `rtl-test/ol_trouper_top/config_1117sq.json` (die `0 0 1117.5 1117.5`,
`PL_TARGET_DENSITY_PCT: 88`, default `LEFT/RIGHT/TOP/BOTTOM_MARGIN_MULT`), rebalanced pin
order `io_placement_1117sq.cfg` (4-way-balanced S/W/E/N split — the existing
`io_placement_bl.cfg`'s 23/8/16/12 split assumed the long south edge of the 1200×1100
rectangle, which a square die doesn't have):

```
IFP-0104  Effective utilization:        0.809   (raw synth cell area / core area)
GPL-0302  Target density 0.88 too low for available free area
          -> auto-escalated to 0.93 just to converge global placement
GPL-1014  Final placement area: 1,080,694 um^2
DPL-0036  Detailed placement failed (during CTS) -- 15 instances couldn't legalize
```

Fails one stage *before* the `GRT-0116` global-routing congestion wall that kills a
default-margin 1100×1100 rectangle (see `planning/area-reduction-roadmap.md` §9 /
`project_1100_target_not_reachable_via_rtl` memory). At face value this reads as "no known
lever reaches this die size" — consistent with the standing 2026-08-05 verdict that RTL
cuts and voltage both fail to close 1100×1100.

## 2. Root cause: the die↔core gap is a LibreLane default, not a PDK/DRC constraint

Reading the actual `initialize_floorplan` call from job 4377's floorplan log (a known-good
1200×1100 signoff run) surfaced the real mechanism:

```
+ initialize_floorplan -site GF018hv5v_mcu_sc7 -die_area 0 0 1200 1100 \
    -core_area 6.72 15.68 1193.28 1084.32
```

Core is inset from the die edge by **6.72 µm (X)** and **15.68 µm (Y)** on every side. That
inset is not a PDK edge-clearance rule or I/O pin-length requirement — it is exactly
`LEFT/RIGHT_MARGIN_MULT` (default **12**) and `TOP/BOTTOM_MARGIN_MULT` (default **4**)
multiplied by the standard-cell site pitch (`gf180mcu_fd_sc_mcu7t5v0`: 0.56 µm wide ×
3.92 µm tall, 7-track site):

```
12 x 0.56 = 6.72 um   (L/R)
 4 x 3.92 = 15.68 um  (T/B)
```

At 1117.5×1117.5 this ring is **50,300 µm² — 4.0% of the die** — silently unavailable to
place into, with no override in any of this project's existing configs (`CORE_AREA` was
never set, so the margin-mult defaults always applied).

## 3. Margin reclaimed → NR=4 routes clean

Job 4484, config `rtl-test/ol_trouper_top/config_1117sq_maxarea.json` — identical to job
4480's config except `LEFT/RIGHT/TOP/BOTTOM_MARGIN_MULT` all set to **1** (the minimum),
reclaiming the ring:

| | job 4480 (default margins) | job 4484 (margin=1) |
|---|---|---|
| Core area | 1,198,507 µm² | 1,238,135 µm² |
| Forced placement util | 90.2%→93% (auto-escalated) | 89.5% |
| Detailed routing | never reached (`DPL-0036` at CTS) | **completed** |
| Magic DRC | — | **0 errors** |
| LVS | — | **clean** (0 across every check) |
| WNS `nom_tt_025C_3v30` | — | **−4.10 ns** |
| WNS `max_ss_125C_3v00` | — | −56.66 ns |
| WNS `max_ff_n40C_3v60` | — | 0.00 ns (meets) |

Job 4484 is a **complete physical signoff pass** — routing, DRC, and LVS all clean. It only
exits nonzero because LibreLane's deferred-error check hard-stops on *any* setup violation,
including the nominal-TT corner. The critical path (`56-openroad-stapostpnr/nom_tt.../max.rpt`)
is `IQ_DATA_Q_0` (input port) through CIC-comb combinational logic into a flop — the
decimator front-end path, the same *class* of path this project already closes at 1200×1100
via MCP/pacing (see `project_ss_decimator_pipeline` memory). `max_ss_125C_3v00`'s −56.66 ns
is the same voltage-bound SS gap every config in this project carries (Open Risks #1), not a
new problem introduced by the smaller die.

**This reverses the framing of Open Risks #46's original writeup: NR=4 is not structurally
blocked at 1117.5×1117.5 — the die↔core margin default was.** Reclaiming it converts a
routability dead-end into an ordinary timing-closure task.

## 4. A same-day parallel probe: +50 µm instead of margin reclaim

Job 4485, config `config_1167sq.json` — same pin order and 88% density target as job 4480,
die grown to **1167.5×1167.5** (+50 µm/side, default margins, matching this project's
established 50 µm sweep step size), run in parallel with job 4484 to compare two different
ways of buying back area. It failed differently:

```
DRT-1231  Pin clkbuf_2_1_0_IQ_CLK_regs/I does not have access point
          (detail routing, ~30% complete)
```

This is the exact brittle-`IQ_CLK`-clkbuf-pin-access failure already on record in
`planning/area-reduction-roadmap.md` (the 1340×1100/1300×1100 rectangle sweep), which has a
known fix there (`CTS_APPLY_NDR: "none"`) — not carried into this run, so untested in
combination. Growing the die without also touching margins does not automatically help;
margin reclaim on the *smaller* 1117.5² die outperformed a 50 µm larger die with default
margins.

## 5. 5V-core does not help, even with the margin fixed

Job 4486, config `config_1117sq_maxarea_5vrail.json` — identical to job 4484 (margin=1,
88% density, same pin order/SDC) except `DEFAULT_CORNER`/`STA_CORNERS`/`LIB` swapped to the
project's established 5V-rail set (`tt_5v00` / `ss_4v50` / `ff_5v50`, matching
`config_5vrail_1550.json`'s pattern):

```
GPL-0302  Target density 0.88 too low for available free area (same as always)
CTS       completed clean (unlike the earlier default-margin 1100x1100 5V test, which
          died right at CTS legalization)
Step 37   OpenROAD.ResizerTimingPostCTS -> DPL-0036 (couldn't legalize the buffers the
          5V timing model needs inserted post-CTS)
```

Gets further than the 2026-08-05 5V test (`project_1100_target_not_reachable_via_rtl`
memory) — that one died directly at CTS legalization on the old default-margin floorplan;
this one clears placement and CTS, and only breaks when the post-CTS resizer needs more
buffering than 3.3V does and there's no spare density left to legalize it into, even after
the margin reclaim. **Confirms and extends the standing verdict that 5V does not lower the
legalization floor for this cell count — it only relocates where the flow runs out of room.**

## Bottom line

| Path | Status |
|---|---|
| NR=4, 1117.5², default margins | **Fails** — `DPL-0036` |
| NR=4, 1117.5², margins reclaimed | **Clean physical signoff** (DRC=0/LVS=0); only −4.1 ns TT / −56.7 ns SS timing open, same closure toolkit as 1200×1100 |
| NR=4, 1117.5², margins reclaimed + 5V | **Fails** — `DPL-0036`, later stage; 5V is not a lever here |
| NR=4, 1167.5² (+50 µm), default margins | **Fails** — `DRT-1231` clkbuf pin-access (known fix untested here) |
| NR=3, 1117.5², default margins | **Passes** with more headroom (84.7% util, SS WNS −11.4 ns) — see `planning/nr3-fallback-2026-08.md` |

Two live paths to a signed-off 1117.5×1117.5 die now exist: **(a)** take job 4484's
margin-reclaimed NR=4 config and apply the same MCP/pacing timing-closure work already used
at 1200×1100, or **(b)** the already-lower-risk NR=3 fallback. Neither is closed out yet —
this doc is evidence both are viable, not a signoff record for either.

**Configs:** `rtl-test/ol_trouper_top/config_1117sq.json` (4480, fails),
`config_1117sq_maxarea.json` (4484, clean signoff), `config_1167sq.json` (4485, fails),
`config_1117sq_maxarea_5vrail.json` (4486, fails). Pin order: `io_placement_1117sq.cfg`.
Scripts: `rtl-test/scripts/run_pnr_1117sq*.sh`, `run_pnr_1167sq.sh`.
