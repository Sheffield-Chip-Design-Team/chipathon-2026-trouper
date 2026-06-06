# AGC

Per-antenna automatic gain control for the four SX1257 receive chains.

The AGC loop is implemented in the ASIC firmware on PicoRV32. It adjusts each SX1257's `RegRxAnaGain` independently based on energy measured at packet lock.

If PicoRV32 is not operational, AGC is simply absent rather than blocking RX. The supported fallback is fixed gain:

- `RX_GAIN_ACTIVE_0..3` remain at their reset values, or
- the host pre-programs `RX_GAIN_SHADOW_0..3` and commits them before leaving the chip in RX-only mode

This means AGC is an optimisation and robustness feature, not a correctness dependency for baseline reception.

---

## Why AGC lives in the ASIC

This design cannot rely on the SX1302's normal gain-control path for the receive antennas used by MRC/ALMMSE.

Reasons:

- The four SX1257s are controlled through the ASIC SPI master, not through the SX1302 control path.
- Combining happens before the SX1302 sees the signal, so gain decisions must be made per antenna on the raw branches.
- The ASIC needs per-antenna energy and saturation handling before channel estimation and combining.
- The gateway may run different gain settings on different antennas; this is invisible to the downstream SX1302.

The result is:

- SX1302 remains the downstream LoRa demodulator
- PicoRV32 owns RX gain policy for `SX1257_0..3` when CPU-managed mode is active
- without PicoRV32, gain remains fixed at the programmed fallback setting

---

## Trigger and timing

AGC runs once per packet at `IRQ_STATUS.CORR_LOCK`.

Sequence:

1. Energy detector latches per-antenna energy over the last 8 symbols
2. `CORR_LOCK` IRQ fires
3. PicoRV32 reads the energy snapshot
4. PicoRV32 updates `RX_GAIN_SHADOW_n` for each antenna if needed
5. PicoRV32 pulses `RX_GAIN_COMMIT`
6. New gain applies at the next packet-safe boundary

Important constraints:

- no mid-packet gain changes
- AGC is independent of the later `IRQ_TRAINING_DONE` / W-computation path
- AGC is skipped during TX windows
- between packets, gain stays frozen

This is intentional: maximum idle gain preserves weak-packet sensitivity, and any gain change after lock would break packet consistency.

---

## Controlled register

Each SX1257 uses `RegRxAnaGain (0x0C)`.

Bit layout:

| Bits | Field | Range | Meaning |
| --- | --- | --- | --- |
| [7:5] | `RxLnaGain` | 1..6 | `1 = G1` max gain, `6 = G6` min gain |
| [4:1] | `RxBbGain` | 0..15 | Baseband gain, 2 dB per step |
| [0] | `LnaZin` | 0 | Keep 50 ohm setting |

Notes:

- `RxLnaGain` is inverted: larger register value means less gain
- LNA steps are non-uniform: 6 dB for `G1..G3`, 12 dB for `G3..G6`
- usable total range is about 70 dB; nominal register range is 78 dB

Host-visible control and state:

- `RX_GAIN_SHADOW_0..3` at `0x20`–`0x23`
- `RX_GAIN_ACTIVE_0..3` at `0x26`–`0x29`
- `RX_GAIN_CTRL` at `0x2A`

These registers implement the same shadow/active model used elsewhere in the design:

- writers modify `RX_GAIN_SHADOW_n`
- `RX_GAIN_COMMIT` requests promotion
- the request applies to all four branches together
- the Packet Control FSM `safe_switch` window is the only legal apply point
- a gain-control sequencer drives the SX1257 SPI writes during that safe window
- `RX_GAIN_ACTIVE_n` shows the live state currently in force
- `RX_GAIN_PENDING` stays set until the off-chip writes complete
- `RX_GAIN_ERROR` indicates the previous apply sequence did not complete, in which case the old live gain remains in force

---

## AGC input

AGC uses the per-antenna energy snapshot captured at lock:

```text
ENERGY_n = Σ |x_n|² over the last 8 symbols
```

Properties:

- int16 unsigned
- arbitrary units
- proportional to received power before gain control
- latched at correlator lock so all later firmware reads are packet-consistent

**Non-FFT path: energy tap point must be full-precision decimator output.**

