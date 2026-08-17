# L-shape floorplan trial (1100×1100 + 550×550 leg) — 2026-08-16

Supersedes the June verdict in `Physical Design Change List.md:137`
(`l-shape: failed on delaybuf_0_clk_32m access`). That verdict was for the
1650×1100 full rectangle. **The L-shape is routable and improves WNS.**

## Geometry

`DIE_AREA 0 0 1650 1100` + `FP_OBSTRUCTIONS [[1100, 550, 1650, 1100]]`

- Main lobe 1100×1100, leg 550×550 (east, southern half)
- Usable area **1,512,500 µm²** vs 1,320,000 µm² for the 1200×1100 baseline
- Padring: **5 slots vs 6** — the obstructed NE quadrant costs one edge segment

## Results

All three runs are the v26 SDC (20 MCP groups, `sc_clear` withdrawn),
FD cells `gf180mcu_fd_sc_mcu7t5v0`, `max_ss_125C_3v00`.

| job | config | WNS (ns) | TNS (ns) | util | DRC | antenna |
|---|---|---|---|---|---|---|
| 4376 | 1200×1100 baseline | −20.12 | −3279 | 86.3% | 0 | — |
| 4387 | L-shape, default pins, density 50 | −18.26 | −5155 | 62.7% | 0 | 8 |
| 4392 | L-shape, shaped pins, density 78 | **−14.59** | −3578 | 63.1% | 0 | **4** |

**+5.53 ns WNS vs baseline; +3.67 ns from pin shaping + density alone.**
TNS is *worse* than baseline on both L runs — the win is concentrated on the
critical path, not spread across the cone population.

⚠️ **n = 1 per config.** Prior sessions established WNS on this design behaves
partly as a repair-lottery (see `project_b4_b6_implemented_measured`), so the
3.67 ns delta is not yet separable from run-to-run variance. Repeat before
treating it as a committed number.

## Placement outcome (job 4392)

Parsed `final/def/trouper_top.def` (2000 DBU/µm, 84,507 components), joined to
hierarchical net names from `final/nl/trouper_top.nl.v`. Leg = x > 1100, y < 550.

| group | flops | centroid (x, y) | % in leg |
|---|---|---|---|
| `u_dec` CIC ch3 | 28 | (1555, 129) | **100%** |
| `u_dec` CIC ch2 | 28 | (1388, 130) | **100%** |
| `u_dec` CIC ch1 | 28 | (1221, 138) | **100%** |
| `u_dec` CIC ch0 | 28 | (1042, 190) | 0% |
| `u_dec` other (polyphase delay lines) | 1972 | (1132, 529) | 53.0% |
| `u_dec` HB (shared TDM) | 70 | (870, 845) | 1.4% |
| (top) | 1247 | (605, 291) | 0.2% |
| `u_sc` | 513 | (392, 573) | 0% |
| `u_psram` | 387 | (615, 497) | 0% |
| `u_comb` | 246 | (278, 662) | 0% |
| `u_tacc` | 211 | (512, 302) | 0% |
| `u_remod` | 112 | (212, 931) | 0% |
| `u_pcfsm` | 108 | (184, 423) | 0% |
| `u_dcr` | 104 | (971, 628) | 7.7% |
| `u_spi` | 50 | (651, 306) | 0% |

Two things worked as designed:

1. **CIC channels 1–3 are 100% in the leg**, at x = 1221 / 1388 / 1555 —
   monotonically ordered west-to-east, tracking the south-edge pin order in
   `io_placement_lshape.cfg` (`IQ_DATA_{I,Q}_2/3` pushed to far-east South).
   ch0 sits just outside at x = 1042. Pin placement shaped placement directly.
2. **No timing-critical block crossed the seam.** `u_sc`, `u_psram`, `u_pcfsm`,
   `u_tacc`, `u_comb`, `u_remod` are all 0% in the leg. Nothing carrying
   unrelaxed timing debt got stranded across the notch.

## Correction to the original premise

I proposed this as "move 2 of the 4 decimator branches into the leg."
That was wrong about the RTL. `sd_decimator_poly.v` is **hybrid**:

- `generate for (g = 0; g < 4) : gen_cic_comb` — 4 parallel per-channel CICs,
  separable, but only **28 flops each (112 total)**
- `u_hb1_mac` / `u_hb2_mac` — **single shared TDM** datapaths, not separable

112 CIC flops cannot account for a 3.67 ns swing. What actually filled the leg
is `u_dec other` (1972 flops, 53% in leg) — polyphase delay-line registers
spreading into available space, not deliberately placed.

So the honest attribution is: **the density fix (50 → 78) is likely doing most
of the timing work**, and the pin shaping ensured the spreading happened in a
coherent east-west direction instead of smearing logic across the seam. Both
levers mattered, not in the proportion originally claimed. The two were changed
together in 4392 and have not been separated — an A/B (pins-only at density 50)
would settle it.

## Cost / open questions

- **One padring slot lost** (5 vs 6). Not yet checked against the pad budget —
  this is the main reason the L-shape is not obviously free.
- Antenna violations 8 → 4, DRC 0 on both L runs. LVS not yet run.
- Configs are **uncommitted**: `rtl-test/ol_trouper_top/config_lshape_1100_550_v26{,_pins}.json`,
  `io_placement_lshape.cfg`, `rtl-test/scripts/run_pnr_lshape_v26{,_pins}.sh`.
  The two JSONs differ by exactly `IO_PIN_ORDER_CFG` and
  `PL_TARGET_DENSITY_PCT` (50 → 78).

## Next

1. Repeat 4392 (n ≥ 3) to separate the WNS delta from repair-lottery noise.
2. A/B pins-only vs density-only to attribute the gain.
3. Check the 5-slot padring against the actual pad count before committing.
