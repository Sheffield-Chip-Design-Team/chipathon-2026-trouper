# trouper_top Area-Reduction Roadmap

Status: 2026-07-04 (§7 per-block re-measure + ranked Lever-B candidates added). Owner: timothyjabez.

Goal: shrink `trouper_top` from the current **1550 × 1150 µm** SS-closure
floorplan toward the long-stated **1100 × 1100 µm** target, *without* losing the
SS-corner timing closure or DSP precision earned so far.

This document is grounded in a fresh per-module area measurement (Yosys
keep-hierarchy stat against `gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30`, SGE job
2177), not the stale 982K memory figure.

---

## 1. Where the area actually is

Real routed cell area = **973K µm²** (unchanged by the SS pacing/registering
work). All large blocks are single TDM instances (×4 branches folded
internally), so there are no easy multiplicity wins.

| Block | Area µm² | % cells | Character |
|---|---:|---:|---|
| **sd_decimator_poly** (u_dec) | **335K** | **36%** | CIC-3 R=16 14-bit + HB1/HB2 polyphase MAC |
| sc_detector (+ shared mul) | 135K | 14.5% | autocorr; mul already folded to 1 shared 13-bit |
| training_acc | 134K | 14.4% | all-pairs correlator; 2nd mult already halved |
| psram_buf_ctrl | 71K | 7.7% | QSPI + SC-delay + dbg |
| mrc_combiner | 62K | 6.6% | w^H·x |
| sd_remod | 59K | 6.4% | fixed 3rd-order NTF — SQNR-locked, do not touch |
| reg_bank | 40K | 4.3% | 128-reg map |
| packet_ctrl_fsm | 37K | 4.0% | |
| dc_removal | 33K | 3.6% | single instance |
| glue / spi_slave | 23K | 2.4% | |

**Decimator is 36% of the chip but is ALREADY OPTIMIZED — not a remaining area
target.** Per `decimator-hb-area-reduction.md` (2026-06-20, all verified bit-exact
on SGE):
- Storage is ~**50%** of the decimator (~160K µm²; `dffrnq` = 74.6 µm²/flop, 1344
  HB + 672 CIC flops). It is irreducibly flop-based at this size — SRAM-backed
  delay lines were **explored and rejected** (168 B is sub-2-kbit; smallest fitting
  macro is +47% area and bandwidth-bound at single-port).
- Polyphase + 14-bit-CIC fold already banked **−13.8%** (378K→326K), bit-exact.
- **CIC precision is EXHAUSTED.** Width is overflow-locked: N=3, R=16 → max output
  4096 = 2¹² → 14-bit signed is the *bit-exact minimum* (13-bit wraps at the +4096
  full-scale peak; proven against sustained ±full-scale). 14→13 corrupts output;
  14→12 is off by 4×. There is NO CIC precision margin.
- Only untouched lever is **HB tap data 8→7 bit**, but SQNR gate is ≥40 dB with
  ~42 dB measured (~2 dB margin); a bit costs ~6 dB → fails. Not viable.
- Reset-removal on HB lines and AREA-0 synthesis: **both rejected** — each regresses
  SS 9–16 ns for ≤6% area on the high-fanout IQ_CLK domain.

Conclusion: do not spend effort on decimator precision/storage — it is a closed
question. Area must come from elsewhere (below).

---

## 2. The arithmetic that sets the target

**Measured utilisation vs die (2026-06-24, honest-MCP runs, all DRC=0):**

| Die | Area µm² | Placed util | SS WNS (3.0V, unrelaxed) | Pad |
|---|---:|---:|---:|---:|
| 1550×1150 | 1.78 M | **65.4%** | −17.02 (v15c/v15g) | 2–3 |
| 1500×1100 | 1.65 M | **70.4%** | −18.77 (v16c) | 2 |
| **1380×1100 ✅ SIGNED OFF** | **1.52 M** | **76.5%** | **−15.31 (v26/v27)** | **1 or 0** |

- **1380×1100 ROUTES CLEAN at DPL_CELL_PADDING=1 or 0** (v26 job 2214, v27 job 2215,
  2026-06-24): Magic DRC=0, route DRC=0, **LVS match uniquely**, util 76.5%, SS WNS
  −15.31 ns. This is a **15% die shrink** from 1550×1150 with full signoff intact.
- **The 1380 "floor" was a PADDING artifact, not physics.** Earlier 1380 runs failed
  DRT-1231 (clkbuf pin-access) — but those used `DPL_CELL_PADDING=3`, which over-spread
  cells and crowded the IQ_CLK clock buffers. Dropping padding to 1/0 gives the router
  the access points → routes clean. **pad=1 is the pick** (pad=0 identical on every
  metric; pad=1 keeps a hair of margin for free).
- **The "3.0 V shrink trap" is FALSE.** We'd recorded v15f @1380 = −33 ns and concluded
  tighter placement crowds timing-repair buffering so shrink fights timing. WRONG — that
  −33 was the pad=3 buffer-bloat artifact. At pad=1, 1380 is **−15.31 ns, ~2 ns BETTER**
  than the 1550 die (−17). Shrink and SS timing do NOT fight. SS stays voltage-bound
  (both pad=1 and pad=0 land on the identical −15.30669, same critical cone).

> **See also [die-shrink-routability-floor.md](die-shrink-routability-floor.md)** (2026-07-04):
> extends this sweep downward — 1100×1100 is a hard GRT-0116 congestion wall (94% util, local
> M1/M2 pin-access; padding, RT_MIN_LAYER=Metal1, and metal-width knobs all fail to rescue it).

**Sub-1380 sweep DONE (2026-06-24, pad=1, one-variable = die only):**

