# Foundational-Block First-Silicon Bring-Up Plan

## Purpose

Trouper's primary demonstration is the complete receive/replay/MRC path. That path has several external dependencies: valid 32 MHz one-bit I/Q sources, successful PSRAM initialisation and QPI traffic, Schmidl-Cox acquisition, and host configuration. A fault in an early dependency must not prevent a credible demonstration of the chip's independent foundation blocks.

This plan defines an evidence-first bring-up sequence and a deliberately small, *not yet implemented*, internal-stimulus option. It adds no package pins and does not change the normal receive path unless the option is later approved and implemented.

## Existing independent evidence paths

| Foundation block | Stimulus / control already present | Observable evidence | Limitation |
| --- | --- | --- | --- |
| Host SPI and register bank | Host SPI pins; `CHIP_ID` (`0x00`) and register access map | SPI readback, `IRQ_OUT`, sticky status | Does not exercise DSP datapath |
| PSRAM QPI controller | `PSRAM_DBG_WDATA` (`0x79`) and `PSRAM_DBG_CTRL.WR_TRIG` (`0x75[2]`) | SPI debug readback (`0x76`); address/data march patterns | Tests QPI memory service, not live capture/replay |
| Packet control / IRQ | `SC_FORCE_LOCK` (`0x19[0]`) | `PACKET_STATUS` (`0x1C`), IRQ status/output, timeout | Deliberately bypasses a valid correlator timing reference |
| Array acquisition sync | Two populated `ARRAY_ACQ_N` pads and `ARRAY_SYNC_CTRL` (`0x18[0]`) | Peer lock/state/IRQ observations | Requires two chips or an external open-drain fixture |
| Decimator, DC removal, SC detector | FPGA or fixture drives deterministic 1-bit I/Q on existing eight `IQ_DATA_*` inputs | Debug-probe groups 001/010/011, SC registers, PSRAM capture data | Depends on the external source and upstream chain |
| Training accumulator | `TACC_NOISE_TRIG` (`0x1F[0]`) plus controlled input stream | `N_ACC`, `ZDIAG`, training/noise status | Meaningful complex `Z` values still require input samples |
| Combiner in bypass | Existing mode/antenna controls and replayed PSRAM samples | Debug-probe group 110 and remodulator output pads | Cannot be isolated if capture/replay is unavailable |
| Re-modulator | Existing `REMOD_A_I/Q` pads | 32 MHz one-bit I/Q capture, externally decimated and compared | Its input currently depends on upstream blocks |

The two debug pads are observability aids, not a high-bandwidth trace port. They can show selected bits of the registered input to the re-modulator in group 110, but the correct primary observation point for its 32 MHz output is the dedicated `REMOD_A_I` / `REMOD_A_Q` pads.

## Bring-up sequence without new RTL

1. **Control-plane proof.** Read `CHIP_ID`; verify the implemented register reset map and `RX_HOLD` (`0x1A`) behavior.
2. **PSRAM proof.** After the board-specified power-up wait, initialise PSRAM, then write and read address-encoded / marching patterns through the existing debug port. This independently proves the QPI pins, device, controller, and SPI service path. Note that `DBG_BUSY` (`0x75[7]`) reads `1` at power-on because it folds in `!qe_init_done` — a script that polls for `DBG_BUSY=0` *before* triggering PSRAM init will appear to hang on a perfectly healthy chip. Wait on `PSRAM_STATUS.INIT_DONE` (`0x71[3]`) first, then on `DBG_BUSY`.
3. **Control/FSM proof.** Use `SC_FORCE_LOCK` while idle to establish the expected packet-state, timeout, and IRQ sequence. Do not interpret this as valid packet acquisition or channel training.
4. **Frontend proof.** Drive a known 1-bit I/Q stream from an FPGA or fixture into `IQ_DATA_*`; use raw/decimated/SC debug selections, status registers, and PSRAM readback to validate the decimator through detector path.
5. **Full-chain proof.** With the same fixture and working PSRAM, demonstrate bypass replay first, then training/weights/MRC, observing the direct re-modulator pad streams and externally decimating them.

This sequence already gives a useful failure partition: a failing early stage does not obscure SPI, PSRAM service, packet control, or board I/O evidence.

## Shared internal stimulus source — option (c) chosen 2026-09-03, at the re-modulator input

