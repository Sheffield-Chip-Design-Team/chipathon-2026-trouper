# sd_remod_interp2x P&R impact investigation (2026-09-05)

**PROMOTED TO CANONICAL, 2026-09-05.** Following this investigation's full
campaign (below) and the multiplierless fix in particular (§7.4), the
combined interpolator + multiplierless-core design (job 5606's exact
configuration: DRC 0, LVS clean, antenna 0, SS WNS −16.08ns, inside this
design's normal signoff range) was promoted to `src/remod/sd_remod.v` /
`src/remod/sd_remod_multiplierless.v`, superseding the plain-4th-order-only
`sd_remod.v`. `trouper_top.v` needed **no changes** — the promoted `sd_remod`
module keeps the exact same external port interface and sample cadence, so
the existing `sd_remod u_remod (...)` instantiation is still correct as-is.
The pre-promotion core is preserved at
`rtl-test/rtl/sd_remod_pre_multiplierless_reference.v` solely so the
bit-exact equivalence regression (`sim_sd_remod_multiplierless_equiv`) keeps
a stable reference to check `sd_remod_multiplierless.v` against. Everything
below this point documents the investigation that led to the promotion, not
its current state — the "not yet an adopted fix" framing in the next section
no longer applies to the final combined design that shipped.

## 1. Context

`rtl-test/rtl/sd_remod_interp2x.v` is an experimental 2x half-band interpolator
placed in front of the deployed 4th-order `sd_remod` (see
`planning/sd-remod-4th-order-fix-2026-09-04.md` for the remod fix itself). It
targets the STF gain droop at fs/4 (~-0.9 dB) left open by that fix: reducing
the final zero-order hold from 64 to 32 clocks changes the 125 kHz response
from -0.912 dB to -0.224 dB, leaving ~-0.18 dB net droop after the half-band
filter's own response. It reuses the existing `sd_decimator_poly` HB1
coefficients `[19, 0, -73, 0, 312, 512, 312, 0, -73, 0, 19]/1024` run in
reverse as an interpolator, in polyphase form (even phase = weighted sum of 3
symmetric input pairs via shift-add constant multiplies; odd phase = a
delayed copy, since the center tap gain is exactly 1).

This is **not yet an adopted fix** — this document records only the area and
P&R-impact investigation prompted by "just to see how much pnr changes."
Nothing here has been committed to git; all files below are untracked
working-tree additions.

## 2. Standalone synthesis cost (job 5587)

Yosys-only (`synth -top <mod> -flatten; dfflibmap; abc; stat -liberty`) against
`gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib`:

| module | cells | area (µm²) |
|---|---|---|
| `sd_remod` alone (4th-order, current deployed) | 3,275 | 73,884 |
| `sd_remod_interp2x` (wraps `sd_remod`) | 4,638 | 103,908 |
| **delta from adding the interpolator** | **+1,363 (+41.6%)** | **+30,024 (+40.6%)** |

The interp2x-specific delta is dominated by arithmetic cells (`xor2_1`: 695,
`nand2_1`: 866, `aoi21_1`/`oai21_1`: 342/369 total in the combined module) —
consistent with the datapath computing three parallel shift-add constant
multiplies (`×19`, `×73`, `×312`) **twice in full**, once for I and once for Q,
every sample.

## 3. Full-chip P&R campaign

All runs use `trouper_top_interp2x_experiment.v` (a copy of
`src/top/trouper_top.v` with `u_remod` instantiating `sd_remod_interp2x`
instead of `sd_remod` — same port interface, drop-in swap) and
`src/remod/sd_remod_interp2x.v` (copied from `rtl-test/rtl/`), driven by
config variants derived from the canonical `src/config/trouper_top_minff_rcx.json`.
The real `src/top/trouper_top.v` was never modified.

**Baseline (job 5588):** synth cell count 40,739 vs. 38,849 for the plain
4th-order `sd_remod` build (job 5563/5583) — **+1,890 cells (+4.9%)**, area
1,113,970 µm² (+2.2%). **FAILED** in detailed routing, step 46/80:
`[DRT-1231] Pin clkbuf_1_0__f_IQ_CLK/I does not have access point` — the same
known, pre-existing clkbuf pin-access failure mode this project has hit before
(`[[project_drt1231_clkbuf]]`), not a new class of bug.

### 3.1 Density probes (jobs 5592, 5593)

`PL_TARGET_DENSITY_PCT` 63% and 60% (down from the canonical 65%). Both
**FAILED identically** — same pin, same stage. Checking the actual global
placement metrics explains why: `design__instance__utilization` measured
**0.658135** at 63%, not 63% — `GPL-0302: Target density 0.6300 is too low for
the available free area` fires in every one of these runs. The interp2x
netlist's real cell area, divided by the fixed A40 core area (die minus
padframe-template margins/ring/blockages), floors utilization at **~65.8%**
regardless of what's requested below that. All three density values (65/63/60)
therefore landed at the same real placement and failed the same way — density
was never a live knob here.

