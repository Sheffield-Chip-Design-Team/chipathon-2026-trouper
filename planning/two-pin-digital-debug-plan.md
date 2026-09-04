# Two-Pin Digital Debug / Bring-Up Plan

**Status: IMPLEMENTED 2026-08-30; RESHAPED 2026-09-03** — RTL, registers, pads
and tests are in (`debug_probe_mux` in `src/top/trouper_top.v`, `DBG_CTRL0` /
`DBG_CTRL1` / `DBG_STATUS` in `reg_bank.v`, suite `cocotb/dbg_probe`).

**2026-09-03 change — the integrator budget was corrected from 28 pads to 27.**
Rather than drop a debug channel, `DBG1` was **merged onto the `IRQ_OUT` pad**:

- `DBG_CTRL0` (`0x04`) drives the one dedicated pad, `DBG0_OUT` (the d0 column
  of the encoding table).
- `DBG_CTRL1` (`0x06`, reclaimed from reserved) drives the shared
  `IRQ_OUT`/`DBG1` pad (the d1 column). That pad carries the sticky interrupt
  whenever `DBG_CTRL1.EN=0`, and the selected debug source when `EN=1`.
- The two selector bytes are decoded **fully independently** (same
  `[7]EN [6:4]GROUP [3:2]ANT [1:0]SEL` layout), so the pads can point at
  unrelated signals — e.g. the shared pad pinned to the `IRQ` group (`irq_out`)
  while `DBG0` roams the other groups.
- `IRQ_OUT_SL` moved from slow (`1'b1`) to fast (`1'b0`): the shared pad can now
  toggle at 32 MHz in raw-RX mode. The board damps the RPi IRQ net with a
  series resistor instead (`TRPR-SPS-008` slow-slew choice reversed for this
  pin only). See `planning/Pinout.md`.
- The override is a pure output mux — nothing in the core reads `IRQ_OUT_OUT`
  back — so it cannot perturb the receiver (TRPR-DBG-004,
  `test_shared_pad_changes_only_irq`).

`info.yaml` declares `DBG0_OUT` (plus `ARRAY_ACQ_N`), taking the allocation to
**27 of 27 — full, no spare**.

Not yet closed: integrator confirmation of slot N16, a P&R run against a real
integrator DEF (the current run uses a locally extended template), and the
bench electrical check — now also covering the `IRQ_OUT` net at fast slew. See
"As built" and "Acceptance criteria" below, and Open Risks #52/#57.

## Objective

If two additional package pads are available, use them as `DBG0_OUT` and
`DBG1` (shared onto `IRQ_OUT`): two **output-only**, register-selected logic-analyser probes.  They
provide first-silicon visibility of the RX, acquisition, packet, PSRAM, and
combiner paths without sharing a functional interface or changing behaviour of
the receiver.

This is intentionally not JTAG.  A two-pin TAP is not useful for state access,
would add a clock/control protocol and DFT verification, and would be a poorer
bring-up tool than probes that correlate directly with the already available
32 MHz `IQ_CLK` reference.

## Scope and allocation gate

**Updated 2026-09-03 — the integrator budget is 27 pads, not 28.** This feature
originally took the last two slots as `DBG0_OUT`/`DBG1_OUT`; with only one slot
free after `ARRAY_ACQ_N`, `DBG1` was folded onto the `IRQ_OUT` pad (see the
status header). Current occupancy is **27 of 27: exactly full, no spare** — the
27 pins `info.yaml` declares, which includes `DBG0_OUT`, `ARRAY_ACQ_N`,
`VDD_CORE` and `VSS`. Any later pin need would have to displace something
already allocated.

`DBG0_OUT` remains gated on the integrator confirming slot N16 exists and is
bondable — the same open item `ARRAY_ACQ_N` carries in Open Risks #52 — and no
P&R run has been built against the 27-pin list. It must not displace an RX IQ
input, PSRAM lane, `IQ_CLK`, reset, or host SPI. Place it at a board-accessible
location with a short probe trace and an adjacent ground test point.

`IRQ_OUT` is now a **shared** pin: a functional interrupt by default, `DBG1`
when `DBG_CTRL1.EN=1`. It can no longer double as a dedicated always-on
analyser trigger while `DBG_CTRL1` is armed — trigger on `DBG0_OUT`, or on an
`IRQ`-group selection on the shared pad, instead. When the shared pad is
borrowed for debug the host loses the interrupt line and must poll
`IRQ_STATUS` (`0x02`); this is why `DBG_CTRL1` resets to `0x00` (interrupt
active) and only yields the pin on an explicit firmware write.

