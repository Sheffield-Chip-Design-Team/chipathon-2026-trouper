# Multi-ASIC Array Acquisition Synchronisation

## Purpose

This note defines the optional acquisition synchronisation link between Trouper
instances that form one coherent antenna array.  It uses one of the otherwise
spare package pins to share a preamble-acquisition event.  It is an acquisition
aid only: it does not distribute sample data, phase, weights, or a clock.

The existing four coherent RX branches in one Trouper already provide the data
needed for four-element digital MRC and firmware-calculated nulling (for example
MVDR/eigenvector weights).  Adding this pin does not increase the number of
spatial degrees of freedom of a single chip.

## What it does and does not enable

Two Trouper instances, each with four antennas, can share a first acquisition
event so that either receiver may start the other receiver's training window.
With a shared clock and reset, the two 4-element correlation matrices may then
be combined in firmware into an eight-element array solution.

This is not by itself a two-dimensional direction finder.  A vertical and a
horizontal four-element sub-array can estimate two angular components only
after array calibration and a phase-coherent common sampling reference.  The
calibration must cover element position, cable/AFE phase, gain, and relative
chip timing.  A single-point calibration can remove one complex per-channel
offset; it cannot determine the geometry or correct direction-dependent array
response.  Weight vectors alone are therefore not a reliable direction output.

## External wire

The board connects every participating chip's `ARRAY_ACQ_N` pad to one shared
net with a single external pull-up resistor to the IO supply.

| Property | Definition |
|---|---|
| Signalling | Active low, wired-AND/open-drain style |
| Idle level | High, provided by the external pull-up |
| Assert | A chip pulls the net low after a local natural Schmidl-Cox lock |
| Release | The asserting chip releases the pad on `packet_done`, `rx_hold`, or reset/disable |
| Pad implementation | `gf180mcu_fd_io__bi_t` (`info.yaml` `io_type: bidirectional`); drive `A=0`, assert `OE`, and sample `Y` |
| Drive strength | `PDRV[1:0]=00` (4 mA) — ample to sink the board pull-up, and the slowest available falling edge on a shared multi-drop net |
| Internal pulls | `PU=1`, `PD=0`. The board pull-up is still mandatory on a multi-chip net; the internal device only keeps an *unpopulated* pin from floating. On a shared net one internal pull-up per chip sits in parallel with the board resistor and counts against the pull-up / V_OL budget. |
| Enable | `ARRAY_SYNC_CTRL[0]` (`0x1B`) `ARRAY_SYNC_EN`, **resets to 0**. The pin is inert in both directions until firmware sets it. |
| Input conditioning | Schmitt trigger enabled (`CS=1`) and input enabled (`IE=1`) |

The GF180 PDK does not supply a dedicated open-drain pad primitive.  The
bidirectional pad's output-enable is intentionally used to emulate open drain:
the output is either a driven zero or high impedance.  `X/Y` are not used as a
conventional encoded signalling pair.

The pull-up value, maximum bus capacitance, trace length, and required rising
edge time are board-level design items.  All participating outputs must remain
open-drain; no device may actively drive this net high.

### Disabling the link

`ARRAY_SYNC_EN` (`ARRAY_SYNC_CTRL[0]`, register `0x1B`, reset 0) gates **both**
directions in
`array_acq_sync`: it is a term in `armed`, so a disabled chip cannot accept a
peer event, and a term on the `drive_oe` set condition, so a disabled chip
cannot pull the net down when it acquires. Clearing it also forces `drive_oe`
low immediately.

Off is the reset state, which is what makes an unused pin safe: a single-chip
board may leave `ARRAY_ACQ_N` unpopulated with no external pull-up, and nothing
the floating pad does can start the receiver. A two-chip array must therefore
set `ARRAY_SYNC_CTRL[0]` on *both* chips at bring-up — it is a gated config
register, so write it with `RX_HOLD=1` before releasing the receiver, alongside
SF and BW.

It has its own register rather than a spare `BW_CFG` bit: `BW_CFG` is the
bandwidth register (already carrying `sc_ant_sel`), and arming a multi-chip link
has nothing to do with bandwidth. `0x1B` was reserved and sits with the other
SC/receiver control registers, `SC_FORCE_LOCK` (`0x19`) and `RX_HOLD` (`0x1A`).
Its upper seven bits are free for future array status/control.

`test_disabled_link_ignores_the_wire` covers the default state, and
`test_disabled_receiver_rejects_a_real_edge` applies a genuine falling edge from
an enabled peer to a disabled receiver — the case where gating only the drive
side would look identical to gating both.

## RTL protocol and simultaneous events

`array_acq_sync` synchronises the pad input through two IQ_CLK flops.  A chip
accepts a peer event on a high-to-low transition only when it is idle:

- `packet_active=0`
- no concurrent local natural SC-lock pulse
- `rx_hold=0`
- the line has previously been observed high

