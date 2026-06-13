# 3-ASIC Cascade — Dual-Polarisation Receive Beam Steering

**Status:** Design exploration (2026-06-08)
**Related:** [NR2 Multi-ASIC Cascade](NR2-multi-ASIC-cascade.md), [MIMO Algorithms](MIMO%20Algorithms.md)

---

## Motivation

A 3-ASIC cascade built from identical NR=4 dies can be configured with 4 horizontally-polarised antennas on ASIC 1, 4 vertically-polarised antennas on ASIC 2, and a combiner on ASIC 3. This gives dual-polarisation diversity and — via SPI-controlled steering weights — receive beam steering in the plane of each sub-array, without any RTL changes.

---

## Antenna Spacing

At 868 MHz, λ ≈ 34.6 cm, λ/2 ≈ 17 cm.

λ/2 element spacing is the natural operating point because it provides full gain in both deployment environments encountered in practice:

| Environment | Channel | What λ/2 spacing gives |
|---|---|---|
| Indoors / rich multipath | Decorrelated fades (d_coh ≈ λ/2) | MRC diversity gain — independent fade branches |
| Outdoors / LOS or sparse scattering | Correlated, phase-ramp channels | Array / beamforming gain — coherent aperture |

Larger spacing (e.g. 1 m to take advantage of cable runs) only benefits the outdoor regime and gives no additional indoor gain once elements are already decorrelated. For a dual-purpose demo, λ/2 is the right choice.

---

## Topology

```
ASIC 1                           ASIC 2
┌──────────────────────┐         ┌──────────────────────┐
│ 4× H-polarised ants  │         │ 4× V-polarised ants  │
│ 4× ΣΔ decimator      │         │ 4× ΣΔ decimator      │
│ SC detect            │         │ SC detect            │
│ training_acc         │         │ training_acc         │
│ weight_gen (fw path) │         │ weight_gen (fw path) │
│ MRC combiner         │         │ MRC combiner         │
│ ΣΔ re-modulator      │         │ ΣΔ re-modulator      │
│ PicoRV32             │         │ PicoRV32             │
└──────┬───────────────┘         └──────────┬───────────┘
       │ REMOD_A (1-bit ΣΔ 32 MHz)          │ REMOD_A
       └─────────────┬───────────────────────┘
                     ▼
              ASIC 3 (identical die)
              ┌───────────────────────────────┐
              │ iq_in[0] ← ASIC 1 REMOD_A    │
              │ iq_in[1] ← ASIC 2 REMOD_A    │
              │ 2× ΣΔ decimator               │
              │ SC detect (on iq_in[0])       │
              │ training_acc (NR=2)           │
              │ weight_gen                    │
              │ MRC combiner                  │
              │ ΣΔ re-modulator               │
              │ PicoRV32                      │
              └───────────────────────────────┘
                     │
                     ▼
              SX1302 combined stream
```

ASIC 3 is configured identically to the NR=2 cascade combiner described in [NR2 Multi-ASIC Cascade](NR2-multi-ASIC-cascade.md), including the OR-lock scheme and shared TCXO clock requirement.

---

## Beam Steering Mechanism

### Why MRC already beams implicitly

In a LOS / low-scattering channel, the signal arriving at branch k of a uniform linear array (ULA) at λ/2 spacing is:

```
h_k = α · exp(jπk·sin(θ))
```

The MRC combiner applies `w^H · x` where MRC weights are the conjugate channel estimates: `w_k = h_k*`. This is exactly the ULA steering vector conjugate — MRC in a LOS channel IS receive beamforming, steered automatically toward the packet source by the preamble training. No firmware intervention is required.

### Explicit steering via firmware weight path

The `weight_gen` block supports a firmware weight path (`wgt_src=1`): the PicoRV32 (or the RPi host via SPI → reg_bank) writes arbitrary complex weights `fw_W_re_k`, `fw_W_im_k` and asserts `fw_W_commit`. The hardware training-derived weights are then ignored for that packet.

To steer the H sub-array (ASIC 1) toward azimuth angle θ:

```
fw_W_re_k = round(A · cos(π·k·sin(θ)))
fw_W_im_k = round(A · -sin(π·k·sin(θ)))    for k = 0, 1, 2, 3
```

where A = 32767 (full scale) normalised by the peak weight magnitude to avoid saturation.

ASIC 2's V sub-array is steered independently in the same way, enabling independent azimuth and elevation control if the H and V arrays are oriented differently.

---

## Operating Modes

### Mode 1 — Adaptive implicit beamforming (no firmware change)

Set `wgt_src=0`, `wgt_mode=11` (MRC) on ASICs 1 and 2. Each ASIC's PicoRV32 estimates the channel from the preamble and commits MRC weights. In LOS this produces a beam steered toward the transmitter; in multipath it produces MRC diversity combining. The system adapts automatically per packet with no RPi involvement.

### Mode 2 — Open-loop scan (RPi-driven)

RPi writes a steering vector to each ASIC's `fw_W_re/im` registers via SPI before packet reception:

1. RPi computes steering vectors for candidate angle θ
2. Writes `fw_W_*` to ASICs 1 and 2 via SPI, sets `wgt_src=1`
3. Waits for LoRa packet detection (SX1302 or ASIC 3 IRQ)
4. If no packet: increment θ, repeat

