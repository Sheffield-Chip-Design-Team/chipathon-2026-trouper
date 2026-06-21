# Half-Band Decimator — Area Reduction Candidates

**Status:** Candidate optimizations, not yet prototyped
**Date:** 2026-06-20
**Related:** `planning/decimator-hb-redesign.md`, `planning/decimator-hb-migration-impact-plan.md`

## Context

The half-band migration is a signal-quality win — it eliminates the −11.8 dB
250 kHz droop (R=128 chirp edge at Nyquist → R=16 edge at −0.17 dB), removes
per-BW mode switching and the droop-EQ stage, and runs the re-modulator at its
nominal OSR=64. But it **costs area**, and that cost forces a larger die:

| Metric | Baseline (R=128 CIC) | HB version | Delta |
|---|---:|---:|---:|
| Decimator synth (FD TT, shared TDM) | 207,754 µm² | 378,108 µm² (SGE 2082) | +82% |
| Top-level synth (FD TT) | 760,641 µm² | 961,858 µm² | +22.7% |
| Die / blocks (P&R) | 1100×1100 target | 1650×1100, 6 blocks (SGE 2094) | larger |

This document records candidate ways to claw back area. None of these address
the SS-corner timing gap (−16 ns, FD-cell library limitation, handled by MCP=3);
they target area only.

## Where the area lives

In the shared decimator (`rtl-test/rtl/sd_decimator_hb_tdm.v`), **sequential
elements are 50.67% (191,592 µm²)** — state storage dominates compute. The flop
inventory:

| State | Count | Notes |
|---|---:|---|
| HB1 delay lines | 4 ch × 11 taps × 8 b × 2 (I/Q) = 704 FF | full shift register, incl. zero taps |
| HB2 delay lines | 4 ch × 15 taps × 8 b × 2 = 960 FF | full shift register, incl. zero taps |
| CIC integrators + combs | 4 ch × 6 × 16 b × 2 = 768 FF | 16-bit, oversized for R=16 |

Separately, part of the top-level +22.7% comes from the **2× output rate (500 vs
250 kS/s)** widening downstream counters: `M` 12→15 b, `n_acc` 16→18 b with
3-byte readback, PSRAM `del_cnt`/`del_n` 13→15 b, across `sc_detector_hb`,
`training_acc_hb`, `packet_ctrl_fsm_hb`, `reg_bank_hb`. These widenings are
mostly required by the architecture and offer little to recover.

## Candidate optimizations (ranked by expected leverage)

### 1. RAM-backed FIR delay lines — EXPLORED AND REJECTED (2026-06-20)

Idea: replace the HB1/HB2 flop delay lines with a dedicated on-chip SRAM macro.
Explored against the actual `gf180mcu_fd_ip_sram` macros and the measured flop
area. **Rejected — worse on area and infeasible on bandwidth.**

Total post-polyphase delay state is only **168 bytes** (HB1 9 B + HB2 12 B, × 4 ch
× 2 IQ) = 1344 flops. Measured flop cost: dffrnq_1 = 74.6 µm²/bit (= 184,427 µm² /
2471 FF from the w14 synth) → 597 µm²/byte → the whole delay state ≈ **100,250 µm²
in flops**.

Available single-port ×8 macros (from LEF `SIZE`):

| Macro | Capacity | Area | vs equivalent flops |
|---|---|---:|---|
| sram64x8 | 64 B | 100,580 µm² | floor alone ≈ all our delay state |
| sram128x8 | 128 B | 116,134 µm² | too small to hold 168 B |
| sram256x8 | 256 B | 147,224 µm² | **+47%** vs the 100,250 µm² it replaces |
| sram512x8 | 512 B | 209,420 µm² | — |

**Killer 1 — area floor.** The smallest macro that fits 168 B (sram256x8) is 47%
*larger* than the flops it would replace. Break-even vs flops is ~250 B (~2 kbit);
the FIR taps are ~1.3 kbit, below crossover. GF180 foundry SRAM peripheral overhead
(decoders/sense amps) dominates at this size.

**Killer 2 — bandwidth.** The macros are single-port (1 access/clock). The FIRs
need ~3.5 tap-accesses/clock (16 HB1 MACs × 7 taps + 8 HB2 × 9 taps + writes per
64-clock output period). Meeting that needs ≥4 parallel banks (≥400K µm²); the ×8
word can't be widened to read taps in parallel.