## Electrical and temporal contract

| Item | Requirement |
| --- | --- |
| Names/direction | `DBG0_OUT` (dedicated) and `IRQ_OUT` (shared, carries `DBG1`); output-only at the logical top level. |
| Reset / disabled state | `DBG0_OUT` drives `0` during reset and while `DBG_CTRL0.EN=0`. The shared pad drives the sticky interrupt (itself `0` out of reset) whenever `DBG_CTRL1.EN=0`. |
| Timing reference | The external analyser uses the board's `IQ_CLK` net as its 32 MHz reference. No debug clock is created or driven by Trouper. |
| Functional isolation | Debug logic is a feed-forward fanout only: it has no input to the datapath, FSM, interrupts, PSRAM ownership, or register-write gating. The shared-pad override reads only `irq_out` and the mux value and drives only `IRQ_OUT_OUT`, which nothing in the core reads back. A debug-pad fault cannot alter receiver behaviour. |
| Configuration | `DBG_CTRL0` and `DBG_CTRL1` writes take effect only while `PACKET_ACTIVE=0`. An attempted mid-packet write to either is ignored and sets the existing `RX_HOLD.CFG_WR_REJECTED` sticky bit. The selected source stays constant for the complete packet. |
| Raw-RX implementation | Raw IQ is first captured into eight dedicated one-bit debug flops at `IQ_CLK`, then selected to the pads. It is therefore an exact sampled copy with one-cycle latency, never a combinational IQ-pad-to-debug-pad path. |
| Pad configuration | `DBG0_OUT`: ordinary `bi_t` output, output-enable tied high, CMOS, **fast** slew, mid drive (8 mA). The shared `IRQ_OUT` pad: `bi_t`, output-enable tied high, **fast** slew (`SL=0`, changed from slow 2026-09-03 — `DBG1` can toggle every 32 MHz edge), mid drive (8 mA). Board routing shall include a 0-ohm series-resistor footprint at each ASIC pin — populated with a real value on the `IRQ_OUT` net to damp the edge into the RPi cable — and use a high-impedance, low-capacitance probe. |

The probes are observability only, not a data transport.  For sample modes the
selected bit changes only when its producing sample register changes; the host
uses the known 500 kS/s cadence (every 64 `IQ_CLK` cycles) or an external
analyser trigger.  No claim is made that the pins form an 8-bit data port.

## Proposed register interface

Reclaim the former debug-register slots; this does not expand the fixed 7-bit
SPI map.

| Address | Name | R/W | Reset | Definition |
| --- | --- | --- | --- | --- |
| `0x04` | `DBG_CTRL0` | R/W | `0x00` | Selector for the dedicated `DBG0_OUT` pad (d0 column). `[7] EN`; `[6:4] GROUP`; `[3:2] ANT`; `[1:0] SEL`. Reserved encodings read back but drive the pad low. |
| `0x05` | `DBG_STATUS` | R | `0x00` | `[0] DBG0_PAD_VALUE`; `[1] DBG1_PAD_VALUE` (= the shared `IRQ_OUT` pad output); `[7:2] 0`. Readback is after the mux/enable gate and is a connectivity sanity check, not a sampled trace. |
| `0x06` | `DBG_CTRL1` | R/W | `0x00` | Selector for the shared `IRQ_OUT`/`DBG1` pad (d1 column). Same layout as `DBG_CTRL0`. `EN=0` → pad carries the sticky interrupt; `EN=1` → pad drives the selected debug source. Reserved encodings drive the pad low (they do **not** fall back to the interrupt). |
| `0x07` | — | — | `0x00` | Remains reserved. |

Both selectors share the `!PACKET_ACTIVE` write gate and raise `RX_HOLD.CFG_WR_REJECTED`
on a mid-packet write, exactly as the single `DBG_CTRL` did.

**d0 / d1 columns.** `DBG0` always takes the d0 source of its selected
group/sel; the shared pad always takes the d1 source. So `DBG0` can show
`packet_active`, `sc_hit`, `sc_lock`, `sample_skip`, `psram_init_done`,
`irq_status[SEL]`, … and the shared pad can show `training_done`, `sc_lock`,
`packet_active`, `replay_missed`, `qpi_busy`, `irq_out`, … — see the encoding
table below. To reproduce the old paired probe, write the identical selector to
both bytes.

`ANT` selects branch 0–3 for branch-qualified groups. `SEL` chooses a bit,
pair, or event within the selected group as specified below. The hardware must
not clamp invalid values; it drives zero for reserved encodings.

