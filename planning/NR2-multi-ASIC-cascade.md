# NR=2 Multi-ASIC Cascade — Architecture and Lock-Detect Scheme

**Status:** Archived design exploration (2026-06-03)

> This note evaluates an older `mimo_rx_top` / PicoRV32 / hardware-`weight_gen` architecture.
> It is not the baseline for the current active `trouper_top` hard macro.
> For current area ranking, use `rtl-test/syn_mimo_per_module/README.md` and the SGE-1965 synthesis report.

## Area Targets

**AS cell synthesis (gf180mcu_as_sc_mcu7t3v3). 65% effective density (DRT-safe limit from P&R history).**

#### Measured baseline (job 1249, AS cells)

Full top-level `mimo_rx_top` with current RTL: NR=4, 4× CIC-only, ser-IQ mrc, HW weight_gen, energy_meas_coarse, no NFE:
**1,598,073 µm² stdcell** (NR=4). NR=2 estimate: ~1,167k µm².

#### Die area at 65% effective density

| Config | Stdcell | Macros | Die (65%) |
|--------|---------|--------|-----------|
| NR=4 CIC-only, current RTL (measured) | **1,598k** | 0.52 mm² | **~3.26 mm²** |
| NR=2 CIC-only, current RTL | ~1,167k | 0.41 mm² | **~2.43 mm²** |
| NR=2 + sw weight_gen + no energy_meas | ~992k | 0.41 mm² | **~2.16 mm²** |
| NR=2 + sw weight_gen + no energy_meas + 12-bit W | ~962k | 0.41 mm² | **~2.11 mm²** |

Cut stack from NR=2 1,167k baseline: sw weight_gen −105k, energy_meas_coarse −70k, mrc 12-bit weights ~−30k.
NFE already removed — not in current RTL baseline.

> **Timing caveat:** FD cells close TT 25°C at 32 MHz but fail SS 125°C. AS cells close SS but add ~16% die area.

### Per-block breakdown (AS cells, jobs 1241–1247)

| Block | ×NR? | NR=4 (µm²) | NR=2 (µm²) | Cut option |
|---|---|---|---|---|
| PicoRV32 core + wrap | No | 307,618 | 307,618 | SERV swap (−~250k) |
| sd_decimator TDM CIC | Yes | 256,779 | 128,694 | already optimised |
| dc_removal | Yes (1 module) | 50,009 | ~25,000 | — |
| training_acc | Yes | 155,762 | 111,358 | — |
| weight_gen | Yes | 138,115 | 105,198 | **→ software (−105k NR=2)** |
| mrc_combiner (4 muls) | Yes | 121,366 | 107,394 | — |
| mrc_combiner ser-IQ (2 muls) | Yes | 97,601 | **84,315** | **ser-IQ RTL (−23k NR=2)** |
| sc_detector | No (NR=1) | 111,608 | 111,608 | — |
| reg_bank | Partial | 99,034 | 90,247 | sw weight_gen saves ~0 |
| energy_meas | No | 70,383 | 70,383 | coarse saves only 1.2k |
| psram_buf_ctrl | No | 46,475 | 46,475 | — |
| noise_floor_est | No | 33,558 | 33,558 | **remove entirely (−34k)** |
| packet_ctrl_fsm | No | 32,902 | 32,902 | — |
| sd_remod | No | 29,262 | 29,262 | — |
| frontend_buf_ctrl | No | 17,434 | 17,434 | — |
| spi_slave + master | No | 27,713 | 27,713 | — |
| irq_ctrl + ahb_bus | No | 5,036 | 5,036 | — |
| **Baseline TDM CIC** | | **~1,502k** | **~1,190k** | |
| **+ sw weight_gen** | | **−138k** | **−105k** | |
| **+ ser-IQ mrc** | | **−24k** | **−23k** | |
| **+ remove NFE** | | **−34k** | **−34k** | |
| **Optimised total** | | **~1,306k** | **~1,028k** | |

