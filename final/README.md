# trouper_top — Final P&R Outputs

Signoff-flow output for `trouper_top`, full **1675 × 1110 µm** rectangular die —
**SGE job 5158, 2026-08-29**, config
`rtl-test/ol_trouper_top/config_1675x1110_full_rect.json`.

## Why the die grew (1650×1100 → 1675×1110)

The A40 shared-padframe integrator reserves **1675 × 1110 µm** for Trouper
(`A40_ACV.def` `DIEAREA`, `A40_ACV_interface.yaml` `size_microns`). The previous
`final/` (job 5122) was 1650 × 1100, so its GDS **layer-0/0 bounding box
under-filled the reserved slot by 25 × 10 µm** — the organiser flagged both the
die-size and the bounding-box mismatch; they are the same root cause. This run
rebuilds at the slot size. `lef/trouper_top.lef` `SIZE` and the GDS layer-0/0
rectangle are now `1675.000 × 1110.000`.

## This is a fresh P&R, not a rebuild of job 5122

Unlike the 4780 → 5105 → 5122 chain (byte-identical geometry), this run differs
from job 5122 in three ways and therefore has a **new placement, netlist, and
GDS**:

1. **Die** 1650×1100 → 1675×1110.
2. **RTL** is current `main` (post-PR #47) — it carries the Grouper
   `trouper_ahb8_adapter` AHB-Lite endpoint that job 5122's RTL did not. Synthesis
   and the netlist differ accordingly.
3. **`PL_TARGET_DENSITY_PCT` 78 → 65.** At 78 and 72 detailed routing aborts
   `DRT-0073`/`DRT-1231` on an `IQ_CLK` clock-tree buffer. Job 5159 isolated the
   cause: the ~40 forced top-level pins of the new AHB endpoint (`io_placement`
   places them on `#S` alongside `GRP_*`) perturb global placement / CTS enough
   to strand a clkbuf — it reproduces at the original 1650×1100 die too, so it is
   the AHB pins, not the die growth. Density 65 gives detailed placement the room
   to seat that buffer with a legal access point.

`io_placement_lshape_1675.cfg` = `io_placement_lshape.cfg` + the 40 AHB `H*` bits
appended to `#S`. Pin arrangement is otherwise identical to job 5122. RTL carries
**no A40 rename / pad-control tie-offs** — that work lives on
`pnr/trouper-a40-padframe-tieoffs`.

SDC is unchanged: `PNR_SDC_FILE = pnr_32m_scoped_v25_b6.sdc`,
`SIGNOFF_SDC_FILE = pnr_32m_scoped_v25_b6_signoff.sdc` (v28–v30 signoff-only MCP
groups, `SPI_SCK` at 2 MHz).

## Results summary

- **DRC:** 0 errors (Magic), 0 (KLayout XOR differences)
- **LVS:** 0 errors, 0 unmatched pins (netgen — circuits match uniquely)
- **Max fanout:** 0 violations (all corners)
- **Hold:** WNS 0.0 ns (all corners) — clean
- **Max slew / max cap violations:** 8 / 4 (nom_tt), 15 / 5 (max_ss), 8 / 5
  (max_ff) — the documented DRV waiver, essentially unchanged from job 5122
  (10 / 4, 15 / 6, 10 / 4). See "DRV residual".
- **Timing (WNS / TNS, setup):**
  - `nom_tt_025C_3v30`: **0.0 ns** (met)
  - `max_ff_n40C_3v60`: **0.0 ns** (met)
  - `max_ss_125C_3v00`: **−13.52 ns / −323 ns**. Same character as job 5122's
    −12.45 ns — the voltage-headroom gap (`gf180mcu_fd_sc_mcu7t5v0` is
    5 V-characterized cells run at 3.0 V SS). The worst path is now the
    `ahb_re` → `reg_bank`/AHB read-decode cone (`_63059_ → _61493_`, IQ_CLK
    domain, 14+ gate levels), the new endpoint's decode logic; the rest is the
    same paced-DSP / quasi-static residual analysed for job 5122.
- **IR drop:** worst 5.3 mV on VDD (0.16 %), min on-grid voltage 3.295 V
- **Core utilization** 0.645, **instance count** 123 691 (48 310 std cells),
  **routed wirelength** 2.04 mm
- Full metrics: `metrics.json` / `metrics.csv`

## Signoff-SDC MCP relaxations (v28–v30, carried from job 5122)

`SIGNOFF_SDC_FILE` is `pnr_32m_scoped_v25_b6_signoff.sdc` — the P&R SDC plus
three `set_multicycle_path 3 -setup / 2 -hold` groups. `PNR_SDC_FILE` is
unchanged, so placement/routing builds those paths as single-cycle
(conservative).

| Group | Scope (`-to`) | Cone |
|---|---|---|
| `tacc_accumulate` (v28) | `Zpair_i/q[*]`, `Zdiag[*]` accumulator flops (512 endpoints) | `training_acc` all-pairs MAC recurrence |
| `iq_samp_cnt` (v29) | `iq_samp_cnt[*]` flops (20 endpoints) | top-level 32-bit sample counter, `+1` per `dcr_valid` |
| `pcfsm_tick_decrement` (v30) | `acq_cnt/wpend_cnt/pkt_cnt` (63 endpoints) | `sample_count → ST_ACQ_SETUP` load + the `if (iq_tick) cnt<=cnt-1` decrement |

Rationale and non-vacuity evidence per group: `mcp_audit_manifest.json`,
`run_mcp_audit.sh` (re-audit against this run's routed netlist recommended before
tapeout; the job-5124 baseline was taken on the pre-AHB job-5122 netlist).

**Why signoff-only, not P&R:** adding any of these to the P&R SDC perturbs the
post-GRT resizer enough to strand the `IQ_CLK` root clkbuf with no routing
access point (`DRT-0073`).

## DRV residual (waiver, ~15 pins)

`RUN_POST_GRT_RESIZER_TIMING = true` with `DESIGN_REPAIR_MAX_SLEW_PCT` /
`_CAP_PCT = 65` (and the GRT equivalents) — carried from `config_1650x1100_full_rect.json`.
Do **not** add `set_max_transition` / `set_max_capacitance` to either SDC: any
design-wide value stalls `repair_design` on this netlist for 70+ min.

The ~15 residual pins (worst: nom_tt +1.8 ns over an 8.6 ns slew limit; max_ss
+7.4 ns over 15.6 ns) sit in two quasi-static combinational cones:

- **`sc_detector` SF/BW symbol-period decode** — cells fed by `u_sc.sym_cnt[*]`,
  `rb_sf_cfg[*]`, `rb_bw_sel` (`sym_cnt` vs `M = 1<<(SF+sample_shift)`).
- **`reg_bank` / AHB read-address decode** — cells fed by `ahb_addr[*]`,
  `ahb_re`, `spi_reg_rd_addr[*]` (the readback mux, now merged with the AHB read
  path).

Both re-evaluate only on config writes or host reads (SPI ≤ 2 MHz), settle far
within a cycle, and hold is clean — functionally immaterial. Same class as the
job-5122 waiver. Full list: `reports/sta/*/checks.rpt`.

## Contents

| Path | What it is |
|---|---|
| `gds/trouper_top.gds` | Final layout, 1675×1110 (layer-0/0 bbox = die) |
| `def/trouper_top.def` | Final placed-and-routed DEF |
| `lef/trouper_top.lef` | Abstract view (`SIZE 1675 BY 1110`) |
| `nl/`, `pnl/` | Post-layout gate-level netlists (logical / with physical cells) |
| `spice/trouper_top.spice` | SPICE netlist |
| `vh/trouper_top.vh` | Verilog port header |
| `sdc/trouper_top.sdc` | SDC written by the flow (P&R set; the v28–v30 signoff groups are in `rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6_signoff.sdc`) |
| `lib/<corner>/…` | Per-corner timing library views |
| `json_h/trouper_top.h.json` | Yosys JSON header |
| `render/trouper_top.png` | Layout render (this run) |
| `metrics.json`, `metrics.csv` | Full signoff metric dump (job 5158) |
| `reports/sta/<corner>/{max,min,checks}.rpt` | Post-P&R STA per corner (signoff SDC) |
| `reports/drc/drc.magic.rpt` | Magic DRC (0) |
| `reports/lvs/lvs.netgen.rpt` | netgen LVS (0 mismatches) |
| `reports/irdrop/irdrop.rpt` | IR-drop summary |

`gds/` and `def/` are plain git blobs here, *not* Git LFS.

## Files intentionally dropped from LibreLane's full `final/` output

`spef/`, `sdf/`, `odb/`, `mag/`, `mag_gds/`, `klayout_gds/` — regenerable from
the P&R run, kept on NFS (`/srv/eda/runs/timothyn-dev/lora-mimo/5158/`). The
`reports/` here are copied from the run's stage dirs (`57-openroad-stapostpnr/`,
`66-magic-drc/`, `72-netgen-lvs/`, `58-openroad-irdropreport/`).