The accepted peer event is a one-cycle `sc_lock_sync` pulse to `sc_detector`.
The detector reconstructs `timing_ref` using the normal back-calculation,
`sample_count - (SC_HITS_REQ + 1) * M + 1`, so downstream training uses the
same time reference *convention* as a local acquisition.

### Epoch compensation

The peer path is inherently *late*. The detecting chip back-calculates from
`eval_sample_mark` — the correlation window mark latched when the hit was
evaluated — while the receiving chip can only read the live `sample_count` when
the wire edge arrives, after the peer's evaluation pipeline, its lock-to-`OE`
delay, and its own two-flop synchroniser.

Uncompensated, that measured **+2 output samples** (`cocotb/array_sync`, SGE job
5264). The lag is a fixed number of `IQ_CLK` cycles, and the decimator is fixed
R=64 — one output sample is always 64 clocks — so the lag is a fixed number of
*samples* for every SF and BW. Confirmed by measurement, not by argument:

| Configuration | Raw delta | Compensated delta |
|---|---:|---:|
| SF7 / BW 250 kHz (M=256) | +2 | 0 |
| SF7 / BW 125 kHz (M=512) | +2 | 0 |
| SF8 / BW 250 kHz (M=512) | +2 | 0 |

`sc_detector` therefore subtracts `SYNC_EPOCH_LAG_SAMPLES = 2` in the
`sc_lock_sync` branch, and **both chips now land on the same `timing_ref`**
(SGE job 5265). `test_epoch_offset_is_stable_across_sf_bw` asserts the
compensated delta is exactly 0 — not a tolerance, so that a future change to
the evaluation pipeline makes the stale constant fail loudly instead of
degrading multi-chip combining quietly.

**What this does and does not buy.** It removes the *protocol's* contribution
to epoch error, so two chips that share a clock and a reset now agree on the
sample index a packet started at. It does nothing about the physical terms in
the coherency prerequisites below — board clock skew, reset-release
misalignment, and per-channel AFE phase are all untouched, and they, not this
constant, are what stand between the link and calibrated beamforming.

### Resetting and re-arming the link

There is no timer in `array_acq_sync`; release is entirely event-driven.

| Signal | Cleared by | Re-set by |
|---|---|---|
| `drive_oe` | `packet_done`, `rx_hold`, `!array_sync_en` | a local natural SC lock while idle |
| `line_idle_seen` | `packet_done`, `rx_hold` | observing the net high again |

`line_idle_seen` is what makes reset safe. A chip released from reset while the
net is *already* low must not read that standing level as a fresh event, so it
refuses to accept anything until it has seen the line released. The same flop
is what lets a second packet sync over the same link.

`packet_done` is guaranteed to arrive: `packet_ctrl_fsm` loads an absolute
`pkt_cnt` deadline from `PKT_TIMEOUT_SYMS` at `ST_ACQ_SETUP` and unconditionally
returns to `ST_IDLE` when it expires. A chip that locks falsely therefore cannot
hold the whole array's wire down indefinitely — it releases at its own packet
timeout. `RX_HOLD` is the firmware-side escape hatch: asserting it drops
`drive_oe` and clears `line_idle_seen` immediately, without waiting for the
timeout.

`test_sync_releases_and_rearms` covers the full cycle: sync, packet timeout,
both chips release, the net returns high, `sc_lock` clears on both, and a
second packet syncs over the same link.

### A peer-synced chip ignores its own detector

In a real array both chips hear the packet, so the interesting case is not the
starved receiver in the bench — it is the receiver whose *own* correlator
completes its hit run shortly after it was already started by the wire.

It is ignored. `sc_detector` gates the entire natural-lock block behind
`metric_valid_pulse && !sc_lock`, so from the moment the peer event sets
`sc_lock` the local correlator cannot fire again until `sc_clr` (packet done or
`RX_HOLD`). Three consequences, all deliberate:

- `timing_ref` is **not** rewritten mid-packet. `packet_ctrl_fsm` latches it
  once in `ST_ACQ_SETUP` and derives absolute deadlines from it; a late
  overwrite would leave the FSM and the detector anchored to different epochs.
- `sc_lock_natural_pulse` does **not** fire, so a synced chip never re-drives
  the shared wire. Without this the array could ring — each chip restarting the
  other for as long as the net stayed low.