### 3.2 `DPL_CELL_PADDING` / GPL padding (discussed, not run)

Already at its ceiling (2); raising to 3 is documented to break diode
legalization outright (`DPL-0036`). Lowering it tightens cell packing, the
wrong direction for a pin-access/congestion failure. No headroom in either
direction — not run as a separate job.

### 3.3 PDN pitch (discussed, not re-run)

Already tested historically at the (smaller) baseline netlist: `pitch ×1.4`
(job 5394) signed off clean with zero measurable timing gain; `pitch ×1.2`
(job 5393) **failed outright** with the identical failure class,
`clkbuf_2_1_0_IQ_CLK_regs/I`. Non-monotonic / unstable lever per the
config's own comment (`_comment_pdn`); not re-run given this history.

### 3.4 GRT slew/cap repair margin (job 5595)

`GRT_DESIGN_REPAIR_MAX_SLEW_PCT` / `MAX_CAP_PCT` loosened 65%→75% (density
back at 65%). **Cleared detailed routing** — the first variant to do so.
Full signoff:

- `magic__drc_error__count`: 0; LVS: all 0 (clean)
- Antenna: 0 violations (34 diodes inserted, all repaired)
- **SS WNS: −32.55 ns, SS TNS: −3,121 ns** — catastrophic, vs. this design's
  normal ~−10 to −17 ns signoffs
- `MaxCapViolations` now present at **both** SS and nom_tt (nom_tt is
  normally clean)
- Final utilization 76% (not the ~65.8% floor) — driven by a large post-route
  timing-repair buffer insertion (`timing_repair_buffer` class: 64,859 µm²)

**Mechanism, and why this is REJECTED, not adopted:** loosening the margin
let the *pre-route* repair pass (which competes for the same congested space
that was failing) skip fixing marginal nets, so detailed routing had less to
contend with and didn't hit DRT-1231. But the skipped violations didn't
disappear — they were deferred to the post-route resizer pass, which can
insert buffers into already-legal gaps without needing to re-solve routing,
so it "passed" without ever resolving the actual congestion. And even with a
huge buffer dump, it still didn't recover timing. This is a **false lead**:
routing cleared by starving a repair pass that keeps timing sane, not by
fixing anything.

### 3.5 Jumper-only antenna repair (job 5596)

`GRT_ANTENNA_REPAIR_JUMPER_ONLY` / `DRT_ANTENNA_REPAIR_JUMPER_ONLY` both set
true (density back at 65%), removing diode insertion as an antenna-repair
mechanism entirely — targeting the project's own documented root cause for
the *original* DRT-0073 (diodes crowding the IQ_CLK clkbufs). **Cleared
detailed routing.** Full signoff:

- DRC: 0; LVS: clean
- **Antenna: 22 violating nets, 27 violating pins, 0 diodes inserted** —
  jumpers alone couldn't repair everything, and diode fallback was disabled.
  This project's own established recipe (job 5198) specifically targets zero
  antenna violations for signoff; this is a real manufacturability failure.
- SS WNS: −27.6 ns, SS TNS: −2,012 ns — regressed, though less catastrophically
  than 3.4
- Final utilization 74.7%, same "cleared routing by giving something up
  elsewhere" pattern as 3.4

**REJECTED**: not a viable signoff candidate.

### 3.6 No PDN core ring (job 5597)

`PDN_CORE_RING`/`PDN_CORE_RING_CONNECT_TO_PADS` set false, `LEFT/RIGHT_MARGIN_MULT`
reverted 27→12 (the pre-ring baseline), reclaiming ~1% core area and removing
the ring's Metal2/Metal3 via-ladder crossings. **FAILED** — same failure
class, different specific clkbuf instance
(`clkbuf_2_1_0_IQ_CLK_regs/I`, notably the same net name that failed under
the PDN-pitch-×1.2 trial, job 5393, on an unrelated netlist). Reclaiming the
ring's area/routing-layer cost was not enough on its own.

