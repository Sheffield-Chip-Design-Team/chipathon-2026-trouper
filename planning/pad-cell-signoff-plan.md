# Pad-Cell Signoff Plan — SPICE LVS, DRC and Simulation

**Status:** entry criteria **met** (Open Risk #52 closed 2026-09-04 — integrator
confirmed **27** slots, `A40_ACV.def` regenerated from the integrator tooling,
first full A40 P&R against it clean on job 5511). The generator artifacts —
`A40_ACV_padring.v`, `A40_ACV_pad_map.yaml`, `A40_ACV_interface.yaml` — are in
`rtl-test/ol_trouper_top/a40_integrator/`, so the cell-per-slot map and the
per-terminal contract are now pinned.

- **Work item 1 (LVS across the pad boundary) is integrator-owned** (2026-09) —
  the integrator runs the assembled-die LVS. Trouper's job is the boundary
  contract + the pre-LVS connectivity check (`test_padring_connectivity.py`),
  then confirming the integrator's LVS result covers the A40 slot arc.
- **Work items 2–3 (Magic DRC on the assembled die, targeted SPICE)** remain
  Trouper-side and are ready to start.
- Residual: a literal integrator human sign-off on the 27 slot names / bonding
  (Open Risk #52 note).

**Note on pad count:** this document predates the 2026-09-03 cut to 27 pads —
`DBG1` was merged onto the `IRQ_OUT` pad and has no slot or control ports of its
own. N15 = `ARRAY_ACQ_N`, N16 = `DBG0`; there is no N17 functional slot. Read
"28" / "N17" / "`DBG1_OUT`" below as historical.

### Simulation-tier coverage now in place (2026-09)

Logic-level, not a substitute for work items 1–3 (which are the electrical /
layout signoff), but they close the "no run has ever exercised a pad cell" gap
for functional behaviour:

- `cocotb/io_cell_controls/` — legal-mode + PU/PD + PDRV smoke bench for all
  four signal cells (`bi_t`, `bi_24t`, `in_c`, `in_s`) against the pinned PDK
  model.
- `cocotb/padring_integration/` — `trouper_top` driven **through**
  `A40_ACV_padring.v` + the `gf180mcu_fd_io` models at the physical pad nets
  (icarus): reset + CHIP_ID over pad-net SPI, PSRAM QPI init through the four
  `bi_t` SIO pads, `sc_lock` through the `in_c` IQ path, and one full
  end-to-end packet.
- `sim/tests/test_padring_connectivity.py` — static, non-circular cross-check
  that every `trouper_top` pad-control port maps 1:1 to the right
  `A40_ACV_padring.v` cell terminal with the right direction, that the cell type
  matches `io_type`, and that the RTL tie-off values are electrically legal for
  the assigned cell.

### Full-die DRC still owed

The reticle-level review DRC (`tools/run_a40_full_gds_drc.sh` over
`SSCS_2026_01`) has **not** been re-run for the v6 tile drop — SGE jobs
5663/5664 (2026-09-06) came back CANCELLED. A re-run is owed (work item 2
territory); it is not executed as part of the simulation-tier work above.

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
| **slot** | A position in the A40 padring allocated to this project (27 of them) |
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

## Entry criteria — met 2026-09-04

- [x] Integrator slot assignment confirmed — **27 slots** (N15 `ARRAY_ACQ_N`,
      N16 `DBG0`; `DBG1` merged onto `IRQ_OUT`). Open Risk #52 closed.
- [x] Regenerated `A40_ACV.def` (159 Metal2 `PINS`, functional names matching
      `trouper_top.v` verbatim) — `src/config/A40_ACV_rtlnames.def`, produced by
      `rtl-test/scripts/regen_a40_def.sh`. The synthetic-coordinate stopgap
      (`A40_ACV_rtlnames_dbgpins.def` + `a40_append_provisional_pads.py`) is
      retired.
- [x] Cell type per slot confirmed — `A40_ACV_pad_map.yaml`: `in_c` W13–W21,
      `in_s` W22/N09–N11, `bi_t` N01/N02/N04–N08/N12/N13/N15/N16, `bi_24t` N03,
      `dvdd` N14, `dvss` W12.
- [x] Padring netlist available — `ip/chipathon-2026-padring-system` submodule
      +  the generated `rtl-test/ol_trouper_top/a40_integrator/A40_ACV_padring.v`.
- [ ] Residual: a literal integrator human sign-off on the 27 slot names / IO
      cell types / bonding (Open Risk #52 note).

## Work items

### 1. SPICE-level LVS across the pad boundary — INTEGRATOR-OWNED

**Ownership resolved (2026-09): the integrator runs the full-chip / assembled-die
LVS**, including across the pad boundary (core macro + padring, layout vs. a
netlist that instantiates the `gf180mcu_fd_io__*` cells). Trouper does **not**
run this and does not need to — Trouper's job is to hand over a correct
contract for the integrator to LVS against, which is:

- `src/config/A40_ACV_rtlnames.def` — the 159-pin boundary template, functional
  names matching `trouper_top.v` verbatim (`regen_a40_def.sh`).
- `A40_ACV_pad_map.yaml` / `A40_ACV_interface.yaml` — slot ↔ pin ↔ cell ↔
  terminal, machine-readable.
- `sim/tests/test_padring_connectivity.py` — asserts, pre-LVS, that every
  `trouper_top` pad-control port maps 1:1 to the right `A40_ACV_padring.v` cell
  terminal with the right direction and cell type. This is the Trouper-side
  check that the contract we give the integrator is internally consistent; the
  integrator's LVS is what proves the assembled GDS matches it.

The class of error this closes — a `_OE`/`_IE`/`_CS`/`_SL`/`_PU`/`_PD`/`_PDRV*`
tie-off landing on the wrong cell terminal in layout — is caught by the
integrator's die-level LVS, not by anything in this repo (Trouper's own LVS has
0 IO cells, Open Risk #48). **Action for Trouper: confirm the integrator's LVS
result covers the A40 slot arc once it is available, and record the job/report
reference here.**

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
#52 (slot allocation — closed), #53 (`ARRAY_ACQ_N` pad electrics);
`planning/Pinout.md`; `planning/a40-padframe-integration-2026-08.md`;
`planning/two-pin-digital-debug-plan.md`; `planning/array-acquisition-sync.md`;
`planning/padring-gls-extension.md`.
