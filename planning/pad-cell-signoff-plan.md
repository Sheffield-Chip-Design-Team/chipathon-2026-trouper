# Pad-Cell Signoff Plan — SPICE LVS, DRC and Simulation

**Status:** planned, **gated on the integrator confirming the IO padframe**.
Nothing here can start until we have the real padring: the cell instances, their
slot assignment, and the assembled die. See "Entry criteria".

## Why this exists

Everything this project has signed off so far — every DRC, LVS, antenna and
timing number, including job 5279 — covers the **Trouper macro only**.
`trouper_top` instantiates **zero** `gf180mcu_fd_io__*` cells. The netlist
handed to LVS has none, so LVS cannot have checked one; the layout has none, so
Magic DRC cannot have checked one either. Verified 2026-08-30 on job 5279: 0 IO
cells in `trouper_top.pnl.v`, 0 occurrences of `gf180mcu_fd_io` in
`lvs.netgen.rpt`.

What we *do* have at the macro boundary are **boundary pins** — DEF `PINS`
entries, Metal2 rectangles at the die edge — plus core logic driving what will
become the pad cells' control inputs (`_OE`, `_IE`, `_CS`, `_SL`, `_PU`, `_PD`,
`_PDRV[1:0]`). The pad cells themselves live in the shared A40 padring and are
instantiated by the integrator, not by us.

That distinction is easy to lose in the word "pad". Vocabulary used from here:

| Term | Means |
|---|---|
| **slot** | A position in the A40 padring allocated to this project (28 of them) |
| **boundary pin** | A `PINS` entry on the Trouper macro edge; what our P&R places and checks |
| **pad cell** | A `gf180mcu_fd_io__*` instance in the padring; **not** in any Trouper netlist or layout |
| **pad-control signal** | A core output that drives a pad cell's control input |

So "DRC clean" in any Trouper run means *the macro is clean*. It is not a
statement about pad cells, and it never has been.

## What is unvalidated today

Every electrical claim the design makes about its pins rests on datasheet
reading and inference, not simulation. Specifically:

