# Die Area Analysis

> **Date:** 2026-05-31
> **Status:** Jobs 1118 (5V) / 1119 (3.3V) running — this analysis predicts their outcome.

## How FP_CORE_UTIL actually works in LibreLane

`FP_CORE_UTIL` sizes the floorplan based on **stdcell area only**:

```
Core area = stdcell_area / FP_CORE_UTIL
```

SRAM macros are then placed *within* that same core area, on top of the stdcell budget.
This means the **effective density** (what DRT sees) is higher than FP_CORE_UTIL implies:

```
Effective density = (stdcell_area + macro_area) / core_area
                  = (stdcell_area + macro_area) / (stdcell_area / FP_CORE_UTIL)
```

The DRT density wall on GF180MCU is **60–65%** (DRT-0073/1231 failures above this).
To stay safe, effective density should be ≤ 55%.

## Current design logic budget

After all area cuts to date (2026-05-31):

| Component | Area |
|---|---|
| Stdcell total | ~1.62 mm² |
| OCD SRAM ×2 (CPU, 2 kB) | ~0.31 mm² |
| FD SRAM ×1 (frontend buf) | ~0.21 mm² |
| **Total logic** | **~2.14 mm²** |

## Die area vs FP_CORE_UTIL

| FP_CORE_UTIL | Core area | Effective density | Routeable? | Die ≈ |
|---|---|---|---|---|
| 55% | 2.95 mm² | 72.5% | **No** — hits DRT wall | — |
| 45% | 3.60 mm² | 59.4% | Marginal | ~3.6 mm² |
| 40% | 4.05 mm² | 52.8% | **Yes** | ~4.0 mm² |
| 35% | 4.63 mm² | 46.2% | Yes (loose) | ~4.6 mm² |

**Conclusion: realistic die size with current logic is ~4 mm² at safe routing density.**

The P&R jobs with FP_CORE_UTIL=55 will likely fail DRT for this reason.
Next run should use FP_CORE_UTIL=40.

## Impact of remaining cut options

| Scenario | Stdcell | Macros | Total logic | Safe die (~40%) |
|---|---|---|---|---|
| Current (all cuts to date) | 1.62 mm² | 0.52 mm² | 2.14 mm² | ~4.0 mm² |
| + SERV swap (−355k stdcell) | 1.27 mm² | 0.52 mm² | 1.79 mm² | ~3.2 mm² |
| + OCD ×2→×1 if fw fits 1 kB | 1.27 mm² | 0.37 mm² | 1.64 mm² | ~2.9 mm² |
| + TDM+FIR decimator (−86k) | 1.18 mm² | 0.37 mm² | 1.55 mm² | ~2.7 mm² |

**SERV is the only remaining cut that changes the die size category (4 mm² → 3 mm²).**
All the per-block TDM optimisations done so far are real savings but do not move
the category boundary — the macros and PicoRV32 dominate.

## Why our per-module synthesis numbers seemed more optimistic

Per-module Yosys synthesis reports stdcell area only. Summing those gives ~1.62 mm²,
which looks small. The die area is much larger because:

1. Macros (0.52 mm²) add on top of stdcell area
2. Routing overhead requires ~2× the logic footprint for safe DRT (FP_CORE_UTIL=40)

The synthesis area is not the die area.

## Action items

- [x] Rerun mimo_rx_top P&R with FP_CORE_UTIL=40 once jobs 1118/1119 complete → superseded by absolute die sizing below
- [ ] Confirm chipathon die area limit (determines whether SERV is mandatory)
- [ ] If limit is ≤ 2 mm²: implement SERV swap (see `planning/blocks/PicoRV32 Integration.md`)

---

## Actual P&R result (2026-06-05): 2.5 mm² achieved

> **Status:** Closed cleanly. 2000×1250 µm flat `mimo_rx_top` run (job 130, RUN_2026-06-05_16-03-48).

The May 31 prediction of ~4 mm² minimum was overly pessimistic. Switching from `FP_CORE_UTIL`-relative sizing to **absolute die sizing** with per-macro `FP_OBSTRUCTIONS` and a single bottom-row SRAM layout achieves far better packing efficiency than the util-based model.

### Achieved result

| Metric | Value |
|---|---|
| Die area | **2.5 mm² (2000×1250 µm)** |
| Area reduction vs prior best (3.2 mm²) | **−22%** |
| Area reduction vs predicted minimum (4.0 mm²) | **−37%** |
| Std cells | 31,153 |
| Placement utilisation | 46.3% |
| Setup TT WNS | 0 ns ✓ |
| Hold TT WNS | −0.120 ns (1 path, suppressed) |
| DRC errors | 0 ✓ |

### Why the prediction was wrong

The May 31 model assumed:

1. `FP_CORE_UTIL` mode where macros are placed *inside* the stdcell core area, doubling the effective density penalty.
2. A stdcell budget of ~1.62 mm² — larger than the synth result after the May cuts were fully applied.
3. A conservative effective density ceiling of 55%.

The flat PnR run used:

1. Absolute die sizing: macros and stdcells are placed independently; the 242 µm gap between CPU SRAM cluster and DSP SRAM is usable logic area, not wasted overlap.
2. Per-macro obstructions rather than a blanket obstruction: GPL places stdcells in the inter-SRAM corridor.
3. `GPL_CELL_PADDING: 0` to avoid DPL-0011 boundary failures at obstruction edges.
4. All 5 SRAMs in a single bottom row (y=25) so the entire upper ~700 µm of the die is stdcell-only routing area.

The effective stdcell area above the SRAM row is roughly 2000×700 = 1.4 mm², fully available to the router with Metal4/Metal5 passing freely over the SRAMs below.
