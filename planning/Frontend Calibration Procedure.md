# Frontend Calibration — RF Loopback Procedure

Derives and programs the `cal_j` coefficients (`CAL_0..3` registers at `0xA0`–`0xAF`) that correct per-branch gain and phase mismatch in the Weight Generation block.

**Related:** [Weight Generation](blocks/Weight%20Generation.md) · [Register Map](Register%20Map.md) · [Test Plan — AFE characterisation](Test%20Plan.md) · [System Architecture](System%20Architecture.md)

---

## Background

The Weight Generation block applies calibration as:

```
H_j_cal = H_j · conj(cal_j)
```

`H_j` is the per-branch channel estimate produced by the Training Accumulator. `cal_j` is a static complex Q1.15 coefficient that corrects for gain/phase mismatch introduced by the SX1257 mixers, LNA, and PCB routing — mismatch that is constant across packets and must be removed before coherent combining.

Default: `cal_j = 1+0j` (no correction) for all branches.

### Why the signal must be a LoRa preamble

The calibration measurement reads `Z_j` from the Training Accumulator output registers (`0x70`–`0x8F`). The Training Accumulator computes:

```
Z_j = Σ rx_j[n] · conj(rx_ref[n])
```

where `rx_ref` is the known upchirp sequence. A CW tone has zero correlation with this reference and produces `Z_j ≈ 0` — it cannot be used. The calibration signal must be a LoRa preamble so that the accumulator produces a valid channel estimate on each branch.

---

## Two calibration methods

### Method A — External LoRa node via splitter (preferred)

A LoRa test node (e.g. Heltec V3) transmits a LoRa preamble into a 4-way RF power splitter whose four output ports connect by cable to the four SX1257 RX input ports (bypassing the antennas). All four branches receive the same coherent preamble. Because all four SX1257s share the same TCXO reference (XTB fan-out), any phase or amplitude difference in the measured `Z_j` is hardware mismatch.

**When to use:** first silicon bring-up; board-level calibration before deployment; whenever an absolute inter-branch reference is needed.

### Method B — SX1257 internal RF loopback

The SX1257 can route its TX DAC input back to the LNA input internally (SX1257 datasheet §3.8.2). The SX1302 is configured to transmit a LoRa preamble, driving the SX1257 TX sigma-delta inputs. With all four SX1257s in RF loopback simultaneously, each RX path receives its own TX signal. Because all devices share the TCXO reference, the four received preambles are frequency-coherent and the inter-branch `Z_j` comparison is valid.

**When to use:** board not yet assembled with an external splitter; quick in-circuit inter-branch check. **Note:** RF loopback exercises the full RX mixer chain but the TX→RX amplitude is an internal path and may not match the external-signal gain. Use Method A when absolute amplitude calibration matters.

---

## Calibration math

### Measuring P_j

With a LoRa preamble injected into all branches, the Training Accumulator produces `Z_j`. For a coherent common input:

```
Z_j ≈ P_j · C
```

where `P_j = A_j · exp(j·φ_j)` is the effective complex gain of branch j and `C` is a common scalar that cancels in the normalisation step.

### Choosing the reference branch

Pick the branch with the largest magnitude as the reference to ensure all `cal_j` have magnitude ≤ 1 (required for Q1.15 representation):

```python
j_ref = argmax_j |Z_j|
P_ref  = Z[j_ref]
```

If all branches are within 1 dB of each other, branch 0 is a simpler choice. If any branch magnitude is more than 6 dB below the maximum, stop and see Failure thresholds.

### Computing cal_j

```python
for j in range(4):
    # conj(P_ref / P_j): rotates H_j so all branches align with the reference phasor
    cal_j[j] = conj(P_ref / Z[j])
```

Expanded in polar form (useful for sanity checks):

```
|cal_j|   = |P_ref| / |Z_j|           # amplitude equalisation to reference branch
∠cal_j    = ∠Z_j - ∠P_ref             # phase correction relative to reference
```

For `j == j_ref`: `cal_j = conj(1) = 1+0j` — reference branch keeps the default value.

### Q1.15 encoding

```python
def to_q15(x: float) -> int:
    """Clamp and round float in [-1,1) to signed 16-bit Q1.15."""
    v = round(x * 32767)
    return max(-32768, min(32767, v))

for j in range(4):
    I_q15 = to_q15(cal_j[j].real)
    Q_q15 = to_q15(cal_j[j].imag)
```

