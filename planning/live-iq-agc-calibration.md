# Live IQ Register — Firmware AGC Calibration

**Date:** 2026-06-03  
**Status:** Design proposal — not yet implemented  
**Related:** [area-cut-contingency.md](area-cut-contingency.md), [psram-software-energy-meas.md](psram-software-energy-meas.md)

---

## Motivation

When `energy_meas_coarse` is removed, firmware needs an alternative way to measure per-branch received signal level for AGC. Two options exist:

1. **PSRAM readback** — reads buffered samples; requires PSRAM and post-packet timing.
2. **Live IQ register polling** (this document) — firmware reads real-time decimated IQ samples directly from reg_bank registers; works at any time, requires no PSRAM.

The live IQ approach is the simpler fallback and enables a **periodic background AGC calibration** that runs between LoRa packets, independently of the packet processing pipeline.

---

## Signal path

The DC-removed IQ samples (`dcr_i[0..1]`, `dcr_q[0..1]` for NR=2) are present on the 32 MHz fabric at every `dcr_valid` pulse (125 kHz). They are the same samples consumed by `sc_detector`, `training_acc`, `energy_meas_coarse`, and `mrc_combiner`. No special AFE mode is required — the signal always flows through this path.

```
SX1257 → ΣΔ decimator → dc_removal → dcr_i/q (always live) → reg_bank snapshot
                                                              ↑
                                                    firmware reads here
```

---

## Hardware addition — live IQ snapshot registers

Add to `reg_bank` (or `trouper_top`): four 8-bit registers latched from `dcr_i[0..1]`, `dcr_q[0..1]` on every `dcr_valid`, plus a firmware-readable valid flag.

| Register | Address | Content |
|---|---|---|
| `LIVE_I0` | 0xD8 | `dcr_i[0]` — 8-bit signed, ant0 I |
| `LIVE_Q0` | 0xD9 | `dcr_q[0]` — 8-bit signed, ant0 Q |
| `LIVE_I1` | 0xDA | `dcr_i[1]` — 8-bit signed, ant1 I |
| `LIVE_Q1` | 0xDB | `dcr_q[1]` — 8-bit signed, ant1 Q |
| `LIVE_VALID` | 0xDC | `[0]` — pulses 1 for one 32 MHz cycle on each `dcr_valid`. Reading `LIVE_I0` auto-clears. |

**RTL change:** ~10 lines in `trouper_top.v` or `reg_bank.v`. Estimated area: **~2k µm²** (4 × 8-bit snapshot registers + valid flag + read logic). No changes to existing blocks.

---

## Firmware AGC calibration sequence

```c
// Run between LoRa packets (system idle, sc_detector in IDLE state).
// M = number of samples to average. Use M = 128 (one SF7 symbol = 1 ms).

void agc_calibrate(void) {
    int32_t e0 = 0, e1 = 0;
    for (int n = 0; n < M; n++) {
        while (!(reg_read(LIVE_VALID) & 1));   // wait for dcr_valid (up to 8 µs)
        int8_t i0 = (int8_t)reg_read(LIVE_I0); // clears LIVE_VALID
        int8_t q0 = (int8_t)reg_read(LIVE_Q0);
        int8_t i1 = (int8_t)reg_read(LIVE_I1);
        int8_t q1 = (int8_t)reg_read(LIVE_Q1);
        e0 += (int32_t)i0*i0 + (int32_t)q0*q0;
        e1 += (int32_t)i1*i1 + (int32_t)q1*q1;
    }
    int32_t noise_floor_0 = e0 / M;  // σ² estimate, ant0
    int32_t noise_floor_1 = e1 / M;  // σ² estimate, ant1

    // Adjust SX1257 LNA/VGA gain via SPI to target e.g. noise_floor ≈ 400 (≈ 20 LSB RMS)
    agc_update_gain(noise_floor_0, noise_floor_1);
}
```

---

## Timing budget

| SF | M | Duration | CPU cycles | Budget | Used |
|---|---|---|---|---|---|
| 7 | 128 | 1.0 ms | ~8,064 | 128,000 (8 ms) | **6.3%** |
| 9 | 512 | 4.1 ms | ~32,256 | 524,288 (33 ms) | **6.2%** |
| 12 | 4,096 | 32.8 ms | ~258,048 | 4,194,304 (262 ms) | **6.2%** |

Per-sample: poll (~16) + 4 AHB reads (~32) + 2 MUL + 4 ADD (~15) = **~63 cycles**.  
Budget per sample: 128 cycles at 16 MHz / 125 kHz. **50% spare on every sample.**

For a quick calibration (AGC only), M=32 (256 µs) is sufficient — 1.6% of SF7 budget.

---

## Use cases

### 1. Inter-packet AGC (primary use)

Run `agc_calibrate()` once per packet gap, targeting a quiet period (noise only). The measured noise floor drives the SX1257 gain:
- Too high → reduce LNA gain
- Too low → increase LNA gain
- Target: noise floor ≈ 300–500 LSB² (≈ 17–22 LSB RMS), keeping ADC well away from clipping

### 2. Signal energy measurement during reception

Run the same loop during packet payload to measure signal+noise power. Compare with pre-packet noise floor to estimate SNR per branch. This can drive weight computation without PSRAM.

### 3. NW-MRC noise estimation (fallback)

If PSRAM readback is not available, run `agc_calibrate()` during the pre-preamble quiet window (before sc_lock) to estimate σ²_j per branch for NW-MRC weight computation.

---

## Comparison with PSRAM readback

| Property | Live IQ registers | PSRAM readback |
|---|---|---|
| Hardware addition | ~2k µm² (4 registers) | ~8k µm² (wr_ptr + diag read) |
| PSRAM required | No | Yes |
| Timing | Real-time, any window | Post-packet, fixed timing |
| History depth | Current sample only | Full packet history |
| NW-MRC capable | Yes (if run during noise window) | Yes (pre-preamble noise) |
| AGC capable | Yes | Yes |
| Complexity | Trivial | Moderate |

**Recommendation:** Implement live IQ registers as the primary AGC calibration path. Use PSRAM readback for per-packet NW-MRC noise estimates (higher quality, reads the specific pre-preamble window). The two approaches are complementary and can coexist.

---

## Relationship to energy_meas_coarse removal

This scheme enables `energy_meas_coarse` removal (−70k µm², −62k µm² net) while preserving:
- ✓ Per-branch AGC (inter-packet calibration)
- ✓ NW-MRC noise estimates (via noise window polling)
- ✓ No PSRAM dependency for basic AGC

The only thing lost vs. hardware `energy_meas_coarse`:
- Per-symbol energy tracking during payload (not needed for AGC)
- Continuous `energy_valid` strobe (not needed when energy_meas removed)

---

## Open items

1. **Confirm address space:** Registers 0xD8–0xDC are currently unallocated in the register map. Verify no conflict.
2. **LIVE_VALID auto-clear on `LIVE_I0` read:** Must be implemented carefully to avoid race between 32 MHz `dcr_valid` and 16 MHz firmware read clock.
3. **Gain control table:** Firmware AGC loop needs a mapping from noise_floor measurement → SX1257 gain register value. Calibrate on bench.
4. **Inter-packet quiet window detection:** Firmware must detect when the channel is idle (sc_detector IDLE state readable via `packet_active` bit in reg_bank 0x34).