> **Status 2026-09-02 — SUPERSEDED by the 2026-09-03 decision further down;
> kept because the MRC and P&R findings it records are what drove that decision.**
>
> Implemented on `feat/bringup-src` at the **combiner input**, as
> `src/debug/bringup_src.v` plus `BRINGUP_CTRL` (`0x06`) / `BRINGUP_AMPL` (`0x07`).
> The combiner insertion point was chosen because `mrc_combiner` is a bit-exact
> passthrough in bypass, so one generator proves **both** blocks with no loss of
> `sd_remod` isolation: the programmed sample arrives unmodified, and a bad 1-bit
> output stream is unambiguously `sd_remod`'s fault. The doc's stated cost of that
> choice — "needs a four-branch source" — turned out to conflate the generator with
> the mux: one complex generator is fanned out to all four branches, so the extra
> silicon over the re-modulator tap is mux width, not arithmetic.
>
> **Requirement 4 is now measured, and it does not clear the bar as written.**
> Job 5404 (feature) against job 5379 (baseline), same `src/config/trouper_top.json`:
>
> | Metric | Baseline 5379 | With BRINGUP_SRC 5404 | Delta |
> | --- | --- | --- | --- |
> | SS WNS `max_ss_125C_3v00` | −10.130 ns | −10.916 ns | **−0.787 ns** |
> | SS TNS | −383.5 ns | −699.3 ns | **−315.8 ns (1.82×)** |
> | Stdcell area | 1,171,490 µm² | 1,180,280 µm² | +8,790 (+0.750%) |
> | Stdcell count | 48,926 | 49,275 | +349 |
> | Sequential cells | 5,228 | 5,273 | +45 |
> | Stdcell utilisation | 66.07% | 66.57% | +0.50 pt |
> | Magic DRC / antenna / XOR / LVS | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | clean |
>
> **On the utilisation line specifically:** 66.57% is measured
> `design__instance__utilization__stdcell`, not a target. The config sets
> `PL_TARGET_DENSITY_PCT: 65`, and its own `_comment_density` records that this
> figure is *load-bearing for routability, not area* — 78% and 72% both hit
> DRT-0073/DRT-1231 on this 1675×1110 die, 65% is what cleared it, and every clean
> signoff since (5198/5214/5279/5284/5286) has run at 65%. So the +0.50 pt this
> feature costs is not spare room being consumed: it spends the same budget that
> buys pin access for the `IQ_CLK` clock tree and the antenna diodes. Recovering it
> by raising density "requires re-proving routing, not just timing". That is a
> second, independent reason the timing delta below should not be waved through —
> the design is at 66.57% against a 65% target that exists because routing fails
> above it.
>
> The area cost is small and the physical checks are clean. The timing cost is not
> small: this requirement says the source "is not justified if it worsens current
> timing or routing risk beyond an agreed budget", and no budget was ever agreed.
> A near-doubled TNS on a design that already misses SS is the finding, not the
> −0.787 ns WNS — WNS on this design is a known repair lottery, so a single pair
> cannot separate 0.8 ns from run-to-run scatter, whereas a 1.82× TNS cannot
> plausibly be scatter. (That "repair lottery" behaviour was first observed on the
> older, denser B4+B6 floorplan at ~88% utilisation. It is recorded here because the
> scatter caveat still applies, but the 88% figure does **not**: this A40 die runs at
> 66.57%. Do not carry the density number across builds.)
>
> **Requirement 3 is now met, and requirement 2's coverage found a limitation that
> changes what the feature buys.** `cocotb/bringup_src` is 20/20 (job 5419).
> Requirement 3 — "compare captured 1-bit outputs after external/Python decimation
> with the programmed DC/tone reference" — had no coverage at all until now: every
> test stopped at the *combiner input*, which proves the mux, not the signature a
> bring-up engineer would actually compare against. Two tests close it, both
> reading `REMOD_A_I/Q` at the pads:
>
> - `test_dc_signature_at_the_remod_output` — the ±1 output density equals
>   `level/127` for levels 16/32/48, on I and Q independently. Needs no filter and
>   no phase alignment: computable on the bench from a bit count alone.
> - `test_tone_signature_at_the_remod_output` — R=64 brickwall reconstruction (the
>   same decimation `sim.tests.remod_order_sweep` uses) matched against
>   `A/127·exp(+jπn/2)` in amplitude *and rotation direction*, which is what tests
>   I and Q **together**: a swapped or inverted rail leaves both per-rail densities
>   untouched and shows up only as the conjugate tone. Whole-band SQNR measured
>   18.2 dB.
>
> Also added: the exact 500 kS/s cadence, a golden-LFSR compare for PRBS (liveness
> was all that was checked before), `psram_silence` held low across the capture,
> precedence over a *live* decimator arm (every other test runs with the IQ pads
> tied low, so a mux with inverted priority would have passed all of them), and
> mid-burst disarm.
>
> **The limitation: MRC mode is structurally unreachable while the source is
> armed.** `W_valid` is cleared on every clock where `!packet_active`
> (`trouper_top.v:761-765`) and `bringup_en_q` requires `!packet_active`
> (`trouper_top.v:885`), so the two are mutually exclusive — a committed W survives
> at most the single clock after `W_valid_set`, and `mrc_combiner` latches
> `use_mrc_r` only at a burst start, one clock in 64. **BRINGUP_SRC can prove the
> combiner's bypass passthrough only**; the MAC, the `acc >>> (8 - pgs)` output
> shift, saturation, and per-branch weight application stay dark. `bringup_src.v`'s
> header claimed all four; that claim has been corrected in the RTL, and the
> behaviour is now pinned by `test_mrc_mode_is_unreachable_while_armed` plus
> `test_combiner_degrades_to_bypass_not_to_zero` (the fallback is bypass, not
> silence — silence would be indistinguishable from a dead re-modulator, the exact
> diagnosis this feature exists to enable).
>
> This feeds the decision gate directly: option (c) below — moving the source to the
> re-modulator input — was costed as "giving up combiner coverage". The combiner
> coverage actually on offer is the bypass passthrough, which is a wire. The gap
> between (c) and the implemented option is therefore much smaller than the plan
> assumed, while the measured cost is 1.82× TNS.
>
> **Decision owed to the first-silicon team**, in the plan's own terms below: does
> proving the combiner and re-modulator without a working frontend/PSRAM chain
> outweigh this? Options, cheapest first: (a) accept, on the grounds that SS is
> already missed and the fix is voltage, not slack; (b) re-run the pair two or
> three times to bound the scatter before deciding; (c) move the source to the
> re-modulator input, giving up combiner coverage for a smaller mux; (d) drop it
> and rely on the FPGA IQ stimulus baseline. Do not treat the existence of this
> RTL as approval.

