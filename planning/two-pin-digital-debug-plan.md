# Two-Pin Digital Debug / Bring-Up Plan

**Status:** proposed for explicit pin-allocation decision; no RTL or package change yet.

## Objective

If two additional package pads are available, use them as `DBG0_OUT` and
`DBG1_OUT`: two **output-only**, register-selected logic-analyser probes.  They
provide first-silicon visibility of the RX, acquisition, packet, PSRAM, and
combiner paths without sharing a functional interface or changing behaviour of
the receiver.

This is intentionally not JTAG.  A two-pin TAP is not useful for state access,
would add a clock/control protocol and DFT verification, and would be a poorer
bring-up tool than probes that correlate directly with the already available
32 MHz `IQ_CLK` reference.

## Scope and allocation gate

**Updated 2026-08-30 — the allocation is confirmed at 28 pads, and these two
fit.** The 22-pad figure this section was written against was a working
assumption, now superseded (`planning/Pinout.md` allocation status, Open Risks
#46). Current occupancy is **26 of 28** — the 26 pins `info.yaml` declares, which
includes `ARRAY_ACQ_N`, `VDD_CORE` and `VSS`, all of which take a slot. Adding
`DBG0_OUT`/`DBG1_OUT` therefore reaches **28 of 28: exactly full, with no spare
left**.

That is a real decision, not a formality. These two pins would consume the
entire remaining margin, so any later pin need — a second supply, a strap, a
spare for a bring-up escape — would have to displace something already
allocated. Weigh that against first-silicon debug value before committing.

The pins are no longer gated on the *budget* in the sense that they fit. They
remain gated on
the integrator confirming the specific slots exist and are bondable — the same
open item `ARRAY_ACQ_N` carries in Open Risks #52 — and no P&R run has been
built against a pin list containing them.
They must not displace an RX IQ input, PSRAM lane, `IQ_CLK`, reset, or host SPI.
If they are allocated, add two output pads at board-accessible locations with
short probe traces and adjacent ground-test points.

`IRQ_OUT` remains a functional interrupt and must not be reused as either debug
pin.  It can be used as a logic-analyser trigger in parallel with these probes.

## Electrical and temporal contract

| Item | Requirement |
| --- | --- |
| Names/direction | `DBG0_OUT`, `DBG1_OUT`; output-only at the logical top level. |
| Reset / disabled state | Both pads drive `0` during reset and while `DBG_CTRL.EN=0`. |
| Timing reference | The external analyser uses the board's `IQ_CLK` net as its 32 MHz reference. No debug clock is created or driven by Trouper. |
| Functional isolation | Debug logic is a feed-forward fanout only: it has no input to the datapath, FSM, interrupts, PSRAM ownership, or register-write gating. A debug-pad fault cannot alter receiver behaviour. |
| Configuration | `DBG_CTRL` writes take effect only while `PACKET_ACTIVE=0`. An attempted mid-packet write is ignored and sets the existing `RX_HOLD.CFG_WR_REJECTED` sticky bit. The selected source stays constant for the complete packet. |
| Raw-RX implementation | Raw IQ is first captured into eight dedicated one-bit debug flops at `IQ_CLK`, then selected to the pads. It is therefore an exact sampled copy with one-cycle latency, never a combinational IQ-pad-to-debug-pad path. |
| Pad configuration | Use the ordinary `bi_t` output configuration, output-enable tied high, CMOS, **fast** slew, and mid drive (8 mA). The raw mode can toggle on every 32 MHz clock edge, unlike `SPI_MISO` / `IRQ_OUT`; slow slew is not assumed adequate. Board routing shall include a 0-ohm series-resistor footprint at each ASIC pin and use a high-impedance, low-capacitance probe. |

The probes are observability only, not a data transport.  For sample modes the
selected bit changes only when its producing sample register changes; the host
uses the known 500 kS/s cadence (every 64 `IQ_CLK` cycles) or an external
analyser trigger.  No claim is made that the pins form an 8-bit data port.

## Proposed register interface

Reclaim the former debug-register slots; this does not expand the fixed 7-bit
SPI map.

| Address | Name | R/W | Reset | Definition |
| --- | --- | --- | --- | --- |
| `0x04` | `DBG_CTRL` | R/W | `0x00` | `[7] EN`; `[6:4] GROUP`; `[3:2] ANT`; `[1:0] SEL`. Reserved encodings read back but drive both pads low. |
| `0x05` | `DBG_STATUS` | R | `0x00` | `[0] DBG0_PAD_VALUE`; `[1] DBG1_PAD_VALUE`; `[7:2] 0`. Readback is after the mux/enable gate and is a connectivity sanity check, not a sampled trace. |
| `0x06`–`0x07` | — | — | `0x00` | Remain reserved. |

`ANT` selects branch 0–3 for branch-qualified groups. `SEL` chooses a bit,
pair, or event within the selected group as specified below. The hardware must
not clamp invalid values; it drives zero for reserved encodings.

## Debug-mux encoding

| `GROUP` | `SEL` | `DBG0_OUT` | `DBG1_OUT` | Bring-up use |
| --- | --- | --- | --- | --- |
| `000` disabled | any | 0 | 0 | Establish pad baseline. |
| `001` raw RX | any | registered selected `IQ_DATA_I[ANT]` | registered selected `IQ_DATA_Q[ANT]` | `ANT=0…3` selects each complete I/Q pair in turn; confirms each SX1257 stream reaches the ASIC pins. All four pairs cannot be observed simultaneously with two pins. |
| `010` decimated IQ | `0`–`3` | selected `dc_i` bit | selected `dc_q` bit | Inspect corresponding bits of post-decimator/DC-removal I/Q. Bit mapping is `SEL=0→[7]`, `1→[6]`, `2→[1]`, `3→[0]`; start with the sign bit. |
| `011` SC | `0` | `sc_hit` | `sc_lock` | Tune and validate acquisition. |
|  | `1` | `del_rdy` | `sc_tdm_busy` | Distinguish delay-line warm-up from detector activity. |
|  | `2` | `sc_lock` | `packet_active` | Verify lock reaches packet control. |
| `100` packet / weights | `0` | `packet_active` | `training_done` | Packet lifecycle. |
|  | `1` | `w_pending` | `w_valid` | Weight-compute and commit timing. |
|  | `2` | `packet_phase[0]` | `packet_phase[1]` | State decoding; use SPI `PACKET_STATUS` for the third state bit. |
| `101` PSRAM | `0` | `psram_init_done` | `qpi_busy` | Power-up / QPI activity. |
|  | `1` | `buf_active` | `replay_active` | Capture-to-replay handoff. |
|  | `2` | `sample_skip` | `replay_missed` | Immediate fault visibility. |
|  | `3` | `dbg_busy` | `qspi_owner` | Service/debug ownership only. |
| `110` combiner | `0`–`3` | selected `comb_i` bit | selected `comb_q` bit | Inspect corresponding pre-re-modulator combined-I/Q bits. The same `[7]`, `[6]`, `[1]`, `[0]` bit mapping as decimated IQ applies. |
| `111` IRQ | `0`–`4` | `irq_status[SEL]` | `irq_out` | Correlate a particular sticky source with the pad interrupt. |

Names above describe logical source points.  The implementation shall take the
decimated group from the registered post-DC output and the combiner group from
the registered int8 input to `sd_remod`; it shall not tap combinational MAC
intermediates or PSRAM SIO pads.

## First-silicon sequence

1. With reset asserted and then with `DBG_CTRL.EN=0`, confirm both pins remain
   low. Read `DBG_STATUS` to verify the top-level-to-pad connection.
2. Enable raw-RX mode for `ANT=0`, then repeat for `ANT=1`, `2`, and `3`; use
   `IQ_CLK` as analyser reference and account for the documented one-cycle
   probe latency. Check active I/Q bitstream density and identical fixture tone
   presence. A simultaneous four-antenna capture requires probing the eight
   existing board-side SX1257 output nets, not these two ASIC pads.
3. Select decimated-IQ sign bits and then individual bits for a repeatable tone.
   Compare the observed update cadence with 64 `IQ_CLK` cycles and use SPI
   telemetry / PSRAM readback for numerical values.
4. Select SC mode (`sc_hit`, `sc_lock`), tune thresholds, then show
   `sc_lock` followed by `packet_active`.
5. Select packet/weight and PSRAM modes to establish the expected sequence:
   capture active -> training done -> W pending/valid -> replay active -> packet
   complete. Trigger on `sample_skip` or `replay_missed` if either ever asserts.
6. Select combiner sign bits while applying a common tone and compare MRC and
   passthrough settings. Use `IRQ` mode to correlate software-visible events.

## RTL, physical-design, and verification work

- Add `dbg_ctrl` storage/readback and the idle-only write gate to `reg_bank.v`
  (and its `rtl-test` mirror); export the decoded fields to `trouper_top.v`.
- Add a standalone combinational `debug_probe_mux` (or equivalent local mux) in
  `trouper_top.v`. Inputs must be existing registered observability signals;
  outputs must be driven only by the mux and `DBG_CTRL.EN` gate.
- Add the two top-level pad ports and all A40 output pad-control ports/tie-offs;
  update `planning/Pinout.md`, padframe integration collateral, and the P&R IO
  placement only after allocation approval.
- Update `planning/Register Map.md`, `planning/Trouper Chip Specification.md`,
  firmware register definitions, and traceability at implementation time.
- Cocotb: cover reset/disabled low, every valid group/SEL source, reserved zero,
  idle-only configuration and rejection sticky, fixed selection throughout a
  packet, and proof that toggling all observed sources never changes a
  functional output/state. Extend the pad tie-off structural test for both new
  output pads.
- P&R: constrain the pins as ordinary non-clock outputs; review that the debug
  fanout does not enter any timing-critical source cone and does not worsen the
  `IQ_CLK` root or PSRAM routing. In particular, add the two pads to the normal
  2 ns `IQ_CLK` output-delay set and report (a) the worst raw-debug
  flop-to-output path, and (b) the pre-existing IQ-input-to-decimator paths
  before/after adding the eight raw-debug flop loads. No timing exception is
  permitted for either check.
- Bench electrical check: with a low-capacitance active probe or equivalent
  logic analyser attached, demonstrate a clean 32 MHz worst-case alternating
  pattern at the debug pad. If ringing needs damping, populate the planned
  series resistor; do not weaken the pad slew as a substitute without repeating
  this measurement.

## Acceptance criteria

The feature is ready for tapeout only when allocation is approved, all valid
mux selections are bit-accurate in simulation, disabled/reserved selections
are provably zero, debug-control writes cannot change during a packet, the pads
meet their specified control tie-offs, the 32 MHz raw pattern is electrically
clean at the intended probe load, and top-level P&R/signoff remains clean.
