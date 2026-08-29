# Antenna Closure Investigation — trouper_top @ 1675×1110 (2026-08-29)

Record of the antenna-violation investigation on the A40 die-size rebuild. Written
so the ~25 P&R iterations behind it do not have to be repeated.

## Context

The A40 integrator flagged that `main`'s `final/` GDS is 1650×1100 but the padframe
slot (`A40_ACV.def` / `A40_ACV_interface.yaml`) reserves **1675×1110** — the same
root cause as the separately-reported bounding-box complaint. Job **5158** rebuilds
`trouper_top` at 1675×1110 and is signoff-clean on every axis *except* antenna:

| metric | job 5158 |
|---|---|
| die / bbox | 1675×1110, single clean layer-0/0 rect |
| DRC (magic) | 0 |
| XOR | 0 |
| LVS | 0 / 0 |
| hold WNS | 0 (all corners) |
| setup nom_tt / ff | met (+9.9 / +11.8 ns) |
| setup max_ss | −13.52 ns (known voltage-headroom gap) |
| **antenna** | **26 net / 35 pin** |

For reference, `main`'s current `final/` (job **5122**, pre-#47 RTL, 1650×1100,
density 78) ships with **12 antenna net violations**. Zero has never been the
shipped state.

## Constraint

The user's requirement was **"no RTL fix and violations not acceptable"**. Note that
`SYNTH_KEEP_HIERARCHY_MODULES` was later established to be a *config* key, not an RTL
change (see §4) — so it was legitimately in scope — but it did not help.

## 1. Where the violations are

All violators are metal **side-area (transition)** antenna, ratio limit 400. From
`48-openroad-checkantennas-1/reports/antenna_summary.rpt` (job 5158):

| group | count | layers | worst ratio | path |
|---|---|---|---|---|
| `net75` / `output*/I` | 8 | M2/M3/M5 | 4.5× | die-edge output buffers |
| `sc_stat[*]` | 7 | M5 | 1.1–1.4× | sc_detector → reg_bank readback |
| `psram_cur_i0/q0[*]` | 11 | M3/M5 | 1.1–1.2× | psram_buf_ctrl → sc_detector |

All three feed the flattened `_36xxx_` reg_bank/AHB read-decode cone — the same cone
as the max_ss worst path (`_63059_ → _61493_`). PR #47's `trouper_ahb8_adapter` adds
~68 forced die-internal pins, which is why the post-#47 netlist is worse than 5122's
pre-#47 one (26 vs 12).

## 0. RESOLVED — zero antenna, job 5198 (`config_1675_c5_diodepad4.json`)

**`DIODE_PADDING: 4` closes it.** Sections 2–6 below are the investigation that led
here and are kept for the reasoning; the conclusion in §6 that "zero is not reachable
by P&R config" is **superseded and wrong**.

| metric | baseline 5158 | **C5 — job 5198 (ADOPT)** | C3 — job 5196 |
|---|---|---|---|
| **antenna** | 26 / 35 | **0 net / 0 pin** | **0 net / 0 pin** |
| magic DRC | 0 | 0 | 0 |
| XOR | 0 | 0 | 0 |
| LVS | clear | clear | clear |
| hold WNS (all corners) | 0 | 0 | 0 |
| setup nom_tt / ff | met | met | met |
| setup max_ss | −13.52 ns | **−13.15 ns** | −12.69 ns |
| clock skew (max_ss) | — | **0.312 ns** | 0.442 ns |
| die / bbox | 1675×1110 | 1675×1110 | 1675×1110 |

**Root cause:** antenna *repair* was never the problem — inserted diodes were crowding
IQ_CLK clock buffers and stealing their routing pin access, so detailed routing died
with `DRT-0073`/`DRT-1231`. `DIODE_PADDING` was unset (`None`), leaving diodes free to
abut a clock buffer. Setting it fixes the interaction outright.

**Two hypotheses were tested; the intuitive one was wrong.** The failing cell was a
`clkbuf_16` in every early run (5183, 5194, 5195), which suggested the largest buffer's
pin geometry was at fault. C3/C4 therefore dropped `clkbuf_16` from `CTS_CLK_BUFFERS` —
but **C4 (job 5197) then failed on `clkbuf_4_3_0_IQ_CLK_regs/I`, a `clkbuf_12`**, i.e.
the very cell it had downsized to. The failure simply follows the clock tree to whatever
buffer the diodes box in; buffer *size* is irrelevant. Downsizing is the wrong fix, and
it also costs skew (0.442 vs 0.312 ns) for no benefit.

**Adopt C5, not C3:** both reach zero, but C5 leaves the clock tree completely alone,
so there is no drive-strength or skew trade to re-validate, and it has the better skew.
C3's 0.46 ns WNS advantage is within the known repair-lottery spread.