| Die | Util | SS WNS 3.0V | Result |
|---|---:|---:|---|
| 1380 | 76.5% | −15.31 | ✅ clean (DRC0/LVS) |
| 1340 | 79% | — | ❌ DRT-1231 clkbuf no access |
| 1300 | 81% | — | ❌ signals routed 100% clean, then DRT-0073 on a **setup-repair buffer** |
| 1260 | 83.4% | **−23.84** | ✅ clean (DRC0/LVS) but SS ~8.5ns WORSE |

Two findings: **(1) Routability below 1380 is NOT util-monotonic — it's stochastic clkbuf
pin-access** (1380✓ 1340✗ 1300✗ 1260✓). The trigger is the **post-route SETUP-timing
resizer** stuffing buffers into the IQ_CLK net: 1300 routed all signals 100% clean and only
failed when the resizer added a clock buffer with no access point. At 3.0V this resizer is
FUTILE (can't close −15ns) so it's pure downside. **(2) Shrink-vs-timing DOES trade below
1380** — 1260 routes clean but SS = −23.84 (vs −15.31 @1380), the resizer crowding buffers
into worse spots at 83% util. So the 1550→1380 "shrink is free" result does NOT extend past
1380. **1380 is the sweet spot: SS-optimal AND reliably routable. KEEP IT as baseline.**
1260 is a clean existence proof the die *can* be that small, but −8.5ns SS + luck-only route
make it a bad tapeout choice.
Baseline `config_current_signoff.json` = validated v26 (1380/pad=1/SDC v18/CTS root16); prev
saved `config_current_signoff.prev_1380pad2_20260624.json`.

**RESIZER HYPOTHESIS FALSIFIED (2026-06-24, v31 job 2219 / v32 job 2220).** I had claimed
"the post-GRT setup resizer is the villain — cap it and routing de-risks." WRONG. v31 set
`RUN_POST_GRT_DESIGN_REPAIR:false` + buffer-pct 0 and **still failed DRT-0073** (clkbuf no
access). v32 dropped SS from STA_CORNERS and **also failed DRT-0073**. So it is NOT the
resizer and NOT the SS corner. **Real finding: 1380 clkbuf pin-access is BRITTLE / flow-
perturbation-sensitive.** Signal routing completes 100% clean every run; only a few IQ_CLK
*clock-buffer pins* fail. The v26 baseline routes clean partly by placement luck — ANY flow
perturbation (resizer off, corner-list change, die ±40µm) shifts CTS/placement enough to tip
those pins inaccessible (same non-monotonic fragility as the die sweep 1380✓1340✗1300✗1260✓).
**What limits sub-1380 / flow changes = marginal clock-buffer pin access (a CTS/physical
limit), NOT congestion (GRT 0 overflow), NOT the SS timing corner.** Timing is SEPARABLE:
TT meets at 25°C, so V+T control solves *timing*; it does NOT solve this pin-access fragility.

**PIN-ACCESS LEVER FOUND (2026-06-24, 4-knob experiment on the failing 1340 die):**
`CTS_APPLY_NDR: "none"` is the fix. Of four CTS knobs tried one-per-run, only NDR-removal
cracked the 1340 DRT-1231 wall — the other three failed on the *identical* clkbuf:
- v33 `CTS_OBSTRUCTION_AWARE:true` → ❌ DRT-1231 (same cell)
- v34 `CTS_APPLY_NDR:"none"` → ✅ **CLEAN signoff: 1340×1100, DRC0/route0/LVS uniq, util 78.6%, SS −16.00**
- v35 `CTS_MAX_CAP/SLEW` loosened → ❌ DRT-0073
- v36 `CTS_DISABLE_POST_PROCESSING:true` → ❌ DRT-1231 (same cell)
Root cause: the default `CTS_APPLY_NDR:"half"` applies **2× spacing** to clock nets, which was
crowding the IQ_CLK clkbuf pins out of routing access. Removing it frees them. **So "1380 is
the practical floor / pin access is hard" was WRONG — there was a lever.** 1340+NDR=none lands
SS −16.00 (vs 1380 −15.31, 1260 −23.84) — a good point, ~3% smaller than 1380 for ~0.7ns SS.
TRADEOFF: `none` drops the clock-SI 2× spacing → slightly more clock crosstalk/jitter; at
32MHz GF180 almost certainly fine but note for tapeout (now a §6 signoff item).

**NDR=none CONFIRMED A ROBUST LEVER ACROSS THE SUB-1380 SWEEP (2026-06-24, jobs 2225/26/27,
v37/38/39).** Re-ran the *entire* die sweep with `CTS_APPLY_NDR:"none"`. Every die that
previously failed routing now signs off clean (Magic DRC 0, route DRC 0, LVS clean):

| Die        | util  | SS WNS   | vs default-NDR (`"half"`) |
|------------|-------|----------|----------------------------|
| 1380×1100  | 76.5% | −16.33ns | was −15.31 ✅ (now ~1ns worse) |
| 1300×1100  | 81.2% | −19.28ns | was ❌ DRT-0073 → **now routes** |
| 1260×1100  | 83.4% | −24.09ns | was −23.84 ✅ (≈ same) |

**HARD AREA FLOOR = 1220×1100 (2026-06-24, breaking-point sweep jobs 2233/34/35/36, NDR=none):**
| Die        | util  | result                       |
|------------|-------|------------------------------|
| 1260×1100  | 83.4% | ✅ signoff, SS −24.09         |
| **1220×1100** | **86.3%** | ✅ **smallest clean signoff, SS −31.25** |
| 1180×1100  | —     | ❌ GRT-0116 congestion (pad=1 *and* pad=0 — byte-identical 2.98M wirelen, padding is a no-op here) |
| 1140×1100  | —     | ❌ GRT-0116 congestion (wirelen blew up to 4.36M — router thrashing) |
Breaking point is **global-routing congestion between 1180 and 1220**, NOT the DPL-0036
placement wall (both 1180/1140 *passed* placement, died at GRT). **`DPL_CELL_PADDING=0` does not
rescue 1180** — bit-identical routing to pad=1. AND **SS degrades super-linearly & accelerating
toward the floor**: −16.33→−19.28→−24.09→**−31.25**; the last 40µm (1260→1220) cost **7ns** (vs
5ns the prior step) as the setup resizer buffer-stuffs past ~83% util. So **1220 is physically
reachable but a poor tapeout choice** (fragile −31ns @ 86%). **Sensible signoff window = 1260–1380.**

Two findings: (1) **the routability floor is GONE — NDR=none is not a one-off, it routes the
whole 1380→1220 range** (the non-monotonic 1380✓1340✗1300✗1260✓ pattern under `"half"` was the
2× clock spacing tipping clkbuf pins in/out of access; remove it and all dies down to 1220 route). (2)
**The binding limit below 1380 is now purely SS TIMING, monotonic with shrink** (−16.33 →
−19.28 → −24.09 → −31.25, super-linear) — no more stochastic pin-access cliff. So the die
choice is a clean timing/area trade, not a routing gamble. NDR=none costs ~1ns SS at 1380
(−16.33 vs the `"half"` baseline −15.31) — the 2× clock spacing wasn't free for timing either.

**`root_only` EXPERIMENT — NDR IS A SHRINK-COUPLED CHOICE, `none` IS NOT FREE (2026-06-24,
jobs 2231/2232, v41/v42).** Tested `CTS_APPLY_NDR:"root_only"` (NDR on clock trunk only,
default on branches) on two dies:
- **v42 1380 root_only → ✅ routes clean, SS −15.30669** — *bit-identical to the `"half"`
  baseline*, NOT the −16.33 that `"none"` gives at 1380.
- **v41 1300 root_only → ❌ DRT-0073** on `clkbuf_2_0_0_IQ_CLK_regs/I` (the same IQ_CLK
  clkbuf-pin-access failure as `"half"`). So the trunk-level 2× spacing *alone* re-crowds the
  pin; only full `none` frees it below 1380.

Conclusion — clean rule for the knob:
| die | `half` | `root_only` | `none` |
|-----|--------|-------------|--------|
| 1380 | ✅ −15.31 | ✅ **−15.31** (keeps trunk SI) | ✅ −16.33 (worse!) |
| 1300 | ❌ DRT | ❌ DRT-0073 | ✅ −19.28 |
`none` is **NOT a free lever** — it costs ~1ns SS *and* all clock-net SI. Its *only* value is
cracking sub-1380 dies. So: **at 1380 use `root_only` (or `half`)** — same −15.31 SS, keeps the
trunk clock NDR, no SI sacrifice; `none` is strictly worse there. **Below 1380 you MUST use
`none`** and you pay ~1ns SS + the full clock-SI loss. **The clock-SI tradeoff is therefore
coupled to the shrink: you can keep clock-net NDR only if you stay at 1380.** (v42 final
Magic-DRC/LVS pending at write time; route DRC clean — got past detailed routing.)

**SS-CORNER BUFFERING TAX IS SMALL — BUT WHAT IT BUYS IS HUGE (2026-06-24, job 2228 v40 +
post-hoc read job 2229, 1380).** v40 optimized against **TT+FF only** (SS dropped from
STA_CORNERS). Two measurements on that same netlist:
- **Area:** util **74.9%** vs v37's 76.5% (SS in corners) → SS-targeted buffering costs only
  **~1.6 util points**.
- **Post-hoc SS read** (OpenSTA, swap in `ss_125C_3v00` liberty + max SPEF on the v40 routed
  netlist, job 2229): **worst SS slack −51.24ns**, vs v37's −16.33ns optimized *with* SS in.

So the SS setup buffering buys **~35ns** of SS slack (−51 → −16) for **~1.6 util pts** — it is
extremely cheap *and* effective at what it does. Yet **~16ns of SS gap remains that buffering
cannot close** → that residual is the **voltage-bound** part

**REFRESHED on current B1 RTL 2026-07-04 (jobs 3226 TT+FF-only PnR + 3227/3230 OpenSTA reload):**
Same experiment on the post-B1 netlist. Dropping SS from STA_CORNERS: util 74.47%→**73.36%
(−1.11 pts)**, repeaters 2197→**1877 (−320)**, ~−16K µm², DRC/LVS still 0. Post-hoc SS read
(ss_125C_3v00 lib + max SPEF on the TT+FF-only routed netlist via standalone `sta`): worst
setup slack **−50.26 ns** vs the SS-in netlist's −16.08. So the 320 SS-buffers buy **+34 ns**
(−50→−16), ceiling −16 (voltage-bound). Tax is now 1.1 pts (was 1.6) because B1 already removed
the sc_detector multiply cone from the SS-critical set. Worst path: an IQ_CLK dffrnq endpoint
with **85 ns data-arrival vs a 31.25 ns period** — a path 2.7× the clock at 3.0V; unbufferable
by construction. Recipe for the reload: `sta -no_init` (NOT openroad — needs no LEF),
read_liberty ss + read_verilog final/nl + read_spef final/spef/max + read_sdc (stage-53) +
set_propagated_clock + report_worst_slack -max.: STA already spent the cheap
buffers, the rest is physics at 3.0V, not buffer bloat and not a missing knob. (v40 then
aborted on deferred non-blocking warnings — Yosys synth checks + KLayout-DRC-not-reported —
*after* Magic DRC and LVS passed clean, so the util/area numbers and the routed netlist used
for the post-hoc read are both valid.)
- **Placed cell area ≈ 1.16 M µm²**, NOT the 973 K Yosys synth estimate. The
  ~190 K difference is **P&R timing-repair buffering + CTS** added at 3.0 V — and
  that part is **voltage-dependent** (see §below / 5v-core doc): 5 V removes most
  of it, so 5 V could *lower* util at a given die or lower the floor itself. (So
  "placement floor is voltage-independent" is too strong — only the base synth
  cell count is fixed; the buffering on top is not.)
- **Binding constraint is PLACEMENT (DPL-0036), not routing (GRT).** At ≥1380 the
  router has **0 overflow** (M2 38%, M3 46%, **M4 1%, M5 8%**); below 1380,
  *placement legalisation* fails before routing even runs. So **metal-layer
  rerating** (`GRT_LAYER_ADJUSTMENTS`, tried in v17a — derate M2/M3, fill empty
  M4/M5) is currently MOOT: it only acts at GRT, but GRT is never the binding
  limit. v17a never reached GRT (died at DPL). Layer-rerating only becomes useful
  AFTER the placement floor drops (5 V buffering cut or RTL) and routing congestion
  reappears. v25 = v24 + rerating @ 1380 d50 validates the mechanism (does routing
  shift onto M4/M5?) for when it's needed.
- Target 1100×1100 = 1.21 M would need ~96% util at 1.16 M placed area — not
  reachable at 3.0 V. Needs either non-decimator RTL cuts OR the 5 V buffering
  reduction (untested below 1380).

**SS-vs-die at 3.0 V confirms the trap:** SS gets *worse* as the die shrinks
(−17 → −33), because tighter placement crowds the timing-repair buffering. So at
3.0 V you cannot shrink *and* close — they fight. (At 5 V timing closes with
slack, so this trap disappears — that's the v20 experiment.)

**DRT-1231 minimal fix (confirmed 2026-06-24, v15c clean signoff):** CTS root
buffer `clkbuf_20→clkbuf_16` + drop `clkbuf_4` is sufficient on its own; the
padding-3/density-50 of the v15g combo is NOT required. See [[project_drt1231_clkbuf]].
**BUT it is density-sensitive (2026-06-24 overnight):** the fix holds at 1550×1150
but DRT-1231 (`clkbuf_*_IQ_CLK/I no access point`) RETURNS at 1380 (v24 job 2211,
v25 job 2213 both failed at detailed routing). So the clkbuf pin-access fix is tied
to the 1550 floorplan slack; tightening to 1380 re-crowds the clock buffers.

**"RAISE SS ONLY" VOLTAGE PROBE — SS closes at 4.5 V, but the flow must be told to
try (2026-07-04, B1 RTL).** Experiment: keep DEFAULT_CORNER = nom_tt_025C_3v30
(placement/CTS/routing stay on the known-routable 3.3 V behaviour) and change ONLY the
setup corner ss_125C_3v00 → **ss_125C_4v50** (4.5 V). Needs a `LIB` dict override in the
config to register the 4.5 V corner — LibreLane's gf180mcuD auto-derives only the 3.3 V
corner names; without it STA fails "No SCL lib files found for max_ss_125C_4v50".
- **Post-hoc STA reload of the 3219 (B1, SS-3.0V-optimised) netlist at 4.5 V (jobs
  3231): worst setup slack = +1.17 ns → MEETS**, TNS 0. The full 16 ns SS gap is erased
  by voltage alone. (Recipe: `sta -no_init`, read_liberty ss_125C_4v50 + read_verilog
  final/nl + read_spef final/spef/max + read_sdc stage-53 + set_propagated_clock.)
- **BUT a full re-PnR *targeting* SS-4.5 V (job 3235) lands SS = −8.31 ns** despite
  routing 100 % clean (DRT 0), TT +0.82, hold 0, DRC/LVS 0. Same corner, ~9 ns worse
  than the reload — the only difference is buffering (2,006 repeaters vs 3219's 2,197).
- **ROOT CAUSE — the setup resizer under-drives a milder target corner.** `repair_timing
  -setup -setup_margin 0.05 -max_buffer_percent 50` works a path only as hard as the
  target corner makes it *look* critical. At SS-3.0 V paths look −16 → the resizer upsizes
  + buffers aggressively (→ over-margined, reads +1.17 at 4.5 V). At SS-4.5 V the same
  paths look only −8 → less urgency → lighter repair → converges at −8.31. Buffers fix
  *wire* delay; this residual is *cell*-delay-dominated deep logic that needs aggressive
  upsizing, and the resizer only upsizes as hard as the corner pessimism pushes it. So
  naively swapping to the true operating corner tells the tool to try LESS. **4.5 V is
  provably closeable (the reload proves it); the corner-swap just under-optimises.**
- **Fixes:** (a) sign off at 4.5 V using the 3.0 V-targeted netlist (already +1.17, zero
  work, keeps 3.0 V buffering); or (b) re-PnR targeting 4.5 V with a ~9 ns
  `PL/GRT_RESIZER_SETUP_SLACK_MARGIN` to force the resizer to close −8.31.
- **RUN #2 DONE (job 3237, SS-4.5 V + 9 ns setup margin): SS@4.5 V = +1.40 ns → MEETS**,
  TT +8.32, hold 0, **Magic DRC 0 / LVS 0 / route 0**, util 74.53%, 2,110 repeaters. A
  genuine self-consistent signoff-quality closure at 4.5 V (optimised for AND meeting the
  corner), not just a reload. **Confirms the voltage lever in a real flow.**
- **Area nuance:** util 74.53% ≈ the 3.0 V baseline 74.47% → closing 4.5 V did NOT reclaim
  buffering here, because (i) closing the deep cell-delay paths needs real repair
  regardless, and (ii) the 9 ns margin overshoots (forces +9 ns on every path →
  over-buffers the easy ones). A surgical ~2–3 ns margin would likely land lower (between
  the −8.31 run's 73.6% and this 74.5%).
- **SCOPE CAVEAT (do not over-conclude):** this is an *SS-only-4.5 V hybrid* —
  DEFAULT_CORNER stayed tt_3v30, so synth/placement/CTS were all done for **3.3 V** cells;
  only the SS setup check/repair used 4.5 V. Proves the core TIMES at 4.5 V; does NOT test
  the "5 V sheds the ~190 K buffering" area hypothesis. That needs a **full 5 V-rail**
  synth+place+route (tt_5v00 / ss_4v50 / ff_5v50 as DEFAULT+corners) — the next experiment.
- **General trap for the 5 V-rail signoff: always give the resizer a setup-slack margin
  matched to how much you need the milder corner to close — a bare corner swap under-drives.**

**Corrected-MCP is a DEAD END at 3.0 V (confirmed 2026-06-24, v18 job 2197).** With
the MCP scope *actually hitting the registered barrel-shift endpoints* (v18 SDC fixes
the STA-0361 silent no-op), SS WNS = **−17.017 ns** — bit-identical to the un-corrected
baseline (v15g −17.02). Fixing the no-op bought ZERO relaxation → the QSPI barrel-shifter
was never on the critical path. No MCP/pacing closes 3.0 V SS. Voltage is the only lever.

**5 V corner-swap won't route at a shrunk die (2026-06-24).** v20–v23 (5 V corners @
1450/1400/1350/1300) ALL failed DPL-0036 at placement — the 5 V default corner perturbs
CTS/placement legalization, failing even the generous 1450. The 5 V experiment must run
at the known-routable **1550** die first (vary voltage OR die, not both at once).

---

## 3. Levers (in priority order)

**Lever A — Floorplan tighten (free, no RTL).** Once SS WNS is MET, buffering
settles and the die can retighten 1550×1150 → ~1450×1150 (58%). Must come
*after* SS closes — shrink and timing-buffering fight each other (see Gate 0).

**Lever C — PD knobs (cheap, measure the real ceiling).**
- `DPL_CELL_PADDING` 2 → 1: most direct util lever (~+5–8%). Pair with CTS fix.
- PDN sparsification: widen `PDN_VPITCH`/`HPITCH` (153→~200 µm) to free Metal4/5
  signal tracks; trades IR-drop margin (gated by `RUN_IRDROP_REPORT`).
- CTS congestion management: smaller/distributed clkbuf cells, routing halo —
  directly targets the DRT-1231 failure mode (Gate 0).

**Lever B — RTL area cut (to break below the 1380×1100 floor).** The decimator is
CLOSED (see §1). Candidate blocks instead:
1. sc_detector (135K) / training_acc (134K) — arithmetic-heavy; the shared mul is
   already folded, 2nd mul already halved. 10–15% trims ≈ 25–30K, diminishing.
2. Decimator #4 (deeper comb TDM) — untested incremental control-state trade; the
   only decimator lever left, and small.
3. Everything else <8% each — not worth structural risk.
Note: prior RTL cuts on the IQ_CLK domain repeatedly traded SS regression for area
(reset-removal −9.3 ns, AREA-0 −15.6 ns). Any new cut must be checked at SS, not
just synth area.

**Lever D — Delay lines → SRAM macro: REJECTED** (see §1) — 168 B is sub-2-kbit,
smallest macro +47% area, bandwidth-bound. Do not revisit without a custom
dual-port OpenRAM macro (unproven, tapeout-risk).

---

## 4. Gate 0 (BLOCKER) — CTS pin-access DRT-1231 on the v15 SDC

The honest barrel-shift `set_multicycle_path 2` SDC (v15) perturbs timing-driven
CTS such that level-1 clock buffer `clkbuf_1_0__f_IQ_CLK/I` lands without a
routing access point → **DRT-1231 at detailed routing**. Reproducible at density
55 (job 2173) and 52 (job 2175); v12/v14 (no barrel-shift MCP) route fine. This
blocks *every* PnR — SS-number verification and density probes alike — so it is
the first thing to fix.

Candidate fixes (try in order):
1. CTS buffer-set change: root `clkbuf_20`→`clkbuf_16`, drop smallest `clkbuf_4`.
2. Placement seed / `PL_TARGET_DENSITY_PCT` nudge with the new buffer set.
3. If intractable: accept v14's registered cone (routes, SS −16.25, cocotb 12/12
   PASS) and treat the residual as STA-pessimistic — the RTL stability-gate
   already guarantees the multicycle settle in hardware regardless of the SDC.

---

## 5. Sequenced plan

- **Gate 0** — unblock DRT-1231 (CTS buffer set). Get a routed honest-MCP SS WNS.
- **Gate 1** — confirm SS closure (or quantify residual). Don't shrink before this.
- **Gate 2** — re-establish the un-paced 1380×1100 floor WITH the honest-MCP SDC:
  shrink 1550×1150 → 1500×1100 → 1380×1100, holding TT=0/DRC=0 and watching SS.
- **Gate 3** — Lever C: `DPL_CELL_PADDING=1` / PDN-pitch probes to push past 1380.
- **Gate 4** — Lever B: if below-1380 is wanted, trim sc_detector/training_acc
  arithmetic — re-verify SS each cut (IQ_CLK-domain cuts have regressed SS before).
- **Gate 5** — re-baseline the 1100×1100 target vs measured reality.

---

## 6. Open risks

- **CLOCK SIGNAL INTEGRITY — `CTS_APPLY_NDR: "none"` (TAPEOUT SIGNOFF ITEM).** The
  pin-access fix that unlocks sub-1380 routing removes the default 2× spacing
  non-default rule on clock nets (`"half"` → `"none"`). The clock tree then routes
  at *default* signal spacing → less isolation → potentially more **crosstalk-induced
  clock jitter/skew** on IQ_CLK, which fans out to the *entire* 32 MHz synchronous DSP
  chain. At 32 MHz on GF180 (5 LM) this is almost certainly fine, but it is NOT
  free and must be explicitly signed off before tapeout, not adopted silently. To
  RESOLVED 2026-06-24 (jobs 2231/2232) — the answer is **shrink-coupled**:
  - **`root_only` works at 1380** (v42: clean route, SS −15.30669 = identical to `"half"`,
    keeps the trunk-NDR clock SI). So **at the 1380 die there is NO SI sacrifice** — use
    `root_only` (or `half`), and `none` is strictly worse (−16.33, no SI). The earlier "must
    accept the SI hit" framing was over-stated *for 1380*.
  - **`root_only` FAILS below 1380** (v41 1300: DRT-0073 on the same IQ_CLK clkbuf as `"half"`).
    The trunk-level 2× spacing alone re-crowds the pin → only full `none` routes sub-1380.
  So the real tradeoff: **you can keep clock-net NDR only if you stay at 1380; shrinking below
  forces `none` and accepts the full clock-SI loss + ~1ns SS.** Decision = whether the ~3-6%
  die saving below 1380 is worth giving up clock-net isolation on the whole 32MHz chain;
  decision owner is whoever signs the clock tree. Remaining signoff step regardless of die:
  (a) check post-route clock skew/jitter & coupling-cap vs the `"half"` baseline. See §1
  pin-access finding (v34 job 2222, sweep 2225/26/27, root_only 2231/2232).
- 1100×1100 may be physically unreachable at 7-track / 5LM GF180 with this DSP
  workload; **1380×1100 is the measured routing-congestion floor** for the
  un-paced design — and the honest-MCP SDC currently won't even reach 1550×1150.
- Decimator precision is CLOSED (§1) — not a lever. Do not re-open CIC width.
- DRT-1231 is timing-SDC-sensitive; the CTS fix must survive future SDC edits.
- SGE has two nodes: gaming-pc (22 cores) + nas-server (5 cores). Two full
  signoffs (`DRT_THREADS=10` each) run concurrently on gaming-pc — PnR
  experiments can be parallelised, not serialised.

---

## 7. 2026-07-04 per-block re-measure + concrete Lever-B candidates

Fresh hierarchical Yosys stat against `gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30`
on the current RTL (post SS-pacing, post training-window control), SGE job
**3214**. Output: `rtl-test/syn_mimo_per_module/out_trouper_top_202607/stat_hier.txt`;
re-run via `rtl-test/syn_mimo_per_module/run_synth_top_breakdown_202607.sh`.

**Synth stdcell total = 939.9K µm²** (today's signoff run 06-yosys stat: 984.5K
after synthesis-time buffering; placed will be ~1.16M per §2).

| Block | µm² (incl. subs) | % | Notes |
|---|---:|---:|---|
| sd_decimator_poly | 342K | 36.4% | 2,219 dffrnq (166K) + 1,874 enable-mux2 (53K). CLOSED (§1) |
| training_acc | 137K | 14.6% | 743 flops; 16×32-bit accumulators, dual 8×8 mult |
| sc_detector | 135K | 14.4% | 670 flops + `signed_mul24_pipe` **24.4K** |
| psram_buf_ctrl | 69K | 7.4% | 476 flops (3× 64-bit shift buffers + ptrs) |
| mrc_combiner | 62K | 6.6% | 318 flops (x/W latches) |
| sd_remod | 59K | 6.3% | ~117 flops; six 16×9 const mults + 27-bit summers |
| reg_bank | 41K | 4.4% | register file — leave |
| dc_removal | 38K | 4.0% | 8× dc_removal_chan @4.7K each |
| packet_ctrl_fsm | 34K | 3.6% | five 32-bit absolute-time regs + comparators |
| glue + spi_slave | 24K | 2.5% | — |

Design-wide cell facts: **5,177 `dffrnq_1` = 386K µm² (41%)**; 3,465 `mux2_1`
(enable recirculation) = 99K; `dffq_1` (no reset) is 63.7 vs `dffrnq_1` 74.6
µm² → −10.9 µm²/flop where reset is droppable.

### Ranked candidates (~50–60K realistic, ≈5–6% of stdcell)

Every cut on the 32 MHz IQ_CLK domain must be re-verified at SS post-PnR — §1
precedent: decimator reset-removal and AREA-0 both *regressed SS 9–16 ns for
≤6% area* and were rejected on that basis, not on synth area.

**B1. sc_detector eval multiplier → bit-serial. −17K. ✅ IMPLEMENTED + functionally
verified 2026-07-04 (SS PnR gate pending).**
`signed_mul24_pipe` cost 24.4K µm² (1,163 cells) to perform **four multiplies
per symbol** (ci0², cq0², E0cur×E0del, thr×e_slice). Eval budget ≥ 4,096 clocks
(SF6·shift0). Replaced with `serial_mul13`, a 13-bit LSB-first shift-add serial
multiplier (~14 clocks/product; critical path = one 26-bit add, no 13×13 array),
and rewrote the eval FSM from a throughput-1 pipeline (eval_valid_pipe /
eval_step_0..2 / eval_issue_done) to a sequential launch→wait(`mul_done`)→
accumulate handshake (`mul_start`). ~4×15-clock serial latency sits inside the
≥1,500-clock symbol period, so every latched output (timing_ref, sc_stat,
c_i0/q0, eval_hit) is unchanged. The serial product is the *exact* two's-
complement integer a·b, so bit-exactness is structural, not empirical.

Results (all on SGE, current RTL synced to NFS):
- **Area:** `sc_detector` standalone synth **135K → 118.0K µm² (−17K)** (job 3216;
  the ~−20K estimate assumed the full 24.4K was recoverable — a few K folds into
  shared logic).
- **Function:** cocotb full-chip `test_trouper_top` **12/12 PASS** across SF7–SF12
  × BW250/125 — sc_lock + training + weights + remod (job 3218). SF7 sanity 2/2
  (job 3217). This is the maintained gate; the old verilator `tb_dsp_chain*`
  benches are dead (don't compile vs current RTL — missing sample_shift /
  tacc_window_syms pins, true at HEAD too — cleanup TODO).
- **SS gate: ✅ BANKED.** Full signoff PnR of the 1380×1100 baseline
  (config_current_signoff, NDR=none/pad=1/SDC v20), only sc_detector.v changed
  (job 3219, run RUN_2026-07-04_14-53-01): **SS setup WNS −16.08 ns** vs the
  −16.33 baseline → **+0.25 ns BETTER**, plus **Magic DRC 0 / LVS 0 / route DRC 0**,
  util 74.5%. Confirms the hypothesis: pulling the 13×13 combinational cone off
  the IQ_CLK domain is SS-positive, the opposite of the §1 decimator cuts.
- **CAVEAT for parallel PnR:** both PnR jobs share `ol_trouper_top/runs/`, so a
  `ls -dt runs/RUN_* | head -1` in the job script races (3219 mis-printed 3222's
  dir). Read WNS from the run whose `06-yosys-synthesis` timestamp matches the job
  start, not the newest dir.

**B2. Reset-free data flops — ✅ REVISED 2026-07-05: banked at the current 1200×1100/88%-density floorplan (superseded the 2026-07-04 rejection below).**
The 07-04 rejection (immediately below) was measured at the older 1380×1100/50%-density
floorplan. Re-tested same-day-current on `config_current_signoff.json` as it stands now
(1200×1100, `PL_TARGET_DENSITY_PCT=88`, fixed `io_placement_bl.cfg` pin order) — a clean
apples-to-apples pair, only `training_acc.v` differing (confirmed via netlist: the
without-B2 run's `Zpair_i` flops are `dffrnq_1`; the with-B2 run's are the reset-free cell):
**without B2** (job 3251, `RUN_2026-07-05_00-56-34`): SS WNS **−25.39 ns**, util 85.25%,
instance area 1,264,650 µm², DRC/LVS/route-DRC 0/0/0, antenna 3.
**with B2** (job 3266, standalone probe dir `tacc_b2_pnr_probe`, same config):
SS WNS **−20.50 ns (+4.89 ns BETTER)**, util 86.02%, instance area 1,264,650 µm²
(*identical* — the raw flop saving is still fully reabsorbed, same mechanism as before),
DRC/LVS/route-DRC 0/0/0, antenna 4. So the tradeoff is unchanged in kind (no free area;
the −3.6K synth flop saving never survives to placed area, at this or any density so far
tested) but reversed in direction on SS: at 1380×1100/50% it cost ~1 ns of SS; at the
current denser 1200×1100/88% floorplan it *gains* ~4.9 ns instead. Promoted
`training_acc.v` (resetless Zpair_*/Zdiag_*) to `src/combiner/training_acc.v`.
**This result is density/congestion-coupled, same as the voltage-coupling noted below —
re-verify if the die size or density target changes again; do not assume it holds at a
different floorplan without re-running both sides of the comparison.**

**B2 original 2026-07-04 result (kept for history; see revision above) — PnR-REJECTED at 3.0 V (revisit at 5 V).**
training_acc beachhead built + functionally proven, but the SS PnR gate killed it:
combined B1+B2 (job 3222, RUN_2026-07-04_15-05-34) = **SS −17.02 ns vs B1-only
−16.08 → −0.94 ns WORSE**, with **util 74.56% ≈ B1's 74.47% (flat/up)** — i.e. the
−3.6K synth flop saving was entirely reabsorbed by SS timing-repair buffering and
never reached placed area, *and* it cost ~1 ns of SS. Same mechanism as the §1
decimator reset-removal, milder. DRC/LVS still 0. **Reverted training_acc.v to HEAD;
kept `tb/tb_tacc_resetless_equiv.v` as a reusable verification asset.**
VOLTAGE-COUPLED, like everything else here: at ~5 V the ~190K timing-repair
buffering (§2) largely disappears, so the flop saving WOULD survive to placed area
AND the −0.94 ns is absorbed by SS slack → B2 (and the mrc/psram/sc_detector operand
regs) become worth taking *only on the 5 V path*. Do not re-run B2 at 3.0 V.
Lesson: at 3.0 V, a pure-area cut on any timing-adjacent domain is net-zero-area +
SS-negative (buffering refills it) — only cuts that *remove a wide combinational
cone* (B1) pay, because they shrink the critical path instead of feeding the buffer
pump. Original notes retained below for the 5 V revisit:
Decimator scope was REJECTED (§1, SS regression on IQ_CLK). Remaining
candidates sit mostly in the 16 MHz CE-gated / paced domains where that SS
mechanism is weaker: training_acc Zpair/Zdiag, mrc_combiner x/W latches (~190),
psram wr/rd/dbg shift buffers (~150), sc_detector tlat/tdm/eval operand regs
(~100). ~950–1,000 flops → ~−11K. Keep async reset on all FSM/control state.

training_acc done (`rtl-test/rtl/training_acc.v`): the 20 Zpair_*/Zdiag_* (640
flops) are provably reset-redundant — unconditionally zeroed at arm (sc_lock or
noise_trig rising edge) and never read until training_done (reg_bank IRQ gate).
Moved them out of the `posedge clk or negedge rst_n` block into a dedicated
`always @(posedge clk)` (arm-zero priority over accumulate; single driver). Synth
maps **544 flops → dffq_1** (199 control flops keep dffrnq_1); module **137K →
133.4K (−3.6K)** (job 3220) — below the 5.9K raw flop-cell delta because
recirculation muxing offsets part of it. cocotb SF7 ×2 PASS incl. training_done
(job 3221) — no X-prop failure.

Resetless-init safety PROVEN, not just tested: `tb/tb_tacc_resetless_equiv.v`
runs two identical instances, force-loading DUT's Z flops with garbage
(0xA5A5A5A5) and REF's with 0, then asserts every output bit-identical from the
first arm across two arm windows — **PASS** (job 3223). Garbage (not X) is
deliberate: it defeats the X-optimism trap where a 4-state X gets "lucky"
through an operator. This is the definitive check that the removed reset can
never leak into a consumed output. Remaining tapeout-confidence step: gate-level
sim on the post-synth netlist with flops left X (no setundef -zero).

**SS probe: combined B1+B2 PnR job 3222** (vs B1-only 3219, so B2's marginal SS =
3222 − 3219). Risk still open per §1: confirm no SS echo of the decimator
reset-removal regression before banking.

**B3. sd_remod 3rd→2nd order. ❌ REJECTED 2026-07-05 — measured, does not clear the noise floor.**
§1 table said "SQNR-locked, do not touch" pending the DSP Chain SNR Loss Budget
§9 sweep (Gate 9/10), which was a placeholder physics argument, not a
measurement: "2nd-order OSR=64 in-band SQNR ≈ 77 dB, clears the ≈50 dB int8
floor by >25 dB." That sweep has now been run (`sim/tests/remod_order_sweep.py`,
extending `sim/notebooks/14_sd_remod.ipynb`'s methodology to a genuinely
order-configurable `SigmaDeltaRemodulator`, `sim/models/converter.py`) and the
estimate does not hold:

| | order=3 (deployed) | order=2 (this candidate) |
|---|---|---|
| SQNR at realistic operating amplitude (0.5) | 65.7 dB | **49.0 dB** |
| Peak-achievable SQNR (near instability cliff) | 66.8 dB | 52.8 dB |
| Margin over int8 floor (≈49.9 dB) at op point | +15.8 dB | **−0.9 dB** |
| Stability cliff / margin over −3 dBFS | amp 0.88 / +1.9 dB | amp 1.00 / +3.0 dB |
| Full SF7-12×BW125/250 loopback | PASS | PASS |

2nd-order is actually *more* stable (wider input range, as CIFF theory
predicts for lower order) but its SQNR sits right at the int8 quantisation
floor with no margin at the amplitude the design actually operates at — not
the 25 dB of headroom the physics argument assumed. The symbol-loopback test
alone doesn't catch this (single-symbol chirp demod is a much coarser probe
than SQNR), which is why it still passes. **Do not take this cut** unless the
design is willing to trade away integrator headroom margin to push the
operating amplitude toward the 2nd-order cliff — which itself erodes the
safety margin `sim/notebooks/14_sd_remod.ipynb` §4 relies on. Sweep debt (§9)
is now paid either way.