Q1.15 cannot represent exactly +1.0; 0x7FFF ≈ +0.99997 is the maximum. The error is negligible.

---

## Step-by-step procedure

### Prerequisites

- ASIC powered, SPI communication verified
- BIST passed (or degraded-mode channel mask set)
- DC Removal settling elapsed: allow ≥ 512 samples at f_s = 125 kS/s after reset before capturing (see [DC Removal](blocks/DC%20Removal.md))
- **Method A:** LoRa test node connected via SMA cable → 4-way power splitter → four SX1257 RX input ports; node configured to transmit repeatedly at the gateway centre frequency and SF
- **Method B:** SX1302 TX path enabled and configured to transmit a LoRa preamble; all four SX1257 TX sigma-delta inputs driven from SX1302; RF loopback not yet enabled (enable in Step 2)

### Step 1 — Reset cal_j to defaults

Write the default values to all `CAL` registers so no prior calibration affects the measurement:

| Register | Address | Value |
|---|---|---|
| `CAL_0_I_HI` | `0xA0` | `0x7F` |
| `CAL_0_I_LO` | `0xA1` | `0xFF` |
| `CAL_0_Q_HI` | `0xA2` | `0x00` |
| `CAL_0_Q_LO` | `0xA3` | `0x00` |
| `CAL_1_I_HI` | `0xA4` | `0x7F` |
| `CAL_1_I_LO` | `0xA5` | `0xFF` |
| `CAL_1_Q_HI` | `0xA6` | `0x00` |
| `CAL_1_Q_LO` | `0xA7` | `0x00` |
| `CAL_2_I_HI` | `0xA8` | `0x7F` |
| `CAL_2_I_LO` | `0xA9` | `0xFF` |
| `CAL_2_Q_HI` | `0xAA` | `0x00` |
| `CAL_2_Q_LO` | `0xAB` | `0x00` |
| `CAL_3_I_HI` | `0xAC` | `0x7F` |
| `CAL_3_I_LO` | `0xAD` | `0xFF` |
| `CAL_3_Q_HI` | `0xAE` | `0x00` |
| `CAL_3_Q_LO` | `0xAF` | `0x00` |

### Step 2 — Enable calibration signal path

**Method A:**

1. Verify all four SE2435L T/R switches are in RX mode (`FEM_CTRL` register).
2. Enable all four SX1257s for RX via SPI.
3. Start the test node transmitting. Confirm signal level at splitter output port is approximately −65 to −75 dBm (mid-range, clear of noise floor and compression).

**Method B:**

1. Configure all four SX1257s at the same centre frequency and SF as the SX1302 TX.
2. Enable RF loopback on each SX1257 (SX1257 datasheet §3.8.2). The PA output is internally routed to the LNA input; FEM T/R switch state does not matter.
3. Set SX1302 PA power to the minimum configurable level — the internal loopback path has no FEM attenuation and will saturate the RX at normal TX power.
4. Trigger the SX1302 to begin transmitting a LoRa preamble repeatedly.

### Step 3 — Capture Z_j

1. Set `WGT_SRC = SW` (bit 0 of `WGT_CTRL` = 1) so the hardware FSM does not auto-commit and overwrite the measurement.
2. Set `MIMO_CTRL.MODE=0` (MRC mode) and enable all four branches (`ANTENNA_EN = 0xF`).
3. Arm the SC detector and wait for `IRQ_TRAINING_DONE`. The Training Accumulator produces `Z_j` by correlating each branch against the upchirp reference.
4. Read `Z_j` from registers `0x70`–`0x8F` (see [Register Map](Register%20Map.md) for byte layout). Each `Z_j` is a complex int32 pair: I[31:0] at byte offsets 0–3, Q[31:0] at byte offsets 4–7, for branch j = 0..3.
5. Record `Z_j` for all four branches.

Repeat steps 3–5 three times and average in the complex domain to reduce noise:

```python
Z_avg[j] = (Z_run1[j] + Z_run2[j] + Z_run3[j]) / 3
```

### Step 4 — Compute cal_j

