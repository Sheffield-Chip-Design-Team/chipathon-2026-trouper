# Repair max-wire-length sweep + DRV residual — 2026-10-11

**Status:** sweep done, canonical unchanged (450 µm). DRV residual on the host-SPI
read path is a **regression vs job 5842** and is open — see "DRV residual" and
Open Risks #82.

## Why

Job 5861 (RTL: `reg_bank` IRQ set-wins + `dc_removal` int8 saturation, on top of
the 2026-10-03 edits) is physically signoff-clean on the canonical A40 config
but, versus reference job 5842 (same config, previous RTL):

- SS setup WNS −15.21 → −19.06 ns (TNS −1159 → −1199, violations 326 → 317);
- max-slew / max-cap 2/0 → 9/5 at SS, **0/0 → 4/3 at nom_tt** and max_ff.

LibreLane exposes no placement seed (`global_placement` is deterministic; no
`SEED`/`RANDOM` variable in `resolved.json`), so the only way to probe the
spread is a config knob. `{GRT_,}DESIGN_REPAIR_MAX_WIRE_LENGTH` was swept.

## Sweep

Canonical `src/config/trouper_top.json`; only both wire-length keys changed.

| Job | Wire length | SS WNS | SS TNS | SS vios | slew/cap tt | ff | ss | worst SS slew slack |
|---|---|---|---|---|---|---|---|---|
| 5842 | 450 (old RTL) | −15.21 | −1159 | 326 | 0/0 | 0/0 | 2/0 | −0.25 |
| 5862 | 350 | −20.54 | −2388 | 400 | 6/3 | 8/3 | 8/4 | −11.30 |
| 5863 | 400 | −19.29 | −1401 | 341 | 5/2 | 5/3 | 7/3 | −5.66 |
| **5861** | **450** | −19.06 | −1199 | 317 | 4/3 | 4/3 | 9/5 | −6.13 |
| 5864 | 550 | −19.05 | −1293 | 304 | 5/4 | 10/4 | 16/5 | −6.23 |
| 5865 | 650 | −18.26 | −1117 | 303 | 2/1 | 2/2 | 12/5 | −6.31 |

All six: magic/route DRC 0, LVS 0, antenna 0, XOR 0, hold MET (worst +0.106 ns).
Known failure below the range: 250 µm → `GRT-0116` congestion (job 5839).

**Result:** wire length is not a lever. ≤ 400 µm hurts (350 doubles TNS);
450–650 is flat within run-to-run perturbation (the RTL edit alone moved WNS
3.85 ns). The SS worst path is in `u_remod` (`term_step`) in every run; no
setting clears DRV. Canonical stays at 450.

## DRV residual (nom_tt 4/3 on job 5861)

Every violating driver is a `nor4_1` driving a single load over a long wire
(SS cap 0.12 pF vs 0.082 pF limit; nom_tt slew 9.66 ns vs 8.6 ns). Followed
forward through the final netlist they are the **last stage of the `reg_bank`
read-data mux into the host-SPI MISO shift register**:

| Driver | Load (D pin) |
|---|---|
| `_39544_` | `net37` (MISO shreg bit) |
| `_39460_` | `u_spi.miso_shreg[6]` |
| `_39320_` | `u_spi.miso_shreg[4]` |
| `_39238_` | `u_spi.miso_shreg[3]` |
| `_33420_` | `psram_overflow`, `rpl_valid` |

This is the same class the 2026-10-04 re-check found ("~11 fanout-1 ×1 drivers
on 300–470 µm wires: reg_bank read mux, Z readback, debug mux, tacc operand
select"). The IRQ edit re-synthesised the read mux and the placement moved,
which pushed these few nets over at nom_tt.

**Mechanism (unchanged from `drv-margin-sweep-2026-09-03.md`):** the last
repair is step 44 `ResizerTimingPostGRT` on global-route *estimated* RC; this
LibreLane build has no post-detailed-route repair, so the estimate→extracted
gap on long routes is never fixed. The `GRT_` margin lever was re-tested
2026-10-04 (job 5838) and rejected.

**Functional impact:** low. The read mux → MISO path is timed at the 2 MHz
host SPI, with large slack; the risk is an out-of-characterisation slew on 4
flop D pins, not a logic error. It is still a signoff DRV violation and breaks
the "nom_tt DRV-clean" bar job 5842 met.

**Fix options, cheapest first:**

1. **Upsize these drivers only** — `MANUAL_GLOBAL_PLACEMENTS`-style point fix
   is placement, not sizing; a post-route ECO (`repair_design` on the final ODB
   with extracted SPEF, then incremental global + detailed route) targets just
   these nets. Needs a custom OpenROAD step; no RTL/SDC change.
2. **Keep `u_spi` near the `reg_bank` read mux** (placement constraint), so the
   long wire disappears.
3. **RTL:** register the read byte next to `reg_bank` before it crosses to
   `u_spi`. Touches SPI read latency (cf. the fixed SPI-read-late issue) —
   needs the `spi_cdc` / `spi_slave` regressions and formal rerun.
4. **Waive** as before (`_comment_drv_closure`), recording that nom_tt is no
   longer clean.

Recommendation: try (1) first.
