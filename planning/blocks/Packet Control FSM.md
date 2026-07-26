# Packet Control FSM

RX path control block (non-FFT frontend). See [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) and [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Rewritten for non-FFT path

---

## Role

Owns packet phase and no-glitch switching between bypass and combined output. Converts SC timing events and weight-readiness signals into deterministic control for the frontend buffer, weight generation, combiner, and optional PSRAM replay path.

Compared to the FFT-path FSM, this version is significantly simplified:

- No FFT trigger, no capture protection, no SRAM window management
- No `h_ready` input — replaced by `training_done` from the training accumulator
- Critical path is: `sc_lock → training_done → W_commit → safe_switch`

The FSM must never backpressure `iq_valid`. If weight computation misses the current packet, the live stream stays in bypass — this is expected next-packet behaviour, not an error.

If the optional PSRAM same-packet path is enabled, the FSM also decides whether the current packet should:

- stay on the baseline live/bypass flow
- start PSRAM buffering at `sc_lock`
- switch the SX1302-facing output from zeros to PSRAM replay once `W_commit` arrives
- drain buffered packet tail after `packet_end`

---

## State Machine

```
        sc_lock
IDLE ──────────────► PREAMBLE_ACQ
 ▲                        │
 │                  training_done
 │                        │
 │                        ▼
 │                    W_PENDING ──── timeout / W_commit ──► PAYLOAD_ACTIVE
 │                                                                │
 └────────────────────────────── packet_end / timeout ───────────┘
```

| State | Entry condition | Active behaviour | Exit condition |
|---|---|---|---|
| `IDLE` | Reset; packet end; timeout | `safe_switch=1`; promote `W_SHADOW→W_ACTIVE` if `W_commit_pending`; unfreeze FRONTEND_BUF; assert `noise_sample_en` each symbol period while `energy_j < NOISE_THRESH` and `!sc_lock` | `sc_lock` |
| `PREAMBLE_ACQ` | `sc_lock` | Latch `timing_ref`, `ACTIVE_MODE`, `ACTIVE_ANTENNA_EN`; freeze FRONTEND_BUF; combiner=bypass; raise `IRQ_CORR_LOCK` | `training_done` or preamble timeout |
| `W_PENDING` | `training_done` | Raise `IRQ_TRAINING_DONE`; firmware computes and writes `W_SHADOW`; combiner stays bypass | `W_commit` or payload-start timeout |
| `PAYLOAD_ACTIVE` | Payload phase begins | Combiner = `W_ACTIVE` if `W_valid`, else bypass; if `PSRAM_EN=1` and replay was armed on time, combiner input switches to PSRAM replay; else live path remains active; set `W_MISSED_PACKET` if W was not committed before this state | `packet_end` or timeout |

### Packet end detection

The ASIC has no explicit framing signal from SX1302. Packet end is detected by either:

1. **New `sc_lock`** — a new preamble detected implies the previous packet is done
2. **Configurable timeout** — `timing_ref + PKT_TIMEOUT_SYMS * M` where `PKT_TIMEOUT_SYMS` is a register-configurable maximum packet length in symbols (default covers the maximum LoRa payload at the configured SF/BW/CR)

Whichever fires first terminates the current packet and returns the FSM to IDLE.

---

## Timing Events

### Preamble timeout

Training should complete within the 8-symbol preamble window:

```
preamble_timeout = timing_ref + 8M + PREAMBLE_GUARD
```

`PREAMBLE_GUARD` is a small configurable margin (default 2M) to account for timing_ref accuracy. If `training_done` has not asserted by this point, the FSM transitions to PAYLOAD_ACTIVE without valid weights, and `W_MISSED_PACKET` is set.

### Payload start estimate

The FSM enters PAYLOAD_ACTIVE no later than:

```
payload_start_estimate = timing_ref + 12M   (approximate sync + SFD length at SF6)
```

If `W_commit` fires before this point and the receiver is between packets, `W_valid_set` promotes the weights. Otherwise the commit is queued for the next safe_switch.

### Safe switch

`safe_switch=1` only while in IDLE (between packets). This is the only window where:

- `W_ACTIVE` is updated from `W_SHADOW`
- `ACTIVE_MODE` and `ACTIVE_ANTENNA_EN` are updated from their shadow registers
- queued `RX_GAIN_COMMIT` requests may be applied to the SX1257s
- FRONTEND_BUF is unfrozen

Mid-packet changes to mode or antenna mask are accepted into shadow registers but do not take effect until the next IDLE entry.

---

## W_commit handling

`W_commit` may arrive in any state. The FSM sets `W_commit_pending` as a sticky flag:

```
W_commit asserted → W_commit_pending = 1
In IDLE           → W_valid_set = 1, W_ACTIVE ← W_SHADOW, W_commit_pending = 0
```

| W_commit timing | Result |
|---|---|
| Arrives in W_PENDING or PAYLOAD_ACTIVE | Queued; activates at next IDLE entry |
| Arrives in IDLE | Immediately promotes W_SHADOW → W_ACTIVE |
| Never arrives before packet end | W_MISSED_PACKET set; combiner stays bypass for that packet |

---

## Buffer control

> **Superseded 2026-07-26.** This section described a `buf_freeze` output driving the
> on-chip `frontend_buf_ctrl` / 1 kB SRAM. That block and its SRAM were removed
> (TRPR-PHY-006), and `buf_freeze` — which was bit-identical to `packet_active` — has
> been deleted from the RTL along with the formal-harness port and assertion.

| FSM event | PSRAM Buffer Controller action |
|---|---|
| sc_lock (IDLE → PREAMBLE_ACQ) | `packet_active` asserts; the PSRAM controller latches the packet-start pointer and ceases SC delay reads, keyed off `sc_lock` directly (TRPR-FBC-002, TRPR-PSR-002/016) |
| packet_end (any → IDLE) | `packet_active` de-asserts; circular capture resumes |

The FSM does not gate the buffer itself — `psram_buf_ctrl` sequences capture and replay
from `sc_lock`, `packet_active`, `packet_end` and `W_commit`. The live sample path to the
training accumulator and combiner is unaffected either way; those receive samples
directly from `dc_removal`, except during replay, when a `replay_active` mux substitutes
the PSRAM read data at the combiner input.

---

## Combiner source policy

| Condition | `combiner_source` |
|---|---|
| `W_valid = 0` (no committed weights yet) | Bypass (lowest enabled antenna) |
| In PREAMBLE_ACQ or W_PENDING | Bypass |
| In PAYLOAD_ACTIVE, `W_valid = 1` | W_ACTIVE |
| In PAYLOAD_ACTIVE, `W_valid = 0` | Bypass |
| `W_MISSED_PACKET = 1` for current packet | Bypass (this packet only) |

`W_valid` is set once after the first successful W_commit and cleared only if the host explicitly resets it or changes mode. It persists across packets so that an older (but still valid) W is used rather than falling back to bypass every time weight computation is slightly late.

### Optional PSRAM same-packet replay

When `PSRAM_EN=1`, the FSM commands the [PSRAM Buffer Controller](PSRAM%20Buffer%20Controller.md) as follows:

| FSM event | PSRAM action |
|---|---|
| `IDLE -> PREAMBLE_ACQ` | Assert `psram_packet_arm`; begin buffering at `sc_lock` |
| `W_commit` during BUFFERING and before `packet_end` | Assert `psram_replay_start`; PSRAM controller switches SX1302 input from zeros to delayed replay |
| `W_commit` after `packet_end` | Replay for the current packet is impossible; queue W for the next packet |
| `packet_end` while replay active | Allow PSRAM controller `DRAIN` phase, then return to live path in `IDLE` |
| Timeout / abort | Assert `psram_abort`; fall back to baseline next-packet behaviour |

The replay path is optional and default-off. With `PSRAM_EN=0`, all outputs above remain inactive and the FSM behaviour is identical to the baseline next-packet design.

Unlike the baseline live path, PSRAM replay does **not** require `W_commit` before the live payload boundary. During BUFFERING the SX1302-facing output is forced to zero, so the current packet is not exposed downstream until replay begins. The practical PSRAM deadline is therefore `packet_end`, not `payload_start_estimate`.

---

## Interface

> **RTL status (2026-07-12):** the implemented `packet_ctrl_fsm.v` interface
> is a subset of this table. The PSRAM command outputs (`psram_packet_arm`,
> `psram_replay_start`, `psram_abort`, `payload_rd_base`) were superseded by
> the continuous-delay replay redesign — `psram_buf_ctrl` self-sequences
> from `training_done`/`W_commit`/`packet_end` directly — and, with
> `safe_switch`/`combiner_source` (top-level derives these from
> `W_valid`/`packet_active`) and the unused `iq_valid`/`psram_en`/
> `psram_replay_active` inputs, were **deleted from the RTL** (Open Risks
> #25). `psram_abort`'s mid-payload re-lock scenario was verified
> structurally unreachable (`sc_lock` is level-held until packet done).
> `noise_sample_en`/`noise_thresh` were removed with the noise-estimator
> migration. The clock is 32 MHz, not 16. Rows below are kept for design
> history; consult the RTL for the live port list.

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | 16 MHz system clock |
| `rst_n` | in | 1 | Active-low reset |
| `iq_valid` | in | 1 | Decimated sample strobe |
| `sample_count` | in | 32 | Free-running iq_valid sample counter |
| `sf` | in | 3 | Spreading factor; M = 2^SF |
| `sc_lock` | in | 1 | SC preamble detection event |
| `timing_ref` | in | 32 | Preamble-start sample index from SC |
| `training_done` | in | 1 | Training accumulator complete |
| `W_commit` | in | 1 | Firmware/host finished writing W_SHADOW |
| `mode_shadow` | in | 2 | Host/firmware requested combining mode |
| `antenna_en_shadow` | in | 4 | Host/firmware requested antenna mask |
| `psram_en` | in | 1 | Optional same-packet PSRAM replay enable |
| `psram_replay_active` | in | 1 | PSRAM controller is currently feeding replay samples to combiner |
| `pkt_timeout_syms` | in | 8 | Max packet length in symbols (register-configurable) |
| `safe_switch` | out | 1 | Receiver idle; W/mode/antenna active banks may update |
| `W_valid_set` | out | 1 | Strobe: commit W_SHADOW → W_ACTIVE |
| `W_missed_packet` | out | 1 | Sticky: baseline path missed payload deadline, or PSRAM path missed `packet_end`; cleared on next sc_lock |
| `combiner_source` | out | 1 | 0=bypass, 1=W_ACTIVE |
| `psram_packet_arm` | out | 1 | Start per-packet PSRAM buffering at `sc_lock` |
| `psram_replay_start` | out | 1 | Start PSRAM replay from `payload_rd_base` |
| `psram_abort` | out | 1 | Cancel replay for current packet and fall back to live path |
| `payload_rd_base` | out | 24 | Byte offset into the current PSRAM packet buffer for replay start |
| `packet_phase` | out | 3 | Encoded FSM state for status/debug |
| `packet_active` | out | 1 | Packet FSM not in IDLE |
| `active_mode` | out | 2 | Latched combining mode for current packet |
| `active_antenna_en` | out | 4 | Latched antenna mask for current packet |
| `noise_sample_en` | out | 1 | Pulses once per symbol in IDLE when `!sc_lock` and all `energy_j < NOISE_THRESH`; triggers `IRQ_NOISE_SAMPLE` |
| `noise_thresh` | in | 16 | Per-branch energy threshold below which idle energy is treated as noise floor; from `NOISE_THRESH` register |

---

## IRQ Sources

| IRQ | Trigger | Consumer |
|---|---|---|
| `IRQ_CORR_LOCK` | IDLE → PREAMBLE_ACQ | Debug / host visibility |
| `IRQ_TRAINING_DONE` | PREAMBLE_ACQ → W_PENDING | PicoRV32 (firmware weight path) or debug |
| `IRQ_W_MISSED_PACKET` | W_MISSED_PACKET set | Debug / threshold tuning |
| `IRQ_PACKET_DONE` | Any → IDLE | Debug / host visibility |

---

## Per-branch noise floor estimation

While in IDLE, the FSM asserts `noise_sample_en` once per symbol window when both conditions hold:

1. `sc_lock` has not fired (no preamble detected)
2. All per-branch `energy_j < NOISE_THRESH` (near-far guard)

`noise_sample_en` is consumed directly by the **Noise Floor Estimator** RTL block, which updates the per-branch EMA automatically. The FSM does not maintain any EMA state.

`NOISE_THRESH` is a register-configurable value; recommended starting point is `AGC_TARGET / 8` (−9 dB below AGC target).

The FSM hardware contribution is:
- Assert `noise_sample_en` at the symbol boundary when both conditions are met
- `NOISE_THRESH` register input (from `NFE_CTRL` / `NOISE_THRESH` registers)

See [Noise Floor Estimator](Noise%20Floor%20Estimator.md) for the EMA block spec.

---

## Comparison with FFT-path FSM

| Feature | FFT path | Non-FFT path |
|---|---|---|
| After sc_lock | Wait for live FFT window (`timing_ref + 8M - 1`), trigger FFT | Wait for `training_done` (asserts at approximately same point) |
| States | IDLE / PREAMBLE_DETECTED / FFT_WAIT / W_COMMIT_WINDOW / PAYLOAD_ACTIVE / PACKET_DONE | IDLE / PREAMBLE_ACQ / W_PENDING / PAYLOAD_ACTIVE |
| SRAM management | `live_fft_ready`, `capture_protect` for 288 KB capture window | none — no on-chip SRAM; off-chip PSRAM sequenced by `psram_buf_ctrl` |
| W computation trigger | `h_ready` from FFT engine | `training_done` from training accumulator |
| W computation path | PicoRV32 reads H/N0 from SRAM | PicoRV32 or hardware reads Z_j from registers |
| Combiner fallback | Bypass until W_valid | Bypass until W_valid (identical policy) |
| safe_switch policy | Identical | Identical |

---

## Verification

| Test | Method | Pass criterion |
|---|---|---|
| Normal lock and train | Inject sc_lock → training_done → W_commit in sequence | FSM traverses all states; W_valid_set asserts in IDLE; combiner uses W_ACTIVE on next packet |
| W on time | W_commit before payload start | W_MISSED_PACKET=0; W_ACTIVE valid for current packet in baseline live mode |
| W late (next-packet) | W_commit during PAYLOAD_ACTIVE | W_MISSED_PACKET=1; combiner stays bypass this packet; W_ACTIVE updated at IDLE |
| PSRAM replay on time | `PSRAM_EN=1`, `W_commit` before `packet_end` | `psram_replay_start` asserts once; SX1302 output switches from zeros to replayed packet stream |
| PSRAM disabled | `PSRAM_EN=0` for full packet | `psram_packet_arm/replay_start` never assert; behaviour matches baseline next-packet path |
| PSRAM late replay | `PSRAM_EN=1`, `W_commit` after `packet_end` | Replay for that packet never starts; W queued for next packet |
| Training timeout | training_done never asserts | Preamble timeout fires; FSM enters PAYLOAD_ACTIVE in bypass; W_MISSED_PACKET=1 |
| Packet timeout | New sc_lock never arrives | PKT_TIMEOUT_SYMS expires; FSM returns to IDLE |
| Back-to-back packets | Two sc_locks in rapid succession | First sc_lock ends current packet (IDLE); second sc_lock immediately enters PREAMBLE_ACQ |
| Mode shadow write mid-packet | Write mode_shadow during PAYLOAD_ACTIVE | active_mode unchanged until IDLE; shadow value promoted at safe_switch |
| No backpressure | Packet arrives during W_PENDING | iq_valid path unaffected; combiner stays bypass |
| packet_active timing | Check packet-phase control | `packet_active` asserts at sc_lock, de-asserts at packet end (TRPR-PCF-002/008, `test_w_missed_packet.py`) |
| Noise sample, quiet channel | IDLE, inject noise-only signal below NOISE_THRESH, no sc_lock | `noise_sample_en` pulses once per symbol; `IRQ_NOISE_SAMPLE` fires |
| Noise sample suppressed, near-far | IDLE, inject signal above NOISE_THRESH, no sc_lock | `noise_sample_en` does not pulse; no IRQ |
| Noise sample suppressed, sc_lock | IDLE → PREAMBLE_ACQ mid-symbol | `noise_sample_en` suppressed from the symbol where sc_lock fires |

---

## Related Blocks

- [Correlator Bank (SC)](Correlator%20Bank.md) — provides `sc_lock`, `timing_ref`
- [Training Accumulator](Training%20Accumulator.md) — provides `training_done`
- [Weight Generation](Weight%20Generation.md) — archived hardware exploration; current `W_commit` source is firmware/host
- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) — **removed block**, retained for history only
- [PSRAM Buffer Controller](PSRAM%20Buffer%20Controller.md) — optional same-packet replay path
- [MRC Combiner](MRC%20Combiner.md) — receives `combiner_source`, `active_mode`, `active_antenna_en`
- [Register Map](../Register%20Map.md) — `PKT_TIMEOUT_SYMS`, `PACKET_PHASE`, `W_MISSED_PACKET`, IRQ registers
