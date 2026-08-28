# A40 shared-padframe integration — pin placement & tie-offs

2026-08-28. How Trouper's top-level P&R maps onto the A40 (ACV) shared
padframe, and the P&R evidence that the mapping routes and closes.

## The A40 mechanism

Trouper is one project on the shared **A40** pad ring (block code `A40_ACV`).
Each project publishes an `info.yaml` pin list; the integrator's padring tooling
(`padring_template.cfg` + `build/padframes/A40/...`) assigns each project a
contiguous arc of pad slots and emits per-project artifacts:

- `A40_ACV_pad_map.yaml` — slot ↔ pin ↔ io_type
- `A40_ACV.def` — **core pin-placement template**: every pad expanded to its full
  IO-cell control interface, all `FIXED` with coordinates (139 pins)
- `A40_ACV_padring.def` / `.v` / `_interface.yaml`

Current bundle: `tmp/A40.def.tgz`, `spec_blob_sha 7398a4da…`, dated 2026-08-23.

**`info.yaml` list order drives the placement.** The tooling took Trouper's 25
pins in list order and wrapped them around the NW corner:

| `info.yaml` entries | A40 slots | Edge |
|---|---|---|
| `VSS`, `IQ_DATA_{I,Q}_0..3`, `IQ_CLK`, `RESETB` (11) | W12–W22 | **West**, bottom→top |
| `REMOD_A_{I,Q}`, `PSRAM_SCK`, `PSRAM_CE_N`, `PSRAM_SIO_0..3`, `HOST_CS`, `SPI_{SCK,MOSI,MISO}`, `IRQ_OUT`, `VDD` (14) | N01–N14 | **North**, left→right |

The **Grouper interface is die-internal** ("Grouper will be internal"):
`GRP_*` (28), the AHB `H*` endpoint (~40 bits), and `IRQ_GROUPER` are **not**
pads — they abut Grouper on the south edge. `info.yaml` never listed them.

## No output-only cell → pad-control tie-offs in the block

The A40 padring has **no output-only IO cell**: every functional output sits on a
bidirectional pad (`gf180mcu_fd_io__bi_t`, or `bi_24t` for `PSRAM_SCK`). The
`A40_ACV.def` template exposes each pad's full control interface
(`_OUT/_IN/_OE/_IE/_CS/_SL/_PU/_PD/_PDRV0/_PDRV1`) as core pins.

