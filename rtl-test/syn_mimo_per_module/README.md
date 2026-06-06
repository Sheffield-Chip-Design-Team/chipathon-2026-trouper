# mimo_rx_top per-module area breakdown

Hierarchical yosys synthesis of `mimo_rx_top` against the **Avalon
`gf180mcu_as_sc_mcu7t3v3`** 3.3 V 7-track cell library. No `-flatten`, so the
`stat -liberty -top` report attributes cells to their owning submodule.
This is pre-place gate area only (SRAM macros are blackboxes; fill/utilization
not included).

- Script: `run_synth_hier.sh` (runs `yosys -s` against a generated `synth.ys`)
- Output: `out/stat_hier.txt`, `out/yosys.log`
- Job: SGE 1076 (4 CPU / 4G, 20 s)
- Library: `gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib`

## Total

| Top                  | Cells | Area (µm²) | Seq fraction |
|----------------------|-------|------------|--------------|
| `mimo_rx_top` (flat) | 80,751 | **2,512,196** | 37.4 % seq |

(Matches the earlier flat-synth report at ~2.58M when run with `-flatten`; small
delta is structural-vs-flat ABC choices.)

## Top-level submodule areas (including children)

Sorted by total contribution to `mimo_rx_top`. Instance count from yosys
hierarchy report.

| Rank | Submodule              | Instances | Area each (µm²) | Total (µm²) | % of chip |
|-----:|------------------------|----------:|----------------:|------------:|----------:|
|   1  | **`sd_decimator`**     | **4**     |  203,627        | **814,508** | **32.4 %** |
|   2  | `sc_detector`          | 1         |  408,158*       |    408,158  | 16.2 % |
|   3  | `picorv32_wrap`        | 1         |  373,000*       |    373,000  | 14.9 % |
|   4  | `weight_gen`           | 1         |  186,201        |    186,201  |  7.4 % |
|   5  | `training_acc`         | 1         |  152,000*       |    152,000  |  6.0 % |
|   6  | `mrc_combiner`         | 1         |  120,758        |    120,758  |  4.8 % |
|   7  | `energy_meas`          | 1         |   98,040        |     98,040  |  3.9 % |
|   8  | `reg_bank`             | 1         |   97,932        |     97,932  |  3.9 % |
|   9  | `noise_floor_est`      | 1         |   82,568        |     82,568  |  3.3 % |
|  10  | `dc_removal`           | 1         |   50,009        |     50,009  |  2.0 % |
|  11  | `packet_ctrl_fsm`      | 1         |   32,902        |     32,902  |  1.3 % |
|  12  | `frontend_buf_ctrl`    | 1         |   29,809        |     29,809  |  1.2 % |
|  13  | `sd_remod`             | 1         |   29,262        |     29,262  |  1.2 % |
|  14  | `spi_slave`            | 1         |   17,489        |     17,489  |  0.7 % |
|  15  | `spi_master`           | 1         |   10,241        |     10,241  |  0.4 % |
|  16  | `irq_ctrl`             | 1         |    2,571        |      2,571  |  0.1 % |
|  17  | `ahb_lite_bus`         | 1         |    2,465        |      2,465  |  0.1 % |
|      | `mimo_rx_top` (local)  | -         |    4,537        |      4,537  |  0.2 % |

`*` includes child modules:
- `sc_detector` = 308,588 local + `signed_mul24_pipe` 99,570
- `picorv32_wrap` = 18,156 local + `picorv32` 286,157 + `picorv32_pcpi_mul` 33,501 + `picorv32_pcpi_div` 35,042
- `training_acc` = 117,557 local + `signed_mul8_pipe` 8,583 + glue

SRAM macros (`sram512x8m8wm1` ×1, `sram1024x8m8wm1` ×4) are blackboxes — their
silicon area is **not** in the 2.51 M µm² number; they will show up as
hard-macro footprint at floorplan.

## Headlines

1. **`sd_decimator` ×4 = 32 % of all cell area.** This is by far the biggest
   single architectural choice. The 4 instances correspond to (2 RX channels ×
   I/Q paths). Folding to NR=1 (no MIMO) drops to 8.1 % saving ~610 k µm² of
   stdcell. Time-multiplexing 4→1 saves the same with a 4× clock-rate cost.

2. **CPU is ~15 %, not dominant.** `picorv32_wrap` (CPU + pcpi mul/div + AHB
   master + bus glue) is third on the list and matches the standalone-synth
   number (~370 k µm² gate, plus 4× SRAM macros). It's not the bottleneck.

3. **The DSP datapath dominates over control.** Top 5 blocks (sd_decimator,
   sc_detector, picorv32_wrap, weight_gen, training_acc) = **76.9 %** of cell
   area. The control/SPI/bus/IRQ tail (ranks 11–17) is < 4 % combined — not
   worth optimizing for area.

4. **`signed_mul24_pipe` in `sc_detector` = 100 k µm²** on its own. If
   sc_detector can be done at a lower clock rate post-detection, this multiplier
   is a TDM candidate (single multiplier shared across the detector phases).

## Time-multiplex targets, ranked by leverage

| Target                       | Saving if folded 4→1 / 2→1 | Cost                             |
|------------------------------|---------------------------:|----------------------------------|
| **`sd_decimator` 4→1 TDM**   | ~610 k µm² (24 % of chip)  | 4× internal clock OR pipelined SerDes; per-channel state buffering |
| `sc_detector` mul fold       | ~75 k µm² (3 %)            | small FSM around `signed_mul24_pipe` |
| `weight_gen` time-share      | up to ~140 k µm² (5.5 %)   | needs analysis of dependency chain |
| `training_acc` 2→1 (per-ch)  | ~75 k µm² (3 %)            | one accumulator, TDM across channels |

Folding `sd_decimator` alone is worth more than every other optimization
combined. That's the architectural decision to make first.

## Caveats

- Numbers are post-tech-map but pre-place; no buffering, no fill, no halo,
  no CTS. Final die area will be ~2-3× this depending on utilization target
  (32 % util on as_sc gave 2.97 mm² for picorv32_wrap alone).
- SRAM macro footprint not counted; mimo_rx_top has 1× 512×8 + 4× 1024×8
  hard macros.
- as_sc liberty has some unusual cell-area weights (`maj3_2` heavy use);
  ranking is stable but absolute numbers shift ~5-10 % across libraries.
- `mimo_rx_top` "local" area (4.5 k µm²) is just the top-level wiring/glue —
  it does not include any submodule.
