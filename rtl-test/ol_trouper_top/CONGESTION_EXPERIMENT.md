# trouper_top congestion / area experiments

## Problem

`trouper_top` P&R lands a **~8.59 mm² die at only ~24.6 % std-cell utilization**
(run `RUN_2026-05-29_17-23-37`, FP_CORE_UTIL 28 / density 36). The die is big
because utilization is forced low, **not** because of timing (the design has
**+38.8 ns setup slack** at 16 MHz) or logic size. So the question is purely
routability: how dense can this block route, and what limits it?

## Root-cause analysis (from the routed run)

GF180MCU has 5 metals, but in this flow only **two carry signal**:

| Layer | Role | Routed signal wire |
|---|---|---|
| Metal1 | power rails (`followpins`) + cell pins | 0 (min routing layer = M2) |
| **Metal2** (V) | **signal** | 1,434,619 µm (51 %) |
| **Metal3** (H) | **signal** | 1,258,305 µm (44 %) |
| Metal4 (V) | PDN vertical straps (sparse) | 98,935 µm (3.5 %) |
| Metal5 (H) | PDN horizontal straps (sparse) | 37,767 µm (1.3 %) |

**95 % of all wire is on M2+M3.** As utilization climbs, all the extra demand
piles onto those two layers, they saturate, and detailed routing fails
(`DRT-0073` no-access-point — the documented density wall). Timing slack can't
relieve a track-count limit, which is why the over-margined top still won't pack.

### Key finding: M4/M5 are *not* blocked — the router just won't use them

The PDN is already sparse: `PDN_VPITCH 153.6 µm`, strap pairs ~5 µm wide → power
consumes only ~3 % of M4 tracks, so **M4/M5 are ~97 % physically free**. Yet the
router used them at 0.3 %. Cause: `GRT_LAYER_ADJUSTMENTS = [0,0,0,0,0]` (no
per-layer bias) + the global router's default preference for the lowest layers.
So at low util it never needs to spill up, and at high util it apparently fails
(DRT-0073) rather than spilling onto the free upper layers.

So the lever is **not** widening the PDN (already sparse) — it's **biasing the
global router to use M4/M5**.

## Known issue: 36 "Illegal overlap obsv2/metal2" in Magic.SpiceExtraction

The util sweep runs route cleanly (route DRC = 0) and write final metrics, but
**exit nonzero**: the `Magic.SpiceExtraction` step (runs even with `RUN_LVS:
false`) emits **36 identical** feedbacks `"Illegal overlap between obsv2 and
metal2 (types do not connect)"` (severity medium, ~0.056×0.12 µm slivers along a
single macro horizontal edge), and these are treated as deferred (fatal) errors.

Root cause: both SRAM macro LEFs (`gf180mcu_fd_ip_sram__sram512x8m8wm1`,
`gf180mcu_ocd_ip_sram__sram1024x8m8wm1`) declare **Metal2 pins AND Metal2 OBS on
the same edge**. The detailed router must drive Metal2 up to those pins; at the
pin edge the wire/via abuts the macro's own Metal2 obstruction (`obsv2`), and
Magic's extraction flags the touch. The 12 µm `FP_MACRO_*_HALO` doesn't prevent
it — a halo is a placement/PDN keep-out, but routing still has to reach the pins.

**Assessment:** LVS-extraction artifact at macro pin edges, **not** a
routing/DRC defect (route DRC = 0). Not yet confirmed 100% benign vs a real
over-OBS route — would need the 36 boxes overlaid on the macro outline; route
DRC = 0 argues benign.

**Handling now:** the sweep scripts skip the step
(`librelane --skip Magic.SpiceExtraction`) so runs complete cleanly; the
area/routability numbers are unaffected (GDS + final metrics are produced before
this step anyway).

**MUST fix before tapeout signoff** (one of): trim the macro LEF Metal2 OBS so
it doesn't abut its own pins; treat the SRAMs as true magic abstracts (don't
extract their internal geometry); or formally waive these as known macro-pin
artifacts after confirming KLayout signoff DRC is clean.

## Experiment A — utilization sweep (baseline wall)

Find where the *unmodified* flow breaks. Configs `config_util40/55/70.json`
(based on `config_area_t12`, which has the macro placement; FP_CORE_UTIL
40/55/70, density +5, default GRT layers). SGE jobs **1054 / 1055 / 1056**.

Per point, collect: does DRT complete? final die area + achieved utilization,
and *how* it fails (DRT-0073 pin access vs M2/M3 overflow). Baseline reference:
util 28 → 8.59 mm² / 24.6 %.

## Experiment B — push signal onto M4/M5 (layer-adjustment)

Same high-util points, but bias the global router to spread onto the free upper
layers. Configs `config_layeradj_util55/70.json`:

```json
"GRT_LAYER_ADJUSTMENTS": [0, 0.5, 0.5, 0, 0],   // [M1,M2,M3,M4,M5]
"GRT_ADJUSTMENT": 0.2
```

This heavily derates M2/M3 (so GRT treats them as ~50 % smaller and routes the
trunk of nets up) while keeping M4/M5 at full capacity. If routing uses M4/M5
and completes where Experiment A fails — or completes with lower congestion —
that turns the 2-layer routing problem into a 3-layer one (~50 % more capacity)
and is the path to a **smaller die at higher utilization**.

Wrappers: `rtl-test/run_mimo_layeradj_util55.sh`, `..._util70.sh`.

### Comparison to make

| Run | util | GRT layers | DRT done? | die area | M4/M5 wire % |
|---|---|---|---|---|---|
| baseline (1054) | 40 | default | _TBD_ | _TBD_ | _TBD_ |
| baseline (1055) | 55 | default | _TBD_ | _TBD_ | _TBD_ |
| baseline (1056) | 70 | default | _TBD_ | _TBD_ | _TBD_ |
| layeradj | 55 | [0,.5,.5,0,0] | _TBD_ | _TBD_ | _TBD_ |
| layeradj | 70 | [0,.5,.5,0,0] | _TBD_ | _TBD_ | _TBD_ |

Direct A/B at util 55 (1055 vs layeradj-55) and util 70 (1056 vs layeradj-70):
if the layer-adjusted run routes denser, the wall is M2/M3 saturation and the
fix is layer balancing. If it still dies on DRT-0073 with M4/M5 left empty, the
limit is local **pin-access** (M1↔M2 vias at cell/macro pins), which upper
layers can't fix — then the levers shift to macro placement, pin spreading, or
RTL/datapath-width reduction.

### Other levers (not yet tried)
- Widen further / lighten PDN to free even more of M4/M5 (marginal — already 3 %).
- Lower `GRT_ADJUSTMENT` globally (less safety derate = more apparent capacity).
- Reduce wire demand: narrower datapaths, macro placement that localizes the
  32-bit buses, fewer/denser SRAM macros.

Related notes: memory `drt-density-wall`, `sram-pin-geometry`,
`picorv32-pd-knob-findings`.