Notes:
- dc_removal is a single module for all NR channels; NR=2 is a constant-propagation estimate.
- NR=2 training_acc/mrc_combiner/weight_gen are constant-propagation estimates; actual NR=2 rewrite ~5% smaller.
- mrc_combiner ser-IQ (`mrc_combiner_serIQ.v`): 11-state machine, 2 multipliers, 11 cycles/sample vs 7 in baseline. Budget 256 cycles — ample margin.
- Software weight_gen: PicoRV32 computes weights in ~800 cycles; SF7 training window = 131k cycles. 160× headroom.
- NFE removal: safe if sigma2 feedback path is confirmed unused in final system.
- opt-C (fix post_gain_shift=0): only saves 4k µm² — not worth the register-map change.
- energy_meas_coarse: saves only 1.2k µm² — not worth implementing.

### Die area summary (65% effective density, OCD macros)

65% is the conservative empirical limit from P&R history (DRT-0073 above ~65%).

| Config | Stdcell | Macros | Die (65%) |
|--------|---------|--------|-----------|
| NR=2 TDM CIC, baseline | ~1.19 mm² | 0.41 mm² | **~2.46 mm²** |
| NR=2 TDM CIC + sw-wgt + ser-IQ + no-NFE | ~1.03 mm² | 0.41 mm² | **~2.22 mm²** |
| NR=4 TDM CIC, baseline | ~1.50 mm² | 0.52 mm² | **~3.11 mm²** |
| NR=4 TDM CIC + sw-wgt + ser-IQ + no-NFE | ~1.31 mm² | 0.52 mm² | **~2.82 mm²** |

Macros: 2× OCD 1024×8 (CPU IMEM/DMEM) + 1× OCD 512×8 (frontend buf, NR=2) or 1× FD 512×8 (NR=4).

### System-level silicon comparison (updated)

| System | Config | Die | Total silicon |
|--------|--------|-----|---------------|
| NR=4 single chip | TDM CIC baseline | ~3.11 mm² | **~3.11 mm²** |
| NR=4 single chip | + sw-wgt + ser-IQ + no-NFE | ~2.82 mm² | **~2.82 mm²** |
| NR=2 cascade (×3) | TDM CIC baseline | ~2.46 mm² | **~7.38 mm²** |
| NR=2 cascade (×3) | + sw-wgt + ser-IQ + no-NFE | ~2.22 mm² | **~6.66 mm²** |

NR=4 remains 2.3× more silicon-efficient. The cascade is only justified if there is a hard per-die area limit below ~2.82 mm².

---

---

## 8-Stream TDM ΣΔ Decimator

For NR=4 (4 antennas × I + Q = 8 independent 1-bit streams at 32 MHz), a single shared CIC can serve all 8 streams via pre-decimation + TDM.

### Architecture

**Stage 1 — boxcar-8 pre-decimator (per stream, trivial):**
Accumulate 8 consecutive 1-bit samples into a 4-bit partial sum. This is a 3-bit counter with an output latch. 8 instances ≈ negligible area.

Each stream drops from 32 MHz 1-bit → 4 MHz 4-bit.

**Stage 2 — TDM CIC(R=32) (shared):**
```
8 streams × 4 MHz/stream = 32 MHz total throughput
                         = 1 stream per 32 MHz clock cycle  ← perfect fill
```
One physical adder cycles through all 8 streams' state in rotation. One set of CIC comb logic at 1 MHz (8 × 125 kHz) handles all 8 outputs.

Total OSR = 8 × 32 = 256 — identical to the standalone R=256 design. A boxcar-8 (1st-order CIC, R=8) cascaded with a 3rd-order CIC(R=32) gives a 4th-order CIC(R=256): one additional order of alias rejection vs the current 3rd-order design.

### What is shared vs per-stream

| Resource | Standalone (8 CICs) | TDM approach |
|---|---|---|
| Integrator adders | 8× | **1×** + 8-way state mux |
| Comb subtractors | 8× | **1×** (1 MHz, trivial TDM) |
| State registers | 8 × k × ~25 bit | 8 × k × ~25 bit **(unchanged)** |
| Pre-stage | — | 8 × 3-bit counter (negligible) |

