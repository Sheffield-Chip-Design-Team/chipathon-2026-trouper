# AGC

Per-antenna automatic gain control for the four SX1257 receive chains.

**Rewritten 2026-07-28** to match the current architecture: Trouper has no on-chip CPU, no on-chip SPI master, and (as of this date) no on-chip gain-shadow/commit register file. Everything below describing an on-chip register interface, an `ENERGY_n` detector block, `CPU_RESET`, or a `safe_switch` apply window in a previous revision of this doc was speculative and has been removed — see "Superseded content" at the bottom for what changed.

---

## Ownership and where AGC runs

AGC is entirely a **firmware** function, running on Grouper's PicoRV32 (Trouper itself has no CPU). It:

- reads Trouper's training-accumulator registers over `GRP_*`/SPI to measure per-antenna preamble power
- programs each SX1257's `RegRxAnaGain` directly over Grouper's own SPI master (board-level, external to Trouper — TRPR-SPM-001)
- keeps all gain state (current LNA/BB setting per antenna, thresholds, hysteresis) in its own firmware memory

Trouper has **no on-chip gain register of any kind**. `RX_GAIN_SHADOW_0..3`/`RX_GAIN_ACTIVE_0..3`/`RX_GAIN_CTRL` existed at `0x10`–`0x18` in earlier revisions of the register map but were removed (2026-07-28): they only mirrored software-written values back to software, with no SX1257-facing hardware behind them, so they added silicon area and register-map surface without doing anything a firmware variable couldn't do. See `planning/Register Map.md` ("Removed registers") and `planning/Trouper Chip Specification.md` (TRPR-AGC-003, REMOVED).

If PicoRV32 is not operational, AGC is simply absent rather than blocking RX. The supported fallback is fixed gain: whatever the SX1257s were last programmed to (at power-on, or by a one-time bring-up script) stays in force. This means AGC is an optimisation and robustness feature, not a correctness dependency for baseline reception.

---

## Why AGC is not delegated to the SX1302

This design cannot rely on the SX1302's normal gain-control path for the receive antennas used by MRC.

Reasons:

- Combining happens before the SX1302 sees the signal, so gain decisions must be made per antenna on the raw branches.
- Trouper needs per-antenna preamble-power and saturation handling before channel estimation and combining.
- The gateway may run different gain settings on different antennas; this is invisible to the downstream SX1302.

The result is:

- SX1302 remains the downstream LoRa demodulator
- Grouper firmware owns RX gain policy for `SX1257_0..3`
- without a functioning firmware loop, gain remains fixed at whatever was last programmed

---

## Power measurement: reuses the training accumulator, no dedicated energy block

There is no separate per-antenna energy-detector block. AGC reuses `training_acc.v`'s normal per-packet output:

- After `sc_lock`, `training_acc` accumulates over the preamble for `TACC_WINDOW_SYMS` symbols (register `0x27`, default/minimum 8) and produces `Zdiag_k = Σ|raw_k|²` per antenna (real int32, top 24 bits readable at `0x64`–`0x6F`), alongside the cross-correlation `Z_kl` pairs used for weight computation.
- `IRQ_TRAINING_DONE` fires when the window completes; `N_ACC` (`0x21`–`0x23`, 18-bit) gives the exact sample count accumulated.
- Firmware computes per-antenna preamble power as `Zdiag_k / n_acc` and uses that as the AGC input for that packet (TRPR-AGC-001).

This is the same data training_acc already produces for weight computation — AGC does not require Trouper to run any additional measurement, and does not depend on a separate "energy at correlator lock" snapshot the way earlier plans assumed.

Consequences of this being training-window power rather than a running per-symbol energy detector:

- AGC only gets one power reading per successfully-locked packet (at `IRQ_TRAINING_DONE`), not a continuously updated value.
- If `sc_lock` never happens (e.g. because the branch is so far under-ranged that acquisition fails), that antenna produces no AGC data for that packet — its gain stays at the previous setting until a packet does lock.

---

## Trigger and timing

AGC runs once per successfully-trained packet, at `IRQ_TRAINING_DONE`.

Sequence:

1. `sc_lock` → training window accumulates for `TACC_WINDOW_SYMS` symbols
2. `IRQ_TRAINING_DONE` fires
3. Firmware reads `Zdiag_k` (`0x64`–`0x6F`) and `N_ACC` (`0x21`–`0x23`)
4. Firmware computes `Zdiag_k / n_acc` per antenna and decides whether to step gain
5. If a change is needed, firmware writes the new `RegRxAnaGain` byte directly to that SX1257 over its own SPI master

Important constraints:

