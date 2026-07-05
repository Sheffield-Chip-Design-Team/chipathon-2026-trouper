# Die-Shrink Routability Floor (2026-07-04)

**Verdict:** 1100×1100 is a **hard wall** — it fails **global routing** (GRT-0116 congestion)
and no routing-side knob rescues it (local M1/M2 pin-access density at ~94% util). Getting to
1100×1100 needs **RTL area reduction**, not floorplan tightening.

On the **current (post-B1) RTL**, two floors (both far below the pre-B1 "~1380" assumption):
- **Auto-pin floor = 1150×1100 (~90% util)** — §7 sweep; every die 1150→1380 signs off clean,
  GRT-0116 wall pinned to 1120↔1150.
- **Fixed-pin (PCB-realistic) floor = 1200×1100 (~86% util)** — §8; with the real
  `io_placement_bl.cfg` pad order, 1150 flips to congestion, 1200 signs off clean. **This is the
  number to use for a real pinout.**

> **Do NOT cross-compare with the June 2026-06-24 sub-1380 sweep** (roadmap §2: 1380✓ 1340✗
> 1300✗ DRT-0073 1260✓). That sweep ran on the **pre-B1 netlist** — before the sc_detector
> serial-mul cut (−17K, a full 13×13 combinational cone removed), which changes both area and
> placement/CTS. B1 plausibly made 1300 genuinely routable rather than it being "stochastic
> luck." The pre-B1 numbers are **superseded**; judge the floor only from the current-RTL sweep
> below.

See [area-reduction-roadmap.md](area-reduction-roadmap.md) §7 for cut levers; §2 for the
(now superseded) pre-B1 sweep.

Related: [die-area-analysis.md](die-area-analysis.md), area-reduction-roadmap.md §2 (die arithmetic).

---

## 1. Method

All runs: 3.3 V FD cells (`gf180mcu_fd_sc_mcu7t5v0`), `config_current_signoff` derivatives,
`NDR=none`, SDC `pnr_32m_scoped_v20`, SGE. One variable per run.

| Job | Die | DPL_CELL_PADDING | RT_MIN_LAYER | Pins | Result |
|---|---|---|---|---|---|
| 3240 | 1380×1100 | 1 | Metal2 (dflt) | **fixed** (io_placement_bl) | ✅ full signoff, DRC/LVS/DRT = 0 |
| 3241 | 1380×1100 | 1 | Metal2 | fixed (rebalanced) | ✅ clears GRT → detailed routing |
| 3242 | 1100×1100 | **1** | Metal2 | auto | ❌ GRT-0116 congestion @ step 39 |
| 3243 | 1100×1100 | **0** | Metal2 | auto | ❌ GRT-0116 congestion @ step 39 |
| 3245 | 1100×1100 | 1 | **Metal1** | auto | ❌ GRT-0116 congestion @ step 39 |
| 3244 | 1300×1100 | 1 | Metal2 | auto | ⏳ clears GRT; DRT **pending** (prior 1300 sweep hit DRT-0073 in detailed route) |

## 2. Density decomposition (why "79%" is really "94%")

Cell *logic* area (Yosys/synth-instance) = **959,667 µm²**. Naive die-area utilisation at
1100×1100 = 960K / 1.21M = **79.3%** — but that is **not** what OpenROAD legalises against:

- Die 1100×1100 = 1,210,000 µm²
- Core (floorplan IFP-0102) = **1,158,363 µm²** = 95.7% of die (thin ~7–15 µm margin ring)
- Std-cell logic = 82.9% of core
- **+ tap cells (41.5K) + endcaps + physical/PDN cells (~85K)** → total placeable ≈ 1.086M
- **→ 93.8% core utilisation** (OpenROAD GPL-0019)

So ~13 pts of the real density is unavoidable physical-cell overhead that naive cell-area math
misses. **1380×1100 sits at 74.6% util (routes clean); 1100×1100 at 93.8% (congests).**
`DPL_CELL_PADDING` does **not** change this number — it only affects legalisation spacing, so
3242/3243/3245 all report the identical 93.8% and all fail identically.