### 3.7 Options considered but not executed

- **Free-floating I/O placement (drop `FP_DEF_TEMPLATE`, use the retained
  `io_placement_bl.cfg` standalone pin order)**: plausible diagnostic — it
  would isolate whether the A40 padframe's fixed pin/blockage geometry is
  itself the bottleneck. Not run: the result would only ever be diagnostic,
  since a build without the real padframe template cannot bond to the actual
  shared multi-project padring and is not tapeout-viable as-is.
- **Removing one axis of the PDN stripe mesh** (e.g. horizontal-only on one
  layer): plausible mechanism (fewer via-ladder crossings through
  Metal2/Metal3), but requires editing the PDN script directly (not a config
  knob) and introduces an unevaluated IR-drop risk (single-direction current
  spreading across a 1675×1110 die). Deprioritized below the RTL-side fix.
- **More routing/repair iterations** (`ROUTING_OPT_ITERS`, etc.): not
  applicable. `DRT-1231` is a hard failure at pin **access-point generation**,
  before any maze-routing iteration runs — confirmed by the log showing the
  error firing mid-way through the *first* routing pass. No amount of
  iteration budget changes a geometry that has no legal access point.

## 4. Verdict

| Variant | Result |
|---|---|
| Density 65% (baseline interp2x, job 5588) | FAILED — DRT-1231 |
| Density 63% (job 5592) | FAILED — DRT-1231, identical |
| Density 60% (job 5593) | FAILED — DRT-1231, identical |
| No PDN core ring (job 5597) | FAILED — DRT-1231, same net family |
| GRT slew/cap margin 75% (job 5595) | "Cleared" routing; SS WNS −32.55 ns (catastrophic) — REJECTED |
| Jumper-only antenna repair (job 5596) | "Cleared" routing; 22 unrepaired antenna violations — REJECTED |

Every P&R-config lever that preserves correctness elsewhere failed
identically at the same stage; the only two that avoided the routing failure
did so by disabling a correctness check (timing repair, antenna diode
fallback) rather than resolving the underlying congestion. This is a
converging, consistent result: **the interp2x netlist is genuinely too large
for this die's routing headroom around the IQ_CLK clock tree**, and no P&R
knob fixes it without giving something else up.

## 5. Path forward: RTL-side netlist reduction

Ranked by expected payoff vs. effort (see cell-type breakdown, §2):

1. **Time-multiplex I and Q through one shared adder tree** (biggest win,
   moderate effort). The datapath currently runs two fully separate sets of
   20-bit adders/subtractors (`pi_x19/x73/x312` and `pq_x19/x73/x312`) every
   sample, despite the sample rate (500 kS/s) being 64× slower than the clock
   (32 MHz). Serializing I then Q through shared hardware would roughly halve
   the added combinational logic (likely 600-700 of the 1,363-cell delta) at
   the cost of one extra clock of latency. **This is the option now being
   implemented directly in the RTL** (2026-09-05, "IQ serialisation for
   remod").
2. **Trim intermediate wire widths 20→18 bits** (small win, trivial, zero
   functional risk). `pi0e/pi1e/pi2e`, `pi_x19/x73/x312`, `even_acc_*`,
   `even_scaled_*` are all declared 20 bits; the real required range
   (`±312×256 = ±79,872`) needs only 18. Pure bit-width cleanup, same math.
3. **CSD-optimize the ×312 constant multiply** (tiny win, trivial). Currently
   `312 = 256+32+16+8` (4 terms, 3 adds); `312 = 320−8 = (x<<8+x<<6)−(x<<3)`
   needs only 2 adds — saves one 18-bit adder per channel.
4. **Design a smaller bespoke droop-compensation filter** (biggest potential
   win, most effort). The current filter reuses the decimator's HB1 taps
   wholesale, which were designed for a much harder spec
   (decimation/anti-aliasing) than what's needed here (flattening the STF
   near fs/4 only). A purpose-built, shorter filter targeting only the droop
   shape could plausibly be far smaller — but requires new coefficient
   derivation and re-validation (SQNR/gain-flatness regression), not a
   mechanical edit.

## 6. Working-tree artifacts from this investigation (untracked, uncommitted)

- `src/top/trouper_top_interp2x_experiment.v` — copy of `trouper_top.v` with
  `u_remod` swapped to `sd_remod_interp2x`; real `trouper_top.v` untouched.
