# DRV repair-margin sweep — 2026-09-03

**Status: SUPERSEDED — do NOT apply the recommended change.** The re-verification
run (2026-09-04, jobs 5527/5528/5529, see the section at the bottom) found the
GRT-margin lever is **dead on the merged netlist**: it no longer clears the
nom_tt DRV and slightly regresses max_ff / SS DRV. `trouper_top_drvp1.json` and
`trouper_top_drvp4.json` should be retired. The 2026-09-03 result below is kept
for the mechanism write-up only.

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

---

## Re-verification against the merged netlist — 2026-09-04 (jobs 5527/5528/5529)

Run on `main` @ `78b4a33` — i.e. after the Grouper-boundary removal, the
`rtl/open-risk-fixes` merge (#61–68), and #69/#70 (PSRAM QPI pad relaunch +
two-stage IQ capture). All three full A40 P&R, canonical flow, `--project
lora-mimo`, DRC/LVS/antenna **0** on all.

| Job | Variant | GRT margin | nom_tt slew/cap | max_ff slew/cap | SS slew/cap | SS WNS | SS TNS | cells |
|---|---|---|---|---|---|---|---|---|
| **5527** | base | 65 | **2 / 2** | 4 / 2 | 9 / 3 | −14.44 | −1008.7 | 127 200 |
| 5528 | drvp1 | 50 | 2 / 2 | 6 / 2 | 13 / 4 | −13.48 | −1121.8 | 127 204 |
| 5529 | drvp4 | 40 | 2 / 2 | 6 / 2 | 13 / 4 | −13.48 | −1121.8 | 127 204 |

### Findings

1. **The GRT-margin lever no longer works.** nom_tt DRV stays at 2/2 for every
   value tried. Pre-merge (job 5491) GRT-50 drove it to 0/0 — a strict win.
   Post-merge it clears nothing and regresses max_ff (4→6) and SS (9/3→13/4),
   plus SS TNS −1009 → −1122. **Retire `trouper_top_drvp1.json` /
   `trouper_top_drvp4.json` and this doc's "Recommended change".**
2. **GRT 50 and GRT 40 produced a bit-identical netlist** (5528 ≡ 5529: same
   cells, WNS, TNS, DRV). The post-GRT repair is saturated — no headroom left
   in that knob.
3. **Job 5527 (base) reproduces the promoted `final/` (job 5511) byte-for-byte**
   — SS WNS −14.436, TNS −1008.73, 127 200 cells, 68.7 % util, DRV 9/3
   identical. There is **no regression** from this work; the −276 SS TNS in the
   2026-09-03 baseline (job 5469) is not comparable — 5469 predates all of the
   merges above.
4. **The residual nom_tt DRV is two specific gates, unchanged across all runs:**
   `_39367_` (`nor4_1`, max-slew −0.30 ns *and* max-cap −0.009 pF at GRT-50) and
   `_39500_` (`oai221_1`, max-cap −0.005 pF). Both sit in the `reg_bank`
   W-shadow readback / `u_psram.dbg_buf` debug-probe mux cone — wide fan-in
   combinational logic, **not on a timing path** (nom_tt WNS +3.3 ns). GRT-50
   improved the dominant `_39367_` slew slack (−1.36 → −0.30 ns) but did not
   close it and nudged the marginal `_39500_` cap further over.
5. **SS critical-path structure (job 5527, 246 setup violators):** dominated by
   high-fanout control nets, not deep logic —
   `u_pcfsm.packet_active_ps` on **186 / 246** paths, `sc_lock` on 73,
   `u_psram.sub[3]` on 72. `sd_remod` owns the numerically worst single path
   (`rb_remod_backoff_shift[1] → IRQ_OUT_OUT`, −14.44 ns, through the DBG1/IRQ
   shared-pad debug mux) plus a ~16-path `u_remod.s2_i` integrator-ripple
   cluster at −11.3 ns, but is a minority of the count. SS −14 ns at 3.0 V is
   the known voltage problem (closes at ~4.5 V), not a P&R-knob target.

### Actions taken

- `pnr_32m_scoped_v25_b6_signoff.sdc` v31: `set_false_path` on the two-pin
  digital debug-probe pad paths (`DBG0_OUT` wholesale; the debug side of
  `IRQ_OUT_OUT` scoped through `rb_dbg_ctrl1*` / `rb_remod_backoff_shift*`,
  leaving the functional `rb_irq_out_sticky → IRQ_OUT_OUT` interrupt arc timed).
  Drops the −14.44 ns worst path and the `DBG0_OUT` −6.31 ns sibling off the SS
  report — both are logic-analyser observability, not synchronous interfaces.
- `trouper_top_drvp1.json` / `trouper_top_drvp4.json`: deleted (rejected — the
  GRT-margin lever this doc originally recommended).

### v31 overlaps Open Risk #41 — reconciled 2026-09-04 (job 5534)

Open Risk #41's exit run (job 5530, `RCX_RULESETS` min_ff override, **no SDC
change**) independently produces the **exact same** SS report as v31: SS WNS
−11.343569959984231, 245 setup violators, `DBG0_OUT` clear, one
`packet_active_ps → IRQ_OUT_OUT` residual at −11.25. Both changes clear the
same −14.44 ns `rb_remod_backoff_shift → IRQ_OUT_OUT` debug arc by different
mechanisms (#41: honest re-extraction re-times it; v31: excluded from the
report), landing on the same `u_remod.s2_i` integrator-ripple floor either way
— **the −14.44 → −11.34 SS-WNS improvement is not v31's; #41 already banked
it.**

Job 5534 (`trouper_top_minff_rcx.json` — #41's RCX override *plus* v31, via
the shared signoff SDC — **fresh full P&R**, not a re-STA of job 5527's
netlist) confirms the two are compatible and the −11.34 floor is deterministic,
not repair-lottery: SS WNS −11.343569959984231, bit-identical to jobs 5530 and
5531 to 15 significant figures. Route DRC 0 (159→…→0 across iterations), no
GRT-0116/DRT-1231/DRT-0073, DRC/LVS/XOR/antenna 0, hold MET all corners, and
#41's RCX deck additionally clears ff DRV (slew 4→0, cap 2→1) — which v31
alone does not touch. **Decision: keep v31 anyway** (debug pads have no
business being timed, and it guards future `DBG_CTRL` selections), fold #41's
`RCX_RULESETS` into `src/config/trouper_top.json` separately when #41 is
adopted. Caveat: all four jobs (5527/5528/5529/5530/5531/5534) share one
seed-deterministic routed netlist — LibreLane P&R here doesn't vary with these
config deltas, so this does not probe placement-seed robustness of the −11.34
floor, only its config-independence.