`DPL_CELL_PADDING` is *not* an alternative lever: it is 2, and 3 causes `DPL-0036`
(diodes fail to legalize). `DIODE_PADDING` applies to diode cells only and avoids that.

## 2. Diode repair reaches 8, then dies on a clock buffer (superseded by §0)

Jobs **5165 / 5166 / 5183** produced *byte-identical* repair traces despite differing
`DPL_CELL_PADDING`, which means the outcome is deterministic:

```
GRT: Inserted 67 diodes
GRT: Inserted 8 jumpers for 6 nets
GRT: Inserted 11 diodes          → antenna now 8 net / 10 pin   (from 26/35)
DRT: Inserted 22 diodes          → [DRT-0073] No access point   → FLOW DIES
```

**Antenna repair is not the problem.** 78 GRT-side diodes legalize cleanly and remove
69% of the violations. The flow then fails **8 violations from the finish**, because
one of the final 22 DRT-side diodes cannot be given a routable access point.

This is a diode *placement/access* failure, not a repair-capability failure, and it is
the most promising remaining line of attack. Untried levers that target it directly:

- raise `GRT_ANTENNA_REPAIR_ITERS` so GRT (which legalizes fine) converges further and
  leaves DRT fewer than 22 diodes to place
- raise `GRT_ANTENNA_REPAIR_MARGIN` above 90 for the same reason
- drop `PL_TARGET_DENSITY_PCT` below 65 to give diode placement more room
- identify and locally unblock the specific failing instance (`ANTENNA_473/I` in the
  5186/5188 variants; the clkbuf `clkbuf_0_IQ_CLK_regs` in the GRT-diode variants)

## 3. What was tried and rejected

