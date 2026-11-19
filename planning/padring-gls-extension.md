# Padring-inclusive GLS — follow-on scope (not yet done)

**Status:** scoped, not started. Pointer so it is not lost.

## What exists

Open Risk #54: `rtl-test/tb/tb_trouper_spi_gl.v` + `rtl-test/gl_item54_inputs/`
(`trouper_top.nl.v`, post-route SDF `sdf/nom_tt_025C_3v30/`, `spef/min/`,
`trouper_top.sdc`) — a black-box, port-only Icarus host-SPI gate-level harness
with `$sdf_annotate`, run on SGE via `rtl-test/gl_spi_sdf_item54.sh`. It is
**macro-level**: the routed `trouper_top` netlist, no pad cells.

The functional (RTL) counterpart through the real padring now exists —
`cocotb/padring_integration/` drives `trouper_top` through
`rtl-test/ol_trouper_top/a40_integrator/A40_ACV_padring.v` + the
`gf180mcu_fd_io` models. There is still **no gate-level** pass through the pad
cells.

## The follow-on

Wrap the item-54 routed netlist in `A40_ACV_padring.v` + the pinned PDK
`gf180mcu_fd_io.v`, driven at the physical pad nets (SPI at N09/N10/N11, RESETB
at W22, IQ at W13–W21, bidir at N01–N16), and re-run the host-SPI SDF vectors.
Reuse `tb_trouper_padring.v`'s slot↔signal wiring; swap the DUT from behavioural
`trouper_top` to the routed `trouper_top.nl.v` and keep `$sdf_annotate` on the
macro instance.

Out of scope for the 2026-09 padring-integration work because it needs:

- a post-route `trouper_top` netlist + matching SDF that is current with the
  tapeout candidate (the item-54 inputs are refreshed per promote — see the
  `pnr-post` skill / `git ls-files final/`);
- a decision on whether pad-cell SDF (the padring is the integrator's, no SDF
  for it) matters or the pad cells stay zero-delay.

Blocking dependency: none beyond a fresh routed netlist. Pick up alongside the
next `final/` promote.

**See:** Open Risk #54; `planning/pad-cell-signoff-plan.md`;
`rtl-test/gl_spi_sdf_item54.sh`; `cocotb/hdl/tb_trouper_padring.v`.

**Related (LVS, not GLS):** `planning/a40-bridge-tile-lvs-selfcheck.md` — a
layout-level self-check of the PDN bridges + padframe seam on the assembled v6
tile with the bridged A40 swapped in. Phase 1 (power-seam connectivity trace)
PASSES; phase 2 is full KLayout LVS of the A40-only tile.