## 3. Root cause: local pin-access, not layer supply

At 94% util the bottleneck is **space between densely packed cells for M1/M2 to escape cell
pins** — a placement-density problem, not global track supply:

- M4/M5 sit ~empty in the routed 1380 design (10.3K / 1.4K wire segments vs **325K on Metal2**,
  100K on Metal3). Free upper layers therefore cannot absorb the congestion.
- Lowering `RT_MIN_LAYER` to Metal1 to add escape tracks (job 3245) **did not help** — M1 is
  already saturated with pin access at this density.

## 4. Levers that do NOT work (closed)

| Lever | Why it fails |
|---|---|
| `DPL_CELL_PADDING` 1→0 | util fixed by die+cell-count; padding only moves cells within it (3242 vs 3243 identical) |
| `RT_MIN_LAYER` = Metal1 | M1 already pin-access-saturated at 94% (3245 congests) |
| More/upper metal layers | M4/M5 already available and ~empty; congestion is local not global |
| Metal **width** / NDR | min width is DRC-floored (M1–4 pitch 0.56 µm = min-width+min-space); the only width knob (NDR) *widens* wires → worsens congestion. `NDR=none` already set. |
| `GRT_ALLOW_CONGESTION` | only relocates the failure to detailed routing; not a real fix |

## 5. What actually unlocks a smaller die

1. **RTL cell-area cuts** — see area-reduction-roadmap.md §7. Open stack B4+B5+B6 ≈ −17K safe,
   +B3 (remod 3rd→2nd, blocked on OSR=64 SQNR sweep) ≈ −35K. Lowers util at a given die.
2. **5 V core path** — at ~5 V the ~190K µm² of SS timing-repair buffering (the buffer "pump")
   evaporates, deflating *placed* area and letting B2-class reset-free-flop cuts finally stick.
   This is the real die-shrink lever; 3.0 V RTL cuts mostly buy SS margin, not silicon. See
   `planning/5v-core-voltage-strategy.md` and Open Risks #27.

