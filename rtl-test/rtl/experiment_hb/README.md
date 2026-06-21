# experiment_hb — HB Decimator Migration Sandbox

Experimental copies of production RTL blocks for the half-band decimator migration
(see `planning/decimator-hb-migration-impact-plan.md`).

**Production RTL in `rtl-test/rtl/` is untouched.** All module names here carry an
`_hb` suffix so both sets can coexist in simulation without name collisions.

## Files

| File | Copied from | Gate(s) |
|---|---|---|
| `trouper_top_hb.v` | `trouper_top.v` | 4, 11 |
| `sc_detector_hb.v` | `sc_detector.v` | 5 — widen M_val to 15 bits |
| `dc_removal_hb.v` | `dc_removal.v` | 9 — alpha 1/16→1/32, 13-bit acc |
| `training_acc_hb.v` | `training_acc.v` | 6 — widen n_acc to 18 bits |
| `packet_ctrl_fsm_hb.v` | `packet_ctrl_fsm.v` | 7 — M-derived thresholds |
| `reg_bank_hb.v` | `reg_bank.v` | 3 — BW_CFG register (0x0A) |

`trouper_top_hb.v` instantiates `sd_decimator_hb_tdm` (from `../sd_decimator_hb_tdm.v`)
plus all `_hb`-suffixed blocks above. Unchanged blocks (`mrc_combiner`, `weight_gen`,
`noise_est`, `psram_buf_ctrl`, etc.) are referenced from `../`.

## Change-control

Do NOT merge changes back to production RTL until the relevant gate in the migration
impact plan is accepted.