- `src/remod/sd_remod_interp2x.v` — copy of `rtl-test/rtl/sd_remod_interp2x.v`.
- `src/config/trouper_top_minff_rcx_interp2x_experiment.json` (+ `_d63`,
  `_d60`, `_grt75`, `_jumperonly`, `_noring` variants) — config derivatives
  used for jobs 5588/5592/5593/5595/5596/5597.
- NFS scratch: `/srv/eda/designs/timothyn-dev/lora-mimo/rtl-test/scratch_sqnr/cellcount/`
  (standalone synth comparison scripts and logs, job 5587) and
  `/srv/eda/runs/timothyn-dev/lora-mimo/{5587,5588,5592,5593,5595,5596,5597}/`
  (full run outputs).

None of the above have been committed to git. Cleanup (or promotion to
tracked files, if the IQ-serialization rework is adopted) is a follow-up
decision, not yet made.

## 7. Follow-up: I/Q serialization, 7-tap compact, and the real root cause

### 7.1 I/Q serialization (job 5598 synth, job 5599 full P&R)

`rtl-test/rtl/sd_remod_interp2x.v` was rewritten to serialize the even-phase
arithmetic across I and Q through one shared pair-adder and one 20-bit
accumulator (10 shifted power-of-two terms per rail, 20 of the 64 available
clocks), instead of two fully parallel adder/subtractor sets.

Standalone synth (job 5598): full module 4,638→4,101 cells (−11.6%),
103,908→96,053 µm² (−7.6%). Isolating the interp2x-only delta: 1,363→826
cells (−39.4%), 30,024→22,169 µm² (−26.2%) — less than a clean 50/50 halving
because some combinational savings were spent back on control/accumulator
state (`mac_busy`, `mac_q`, `term_step`, and critically the 20-bit `mac_acc`
accumulator, now a real flop).

