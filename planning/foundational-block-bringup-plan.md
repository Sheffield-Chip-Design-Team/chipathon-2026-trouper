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

## Candidate shared internal stimulus source — decision not taken

If lab risk warrants a downstream path independent of frontend, detector, and PSRAM replay, add one small deterministic complex-sample generator at the combiner/re-modulator boundary. It is explicitly preferred over separate per-block BIST engines.

```text
normal replayed sample ────────────────┐
                                      mux ──> combiner / sd_remod ──> REMOD_A_I/Q
BRINGUP_SRC (500 kS/s complex sample) ─┘
```

The exact insertion point must be selected during microarchitecture review:

- **At the re-modulator input:** proves `sd_remod` and its output pads with the least logic and least disturbance to timing; it does not prove the combiner.
- **At the combiner input:** can prove deterministic bypass and fixed-weight combiner behavior as well as `sd_remod`; it needs a four-branch source and an explicit valid cadence.

For either choice, the source SHALL be enabled only when `RX_HOLD=1` and `PACKET_ACTIVE=0`; reset SHALL select the normal path. Test-source controls SHALL be ignored or rejected outside that safe state, with a readable sticky status indication. The test source SHALL not alter PSRAM ownership, SC state, training state, weights, interrupts, or normal packet behavior.

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
