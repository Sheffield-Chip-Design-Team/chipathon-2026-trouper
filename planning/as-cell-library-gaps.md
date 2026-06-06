# AS Cell Library Gaps — gf180mcu_as_sc_mcu7t3v3

## Background

The `gf180mcu_as_sc_mcu7t3v3` library is a **custom 3.3V 7-track standard cell library**
built by Avalon Semiconductors from scratch for the GF180MCU PDK:
- Upstream: https://github.com/AvalonSemiconductors/gf180mcu_as_sc_mcu7t3v3
- Local submodule: `ip/gf180mcu_as_sc_mcu7t3v3/`
- Characterisation tool: [lctime](https://codeberg.org/TholinVali/lctime) (custom fork)
- **76 cells total** — this is the complete library, not a subset of a larger kit

## What's missing vs the FD library

The FD library (`gf180mcu_fd_sc_mcu7t5v0`) uses ~34 distinct cell types in synthesis
for a medium block. AS synthesis maps the same logic using only the 76-cell set,
producing ~10-15% larger netlists due to the following gaps:

### High-impact synthesis gaps

| Missing | FD equivalent | Why it matters |
|---|---|---|
| `oai21, oai22, oai31, oai32, oai33, oai221` | `oai21_1` etc. | OAI gates are the CMOS-native form for sum-of-products; only `oai211_2` exists in AS. This is the biggest single quality gap. |
| `aoi221, aoi222` | `aoi221_1` etc. | Fewer complex reduction paths |
| `and3, and4, or3, or4` | `and3_1` etc. | Synthesis decomposes to 2-input gates → more levels, more area |
| `xor3, xnor3` | `xor3_1` | 3-input XOR for adder/parity logic |
| x1 drive strength (all cells) | `nand2_1, nor2_1` etc. | Minimum gate is x2; forces 2× overdrive on low-fanout paths |

### CTS-specific gap — highest priority for tapeout

| Missing | FD equivalent | Why it matters |
|---|---|---|
| `clkbuff_16` | `gf180mcu_fd_sc_mcu7t5v0__clkbuf_16` | AS max CTS buffer is `clkbuff_12`. For large-fanout clock nets (e.g. `clk_32m_regs` at 2508 terminals in picorv32), the tool needs more tree levels and is more prone to DRT-0073. A `clkbuff_16` would reduce tree depth and routing pressure. |

### FF variant gaps

| Missing | Notes |
|---|---|
| `dfxtp_1` (min drive) | Area optimisation for low-fanout flops |
| Reset/enable combinations | Synthesis adds glue logic instead |
| Dedicated `clkinv` | Regular `inv_*` used for clock inversion; timing annotation may differ |

## Recommended action: add clkbuff_16

`clkbuff_16` is the **lowest-effort, highest-impact near-term addition**:

- Architecturally identical to the existing `clkbuff_12` — same 7-track cell structure,
  same pin topology, just wider output transistors for higher drive strength
- The lctime characterisation workflow is already proven on `clkbuff_4/8/12`
- Fixes the CTS root-buffer DRT-0073 wall for large fanout nets permanently
- Does not require a new logic function or complex CMOS topology

**Suggested path:**
1. Clone the upstream repo and duplicate the `clkbuff_12` GDS/schematic
2. Scale the output stage transistors for ~16× drive (matching FD `clkbuf_16` sizing)
3. Run lctime characterisation for TT/SS/FF corners at 3.3V
4. Submit PR upstream to `AvalonSemiconductors/gf180mcu_as_sc_mcu7t3v3`
5. Update `ip/gf180mcu_as_sc_mcu7t3v3` submodule once merged

## Longer-term: OAI/AOI and wide gate additions

If synthesis quality becomes the blocking constraint, the OAI family
(`oai21, oai22, oai31`) would have the largest single impact on netlist size.
Each requires a new GDS layout + characterisation. Raise a GitHub issue on the
upstream repo — the library is in active development and cell additions have been
merged recently (dlybuff_2/4 added in the most recent commits).

## Mixed AS+FD library approach

An alternative to adding new AS cells is to build a **filtered combined library**
that uses AS as the primary SCL and pulls in a curated subset of FD cells to fill
the gaps. This is faster than new cell characterisation and viable for setup-timing
signoff.

### Timing accuracy analysis

FD cells are characterised at 5V nominal / 3V SS. We operate at 3.3V:

| Corner | FD lib voltage | Our voltage | STA result for gap cells |
|---|---|---|---|
| SS | 3.0 V | 3.3 V | Cell is *faster* at 3.3V than at 3V → FD SS is **conservative** ✓ |
| TT | 5.0 V | 3.3 V | Cell is *much slower* at 3.3V → FD TT is **optimistic** ✗ |
| FF | 3.6 V | 3.3 V | Cell is *slower* at 3.3V → FD FF is **optimistic** ✗ |

SS corner (setup signoff) is conservative — the gap cells will be slower in silicon
than FD-3V predicts, so setup timing is safe. TT/FF optimism only affects hold paths
through the gap cells, which are a small fraction of the netlist. This is the same
trade-off already accepted for OCD SRAM timing.

### Gap cells to pull from FD

Only the cells absent from AS should be admitted:

| Category | FD cells to include |
|---|---|
| OAI gates | `oai21_1, oai22_1, oai31_1, oai32_1, oai33_1, oai221_1` |
| AOI gates | `aoi221_1, aoi222_1` |
| Wide AND/OR | `and3_1, and4_1, or3_1, or4_1` |
| Wide XOR | `xor3_1, xnor3_1` |
| Min drive | `buf_1, inv_1, nand2_1, nor2_1` |
| CTS root | `clkbuf_16` (CTS_ROOT_BUFFER only, not in synth) |

All other FD cells must be added to `no_synth.cells` to prevent Yosys from
defaulting to FD for logic AS can already handle.

### Implementation steps

1. **Filter the FD .lib:** extract only the gap cell entries from
   `gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib` (and SS/FF equivalents) into a
   new `gf180mcu_fd_gap__<corner>.lib`.
2. **Update `LIB` in config:** add the gap .lib alongside the AS .lib for each corner.
3. **Extend `no_synth.cells`:** append all non-gap FD cells so Yosys ignores them.
4. **CTS config:** set `CTS_ROOT_BUFFER` to `gf180mcu_fd_sc_mcu7t5v0__clkbuf_16`
   while keeping `CTS_CLK_BUFFERS` as AS `clkbuff_4/8/12`. This uses the larger FD
   root buffer without mixing FD into the tree body.

### Trade-offs vs native AS clkbuff_16

| Approach | Effort | Setup accuracy | Hold accuracy | Risk |
|---|---|---|---|---|
| Filtered AS+FD lib | Low (lib editing + no_synth) | ✓ Conservative SS | ✗ Slightly optimistic FF | Low — proven pattern (OCD SRAM lib) |
| New AS clkbuff_16 | Medium (layout + lctime) | ✓ Fully accurate | ✓ Fully accurate | Low for CTS-only cell |
| New AS OAI/AOI cells | High (multiple layouts + lctime) | ✓ Fully accurate | ✓ Fully accurate | Medium — new CMOS topologies |

**Recommendation:** do the filtered AS+FD lib first (fast win on synthesis quality and
CTS), then upstream `clkbuff_16` to AS before tapeout for a fully accurate CTS model.

## Impact on current PnR

Without `clkbuff_16`, the workaround is to lower `PL_TARGET_DENSITY_PCT` to 55
(vs 60 for FD cells) to give the router enough routing tracks around the CTS
buffers for large-fanout clock nets. See [`as-cts-buffer-policy.md`](../memory/as-cts-buffer-policy.md).
