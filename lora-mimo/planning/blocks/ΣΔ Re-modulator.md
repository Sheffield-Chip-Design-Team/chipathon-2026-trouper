# ΣΔ Re-modulator

RX path stage 9. See [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Page-37-style 3rd-order feed-forward sigma-delta modulator converting int8 combined samples back to a 1-bit I+Q bitstream at 32 MS/s for the SX1302 Radio A input. The chosen structure is three delayed, saturating integrators with a feed-forward summer into a 1-bit sign quantiser, matching the SX1257 datasheet diagram.

```
Three cascaded ideal integrators (Z⁻¹/(1−Z⁻¹)) with feed-forward
coefficients summed at a 1-bit quantiser.
Integrators must saturate — not wrap — to ensure stability.
Input must be kept below −3 dBFS for stable operation.
```

OSR = 256 / 128 / 64 for 125 / 250 / 500 kHz BW respectively (32 MS/s / f_s). In-band SQNR > 100 dB at the lowest OSR (64, 500 kHz BW). The 8-bit input gives ~50 dB in-band SQNR, which exceeds LoRa decoding requirements by > 50 dB at all operating SNRs.

---

## Interface

| Port | Direction | Width | Rate | Description |
| --- | --- | --- | --- | --- |
| `in_i` | in | 8 signed | f_s | I from combiner (÷2 already applied in combiner MRC output stage) |
| `in_q` | in | 8 signed | f_s | Q from combiner (÷2 already applied in combiner MRC output stage) |
| `in_valid` | in | 1 | f_s | Sample strobe |
| `en` | in | 1 | static | 0 = output driven to midscale idle (for gating during TX window if required) |
| `clk_32m` | in | — | 32 MHz | Master clock |
| `rst_n` | in | — | — | Active-low reset |
| `out_i` | out | 1 | 32 MS/s | 1-bit I bitstream → SX1302 |
| `out_q` | out | 1 | 32 MS/s | 1-bit Q bitstream → SX1302 |

---

## Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| Modulator order | 3 | Feed-forward topology |
| OSR | 256 / 128 / 64 | 32 MS/s / f_s; 125 kHz BW → OSR=256, 250 kHz → 128, 500 kHz → 64 |
| Integrator width | 12-bit signed | 8-bit input + 4 bits stability headroom; prevents saturation at full-scale input |
| Feed-forward coefficients | Per NTF design | Optimise for SQNR; see Lee/Schreier DELSIG reference |
| Input ÷2 shift | Fixed 1-bit right-shift | Applied in the combiner MRC output stage (not here); bypass path receives no ÷2 |
| Input full-scale | −3 dBFS max (after ÷2) | Stability constraint; AGC owns this — see AGC headroom constraint |

---

## Implementation notes

**Page-37 feed-forward structure.** Three delayed integrators feed a weighted summer and a sign comparator. The quantiser output is fed back as a symmetric +127/−127 1-bit stream, while each integrator state saturates rather than wrapping. This is the architecture that now matches the datasheet diagram and the loopback probe result, so the remaining work is output swing tuning, not loop stability.

**Integrator saturation.** Each integrator accumulator must clamp to ±(2^(width−1)−1) rather than wrap. Wrap-around causes instability that does not self-recover. Use saturating adders.

**Input level constraint.** 3rd order ΣΔ modulators with Lee's criterion require input < −3 dBFS. The re-modulator receives int8 directly from the combiner. The combiner MRC output stage applies the ÷2 right-shift (absorbing √NR=4 combining gain); the bypass path delivers int8 directly with no ÷2, preserving the full per-branch amplitude. In both modes the remod receives a signal scaled to approximately per-branch decimator amplitude. The AGC is responsible for keeping per-branch amplitude below −3 dBFS; no additional scaling at the remod input is needed. The ÷2 in the MRC path costs 6 dB of dynamic range there, but with 8-bit input the in-band SQNR is already limited to ~44 dB after ÷2, which far exceeds LoRa requirements.

**Clock domain.** Input is at f_s (in_valid strobe); modulator runs at 32 MHz. On `in_valid`, latch the input into a register and run the 3rd order loop at 32 MHz for the next 32 cycles.

**TX gating.** If the SX1302 does not cleanly ignore REMOD_A while transmitting, set `en=0` for the TX window (drives output low). See TX chain notes in [System Architecture](../System%20Architecture.md).

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Sine at −6 dBFS, 10 kHz | cocotb: inject; Python decimate output | SQNR > 80 dB after decimation |
| Sine at −3 dBFS | Same | Stable output; SQNR > 70 dB |
| Input at 0 dBFS | Same | Integrators saturate; output does not latch up |
| DC input | Various DC levels | Output bitstream average matches input; no runaway |
| Output gated | `en=0` | `out_i` / `out_q` held low |
| Reset recovery | Assert `rst_n`, release, inject sine | Stable output within 100 cycles |

---

## Open items

**Validate 8-bit input with cocotb simulation.** The integrator width reduction from 20-bit to 12-bit and the int8 input truncation after ÷2 are based on analysis at the AGC operating point (−12 dBFS per branch, NR=4 MRC). Before RTL freeze, verify with cocotb:
- Sine at −6 dBFS input: SQNR after decimation > 40 dB (expected ~44 dB)
- AGC transient: brief overload at 0 dBFS per branch before AGC settles; confirm saturation to int8 does not cause modulator latch-up
- Confirm 12-bit integrators do not saturate at maximum stable input level (−3 dBFS)

---

## Related blocks

- [ALMMSE-MRC Combiner](ALMMSE-MRC%20Combiner.md) — int8 output (MRC: int32 ÷2 → int8; bypass: direct int8)
- [System Architecture](../System%20Diagram.md) — REMOD_CLK routing, SX1302 interface
- [DSP Flow](../DSP%20Flow.md)