In the non-FFT frontend, the FRONTEND_BUF writes 8-bit *saturated* samples to SRAM. If the energy measurement reads from SRAM rather than the decimator, strong signals that are being clamped to ±127 will appear at lower energy than they actually are — the saturation hides the true signal level from AGC.

The energy measurement must tap the **full-precision samples from the decimator output** (the same point used by the training accumulator), before the 8-bit saturation applied at the SRAM write path. This ensures AGC sees the true received power and can correctly step down gain when a strong signal arrives.

---

## Headroom constraint and ownership

The AGC is the sole owner of the per-branch signal level constraint. No other block in the pipeline adjusts signal amplitude for headroom purposes — the combiner, weight generation, and re-modulator all assume the AGC has done its job.

The end-to-end headroom chain is:

```
SX1257 gain (AGC-controlled)
    ↓
Decimator output — per-branch amplitude, int8
    ↓
MRC Combiner — coherently adds NR=4 branches: output amplitude ≤ √NR × per-branch = 2×;
               ÷2 right-shift applied in MRC output stage → int8 output ≈ per-branch amplitude
               (bypass path: int8 direct, no ÷2)
    ↓
ΣΔ Re-modulator — requires input < −3 dBFS for stability
```

The shift-MRC weight generator already adds branch-count headroom, and the combiner applies a fixed ÷2 guard shift before optional `COMB_POST_GAIN`. A separate remod-input backoff (`REMOD_BACKOFF_SHIFT`, register `0x37`, reset default `1`) is then applied on the MRC path only. Firmware may raise `COMB_POST_GAIN` only after observing enough output headroom. The AGC target still must keep **per-branch signal amplitude below −3 dBFS** (≤ 90 counts for int8 full scale = 127, i.e. 0.707 × 127), but remod safety no longer depends on AGC alone.

This single constraint, if met by the AGC, simultaneously satisfies:
- Combiner MRC output has guard headroom under the default shift-MRC + fixed ÷2 scaling
- Bypass output fits in int8 directly (per-branch amplitude ≤ 90)
- Re-modulator input below −3 dBFS stability limit unless firmware deliberately raises post-combine gain

**AGC_TARGET_HI must be calibrated on silicon to correspond to −3 dBFS per branch.** The current planning value (0x6000) is a placeholder and must be verified against actual decimator output levels and energy metric scaling.

### Interaction with COMB_POST_GAIN

AGC and `COMB_POST_GAIN` should not fight each other. AGC owns the per-branch analog/digital input level; `COMB_POST_GAIN` only recovers digital amplitude after conservative shift-MRC combining.

Recommended policy:

- If any branch or combined output saturates, reduce analog gain first and force `COMB_POST_GAIN=0`.
- If per-branch AGC is stable and the combined output peak is below target, increase `COMB_POST_GAIN` packet-to-packet using the combiner policy.
- Do not use `COMB_POST_GAIN` to compensate a weak RF gain setting if the per-branch samples are under-ranged before training; fix AGC first.


---

## Control policy

Use BB gain for fine tracking and LNA gain for coarse correction.

Policy:

- start at maximum gain for first-packet sensitivity
- if energy is slightly high or low, step BB gain by 2 dB
- if BB hits a limit, step LNA gain and restore BB near mid-scale
- if saturation is detected, step LNA down immediately

Current thresholds:

```c
#define AGC_TARGET_LO  0x0800   // too cold — TBD, calibrate on silicon
#define AGC_TARGET_HI  0x6000   // too hot  — TBD, must correspond to −3 dBFS per branch
#define AGC_SAT_GUARD  0xE000   // near saturation
```

Current initial state:

```c
#define LNA_G1  1
#define LNA_G6  6
#define BB_MAX  15
#define BB_MIN  0
#define BB_MID  7
```

Initial gain on all four antennas:

```c
lna_gain[n] = LNA_G1
bb_gain[n]  = BB_MAX
```

Rationale:

- weak first packets should not be missed because startup gain was conservative
- strong first packets may saturate, but that packet can be discarded and the next one will be cleaner

---

## Firmware behavior

Current AGC update shape:

```c
if (TX_ACTIVE) return;

for each antenna n:
    e = read_energy(n)

    if e > AGC_SAT_GUARD:
        step LNA down immediately, restore BB to mid if possible
    else if e > AGC_TARGET_HI:
        reduce BB, or step LNA down if BB already at minimum
    else if e < AGC_TARGET_LO:
        increase BB, or step LNA up if BB already at maximum
    else:
        leave gain unchanged

    if gain changed:
        write RX_GAIN_SHADOW_n
        pulse RX_GAIN_COMMIT   // requests atomic apply of the full gain bank at next safe_switch
        set ema_reset_pending
```

Expected behavior:

- fine tracking converges in 1-2 packets once near the target window
- large overdrive may take multiple packets if an LNA boundary is crossed
- static-channel convergence target in planning is within 3 packets

---

## Interaction with channel estimation and W

Gain changes do not apply inside the current packet.

That matters for consistency:

- `Z_j` (non-FFT path) or `H/N0` (FFT path) are estimated from one packet under one gain setting
- W is computed from those packet-consistent values
- the next packet may use a different gain, and therefore a new `Z_j`

Because `Z_j` scales with gain, gain changes invalidate cross-packet smoothing of channel estimates.

Current rule:

- if any antenna gain changed, set `ema_reset_pending = true`
- on the following packet, skip any cross-packet accumulation and seed from the new estimate directly

This prevents averaging channel estimates measured under incompatible gain states.

---

## Known limitations

### Shadow/active ownership

Ownership is a hard architectural rule, not a convention:

- `CPU_RESET=1`: `RX_GAIN_OWNER=0`, so host/manual logic owns `RX_GAIN_SHADOW_n` and `RX_GAIN_COMMIT`
- `CPU_RESET=0`: `RX_GAIN_OWNER=1`, so PicoRV32 AGC owns `RX_GAIN_SHADOW_n` and `RX_GAIN_COMMIT`

`RX_GAIN_OWNER` is therefore a direct reflection of whether the CPU is held in reset. There is no mixed-writer mode in the current architecture.

If host override is needed while PicoRV32 would otherwise be active, the host must first assert `CPU_RESET=1`, then rewrite `RX_GAIN_SHADOW_n`, and then pulse `RX_GAIN_COMMIT`.

### Apply completion semantics

`RX_GAIN_COMMIT` does not write the SX1257 immediately. It only queues a bank update.

Completion rules:

1. shadow values are sampled as one bank when `RX_GAIN_COMMIT` is pulsed
2. the bank is applied only during `Packet Control FSM IDLE`
3. all four branch writes must complete before `RX_GAIN_ACTIVE_n` is updated
4. on success: `RX_GAIN_PENDING` clears and the new bank becomes live for the next packet
5. on failure: `RX_GAIN_PENDING` remains set, `RX_GAIN_ERROR` asserts, and the previous active bank stays live

### No between-packet probing

AGC only updates on actual packet locks. During silence, gain does not adapt.

This is a deliberate tradeoff:

- pro: keeps maximum idle sensitivity
- con: the first packet after a large path-loss change may saturate or be under-ranged

### Saturation-first policy

The current policy accepts that a very strong first packet may not produce a valid `H`.

Mitigation:

- discard corrupted `H`
- keep previous W if available
- otherwise wait for the next clean packet

### Per-packet control only

There is no mid-packet recovery path. If a packet starts with bad gain, that packet is not fixed in flight.

---

## Open calibration items

- calibrate `AGC_TARGET_LO`, `AGC_TARGET_HI`, and `AGC_SAT_GUARD` on silicon
- verify the energy metric tracks useful headroom across all supported decimation settings
- confirm one clipped branch does not poison the full packet estimate path
- define branch-masking policy if one antenna is persistently saturated, dead, or noisy
- check AGC behavior under strong blockers and near-far conditions

---

## Verification targets

Current planning targets already call for:

- AGC convergence within 3 packets on a static channel
- AGC settling under a 20 dB path-loss change

Useful additional checks:

- one-branch saturation while other branches remain usable
- per-antenna gain mismatch after convergence
- effect of gain change on EMA reset behavior
- false-lock plus AGC mis-adjustment interaction

---

## Related docs

- [PicoRV32 Integration](./PicoRV32%20Integration.md)
- [Register Map](../Register%20Map.md)
- [Energy Measurement](./Energy%20Detector.md)
- [SPI Master](./SPI%20Master.md)
- [Test Plan](../Test%20Plan.md)