**Corollary — do NOT reuse the external PSRAM either.** Independently of the above,
the APS6404L is throughput-bound at 500 kS/s (Gate 8: 56/64 cycles used, debug
fetch already deferred), so it cannot absorb tap traffic.

**Conclusion:** flop-based polyphase (#2) is the correct design point for storage
this small. SRAM macros only win above ~2–4 kbit — which is why the frontend
rolling buffer and PSRAM replay paths use SRAM and the FIR delay lines must not.
A custom OpenRAM dual-port macro could cut bandwidth/overhead but would be an
unproven macro (same tapeout-risk objection as AS cells) for a sub-2-kbit array —
not worth it.

### 2. Polyphase decomposition of the halfband FIRs

A 2:1-decimating halfband has every odd tap = 0 except the center. The current
RTL stores **all** taps (`hb1_i_z[...][1,3,7,9]` etc.) and skips the zeros only at
compute time. Splitting each HB into two polyphase branches makes one branch a
pure delay (center tap only) and the other hold just the symmetric non-zero taps —
roughly **halving both delay storage and MAC width** per stage. Stacks with #1
(fewer words to store in RAM).

### 3. Trim CIC integrator/comb width 16 → 13 bits

`decimator-hb-redesign.md` states R=16, N=3 needs only 2¹² headroom = 13 bits.
The RTL hardcodes 16. Trimming 3 bits across 12 registers × 2 (I/Q) × 4 ch shrinks
both the flops and the integrator/comb adders. Low-risk, bounded saving.

### 4. Deepen TDM on the CIC combs and output scaling

Integrators must update every clock per branch (cannot be shared), but the comb
subtractions and the `>>>5` round/saturate currently run for all 4 channels in a
combinational `for` loop. Fold them onto the existing TDM slot engine so one comb
datapath serves all branches, trading the parallel comb logic for a few control
states inside the 64-clock budget.

### 5. Configurable final ÷2 for the 125 kHz path (architectural fallback)

125 kHz is already 4× oversampled at 500 kS/s. Making the final HB2 ÷2 optional
(125 kHz → 250 kS/s) would also shrink the downstream counter widenings back
toward baseline. This **trades back the fixed-rate / no-mode-switch simplicity**
that motivated the migration, so pursue only if #1–#4 do not recover enough area.

## Measured results (FD TT yosys, vs 378,108 µm² baseline)

Candidates #2 (polyphase) and #3 (CIC trim) were prototyped on the standalone
decimator, **proven bit-exact** against `sd_decimator_hb_tdm` (cycle-for-cycle,
including sustained ±full-scale bursts that exercise the CIC ±4096 corner), and
FD-synthesized. RTL: `rtl-test/rtl/sd_decimator_hb_w14.v`,
`rtl-test/rtl/sd_decimator_hb_poly.v`; TBs `tb_hb_{w14,poly}_equiv.v`; scripts
`rtl-test/scripts/run_hb_{w14,poly}_verify_synth.sh`.

| Variant | Optimizations | Cells | DFFs | Seq area | Chip area | Δ vs base | Equiv |
|---|---|---:|---:|---:|---:|---:|:--:|
| `sd_decimator_hb_tdm` (baseline) | — | — | 2567 | 191,593 (50.7%) | 378,108 | — | ref |
| `sd_decimator_hb_w14` | #3 only (14-bit CIC) | — | 2471 | 184,428 | 358,079 | **−5.3%** | PASS (SGE 2098) |
| `sd_decimator_hb_poly` | #3 + #2 (polyphase) | — | 2151 | 160,544 (49.3%) | **325,761** | **−13.8%** | PASS (SGE 2099) |

The −416 DFF from baseline to `poly` matches prediction exactly: 96 from the CIC
trim (2 b × 6 regs × 2 IQ × 4 ch) + 320 from the polyphase delay lines (HB1 11→9,
HB2 15→12 taps per channel/IQ). Net **−52,347 µm² (−13.8%)** on the decimator,
bit-exact — these are safe to fold into `sd_decimator_hb_tdm`.

**Correction to #3:** the redesign doc's "13-bit min" is one bit short. A sustained
full-scale +1 drives the CIC-3 R=16 comb output to +4096 = 2¹², which needs 14-bit
signed (13-bit signed wraps at +4095). 14-bit is the bit-exact minimum.

## Suggested next steps

1. DONE: #2+#3 folded into `trouper_top_hb` (instantiates `sd_decimator_hb_poly`,
   config `ol_trouper_top_hb/config.json`); P&R re-run submitted as SGE 2100 on the
   same FD+MCP=3 1650×1100 die to measure the top-level saving. If utilization drops
   meaningfully, follow up with a die-shrink experiment toward 1100×1100.