---

### DECISION 2026-09-03: option (c). Source moved to the re-modulator input.

Taken once the coverage work showed option (c)'s stated cost — "giving up
combiner coverage" — was not a cost at all. The MRC exclusion above means the
only combiner behaviour the source could ever reach was the bypass passthrough,
which is a wire. Option (c) proves the same thing for a smaller mux and
diagnoses better: at the combiner input a bad 1-bit stream implicated `sd_remod`
**or** the bypass path with no way to tell which from the pads; at the
re-modulator input it implicates `sd_remod` alone. That isolation argument, not
the cell count, is the reason to prefer it.

**Implemented** (commit `9b36e6d`, branch `feat/bringup-src`):

- The `BRINGUP_SRC` arm is removed from the combiner input mux, which returns to
  a two-way `replay_active ? rpl : dcr` select. The generator is muxed into
  `remod_in_i/remod_in_q/remod_in_valid` instead: 3 mux points rather than 9
  (4 branches × 2 rails + valid).
- The armed source takes **absolute priority** at that mux, ahead of both
  `psram_silence` and `REMOD_BACKOFF_SHIFT`. `psram_silence` would let a buffer
  state zero the stimulus, and silence at the pads is indistinguishable from a
  dead re-modulator — the exact diagnosis this source exists to enable. The
  backoff would make the pad signature depend on `COMB_CFG` rather than on the
  programmed value. Skipping the backoff is safe because the generator clamps to
  ±64 (−6 dBFS), already inside `sd_remod`'s −3 dBFS stability bound.
- `BRINGUP_CTRL` (`0x06`) / `BRINGUP_AMPL` (`0x07`) are unchanged, so the
  register map, firmware header and reset/RW sweeps need no revision.
- Side effect worth knowing at the bench: the two-pin debug probe's COMB group
  taps `remod_in_i/q`, which is now downstream of the mux, so an armed source is
  visible on `DBG0`/`DBG1` as well as on `REMOD_A_I/Q` — a second, byte-level
  view of the stimulus with no radio attached.