Scan granularity is limited by SPI write latency and LoRa packet inter-arrival time, not by the ASIC architecture. Practical scan rates depend on the LoRa traffic density being monitored.

### Mode 3 — Closed-loop per-packet refinement (PicoRV32-driven)

On each ASIC, the preamble training provides `Zpair_kl` inter-element cross-correlations in reg_bank `0x40–0x63` (24-bit readback). The PicoRV32 on each front-end ASIC can:

1. Start packet reception with a coarse preset steering weight (from RPi via SPI, or zeroed for MRC fallback)
2. `sc_lock` fires → `training_acc` accumulates over the preamble → `Zpair_kl` committed
3. PicoRV32 reads `Zpair_kl`, estimates inter-element phase differences → computes refined AoA estimate
4. Computes updated `fw_W_re/im` → commits → payload received with refined beam weights

This achieves **adaptive beam steering within a single packet's preamble** at no additional hardware cost. The AoA estimation computation is straightforward on RV32IM: six complex multiplications and argument extraction, well within the preamble training window budget (~131k cycles at SF7).

---

## Capability Summary

| Capability | Available | Notes |
|---|---|---|
| Indoor MRC diversity gain (4-element H sub-array) | Yes | Mode 1, automatic |
| Indoor MRC diversity gain (4-element V sub-array) | Yes | Mode 1, automatic |
| Polarisation diversity combining (H+V at ASIC 3) | Yes | All modes |
| Outdoor implicit azimuth beamforming | Yes | Mode 1, automatic |
| Explicit azimuth beam scan (H plane) | Yes | Modes 2 and 3, via fw_W path |
| Explicit elevation beam scan (V plane, if array oriented for it) | Yes | Modes 2 and 3, via fw_W path |
| Per-packet adaptive AoA refinement | Yes | Mode 3, PicoRV32 firmware |
| Full 8-element coherent aperture beam steering | No | Cascade collapses 4→1 stream before ASIC 3 |
| Null steering / interference cancellation | No | MRC maximises SNR, does not null interferers |
| Transmit beamforming | No | NT=1 single ΣΔ output |

### Gain budget (approximate)

| Stage | Gain |
|---|---|
| 4-element H sub-array (ASIC 1, LOS coherent) | ~6 dB |
| 4-element V sub-array (ASIC 2, LOS coherent) | ~6 dB |
| ASIC 3 polarisation combining (MRC of 2 streams) | ~3 dB |
| **Total over single antenna** | **~7–8 dB** (accounting for sub-optimality of hierarchical MRC) |

True 8-element coherent combining would give ~9 dB. The ~1–2 dB gap is the cost of the two-level hierarchy (see [NR2 Multi-ASIC Cascade — Combining Gain and Suboptimality](NR2-multi-ASIC-cascade.md#combining-gain-and-suboptimality)).

---

## Physical Constraints

### Cable length to antennas

The SX1257 outputs 1-bit ΣΔ streams synchronous to the shared TCXO. Cable length from SX1257 to ASIC pad is not constrained by spatial diversity requirements — antenna separation determines diversity, not cable length to the ASIC.

**Clock topology is the binding constraint:** if the TCXO is co-located with the ASIC (at the ASIC demo board), each SX1257 1m away receives the clock 1m out and returns data 1m back — a ~10 ns net skew at 31 ns (32 MHz) period. Place the TCXO with the SX1257 cluster so both clock and data travel the same ~1 m to the ASIC, collapsing skew to the SX1257 internal pipeline delay only.

### OR-lock between ASIC 1 and ASIC 2

Required for PSRAM replay alignment at ASIC 3, as documented in [NR2 Multi-ASIC Cascade — Inter-Chip Lock Detect](NR2-multi-ASIC-cascade.md#inter-chip-lock-detect--or-lock-scheme). The OR-lock wires (`sc_lock_out`, `sc_lock_in`) must be routed between ASIC 1 and ASIC 2 on the PCB.

### Shared clock and reset

All three ASICs must share a single 32 MHz TCXO source and a reset driven from a single registered output with matched trace lengths. See [NR2 Multi-ASIC Cascade — Inter-Chip Clock and Reset](NR2-multi-ASIC-cascade.md#why-timing_ref-is-still-valid-after-a-forced-lock).

---

## Open Items

1. **AoA estimation firmware** — implement `Zpair_kl` → inter-element phase → steering vector computation on PicoRV32. Verify runtime fits within preamble window at SF7 (tightest case).
2. **SQNR cascade simulation** — same risk as the NR=2 cascade: two ΣΔ re-mod/decim stages before ASIC 3 combiner. Verify SNR margin is acceptable. See [NR2 Multi-ASIC Cascade — Re-Modulator SQNR Accumulation](NR2-multi-ASIC-cascade.md#re-modulator-sqnr-accumulation).
3. **Antenna arrangement for 2D steering** — to get independent azimuth and elevation control, H antennas must be spaced horizontally and V antennas vertically. Confirm demo mechanical arrangement.
4. **Open-loop scan latency** — characterise SPI write time for fw_W update and determine practical scan rate given LoRa packet inter-arrival times.
