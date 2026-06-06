# Application Notes

Usage scenarios and deployment configurations for the GF180MCU MIMO ASIC.

---

## Cascaded ASIC topology — scalable antenna count

### Overview

The ASIC's REMOD_A output (1-bit ΣΔ I+Q at 32 MS/s) is electrically identical to a SX1257 ADC output. This means multiple ASICs can be cascaded to achieve MRC combining gain beyond the 4-antenna limit of a single device, with no loss of optimality relative to a hypothetical joint NR=8 processor.

### Reference topology: NR=8 (2 front-end ASICs + 1 aggregator)

```
SX1257_1–4  →  ASIC_A  →  REMOD_A  ──┐
                                       ├──  ASIC_C (aggregator)  →  SX1302
SX1257_5–8  →  ASIC_B  →  REMOD_A  ──┘
```

- **ASIC_A** and **ASIC_B**: standard 4-antenna MRC configuration. Each produces a 1-bit ΣΔ combined stream.
- **ASIC_C**: receives the two combined streams on `IQ_DATA_I/Q[0]` and `IQ_DATA_I/Q[1]`. `ANTENNA_EN = 0b00000011` (ports 0 and 1 active). Performs a second stage of MRC across the two super-antennas and forwards the result to SX1302 Radio A.

### Why combining gain is optimal

After ASIC_A's 4-antenna MRC the output is:

```
y_A[n] = ‖h[0..3]‖ · s[n] + noise_A[n]    noise variance σ²
y_B[n] = ‖h[4..7]‖ · s[n] + noise_B[n]    noise variance σ²
```

ASIC_C applies MRC across these two inputs. The resulting output SNR is:

```
SNR_out = (‖h[0..3]‖² + ‖h[4..7]‖²) / σ²
        = Σⱼ |hⱼ|² / σ²    for j = 0..7
```

This equals the SNR of an ideal single-stage 8-antenna joint MRC processor. The cascade introduces no combining loss. The ΣΔ re-modulator's effective SQNR (~44 dB with 8-bit input after ÷2) is negligible relative to thermal noise at all LoRa operating SNRs (LoRa decodes well below 0 dB SNR).

### Why time alignment is preserved

The latency concern that would apply in a non-symmetric cascade does not arise here. ASIC_A and ASIC_B are the same chip running on the same IQ_CLK from the shared TCXO buffer. Their pipeline latencies (CIC + FIR + combiner + ΣΔ re-mod) are identical. Their outputs therefore represent the same time instant of the received signal and arrive at ASIC_C's input pads mutually coherent.

ASIC_C's training accumulator cross-correlates:

```
Z_0 = Σ y_A[n] · conj(y_A[n])   →  ‖y_A‖²  (real, w_0 is real and positive)
Z_1 = Σ y_B[n] · conj(y_A[n])   →  relative complex gain of y_B vs y_A
```

Both inputs retain the LoRa chirp structure (MRC is a linear operation; it scales and phase-shifts but does not alter the self-similar preamble property that SC detection and the training correlator rely on).

### Configuration requirements

| Parameter | ASIC_A / ASIC_B | ASIC_C (aggregator) |
|---|---|---|
| `ANTENNA_EN` | `0xF0` (all 4) | `0xC0` (ports 0+1 only) |
| `MIMO_CTRL.MODE` | 0 (MRC) | 0 (MRC) |
| SC threshold `SC_THR` | default 0.90 | may reduce slightly — each input is already a 4-antenna combined signal with higher per-port SNR |
| `SC_HITS_REQ` | 2 | 2 |
| IQ_CLK source | shared TCXO buffer | shared TCXO buffer (mandatory) |

### Board-level requirements

**Clock fan-out.** All three ASICs and all eight SX1257 XTB pins must be driven from the same TCXO buffer. The current 1→5 buffer (1 ASIC + 4 SX1257s) must be replaced with a 1→11 or 1→16 buffer for this topology.

**SX1302 clock.** SX1257_1 CLK_OUT → SX1302 CLK_IN as in the single-ASIC case. No change.

**ASIC_C unused ports.** `IQ_DATA_I/Q[2:3]` on ASIC_C can be left unconnected (with `ANTENNA_EN` disabling those ports) or connected to two additional SX1257s for a 10-antenna system.

### Scaling further

The same principle generalises to additional layers:

| Layer count | ASICs total | Effective NR |
|---|---|---|
| 1 | 1 | 4 |
| 2 | 3 (2+1) | 8 |
| 2 | 5 (4+1) | 16 |
| 3 | 21 (16+4+1) | 64 |

Each layer adds one pipeline latency (~200 µs estimate at 125 kHz BW). LoRaWAN RX1 window is 1 s; two pipeline delays (~400 µs) leave >2,000× margin. Latency is not a practical constraint at any realistic number of layers.

The primary scaling constraints are clock buffer fan-out, PCB routing complexity, and power.

### Limitations

- All ASICs must share a single IQ_CLK. If any ASIC runs on a different clock, the time-alignment guarantee breaks and combining gain degrades.
- Front-end ASICs should run in MODE=0 (MRC). Running them in passthrough (MODE=1) wastes three of their four antennas, reducing the system to a trivial relay.
- Per-packet weight computation at each layer is independent. Front-end ASICs compute their weights from their local 4-antenna preamble measurements; ASIC_C computes its weights from the two combined-stream preambles. No inter-ASIC coordination is required.
- Calibration (see [Frontend Calibration Procedure](Frontend%20Calibration%20Procedure.md)) must be performed per ASIC independently.