- **No mid-packet gain changes.** There is no hardware gate enforcing this (unlike register writes to `SF_CFG`/`BW_CFG`, which Trouper's `reg_bank` blocks while `PACKET_ACTIVE`) — nothing in Trouper prevents firmware from reprogramming an SX1257 at an arbitrary time, because the SX1257s are not Trouper registers at all. Firmware **must** self-enforce this by checking `PACKET_STATUS.PACKET_ACTIVE` (`0x1C[0]`) before writing gain, the same way it would check any other packet-safety condition.
- AGC is independent of the noise-EMA path (`TACC_NOISE_TRIG`, separate from normal per-packet training).
- AGC is skipped during TX windows.
- Between packets, gain stays frozen at its last setting — there is no idle-window probing.

This is intentional: maximum idle gain preserves weak-packet sensitivity, and any gain change after a lock would invalidate the channel estimate that packet is producing.

---

## Controlled register (on the SX1257, not on Trouper)

Each SX1257 uses `RegRxAnaGain (0x0C)` on its own SPI interface. This register lives on the SX1257, not on Trouper — Trouper has no visibility into it beyond what firmware chooses to remember.

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

Firmware is the sole owner of both the desired and applied gain state (`lna_gain[4]`/`bb_gain[4]` in DMEM, per [PicoRV32 Integration](./PicoRV32%20Integration.md)). There is no shadow/active split, no commit pulse, and no pending/error status — the write to the SX1257 either completes over Grouper's SPI master or it doesn't, and firmware's own SPI-transaction error handling is the only failure path.

---

## Headroom constraint and ownership

AGC is the sole owner of the per-branch signal level constraint. No other block in the pipeline adjusts signal amplitude for headroom purposes — the combiner, weight computation, and re-modulator all assume AGC has done its job.

The end-to-end headroom chain is:

```
SX1257 gain (AGC-controlled, external)
    ↓
Decimator output — per-branch amplitude, int8
    ↓
MRC Combiner — coherently adds NR=4 branches: output amplitude ≤ √NR × per-branch = 2×;
               ÷2 right-shift applied in MRC output stage → int8 output ≈ per-branch amplitude
               (bypass path: int8 direct, no ÷2)
    ↓
ΣΔ Re-modulator — requires input < −3 dBFS for stability
```

The shift-MRC weight generator already adds branch-count headroom, and the combiner applies a fixed ÷2 guard shift before optional `COMB_POST_GAIN_SHIFT`. A separate remod-input backoff (`REMOD_BACKOFF_SHIFT`, `COMB_CFG` register `0x0F[5:4]`, reset default `1`) is then applied on the MRC path only. Firmware may raise `COMB_POST_GAIN_SHIFT` only after observing enough output headroom. The AGC target still must keep **per-branch signal amplitude below −3 dBFS** (≤ 90 counts for int8 full scale = 127, i.e. 0.707 × 127), but remod safety no longer depends on AGC alone.

This single constraint, if met by AGC, simultaneously satisfies:
- Combiner MRC output has guard headroom under the default shift-MRC + fixed ÷2 scaling
- Bypass output fits in int8 directly (per-branch amplitude ≤ 90)
- Re-modulator input below −3 dBFS stability limit unless firmware deliberately raises post-combine gain

**`AGC_TARGET_HI` must be calibrated on silicon to correspond to −3 dBFS per branch.** The current planning value (`0x6000`, on the `Zdiag_k/n_acc` scale) is a placeholder and must be verified against actual decimator output levels and the Zdiag scaling.

### Interaction with `COMB_POST_GAIN_SHIFT`

AGC and `COMB_POST_GAIN_SHIFT` should not fight each other. AGC owns the per-branch analog/digital input level; `COMB_POST_GAIN_SHIFT` only recovers digital amplitude after conservative shift-MRC combining.

Recommended policy:

- If any branch or combined output saturates, reduce analog gain first and force `COMB_POST_GAIN_SHIFT=0`.
- If per-branch AGC is stable and the combined output peak is below target, increase `COMB_POST_GAIN_SHIFT` packet-to-packet using the combiner policy.
- Do not use `COMB_POST_GAIN_SHIFT` to compensate a weak RF gain setting if the per-branch samples are under-ranged before training; fix AGC first.

---

## Control policy

Use BB gain for fine tracking and LNA gain for coarse correction.

Policy:

- start at maximum gain for first-packet sensitivity
- if `Zdiag_k/n_acc` is slightly high or low, step BB gain by 2 dB
- if BB hits a limit, step LNA gain and restore BB near mid-scale
- if the saturation guard is crossed, step LNA down immediately

Current thresholds (on the `Zdiag_k/n_acc` scale, firmware constants — no on-chip comparator registers exist, TRPR-AGC-002):

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

Current AGC update shape (see [PicoRV32 Integration](./PicoRV32%20Integration.md) for the fuller worked example):

```c
if (packet_status_active()) return;  // enforce "no mid-packet gain change" in firmware

for each antenna n:
    p = zdiag(n) / n_acc   // Zdiag_k/n_acc from the just-completed training window

    if p > AGC_SAT_GUARD:
        step LNA down immediately, restore BB to mid if possible
    else if p > AGC_TARGET_HI:
        reduce BB, or step LNA down if BB already at minimum
    else if p < AGC_TARGET_LO:
        increase BB, or step LNA up if BB already at maximum
    else:
        leave gain unchanged

    if gain changed:
        write RegRxAnaGain directly to SX1257_n over the board-level SPI master
        set ema_reset_pending
```

Expected behavior:

- fine tracking converges in 1–2 packets once near the target window
- large overdrive may take multiple packets if an LNA boundary is crossed
- static-channel convergence target in planning is within 3 packets

---

## Interaction with channel estimation and W

Gain changes do not apply inside the current packet — they can only take effect once firmware confirms `PACKET_ACTIVE=0`, and take effect starting with whichever packet locks next.

That matters for consistency:

- `Z_kl`/`Zdiag_k` are estimated from one packet under one gain setting
- W is computed from those packet-consistent values
- the next packet may use a different gain, and therefore a new `Zdiag`/`Z_kl` scale

Because `Zdiag`/`Z_kl` scale with gain, gain changes invalidate cross-packet smoothing of channel/noise estimates.

Current rule:

- if any antenna's gain changed, set `ema_reset_pending = true`
- on the following packet, skip any cross-packet EMA accumulation (both the weight-quality noise EMA, TRPR-AGC-005, and any channel-estimate smoothing) and seed from the new estimate directly

This prevents averaging estimates measured under incompatible gain states.

---

## Known limitations

### No between-packet probing

AGC only updates on `IRQ_TRAINING_DONE` — i.e. on an actual successful packet lock. During silence, gain does not adapt.

This is a deliberate tradeoff:

- pro: keeps maximum idle sensitivity
- con: the first packet after a large path-loss change may saturate or be under-ranged, and if a branch is so under-ranged it never triggers `sc_lock`, it gets no AGC data at all until conditions change enough for it to lock

### Saturation-first policy

The current policy accepts that a very strong first packet may not produce a valid channel estimate.

Mitigation:

- discard the corrupted `Z_kl`/`Zdiag` for that packet
- keep the previous W if available
- otherwise wait for the next clean packet

### Per-packet control only

There is no mid-packet recovery path. If a packet starts with bad gain, that packet is not fixed in flight.

### No hardware mid-packet gate

Unlike `SF_CFG`/`BW_CFG` (which `reg_bank` blocks from being written while `PACKET_ACTIVE`), there is no equivalent hardware protection for SX1257 gain — because the gain register doesn't live on Trouper. Firmware discipline is the only thing preventing a mid-packet gain change; a firmware bug here has no hardware backstop.

---

## Open calibration items

- calibrate `AGC_TARGET_LO`, `AGC_TARGET_HI`, and `AGC_SAT_GUARD` on silicon
- verify the `Zdiag/n_acc` metric tracks useful headroom across all supported decimation settings (both BW_CFG values)
- confirm one clipped branch does not poison the full packet's weight computation
- define branch-masking policy if one antenna is persistently saturated, dead, or noisy
- check AGC behavior under strong blockers and near-far conditions

This is tracked as an open risk: see `planning/Open Risks.md` #8 ("AGC calibration and edge-case behavior are unverified on silicon").

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

None of this is testable in RTL/cocotb — Trouper has no gain hardware to exercise. This is exclusively firmware/board-level verification (see TRPR-AGC-002/005 in `planning/Traceability.md`, tracked as untested firmware under Open Risks #8).

---

## Superseded content (removed 2026-07-28)

Earlier revisions of this document described an architecture that does not match the current chip and was never implemented in RTL:

- An on-chip register file (`RX_GAIN_SHADOW_0..3` at `0x20`–`0x23`, `RX_GAIN_ACTIVE_0..3` at `0x26`–`0x29`, `RX_GAIN_CTRL` at `0x2A`) — these addresses never matched the real register map even before the 2026-07-28 removal (the real, now-removed, addresses were `0x10`–`0x18`); the whole shadow/active/commit block is gone.
- A hardware "gain-control sequencer" driving SX1257 SPI writes from inside Trouper, gated on a Packet Control FSM `safe_switch` window — Trouper has no on-chip SPI master at all (see `planning/blocks/SPI Master.md`, "Legacy note"), and `safe_switch` does not exist in the current `packet_ctrl_fsm.v`.
- `RX_GAIN_PENDING`/`RX_GAIN_ERROR`/`RX_GAIN_OWNER` status bits and a `CPU_RESET`-gated ownership handoff — there is no on-chip CPU, so there is no `CPU_RESET`, and none of these bits ever existed in RTL.
- A dedicated `ENERGY[0..3]` per-antenna energy-detector block/register bank at `0x40`–`0x47`, latched at `IRQ_CORR_LOCK` — no such block exists; `0x40`–`0x47` is live `Z_kl` pair readback, and AGC's actual power measurement is the training accumulator's `Zdiag_k`, read at `IRQ_TRAINING_DONE` (see "Power measurement" above). `planning/blocks/Energy Measurement.md` describes this same never-built energy-detector plan and is itself unimplemented/stale — do not treat it as a current interface either.

---

## Related docs

- [PicoRV32 Integration](./PicoRV32%20Integration.md)
- [Register Map](../Register%20Map.md)
- [SPI Master](./SPI%20Master.md)
- [Trouper Chip Specification](../Trouper%20Chip%20Specification.md) — §4.15 TRPR-AGC
- [Traceability](../Traceability.md) — AGC section
- [Open Risks](../Open%20Risks.md) — #8
