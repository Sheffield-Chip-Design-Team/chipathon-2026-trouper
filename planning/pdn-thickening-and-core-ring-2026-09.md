# PDN thickening and Metal4/Metal5 core ring — 2026-09-02

Record of the PDN work on `trouper_top`: what was measured, what was adopted,
and two methodology findings that turned out to matter more than the PDN change
itself.

**Outcome:** stripe width 1.6 → 4.0 µm plus a 5 µm Metal4/Metal5 core ring, in
the unchanged 1675×1110 die, folded into `src/config/trouper_top.json`
(job 5379, clean signoff). Pitches deliberately left at the PDK default.

---

## 1. Baseline and motivation

The question was whether the PDN could be thickened and a ring added without
growing the die. Starting point (job 5286 signoff): PDK-default 1.6 µm stripes
on a ~153 µm pitch, **no core ring**, and power entering from the A40 template
as two localized Metal2 pin clusters at opposite edges — VSS west-low, VDD
north-right. A ring spreads that single point of entry.

The upper metal looked nearly free, which is what suggested the change was cheap:

| Layer | GRT usage (5286) | Role |
|---|---|---|
| Metal2 | 40.2 % | signal |
| Metal3 | 48.1 % | signal |
| Metal4 | 2.4 % | PDN vertical |
| Metal5 | 10.8 % | PDN horizontal |

**That reasoning was wrong, and the correction is the main technical finding
here — see §3.** Metal4/Metal5 occupancy was never the binding constraint.

## 2. The core-margin mechanism (how a ring fits without growing the die)

A ring needs `offset + 2*width + spacing` per side. LibreLane's core margin comes
from multipliers, not a micron value: `LEFT/RIGHT_MARGIN_MULT` × 0.56 µm site
and `TOP/BOTTOM_MARGIN_MULT` × 3.92 µm row. At baseline that put the core rows
within **6.72 µm** of the die edge horizontally and 15.68 µm vertically.

Ring width drives everything downstream:

| Ring width | Needs/side | Margins required | Core area lost | Result |
|---|---|---|---|---|
| 9 µm | 22 µm | H 45, V 7 | 4.4 % | **job 5367 FAILED** — DRT-0073 |
| 5 µm | 14 µm | H 27, V **4 (unchanged)** | 1.0 % | job 5379 clean |

At 5 µm the vertical margin already clears the requirement, so **the core loses
no height at all** and only the horizontal multiplier moves (12 → 27). That is
the whole reason this fits.

Core area here is routability budget, not spare room: per the config's
`_comment_density`, 72 % density hit DRT-0073/DRT-1231 on this die and 65 % is
what cleared it. The 9 µm ring pushed utilization 66.2 % → ~69 % and died in
detailed routing on `clkbuf_regs_0_IQ_CLK/I`. **Do not widen the ring without
re-proving detailed routing.**

## 3. Why the pitch stays at the PDK default

`add_pdn_connect` ties the Metal1 followpin rails up to Metal4, so **every stripe
crossing punches a via ladder through Metal2 and Metal3** — the layers that carry
all the signal routing. Halving the pitch doubles those ladders:

| Config | PDN shapes | Metal2 resource | SS TNS | IR VDD / VSS |
|---|---|---|---|---|
| 5378 stock (control) | 9 572 | 255 538 | −336.1 | 3.28 / 3.26 mV |
| **5379 width-only** (adopted) | 9 900 | 247 153 | −383.5 | 3.61 / 2.15 mV |
| 5370 width + halved pitch | 19 794 | 233 221 | −528.5 | 1.32 / 0.90 mV |

Halving the pitch costs 8.7 % of Metal2 resource and **57 % of SS TNS**. Holding
it keeps geometry near stock and cuts the TNS cost from ~192 ns to ~47 ns.

Two honest caveats on the adopted config:

- **VDD drop got slightly *worse* than stock** (3.28 → 3.61 mV) and only VSS
  improved (−34 %). The 2.5× VDD gain in 5370 came from stripe density, not the
  ring. No mechanism established for the VDD regression.
- At n=1 per config, part of the ~47 ns TNS delta is placement/repair lottery
  rather than the PDN — 5379's WNS came in 1.04 ns *better* than its control.