**Two distinct, independent limits** — don't conflate them:
- **Routing-congestion floor ≈ 1150×1100** (this doc's sweep, §7) — GRT-0116 at ~94% util. A hard
  density wall, moved only by die area or RTL cell-area cuts.
- **SS timing** — voltage-bound (~−17 ns at 3.0 V) and essentially **die-size-independent**; it is
  NOT relieved by any die choice, only by the 5 V core path. See project_vdd_closes_ss_timing.

## 6. Fixed block-pin placement — CONFIRMED (Open Risk #28)

Job **3241** (1380×1100, `IO_PIN_ORDER_CFG=io_placement_bl.cfg`, rebalanced) routes **DRT = 0**
and places pins **exactly** as specified:

- **S (bottom, 23):** IQ_DATA[3:0] I/Q + IQ_CLK + PSRAM_* — all high-speed board pads
- **W (left, 8):** RESETB, HOST_CS, SPI_SCK/MOSI/MISO, IRQ_OUT, REMOD_A_I/Q — all remaining board pads
- **E (right, 15) + N (top, 12):** GRP_ADDR/WDATA/RDATA + GRP_WE/RE/READY + IRQ_GROUPER (inter-project, no pads)

**Zero board pads off S/W.** Pads on left+bottom, Grouper on top+right, routes clean → the fixed
PCB-friendly pin order carries no DRT-0073 hazard for this arrangement. `IO_PIN_ORDER_CFG` honors
per-edge `#S/#W/#E/#N` counts faithfully (S23/W8/E16/N12 requested = placed).

> **DEF-parse gotcha:** trouper_top DEFs use **2000 DBU/µm** (block boundary `2760000×2200000`
> for a 1380×1100 die). Divide pin coords by **2000**, not 1000 — otherwise mid-edge E/W pins
> (y≈550 µm → 1.1e6 DBU) get misclassified as North and produce a phantom "pad leaked to N".

## 7. Current-RTL width sweep (height 1100, post-B1, auto pins)

Single-variable die-width sweep, all on today's RTL. Util = placeable(≈1.086M) / core(95.7% of die).

| Die | ~util | GRT (congestion) | Detailed route | Signoff |
|---|---:|---|---|---|
| 1380×1100 | 74.6% | ✅ | ✅ | ✅ clean (baseline 3240) |
| 1300×1100 | ~79% | ✅ | ✅ | ✅ clean, DRT/magic/LVS=0 (3244) |
| 1250×1100 | ~83% | ✅ | ✅ | ✅ clean, DRT/magic/LVS=0 (3248) |
| 1200×1100 | ~86% | ✅ | ✅ | ✅ clean, DRT/magic/LVS=0 (3247) |
| **1150×1100** | **~90%** | ✅ | ✅ | ✅ **clean, DRT/magic/LVS=0 (3246)** |
| **1120×1100** | **~92%** | ❌ **GRT-0116** | — | — (3249) |
| **1100×1100** | **93.8%** | ❌ **GRT-0116** | — | — |

**Routable floor on current (post-B1) RTL = 1150×1100 (~90% util).** The GRT-0116 congestion
onset is sharp: 1150 (90%) clears, 1100 (94%) fails hard. Every die from 1150 up to 1380 signs
off fully clean (DRT/magic/LVS = 0, all six jobs). This is a much lower floor than the pre-B1
"~1380" assumption — B1 (−17K, cone removal) plus the current flow reach 1150 clean. Note SS
timing is a separate voltage-bound limit (~−17 ns at 3.0 V) at *all* these dies; a smaller die
does not affect it. **The GRT-0116 wall is pinned to the 1120↔1150 band (~92%↔90% util):**
1120 (3249) congests, 1150 clears. The onset is remarkably sharp — a ~30 µm / ~2 util-pt swing
flips the design from clean signoff to hard congestion, so 1150 is a hard, well-characterised
floor (no margin below it without RTL cuts).

**Perf note:** these three ran ~5× faster after a live `docker update --cpus=8
--cpuset-cpus=…` on each SGE container (default was `NanoCpus=1`, all pinned to core 0). The
1-CPU cap was throttling TritonRoute's parallel phases; total CPU rose 108%→~150% with no
restart. Filed as homelab-sge enhancement `api-option-to-resize-running-job-cpus.md`.

## 8. Fixed-pin (PCB-realistic) floor — the tapeout number

§7's floor uses **auto** pins (router places pads wherever congestion is lowest) — a best case,
not a tapeout floor. A real board needs the fixed PCB-order pins (§6, `io_placement_bl.cfg`).
Re-ran the same width sweep **with fixed pins** (jobs 3250–3253, `--cpus 4`):

| Die | ~util | Auto pins (§7) | **Fixed pins (io_placement_bl)** |
|---|---:|---|---|
| 1300×1100 | ~79% | ✅ | ✅ clean, DRT/magic/LVS=0 (3253) |
| 1250×1100 | ~83% | ✅ | ✅ clean, DRT/magic/LVS=0 (3252) |
| **1200×1100** | **~86%** | ✅ | ✅ **clean, DRT/magic/LVS=0 (3251)** |
| 1150×1100 | ~90% | ✅ | ❌ **GRT-0116 (3250)** |

**Fixed-pin floor = 1200×1100 (~86% util)** — exactly one 50 µm step above the auto-pin floor
(1150). Fixing pads to board-friendly edges costs the router the freedom to relieve the
congestion cliff, so 1150 flips to congestion while 1200 still signs off clean. **Use 1200×1100
as the realistic minimum die for a real pinout** (1150 only holds with auto pins). From the
1380×1100 baseline that is still a ~13% area reduction (1.518M → 1.32M µm²), fully DRC/LVS/DRT
clean with the PCB pin order.