**Requirement 2 evidence — `cocotb/bringup_src` 23/23 (job 5427), core
regression 42/42 (job 5423).** Beyond the requirement-3 work recorded above, the
move added: samples reach `remod_in` unmodified, the combiner is demonstrably out
of the path, the backoff and `psram_silence` overrides, precedence over a *live*
receive path, clean hand-back on disarm (no stuck DC, no stalled valid), and the
debug-probe group. The arming gate's third term is also now covered: raising
`RX_HOLD` mid-packet does **not** end the packet (`packet_ctrl_fsm` never sees
`rx_hold`), but `reg_bank`'s `cfg_wr_ok = rx_hold && !packet_active` refuses the
write; the level term in `trouper_top.v` is a second, independent barrier and is
exercised by forcing the register past the write gate.

**Formal — `formal/bringup_src.sby`, PASS prove + cover (job 5438).** The
generator carried three `` `ifdef FORMAL `` assertions from the day it was
written and nothing ever ran them: no `.sby`, no harness. Running them found one
was **wrong**, not merely unrun — `if (!rst_n || !en) assert(!src_valid)` is
false in the cycle `en` falls, because `src_valid` is registered. Induction
caught a second off-by-one: `mode` is sampled at the tick, so a mode change takes
effect at the *next* tick, not the current one. An unrun assertion is an
unchecked claim, not a weak check.

Two formal-infrastructure defects surfaced on the way, both fixed here:

1. `formal/run_formal_both.sh` has been broken since `/foss/designs` went
   read-only (NFS `manage_gids`, 2026-07-27/28): `sby` creates its work
   directory in the CWD, so **every** proof died with `OSError: Read-only file
   system`. It now stages into `$RUN_DIR`.
2. The runner iterated two of the four `.sby` files; `spi_slave` was already
   missing before `bringup_src` existed. Now it iterates all four — which
   surfaces a **pre-existing `spi_slave` BMC failure** (`a_addr_incr_wrap`,
   `spi_slave_formal.sv:213`, step 33). Untouched here; it needs its own
   triage and does not belong to this feature.

**Requirement 4 — NOT yet met at the re-modulator input. The netlist does not
route.** Jobs 5425 and 5436 both fail detailed routing with the same error:

```
[DRT-0073] No access point for clkbuf_2_2_0_IQ_CLK_regs/I
           (gf180mcu_fd_sc_mcu7t5v0__clkbuf_16)
```

Deterministic — same cell, twice. **And the failing netlist is smaller than the
combiner-insertion variant that routed clean:**

| stage | baseline 5379 | combiner 5404 (clean) | remod 5436 (DRT-0073) |
| --- | --- | --- | --- |
| yosys synthesis | 35,300 | 35,597 | **35,436** |
| openroad CTS | — | 49,020 | **48,900** |
| global routing | — | 49,137 | **49,022** |
| sta midpnr | — | 49,263 | **49,183** |

That contradicts `src/config/trouper_top.json`'s `_comment_density`, which
frames this failure class as "sensitive to netlist size". It is not: a netlist
161 cells *smaller* at synthesis fails where the larger one passed. The
mechanism is **placement perturbation around the `IQ_CLK` clock tree**, and the
practical consequence is that a smaller mux is not a reason to expect a design
to route. Do not carry "fewer cells" into a routability argument on this die.

Probes, in order (do not re-run the rejected ones):

- `DPL_CELL_PADDING` 2 → 3 (`trouper_top_dpl3_probe.json`) — the placement-room
  lever for a pin-access failure. Started as job 5439, cancelled to free the
  node; **not yet evaluated.**
- `PL_TARGET_DENSITY_PCT` 65 → 64 (`trouper_top_d64_probe.json`, job 5440) — a
  perturbation probe, *not* a density theory, for the reason above. 64 is
  untried; 63 and 60 were probed and rejected on the older dbgpins netlist, and
  72/78 hit DRT-0073. **Result pending.**

If a probe clears it, that is a single sample against a knob whose current value
is load-bearing: `_comment_density` records that every clean signoff since job
5198 has run at 65. A one-off pass at 64 needs a confirming re-run, or a
deliberate decision to move the signoff density — it must not be folded in
silently. If no cheap perturbation clears it, option (c) costs a routing fix,
and that belongs in the comparison against option (d) rather than being absorbed
as a detail.

If lab risk warrants a downstream path independent of frontend, detector, and PSRAM replay, add one small deterministic complex-sample generator at the combiner/re-modulator boundary. It is explicitly preferred over separate per-block BIST engines.

As built (2026-09-03), the insertion point is the re-modulator input:

```text
decimator IQ ──┐
               mux ──> mrc_combiner ──> backoff >>> ──┐