```python
import numpy as np

Z = np.array([Z_avg[0], Z_avg[1], Z_avg[2], Z_avg[3]], dtype=complex)

# Sanity check amplitudes
amplitudes_dB = 20 * np.log10(np.abs(Z) / np.max(np.abs(Z)))
for j, dB in enumerate(amplitudes_dB):
    if dB < -6:
        print(f"WARNING: branch {j} is {dB:.1f} dB below reference — see Failure thresholds")

# Reference is the strongest branch
j_ref = int(np.argmax(np.abs(Z)))
P_ref = Z[j_ref]

# cal_j = conj(P_ref / Z_j)
cal = np.conj(P_ref / Z)

# Branch j_ref must be 1+0j
assert abs(cal[j_ref] - 1.0) < 1e-9

# All magnitudes must be <= 1.0 (required for Q1.15)
for j in range(4):
    if abs(cal[j]) > 1.0:
        raise ValueError(f"cal[{j}] magnitude = {abs(cal[j]):.4f} > 1.0 — normalisation error")

# Encode as Q1.15
def to_q15(x):
    return int(max(-32768, min(32767, round(x * 32767))))

cal_q15 = [(to_q15(c.real), to_q15(c.imag)) for c in cal]
```

### Step 5 — Write cal_j to registers via SPI

```python
reg_map = [
    (0xA0, 0xA1, 0xA2, 0xA3),   # branch 0: I_HI, I_LO, Q_HI, Q_LO
    (0xA4, 0xA5, 0xA6, 0xA7),   # branch 1
    (0xA8, 0xA9, 0xAA, 0xAB),   # branch 2
    (0xAC, 0xAD, 0xAE, 0xAF),   # branch 3
]

for j, (I_HI, I_LO, Q_HI, Q_LO) in enumerate(reg_map):
    I_val, Q_val = cal_q15[j]
    spi_write(I_HI, (I_val >> 8) & 0xFF)
    spi_write(I_LO,  I_val       & 0xFF)
    spi_write(Q_HI, (Q_val >> 8) & 0xFF)
    spi_write(Q_LO,  Q_val       & 0xFF)
```

### Step 6 — Verify

Repeat Step 3 (inject preamble, wait for `IRQ_TRAINING_DONE`, read `Z_j`) with `cal_j` now programmed. The Weight Generation block now applies `H_j_cal = H_j · conj(cal_j)` before producing weights.

```python
Z_post = read_z_j_registers()   # new measurement with cal applied

# Phase spread across branches should now be < 5°
phases_deg = np.angle(Z_post, deg=True)
phase_spread = np.max(phases_deg) - np.min(phases_deg)
assert phase_spread < 5.0, f"Residual phase spread = {phase_spread:.1f}° — re-check"

# Amplitude spread should be < 0.5 dB
amplitudes_dB = 20 * np.log10(np.abs(Z_post))
amp_spread = np.max(amplitudes_dB) - np.min(amplitudes_dB)
assert amp_spread < 0.5, f"Residual amplitude spread = {amp_spread:.1f} dB — re-check"
```

If both checks pass, set `WGT_SRC = AUTO` (bit 0 of `WGT_CTRL` = 0) to return to normal hardware weight generation.

---

## Failure thresholds and disposition

| Observed condition | Classification | Disposition |
|---|---|---|
| Any branch > 6 dB below strongest | Investigate | Check cable/splitter port; re-run; if repeatable across power cycles, flag as SX1257 gain fault |
| Post-cal phase spread > 5° | Calibration insufficient | Increase averaging (more runs in Step 3); check preamble signal stability during capture |
| Post-cal amplitude spread > 1 dB | Calibration insufficient | Check for near-compression on any branch; reduce injection level and repeat |
| `|cal_j|` > 1.0 before Q1.15 encode | Normalisation error | j_ref selection logic bug — re-check argmax; should never occur if strongest-branch normalisation is correct |
| Branch completely dead (`|Z_j|` ≈ 0) | Hardware fault | Check SX1257 SPI config; run BIST on DSP SRAM; if SRAM fault, enter degraded mode (see [Memory Strategy](Memory%20Strategy.md)) |
| Calibration result changes > 2° between power cycles | LO phase instability | Check TCXO XTB fan-out levels (1.8 V pk-pk max); verify shared TCXO reaches all SX1257 XTB pins |

---

## Calibration persistence

The `CAL` registers are not battery-backed. They must be reprogrammed by the RPi host after every power cycle, before releasing `CPU_RESET`. Recommended boot sequence:

```
Power-on
  ↓
BIST (DSP and CPU SRAMs)
  ↓
Write CAL registers from stored values on host filesystem
  ↓
Load firmware → release CPU_RESET
  ↓
Optional: re-verify with single-packet calibration injection
```

Re-run the full calibration procedure if ambient temperature changes by more than ~20 °C from the last calibration run, as SX1257 mixer phase balance has temperature dependence.