2. #1 (SRAM-backed delay lines) rejected — see above; flops are optimal at this size.
3. Remaining flop-level levers (all smaller, bit-exactness/precision trade-offs):
   - **non-reset HB delay lines** — measured below; ~4.5% more, deferred pending GLS.
   - 7-bit internal HB tap precision instead of 8-bit — lossy, needs SQNR re-check.
   - #4 (deeper comb TDM) — untested incremental option.

## Top-level P&R of folded #2+#3 (SGE 2100, FD+MCP=3, 1650×1100)

`trouper_top_hb` with `sd_decimator_hb_poly` vs baseline `sd_decimator_hb_tdm`
(SGE 2094), identical config otherwise:

| Metric | Baseline 2094 | Folded poly 2100 |
|---|---|---|
| TT WNS | 0.0 ns | **0.0 ns** |
| SS WNS | −16.23 ns | **−8.59 ns** (+7.6 ns) |
| route DRC | 0 | **0** |

The decimator sits on the high-fanout IQ_CLK domain, so shrinking it nearly halved
the SS-corner violation (the known FD-cell weak corner) — the saving buys timing
headroom, not just area. Follow-up: a die-shrink experiment toward 1100×1100.

## Std-cell-level levers (measured)

Library `gf180mcu_fd_sc_mcu7t5v0` has **no multi-bit/banked flops** (only single-bit
dff/sdff variants), so the usual MBFF clock/reset-sharing win is unavailable. ICG
clock-gate cells exist (power lever, marginal area). AS cells are smaller but
rejected (unproven). Latches (`latq` 43.9 vs `dffq` 63.7 µm²) are impractical
(2-phase clocking). Two levers were measured at top level:

### Area-oriented synthesis (`SYNTH_STRATEGY: "AREA 0"`) — REJECTED for this design

Synth-only (SGE 2103) and full P&R (SGE 2104) on the same 1650×1100 die vs the
DELAY-0 poly run (2100):

| Metric | DELAY-0 poly (2100) | AREA-0 (2104) |
|---|---|---|
| synth total area | 956,734 µm² | 894,919 µm² (−6.5%) |
| post-P&R stdcell | 1,073,360 | 1,008,150 (**−6.1%**) |
| density | 61.5% | 57.8% |
| TT WNS | 0.0 | **0.0** (closes) |
| SS WNS | −8.59 ns | **−24.17 ns** |
| route DRC | 0 | 0 |

Area recovery is real (−6.1%, all combinational; flops unchanged) and TT still
closes, but SS regresses **−15.6 ns** — worse than the −16.23 ns baseline. Area-mode
picks low-drive/longer-path gates and the SS-critical high-fanout IQ_CLK paths blow
out. Spending 15.6 ns of the gating slow corner for 6% area is a bad trade here.
Better use of area: keep DELAY-0 and convert poly's +7.6 ns SS headroom into a
**die shrink** (area without worsening SS past baseline). A *selective* area-map
(off-critical blocks only, DELAY on IQ_CLK domain) could capture part of the win
without the SS hit but needs hierarchical synthesis.

## Reset-removal lever — measured (candidate, deferred)

Flop cell areas (FD TT liberty): `dffq_1` (no reset) = 63.66 µm², `dffrnq_1`
(async reset, currently synthesized) = 74.64 µm². Reset costs ~11 µm²/flop.

The 1344 HB delay-line flops do **not** need reset (pure FIR shift registers that
self-flush). Dropping it → ~14.8K µm² ≈ **−4.5%** more decimator area. CIC
integrators, combs, FSM, counters and `iq_valid` keep reset.

RTL X-injection (`sd_decimator_hb_poly_nordl`, SGE 2101): with delay lines un-reset
(power up X in sim), **control/`iq_valid` is never X and matches the reset reference
every cycle**; the datapath X **flushes in 9 output samples** then is bit-exact
forever. Warm-up budget is ≥256 samples (SC hold-off) → **~28× margin**.

**Status: REJECTED on measured P&R evidence (SGE 2102).** Top-level run with
`sd_decimator_hb_poly_nordl` on the same 1650×1100 die vs the reset poly run (2100):