## As built — deviations from the proposal above

The implementation follows this plan except where noted here. Read these before
using the encoding table.

- **`IRQ` group reaches only `irq_status[3:0]`.** The table below lists
  `SEL=0`–`4`, but `SEL` is a 2-bit field, so only four of the five sticky
  sources are selectable. The fifth stays readable over SPI at `IRQ_STATUS`
  (`0x02`). Widening `SEL` would have cost a `DBG_CTRL` bit for one probe
  position; not judged worth it.
- **`qpi_busy` is derived, not a dedicated signal.** It is `|state_dbg` from
  `psram_buf_ctrl` — true whenever the QPI FSM is out of its idle state, which
  is what the plan's bring-up use asks for.
- **Three small observability exports were added** so the mux taps real
  registered state rather than re-deriving it: `sc_tdm_busy_dbg` (`sc_detector`),
  `del_rdy_dbg` (`psram_buf_ctrl`) and `irq_status_dbg` (`reg_bank`). All are
  pure fanout of existing flops.
- **`DBG_CTRL` is gated on `!PACKET_ACTIVE` only**, as specified — deliberately
  weaker than the `cfg_wr_ok` (`RX_HOLD` + `!PACKET_ACTIVE`) gate the other
  quasi-static registers use. The requirement is a fixed selection per packet,
  not a held receiver; re-pointing a probe between packets without disabling the
  detector is the normal bring-up loop. Rejected writes still raise
  `CFG_WR_REJECTED`.
- **Raw-RX capture flops are free-running**, not gated by `EN`. Gating them
  would fan the enable out across the IQ input cone — the one place this plan
  requires the feature not to disturb.
- **Measured area cost: +4,454 µm² (+0.470%)** against an otherwise identical
  build (Yosys hierarchical synth, jobs 5277/5278 on commits `53eb221` and
  `3342b87`).

## Debug-mux encoding

Column `DBG0_OUT` is the d0 source (selected by `DBG_CTRL0`); column
`IRQ_OUT/DBG1` is the d1 source (selected by `DBG_CTRL1`, and reaches the pad
only when `DBG_CTRL1.EN=1`). The two are chosen independently — the pairing
below is just the table layout, not a hardware constraint.

| `GROUP` | `SEL` | `DBG0_OUT` (d0) | `IRQ_OUT/DBG1` (d1) | Bring-up use |
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

## Timing result (job 5457, 2026-09-03 — 27-pin reshape)

Canonical `src/config/trouper_top.json`, gaming-pc, 22:55, exit 0.

**Physical signoff clean:** Magic DRC 0, route DRC 0, LVS 0, XOR 0, antenna 0
(0 critical disconnected pins), hold WNS +0.117 ns.

**Setup timing:**

| Corner | WNS | note |
|---|---:|---|
| `nom_tt_025C_3v30` | +10.74 ns | meets |
| `max_ff_n40C_3v60` | +11.75 ns | meets |
| `max_ss_125C_3v00` | **−10.88 ns** | vs baseline job 5379 −10.13 ns (−0.75 ns, n=1 repair lottery); SS TNS −295.6 vs −383.5 (better) |

**The `DBG1` output violator moved to `IRQ_OUT_OUT`, as predicted, and shrank:**

| | pre-reshape (job 5279) | reshape (job 5457) |
|---|---|---|
| dedicated debug pad | `DBG0_OUT` −4.44 ns | `DBG0_OUT` −6.16 ns |
| DBG1 / shared pad | `DBG1_OUT` −6.06 ns | `IRQ_OUT_OUT` −4.82 ns |
| other `reg-out` violators | 0 | 0 |

These two are still the *only* register→output violators at SS. The worst path
overall is an internal `IQ_CLK`→`IQ_CLK` `reg-reg` datapath path (−10.88 ns),
unrelated to the debug pins. Fast slew on `IRQ_OUT` did not make its path worse
than the old slow-slew `DBG1_OUT`. 7 `.lib` max-slew + 2 max-cap advisory
violations, all on one internal high-fanout net (`_45654_/Z` cluster) — no
debug/IRQ pad involved, not manufacturing DRC.

**Decision still owed** (unchanged): SS 3.0 V is voltage-bound design-wide
(−10.88 ns; closes at 4.5 V), so whatever closes the design closes these two
pins. Either accept a documented, justified output-delay exception for
`DBG0_OUT` + `IRQ_OUT_OUT`, or fix the paths.

---

### Historical: job 5279 (2026-08-30, pre-reshape, two dedicated debug pads)

