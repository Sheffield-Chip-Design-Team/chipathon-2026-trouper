# Whole-Core SPICE Bring-Up — 2026-08

**Status:** feasibility work in progress.  This is not padframe signoff.

## Objective

Demonstrate a transistor-level SPI register write/read against the extracted
`trouper_top` core before the assembled A40 padframe is available, and compare
ngspice with Xyce where both can run the same GF180 device models.

The temporary harness uses four standalone `gf180mcu_fd_io__bi_t` instances for
CS, SCK, MOSI and MISO.  It does **not** represent the eventual padring,
package, ESD network, pad placement, or board parasitics.  The signoff gate and
the work needed once a real padring exists remain in
[`pad-cell-signoff-plan.md`](pad-cell-signoff-plan.md).

## Inputs and harness

| Item | Location / status |
|---|---|
| Extracted core | `final/spice/trouper_top.spice`; Magic extraction from LibreLane.  It contains extracted interconnect plus abstract standard-cell views, so transistor models must be supplied separately. |
| Standard-cell transistor deck | `$PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/spice/gf180mcu_fd_sc_mcu7t5v0.spice` |
| Temporary IO-cell deck | `ip/sscs-chipathon-2026/resources/Integration/Chipathon2025_pads/xschem/gf180mcu_fd_io.spice` |
| Whole-core harness | `rtl-test/scripts/run_fullchip_spi_trial.sh` (currently uncommitted) |
| Xyce GF180 model bundle | `sim/models/gf180_xyce/` (currently uncommitted); copied from the upstream GF180 primitive-model repository's `models/xyce/` directory |
| Xyce standard-cell smoke test | `sim/gf180_xyce_stdcell_smoke.cir` (currently uncommitted) |

The harness provides 3.3 V, reset release, a 32 MHz IQ clock, and SPI sources.
It temporarily holds unrelated primary inputs low and observes `MISO_PAD`.

## Simulator environment

The pinned image is `hpretl/iic-osic-tools:chipathon26`.

- **ngspice:** v46, built with the KLU direct sparse solver.  It accepts the
  shipped GF180 `libs.tech/ngspice/sm141064.ngspice` wrapper.
- **Xyce:** v7.10-open-source with MPI and KLU2/Basker enabled.  The installed
  GF180 PDK has no `libs.tech/xyce` directory, so the ngspice wrapper cannot be
  used directly.
- **Upstream Xyce models:** the upstream GF180 primitive-model repository
  provides `design.xyce`, `sm141064.xyce`, `sm141064_mim.xyce`, and
  `smbb000149.xyce`, plus standard-cell regressions.  This established that
  GF180/Xyce support exists; it is absent from this particular installed PDK
  bundle, rather than unsupported by Xyce.

## Results to date

| Job / test | Result | Evidence / interpretation |
|---|---|---|
| 5290 | preflight passed | The extracted deck parses as a subcircuit-only deck.  A physical standard-cell model deck is required for transient simulation. |
| 5295 / 5296 | ngspice elaborated, then failed | Reached about 4.7–4.8 GB RSS in 29 s before missing GF180 resistor parameters.  This established that 24 GB is ample for initial elaboration but four requested CPUs did not increase ngspice CPU beyond about one core. |
| local ngspice standard-cell + IO check | passed | The complete ngspice GF180 selection, the `mcu7t5v0` transistor deck, and `bi_t` IO deck work together in a small circuit. |
| local Xyce inverter smoke | passed | The installed `mcu7t5v0` inverter completed a transient run using the upstream Xyce models plus explicit temporary `nfet_05v0`/`pfet_05v0` to `nfet_06v0`/`pfet_06v0` aliases. |
| 5300 | Xyce failed | Missing diode models because `diode_typical` was not selected. |
| 5301 | Xyce failed later | Selecting `diode_typical`, `res_typical`, and `moscap_typical` fixed the diode error.  It then failed at `sm141064.xyce:8868`: MOS-cap device parameter `C` references unrecognised `L` and `W` symbols in this full-core context. |
| 5301 resource use | capacity confirmed | Peak 5.92 GB / 24 GB and 400.6% CPU on four pinned CPUs; this is job-wide, largely from the ngspice leg, since Xyce aborts during elaboration. |

Scheduler jobs intentionally return status 0 even when a simulator fails,
because the harness records each simulator's result separately in `result.txt`.
For example, job 5301 records `ngspice_rc=1` and `xyce_rc=1`.

## Current blockers

### ngspice: full extracted-body assembly

The full transient deck aborts at the first reported standard-cell instance:

```text
unknown subckt: ... gf180mcu_fd_sc_mcu7t5v0__and2_1
```

This is **not** a missing GF180 model or a stale SGE input:

- The local and SGE copies of `trouper_top.spice` have identical SHA-256.
- A standalone `and2_1`, the exact `trouper_top` port header with one nested
  `and2_1`, and an IO-inclusive model/include test all elaborate successfully.
- A replay of the Magic-filtered extracted prefix through the formerly failing
  `X_53870_` `and2_1` instance also elaborates successfully.

Therefore the failure is introduced later while assembling the *complete*
filtered extracted body.  The next step is to bisect that body to find the first
line/instance that corrupts ngspice elaboration, then exclude or repair only the
extraction artifact.  Do not substitute a behavioural standard-cell model: the
purpose of this experiment is transistor-level SPI feasibility.

### Xyce: MOS-cap wrapper scope

The upstream Xyce bundle is a useful and validated starting point, but the
full-core deck instantiates a MOS-cap path that its Xyce wrapper does not accept
with the supplied `L`/`W` parameter scope.  The immediate task is a minimal
MOS-cap reproducer from the extracted/IO netlist, followed by a reviewed wrapper
fix or an explicit nominal MOS-cap replacement.  This must be documented as a
model adaptation, not treated as foundry-qualified signoff.

## Recommended order of work

1. Finish ngspice body bisection and obtain a complete ngspice elaboration.
2. Run a short transient first (reset plus one SPI write/read), then extend to
   the planned 25 us waveform after convergence is stable.
3. Only then repair the Xyce MOS-cap wrapper and repeat the same deck with four
   MPI ranks for an apples-to-apples resource comparison.
4. When the real padframe arrives, replace temporary standalone IO cells with
   the assembled padring and follow the pad-cell signoff plan.

## Resource observation

The completed Xyce trial container was pinned to CPUs `0,2,4,6`, with hard
limits of 4 CPUs and 24 GiB.  While job 5301 was live it used approximately
400% CPU and 5.17 GiB (21.5%) memory.  Capacity is not the current limiting
factor; correct model/deck assembly is.