PSRAM replay ──┘                                      │
                                                     mux ──> sd_remod ──> REMOD_A_I/Q
BRINGUP_SRC (500 kS/s complex sample) ───────────────┘        │
                                                              └──> DBG0/DBG1 (COMB group)
```

Everything left of the second mux — decimator, DC removal, Schmidl-Cox,
`training_acc`, PSRAM, and the combiner — is bypassed while the source is armed
and cannot be stimulated by it. Those blocks keep the independent evidence paths
in the table at the top of this document.

The exact insertion point must be selected during microarchitecture review:

- **At the re-modulator input:** proves `sd_remod` and its output pads with the least logic and least disturbance to timing; it does not prove the combiner.
- **At the combiner input:** can prove deterministic bypass and fixed-weight combiner behavior as well as `sd_remod`; it needs a four-branch source and an explicit valid cadence.

The combiner input was selected. For either choice, the source SHALL be enabled only when `RX_HOLD=1` and `PACKET_ACTIVE=0`; reset SHALL select the normal path. Test-source controls SHALL be ignored or rejected outside that safe state, with a readable sticky status indication. The test source SHALL not alter PSRAM ownership, SC state, training state, weights, interrupts, or normal packet behavior.

Minimum deterministic modes are:

| Mode | Purpose |
| --- | --- |
| zero | Balanced idle-dither and output-connectivity check |
| signed DC, bounded to `±64` | Polarity and one-bit output-density check |
| repeating bounded complex tone | 500 kS/s → 32 MS/s modulation, external reconstruction, and I/Q relation check |
| optional seeded PRBS | Long-run switching stress only; not the primary noise-shaping diagnostic |

A tone and DC are mandatory if this feature is approved. PRBS alone is not an adequate sigma-delta functional test because it makes a failed transfer harder to diagnose and does not directly establish modulation fidelity.

## Required implementation evidence, if approved

1. Allocate control/status bits from the existing reserved register space; update the register map, firmware header, chip specification, traceability, and test plan in the same change. Do not silently repurpose a reserved address. The genuinely free slots are `0x06`–`0x07`, `0x10`–`0x17` and `0x7A`–`0x7F`, per the occupancy line in `planning/Register Map.md`. Do **not** trust that document's "Removed registers" and address-block summary tables, which still list `0x1A`–`0x1B` as reserved: both are live (`RX_HOLD`, `SC_ANT_SEL`). Those two stale lines should be corrected independently of this plan.
2. Add RTL assertions and cocotb tests for reset-to-normal selection, the `RX_HOLD && !PACKET_ACTIVE` gate, no normal-path functional change while disabled, every generator mode, and deterministic restart after reset.
3. Compare captured 1-bit outputs after external/Python decimation with the programmed DC/tone reference. Test I and Q independently and together.
4. Run top-level synthesis/P&R and report area, SS/hold timing, and all output paths affected by the mux. The source is not justified if it worsens current timing or routing risk beyond an agreed budget. **Run this evidence first, not last.** The re-modulator insertion point puts a mux directly on the `sd_remod` input, and `sd_remod` is already a known SS-corner offender — it surfaced at −29.57 ns once the `sc_lock`/`timing_ref` fanout cone was fixed. At 3.0 V SS the mux is not free, and a measured SS WNS delta is the cheapest input to the decision gate below. If it is unaffordable there, evaluate the combiner insertion point on the same basis before writing any other verification.
5. Add a board procedure: set `RX_HOLD`, select mode, capture `REMOD_A_I/Q` using the shared `IQ_CLK` reference, compare with the known signature, then clear test mode before releasing `RX_HOLD`.

## Decision gate

Do not implement the source merely because it is convenient in simulation. Approve it only if the first-silicon team judges that the ability to prove the combiner/re-modulator without a working frontend/PSRAM chain outweighs the additional register, mux, verification, timing, and P&R work. Until then, the sequence above and the existing FPGA IQ stimulus remain the baseline.

## Related material

- `planning/Test Plan.md` — block-level RTL/FPGA evidence and remodulator reconstruction criteria.
- `planning/two-pin-digital-debug-plan.md` — debug-probe source groups and timing limitation.
- `planning/Register Map.md` — `RX_HOLD`, `SC_FORCE_LOCK`, PSRAM debug, and reserved register addresses.
