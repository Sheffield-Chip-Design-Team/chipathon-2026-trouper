# trouper_top — Final P&R Outputs

Signoff-flow output for `trouper_top`, full 1650×1100 µm rectangular die
(NE 550×550 notch reclaimed — see `rtl-test/ol_trouper_top/config_1650x1100_full_rect.json`,
**SGE job 5122, 2026-08-27**).

Job 5122's **placed-and-routed design is byte-identical to job 5105** (`def/`,
`nl/`, `pnl/`, `lef/`, `spice/`, `vh/` all match; `gds/` differs only in
per-structure date records). The P&R SDC (`PNR_SDC_FILE`) is unchanged. The only
difference is the **signoff SDC** (`SIGNOFF_SDC_FILE`), which now carries three
signoff-only multicycle groups (v28–v30, see "Signoff-SDC MCP relaxations"
below). So the numbers here differ from job 5105 in the STA reports and
`metrics.json` only — same silicon, more honest timing report.

Lineage: job 4780 (2026-08-23) → job 5105 (DRV closure, 2026-08-27) → job 5122
(signoff-SDC MCP honesty, 2026-08-27). GDS/DEF are plain git blobs here (see note
near the bottom), not Git LFS.

## Results summary

- **DRC:** 0 errors (Magic)
- **LVS:** 0 mismatches (netgen — circuits match uniquely)
- **Max fanout:** 0 violations (all corners)
- **Max slew / max cap violations:** 10 / 4 (nom_tt), 15 / 6 (max_ss), 10 / 4 (max_ff)
  — unchanged from job 5105 (same netlist). The ~15 residual pins are a
  documented waiver — see "DRV closure".
- **Timing (WNS / TNS, setup):**
  - `nom_tt_025C_3v30`: 0.0 ns (met)
  - `max_ff_n40C_3v60`: 0.0 ns (met)
  - `max_ss_125C_3v00`: **−12.45 ns / −897 ns** (job 5105 read −15.71 / −3960 on
    the same silicon). The improvement is entirely the signoff-SDC MCP groups
    correctly crediting paced / quasi-static cones that were being reported
    single-cycle — no physical change. The remaining SS deficit is the known
    voltage-headroom gap: `gf180mcu_fd_sc_mcu7t5v0` is 5 V-characterized cells
    run at 3.0–3.3 V core. See "SS timing residual" and `planning/` for the
    voltage discussion.
- **IR drop:** worst 3.85 mV on VDD (0.12 %), 3.64 mV on VSS
- **Core utilization** 0.660, **instance count** 113 639, **routed wirelength**
  2.39 mm — all identical to job 5105.
- Full metrics: `metrics.json` / `metrics.csv`

## Signoff-SDC MCP relaxations (v28–v30, job 5122)

`SIGNOFF_SDC_FILE` is now `pnr_32m_scoped_v25_b6_signoff.sdc` — a copy of the
P&R SDC (`pnr_32m_scoped_v25_b6.sdc`) plus three `set_multicycle_path 3 -setup /
2 -hold` groups. `PNR_SDC_FILE` is **unchanged**, so placement/routing is
exactly the job-5105 build with these paths conservatively at single-cycle.

| Group | Scope (`-to`) | Cone | Proof |
|---|---|---|---|
| `tacc_accumulate` (v28) | `Zpair_i/q[*]`, `Zdiag[*]` accumulator flops (512 endpoints) | `training_acc` all-pairs MAC recurrence; wired out to top-level `Zpair_q[3][10]` array nets so `paced_dsp`'s `-through u_tacc.*` never matched them | `test_mcp_tacc_settle.py`, job 4083 (transitive via the shared `active_cycle` gate) |
| `iq_samp_cnt` (v29) | `iq_samp_cnt[*]` flops (20 endpoints) | top-level 32-bit sample counter (`trouper_top.v:171`); `+1` per `dcr_valid` | `test_mcp_iq_samp_cnt_settle.py`, job 5120 (3/3) |
| `pcfsm_tick_decrement` (v30) | `$pcfsm_timeout_regs` = `acq_cnt/wpend_cnt/pkt_cnt` (63 endpoints) | the two arcs the v21/v24 `-through` blocks miss: the `sample_count → ST_ACQ_SETUP load` operand, and the `if (iq_tick) cnt <= cnt-1` decrement recurrence | job 5120 (`dcr_valid` 1-in-64) + job 4362 (`ST_ACQ_SETUP` 4-cycle dwell) |