- `packet_ctrl_fsm` has no mid-packet re-lock path; it was removed as
  structurally unreachable (Open Risks #25), and the comment there warns
  specifically that *a cascade input without the `!sc_lock` gate* would make it
  reachable again. The gate in the `sc_lock_sync` branch is what keeps that
  warning satisfied.

The cost is that the array adopts **one** chip's timing — whichever detected
first — and the other chip's own, possibly better-aligned, local estimate is
discarded for that packet. That is the intended trade: a single shared epoch is
the point of the link.

`test_peer_lock_suppresses_local_detector` drives exactly this sequence — sync
chip B, then give B the same RF chip A is receiving — and asserts `timing_ref`
never moves and B's `OE` never asserts.

### Simultaneous local detection

If both chips detect locally at nearly the same time, both may pull the wire
low.  This is safe: neither driver can contend because both only drive zero.
Each chip's local qualified lock wins in that cycle; it does not consume its
own wire transition as a second lock.  The line remains low until every
asserting device releases it.  A receiver already processing a packet ignores
the event, preventing a late peer event from restarting its detector.

`SC_FORCE_LOCK` is deliberately excluded from this protocol.  It is a
diagnostic override and does not prove that the normal correlation/timing
reference condition was met; propagating it could establish an invalid shared
time origin.

## Coherency prerequisites

The wire is useful for coherent multi-chip processing only when every chip
shares:

1. the same `IQ_CLK` reference, with skew controlled as part of board design;
2. a common reset release / known sample-count epoch; and
3. identical LoRa configuration (SF, bandwidth, and detector hit count).

The acquisition wire does not correct clock skew or reset-epoch mismatch.
Without these prerequisites it may coordinate packet detection, but the
cross-chip phase needed for calibrated beamforming or direction estimation is
not preserved.

## Implementation footprint and verification

The hard-macro boundary adds ten logical ports: three functional signals
(`ARRAY_ACQ_N_OUT`, `ARRAY_ACQ_N_IN`, `ARRAY_ACQ_N_OE`) and seven pad-control
signals (`IE`, `CS`, `SL`, `PU`, `PD`, `PDRV0`, `PDRV1`).  They map to one
physical `bi_t` bidirectional pad at chip-top integration.  `bi_t` is required
rather than `bi_24t`: only `bi_t` exposes `PDRV[1:0]`, and `bi_24t` has no
drive control at all (fixed 24 mA) — see `planning/Pinout.md`, "Pad cell type
selection".

The pad is declared last in `info.yaml`, after `VDD`, so it takes the next free
A40 slot (N15) without displacing any P&R-validated pin.  Trouper's ACV
allocation is 28 slots (confirmed 2026-08-30), so this spends one of three
spares and leaves two.  What is still outstanding is a regenerated
`A40_ACV.def` and a P&R run against the 26-pin list — no run has been built
against one.  Open Risks #52.

The standalone RTL test `rtl-test/tb/tb_array_acq_sync.v` covers local drive,
packet-complete release, a synchronised peer falling edge, and rejection of a
late event while a packet is active -- all against the `array_acq_sync` module
alone.

`cocotb/array_sync` (`cocotb/tests/test_array_sync.py`, harness
`cocotb/hdl/tb_array_pair.v`) is the end-to-end test: **two complete
`trouper_top` instances** sharing one wired-AND net, chip A fed a CW SDM
stimulus and chip B's IQ inputs held at zero. 7/7 PASS, SGE job 5265,
2026-08-30:

| Test | What it establishes |
|---|---|
| `test_peer_sync_starts_idle_chip` | A acquires, asserts `OE`, and B -- which has no RF input at all -- locks off the wire, starts its packet FSM, and gets a non-zero `timing_ref`. B does **not** re-drive the net, so the array cannot ring. |
| `test_isolated_chip_never_locks` | Same run with the net forced idle-high: B stays dark. Without this control the test above proves nothing. |
| `test_force_lock_does_not_drive_the_wire` | `SC_FORCE_LOCK` asserts A's `sc_lock` but never reaches `OE` or chip B. |
| `test_open_drain_invariant_and_tieoffs` | Neither chip ever drives a 1, and the pad controls match the `bi_t` configuration above. |
| `test_epoch_offset_is_stable_across_sf_bw` | The A→B epoch offset is one constant across SF7/BW250, SF7/BW125 and SF8/BW250 — which is what makes a single `SYNC_EPOCH_LAG_SAMPLES` legitimate — and is 0 after compensation. |
| `test_peer_lock_suppresses_local_detector` | A peer-synced chip ignores its own correlator: `timing_ref` never moves and it never re-drives the wire. |
| `test_sync_releases_and_rearms` | Packet timeout releases the wire on both chips, `sc_lock` clears, and a second packet syncs over the same link. |

Every other bench in `cocotb/` has a single DUT and ties `ARRAY_ACQ_N_IN` to
its idle level, so none of them can exercise the peer path.

An isolated SGE synth-only comparison (job 5152, 2026-08-28) used separate
baseline and extension NFS snapshots and did not overwrite shared inputs.

| Metric | Baseline | With array acquisition sync | Delta |
|---|---:|---:|---:|
| Mapped GF180 standard cells | 34,553 | 34,664 | +111 |
| Mapped cell area | 977,393.04 um² | 981,423.43 um² | +4,030.39 um² (+0.41%) |

Both synthesis runs completed with zero Yosys CHECK problems.  This is a
synthesis-only result; timing, DRC, LVS, pad-ring integration, pull-up sizing,
and multi-chip calibration remain to be validated in their respective flows.
