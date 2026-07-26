# Packet Control FSM

RX path control block. See [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) and [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Reconciled against `src/control/packet_ctrl_fsm.v` on 2026-07-26

> **Reconciliation note (2026-07-26).** This document had drifted a long way from the
> RTL: it described a 4-state FSM (there are 5), a `W_ACTIVE` shadow bank (no such bank
> exists), `W_valid` persisting across packets (it is cleared at every packet end), a
> `W_commit` arriving mid-packet being deferred to IDLE (it is applied immediately), the
> FSM commanding the PSRAM controller through `psram_packet_arm`/`psram_replay_start`/
> `psram_abort`/`payload_rd_base` (all deleted; `psram_buf_ctrl` self-sequences),
> `safe_switch`/`combiner_source`/`buf_freeze` outputs (all deleted), a
> `noise_sample_en`/`NOISE_THRESH` noise-floor path (removed with the noise-estimator
> migration), a 16 MHz clock (it is 32 MHz), `M = 2^SF` (it is `2^(SF+sample_shift)`),
> and packet-end detection off a new `sc_lock` (structurally impossible). All of that is
> corrected below. Sections that documented deleted hardware are removed rather than
> annotated; the deletion history lives in `Open Risks.md` (#25) and
> `planning/spec-contradictions-audit-2026-07.md` (items 16, 29).

---

## Role

Owns packet phase, weight gating, and per-packet latching of the combining mode and
antenna mask. Converts SC timing events and weight-readiness signals into deterministic
control for the combiner, the PSRAM buffer controller's enable window, and the IRQ path.

Compared to the FFT-path FSM this version is significantly simplified:

- No FFT trigger, no capture protection, no on-chip SRAM window management
- No `h_ready` input — replaced by `training_done` from the training accumulator
- Control chain is: `sc_lock → training_done → W_commit → W_valid`

The FSM must never backpressure the sample path. If weight computation misses the current
packet, that packet stays in bypass — expected behaviour, not an error.

The FSM does **not** command the PSRAM replay path. `psram_buf_ctrl` self-sequences its
capture and replay phases from `sc_lock`, `packet_active`, `packet_end` and `W_commit`;
the FSM's contribution is `packet_active` (the enable window) and the `W_valid` gate.

---

## State Machine

Five states. `ST_ACQ_SETUP` is a single dedicated cycle between `sc_lock` and
`PREAMBLE_ACQ` that loads the three timeout down-counters from the already-registered
`lat_timing_ref`, rather than combinationally from the live `timing_ref` input — see
Open Risk #39 for why that arc had to be split.

```
                sc_lock rising          unconditional
       IDLE ──────────────────► ACQ_SETUP ──────────► PREAMBLE_ACQ
        ▲                                                  │
        │                              training_done ┌──────┴──────┐ acq_cnt == 0
        │                                            ▼             │
        │                                        W_PENDING         │
        │                                            │             │
        │                    W_commit | wpend_cnt==0 │             │
        │                                            ▼             │
        └────────── pkt_cnt == 0 ──────────  PAYLOAD_ACTIVE ◄──────┘
                    (clears W_valid)
```

The `acq_cnt` timeout path skips `W_PENDING` entirely and enters `PAYLOAD_ACTIVE`
directly with `W_missed_packet` set — training never completed, so there is nothing to
wait for a weight commit on.

| State | `packet_phase` | Entry condition | Active behaviour | Exit condition |
|---|---|---|---|---|
| `ST_IDLE` | 0 | Reset; packet timeout | `packet_active=0`; apply a pending `W_commit` (`W_valid`, `W_valid_set`) | `sc_lock` rising edge |
| `ST_ACQ_SETUP` | 1 | `sc_lock` rising edge | Load `acq_cnt`/`wpend_cnt`/`pkt_cnt` from `lat_timing_ref` | Unconditional, next cycle |
| `ST_PREAMBLE_ACQ` | 1 | `ST_ACQ_SETUP` | Await training; counters decrement per `iq_tick` | `training_done` → `W_PENDING`; `acq_cnt==0` → `PAYLOAD_ACTIVE` with `W_missed_packet` |
| `ST_W_PENDING` | 2 | `training_done` | Firmware computes and writes the W bank | `W_commit` → `PAYLOAD_ACTIVE` with `W_valid`; `wpend_cnt==0` → `PAYLOAD_ACTIVE`, `W_missed_packet` if `!W_valid` |
| `ST_PAYLOAD_ACTIVE` | 3 | `W_PENDING` or acq timeout | Apply a late `W_commit` immediately; no mid-payload re-lock handling | `pkt_cnt==0` → `IDLE`, clearing `W_valid` |

On the `sc_lock` rising edge the FSM latches `lat_timing_ref`, `active_mode` and
`active_antenna_en`, clears the sticky `W_missed_q`, and asserts `packet_active` /
`packet_active_ps`.

### Packet end detection

There is no framing signal from the SX1302. Packet end is detected by **one** mechanism:
the `pkt_cnt` down-counter reaching zero, loaded from `PKT_TIMEOUT_SYMS` (0x0B) × M.

A new `sc_lock` cannot end a packet: `sc_detector` holds `sc_lock` at level until
`sc_clr` (the falling edge of `packet_active`), so no second rising edge can occur while
the FSM is out of IDLE. Every packet acquisition necessarily passes through `ST_IDLE`.
A former mid-payload re-lock branch, with a `psram_abort` output to bail the PSRAM
controller out of a stale replay, was verified structurally unreachable and removed
2026-07-12. **If `sc_detector` ever gains a mid-packet re-arm path** — for example a
cascade `sc_lock_in` without the `!sc_lock` gate — re-lock handling and a replay abort
must be reintroduced here *and* in `psram_buf_ctrl`.

---

## Timing Events

All three deadlines are **down-counters**, decremented once per captured sample
(`iq_tick`) while the FSM is in `PREAMBLE_ACQ`, `W_PENDING` or `PAYLOAD_ACTIVE`. They are
loaded once, in `ST_ACQ_SETUP`, from quasi-static operands. This replaced three 32-bit
absolute deadlines and their continuous `sample_count >` comparators (area cut B6); the
counters are also wrap-immune, which the old compares were not — a 32-bit sample counter
wraps after ~2.4 h at 500 kS/s.

`M = 1 << (SF + sample_shift)`, so M ≤ 16384 (SF12 at 125 kHz). Spans, in samples
relative to `lat_timing_ref`, with `tacc_span = TACC_WINDOW_SYMS × M`:

| Counter | Span | Width | Purpose |
|---|---|---|---|
| `acq_cnt` | `tacc_span + 2M` | 20 | Training must complete inside the accumulation window plus 2 symbols of guard |
| `wpend_cnt` | `tacc_span + 5M` | 20 | Firmware weight-compute deadline: 3 further symbols beyond `acq_cnt` |
| `pkt_cnt` | `PKT_TIMEOUT_SYMS × M` | 23 | Maximum packet length before a forced return to IDLE |

`TACC_WINDOW_SYMS` is `0x27[3:0]`, default 8. There are two independent clamps: `reg_bank`
rejects writes below 8 (raising them to 8), and the FSM defensively floors a raw 0 to 1.
Counter loads are themselves floored at zero, so an already-expired deadline fires on
first evaluation in the consuming state — identical to the old already-expired compare.

A note on the load arithmetic: elapsed time is computed modulo 2^20 from the low bits of
`sample_count`, because the true elapsed value is structurally bounded by
`(SC_HITS_REQ+1)×M` plus pipeline lag (≈2^17). The full-width 32-bit subtract this
replaced *was* the post-P&R SS worst path at −20.5 ns.

### Mode and antenna latching

`active_mode` and `active_antenna_en` are latched from their shadow registers only on the
`sc_lock` rising edge out of IDLE — never mid-packet. Writes to `MIMO_CTRL` during a
packet land in the shadow registers and take effect at the next packet start. This is the
"safe-switch boundary" of TRPR-PCF-006; it is a *condition* (FSM in IDLE), not a signal.
The former `safe_switch` output was deleted from the RTL.

---

## W_commit handling

`W_commit` may arrive in any state. The FSM latches it as the sticky `W_commit_pending`
and applies it at the first opportunity — it is **not** deferred to IDLE:

| `W_commit` arrives in | Result |
|---|---|
| `IDLE` | `W_valid` set immediately, `W_valid_set` pulses |
| `W_PENDING` | `W_valid` set and the FSM advances to `PAYLOAD_ACTIVE` in the same cycle |
| `PAYLOAD_ACTIVE` | `W_valid` set immediately — the remainder of the packet is combined |
| Never, before `wpend_cnt` expires | `W_missed_packet` pulses (if `!W_valid`), `W_missed_q` latches; packet stays in bypass |

There is **no `W_ACTIVE` bank.** The combiner reads the live W register bank
(0x30–0x3F), which `reg_bank` write-locks while `W_VALID` is high; writes attempted
during the lock are rejected with sticky `W_WR_REJECTED` (0x1E[5]). See TRPR-PCF-004 /
TRPR-MRC-004.

**`W_valid` does not persist across packets.** It is cleared on the `pkt_cnt` timeout
path into IDLE, so every packet must earn its own `W_COMMIT`; there is no carry-over of
an older weight vector. (Earlier revisions of this document claimed the opposite.)

---

## Buffer control

The FSM does not gate the buffer. `psram_buf_ctrl` sequences capture and replay itself:

| FSM event | PSRAM Buffer Controller action |
|---|---|
| `sc_lock` (IDLE → ACQ_SETUP) | `packet_active` asserts; the controller latches the packet-start pointer and ceases SC delay reads, keyed off `sc_lock` directly (TRPR-FBC-002, TRPR-PSR-002/016) |
| `W_commit` before `packet_end` | Controller starts replay (`replay_active`) as a never-rewinding delay line |
| `pkt_cnt==0` (any → IDLE) | `packet_active` de-asserts; circular capture resumes |

The live sample path to the training accumulator and combiner comes directly from
`dc_removal`, except during replay, when a `replay_active` mux substitutes the PSRAM read
data at the combiner input (`trouper_top.v:534-537`).

The on-chip `frontend_buf_ctrl` / 1 kB rolling SRAM this section once described was
removed by TRPR-PHY-006, and the `buf_freeze` output that drove it — bit-identical to
`packet_active` — was deleted 2026-07-26.

---

## Combiner source policy

The FSM does not drive a `combiner_source` signal; the top level derives bypass-versus-
combine from `W_valid` and `active_antenna_en`.

| Condition | Combiner behaviour |
|---|---|
| `W_valid = 0` (no committed weights this packet) | Bypass — lowest enabled antenna per `active_antenna_en` |
| In `PREAMBLE_ACQ` or `W_PENDING` | Bypass (`W_valid` not yet set) |
| In `PAYLOAD_ACTIVE`, `W_valid = 1` | Combine using the live W bank |
| `W_missed_q = 1` for the current packet | Bypass for that packet |

---

## Interface

Live port list, `src/control/packet_ctrl_fsm.v`. Single 32 MHz clock domain.

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | 32 MHz system clock (`IQ_CLK`) |
| `rst_n` | in | 1 | Active-low reset |
| `sample_count` | in | 32 | Free-running captured-sample counter from `trouper_top` |
| `iq_tick` | in | 1 | 1-clock pulse per captured sample (`dcr_valid`) — the counter tick |
| `sf` | in | 4 | Spreading factor, 7–12 |
| `sample_shift` | in | 2 | Oversampling shift: 1 = 250 kHz, 2 = 125 kHz |
| `sc_lock` | in | 1 | SC preamble detection, level-held until packet done |
| `timing_ref` | in | 32 | Preamble-start sample index from SC |
| `training_done` | in | 1 | Training accumulator complete |
| `W_commit` | in | 1 | Firmware/host finished writing the W bank |
| `mode_shadow` | in | 2 | Requested combining mode |
| `antenna_en_shadow` | in | 4 | Requested antenna mask |
| `pkt_timeout_syms` | in | 8 | Max packet length in symbols (`PKT_TIMEOUT_SYMS`, 0x0B) |
| `tacc_window_syms` | in | 4 | Training window in symbols (`TACC_WINDOW_SYMS`, `0x27[3:0]`, default 8); `reg_bank` clamps writes below 8 up to 8, and the FSM floors a raw 0 to 1 |
| `W_valid_set` | out | 1 | 1-cycle strobe: `W_valid` just asserted |
| `W_missed_packet` | out | 1 | 1-cycle pulse: weight deadline missed. Consumed by the IRQ path |
| `W_missed_q` | out | 1 | Sticky mirror of the above for register readback (`PACKET_STATUS[7]` / `WGT_CTRL[3]`); held through IDLE, cleared at the next packet start |
| `packet_phase` | out | 3 | Encoded FSM phase for status/debug: 0 IDLE, 1 ACQ, 2 W_PENDING, 3 PAYLOAD |
| `packet_active` | out | 1 | FSM not in IDLE |
| `packet_active_ps` | out | 1 | Bit-identical duplicate of `packet_active` dedicated to `u_psram`'s wide enable cone, so the repair lottery on one net cannot starve the other's buffer tree. Carries `(* keep *)` to stop `opt_merge` folding it back (2026-07-19 fanout split) |
| `active_mode` | out | 2 | Combining mode latched for the current packet |
| `active_antenna_en` | out | 4 | Antenna mask latched for the current packet |

`W_valid` itself is internal — firmware observes it through `PACKET_STATUS`, and the
combiner is gated on it at the top level.

---

## IRQ Sources

The FSM does not drive IRQ lines directly. `trouper_top` edge-detects the level-held
sources and assembles `irq_set`; `reg_bank` sticky-ORs it into `IRQ_STATUS`, which drives
both `IRQ_OUT` and `IRQ_GROUPER`.

| Bit | IRQ | Trigger | Source |
|---|---|---|---|
| 0 | `CORR_LOCK` | `sc_lock` rising edge | `sc_detector` (edge-detected in `trouper_top`) |
| 1 | `TRAINING_DONE` | `training_done` rising edge | `training_acc` (edge-detected) |
| 2 | `W_MISSED_PACKET` | `W_missed_packet` pulse | **this FSM** |
| 3 | `PACKET_DONE` | `packet_active` falling edge | **this FSM**, via `packet_done_pulse` |
| 4 | `NOISE_READY` | `sigma2_valid` | `training_acc` noise mode |

Status pulses are stretched to two cycles before reaching `reg_bank`, because the
CE-gated register bank samples every other clock and would otherwise miss them.

---

## Comparison with FFT-path FSM

| Feature | FFT path | Non-FFT path |
|---|---|---|
| After sc_lock | Wait for live FFT window (`timing_ref + 8M − 1`), trigger FFT | Wait for `training_done` |
| States | IDLE / PREAMBLE_DETECTED / FFT_WAIT / W_COMMIT_WINDOW / PAYLOAD_ACTIVE / PACKET_DONE | IDLE / ACQ_SETUP / PREAMBLE_ACQ / W_PENDING / PAYLOAD_ACTIVE |
| SRAM management | `live_fft_ready`, `capture_protect` for 288 KB capture window | none — no on-chip SRAM; off-chip PSRAM self-sequenced by `psram_buf_ctrl` |
| W computation trigger | `h_ready` from FFT engine | `training_done` from training accumulator |
| W computation path | PicoRV32 reads H/N0 from SRAM | Grouper firmware / host reads Z over SPI or the `GRP_*` bus |
| Combiner fallback | Bypass until W_valid | Bypass until W_valid |
| Mode/antenna switching | Dedicated `safe_switch` output | Latched at the `sc_lock` edge out of IDLE; no `safe_switch` signal |

---

## Verification

| Test | Method | Pass criterion | Status |
|---|---|---|---|
| Normal lock and train | `sc_lock` → `training_done` → `W_commit` in sequence | FSM traverses all states; `W_valid_set` pulses; combiner uses the W bank for the packet | ✅ `test_weight_gen_spi_flow.py` (job 3286) |
| W on time | `W_commit` during `W_PENDING` | `W_missed_q=0`; combine for the current packet | ✅ |
| W never committed | `W_commit` withheld past `wpend_cnt` | `W_missed_packet` pulses, `W_missed_q` sticky through IDLE, payload stays bypass, `PACKET_DONE` fires | ✅ `test_w_missed_packet.py` (job 3310) |
| W late, mid-payload | `W_commit` during `PAYLOAD_ACTIVE` | `W_valid` asserts immediately; remainder of packet combines | ⚠️ Not directly covered — the miss test withholds `W_COMMIT` entirely |
| Training timeout | `training_done` never asserts | `acq_cnt` expires; FSM enters `PAYLOAD_ACTIVE` in bypass with `W_missed_packet` | ⚠️ Not directly covered |
| Packet timeout | Run past `PKT_TIMEOUT_SYMS` | `pkt_cnt` expires; FSM returns to IDLE, `W_valid` cleared | ✅ `test_w_missed_packet.py` |
| Back-to-back packets | Two preambles in succession | First packet ends on timeout (IDLE); `sc_detector` re-arms via `sc_clr`; second enters ACQ_SETUP | ✅ `test_capture_two_packet.py` (job 3273, real capture) |
| Mode shadow write mid-packet | Write `mode_shadow` during `PAYLOAD_ACTIVE` | `active_mode` unchanged until the next packet start | ✅ |
| No backpressure | Packet arrives during `W_PENDING` | Sample path unaffected; combiner stays bypass | ✅ |
| `packet_active` timing | Observe the FSM output | Asserts at `sc_lock`, held through `PAYLOAD_ACTIVE`, de-asserts at IDLE, re-asserts next packet (TRPR-PCF-002/008) | ✅ `test_w_missed_packet.py`, retargeted 2026-07-26 |
| B6 down-counter equivalence | Compare against the frozen absolute-deadline reference model | All outputs bit-identical every cycle, 40 randomised packets | ✅ `tb_pcfsm_b6_equiv.v` |
| Formal: phase/state invariants | k-induction on the `ifdef FORMAL` harness | `packet_active == (state != ST_IDLE)`, `packet_active_ps` mirrors it, `packet_phase` is a pure function of state, `W_missed_q` stickiness, counter-update discipline | ✅ `formal/packet_ctrl_fsm_formal.sv` (job 3487) |

---

## Related Blocks

- [Correlator Bank (SC)](Correlator%20Bank.md) — provides `sc_lock`, `timing_ref`
- [Training Accumulator](Training%20Accumulator.md) — provides `training_done`, and `sigma2_valid` in noise mode
- [Weight Generation](Weight%20Generation.md) — archived hardware exploration; the current `W_commit` source is firmware/host
- [PSRAM Buffer Controller](PSRAM%20Buffer%20Controller.md) — self-sequenced capture and same-packet replay; gated by `packet_active`
- [MRC Combiner](MRC%20Combiner.md) — receives `active_mode`, `active_antenna_en`, and the `W_valid` gate
- [Register Map](../Register%20Map.md) — `PKT_TIMEOUT_SYMS` (0x0B), `TACC_WINDOW_SYMS` (0x27), `PACKET_STATUS` (0x1C), `WGT_CTRL` (0x1E), IRQ registers
- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) — **removed block**, retained for design history only