1. **`ARRAY_ACQ_N` open-drain emulation.** RTL ties `A=0` and toggles `OE` to get
   drive-low-vs-Hi-Z out of a `bi_t`. No SPICE has confirmed the Hi-Z state is
   genuinely high impedance, that the reset/power-on state does not drive, or
   that two chips asserting simultaneously only sink current (Open Risks #53).
2. **The internal pull-up strength on `ARRAY_ACQ_N`.** `PU=1` is enabled on this
   pin alone. Its resistance is not in our data, and the external pull-up must be
   sized against N of these in parallel while still meeting V_OL at the 4 mA
   `PDRV=00` sink.
3. **`DBG0_OUT`/`DBG1_OUT` edge quality.** Claimed fast slew and 8 mA are
   adequate for a 32 MHz alternating pattern at a probe load. Unmeasured.
4. **The `IE=OE=1` state of `bi_t`.** Uncharacterised in the PDK. The RTL avoids
   it on the PSRAM lanes by driving `IE = ~OE`, and the cocotb bench asserts that
   invariant — but that is a logic check, not an electrical one.
5. **`bi_t` itself.** Job 4347 characterised `bi_24t`. Open Risks #27 already
   asks for a `bi_t` cross-check, because `bi_24t` needed an extended `pfet_06v0`
   W bin (a documented PDK deviation) and `bi_t` fits the stock bin.

## Entry criteria — none of this starts before all of these

- [ ] Integrator confirms the **28-slot assignment**, including N15/N16/N17
      (`ARRAY_ACQ_N`, `DBG0_OUT`, `DBG1_OUT`) — Open Risks #52, #57.
- [ ] Integrator supplies a regenerated `A40_ACV.def` containing all 28 pads, so
      our locally extended template
      (`src/config/A40_ACV_rtlnames_dbgpins.def`) can be retired.
- [ ] Integrator confirms the **cell type per slot** — which slots are `bi_t`,
      `bi_24t`, `in_c`, `in_s`. `io_type` in `info.yaml` is our request; the
      padring is what actually gets built.
- [ ] The padring submodule (`ip/chipathon-2026-gf180mcu-padring`) is populated
      with the assembled padring, or the integrator provides its GDS/netlist.

Until then this document is the record of what is owed, not a task list to pick
up.

## Work items

### 1. SPICE-level LVS across the pad boundary

Today's LVS compares the Trouper macro against itself. The check that matters
for silicon is the **assembled die**: core macro + padring, layout versus a
netlist that instantiates the pad cells.

- Build a chip-level source netlist that instantiates `gf180mcu_fd_io__*` per the
  confirmed slot map and connects each to the corresponding Trouper boundary pin.
- Run netgen LVS on the assembled GDS against that netlist.
- **Pass criterion:** circuits match uniquely, with no unmatched pins, nets or
  devices *across the pad boundary* — in particular every `_OE`/`_IE`/`_CS`/
  `_SL`/`_PU`/`_PD`/`_PDRV*` connection landing on the intended cell terminal.
  A tie-off wired to the wrong terminal is exactly the class of error today's
  macro-only LVS cannot see.
- Ownership is likely shared: the integrator may run die-level LVS. **Confirm who
  owns it** rather than assuming — a check both parties believe the other is
  doing is the worst outcome.

### 2. Magic DRC over the assembled die

- Run Magic DRC on core + padring together, not the macro alone.
- **Pass criterion:** 0 errors, with specific attention to the macro-to-padring
  seam and to any density or antenna rule that only appears once the pad cells
  are present.

### 3. SPICE simulation of the specific claims

Reuse the job-4347 flow rather than building a new one:
`characterization/io_levelshift/` (`run_io_levelshift.sh`, `tb_io_*.sp`,
`parse_results.py`) already does corner/temperature sweeps on a real IO cell
netlist and parses results into a table. Add a sibling directory,
`characterization/io_pad_signoff/`, following the same shape.

| # | Simulation | Answers | Closes |
|---|---|---|---|
| 3a | `bi_t` open-drain emulation: `A=0`, sweep `OE`; measure PAD leakage in Hi-Z, V_OL when driving, and behaviour with `RESETB` asserted and during power-on ramp | Is the emulation genuinely open-drain, and can it drive during reset? | #53 |
| 3b | Two-driver contention: two `bi_t` instances on one net, both `A=0`, one or both `OE=1`, external pull-up present | Confirms simultaneous assertion only sinks current, no contention | #53 |
| 3c | Pull-up budget: measure the internal `PU` device resistance, then solve the wired-AND net for N chips — internal pull-ups in parallel with the board resistor — against V_IL/V_OL at `PDRV=00` (4 mA) | Sizes the external resistor; sets the maximum chip count | #53 |
| 3d | `DBG0/DBG1` edge quality: 32 MHz alternating pattern, `SL=0` fast, `PDRV=01` (8 mA), swept load capacitance to the intended probe + trace | Is fast slew / 8 mA adequate, and is the 0-ohm series footprint needed? | TRPR-DBG-010 |
| 3e | `IE=OE=1` on `bi_t`: hold both high and measure static current and PAD/Y behaviour | Quantifies the state the RTL currently avoids by construction | #27 |
| 3f | `bi_t` cross-check of the job-4347 level-shift result | Independently rules out the extended-W-bin deviation `bi_24t` needed | #27 |

Corners: match job 4347 — 3 process × 3 temperature, at the committed rail
voltages. If the split-rail contingency is still live, add the rail splits too.

### 4. Documentation and traceability on completion

- Record results in `characterization/io_pad_signoff/RESULTS.md`, the way
  `io_levelshift/RESULTS.md` records job 4347.
- Close or downgrade Open Risks #53; update #57's slot-confirmation half.
- Update `planning/Pinout.md` with measured drive/slew/pull-up numbers in place
  of the current inferred ones.
- Fill TRPR-DBG-009/010 and the corresponding `ARRAY_ACQ_N` rows in
  `planning/Traceability.md`.

## What this plan does not cover

ESD, latch-up, and pad-ring IR drop remain foundry/databook questions, already
tracked in Open Risks #27 and #47. SPICE on a cell netlist does not answer them.

**See:** Open Risks #27 (IO level-shift / `bi_t` cross-check), #47 (IR drop),
#52 (slot availability), #53 (`ARRAY_ACQ_N` pad electrics), #54 (28/28 full,
slots unconfirmed); `planning/Pinout.md`;
`planning/two-pin-digital-debug-plan.md`; `planning/array-acquisition-sync.md`.