`src/top/trouper_top.v` drives all of it from the block (commit `eadda94`):
**+106 ports** — 100 constant pad-control outputs + 6 unused `_IN` inputs, one
tie-off block. Tie values (pulls off, PSRAM fast/max-drive/input-enabled,
REMOD/MISO/IRQ mid-drive, `SPI_MISO_OE=1` per TRPR-SPS-008) are tabulated in
`planning/Pinout.md` → "A40 pad-control tie-offs". Drive-strength / slew are
provisional pending SI review. Functional port **names are unchanged**
(`PSRAM_SIO_OUT_0`, not the template's `PSRAM_SIO_0_OUT`) to avoid ~30 testbench
touch-points.

## Name reconciliation for `FP_DEF_TEMPLATE`

`FP_DEF_TEMPLATE` matches pins by exact name. 18 template pins use the
`<pad>_OUT/_IN/_OE` convention where Trouper's RTL differs — reconciled
**in the DEF** by `rtl-test/scripts/a40_def_to_rtlnames.py`:

| `A40_ACV.def` | trouper_top.v |
|---|---|
| `PSRAM_SIO_{n}_OUT` / `_IN` / `_OE` | `PSRAM_SIO_OUT_{n}` / `IN_{n}` / `OE_{n}` |
| `REMOD_A_I_OUT`, `REMOD_A_Q_OUT` | `REMOD_A_I`, `REMOD_A_Q` |
| `PSRAM_SCK_OUT`, `PSRAM_CE_N_OUT` | `PSRAM_SCK`, `PSRAM_CE_N` |
| `SPI_MISO_OUT`, `IRQ_OUT_OUT` | `SPI_MISO`, `IRQ_OUT` |

The script keeps the `VDD`/`VSS` boundary pin entries as delivered (see the
VDD/VSS item under "Open / next") and appends the 68 Grouper/AHB pins on the
south edge at synthetic coordinates so every `trouper_top` port is accounted
for → `A40_ACV_rtlnames.def` (207 pins).

## P&R evidence (SGE, `config_1650x1100_full_rect` lineage, signoff SDC `v25_b6`)

| Job | Pin source | Die | Density | Route DRC | Magic DRC | WNS nom_tt | WNS max_ss | WNS max_ff |
|---|---|---|---|---|---|---|---|---|
| 5122 (`final/`) | `io_placement_lshape.cfg` | 1650×1100 | 78 | clean | 0 | 0.0 | **−12.45** | 0.0 |
| 5146 | `io_placement_a40.cfg` | 1650×1100 | 78 | — | — | — | — | — |
| 5147 | `io_placement_a40.cfg` | 1650×1100 | **72** | 0 viol | **0** | 0.0 | **−16.27** | 0.0 |
| 5150 | **`FP_DEF_TEMPLATE`** (`A40_ACV_rtlnames.def`, VDD/VSS dropped) | **1675×1110** | 72 | clear | **0** | 0.0 | **−12.26** | 0.0 |
| 5153 | `FP_DEF_TEMPLATE` (VDD/VSS boundary pins kept) | 1675×1110 | 72 | 0 | **0** | 0.0 | **−12.26** | 0.0 |

- **5146** reached detailed routing then aborted `DRT-0073` "no access point" on
  CTS buffer `clkbuf_2_3_0_IQ_CLK_regs` (`clkbuf_16`). Global route was
  **0/0/0 overflow, ~47 % peak layer** — not congestion; a pin-access geometry
  failure, the `project_io_placement` / `project_drt1231_clkbuf` fragility.
- **5147** — `PL_TARGET_DENSITY_PCT` 78→72 cleared the `DRT-0073`. Full flow to
  magic DRC: **0 DRC, 0 routing violations**, nom_tt/ff met, max_ss −16.27 ns.
  Job state shows `FAILED` only from a post-DRC `DESIGN_DIR` NFS blip after
  step 66 — steps 1–66 completed, GDS streamed, XOR ran.
- **5150** — the `FP_DEF_TEMPLATE` flow, exact template coordinates. **Cleanest
  result**: 0 magic DRC, routing-DRC clear, **XOR 0 differences**, disconnected-
  pins clear, no `DRT-0073` at all. **max_ss −12.26 ns — matches the signed-off
  rectangular baseline (−12.45)**, ~4 ns better than the approximate cfg.
- **5153** — 5150 + the template's `VSS`(W12)/`VDD`(N14) boundary pin entries
  restored. PDN ring terminates on those pins: power-grid violations **0/0**,
  IR drop 5.2 mV. Magic DRC 0, routing DRC 0, XOR 0, LVS-unmatched 0, WNS
  byte-identical to 5150. 15 non-critical disconnected pins (the unused `_IN`
  legs on output-only pads), 0 critical.

Pin edges in every A40 run: **W** = IQ data/clk/rst (+pull ties); **N** =
REMOD / PSRAM / SPI / IRQ_OUT (+pad-control ties); **S** = GRP + AHB +
IRQ_GROUPER; **E** empty — the A40 assignment.

## Conclusions

1. **The A40 functional pinout routes and closes DRC-clean** at both die sizes.
2. **`FP_DEF_TEMPLATE` is the integration path**: exact integrator coordinates
   perturb placement *less* than an approximate edge-order cfg — SS timing is
   **neutral vs the signed-off build**, and the `IQ_CLK` clkbuf fragility does
   not appear.
3. SS WNS is voltage-bound regardless (`project_vdd_closes_ss_timing`); the A40
   re-pin adds no SS cost when built from the template.

## Open / next

- **`info.yaml` order** — the current order is P&R-validated (all runs above).
  Finalise it, then request the integrator regenerate `A40_ACV.def` from it.
- **Die size — DECIDED 2026-08-28: defer to the integrator DEF (1675×1110).**
  The template defines the slot the shared padring actually reserves for
  Trouper; 1650×1100 was only Trouper's own internal target. Job 5150 already
  closed clean at 1675×1110. The signed-off `final/` bundle (1650×1100) will
  need a re-run at the template die for the production A40 build.
- **VDD/VSS — DECIDED: keep** the template's boundary pin entries (`VSS` W12,
  `VDD` N14, `USE POWER`/`USE GROUND`). Job 5153: PDN ring terminates on those
  pins, power-grid violations 0/0, IR drop 5.2 mV, and timing/DRC byte-identical
  to the drop-them run (−12.26 ns SS, 0 DRC/XOR). No downside. They have no
  matching `trouper_top` RTL port — they attach to the PDN's special VDD/VSS
  nets. `a40_def_to_rtlnames.py` keeps them as delivered.
- **Grouper/AHB placement** — *not part of the integrator flow at all*: no pads,
  absent from `info.yaml`, the regenerated `A40_ACV.def` will never contain
  them. The 68 synthetic south-edge pins the script adds exist only to satisfy
  `FP_DEF_TEMPLATE`'s "every port placed" rule. Real placement is the
  **Trouper↔Grouper abutment**, agreed between those two projects.
- **Name reconciliation** — kept on the DEF side (`a40_def_to_rtlnames.py`). For
  the production build, decide DEF-side rename vs renaming the 18 ports in
  `trouper_top.v` (the ~30-TB churn).

## Files

- `rtl-test/ol_trouper_top/config_a40_repin.json` — hand-cfg re-pin (jobs 5146/5147)
- `rtl-test/ol_trouper_top/io_placement_a40.cfg` — full 205-pin edge/order cfg
- `rtl-test/ol_trouper_top/config_a40_fpdef.json` — `FP_DEF_TEMPLATE` dry-run (5150)
- `rtl-test/ol_trouper_top/A40_ACV_rtlnames.def` — reconciled template
- `rtl-test/scripts/a40_def_to_rtlnames.py` — the transform
- `planning/Pinout.md` → "A40 pad-control tie-offs" — tie value table