### 3.1 Relaxing the pitch does not help either — closed 2026-09-02

The obvious follow-up, once the ring was in: if *denser* costs TNS via via-ladder
obstruction, does *sparser* recover it? The ring was the stated reason to try —
lateral spreading no longer depends on stripe count alone, so stripes could in
principle be spent down. Two arms were run against 5392, varying only
`PDN_VPITCH`/`PDN_HPITCH` with width, ring, margins and density held identical:

| Pitch | Job | SS WNS | SS TNS | Wirelength | IR VDD / VSS | Result |
|---|---|---|---|---|---|---|
| ×0.5 | 5370 | — | −528.5 | +3.9 % | 1.32 / 0.90 mV | clean; **−192 ns** |
| ×1.0 | **5392** (canonical) | −10.130 | **−383.5** | 2 137 601 | 3.61 / 2.15 mV | clean signoff |
| ×1.2 | 5393 | — | — | — | — | **FAILED DRT-0073** |
| ×1.4 | 5394 | −10.438 | −388.3 | 2 120 455 (−0.80 %) | 2.82 / 2.19 mV | clean signoff; **no gain** |

**Verdict: the pitch is not a lever in either direction. Leave it at the PDK
default.** The baseline already sits on the flat part of the curve.

The mechanism from §3 was confirmed working, and that is what makes the negative
credible rather than merely inconclusive. Measured in the 5392 final DEF: **3036
via ladders** = 138 per stripe (every other Metal1 followpin rail, since a given
stripe is either VDD or VSS) × 22 stripes, each planting a 4.0 × 0.6 µm landing
pad on *both* Metal2 and Metal3 (`via2_3_8000_1200_1_7_1040_1040`). At ×1.4 the
grid drops to 8 M4 pairs + 6 M5 pairs (from 11 + 8), removing ~18 % of the
ladders — and routing responded exactly as predicted: **−0.80 % wirelength,
−0.53 % vias, Via3 28507 → 22132**. It simply did not convert into timing.

Why it cannot convert: the SS gap here is a **voltage** problem, not a routing-
detour problem (−10 ns WNS at 3.0 V, closing at 4.5 V — see
`project_vdd_closes_ss_timing`). A 0.8 % wirelength change cannot move a −383 ns
TNS dominated by cell delay at a starved corner. The 4.8 ns TNS delta at ×1.4 is
1.3 % of the base, inside the placement/repair lottery band this document already
documents for n=1.

Two further reasons not to revisit it:

- **IR drop is not a binding constraint**, so there is nothing to buy. Worst case
  is ~3 mV on a 3.3 V rail (~0.1 %). Note the ×1.4 VDD figure *improved*
  (3.61 → 2.82 mV) with **fewer** straps — no mechanism, and it mirrors the
  equally unexplained 5379 VDD regression in §3. Both are consistent with VDD IR
  being set by the A40 template's localized Metal2 entry cluster rather than by
  stripe density. Do not cite either number as evidence.
- **Any pitch change re-rolls routability on a marginal die.** Job 5393 (×1.2)
  died in detailed routing on `[DRT-0073] No access point for
  clkbuf_2_1_0_IQ_CLK_regs/I` — the same `IQ_CLK` clock-buffer pin-access family
  that has hit this floorplan repeatedly (5367, and the DRT-1231 recurrence).
  1 of 2 arms failed outright, for zero measured benefit.

The ×1.2 point was deliberately **not** re-run: it lies between two points that
both show no gain, so no decision hinges on it. A re-run would only test whether
that DRT-0073 was re-rollable — a question about the clock tree, not the PDN.

Caveats on the above: n=1 per arm, and KLayout DRC is vacuous in both 5392 and
5394 (see §7), so "DRC clean" rests on Magic alone. Trial configs
`trouper_top_pdn_pitch120.json` / `_pitch140.json` and their run scripts were
deleted as superseded; recover them from git history if the arms need repeating.

## 4. Baseline discipline: job 5286 is NOT a valid comparison

All three early trials were compared against job 5286 before anyone noticed the
netlists differ: 5286 ran 2026-08-30, **before** the 2026-09-01 Grouper-boundary
removal from `src/top/trouper_top.v` (35670 → 35300 cells).

