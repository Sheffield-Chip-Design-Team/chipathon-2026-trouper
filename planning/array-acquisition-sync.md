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
| Internal pulls | Disabled (`PU=0`, `PD=0`); the board pull-up is mandatory |
| Input conditioning | Schmitt trigger enabled (`CS=1`) and input enabled (`IE=1`) |

The GF180 PDK does not supply a dedicated open-drain pad primitive.  The
bidirectional pad's output-enable is intentionally used to emulate open drain:
the output is either a driven zero or high impedance.  `X/Y` are not used as a
conventional encoded signalling pair.

The pull-up value, maximum bus capacitance, trace length, and required rising
edge time are board-level design items.  All participating outputs must remain
open-drain; no device may actively drive this net high.

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

**The two chips do not land on the same sample, and the offset is not zero.**
The natural path back-calculates from `eval_sample_mark` — the correlation
window mark latched when the hit was evaluated — while the peer path reads the
live `sample_count` at the moment the wire edge is accepted. The difference is
the detector's evaluation-pipeline depth plus the asserting chip's
detect-to-`OE` delay plus the receiving chip's two-flop synchroniser.

Measured on the two-instance bench (`cocotb/array_sync`, SF7/BW250, both chips
released from one reset): **+2 output samples**, against a symbol period of
M = 256 samples. `test_peer_sync_starts_idle_chip` asserts the offset stays in
0..4 samples so it cannot widen unnoticed.

Two samples at 500 kS/s is 4 µs. That is small against a symbol but it is not
phase coherence, and nothing downstream removes it. It is acceptable for what
this link claims to be — an acquisition aid that starts a peer's training
window — and it is *not* sufficient on its own for calibrated beamforming or
direction finding, which is the same conclusion the coherency-prerequisites
section reaches from the clock/reset side. Firmware combining eight elements
across two chips must treat the two 4-element solutions as separately timed
unless the offset is measured and compensated.

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
stimulus and chip B's IQ inputs held at zero. 4/4 PASS, SGE job 5261,
2026-08-30:

| Test | What it establishes |
|---|---|
| `test_peer_sync_starts_idle_chip` | A acquires, asserts `OE`, and B -- which has no RF input at all -- locks off the wire, starts its packet FSM, and gets a non-zero `timing_ref`. B does **not** re-drive the net, so the array cannot ring. |
| `test_isolated_chip_never_locks` | Same run with the net forced idle-high: B stays dark. Without this control the test above proves nothing. |
| `test_force_lock_does_not_drive_the_wire` | `SC_FORCE_LOCK` asserts A's `sc_lock` but never reaches `OE` or chip B. |
| `test_open_drain_invariant_and_tieoffs` | Neither chip ever drives a 1, and the pad controls match the `bi_t` configuration above. |

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
