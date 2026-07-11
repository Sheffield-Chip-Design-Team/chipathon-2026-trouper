# Same-Packet PSRAM Replay: Continuous-Delay Redesign Proposal

**Status:** PROPOSED — not implemented. Written 2026-07-11.
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
"wait for a bounded margin, then start a continuously-trailing delay line
from `buf_base` that never rewinds again."

1. **New register**, `REPLAY_DELAY_SAMPLES` (raw sample count, not
   symbols — the thing being bounded is firmware compute time, which is
   SF-independent). Firmware sizes it to the worst-case weight-compute time
   it's actually using (see Open Risks #7 for current estimates: ~750–1000
   samples for 8 iterations).
2. At `sc_lock`, `buf_base` is latched exactly as today.
3. Output stays silent only until `(wr_ptr − buf_base) ≥
   REPLAY_DELAY_SAMPLES × 8` (byte units) — i.e., until enough backlog has
   accumulated between the packet's true start and live time to guarantee
   the configured margin. This wait is bounded by `REPLAY_DELAY_SAMPLES`
   (worst case), not by however long firmware happens to take.
4. Once the margin is met, `rd_ptr` starts at `buf_base` and advances in
   lockstep with `wr_ptr` (the same interleaved one-write-one-read-per-cycle
   mechanism `S_REPLAY` already uses) — a fixed-depth delay line for the
   rest of the packet. **No further state transitions, no rewind.**
5. Weights: bypass mode until `W_COMMIT` (unchanged), then a smooth
   coefficient change applied to the already-continuously-flowing stream —
   compliant with `TRPR-RMD-009` (silence→signal and mid-stream weight
   changes are both explicitly permitted; re-presenting already-sent
   time-index is not, and this design never does that).

## 3. QPI budget: no new parallel read needed

The SC delay-read (`del_addr`, feeding `sc_detector`) is only useful
pre-lock (searching for a new packet). This new replay delay-read is only
useful post-lock (a packet is active). They're mutually exclusive in time —
mux the read-address source by `sc_lock` and reuse the same sub-cycle slot,
rather than running two parallel PSRAM reads. Stays within the existing
44-of-64 sub-cycle write+read budget (see Open Risks #30); does not require
increasing PSRAM throughput.

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

## 5. RTL change summary (`psram_buf_ctrl.v`)

- Remove the `W_commit`-gated trigger: `if (W_commit && buf_base_valid &&
  psram_en) begin rd_ptr <= buf_base; ... state <= S_REPLAY; end`.
- Add a margin-gated trigger instead: once `(wr_ptr − buf_base) >=
  replay_delay_bytes` (a registered comparison, `replay_delay_bytes`
  derived from the new register), latch `rd_ptr <= buf_base` and enter
  `S_REPLAY` — independent of `W_commit`.
- `W_commit` no longer starts replay; it only gates `W_valid` in the
  combiner (already decoupled — `mrc_combiner` already auto-falls-back to
  bypass when `!W_valid`, no change needed there).
- Add `W_COMMIT_LATE` detection: when `W_commit` pulses, compare current
  `rd_ptr` against `buf_base` — if `rd_ptr != buf_base` (i.e., replay has
  already been running), set the sticky bit.
- Read-address mux: `del_addr` (SC path) only computed/used when `!sc_lock`;
  when `sc_lock`, the same read sub-cycle slot computes the replay address
  instead (§3).

## 6. Edge cases to resolve before implementation

- **`packet_end` before the margin is met** (very short packet, or lock
  happens near the packet's own end): replay never starts; packet stays
  silent throughout. Needs to be a clean, non-error fallback, not a stuck
  state.
- **`REPLAY_DELAY_SAMPLES = 0`:** valid but degrades to "start immediately
  at lock" — early preamble permanently bypass-weighted (same limitation as
  next-packet mode). Firmware's choice; not a hardware error case.
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
late. In this redesign, the trailing gap is bounded by the small, known
`REPLAY_DELAY_SAMPLES` margin instead, so the packet-tail-truncation risk
from `PKT_TIMEOUT_SYMS` being smaller than the replay lag shrinks
substantially. Worth re-evaluating #14 once this lands, not closing
pre-emptively.

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
one silence→signal transition per packet), margin-wait duration bit-exact
against the configured register value, `W_COMMIT_LATE`/`W_MISSED_PACKET`
semantics under early/late/never commit timing, and the `packet_end`-before-margin
graceful-fallback case.

## 10. Next steps

Not yet implemented. Before starting: `Open Risks #7`'s cycle-accurate
verification should land first, since it directly informs the default
`REPLAY_DELAY_SAMPLES` value firmware would actually use. Implementation
order: register map + `reg_bank.v` field, `psram_buf_ctrl.v` state-machine
change, `trouper_top.v` mux/`psram_silence` removal, new cocotb regression,
then update `TRPR-RMD-009`'s "not yet met" note and Open Risks #5/#14.