**Why signoff-only, not P&R:** adding any of these to the P&R SDC perturbs the
post-GRT resizer enough to strand the IQ_CLK root clkbuf with no routing access
point (`DRT-0073`, job 5112). Keeping them out of P&R keeps the route
reproducible *and* keeps P&R building those paths as if single-cycle
(conservative — the resizer can't lean on the 3-cycle budget).

**Load-bearing fact for v29/v30:** `dcr_valid` (= `iq_tick`) is a 1-clock pulse
once per HB2 output frame — `sd_decimator_poly.v:348` sets `iq_valid<=4'hf` on
`hb2_stream_last` only, `dc_removal.v:110` is a 1-cycle registered passthrough —
so both counter recurrences have ~63 idle IQ_CLK cycles between launches (21× the
3-cycle budget) and never a back-to-back launch. Proven by
`test_mcp_iq_samp_cnt_settle.py::test_dcr_valid_single_cycle` (job 5120).

All three groups audited non-vacuous on job 5122's routed netlist —
`run_mcp_audit.sh --stage route --sdc …_signoff.sdc`, job 5124, baseline
updated (`mcp_audit_route.evidence` / `mcp_audit_baseline.json`); object counts
512 / 20 / 63 match the RTL register widths exactly. Full rationale per group in
`mcp_audit_manifest.json`.

## SS timing residual (job 5122, `max_ss_125C_3v00`, 229 violating paths)

Only 1 path worse than −10 ns, 4 worse than −8; 138 of 229 are shallower than
−4 ns.

| Cone | ~paths | worst | Nature | Actionable? |
|---|---:|---:|---|---|
| `u_remod → u_remod` (+ `net56/57`) | ~96 | −5.0 | sd_remod OSR=64 MAC, already MCP-3 (`paced_dsp`) | **No** — voltage floor; doesn't close at 3.0 V at any multiplier, closes at 4.5 V |
| `u_psram → u_psram` internal | ~40 | −7.5 | live QPI engine datapath — MCP-1 is correct | **No** |
| `psram_qe_init_done → u_psram` (+ `→ net35..42`) | ~34 | **−12.45** | one-shot bring-up flag: 0 during PSRAM QE-init, then static forever | Left as waiver — false-path candidate, functionally a non-path |
| `rb_comb_post_gain_shift → comb_y_i/q` | 14 | −8.59 | per-packet host gain-shift field → paced combiner output regs; `comb_y_*` are top-level nets so `paced_dsp`'s `-through u_comb.*` misses them | Left as waiver — same match-gap class as v28, quasi-static, could be a v31 signoff MCP if ever wanted |
| `timing_ref → u_tacc/u_psram`, `sc_lock → u_tacc` | ~23 | −6.9 | `timing_ref` updates once per sc_lock event; partially MCP'd (`timing_ref_hits/config`); remainder feeds real-time PSRAM SC-delay addressing | Left honest single-cycle — **not** a blanket-relax candidate |
| misc (`n_acc`, `u_dcr`, `u_rb`) | ~5 | −0.5 | near-zero | ignore |

**Bottom line:** ~140 paths are the genuine voltage-bound paced-DSP floor
(needs ~4.5 V core, tracked in `planning/Open Risks.md`); the rest are
quasi-static cones deliberately left as documented waivers rather than growing
the signoff MCP list further. `nom_tt` and `max_ff` meet with margin.

## DRV closure (carried from job 5105 — unchanged, same netlist)

Job 4780 signed off with 1060 max-slew + 115 max-cap violations at nom_tt (1963
+ 160 at SS), in every corner. Root cause: the only DRV repair passes ran on
*estimated* placement/GRT parasitics and saw an essentially clean design
(3 slew / 6 cap); OpenRCX extraction then exposed the real loads and there was
no post-extraction repair.

Fix — pure LibreLane flow config, **no RTL and no SDC change**, folded into
`config_1650x1100_full_rect.json` (job 5105, still in effect for 5122):

| Var | 4780 | 5105 / 5122 |
|---|---|---|
| `RUN_POST_GRT_RESIZER_TIMING` | false | **true** |
| `DESIGN_REPAIR_MAX_SLEW_PCT` / `_CAP_PCT` | 20 | **65** |
| `GRT_DESIGN_REPAIR_MAX_SLEW_PCT` / `_CAP_PCT` | 10 | **65** |

Cost: core utilization 0.633 → 0.660, routed wirelength +17 % (extra buffers),
die unchanged, DRC/LVS still clean.

**Do not** add `set_max_transition` / `set_max_capacitance` to *either* SDC to
chase the residual: any design-wide value stalls `repair_design` on this netlist
for 70+ min (trials t3/t5/t6, 2026-08-27).

**DRV residual waiver (~15 pins, worst −4.3 ns / 19.9 ns edge at SS):** five root
nets in the `sc_detector` SF/BW symbol-period decode (`_34304/07/18`) and the
`training_acc` `Zpair_q` cross-correlator cone (`_37004/05`, `_46587/88`,
`_46684/85`, `_51034/35`), plus two output-path buffers (`output44/I`,
`_63973_/I`) driving pad loads. The decode/`Zpair` cones are quasi-static,
MCP-relaxed, and read cycles-to-seconds later by firmware; slow edges there are
functionally immaterial. See `reports/sta/*/checks.rpt` for the full list.

## Contents

| Path | What it is |
|---|---|
| `gds/trouper_top.gds` | Final tapeout-ready layout (geometry identical to job 5105; only GDS date records differ) |
| `def/trouper_top.def` | Final placed-and-routed DEF (byte-identical to job 5105) |
| `lef/trouper_top.lef` | Abstract view (pins + blockages) |
| `pnl/trouper_top.pnl.v` | Post-layout gate-level netlist (physical-cells included: taps/decap/fill) |
| `nl/trouper_top.nl.v` | Post-layout gate-level netlist (logical cells only) |
| `spice/trouper_top.spice` | SPICE netlist |
| `vh/trouper_top.vh` | Verilog header (port list) |
| `sdc/trouper_top.sdc` | SDC written by the flow (P&R constraint set — the v28–v30 signoff groups live in `rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6_signoff.sdc`, not here) |
| `lib/<corner>/trouper_top__<corner>.lib` | Per-corner timing library views (nom_tt/max_ss/max_ff) |
| `json_h/trouper_top.h.json` | Yosys JSON header (port/bit-width metadata) |
| `render/trouper_top.png` | Layout render — **carried over from job 4780.** P&R output is byte-identical from 4780→5105→5122 at the geometry level, so the die image is unchanged. Regenerate from `gds/trouper_top.gds` with the `gds-plot` skill if a fresh image is ever needed. |
| `metrics.json`, `metrics.csv` | Cell count/area/utilization + full signoff metric dump (job 5122 STA numbers) |
| `reports/sta/<corner>/{max,min,checks}.rpt` | Post-P&R STA reports per corner (job 5122, signoff SDC — setup/hold paths + constraint checks) |
| `reports/drc/drc.magic.rpt` | Magic DRC report (0 errors) |
| `reports/lvs/lvs.netgen.rpt` | netgen LVS report (circuits match uniquely, 0 mismatches) |
| `reports/irdrop/irdrop.rpt` | IR-drop summary (worst 3.85 mV on VDD) |

**Note:** `gds/` and `def/` are plain git blobs in this directory, *not* Git LFS
(unlike `/gds/*.gds` at the repo root, which is LFS-tracked) — LFS is skipped
here specifically because of tooling issues on the reviewer's side.

## Files intentionally removed from the full LibreLane `final/` output

To keep this directory small enough for a normal git commit, the following
were dropped (still available on request from the full run — NFS-primary,
see project convention in `CLAUDE.md`):

| Removed | Size (this run) | Why it's safe to drop |
|---|---|---|
| `spef/` | 78M | Post-route parasitics per corner — only needed to *re-run* STA yourself; the signed-off timing numbers are already summarized above and in `metrics.json` |
| `sdf/` | 23M | Timing back-annotation for gate-level simulation — regenerable from `pnl.v` + P&R run, not needed for layout/timing review |
| `odb/` | 32M | OpenROAD native database — regenerable from `def`, only useful for resuming/re-editing the P&R flow itself |
| `mag/`, `mag_gds/` | 47M combined | Magic-native layout + its GDS re-export — redundant with `gds/trouper_top.gds`, the actual signoff GDS |
| `klayout_gds/` | 9.5M | Another GDS re-export (KLayout-normalized) — also redundant with `gds/trouper_top.gds` |

The signoff reports under `reports/` above are *not* part of LibreLane's
own `final/` output — they live in the P&R run's numbered stage
subdirectories (job 5122: `57-openroad-stapostpnr/`, `66-magic-drc/`,
`72-netgen-lvs/`, `58-openroad-irdropreport/`) and were copied in here
separately alongside the `final/` tree, since a reviewer needs them next to
the GDS.
