# trouper_top — Final P&R Outputs

Signoff-flow output for `trouper_top`, full **1675 × 1110 µm** rectangular die,
**zero antenna violations** — **SGE job 5198, 2026-08-29**, config
`rtl-test/ol_trouper_top/config_1675_c5_diodepad4.json`.

Supersedes job 5158 (same die, 26 antenna net / 35 pin violations).

## What this run fixes

Three organiser-reported issues, all closed:

1. **Die size.** The A40 shared-padframe integrator reserves **1675 × 1110 µm**
   for Trouper (`A40_ACV.def` `DIEAREA`, `A40_ACV_interface.yaml`
   `size_microns`). The `final/` before job 5158 (job 5122) was 1650 × 1100.
2. **Bounding box.** Same root cause — the GDS layer-0/0 bbox under-filled the
   reserved slot by 25 × 10 µm. Now `(0, 0) – (1675, 1110)` exactly, matching
   `lef/trouper_top.lef` `SIZE 1675.000 BY 1110.000` and the DEF `DIEAREA`.
3. **Antenna — 24 violating nets reported by review → now 0.**

## Antenna closure (`DIODE_PADDING: 4`)

Antenna *repair* was never the failure: global routing drives the count to zero
on its own. The problem was that the **inserted diodes crowded `IQ_CLK` clock
buffers and stole their routing pin access**, so detailed routing aborted with
`DRT-0073` / `DRT-1231`. `DIODE_PADDING` defaulted to `None`, leaving diodes free
to abut a clock buffer. Setting it to **4** resolves the interaction; 24 antenna
diodes are placed and detailed routing completes clean.

**Do not "fix" this by downsizing the clock tree.** The failing cell was a
`clkbuf_16` in every earlier run (jobs 5183, 5194, 5195), which makes it look
like the largest buffer's pin geometry is at fault. It is not — job 5197 dropped
`clkbuf_16` from `CTS_CLK_BUFFERS` and then failed on `clkbuf_4_3_0_IQ_CLK_regs/I`,
**a `clkbuf_12`, the very cell it had downsized to**. The failure follows the
clock tree to whatever buffer the diodes box in; buffer size is irrelevant.
Downsizing also costs skew (0.442 vs 0.312 ns) for no benefit.

`DPL_CELL_PADDING` is **not** an alternative lever: it is 2, and 3 causes
`DPL-0036` (diodes fail to legalize at all). `DIODE_PADDING` applies only to
diode cells and avoids that.

Full investigation record, including the levers that did **not** work:
`planning/antenna-closure-investigation-2026-08.md`.

## Delta from job 5158

Config is `config_1675x1110_full_rect.json` plus the antenna family
(`config_1675_loramimo_antenna.json` → `config_1675_c1_diodepad.json` →
`config_1675_c5_diodepad4.json`):

- `DIODE_PADDING: 4` (was unset)
- `DPL_CELL_PADDING: 2` (was 3 — 3 blocks diode legalization, `DPL-0036`)
- antenna repair is GRT+DRT mixed, not jumper-only

RTL, SDC, IO placement and die are unchanged from job 5158: `PNR_SDC_FILE =
pnr_32m_scoped_v25_b6.sdc`, `SIGNOFF_SDC_FILE = pnr_32m_scoped_v25_b6_signoff.sdc`
(v28–v30 signoff-only MCP groups, `SPI_SCK` at 2 MHz), `IO_PIN_ORDER_CFG =
io_placement_lshape_1675.cfg`. RTL is current `main` (post-PR #47, includes the
`trouper_ahb8_adapter` AHB-Lite endpoint) and carries **no** A40 rename /
pad-control tie-offs — that work lives on `pnr/trouper-a40-padframe-tieoffs`.

## Results summary

- **Antenna:** **0 violating nets, 0 violating pins** (24 diodes placed)
- **DRC:** 0 errors (Magic), 0 KLayout XOR differences
- **LVS:** 0 errors, 0 unmatched pins / nets / devices (netgen)
- **Max fanout:** 0 violations (all corners)
- **Hold:** WNS **+0.18 ns**, TNS 0 — clean at all three corners
- **Timing (setup WNS / TNS):**
  - `nom_tt_025C_3v30`: **+9.85 ns** (met)
  - `max_ff_n40C_3v60`: **+11.81 ns** (met)
  - `max_ss_125C_3v00`: **−13.15 ns / −329 ns** — *better* than job 5158's
    −13.52 ns, so not an antenna-fix regression. This is a **supply-headroom
    gap, not a design defect** — see "SS is a voltage problem" below. Worst path
    is the `ahb_re` → `reg_bank`/AHB read-decode cone (`_63059_ → _61493_`,
    IQ_CLK domain).
- **Clock skew:** 0.312 ns (max_ss)
- **Max slew / max cap:** 13 / 4 (nom_tt), 22 / 5 (max_ss), 17 / 4 (max_ff) —
  the documented DRV waiver, same class as job 5158. See "DRV residual".
- **IR drop:** worst 5.33 mV on VDD (0.16 %), min on-grid voltage 3.29 V
- **Core utilization** 0.646, **instance count** 123 841 (48 417 std cells),
  **routed wirelength** 2.04 mm