| # | approach | result |
|---|---|---|
| 5122 | pre-#47 netlist, 1650×1100, density 78 | 12 net — **what main ships** |
| 5158 | 1675×1110, jumper-only, padding 3, density 65 | **26 / 35**, else signoff-clean |
| 5159 | density 78 at 1675×1110 | 35 net, `DRT-1231` clkbuf — proved the **AHB pins**, not die growth, perturb CTS |
| 5165/5166 | GRT+DRT diodes, padding 3 | **8 net**, then `DRT-0073` |
| 5183 | GRT+DRT diodes, padding 2 (lora-mimo's value) | **8 net**, then `DRT-0073` — padding is not the lever |
| 5176/5178 | `DIODE_ON_PORTS: "both"` | not a valid value in this LibreLane; 0 diodes placed, no effect (25–27 net) |
| 5177 | `FP_OBSTRUCTIONS` near clkbuf_2_2 | 27 net — no antenna help *and* WNS −17.2 vs −13.5 |
| 5186/5188 | GRT jumper-only + DRT mixed | GRT: 1866 jumpers → converges; DRT floods **10201 diodes** at once → `DRT-0073` on `ANTENNA_473/I`; ends 26 |
| 5189 | + `*_ANTENNA_REPAIR_ITERS: 10` | wedged: GRT looped `Found 984 violations / Inserted 0 jumpers` (jumper-only cannot fix side-area); killed |
| 5191 | keep-hierarchy, 4 modules | **OpenROAD SIGSEGV** — see §4 |
| 5192 | keep-hierarchy, 2 modules | **38 / 42 — worse**; see §4 |
| — | `RUN_HEURISTIC_DIODE_INSERTION` @ threshold 90 | flooded 31046 diodes → `DPL-0036` (543 unplaceable) |
| — | Metal4 routing cap | failed to run |
| — | GRP-pin consolidation to south | 28 net — worse |

Infrastructure losses (not design failures): jobs **5147, 5162, 5168, 5173, 5175,
5182, 5184, 5186** died on NFS live-mount blips (`DESIGN_DIR ... does not exist`);
`--retry-on-exit` does not help because the flow exits 0 despite the traceback.

## 4. keep_hierarchy — config-only, but it makes antenna WORSE

`SYNTH_KEEP_HIERARCHY_MODULES` is a **LibreLane config key** (confirmed present in the
`chipathon26` image alongside `SYNTH_HIERARCHY_MODE: 'flatten'`). It changes no ports,
logic or state and is invisible to simulation, so **all cocotb and formal results stay
valid bit-for-bit** — it is not an RTL fix.

The theory was that flattening smears the reg_bank/AHB decode cone across the die and
creates the long M5 arms. **The theory is wrong**, measured at 1675×1110 jumper-only:

| run | keep-set | antenna | max_ss WNS | area |
|---|---|---|---|---|
| 5158 | none (flatten) | **26 / 35** | −13.52 ns | 1,102,220 µm² |
| 5192 | `reg_bank` + `trouper_ahb8_adapter` | **38 / 42** | **−12.68 ns** | 1,101,880 µm² |

Flattening gives the router more freedom and produces *shorter* nets than hard module
boundaries. Do not re-propose keep-hierarchy as an antenna lever.

**Worth keeping for a different purpose:** it bought **+0.85 ns of SS WNS at zero area
cost**, DRC 0 / LVS clean. That is a real SS-closure lever if antenna is solved by
other means.

### 4.1 The keep-set is constrained by the SDC — getting it wrong SEGFAULTs OpenROAD

`pnr_32m_scoped_v25_b6.sdc` scopes every multicycle with `-through <net>` using
**flattened** net names. The SDC says so itself:

> *Net names retain hierarchy ('.' separator) after flatten; cell names do not.*

`u_dec.hb2_stream[1]` is a flat net name that merely *contains* a dot. Keeping a module
hierarchical renames its internals, the `-through` lookups fail (**169 × `STA-0361`**;
baseline has 0), and OpenROAD then crashes writing the SDC back out:

```
sta::WriteSdc::writeExceptionThru → sta::sortByPathName → SIGSEGV (signal 11)
at 32-openroad-repairdesignpostgpl        (job 5191, kept sc_detector + psram_buf_ctrl)
```

Modules the SDC reaches **into**, hence off-limits without rewriting the SDC:
`u_dec`, `u_sc`, `u_tacc`, `u_comb` (the `paced_nets` MCP=3 wildcard, line 393),
`u_pcfsm`, `u_psram`. Only **`reg_bank`** and **`trouper_ahb8_adapter`** are safe —
the SDC touches reg_bank solely via top-level `rb_*` wires.

### 4.2 Never keep the decimator hierarchical

Tempting, because `u_dec` has by far the highest toggle rate (full 32 MS/s CIC vs
500 kS/s downstream), so locality would cut dynamic power. **Do not.** It breaks the
`paced_nets` wildcard, and the SDC records what that cost when it silently broke before:

> *v8 BUG: … that pattern matched NOTHING and the MCP=3 was a no-op → the whole design
> ran at honest single-cycle and the decimator HB2 MAC surfaced at SS WNS **−39.97 ns**
> (job 2156).*

A silent 26 ns cliff. The decimator is also not on the critical path and has no antenna
violations, so there is no upside to weigh against it.

## 5. Why the adjacent lora-mimo repo "pnrs cleanly"

`chipathon-2026-lora-mimo/lora-mimo/integration/pd/config_landscape_2235.yaml` uses
`DPL_CELL_PADDING: 2`, mixed (non-jumper-only) GRT+DRT repair,
`DRT_ANTENNA_REPAIR_ITERS: 10`, `DRT_ANTENNA_REPAIR_MARGIN: 10`. Those values were
tried here (5183, 5189) and do not transfer: that design is **2235×2235** with SRAM
macros and far more routing room. Its own config notes the same trap we hit —
*"Job 4770 proved jumper-only leaves 39 violations and stops the flow before DRT."*

## 6. Status and options

Zero antenna is **not reachable through P&R configuration alone** on the post-#47
netlist. The realistic states:

| option | antenna | notes |
|---|---|---|
| **A. Rebuild pre-#47 (5122) netlist at 1675×1110** | ~12 | Matches what `main` ships today, plus the die/bbox fix. `trouper_ahb8_adapter` is unwired ("integration must drive the AHB port only"), so excluding it from the tapeout GDS loses no function; it lands on its own branch. |
| B. Ship job 5158 as-is | 26 / 35 | Die/bbox fixed, everything else signoff-clean, but more violations than the baseline. |
| C. Pursue §2 (close the last 8 via diode placement) | 0 target | The only path to true zero. Unproven but not yet exhausted — the flow currently dies 8 violations from the finish. |

**Recommendation: C first** (it is the only route to zero and the failure is a narrow,
well-localised placement problem), with **A** as the fallback if it does not converge.

## 7. Tooling notes

- The homelab SGE API is now **Bearer-token gated**; bare `curl $HLAB_SGE_URL/api/jobs/<id>`
  returns `{"detail":"Authentication required."}`. This also breaks `hqstat`, which
  prints "No jobs found" while the resource line correctly shows the allocation. Monitor
  jobs via the NFS run dir / `job.log` EXIT marker instead.
- Job stdout logs are capped at ~2 MiB (`job-<id>.o` stops growing), so a full P&R run's
  tail is lost. The per-step run dir on NFS is authoritative.
- Give every job a **unique `$OUT`** name: job 5188 resumed into 5186's stale run dir
  (shared `trouper_1675_pad2_split`) and inflated its step numbering to 73–75.