**B4. mrc_combiner: delete local W latches. −6K.**
`wr_re/wr_im[0:3]` (64 flops + enable muxes) re-latch reg_bank W-shadow values
that are static during a burst (firmware commit protocol + safe_switch already
guarantee stability). Mux the W ports directly. Do NOT fold the two multipliers
into one: the 16 MHz burst is 31 of 32 available clocks — no headroom.

**B5. Debug register trim. −6K. Tapeout decision.**
`sc_first_hit_dbg` + `sc_lock_sample_dbg` (64 flops) + reg_bank 0x28–0x2B
decode are bringup observability. Decide whether they survive to tapeout.
psram `dbg_buf` path is NOT in scope — it is the firmware diagnostic-read path
(software energy measurement plan).

**B6. packet_ctrl_fsm relative timeouts. −5K.**
`acq_timeout_q`/`wpend_timeout_q`/`pkt_end_q` are 32-bit absolute sample counts
each with a 32-bit comparator; as ≤18-bit down-counters the comparators become
zero-checks. `M_val` needs only 15 bits (M ≤ 16,384).

### Considered and rejected (do not re-explore without new data)

- **Clock gating to kill the 99K of enable-mux2**: FD lib has no ICG cell;
  hand-built latch-AND gating through OpenLane CTS is a routability/verification
  gamble that fights the honest-MCP work. (Same conclusion as [[project_ce16_partition]]
  reached via CE muxing instead.)
- **training_acc 24-bit accumulators**: reg map exposes Z[31:8], but the low
  8 bits carry real weight across ~10⁵ accumulations — truncating the addend
  biases Z. Rejected on precision.
- **Shared global sample_count** (sc/tacc/pcfsm each hold 32-bit): saves ~5K but
  the counters have deliberately different increment timing after the pacing
  deferred-increment fix — exactly where the timing_ref class of bug lives.
- **Decimator anything** (width, storage, reset style): CLOSED per §1.

Stack estimate: B1+B2+B4+B5+B6 ≈ **−48K** with no algorithmic change; synth
~892K. **B3 is now closed (rejected, see above) and does not add to this
stack** — the ≈−65K figure that assumed B3 clearing the sweep no longer
applies. Per §2 the −48K stack does not by itself unlock a die step below the
1260–1380 signoff window (binding limit below 1380 is SS timing, and placed
area is buffering-inflated), but it buys util headroom at 1380/1340 and
shrinks the SS repair burden.