- Full metrics: `metrics.json` / `metrics.csv`

## SS is a voltage problem, not a design defect (job 5200)

The `max_ss_125C_3v00` setup gap is supply headroom: `gf180mcu_fd_sc_mcu7t5v0`
is a **5 V-characterised** library ("5v0") run at **3.0 V**, far below native.
**This netlist** was re-timed at the SS corner with only the cell Liberty
swapped — same netlist, same extracted SPEF, same signoff SDC:

| SS 125C corner | setup WNS | setup TNS | hold WNS |
|---|---|---|---|
| `ss_125C_3v00` (control) | −13.121 ns | −329.73 ns | +1.92 ns |
| **`ss_125C_4v50`** | **+2.704 ns — MET** | **0.0** | **+1.00 ns** |

The control reproduces this run's signoff figures (−13.146 / −329.21) to
**0.026 ns**, so the harness is faithful and the 4.5 V number is trustworthy.
At 4.5 V the design **meets 32 MHz outright with +2.70 ns margin and zero total
negative slack**, and hold stays clean — the setup win is not bought with a hold
problem.

Reproduce: `rtl-test/scripts/run_voltage_sta.sh` (STA only, no re-P&R; uses
`honest_sta.tcl`, inputs staged to `ol_trouper_top/vsta_inputs/`).

**This does not make the design signed off at 32 MHz.** Caveats:

- Requires a genuine **4.5–5 V core**, which is *not* the current plan. The
  reference PDN declares a single net with VDD_CORE/VDD_IO tied, so this means
  dual-rail plus PDN work and A40 integrator agreement.
- The IO ring must stay ~3.3 V regardless: SX1257 abs max **3.9 V**, APS6404L
  abs max **4.0 V**. So it is a hot core + 3.3 V IO ring + level shifting, not a
  uniform rail.
- **Hold must be re-signed at the fast 5 V corner** (`ff_*_5v50`), which is not
  in this run's `STA_CORNERS`. Higher voltage = faster silicon = more hold risk.
- Sign off the **3.0 V-optimised netlist at 4.5 V** (this reload, +2.70 ns), not
  a re-P&R targeting 4.5 V — the latter historically lands −7.1 to −8.4 ns
  because paths look easy at the target corner and the setup resizer stops early
  (the "resizer under-drive trap").
- The PDK ships only `ss_125C_1v62 / 3v00 / 4v50`. There is **no 3v60 SS
  liberty**, so "3.6 V is not enough" is an interpolation and cannot be measured.

Corner-policy decision for the team; tracked as Open Risk #1.

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
`run_mcp_audit.sh` — **re-audit against this run's routed netlist before
tapeout**; the job-5124 baseline was taken on the pre-AHB job-5122 netlist.

**Why signoff-only, not P&R:** adding any of these to the P&R SDC perturbs the
post-GRT resizer enough to strand the `IQ_CLK` root clkbuf with no routing access
point (`DRT-0073`) — the same clock-buffer access sensitivity that the antenna
diodes exposed.

## DRV residual (waiver)

`RUN_POST_GRT_RESIZER_TIMING = true` with `DESIGN_REPAIR_MAX_SLEW_PCT` /
`_CAP_PCT = 65` (and the GRT equivalents). Do **not** add `set_max_transition` /
`set_max_capacitance` to either SDC: any design-wide value stalls
`repair_design` on this netlist for 70+ min.

The residual pins sit in two quasi-static combinational cones:

- **`sc_detector` SF/BW symbol-period decode** — cells fed by `u_sc.sym_cnt[*]`,
  `rb_sf_cfg[*]`, `rb_bw_sel` (`sym_cnt` vs `M = 1<<(SF+sample_shift)`).
- **`reg_bank` / AHB read-address decode** — cells fed by `ahb_addr[*]`,
  `ahb_re`, `spi_reg_rd_addr[*]` (the readback mux, merged with the AHB read
  path).

Both re-evaluate only on config writes or host reads (SPI ≤ 2 MHz), settle far
within a cycle, and hold is clean — functionally immaterial. Full list:
`reports/sta/*/checks.rpt`.

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
| `metrics.json`, `metrics.csv` | Full signoff metric dump (job 5198) |
| `reports/sta/<corner>/{max,min,checks}.rpt` | Post-P&R STA per corner (signoff SDC) |
| `reports/drc/drc.magic.rpt` | Magic DRC (0) |
| `reports/lvs/lvs.netgen.rpt` | netgen LVS (0 mismatches) |
| `reports/irdrop/irdrop.rpt` | IR-drop summary |

`gds/` and `def/` are plain git blobs here, *not* Git LFS.

## Files intentionally dropped from LibreLane's full `final/` output

`spef/`, `sdf/`, `odb/`, `mag/`, `mag_gds/`, `klayout_gds/` — regenerable from
the P&R run, kept on NFS
(`/srv/eda/runs/timothyn-dev/lora-mimo/5198/trouper_1675_c5_diodepad4/`). The
`reports/` here are copied from the run's stage dirs
(`57-openroad-stapostpnr/`, `66-magic-drc/`, `72-netgen-lvs/`,
`58-openroad-irdropreport/`).