This produced a ~7 ns SS WNS "improvement" (−18.23 → −11.16) that was **entirely
the RTL change**. The same-netlist stock-PDN control, **job 5378**, measures
−11.17 ns. The PDN contributes 0.01 ns.

Two routing failures (5367, 5369) were also provisionally blamed on the PDN
before the control existed; per the config's `_comment_cts_spi_sck`, the
DRT-0073/DRT-1231 pin-access family is sensitive to netlist *size*, so that
attribution was never established and remains open. **Always run the
same-netlist control arm before attributing a P&R delta to a config knob.**

## 5. IR-drop numbers here are optimistic — see Open Risks #56

Every IR figure in this document comes from LibreLane's **default
`LIB_VOLTAGE`/BTerm-source** mode, which treats every top-level power pin as an
idealized current source. `VSRC_LOC_FILES` is not set in any Trouper config.

This matters for how the work was justified. The absolute numbers (0.10–0.14 %)
were repeatedly used mid-investigation to argue the PDN improvement was not
worth its TNS cost. That argument leans on a number the flow is known to make
optimistic: the real-source analysis on the combined die came back at **~3–5 %**,
not 0.1 %.

The **relative** comparison between configs in §3 is still valid — same flow,
same mode, same netlist. The **absolute** margin claim is not. Anyone revisiting
the width-vs-TNS trade should redo it against a real-source analysis before
concluding the headroom is free.

Note also that #56's stated mitigation (Trouper implemented on a shared die with
Grouper, whose combined analysis supplies the real number) predates the
2026-09-01 decision that **Grouper is not taping out**. Whether that mitigation
still holds under A40 needs revisiting; not resolved here.

## 6. Ring-to-pad boundary connection probe (job 5392)

Job 5392 enabled `PDN_CORE_RING_CONNECT_TO_PADS: true` in the canonical
configuration. It completed cleanly: Magic DRC 0, XOR 0, LVS clean, antenna
0, and PDN violations 0. Its post-route timing and default BTerm-source
IR-drop metrics reproduced the preceding canonical job 5379:

| Metric | Job 5392 |
|---|---:|
| SS WNS / TNS | −10.130 ns / −383.51 ns |
| VDD worst drop | 3.61 mV (0.11%) |
| VSS worst drop | 2.15 mV (0.07%) |

This is a no-regression check only. `trouper_top` is a hardened macro with
**zero pad cells**, and its boundary supplies are only `VDD` and `VSS` Metal2
pins from the A40 template. Consequently the run verifies that a core ring
may connect to those boundary power taps without breaking the macro P&R; it
does **not** create or measure a physical connection to the shared padframe's
`DVDD`/`DVSS` terminals, and it cannot measure pad-driver IR drop. That
requires a rerunnable full-chip padframe integration (top-level source,
pad-placement data, LEF abstracts and PDN configuration), which is not in the
2026-09-01 final-GDS snapshot.

## 7. KLayout DRC was never running

`RUN_KLAYOUT_DRC` is `True`, but **`KLAYOUT_DRC_RUNSET` is unset**, so step
`67-klayout-drc` exits in **11 ms**, writes no report, and emits no metric — and
`69-checker-klayoutdrc` then *passes*, because the metric is absent rather than
zero. This is true of every run in this design's history, 5286 included. Magic
DRC (0), Netgen LVS (0), KLayout XOR (0) and router DRC (0) were all genuinely
running; the KLayout deck was not.

The PDK does ship one (`libs.tech/klayout/tech/drc/gf180mcu.drc`). Run standalone
against 5379's GDS (job 5384): **62 of 63 tables clean**, including `metal1`–
`metal5`, `metaltop`, `via1`–`via5`, all `_split` variants and
`dummy_metal1`–`dummy_metal5`. `contact` — the slowest table at 3 726 s — landed
last and is also **0**. The one table that did not run was `mslot`, on a PDK deck
bug (below).

With that bug fixed, job **5391** runs `mslot` too and the guard certifies the
run:

```
tables expected : 63     reports missing : 0     reports truncated: 0
exceptions      : 0      violations      : 0
RESULT: PASS (all 63 tables ran, 0 violations)
```

