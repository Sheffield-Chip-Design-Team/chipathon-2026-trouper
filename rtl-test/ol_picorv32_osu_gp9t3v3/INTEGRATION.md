# Integrating the OSU 3.3 V SCL into LibreLane P&R

Goal: get `picorv32_wrap` through **real P&R** on `gf180mcu_osu_sc_gp9t3v3`
(3.3 V-native cells) to obtain buffered Fmax + die area — validating the
standalone-synthesis finding (~30 % faster than 5 V `mcu7t5v0`) and testing the
"bigger cells spread pins → ease the clkbuf DRT-0073 wall" hypothesis (the wall
is confirmed local pin-access, not global tracks — see memory `drt-density-wall`).

## What the OSU SCL ships (gp9t3v3)

- `tlef/gf180mcu_osu_sc_gp9t3v3.tlef` — tech LEF with **SITE
  `gf180mcu_osu_sc_gp9t3v3`, 0.10 × 6.300 µm (9-track)**.
- `lef/…​.lef` (merged cell LEF), `gds/…​.gds` (merged + per-cell),
  `lib/…_TT_25C.ccs.lib` (**TT_25C only — no SS/FF**), `spice/`, `verilog/`.
- Cells: full gate set + `dff/dffn/dffsr`, `dlat/dlatn`, `buf/clkbuf/clkinv`
  1–16×, `inv` 1–16×, `tbuf_1`, `tinv_1`, `tieh`/`tiel` (**output pin Y**),
  `fill_1..16`, `decap_1`, `ant` + `antfill` (antenna), `mux2`, adders.

## SCL variable template (from PDK `gf180mcu_fd_sc_mcu9t5v0/config.tcl`)

| Variable | 5 V value | OSU equivalent | Note |
|---|---|---|---|
| PLACE_SITE | GF018hv5v_green_sc9 | `gf180mcu_osu_sc_gp9t3v3` | width 0.10, height 6.300 |
| FP_WELLTAP_CELL | `…__filltie` | **MISSING** | OSU has no welltap |
| FP_ENDCAP_CELL | `…__endcap` | **MISSING** | OSU has no endcap |
| SYNTH_TIEHI_PORT | `…__tieh Z` | `…__tieh Y` | OSU pin is **Y** |
| SYNTH_TIELO_PORT | `…__tiel ZN` | `…__tiel Y` | OSU pin is **Y** |
| FILL_CELL | `…__fill_*` | `…__fill_*` | ok |
| DECAP_CELL | `…__fillcap_*` | `…__decap_*` | name differs |
| DIODE_CELL / pin | `…__antenna` / I | `…__ant` / ? | confirm pin |
| CTS_ROOT_BUFFER | `…__clkbuf_16` | `…__clkbuf_16` | ok |
| CTS_CLK_BUFFER_LIST | clkbuf_2/4/8 | clkbuf_2/4/8 | ok |

## Gaps / decisions

1. **No welltap, no endcap.** Either the cells are *tapless* (self-tied wells —
   then disable tap/endcap insertion) or the PDK requires periodic well ties
   (then we have a problem — the 5 V `filltie`/`endcap` are a different 7 T row
   height, incompatible). **First test assumes tapless** (omit FP_WELLTAP_CELL /
   FP_ENDCAP_CELL, no tap insertion); if Magic/KLayout flags missing well ties,
   revisit. This is the main integration risk.
2. **TT_25C corner only** → no SS/FF signoff. First test runs single-corner; for
   real signoff the missing corners must be characterized (we have the SPICE
   flow from the SRAM work).
3. **Tie pin is Y, not Z/ZN** — easy to get wrong; note it.

## Approach

Two ways to feed LibreLane a non-PDK SCL:

- **(A) Register as a PDK SCL** — write a `config.tcl` for
  `gf180mcu_osu_sc_gp9t3v3` mirroring the 5 V one, install it into the PDK at
  job start, run `librelane --scl gf180mcu_osu_sc_gp9t3v3`. Cleanest variable
  handling; needs a runtime PDK-prep step in the SGE script (container PDK is
  ephemeral).
- **(B) Override every SCL variable in `config.json`** — fully self-contained /
  reproducible, but must get all LibreLane variable names exactly right and
  supply the tlef SITE.

**Recommendation: (A)** — it reuses LibreLane's expected variable plumbing and
the as-shipped 5 V config as a proven template; the only custom bit is a
prep step that drops the OSU `config.tcl` + lib/lef/gds/tlef into the PDK tree
before invoking the flow.

## Plan

1. Write `gf180mcu_osu_sc_gp9t3v3/config.tcl` (SCL vars, tapless handling).
2. SGE job: stage OSU SCL into `$PDK_ROOT/$PDK/libs.{ref,tech}` → `librelane
   --scl gf180mcu_osu_sc_gp9t3v3 ol_picorv32_osu_gp9t3v3/config.json`.
3. Keep the OCD SRAM macro as-is (CPU SRAM); add `--skip Magic.SpiceExtraction`
   (same macro-OBS artifact as mimo, see ../ol_mimo_rx_top/CONGESTION_EXPERIMENT.md).
4. Target CLOCK_PERIOD 31.25 ns (32 MHz) — the speed 5 V cells can't hit — to
   see if 3.3 V closes it. Single corner (TT).
5. Iterate on integration errors (expect a few cycles), then compare die
   area / Fmax / congestion vs the 5 V picorv32 baseline.
