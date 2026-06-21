# trouper_top per-module area breakdown

Hierarchical Yosys synthesis of the **current active** `trouper_top` RTL using the
GF180 FD library `gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib`. No `-flatten`, so
`stat -liberty -top` attributes cells to their owning submodule. This is
pre-place gate area only; CTS, buffers inserted by PnR, fill, and utilization
overhead are not included.

- Script: `rtl-test/scripts/run_synth_trouper_top_breakdown.sh`
- Output: `rtl-test/syn_mimo_per_module/out_trouper_top_current_fd/stat_hier.txt`
- Job: SGE `1965`
- Library: `gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib`
- Date: `2026-06-18`

## Total

| Top | Cells | Area (µm²) | Seq fraction |
|---|---:|---:|---:|
| `trouper_top` | 25,610 | **748,042.9376** | **45.34%** |

## Top-level submodule areas

Sorted by total contribution to `trouper_top` from the hierarchical `stat` report.

| Rank | Submodule | Instances | Area each (µm²) | Total (µm²) | % of chip |
|---:|---|---:|---:|---:|---:|
| 1 | `sd_decimator_cic_tdm8` | 1 | 207,753.7280 | 207,753.7280 | 27.8% |
| 2 | `training_acc` | 1 | 131,229.0560 | 131,229.0560 | 17.5% |
| 3 | `sc_detector` | 1 | 108,486.7840* | 108,486.7840 | 14.5% |
| 4 | `psram_buf_ctrl` | 1 | 67,006.2848 | 67,006.2848 | 9.0% |
| 5 | `mrc_combiner` | 1 | 59,331.8656 | 59,331.8656 | 7.9% |
| 6 | `reg_bank` | 1 | 39,419.2064 | 39,419.2064 | 5.3% |
| 7 | `dc_removal` | 1 | 34,826.8480 | 34,826.8480 | 4.7% |
| 8 | `sd_remod` | 1 | 27,148.0384 | 27,148.0384 | 3.6% |
| 9 | `packet_ctrl_fsm` | 1 | 24,035.2448 | 24,035.2448 | 3.2% |
| 10 | `spi_slave` | 1 | 8,976.1728 | 8,976.1728 | 1.2% |
| 11 | `trouper_top` (local glue) | - | 15,427.8656 | 15,427.8656 | 2.1% |

`*` includes child module `signed_mul24_pipe` at `24,401.8432 µm²`.

## Headlines

1. `sd_decimator_cic_tdm8` is now the largest block in the active macro at about `27.8%` of synthesized area.
2. `training_acc` and `sc_detector` are the next largest arithmetic blocks; together with the decimator they account for about `59.8%` of the total synthesized area.
3. Control-plane logic is relatively small: `packet_ctrl_fsm` + `spi_slave` + top-level glue together are under `6.5%` of the chip.
4. The active macro has **no PicoRV32, no hardware `weight_gen`, no `noise_floor_est`, and no `energy_meas_coarse`** in this synthesis breakdown. Older docs that include those blocks describe superseded RTL.

## Cut Priorities

If area reduction is the goal, the first places to look are:

1. `sd_decimator_cic_tdm8`
2. `training_acc`
3. `sc_detector`
4. `psram_buf_ctrl`
5. `mrc_combiner`

## Caveats

- These numbers are synthesis-only, not PnR area.
- PnR adds clock-tree, repair buffers, tap/endcap/fill, and routing-driven overhead.
- The current implemented top-level FD flow previously reached about `0.91 mm²` post-route instance area on the June 14 runs, so the synthesis total here should be treated as a ranking tool, not a die-size prediction.