**This is the first genuine KLayout DRC signoff in the design's history.** The
`mslot` report is a real one — 1 976 B, all nine rule categories
(`MSLOT.0`–`MSLOT.9`) declared — against the 441 B header-only stub the crashed
runs left behind. That distinction is the whole point: both report "0 items".

### The `mslot` PDK bug

`mslot` crashed — and left a well-formed **empty** `.lyrdb` that reads as
"0 items", i.e. indistinguishable from clean. Cause is a deck bug, not our
geometry and not resources (it reproduces running alone with the full memory
budget, job 5390).

`rule_decks/layers_def.drc` defines each layer only when the table being run
appears on that layer's whitelist:

```ruby
contact_tables = %w[contact contact_split efuse geom dnwell ... main]
if contact_tables.include?(TABLE_NAME)
  contact = get_polygons(33, 0)
end
```

`"mslot"` appears on **no whitelist anywhere in the file**, yet `mslot.drc` uses
`contact`, `via1` and `via2`. Under `TABLE_NAME=mslot` those three are `nil`, and
the slotting loop dies on its **first** iteration — metal1, whose `via_below` is
`contact`:

```
NoMethodError: undefined method `sized' for nil:NilClass
  mslot.drc:470:in `block in execute'
```

Unconditional and geometry-independent. `via3`, `via4` and the `metal*_drawn` /
`metal*_slot` layers are defined ungated, so only three whitelists need the entry.
The guard script adds it (`rtl-test/scripts/klayout_drc_guarded.sh`) against a
writable copy, since `/foss/pdks` is read-only.

**Two wrong diagnoses preceded this, both worth recording.** The unpatched line
470 reads `... - via_below.sized(0.2) - via_above.sized(0.2)`, and I attributed
the nil to `via_above` on the metal5 entry, whose `slots_hash` value is
`polygon_layer` — concluding that `polygon_layer` was undefined. It is not: it is
a KLayout DRC DSL constructor for an empty polygon layer, used the same way in
`mim_a.drc`, and the metal5 entry is correct as written. The actual nil was
`via_below` on **metal1**. I read the deck at the one use site the traceback named
and inferred the rest instead of checking where the layer was defined.

The fix that followed from that wrong cause — nil-guarding the dereferences — was
**not merely incomplete, it was unsafe**. `metal_slotted` is built by subtracting
contact and via areas from the drawn metal; skipping those subtractions when the
layer is nil leaves MSLOT.1 checking the wrong geometry and reporting a clean 0.
It would have converted a loud crash into a silent false pass — the exact failure
mode this whole section exists to prevent. Fixing the layer definitions is the
only correct repair; the nil-guards have been reverted.

Not a concern for this change regardless: `MSLOT.1`'s threshold is **30 µm**
metal width and our widest metal is the 5 µm ring, and we draw no slot shapes so
`MSLOT.0` has nothing to check.

**Signoff note:** this still means running a locally modified rule deck, though
the modification is now three whitelist entries in `layers_def.drc` rather than
altered rule logic. Since `mslot` passes at zero once it runs, no rule needs
waiving and the waiver question is moot — but the patched-deck dependency stands
until it is fixed upstream. It is a PDK bug, not a Trouper one: `mslot` is
unrunnable for any gf180mcuD design, so it is worth reporting.

## 7. Guard script

