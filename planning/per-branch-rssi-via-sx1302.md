# Per-Branch RSSI via SX1302 — Branch-Cycling AGC Scheme

**Date:** 2026-06-03  
**Status:** Design proposal — not yet implemented  
**Related:** [area-cut-contingency.md](area-cut-contingency.md), [live-iq-agc-calibration.md](live-iq-agc-calibration.md)

---

## Motivation

`energy_meas_coarse` (70k µm²) is the only hardware per-branch signal level source. Neither the SX1257 nor the SX1302 provides per-branch RSSI in normal operation. However, the SX1302 has a **continuously-updated channel RSSI register** (`SX1302_REG_RX_TOP_RSSI_VALUE_CHAN_RSSI`, reg 350) that operates on its raw IF input — and the `mrc_combiner` already has a bypass mode that routes a single antenna's IQ directly to the output.

By **cycling through branches in passthrough mode** between LoRa packets, the SX1302 can measure RSSI for each branch in turn, giving per-branch signal levels with no additional hardware.

---

## Mechanism

The `mrc_combiner` bypass mode (already implemented, `mode=1`, `bypass_ant[1:0]`) routes one antenna's decimated IQ directly through `sd_remod` to the SX1302 IF input. The SX1302 measures RSSI on whatever signal it sees on its IF input — in bypass mode that signal is a single antenna branch.

```
Normal operation (MRC mode):
  [ant0, ant1] → mrc_combiner → combined y → sd_remod → SX1302

Branch-k measurement (bypass mode):
  ant_k → mrc_combiner (passthrough) → ant_k IQ → sd_remod → SX1302
                                                               ↓
                                              RSSI_k = SX1302 reg 350
```

---

## SX1302 RSSI register (confirmed from HAL source)

| Register | ID | Description |
|---|---|---|
| `SX1302_REG_RX_TOP_RSSI_VALUE_CHAN_RSSI` | 350 | Continuously-updated channel RSSI (exponential filter output) |
| `SX1302_REG_RX_TOP_RSSI_CONTROL_RSSI_FILTER_ALPHA` | 341 | Filter time constant (configurable α) |
| `SX1302_REG_RADIO_FE_RSSI_BB_OUT` | 791 / 805 | Raw baseband RSSI per RF chain |

- Operates on raw IF input — **before LoRa demodulation**, so valid without a LoRa packet present
- Continuously updated via configurable exponential filter — no packet trigger needed
- dBm offset per RF chain (`rssi_offset`) applied in software for absolute calibration

---

## Calibration sequence

```
// Run between LoRa packets (packet_active = 0, sc_detector IDLE)
for branch k in [0, 1]:   // NR=2
    reg_write(MIMO_CTRL, bypass_ant=k, mode=PASSTHROUGH)
    wait(T_settle)          // allow SX1302 RSSI filter to settle; T_settle ≈ 5/α samples
    RSSI_k = spi_read_sx1302(REG_CHAN_RSSI)   // via spi_master or external MCU
    gain[k] = agc_gain_from_rssi(RSSI_k)
    spi_write_sx1257_k(GAIN_REGISTER, gain[k])

reg_write(MIMO_CTRL, mode=MRC)   // restore combining
```

**Settle time:** With α = 1/8 (fast response), ~5 filter taps × 8 µs/sample = 40 µs. Set α = 1/2 for even faster (5 × 8 = 40 µs still fine). Total calibration: 2 branches × ~100 µs each = ~200 µs per calibration cycle. LoRa inter-packet gaps are typically tens to hundreds of ms.

---

## Control path options

### With PicoRV32 (preferred)

PicoRV32 firmware runs the calibration sequence using the on-chip `spi_master` (`sx_target` MUX selects SX1302 for RSSI read, SX1257[k] for gain write). No external hardware needed.

**Required addition:** `sx_target` must include SX1302 as a target. Check current `sx_target` encoding in reg_bank — if SX1302 is not already addressable via `spi_master`, add one address entry.

### Without PicoRV32 (external MCU)

External MCU controls the ASIC via `spi_slave`:
1. Write `bypass_ant=k, mode=PASSTHROUGH` to ASIC reg_bank via SPI
2. Read SX1302 RSSI via direct SPI from external MCU to SX1302
3. Write new gain to SX1257[k] via direct SPI from external MCU

No new ASIC hardware needed. The `spi_slave` already exposes reg_bank fully.

---

## Comparison with other per-branch AGC approaches

| Approach | HW needed | CPU needed | Notes |
|---|---|---|---|
| `energy_meas_coarse` (current) | 70k µm² | No | Continuous per-branch; always on |
| Branch-cycling via SX1302 RSSI (this doc) | **0 µm²** | No (ext MCU) or PicoRV32 | Between-packet only; ~200 µs per cycle |
| Live IQ register polling | ~2k µm² | PicoRV32 only | Between-packet; works offline from SX1302 |
| PSRAM readback | ~8k µm² | PicoRV32 only | Per-packet; highest quality noise estimate |

**Branch-cycling requires zero new hardware.** It uses existing bypass mode + SX1302 RSSI that is always present.

---

## Constraints and limitations

1. **Between-packet only:** Switching to bypass mode during a packet would corrupt MRC combining. Must only run during inter-packet gaps (check `packet_active = 0` in reg 0x34).

2. **SX1302 sees single-branch signal:** During bypass, the SX1302 is no longer receiving the combined MRC stream. Any LoRa packet arriving during calibration will be missed. Calibration window must be short relative to expected packet arrival rate.

3. **ΣΔ re-modulator SQNR:** The bypass IQ passes through `sd_remod` before reaching SX1302. The re-modulator adds ~34 dB SQNR limit. For AGC purposes (coarse dB-level measurement) this is fully acceptable.

4. **SX1302 RSSI calibration:** The `rssi_offset` per-chain calibration constant must be characterised once on the bench to convert raw register value to dBm. One-time calibration only.

5. **sx_target encoding:** Verify `sx_target [1:0]` in reg_bank supports SX1302 as a read target for PicoRV32 path. Current encoding targets SX1257 instances; may need one additional address slot.

---

## Impact on contingency list

This scheme confirms that `energy_meas_coarse` can be removed (−70k µm²) with **zero additional hardware**, while retaining full per-branch AGC capability in both CPU and CPU-less configurations. The previous constraint ("only viable if PicoRV32 is present") no longer applies.

Update: energy_meas_coarse removal risk level is now **Low** given this scheme.
