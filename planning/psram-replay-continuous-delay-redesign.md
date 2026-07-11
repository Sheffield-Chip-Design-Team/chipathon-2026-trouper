# Same-Packet PSRAM Replay: Continuous-Delay Redesign Proposal

**Status:** PROPOSED — not implemented. Written 2026-07-11; revised same day
(margin anchor moved from `buf_base` to `training_done`, mux keyed on
`replay_active`, timeout benefit added — see §2/§3/§4a).
**Motivated by:** `TRPR-RMD-009` (Trouper Chip Specification §4.9 — no
time-index jump in the re-modulator's input during normal operation).
**Touches:** `psram_buf_ctrl.v`, `trouper_top.v`, `reg_bank.v`, Register Map,
Open Risks #5 / #7 / #14.

---

## 1. Problem

The current same-packet replay design (`psram_buf_ctrl.v` `S_REPLAY`,
gated by `trouper_top.v`'s `psram_silence`) has two issues, one a bug and
one architectural:

- **Bug (Open Risks #5):** `psram_silence` forces `remod_in_*=0` but also
  `in_valid=0`, so `sd_remod` holds its last latched sample instead of
  actually modulating zero — a DC tone, not silence.
- **Architectural (why fixing the bug alone isn't enough):** at `W_COMMIT`,
  the combiner's input mux switches from live `dcr_i/dcr_q` to PSRAM-replayed
  `rpl_i/rpl_q` anchored at `buf_base` — a point at or near the packet's
  start. That's a genuine backward jump in signal time-index, which
  `TRPR-RMD-009` now prohibits regardless of whether the preceding silence
  is real. The wait for `W_COMMIT` is also unbounded (up to `packet_end`),
  so today's silence window can span nearly the whole packet.

## 2. Proposed mechanism

Replace "wait indefinitely for `W_COMMIT`, then rewind to `buf_base`" with
"wait for a bounded margin **after `training_done`**, then start a
continuously-trailing delay line from `buf_base` that never rewinds again."

**Why the margin is anchored at `training_done`, not `buf_base`:** the chain
from packet start to `W_COMMIT` is (a) the training window —
`tacc_window·M` samples, anchored at `timing_ref` (`training_acc.v`
`acc_start/acc_end`), deterministic but strongly SF-dependent (~3.6 k
samples at SF7 up to ~115 k at SF12) — then (b) host response: IRQ latency
+ SPI Z-bank readout + weight compute + W-shadow write + commit, which is
SF-independent but jittery (RPi scheduling, SPI clock). A margin measured
from `buf_base` would have to cover both, making the register SF-dependent
and dominated by (a); worse, a compute-sized value (~1000 samples) would
expire before `training_done` on every packet at every SF. Anchoring at
`training_done` means the register bounds only (b). (`sc_lock` detection
latency shifts neither anchor: `buf_base` is backdated via `timing_ref`,
and the training window is `timing_ref`-anchored too — a late lock only
shrinks `n_acc`, a separate Z-quality issue.)

1. **New register**, `REPLAY_DELAY_SAMPLES` (raw sample count, not
   symbols — it bounds only host response time, which is SF-independent).
   Firmware sizes it to its worst-case IRQ + readout + compute + commit
   latency (see Open Risks #7 for the compute portion: ~750–1000 samples
   for 8 iterations; add readout/IRQ overhead on top).
2. At `sc_lock`, `buf_base` is latched exactly as today.
3. At `training_done`, latch a wait reference (`wr_ptr` at that instant).
   Output stays silent until `wr_ptr` has advanced
   `REPLAY_DELAY_SAMPLES × 8` bytes past it. This wait is bounded by
   `tacc_window·M + REPLAY_DELAY_SAMPLES` from packet start (worst case),
   not by however long firmware happens to take.
4. Once the margin is met, `rd_ptr` starts at `buf_base` and advances in
   lockstep with `wr_ptr` (the same interleaved one-write-one-read-per-cycle
   mechanism `S_REPLAY` already uses) — a fixed-depth delay line
   (depth = `tacc_window·M + margin`, per-packet deterministic) for the
   rest of the packet. **No further state transitions, no rewind.**
5. Weights: bypass mode until `W_COMMIT` (unchanged), then a smooth
   coefficient change applied to the already-continuously-flowing stream —
   compliant with `TRPR-RMD-009` (silence→signal and mid-stream weight
   changes are both explicitly permitted; re-presenting already-sent
   time-index is not, and this design never does that).

**Honest cost this exposes:** the silence window is inherently
≥ training + host response (~`tacc_window` symbols + margin) — the packet
cannot be MRC-weighted from its start with weights that don't exist yet.
The original draft's ~1000-sample figure quietly hid this.

## 3. QPI budget: no new parallel read needed

The SC delay-read (`del_addr`, feeding `sc_detector`) is only useful
pre-lock (searching for a new packet). This new replay delay-read is only
useful post-lock (a packet is active). They're mutually exclusive in time —
mux the read-address source and reuse the same sub-cycle slot, rather than
running two parallel PSRAM reads. Stays within the existing 44-of-64
sub-cycle write+read budget (see Open Risks #30); does not require
increasing PSRAM throughput.

**Mux key: `replay_active` (or `state == S_REPLAY`), not raw `sc_lock`.**
No extra interlock is needed against `sc_lock` dropping while replay still
holds the slot, because it can't in the current wiring: `sc_lock` is sticky
from detection until `sc_clr` (`sc_detector.v`), and `sc_clr` is
`packet_done_pulse` (`trouper_top.v`) — the same pulse fed to
`psram_buf_ctrl` as `packet_end`, so lock-clear and `S_REPLAY`-exit fire on
the same edge (± one cycle of registration skew). But a raw-`sc_lock` mux
would silently inherit that timing if `sc_clr` is ever rewired (e.g. to a
firmware-controlled clear). Keying on the buffer controller's own state
makes the mux self-consistent with its FSM and cleanly defines the
margin-wait window (lock high, replay not yet started): read slot idle —
SC doesn't need delayed samples post-lock, replay hasn't begun.

## 4. New status: partial-miss visibility

Today, a late `W_COMMIT` either makes it before `packet_end` (fine) or
doesn't (`W_MISSED_PACKET`, total loss — the whole packet stays bypass).
With a constant-gap delay line, a `REPLAY_DELAY_SAMPLES` that's too small
for a given packet degrades **silently**: `rd_ptr` advances past
`buf_base` before weights are ready, and whatever commits late only applies
from wherever `rd_ptr` currently is — some prefix of the packet stays
bypass-weighted instead of MRC-weighted, with no indication anything
happened.

**Proposed fix:** add `WGT_CTRL` (`0x1E`) bit `[4]` = `W_COMMIT_LATE`
(RO, sticky) — set when `W_COMMIT` arrives after `rd_ptr` has already
advanced past `buf_base`. Distinct from bit `[3]` `W_MISSED_PACKET` (commit
never arrives at all before `packet_end`):

| Case | Signal |
|---|---|
| Commit lands before margin consumed | neither bit — full packet gets MRC |
| Commit lands late but before `packet_end` | `W_COMMIT_LATE` — partial degradation |
| Commit never lands before `packet_end` | `W_MISSED_PACKET` — as today |

These are mutually exclusive in practice: `W_COMMIT_LATE` fires at the
moment of a late commit; `W_MISSED_PACKET` fires at `packet_end` only if no
commit ever happened.

## 4a. Built-in weight-arrival timeout (graceful degradation)

The margin expiry doubles as a weight-arrival timeout — no extra hardware.
Today the design is all-or-nothing: replay only starts at `W_COMMIT`
(`psram_buf_ctrl.v` `S_WRITE`), so a host that never commits (crashed
firmware, SPI contention) leaves the output in the silence/DC-hold state
for the **entire packet** — total loss, flagged `W_MISSED_PACKET` only
after the fact. In this redesign the delay line starts unconditionally at
`training_done + REPLAY_DELAY_SAMPLES`, with the combiner in its existing
`!W_valid` bypass fallback (single antenna via `bypass_ant`):

- Weights on time → full packet MRC-weighted, no flags.
- Weights late → packet flows in bypass, upgrades to MRC mid-stream at
  commit, `W_COMMIT_LATE` set — ~6 dB diversity loss on the prefix instead
  of losing the packet.
- Weights never → whole packet demodulated in bypass, `W_MISSED_PACKET` at
  `packet_end` — degraded reception instead of silence.

The failure ladder goes from {perfect, total loss} to {perfect, partial
degradation, bypass-only}, each rung firmware-visible. Note the semantics:
a "stop waiting" timeout, not an abort — nothing is cancelled, the stream
starts without weights and accepts them whenever they show up (exactly what
`TRPR-RMD-009`'s mid-stream-weight-change clause permits).

## 5. RTL change summary (`psram_buf_ctrl.v`)

- Remove the `W_commit`-gated trigger: `if (W_commit && buf_base_valid &&
  psram_en) begin rd_ptr <= buf_base; ... state <= S_REPLAY; end`.
- Add a margin-gated trigger instead: at `training_done` (new input from
  `training_acc`), latch a wait reference `wait_base <= wr_ptr`; once
  `(wr_ptr − wait_base) >= replay_delay_bytes` (a registered comparison,
  `replay_delay_bytes` derived from the new register), latch
  `rd_ptr <= buf_base` and enter `S_REPLAY` — independent of `W_commit`.
- `W_commit` no longer starts replay; it only gates `W_valid` in the
  combiner (already decoupled — `mrc_combiner` already auto-falls-back to
  bypass when `!W_valid`, no change needed there).
- Add `W_COMMIT_LATE` detection: sticky bit set when `W_commit` pulses
  while replay is already running. Use a `replay_started` flag (set on the
  `S_REPLAY` entry, cleared at `packet_end`) rather than a
  `rd_ptr != buf_base` comparison — the pointer compare is true from the
  second replay cycle onward anyway, and would read a stale `rd_ptr` from
  the previous packet if a commit lands during the margin wait.
- Read-address mux: keyed on `replay_active`/`state == S_REPLAY`, not raw
  `sc_lock` (§3). `del_addr` (SC path) used outside replay; the same read
  sub-cycle slot computes the replay address inside it.

## 6. Edge cases to resolve before implementation

- **`packet_end` before the margin is met — or before `training_done`
  fires at all** (very short packet, or lock happens near the packet's own
  end): replay never starts; packet stays silent throughout. Needs to be a
  clean, non-error fallback, not a stuck state; `wait_base` state must be
  invalidated at `packet_end` like `buf_base_valid` is today.
- **`REPLAY_DELAY_SAMPLES = 0`:** valid but degrades to "start immediately
  at `training_done`" — output begins before firmware can possibly have
  committed, so the training window's worth of packet is always
  bypass-weighted. Firmware's choice; not a hardware error case.
- **`QSPI_OWNER` handover during the margin wait or during replay:** the
  existing owner-suspend logic (`TRPR-PSR-010/011`, Open Risks #37, closed)
  should already cover this via `qspi_owner_eff` — needs confirmation, not
  expected to need new logic.
- **Overflow** (`rd_ptr == wr_ptr`): existing sticky detection applies
  unchanged.
- **SF/BW/`sc_ant_sel` change mid-packet:** already blocked via the
  `!packet_active` write-gate pattern (Open Risks #31/#32 precedent); the
  new `REPLAY_DELAY_SAMPLES` register should follow the same gating.

## 7. Side effect: likely resolves Open Risks #14 too

Open Risks #14 ("PSRAM replay is truncated at packet timeout") is caused by
`rd_ptr` trailing `wr_ptr` by an unpredictable amount — "the training+commit
latency" — which today can be nearly the whole packet if `W_COMMIT` is
late. In this redesign, the trailing gap is bounded and per-packet
deterministic: `tacc_window·M + REPLAY_DELAY_SAMPLES` (≈ the training
window plus the host-response margin), instead of unbounded-until-commit.
Still SF-dependent via the `tacc_window·M` term, but now a known quantity
firmware can budget `PKT_TIMEOUT_SYMS` against, so the tail-truncation
risk shrinks substantially. Worth re-evaluating #14 once this lands, not
closing pre-emptively.

## 8. Register Map additions (proposed)

| Address | Name | R/W | Notes |
|---|---|---|---|
| `0x77` | `REPLAY_DELAY_LO` | R/W | Bits `[7:0]` of `REPLAY_DELAY_SAMPLES`; write-gated `!packet_active`, same pattern as `SF_CFG`/`BW_CFG` |
| `0x78` | `REPLAY_DELAY_HI` | R/W | Bits `[15:8]` |

Both from the existing `0x77`–`0x7E` "reserved for future growth" range —
no reshuffling of the map needed. `WGT_CTRL` (`0x1E`) bit `[4]` (currently
reserved) becomes `W_COMMIT_LATE` (§4).

## 9. Verification sketch

A cocotb test in the style of `cocotb/sc_ant_sel/test_sc_ant_sel.py`:
monotonic time-index check on the remod input (no rewind, ever, past the
one silence→signal transition per packet), replay-start instant bit-exact
at `training_done` + the configured register value, timeout behaviour
(§4a) under early/late/never commit timing with the matching
`W_COMMIT_LATE`/`W_MISSED_PACKET` flags, the `packet_end`-before-margin
(and before-`training_done`) graceful-fallback case, and a two-packet run
confirming the `replay_active`-keyed read mux hands the slot back to the
SC delay-read for the second packet's search.

## 10. Next steps

Not yet implemented. Before starting: `Open Risks #7`'s cycle-accurate
verification should land first, since it directly informs the default
`REPLAY_DELAY_SAMPLES` value firmware would actually use. Implementation
order: register map + `reg_bank.v` field, `psram_buf_ctrl.v` state-machine
change, `trouper_top.v` mux/`psram_silence` removal, new cocotb regression,
then update `TRPR-RMD-009`'s "not yet met" note and Open Risks #5/#14.