| Metric | poly reset (2100) | nordl (2102) |
|---|---|---|
| sequential-cell area | 384,037 µm² | 369,307 µm² (−14,730, as predicted) |
| total stdcell area | 1,073,360 | 1,064,880 (**−0.8% net**) |
| density | 61.5% | 61.0% |
| SS WNS | −8.59 ns | **−17.90 ns (−9.3 ns)** |
| route DRC | 0 | 0 |

The standalone-synth estimate (−4.5% on the decimator) does **not** hold at top
level: the −14.7K µm² flop saving is real but ~6K is eaten back by extra
timing-repair buffering, leaving only −0.8% net — and SS regresses 9.3 ns, giving
back the entire timing headroom the poly fold bought (worse than the −16.23 ns
baseline). Removing reset perturbed CTS/placement on the high-fanout IQ_CLK domain.
Trading a 9.3 ns SS regression for 0.8% area is a bad deal even before the X-init
GLS verification burden. Not pursued.

## Die-shrink sweep — converting poly's SS headroom into a smaller die (SGE 2105/2106)

The right use of poly's +7.6 ns SS headroom is a **die shrink at the default
DELAY-0 mapping** (no SS-for-area tradeoff, unlike AREA-0 or reset-removal). Two
concurrent DELAY-0 poly P&R runs vs the 1650×1100 poly baseline (2100):

| Die (µm) | util | stdcell µm² | TT WNS | SS WNS | DRC | SGE |
|---|---|---|---|---|---|---|
| 1650×1100 (baseline) | 61.5% | 1,073,360 | 0.0 | −8.59 ns | 0 | 2100 |
| 1560×1100 | 65.0% | 1,071,050 | 0.0 | −11.49 ns | 0 | 2105 |
| **1500×1100** | **67.5%** | 1,069,080 | **0.0** | **−10.50 ns** | 0 | 2106 |

Both shrinks close TT at 0.0 and DRC 0. SS stays in the −10.5 to −11.5 ns band —
worse than the 1650 baseline (−8.59) but **far** better than the 1650×1100 CIC-only
baseline (−16.23) and the rejected AREA-0 (−24.17). 1500×1100 is **−9.1% die area**
(1.815 M → 1.65 M µm²) vs 1650×1100 while still leaving SS margin.
Curiously 1500 has marginally better SS than 1560 (P&R run-to-run variation at these
densities). DRC stays clean at 67.5% utilization.

**Recommendation: adopt 1500×1100 as the trouper_top_hb floorplan target.** It banks
the poly area win as a real die shrink with TT=0, DRC=0, and SS headroom intact. A
further push toward 1100×1100 still requires more RTL area cuts elsewhere (the
decimator is no longer the dominant lever after the poly fold).

## Breaking-point sweep below 1500 (SGE 2107–2110)

Pushed the die down in 60 µm steps to find where P&R breaks (all DELAY-0 poly,
MCP=3, 1100 µm height):

| Die | util | TT WNS | SS WNS | DRC | SGE | Outcome |
|---|---|---|---|---|---|---|
| 1500×1100 | 67.5% | 0.0 | −10.50 | 0 | 2106 | clean |
| 1440×1100 | 70.1% | 0.0 | −18.32 | 0 | 2107 | clean (SS outlier — see note) |
| 1380×1100 | 73.1% | 0.0 | −11.95 | 0 | 2108 | **clean — practical floor** |
| 1320×1100 | ~76% | — | — | — | 2109 | **FAIL: GRT-0116 routing congestion** |
| 1260×1100 | ~80% | — | — | — | 2110 | FAIL: DPL-0036 placement legalization |

**1380×1100 is the smallest die that places + routes DRC-clean with TT=0.** 1320 is
the first to break, on global-routing congestion (post-GRT repair); 1260 cannot even
legalize detailed placement. SS WNS is *not* monotonic with die size (1440 came out
−18.3 while the smaller 1380 made −11.95): OpenROAD is ~deterministic per config, so
this is die-size/density nonlinearity in timing-repair buffering, **not** seed noise —
re-running a config reproduces its number. SS never closes regardless (FD-cell-at-3V
wall, mitigated by MCP=3); the binding signoff gates are TT=0 and DRC=0.

**Die decision:** 1500×1100 (conservative, util 67.5%, SS −10.5) or 1380×1100
(aggressive floor, util 73.1%, SS −11.95) — both TT=0/DRC=0. Below 1380, the wall is
*routing congestion*, so any further shrink needs congestion relief (lower
PL_TARGET_DENSITY_PCT, routability-driven placement, GRT repair budget), not seed
sweeps or extra ROUTING_OPT_ITERS (the latter only converge DRC, not timing).
