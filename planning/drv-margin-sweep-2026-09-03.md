# DRV repair-margin sweep — 2026-09-03

**Status:** finding recorded, change **not yet applied**. The recommended knob
change waits on an incoming RTL merge — re-run the sweep's winner against the
merged netlist before adopting.

## Why

Job 5469 (27-pin A40 P&R) is DRC/LVS/XOR/antenna clean but carries residual DRV:
**7 max-slew / 1 max-cap at nom_tt**, 11 / 2 at SS. The old `final/` signoff
(job 4780) was rejected partly for DRV (1060 / 115 at nom_tt), so *typical-corner
DRV-clean* is effectively an acceptance bar for the P&R review documents.

## Root cause of the residual

The flow's last DRV repair is step 44 `ResizerTimingPostGRT`, which runs on
**global-route *estimated* parasitics**. Detailed routing (46) and RC extraction
(56) happen after, and this LibreLane build has **no post-detailed-route /
post-RCX repair step** (`RepairDesignPostGPL`, `RepairDesign`,
`RepairDesignPostGRT`, `ResizerTimingPostCTS`, `ResizerTimingPostGRT` — all
pre-route). So the 7/1 at nom_tt is the gap between estimated and extracted RC,
with no pass to fix it. The only lever is **pre-route headroom**: repair to a
tighter internal target so the extracted RC still lands under the limit.

## Sweep

All off `src/config/trouper_top.json` (baseline: all four repair margins at 65 %).

| Job | Probe | Change | nom_tt slew/cap | max_ff slew/cap | SS slew/cap | SS WNS | SS TNS | cells | util |
|---|---|---|---|---|---|---|---|---|---|
| 5469 | baseline | — | 7 / 1 | 7 / 1 | 11 / 2 | −11.36 | −276 | 124 399 | 65.73 % |
| **5491** | **drvp1** | **`GRT_DESIGN_REPAIR_MAX_{SLEW,CAP}_PCT` → 50** (pre-GRT stays 65) | **0 / 0** | **0 / 0** | **7 / 1** | **−10.56** | **−268** | 124 350 | 65.70 % |
| 5492 | drvp2 | all four → 50 | 17 / 5 | 40 / 7 | 66 / 17 | −9.81 | −487 | — | — |
| 5489 | drvp3 | all four → 45 | 120 / 15 | 137 / 25 | 282 / 46 | −15.63 | −1762 | — | — |

DRC / LVS / XOR / antenna / router-DRC: **0 on all three** (drvp2/drvp3 route-DRC
repair took many more iterations — 461→50→42 and 132→15→9 vs drvp1's 3→3→2 — but
all converged to 0).

## Conclusions

1. **drvp1 is a strict win**: nom_tt and max_ff DRV → 0/0, SS DRV improved, SS
   WNS/TNS *improved*, 49 fewer cells, util unchanged, all signoff checks 0.
2. **Only the post-GRT margin is a safe lever.** drvp2/drvp3 also tighten the
   **pre-GRT** (`DESIGN_REPAIR_MAX_*_PCT`, applied at `RepairDesignPostGPL` on
   placement-stage RC). That RC is too crude — an aggressive target there dumps
   buffers against bad estimates, bloating placement and forcing the router and
   post-GRT repair to fight it. drvp3's SS TNS is 6.4× worse than baseline.
3. `set_max_transition` / `set_max_capacitance` in the SDC is still off-limits —
   any design-wide value stalls `repair_design` 70+ min (`_comment_drv_closure`).
4. The dominant baseline offender `_45654_` (a min-size `xor3_1` fanning out to 6
   cells) is cleared by drvp1's extra headroom; a synth-buffering hint would be
   the belt-and-braces fix if it ever returns.

## Recommended change (apply after the RTL merge + a re-verification run)

```jsonc
"GRT_DESIGN_REPAIR_MAX_SLEW_PCT": 50,   // was 65
"GRT_DESIGN_REPAIR_MAX_CAP_PCT":  50,   // was 65
// DESIGN_REPAIR_MAX_SLEW_PCT / _CAP_PCT: leave at 65
```

`src/config/trouper_top_drvp1.json` is kept as the ready-to-run variant for that
re-verification. `trouper_top_drvp2.json` / `_drvp3.json` deleted (rejected).