State registers (each stream's running accumulator) cannot be eliminated — they are per-stream by necessity. The saving is 7 adders + 7 subtractors + their associated clock trees.

### Synthesis results (FD cells, R=256, job 1241)

| Variant | Area (µm²) | vs same-NR CIC+FIR |
|---|---|---|
| NR=4 — 4× CIC-only | 300,207 | −57.9% |
| NR=4 — TDM CIC (boxcar-4 + R=64) | **256,779** | −64.0% |
| NR=4 — 4× CIC+FIR shift-add | 713,080 | baseline |
| NR=2 — 2× CIC-only | 150,103 | −57.9% |
| NR=2 — TDM CIC (boxcar-2 + R=128) | **128,694** | −63.9% |
| NR=2 — 2× CIC+FIR shift-add | 356,540 | baseline |

Key findings:
- TDM saves **~14.5% over plain CIC-only** in both NR=4 and NR=2 — consistent, as expected (shared adder; state registers unchanged)
- NR=2 TDM (128k µm²) is exactly half NR=4 TDM (257k µm²)
- FIR elimination remains the dominant lever (−57.9%); TDM adds a further −6% on top
- RTL: `sd_decimator_cic_tdm8.v` (NR=4), `sd_decimator_cic_tdm2ch.v` (NR=2)

---

## Motivation

The ΣΔ decimator is the largest block per antenna branch. Moving from NR=4 to NR=2 per ASIC halves the decimator count and the frontend buffer SRAM, at the cost of splitting the receive chain across multiple chips. A 3-chip cascade (2 feeder chips + 1 combiner chip) recovers the effective NR=4 combining gain while keeping each ASIC's analog and decimation complexity manageable.

---

## Topology

All three chips are **identical**. The cascade is formed by routing each chip's ΣΔ re-modulator output (a 1-bit 32 MHz bitstream) to the next chip's ΣΔ decimator input — the same interface the chip uses with the SX1257. No custom inter-chip protocol is needed.

```
  Chip A                         Chip B
  ┌─────────────────────┐        ┌─────────────────────┐
  │  Ant 0, Ant 1       │        │  Ant 2, Ant 3       │
  │  2× ΣΔ decimator    │        │  2× ΣΔ decimator    │
  │  SC detect (NR=1)   │        │  SC detect (NR=1)   │
  │  Training accum     │        │  Training accum     │
  │  NR=2 weight gen    │        │  NR=2 weight gen    │
  │  NR=2 MRC combiner  │        │  NR=2 MRC combiner  │
  │  ΣΔ re-modulator    │        │  ΣΔ re-modulator    │
  │  PicoRV32 + regs    │        │  PicoRV32 + regs    │
  └────────┬────────────┘        └──────────┬──────────┘
           │ 1-bit ΣΔ bitstream             │ 1-bit ΣΔ bitstream
           │ at 32 MHz (remod_out)          │ at 32 MHz (remod_out)
           └──────────────┬─────────────────┘
                          ▼
                   Chip C (identical die)
                   ┌──────────────────────────────────┐
                   │  iq_in[0] ← chip A remod_out     │
                   │  iq_in[1] ← chip B remod_out     │
                   │  2× ΣΔ decimator                 │
                   │  SC detect (NR=1, on iq_in[0])   │
                   │  Training accum (NR=2)            │
                   │  NR=2 weight gen                 │
                   │  NR=2 MRC combiner               │
                   │  ΣΔ re-modulator                 │
                   │  PicoRV32 + regs                 │
                   └──────────────────────────────────┘
                          │
                          ▼
                   SX1302 combined stream
```

Chip C's SC detector locks on the re-modulated preamble arriving from chips A and B. Because chips A and B are themselves locked and timing-aligned (via the OR-lock scheme), chip C sees two preamble-aligned ΣΔ streams and locks independently without further inter-chip signalling. The OR-lock mechanism is only needed between chips A and B — not between chip C and the feeders.

---

## Inter-Chip Lock Detect — OR-Lock Scheme

### Problem

Chips A and B run independent SC detectors. Their `sc_lock` edges and `timing_ref` values will differ by noise jitter — typically 0–2 samples at SF6, potentially up to 1 symbol in weak-signal conditions. Chip C needs all 4 branches to start training from the same symbol boundary.

### Scheme

Each chip exposes two pins:

| Pin | Direction | Description |
|-----|-----------|-------------|
| `sc_lock_out` | output | asserts when this chip's SC detector naturally locks |
| `sc_lock_in` | input | OR of all chips' `sc_lock_out` lines |

Internally: `effective_lock = sc_lock_detected || sc_lock_in`

**Implementation note (2026-07-12):** the internal OR half of this scheme
already exists on single-chip NR=1 Trouper, as a register instead of a pin —
`SC_FORCE_LOCK` (`reg_bank` 0x19, `sc_detector.sc_lock_force`) asserts
`sc_lock` directly, bypassing the correlator's hit-count logic (see
`planning/Register Map.md` `0x19`; added as a bring-up / catastrophic-
correlator-failure escape hatch, not for this cascade use case). If/when a
spare pad becomes available for `sc_lock_in`, OR it into the same internal
`sc_lock_force` signal rather than building a second force-lock path.