`rtl-test/scripts/klayout_drc_guarded.sh`. The recurring hazard in all of the
above is that **failures are indistinguishable from passes**: a vacuous checker,
a crashed table reporting 0 items, and (twice, in this session's own tooling) a
completion monitor firing on a condition that could never match. Counting
violations is not verification; verifying that every check *ran* is.

The script asserts, before reading any count: `run_drc.py` exit code; zero
`"generated an exception"` lines in the log; one complete `.lyrdb` per generated
table (excluding the `layers_def` include), each with its closing tag. Exit
codes separate the cases — **2 = run incomplete** (violation count explicitly
untrustworthy), **3 = real violations**, **0 = all tables ran, zero violations**.
The layers_def patch fails the run loudly if a whitelist is not found, so a PDK
update cannot silently restore the crash-as-clean behaviour.

**Only one of those three checks is load-bearing here**, and it is worth being
precise about which. On the 5384 crash, `run_drc.py` still exited **0**, and the
`mslot` stub `.lyrdb` *does* carry its closing `</report-database>` tag — so the
exit-code check and the completeness check both pass a table that never ran. The
exception grep is the only one that catches it. The other two are not redundant
(they catch different failures: a killed process, a truncated write), but neither
should be read as evidence that a table ran.

**The guard had a bug of exactly the kind it exists to catch.** Its exception
count was written `exc=$(grep -c ... || echo 0)`. `grep -c` prints `0` *and*
exits 1 when there is no match, so `|| echo 0` appended a second line and `$exc`
became the unparseable `"0\n0"`; `[ "$exc" -gt 0 ]` then errored and was treated
as false. It happened to behave correctly whenever exceptions existed (the count
is a clean `1`), so the failure was invisible in every run that mattered — and it
surfaced only as a stray `0` in the 5391 summary block. Fixed to
`exc=$(grep -c ...); exc=${exc:-0}`. This is the third instance of this one idiom
producing a false negative in this session's own tooling (twice in completion
monitors, once here); it is worth treating `grep -c ... || echo 0` as simply
wrong.

A fourth check would be stronger than all three: assert that each report declares
its rule categories. A crashed table emits the XML header and nothing else, so
`<category>` count is a direct signal that the rule logic executed — which is the
property actually being claimed. Not implemented; noted as the obvious next
hardening.

**`run_drc.py` prints its own verdict, and that verdict is wrong.** On both 5384
and 5386 — runs that lost `mslot` to an exception — it ends with:

```
INFO | Klayout DRC run is clean. GDS has no DRC violations.
```

It counts violations across the reports that exist and never checks whether every
table produced one. Anyone reading the tail of that log would sign off a run with
a dead table. This is the single strongest argument for the guard.

**Exit codes are 10/11, not 2/3.** Job 5386 exited **2** — the code meaning "run
incomplete" — from `error reading input file: Stale file handle`: bash lost the
script mid-execution because it was rsynced over on the shared mount while the
job was running it. The verdict looked right and was produced by an entirely
unrelated failure; the validation logic never ran at all. Low exit codes collide
with the shell's own, so they moved to 10 (incomplete) and 11 (violations). The
operational rule that follows: **never overwrite the script on NFS while a job is
executing it** — stage a per-job copy instead. This is the same class of hazard as
everything else in this section, arrived at from the other direction: here the
*guard's own pass/fail channel* was the thing that could not be trusted.

Defaults `MP=4 THR=4`, down from 8×8: each concurrent table holds the full
layout in flat mode (measured 2.0 GB RSS).

## 8. Job index

| Job | Config | Result |
|---|---|---|
| 5286 | canonical, pre-Grouper-removal RTL | clean — **not a valid baseline** |
| 5367 | width + halved pitch + 9 µm ring | FAILED DRT-0073 |
| 5369 | width + halved pitch, no ring | FAILED DRT-1231 |
| 5370 | width + halved pitch + 5 µm ring | clean; best IR, worst TNS |
| 5378 | **control** — current RTL, stock PDN | clean; the valid baseline |
| 5379 | **adopted** — width + 5 µm ring, default pitch | clean signoff |
| 5384 | standalone KLayout DRC on 5379 GDS | **62/63 = 0 violations**; `mslot` crash |
| 5386 | guarded DRC, nil-guard on line 50 | same crash, moved to `MSLOT.7`; exit 2 was a stale NFS handle, not the guard |
| 5387 | guarded DRC, both nil-guards | same crash — wrong root cause |
| 5390 | mslot standalone, stderr captured | root cause: `layers_def` whitelists |
| 5391 | guarded DRC, whitelists patched | **PASS — 63/63 ran, 0 violations** |
| 5392 | **canonical** — ring + `CONNECT_TO_PADS`, default pitch | clean signoff; the valid baseline for §3.1 |
| 5393 | pitch ×1.2 (184.32 / 183.82) | **FAILED DRT-0073** on `clkbuf_2_1_0_IQ_CLK_regs/I` |
| 5394 | pitch ×1.4 (215.04 / 214.45) | clean signoff; **TNS −388.3, no gain — §3.1** |