**Full P&R (job 5599, standard config — density 65%, standard antenna
repair, standard slew/cap margins, no correctness-disabling knobs): a
genuinely clean physical signoff for the first time.** DRC 0, LVS clean,
antenna 0 violations (14 diodes, all repaired normally). SS WNS −25.7 ns
(better than any interp2x variant so far, but still well short of this
design's normal ~−10 to −17 ns range). Utilization 73.6%.

This proved the routing-access failure (DRT-1231) really was a netlist-size
problem, not something requiring a P&R-config workaround — cutting real
cells resolved it outright, unlike every config lever tried in §3.

### 7.2 Root cause of the residual SS timing gap

Traced job 5599's worst path directly: `Startpoint _73971_` →
`Endpoint _73942_`, net names `u_remod.u_remod.s1_i[11]` →
`u_remod.u_remod.q_i` — entirely **inside the `sd_remod` core itself**, through
the Q8 feed-forward weighted-sum → accumulate → quantize combinational chain.
Data arrival time 61.25 ns against a ~35.5 ns budget — nearly double a clock
period's worth of logic. Not the interp2x wrapper's arithmetic at all.

This is very likely inherited from the 4th-order `sd_remod` fix itself
(2026-09-04), which has never completed a full P&R run on this die on its
own — the one attempt (job 5583) died at DRT-1231 before reaching STA.
interp2x's cell reduction just happened to be what finally let a run get far
enough past routing to expose it.

### 7.3 7-tap compact interpolator (jobs 5600 synth, 5601/5602/5603 P&R)

A second, smaller interpolator design (`sd_remod_interp2x_7tap.v`): centred
7-tap response `[-4,0,19,32,19,0,-4]/64` instead of the 5-tap HB1 reuse, 4
delay stages instead of 5, 14-bit accumulator instead of 20-bit, 4 MAC steps
instead of 10 (the `-4` term is a pure shift, no adder at all).

Standalone synth (job 5600): full module 3,881 cells / 90,236 µm².
Interp2x-only delta: 606 cells / 16,352 µm² — a further −26.6% cells / −26.2%
area vs. the serialized 5-tap, −55.5%/−45.5% vs. the original parallel
5-tap.

Full P&R took three attempts: job 5601 crashed in `OpenROAD.CheckAntennas-1`
(a C++ assertion in the antenna-checker's polygon-intersection code,
`ant::AntennaChecker::Impl::saveGates`/`findNodesWithIntersection` —
confirmed a tool robustness bug unrelated to design/congestion, since routing
itself completed cleanly first); job 5602 was killed by the host OOM killer
(`exit 137`) from unrelated node contention, inconclusive on the crash
question; job 5603 finally completed cleanly (DRC 0, LVS clean) but with **1
remaining antenna violation** (vs. 0 for the serialized 5-tap) — SS WNS
−22.26 ns (better single worst path than the 5-tap serialized version) but
SS TNS −2,444.5 ns (worse aggregate — more paths sitting close to the edge),
utilization 72.7%. Not adopted as-is: this project's antenna-closure bar is
zero violations (job 5198), and the 7-tap variant didn't clear it while the
5-tap serialized version did.

### 7.4 The actual fix: sd_remod_multiplierless.v

`rtl-test/rtl/sd_remod_multiplierless.v` rewrites `sd_remod`'s Q8
feed-forward multiply cone (`w1..w4 = s1..s4 * A1..A4`, a general Verilog `*`
against 10-bit constants) as hand-factored shift/add networks bounded to at
most two adder levels per coefficient (`377=3<<7−7`, `106=3<<5+5<<1`,
`±8`=pure shift), and narrows the final sum 27→25 bits based on a derived
tight bound (`(377+106+8+8)×32768 + 254×256 = 16,416,256 < 2^24`). Same loop
topology, state widths, saturation, coefficients, latency, enable behavior,
and I/O interface — a claimed bit-exact arithmetic substitution, not a
functional change.

**Standalone synth (job 5604):** `sd_remod` 3,275→2,293 cells (−30.0%),
73,884→55,104 µm² (−25.4%) — a much bigger win than anything from the
interp2x work, because a general multiplier against a 10-bit constant
apparently synthesizes to a considerably deeper/larger structure than a
hand-factored two-adder-level network.

The same retained RTL was also compared locally with a reproducible
standalone GF180 FD flow (`abc -D 31250` at TT 25 C/3.30 V, then OpenSTA at
SS 125 C/3.00 V with a 31.25 ns clock):

| standalone metric | deployed `sd_remod` | multiplierless | change |
|---|---:|---:|---:|
| mapped area | 73,884 µm² | 55,104 µm² | −18,780 µm² (−25.4%) |
| worst reg-to-reg data arrival | 53.983 ns | 40.663 ns | −13.320 ns |
| SS WNS at 32 MHz | −23.62 ns | −10.57 ns | +13.05 ns |
| SS TNS | −126.11 ns | −31.54 ns | +94.57 ns |

These are block-level pre-layout results and are supporting evidence only;
jobs 5605/5606 below are authoritative for the complete placed-and-routed
chip. The standalone A/B nevertheless confirms that the improvement is in
the arithmetic structure itself rather than being solely a placement effect.

A carry-save alternative was evaluated and rejected. It expanded the signed
power-of-two partial products into a five-level 25-bit compressor tree. It
remained bit-exact in a 200,000-cycle differential run, but mapped to 77,289
µm² and regressed standalone SS WNS to −15.67 ns. Five serial `xor3`
compressor levels are slower in this GF180 FD library than the retained
two-level Booth-style constant factorizations. The carry-save implementation
was discarded and is not the version in
`rtl-test/rtl/sd_remod_multiplierless.v`.

**Full P&R, two variants, both submitted to `proxmox-agent`** (not
`gaming-pc`, which was already at 24,576/29,820 MiB allocated running job
5603 — confirmed via `hqhost --json` before submitting, per explicit
instruction to check headroom first):

- **Job 5605 (standalone `sd_remod_multiplierless`, no interp2x):** DRC 0,
  LVS clean, antenna 0 violations. **SS WNS −10.78 ns, SS TNS −878 ns**,
  nom_tt WNS 0.0, utilization 69.5%. Squarely inside this design's normal
  clean-signoff range (job 5392: −10.13 ns, job 5527: −14.44 ns, job 3444:
  −12.11 ns) — better than several of them.
- **Job 5606 (`sd_remod_multiplierless` + serialized-I/Q interp2x
  combined):** DRC 0, LVS clean, antenna 0 violations. **SS WNS −16.08 ns, SS
  TNS −1,773.6 ns**, nom_tt WNS 0.0, utilization 71.9%. Also inside the
  normal range, with the droop-compensation interpolator included.

**Conclusion:** the SS timing problem chased across this whole document
(§3-§7.3) was never really about netlist size vs. this die's routing
headroom — it was the general-multiplier synthesis in `sd_remod`'s own Q8
feed-forward cone producing an unnecessarily deep critical path, which
interp2x's growing cell count merely made likely enough to finally surface in
a completed P&R run. Fixing that at the source resolves it with margin to
spare, standalone or combined with the droop fix, on the standard
config — no P&R-side workaround needed.

## 8. Bit-exact equivalence verification (sd_remod vs sd_remod_multiplierless)

New testbench `rtl-test/tb/tb_sd_remod_multiplierless_equiv.v`: instantiates
both `sd_remod` and `sd_remod_multiplierless` side by side with identical
clk/rst/in_i/in_q/in_valid/en, asserts `out_i`/`out_q` match every cycle
post-reset. A direct bit-for-bit equivalence check (not an SQNR/spectral
regression), which is the correct test for a claimed-bit-exact arithmetic
substitution. Three phases: directed extremes (full-scale ±127/-128 steps
and alternating rails, to hit the saturating-integrator corners and the
exact +32768-class overflow region the multiplierless header's own bound
depends on), dense random stimulus (`in_valid` every cycle, 4,000 samples),
and a realistic OSR=64-paced random run (500 samples) to exercise the
`sat16` integrator trajectory over a more representative run, not just
single-step transitions. New Makefile target:
`sim_sd_remod_multiplierless_equiv`.

**Result: PASS (job 5608)** — 35,660 samples, 0 mismatches across all three
phases. `sd_remod_multiplierless` is confirmed bit-exact against the current
`sd_remod`, including at the exact ±32,768-class saturation corners the
module's own 25-bit-sum bound derivation depends on. (Job 5607 failed to
build first — the run script only staged `rtl-test/`, not the sibling `src/`
tree the Makefile's new `src/`-relative paths needed; fixed by staging both.)

Combined with the full-P&R results in §7.4 (jobs 5605/5606, both fully clean
signoffs inside this design's normal SS-timing range), `sd_remod_multiplierless`
is now a verified, drop-in-equivalent candidate to replace the deployed
`sd_remod`'s arithmetic — not yet promoted to `src/`, that decision is still
open.

### 7.5 DRV (max slew/cap) tightening on top of job 5606 -- tried, REJECTED (job 5609)

Job 5606's max-slew/max-cap violation counts (nom_tt 7/16, SS 12/44) are
elevated relative to this project's best-tuned historical baseline (job 5491:
`GRT_DESIGN_REPAIR_MAX_SLEW/CAP_PCT` 65->50, SS 7/1, nom_tt 0/0 -- a "strict
win" on the pre-interp2x/pre-multiplierless netlist, never applied to the
canonical config). Applying that exact same tightening on top of job 5606
(`proxmox-agent`, confirmed free before submitting) **FAILED**, same failure
signature and stage as the whole §3 campaign: `[DRT-1231] Pin
clkbuf_0_IQ_CLK_regs/I does not have access point`, step 46/80.

Mechanism, and why this is the opposite failure mode from job 5595 (§3.4) but
the same underlying lesson: tightening the post-GRT repair margin makes that
pass *more* aggressive, inserting more corrective buffers pre-route to hit
the stricter threshold -- adding cells/congestion back into the exact region
the multiplierless area reduction had only just barely cleared. This
netlist evidently has little routing-headroom margin to spare near the
clock tree, so the safe range for this knob (proven safe on a different,
smaller netlist) is narrower here.

A second, more conservative probe (job 5610, 65%->60%, a much smaller step)
**also FAILED** -- same mechanism, `[DRT-0073] No access point for
clkbuf_2_1_0_IQ_CLK_regs/I` (same clkbuf family, a related error code to
DRT-1231 for the same "no legal access point" condition). Confirms this
isn't a threshold specific to 50% -- there is essentially **zero headroom**
on this knob in either direction for this netlist; any tightening at all
reintroduces the routing failure. **REJECTED** at both 50% and 60%: job
5606's default 65% margin remains the only clean candidate found; the
elevated DRV counts are real but this specific proven-elsewhere fix is not
safe to apply to this combination at any tested tightening.

An additional local 200,000-clock differential run exercised production-like
OSR=64 input pacing, random valid I/Q samples in the supported `[−90,+90]`
range, arbitrary changes on the ignored input pins while `in_valid=0`, and two
disable/re-enable intervals. It also completed with zero I/Q output
mismatches.

The final retained Booth-style RTL was then substituted into the canonical
`cocotb/remod_sqnr` fidelity regression. Both tests passed:

| stimulus | SQNR | RMS error | fitted gain |
|---|---:|---:|---:|
| amp 64, 20 kHz | 46.82 dB | 0.2916 LSB | 0.9988 |
| amp 64, 60 kHz | 46.71 dB | 0.2890 LSB | 0.9781 |
| amp 40, 40 kHz | 41.01 dB | 0.3518 LSB | 0.9879 |
| amp 85, 40 kHz | 48.57 dB | 0.3132 LSB | 0.9884 |
| post-amplitude-transition tail | 48.24 dB | 0.3253 LSB | 0.9883 |

The transition case retained dither (longest identical-bit runs: I=9 clocks,
Q=8 clocks). Since the candidate produces the same one-bit sequences as the
deployed arithmetic, the multiplierless rewrite neither improves nor degrades
passband flatness. The existing fs/4 droop and its interp2x compensation remain
a separate question.

Local reproduction artifacts:

- `rtl-test/rtl/sd_remod_multiplierless.v`
- `rtl-test/tb/tb_sd_remod_multiplierless_equiv.v`
- `rtl-test/syn_mimo_per_module/run_sta_remod_multiplierless.sh`

### 7.6 DRV/WNS knob-probe batch on the PROMOTED canonical config (jobs 5613-5620)

After the 2026-09-05 promotion (see the doc header), six one-knob probes off
the canonical `trouper_top_minff_rcx.json` were run to see whether any
tool-side setting could reduce the residual max cap/slew counts. The
LibreLane step definitions were read directly (`openroad.py` +
`rsz_timing_postgrt.tcl` inside the `chipathon26` image) to pick knobs that
target WNS/DRV without changing the margin threshold that had already been
shown unsafe in §7.5.

**First, a positive result that came for free: the promotion itself
improved timing and DRV.** The promoted flat `sd_remod.v` (interpolator +
`sd_remod_multiplierless` core) synthesizes to a better netlist than the
pre-promotion nested experiment wrappers (`trouper_top_interp2x_multiplierless_experiment.v`
around `sd_remod_interp2x_multiplierless.v` around `sd_remod_multiplierless.v`):

| | job 5606 (pre-promotion experiment config) | promoted canonical (jobs 5613/5614/5615, identical) |
|---|---|---|
| SS WNS | −16.08 ns | **−12.99 ns** |
| SS TNS | −1,773.6 ns | **−1,297.3 ns** |
| max cap (tot/SS/nom_tt) | 12 / 12 / 7 | **2 / 2 / 1** |
| max slew (tot/SS/nom_tt) | 44 / 44 / 16 | **11 / 11 / 2** |
| DRC / LVS / antenna | 0 / clean / 0 | 0 / clean / 0 |

nom_tt DRV on the promoted design (1 cap / 2 slew) is *better* than the last
pre-remod-work `a40_minff_rcx` baseline (job 5563: 2 cap / 4 slew) and
roughly matches the tightest clean signoffs this project has ever produced
(jobs 5511/5527: 2 cap / 2 slew nom_tt, 3 cap / 9 slew SS). It is NOT a
regression -- module hierarchy shape measurably affected synthesis QoR here.

**The knob probes themselves found nothing to adopt:**

| probe | knob | result |
|---|---|---|
| 5613 | `GRT_RESIZER_SETUP_MAX_BUFFER_PCT` 40→60 | NO-OP -- byte-identical WNS/TNS/DRV to the untouched baseline (−12.985961118434266 to 15 d.p.) |
| 5614 | `GRT_RESIZER_SETUP_MAX_BUFFER_PCT` 40→70 | NO-OP -- byte-identical again |
| 5615 | `GRT_RESIZER_SETUP_REPAIR_TNS_PCT` unset→100 | NO-OP -- byte-identical; OpenROAD's default `-repair_tns` already covers all endpoints |
| 5618 | `CTS_SINK_BUFFER_MAX_CAP_DERATE_PCT` 50 (stronger clock buffers) | FAILED -- `[DRT-0073] No access point for clkbuf_4_5_0_IQ_CLK_regs/I`, step 46/80 |
| 5619 | `GRT_RESIZER_FIX_HOLD_FIRST` true | NET WASH -- signoff fully clean (DRC 0, LVS 0, antenna 0) but SS WNS −13.28 (0.30 ns worse than the −12.99 baseline), SS TNS −1,310, SS cap/slew 3/8 (baseline 2/11), TT cap/slew 1/2 (unchanged). Trades 3 SS slew violations for 0.30 ns more setup loss + 1 more SS cap. Not adopted. |
| 5620 | `CTS_APPLY_NDR` half→full | FAILED -- `[DRT-0073] No access point for clkbuf_4_6_0_IQ_CLK_regs/I`, detailed routing. Full non-default routing rules on the clock tree crowd IQ_CLK clkbuf pin access -- same failure class as 5618 and §7.5. |

The buffer-budget no-ops confirm the setup resizer never exhausts even its
default 40% budget on this netlist, so raising it does nothing. The
`CTS_SINK_BUFFER_MAX_CAP_DERATE_PCT` (5618) and `CTS_APPLY_NDR=full` (5620)
failures confirm CTS-side clock-tree strengthening is in the same risk class as
§7.5's margin tightening -- it adds cells/drive/routing resource near the
IQ_CLK tree and reintroduces the exact DRT-0073 routing-access failure the
whole §3 campaign chased. `GRT_RESIZER_FIX_HOLD_FIRST` (5619) is the only
probe that completed AND stayed signoff-clean, but it is a wash: 3 fewer SS
slew violations bought at the cost of 0.30 ns more SS setup loss + 1 more SS
cap violation, with TT DRV unchanged.

**Standing lesson (make this the takeaway):** the max cap/slew counts on
this die are effectively at the floor. Every P&R lever that adds
cells, buffering, or routing resource near the IQ_CLK clock tree either
does nothing (the resizer isn't budget-limited) or reintroduces
DRT-1231/DRT-0073. Reducing them further requires an RTL netlist reduction
or a floorplan change, not a tool knob. Do not re-probe
`GRT_RESIZER_SETUP_MAX_BUFFER_PCT`, `GRT_RESIZER_SETUP_REPAIR_TNS_PCT`,
`GRT_DESIGN_REPAIR_MAX_SLEW/CAP_PCT` (either direction),
`GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH`, `CTS_SINK_BUFFER_MAX_CAP_DERATE_PCT`,
`CTS_APPLY_NDR=full`, or `GRT_RESIZER_FIX_HOLD_FIRST` without a new mechanism.

## 9. Review findings fixed alongside this investigation (2026-09-05)

Three findings from a separate code review, verified against the actual RTL
before fixing (all confirmed real, not fixed blind):

- **`rtl-test/Makefile` stale RTL** (`DSP_SRCS` pulled `sc_detector.v`,
  `training_acc.v`, `mrc_combiner.v` from `rtl-test/rtl/` copies diverging
  190/170/11 lines from `src/`, and referenced `frontend_buf_ctrl.v`, a
  module removed from `src/` entirely). Fixed: `DSP_SRCS`/`DSP_SRCS_RAND` and
  the standalone `mrc_combiner`/`sd_remod` targets now source `src/`
  directly; legacy-only dependencies (`frontend_buf_ctrl.v`,
  `sd_decimator_cic_only.v`) stay sourced from `rtl-test/rtl/` only where
  testbenches actually instantiate them. `TROUPER_TOP_SRCS` (trouper_top.v +
  400+ diverged lines) left alone with a comment pointing at `cocotb/` as
  canonical — not safe to repoint blindly (port interfaces changed).
- **`mrc_combiner.v` width** (`prod_i_r`/`prod_q_r` 16-bit, `acc_i`/`acc_q`
  18-bit — both exactly one bit short of the positive endpoint reachable at
  legal int8 rail extremes: `w_re=w_im=x_i=x_q=−128` gives a per-branch
  product sum of exactly +32,768, and the 4-branch accumulator sum of
  exactly 131,072). Fixed: widened to 17-bit / 19-bit respectively.
- **`sc_detector.v` one-hit diagnostic bug** (`sc_first_hit_dbg` read the
  pre-update `first_hit_sample` register on the same edge it was being
  written, when `sc_hits_req==0` makes `hit_count==0` and
  `hit_count==sc_hits_req` the same condition — a real nonblocking-assignment
  same-cycle hazard, confirmed by tracing the exact mechanism). Fixed: reads
  `eval_sample_mark` directly in that case; normal multi-hit locking
  (unaffected per the review) still uses the register.

**Not fixed, deliberately:** `dc_removal.v` output wraparound is already
tracked (`TRPR-DCR-007`) and gated on a real AFE PCB DC-vs-LNA-gain
measurement due the week of 2026-09-08 — re-deciding it now would preempt
that measurement. `training_acc.v`'s possible same-cycle epoch race (armed
noise-window abort vs. final-sample completion, both nonblocking-driven off
the same always block) is plausible but unconfirmed — needs the directed
collision test the original review already suggested before any RTL change.
