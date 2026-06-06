# PicoRV32 synthesis: 3.3 V-native cells vs 5 V cells at 3.3 V

Quantifies the speed/area cost of the GF180MCU **5 V standard cells run
underdriven at 3.3 V** (the only digital cells in the stock open PDK) versus
**OSU's 3.3 V-native standard cells** (`gf180mcu_osu_sc_*`, `nfet_03v3` devices,
`.lib nom_voltage 3.3`). Motivation: PicoRV32 only closes timing at 16 MHz with
the 5 V cells, and we wanted to know how much of that ceiling is the
device-underdrive penalty rather than the RTL.

See memory note `gf180-3v3-cell-ecosystem` for the library background, and
`characterization/sram_ocd/` for the parallel SRAM (5 V→3.3 V) story.

## Method

Standalone **yosys synthesis + OpenSTA** (no P&R) of `picorv32_wrap`, identical
flow for every library — `run_synth_sta.sh <core_lib> <prefix> <period_ns>
<outdir> [sram_lib]`:

1. `read_verilog` picorv32 + wrapper + SRAM blackbox stub
2. `synth -top picorv32_wrap -flatten`
3. `dfflibmap` + `abc -liberty <lib> -D <period_ps>` (timing-driven tech map)
4. `hilomap` constants to the lib's `tieh`/`tiel`, `splitnets`, `opt_clean`
5. `stat -liberty` → cell area + counts
6. OpenSTA: `create_clock 62.5ns`, `report_checks -path_delay max` (SRAM `.lib`
   read so SRAM-touching paths are real)

All runs use the OCD SRAM `tt_025C_3v30` lib (blackboxed in the netlist), the
same RTL, and a 62.5 ns clock.

## Results (TT/25 °C/3.3 V, 62.5 ns clock)

| Library | Devices | Track | Critical path | Slack @62.5ns | Cell area (µm²) | Flops |
|---|---|---|---|---|---|---|
| `gf180mcu_fd_sc_mcu7t5v0` (stock) | 5 V | 7 T | 65.44 ns | **−4.27 VIOLATED** | 358,985 | ~2,462 |
| `gf180mcu_osu_sc_gp9t3v3` | 3.3 V | 9 T | 45.50 ns | **+16.32 MET** | 542,444 | ~2,462 |
| `gf180mcu_osu_sc_gp12t3v3` | 3.3 V | 12 T | 37.61 ns | **+24.09 MET** | 723,052 | ~2,462 |

**Takeaways:**
- 3.3 V-native cells cut the critical path substantially vs the underdriven 5 V
  cells — **~30 % (gp9t3v3, 45.5 ns)** and **~43 % (gp12t3v3, 37.6 ns)** off the
  65.4 ns 5 V path. The 5 V-at-3.3 V underdrive is most of the 16 MHz ceiling,
  not the RTL.
- Speed/area trade across the 3.3 V variants: gp12t3v3 is ~17 % faster than
  gp9t3v3 (higher 12-track drive) for ~33 % more area.
- Area cost vs the 5 V baseline: **gp9t3v3 ~1.51×**, **gp12t3v3 ~2.01×** logic
  cell area (taller tracks + fewer drive strengths than mcu7t5v0).
- Flop count identical across all three (same RTL) — apples-to-apples map.

## Caveats (important)

- **Raw-synth timing is not a final Fmax.** Both runs show an unbuffered
  high-fanout artifact (the worst path's first `dff` shows a ~37 ns clk-to-Q
  driving a huge unbuffered net). It inflates absolute delay in *both* libs, so
  the ~30 % *relative* gap is valid but the absolute numbers need P&R buffering
  (OpenROAD resizer) to be real. Treat these as synthesis-quality estimates.
- **Cell area ≠ die area** (no whitespace/routing). 
- **OSU ships only the `TT_25C` corner** — no SS/FF, so no worst-case signoff
  until the missing PVT corners are characterized.
- **9 T/12 T track height** ≠ the current 7 T → a full re-floorplan/re-PDN, not a
  drop-in SCL swap; cannot mix rows with 5 V cells.

## Reproduce

```bash
# inside iic-osic-tools, repo mounted at /foss/designs/lora-mimo
cd /foss/designs/lora-mimo/rtl-test/syn_picorv32_3v3
SRAM=/foss/designs/lora-mimo/ip/gf180mcu_ocd_ip_sram/cells/gf180mcu_ocd_ip_sram__sram1024x8m8wm1/gf180mcu_ocd_ip_sram__sram1024x8m8wm1__tt_025C_3v30.lib
./run_synth_sta.sh /foss/designs/lora-mimo/ip/gf180mcu_osu_sc/gf180mcu_osu_sc_gp9t3v3/lib/gf180mcu_osu_sc_gp9t3v3_TT_25C.ccs.lib gf180mcu_osu_sc_gp9t3v3 62.5 out_osu_gp9t3v3 $SRAM
```

Outputs per run in `out_<lib>/`: `netlist.v`, `stat.txt`, `sta.log`.
