# Frontend Calibration — RF Loopback Procedure

Derives and programs the `cal_j` coefficients used by firmware weight generation to correct per-branch gain and phase mismatch before MRC/eigenvector computation.

**Related:** [Weight Generation](blocks/Weight%20Generation.md) · [Register Map](Register%20Map.md) · [Test Plan — AFE characterisation](Test%20Plan.md) · [System Architecture](System%20Architecture.md)

---

## Background

Firmware weight generation applies calibration as:

```
H_j_cal = H_j · conj(cal_j)
```

`H_j` is the per-branch channel estimate produced by the Training Accumulator. `cal_j` is a static complex Q1.15 coefficient that corrects for gain/phase mismatch introduced by the SX1257 mixers and PCB routing — mismatch that is constant across packets and must be removed before coherent combining.

Default: `cal_j = 1+0j` (no correction) for all branches.

### Current limitation — true I/Q imbalance

This procedure corrects **scalar** branch mismatch only: relative gain error and relative carrier-phase error between receive branches. It does **not** implement a true per-branch I/Q imbalance correction.

That distinction matters because true I/Q imbalance is widely-linear. A mismatched branch is better modelled as:

```
y_j = mu_j * x_j + nu_j * conj(x_j)
```

not just `y_j = a_j * x_j`. A single complex coefficient `cal_j` can absorb the `a_j` term but cannot cancel the image term `nu_j * conj(x_j)`.

For the current Trouper revision, treat any residual branch-dependent I/Q imbalance as an uncorrected frontend impairment. It can bias the measured Z matrix and reduce the achievable gain of the existing linear MRC / eigenvector combiner even when DC removal and scalar calibration are working correctly.

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

The dedicated `CAL_*` hardware register bank was removed with the hardware `weight_gen` block. For the current tapeout plan, initialise the firmware-side `cal_j` table in CPU SRAM (or the host-side equivalent if weights are computed off-chip) to:

```
cal_0 = cal_1 = cal_2 = cal_3 = 1 + 0j
```

### Step 2 — Enable calibration signal path

**Method A:**

1. Verify all four SE2435L T/R switches are in RX mode (`FEM_CTRL` register).
2. Enable all four SX1257s for RX via SPI.
3. Start the test node transmitting. Confirm signal level at splitter output port is approximately −65 to −75 dBm (mid-range, clear of noise floor and compression).

**Method B:**

1. Configure all four SX1257s at the same centre frequency and SF as the SX1302 TX.
2. Enable RF loopback on each SX1257 (SX1257 datasheet §3.8.2). The PA output is internally routed to the LNA input.
3. Set SX1302 PA power to the minimum configurable level — the internal loopback path has no external attenuation and will saturate the RX at normal TX power.
4. Trigger the SX1302 to begin transmitting a LoRa preamble repeatedly.

### Step 3 — Capture Z_j

1. Set `MIMO_CTRL.MODE=0` (MRC mode) and enable all four branches (`ANTENNA_EN = 0xF`).
2. Arm the SC detector and wait for `IRQ_TRAINING_DONE`. The Training Accumulator produces the all-pairs Z matrix.
3. Read the required Z values from the register bank. For the current firmware path, prefer the full all-pairs matrix (`0x70`–`0xEF`) rather than the legacy `Z_j` subset.
4. Record the per-branch complex estimates needed to derive `cal_j` for all four branches.

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

### Step 5 — Store cal_j for firmware use

```python
# Current plan: keep calibration coefficients in firmware memory.
# They may be compiled into the firmware image, loaded into CPU SRAM before
# releasing CPU reset, or supplied to an off-chip host weight engine.
firmware_cal = cal_q15
```

### Step 6 — Verify

Repeat Step 3 with `cal_j` now loaded into firmware memory. Firmware weight generation now applies `H_j_cal = H_j · conj(cal_j)` before producing weights.

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

If both checks pass, retain these coefficients as the firmware default calibration set for normal operation.

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