**⚠ Constraint any future `sc_lock_in` implementation must respect:** the
current Trouper RTL assumes `sc_lock` cannot re-assert mid-packet — it is
level-held until `sc_clr` (packet done), and both lock paths are gated
`!sc_lock`. `packet_ctrl_fsm` and `psram_buf_ctrl` had their mid-payload
re-lock / replay-abort handling *deleted* on 2026-07-12 because that
assumption makes it unreachable (Open Risks #25). The OR-lock scheme as
specified here fires only during acquisition-from-idle (both chips at
`packet_active=0` racing for the same preamble), which is compatible. But
if `sc_lock_in` is ever wired so it can pulse *during* an active packet,
the deleted re-lock + replay-abort handling must be reintroduced in both
modules, or a stale in-flight PSRAM replay will be combined against the new
packet.

When `effective_lock` rises and the chip has not already latched `timing_ref`, it latches the current sample counter as `timing_ref`. Chip C gets `sc_lock_in` from the same OR, so all three chips synchronise to the same packet-detect event.

On the PCB: `sc_lock_out` from A and B wired to each other's `sc_lock_in` and to Chip C's `sc_lock_in`. Open-drain drivers with a pull-up give a wired-OR with no contention.

### Why timing_ref is still valid after a forced lock

**Critical requirement: inter-chip clock and reset coherence.**

All three chips must share:
1. The same 32 MHz clock source (XTB/TCXO shared clock tree — already required for 4-channel coherence per the SX1257 clock architecture)
2. A reset deassertion driven from the same flip-flop on the host PCB

Under these conditions, all decimator sample counters run in absolute lockstep. When Chip B's SC detector is forced to assert `effective_lock` because Chip A fired first, Chip B latches its own sample counter — which is identical to Chip A's counter at that instant. Both `timing_ref` values therefore point to the same absolute sample index, and Chip C sees perfectly aligned inter-chip IQ streams.

**If one chip's signal is too weak to naturally lock**, the forced lock still gives the correct symbol boundary because the sample counters are synchronous. That chip's channel estimate `Z_j` will be noise-dominated and MRC will assign it a low weight — the correct outcome.

### Risk: reset skew

If `rst_n` deassertion reaches two chips on different clock cycles, their `decim_cnt` starts from different phases and the sample counters are permanently offset. This is not detectable at runtime (no symptom other than corrupted MRC weights).

**Mitigation:** Route `rst_n` from a single registered output on the host MCU/FPGA with matched trace lengths to all three chips.

---

## Inter-Chip Interface

The inter-chip interface is the same 1-bit 32 MHz ΣΔ bitstream that every chip already uses with the SX1257 — `remod_out` on chip A/B connects to `iq_in` on chip C. No additional protocol or digital bus is required.

The only extra inter-chip signals are the OR-lock wires (between A and B only):

| Signal | Type | Between |
|--------|------|---------|
| `sc_lock_out` | 1-bit open-drain | A ↔ B (wired OR) |
| 32 MHz clock | shared from TCXO XTB | A, B, C all driven from same source |
| `rst_n` | registered output from host, matched traces | A, B, C |

Chip C derives its own `sc_lock` and `timing_ref` by running its SC detector on the incoming re-modulated streams from A and B. No lock signal needs to be forwarded from A/B to C.

---

## Frontend Buffer SRAM

The SC detector is already NR=1 (single-channel, antenna 0 only — Round 2 reduction, job 1138). The delay buffer it needs for stored-phase SC detection is:

```
256 I samples × 8-bit  +  256 Q samples × 8-bit  =  512 × 8-bit
```

This fits exactly in **one 512×8 OCD SRAM macro** per chip. The second antenna in the NR=2 pair contributes to the training accumulator (which cross-correlates without a delay buffer) but not to SC detection.

Result: one SRAM macro per chip, well-understood timing, no multi-macro routing complexity.

---

## PSRAM Replay and Why Lock Sync Is Critical

Each chip has its own PSRAM (APS6404L) which continuously buffers its 2-antenna IQ streams. After lock and weight computation, the chip replays the buffered packet from `timing_ref` through the MRC combiner and ΣΔ re-modulator. This has two important consequences for the cascade:

**Training window is not a problem for chip C.** Chip C stores the incoming re-modulated streams from chips A and B into its own PSRAM as they arrive in real time. Even though chip C locks later than A and B (after A/B's full DSP pipeline has processed the preamble and started replaying), chip C's PSRAM already holds the preamble from the moment the streams arrived. Chip C's training accumulator replays from its own PSRAM starting at its own `timing_ref` and sees the full preamble.

**Lock sync is critical because of PSRAM replay alignment.** When chips A and B replay from their PSRAMs, each starts from its own `timing_ref`. If chip A's `timing_ref` is sample 1000 and chip B's is sample 1003, the re-modulated streams arriving at chip C are offset by 3 samples. Chip C's training accumulator cross-correlates both streams against each other — a 3-sample misalignment produces wrong channel estimates and degraded or failed combining.

The OR-lock scheme ensures chips A and B latch the **same absolute sample index** as `timing_ref` (they share a synchronous clock and sample counter). A and B then replay from the same offset, and the streams reaching chip C are sample-aligned.

This is the primary reason lock sync is required — not preamble detection timing, but PSRAM replay alignment feeding chip C's combining stage.

---

## Combining Gain and Suboptimality

The cascade performs **hierarchical MRC**, not true 4-branch MRC:

- Level 1: Chip A computes `w_A · [h₀, h₁]ᵀ → y_A`; Chip B computes `w_B · [h₂, h₃]ᵀ → y_B`
- Level 2: Chip C computes `w_C · [y_A, y_B]ᵀ → y_out`

This is optimal when all 4 branches have equal SNR. With unequal branch SNRs (one antenna shadowed within a pair), the level-1 combiner suppresses the weak branch before chip C can compensate. The penalty relative to true 4-branch MRC is typically 0.5–1.5 dB for mild imbalance, up to ~2 dB in extreme cases. For co-located antennas in typical outdoor LoRa deployments this is acceptable.

---

## Re-Modulator SQNR Accumulation

Chip C receives a signal that has already passed through one ΣΔ re-modulation → decimation cycle. The 1st-order ΣΔ re-modulator contributes ~34 dB SQNR (measured at R=256, A=0.35). Two cascaded re-mod/decim stages will degrade the effective noise floor at chip C's combiner output.

**Required action before committing to 3-chip topology:** Simulate the cascaded path — inject a known IQ signal into chip A/B, apply the re-modulator model, feed into chip C's decimator model, measure SNR at chip C's combiner output. Confirm the SNR margin is still adequate for the target LoRa sensitivity.

---

## Open Items

1. **Re-modulator SQNR cascade simulation.** See above. This is the primary risk of the cascaded-identical-chip topology.

2. **Hierarchical MRC suboptimality simulation.** Simulate NR=4 true MRC vs 3-chip hierarchical MRC over a sweep of per-branch SNR imbalance. Confirm the worst-case penalty is within the link budget.

3. **Fallback to single-chip NR=2 operation.** If one feeder chip fails, chip C sees only one valid input. It degrades to single-antenna passthrough (bypass mode) or NR=1 operation, not NR=2. This is a graceful degradation: chip C's ANTENNA_EN and bypass logic handle it without firmware intervention.

---

## Related

- [ΣΔ Decimator](blocks/ΣΔ%20Decimator.md) — inter-instance coherence requirements
- [SC Detector](blocks/SC%20Detector.md) — sc_lock and timing_ref interface
- [Weight Generation](blocks/Weight%20Generation.md) — NR parameter, Z_j inputs
- [SX1257 Clock Architecture](../memory/sx1257-clock-architecture.md) — XTB shared TCXO rationale
