# trouper_top per-module area breakdown

Hierarchical Yosys synthesis of the **current active** `trouper_top` RTL using the
GF180 FD library `gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib`. No `-flatten`, so
`stat -liberty -top` attributes cells to their owning submodule. This is
pre-place gate area only; CTS, buffers inserted by PnR, fill, and utilization
overhead are not included.

- Script: `rtl-test/scripts/run_synth_trouper_top_breakdown.sh`
- Output: `rtl-test/syn_mimo_per_module/out_trouper_top_current_fd/stat_hier.txt`
- Job: SGE `3683`
- Library: `gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib`
- Date: `2026-07-28`

## Total

| Top | Cells | Area (µm²) | Seq fraction |
|---|---:|---:|---:|
| `trouper_top` | 32,613 | **935,082.7584** | **41.51%** |

## Top-level submodule areas

Sorted by total contribution to `trouper_top` from the hierarchical `stat` report.

| Rank | Submodule | Instances | Area each (µm²) | Total (µm²) | % of chip |
|---:|---|---:|---:|---:|---:|
| 1 | `sd_decimator_poly` | 1 | ~340,000* | ~340,000 | 36.4% |
| 2 | `training_acc` | 1 | 146,224.4672 | 146,224.4672 | 15.6% |
| 3 | `sc_detector` | 1 | ~119,000† | ~119,000 | 12.7% |
| 4 | `psram_buf_ctrl` | 1 | 74,092.3904 | 74,092.3904 | 7.9% |
| 5 | `sd_remod` | 1 | 60,879.4816 | 60,879.4816 | 6.5% |
| 6 | `mrc_combiner` | 1 | 55,902.9632 | 55,902.9632 | 6.0% |
| 7 | `reg_bank` | 1 | 43,017.1392 | 43,017.1392 | 4.6% |
| 8 | `dc_removal` | 1 | ~37,000‡ | ~37,000 | 4.0% |
| 9 | `packet_ctrl_fsm` | 1 | 36,378.8544 | 36,378.8544 | 3.9% |
| 10 | `spi_slave` | 1 | 9,096.9088 | 9,096.9088 | 1.0% |
| 11 | `trouper_top` (local glue) | - | 14,352.2176 | 14,352.2176 | 1.5% |

`*` `sd_decimator_poly` own cells are 265,937.5040 µm²; plus child submodules
`sd_decimator_poly_hb2_mac` (18,448.4608), `sd_decimator_poly_hb1_mac`
(15,489.3312), and 2× `sd_decimator_poly_cic_comb` (4,965.5424 each, I/Q).

`†` `sc_detector` own cells are 106,754.7712 µm²; plus child module
`serial_mul13` (11,812.3712 µm², the bit-serial eval multiplier from the
2026-07 B1 area cut).

`‡` `dc_removal` top wrapper is 74.6368 µm²; plus 8× `dc_removal_chan`
(4,612.1152 µm² each — 4 I-channel + 4 Q-channel instances).

## Headlines

1. `sd_decimator_poly` is the largest block in the active macro at about `36.4%` of synthesized area — this is *higher* than the pre-HB-migration `sd_decimator_cic_tdm8` measurement below (27.8%), reflecting the added HB1/HB2 polyphase MAC stages. Per `planning/area-reduction-roadmap.md` §1 it is considered CLOSED (no further area to recover without regressing SS timing or SQNR).
2. `training_acc` and `sc_detector` are the next largest arithmetic blocks; together with the decimator they account for about `64.7%` of the total synthesized area.
3. Control-plane logic is relatively small: `packet_ctrl_fsm` + `spi_slave` + top-level glue together are under `6.5%` of the chip.
4. The active macro has **no PicoRV32, no hardware `weight_gen`, no `noise_floor_est`, and no `energy_meas_coarse`** in this synthesis breakdown. Older docs that include those blocks describe superseded RTL.

## Cut Priorities

If area reduction is the goal, the first places to look are:

1. `training_acc` (decimator is closed, see Headlines #1)
2. `sc_detector`
3. `psram_buf_ctrl`
4. `sd_remod`
5. `mrc_combiner`

## Caveats

- These numbers are synthesis-only, not PnR area.
- PnR adds clock-tree, repair buffers, tap/endcap/fill, and routing-driven overhead.
- Placed cell area is materially larger than this synth figure — see
  `planning/area-reduction-roadmap.md` §2 for measured placed-die utilisation
  (placed area ≈ 1.16 M µm² at 3.0 V vs the ~935–973 K synth-only figure here).

## History

The decimator half-band migration (`sd_decimator_cic_tdm8` → `sd_decimator_poly`,
see `planning/decimator-hb-migration-impact-plan.md`) and subsequent area cuts
(B1 sc_detector serial multiplier, B4/B6 flop reduction) moved the absolute
totals and block names since the original 2026-06-18 measurement (job 1965,
748K µm² total, `sd_decimator_cic_tdm8` at 207.8K/27.8%). Do not compare
absolute area numbers across the rename without checking the date.