**The IQ-input loading concern did not materialise.** The eight raw-RX capture
flops load the `IQ_DATA_*` cone, and the worry was that this would worsen the
pre-existing IQ-input-to-decimator paths. It did not: **zero** `IQ_DATA` paths
appear in the SS violator list.

**The debug output paths do violate at SS**, and they are the only output paths
in the design that do:

| Corner | `DBG0_OUT` | `DBG1_OUT` | Other `reg-out` violators |
|---|---:|---:|---:|
| `nom_tt_025C_3v30` | meets | meets | 0 |
| `max_ff_n40C_3v60` | meets | meets | 0 |
| `max_ss_125C_3v00` | **−4.440 ns** | **−6.060 ns** | **0 — these two are the only ones** |

They inherited the standard budget automatically: `pnr_32m_scoped_v25_b6.sdc`
applies `set_output_delay -max 2.0 -clock IQ_CLK` to `[all_outputs]` except
`SPI_MISO_OUT`, so nobody decided 2 ns was right for a debug pin — it was the
default.

**This fails the acceptance criterion above**, which says the pads go in the
normal 2 ns set and *"no timing exception is permitted"*. That sentence exists
to stop exactly the argument that follows, so it is recorded as failing rather
than waived.

The argument for tolerating it, stated so it can be judged rather than assumed:
SS 3.0 V already fails by −17.7 ns design-wide and is a known voltage-bound
risk that closes at 4.5 V; the debug paths fail by roughly a third of that, so
whatever closes the design very likely closes them. The functional consequence
is bounded — a late debug output means an unreliable analyser capture at the
slow corner, not receiver misbehaviour, and nothing downstream consumes these
pins. And a 2 ns output delay inherited from functional outputs is arguably the
wrong constraint for a pin whose consumer samples on its own reference.

**Decision still owed:** either accept a documented, justified exception for
these two pins, or fix the paths. Not "the corner was already red, so it does
not matter".

**Not attributable:** SS WNS moved −16.260 (job 5214) → −17.736 (job 5279) on an
unrelated `reg-reg` path. Job 5279 also carries the array-sync link, the epoch
compensation and the `SC_ANT_SEL` move, so none of that −1.48 ns can be charged
to the debug probe without a baseline P&R of `53eb221` on the same config.

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

Status against each, 2026-08-30 (traceability: `planning/Traceability.md`
TRPR-DBG-001..010):

| Criterion | State |
|---|---|
| Allocation approved | ❌ Slot N16 (`DBG0_OUT`) unconfirmed by the integrator; with `ARRAY_ACQ_N` takes the pinout to 27/27 with no spare. `DBG1` now shares `IRQ_OUT` (N-edge, already allocated). |
| All valid mux selections bit-accurate | ⚠️ Partial — raw-RX (all 4 branches), packet group and `DBG_STATUS` asserted; decimated-IQ, SC, PSRAM, combiner and IRQ groups are structurally identical muxing but not individually checked |
| Disabled / reserved provably zero | ✅ `test_reset_and_disabled_drive_low`, `test_reserved_encodings_drive_zero` |
| Config cannot change during a packet | ✅ `test_config_is_idle_only_and_sticky_records_rejection` |
| Pad-control tie-offs | ✅ `test_pad_tieoffs` — but this checks the **core outputs**, not the pad cells they will drive. Trouper instantiates no IO cells; a tie-off landing on the wrong cell terminal is only visible in chip-level LVS (`planning/pad-cell-signoff-plan.md` §1) |
| Probe cannot perturb the receiver | ✅ `test_probe_does_not_perturb_the_receiver` — 4000 cycles bit-identical (this is not in the original list and should be: it is the criterion that makes the feature safe to ship) |
| 32 MHz pattern electrically clean at the probe | ❌ Gated on the integrator padframe. SPICE first (`planning/pad-cell-signoff-plan.md` §3d), then bench with a low-capacitance active probe |
| Top-level P&R / signoff clean | ⚠️ **macro scope, with a timing exception outstanding** — job 5457 (27-pin): antenna 0, route DRC 0, Magic DRC 0, LVS 0, XOR 0, hold WNS +0.117 ns. But `DBG0_OUT` + `IRQ_OUT_OUT` violate setup at SS (below). No pad cell is present in that netlist or layout, so none of this is a pad-cell result |
| Debug outputs meet the 2 ns output delay, no exception | ❌ **Violated at SS** (job 5457: `DBG0_OUT` −6.16 ns, `IRQ_OUT_OUT` −4.82 ns) — see "Timing result" below |
| Area cost measured | ✅ +4,454 µm² (+0.470%) |
