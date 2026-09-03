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
pins in list order and wrapped them around the NW corner (a 26th, `ARRAY_ACQ_N`,
was appended 2026-08-30 and is not yet in any integrator-generated DEF):

| `info.yaml` entries | A40 slots | Edge |
|---|---|---|
| `VSS`, `IQ_DATA_{I,Q}_0..3`, `IQ_CLK`, `RESETB` (11) | W12–W22 | **West**, bottom→top |
| `REMOD_A_{I,Q}`, `PSRAM_SCK`, `PSRAM_CE_N`, `PSRAM_SIO_0..3`, `HOST_CS`, `SPI_{SCK,MOSI,MISO}`, `IRQ_OUT`, `VDD` (14) | N01–N14 | **North**, left→right |
| `ARRAY_ACQ_N` (1) — *added 2026-08-30, slot unconfirmed* | N15 | **North**, left→right |

`ARRAY_ACQ_N` is appended **after** `VDD` rather than inserted before it, so
every pin above keeps the slot job 5150 validated. Inserting it before `VDD`
would push `VDD` to N15 and break the reserved W12/N14 power slots (see the
VDD/VSS decision below). The ACV allocation is **28 slots** (confirmed
2026-08-30), so N15 spends one of three spares and leaves two — Open Risks #52.

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
provisional pending SI review.

## Name reconciliation for `FP_DEF_TEMPLATE`

The generator builds every DEF pin name as `<info.yaml pad>_<IO-cell terminal>`
(confirmed in `A40_ACV_interface.yaml`: `user_pin_name` + `cell_terminal`).
That convention is fixed — you cannot get `PSRAM_SIO_OUT_0` out of it without a
semantically wrong pad name.

**2026-08-28: the 18 functional ports in `src/top/trouper_top.v` were renamed
to match** (`PSRAM_SIO_OUT_{n}` → `PSRAM_SIO_{n}_OUT`; `REMOD_A_I` →
`REMOD_A_I_OUT`; `PSRAM_SCK` → `PSRAM_SCK_OUT`; `PSRAM_CE_N` → `PSRAM_CE_N_OUT`;
`SPI_MISO` → `SPI_MISO_OUT`; `IRQ_OUT` → `IRQ_OUT_OUT`). This also makes the RTL
self-consistent — the data ports now match the pad-control ties
(`PSRAM_SIO_0_OUT` alongside `PSRAM_SIO_0_IE`). **The integrator's raw
`A40_ACV.def` now matches `trouper_top` verbatim; no rename step.**

`rtl-test/scripts/a40_def_to_rtlnames.py` therefore only: keeps the `VDD`/`VSS`
boundary pin entries as delivered (see "Open / next"), and appends the 68
die-internal Grouper/AHB pins on a synthetic south row so every `trouper_top`
port is placed → `A40_ACV_rtlnames.def` (207 pins).

**Testbenches not yet updated** (deliberate): ~30 `cocotb/` + `rtl-test/tb/`
benches instantiate `trouper_top` with the old port names and will fail to
elaborate against the renamed `src/` until updated. Block regression / cocotb
is broken until then.

## P&R evidence (SGE, `config_1650x1100_full_rect` lineage, signoff SDC `v25_b6`)

| Job | Pin source | Die | Density | Route DRC | Magic DRC | WNS nom_tt | WNS max_ss | WNS max_ff |
|---|---|---|---|---|---|---|---|---|
| 5122 (`final/`) | `io_placement_lshape.cfg` | 1650×1100 | 78 | clean | 0 | 0.0 | **−12.45** | 0.0 |
| 5146 | `io_placement_a40.cfg` | 1650×1100 | 78 | — | — | — | — | — |
| 5147 | `io_placement_a40.cfg` | 1650×1100 | **72** | 0 viol | **0** | 0.0 | **−16.27** | 0.0 |
| 5150 | **`FP_DEF_TEMPLATE`** (`A40_ACV_rtlnames.def`, VDD/VSS dropped) | **1675×1110** | 72 | clear | **0** | 0.0 | **−12.26** | 0.0 |
| 5153 | `FP_DEF_TEMPLATE` (VDD/VSS boundary pins kept) | 1675×1110 | 72 | 0 | **0** | 0.0 | **−12.26** | 0.0 |
| 5154 | 5153 + **18 RTL ports renamed** to `<pad>_<terminal>` | 1675×1110 | 72 | 0 | **0** | 0.0 | **−13.40** | 0.0 |

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
  restored in the DEF. **They had no effect.** `FP_DEF_TEMPLATE` pin matching
  (`template_bterm_names`) excludes POWER/GROUND sigtype bterms from the strict
  check — the only reason 5153 passed with `VDD`/`VSS` present and no matching
  RTL port (invisible, not "handled") — and `FP_TEMPLATE_COPY_POWER_PINS`
  defaults `False` (unset here), so the template's coordinates were never
  copied. The PDN generated its own `VDD`/`VSS` boundary pins identically in
  5150 and 5153: the placed DEFs' `VDD`/`VSS` entries are byte-identical, at
  PDN-chosen locations, and all results (power-grid 0/0, IR drop 5.2 mV, WNS,
  DRC, XOR) match 5150 exactly.
- **5154** — the 18 functional ports renamed in `src/top/trouper_top.v`; the
  raw integrator `A40_ACV.def` now matches `trouper_top` verbatim (`ren` map in
  the transform script is empty). No name-mismatch at floorplan. Magic DRC 0,
  routing DRC 0, XOR 0, LVS 0/0, power-grid 0/0. max_ss −13.40 ns — ~1.1 ns off
  5153, within repair-pass variance (identical logic, die, density, SDC).

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

## 27-pin DEF regenerated — 2026-09-03

The integrator padframe tooling is now vendored and the template is generated
locally, not hand-patched:

- **Submodule** `ip/chipathon-2026-padring-system` = `d-m-bailey/padring_chipathon2026`
  @ `agent/project-padframe-makefile` — carries `chipathon2026-system/Makefile.padframe`
  and the `project-def-A40` target (the padring C++ tool + the Python
  integration layer that expands `info.yaml` onto the reserved slot arc).
- **`rtl-test/scripts/regen_a40_def.sh`** runs
  `make -f chipathon2026-system/Makefile.padframe project-def-A40` inside
  `hpretl/iic-osic-tools:chipathon26`, feeding `info.yaml` + `lvs_config.json`
  + `final/gds/trouper_top.gds`. It applies `ip/patches/padring-system-cstdint-gcc13.patch`
  (a two-line `<cstdint>` fix — the 2019 padring sources do not build under
  GCC 13) before the build and reverts it after.
- The tool measures `trouper_top.gds`'s `0/0` outline (1675 × 1110 µm) and
  selects the smallest fitting block variant — **ACV** — then wraps the 27
  pads around the W/N arc. Output: **159 pin entries**
  (`rtl-test/ol_trouper_top/A40_ACV_rtlnames.def`, copied to `src/config/`),
  = the 139 job-5150-validated entries **unchanged**, plus 10 control terminals
  each for `ARRAY_ACQ_N` (N15) and `DBG0` (N16) at **real generator
  coordinates**. This retires the synthetic-coordinate stopgap
  (`A40_ACV_rtlnames_dbgpins.def` + `a40_append_provisional_pads.py`, both
  removed / deprecated).
- New vs the old template: a `BLOCKAGES` section with the ACV Metal2 corner
  routing keepout (`( 322000 221600 ) ( 335000 222000 )` local) — the padring
  crosses that corner on Metal2. Trouper's floorplan already obstructs a die
  corner via `pdn_cfg.tcl` (`project_lshape_corner_not_actually_empty`);
  reconcile the two before the P&R re-run.
- **`info.yaml` fix:** pad was named `DBG0_OUT`; every other bidirectional pad
  uses the bare functional base and lets the generator append the terminal
  suffix. `DBG0_OUT` produced `DBG0_OUT_OUT` / `DBG0_OUT_OE` …, which do not
  match `trouper_top.v` (`DBG0_OUT`, `DBG0_OE`, …). Renamed the pad to `DBG0`.
- `a40_def_to_rtlnames.py` is now a **pure pass-through** — RTL port names match
  the generator's `<pad>_<terminal>` convention verbatim, `ren = {}`.
- Raw generator artifacts (`A40_ACV_interface.yaml`, `A40_ACV_pad_map.yaml`,
  `A40_ACV_padring.v`, `A40_selected_variants.json`) are under
  `rtl-test/ol_trouper_top/a40_integrator/`.

**Still owed:** integrator confirmation of slots N15/N16, and a P&R run against
this regenerated 27-pin template (Open Risks #52/#53). No run has been built
against it yet.

## Open / next

- **`info.yaml` order** — the 25-pin order is P&R-validated (all runs above);
  the appended `ARRAY_ACQ_N` (N15) + `DBG0` (N16) are **not** — no run has been
  built against the regenerated 27-pin DEF. Confirm the slots with the
  integrator and re-run before treating the pins as committed.
- **Die size — DECIDED 2026-08-28: defer to the integrator DEF (1675×1110).**
  The template defines the slot the shared padring actually reserves for
  Trouper; 1650×1100 was only Trouper's own internal target. Job 5150 already
  closed clean at 1675×1110. The signed-off `final/` bundle (1650×1100) will
  need a re-run at the template die for the production A40 build.
- **VDD/VSS — DECIDED 2026-08-29: option 1, accept the PDN's own edge pins.**
  `PDN_ENABLE_PINS: true` already puts `VDD`/`VSS` boundary pins on the M4/M5
  stripes at the die edge (distributed). The A40 padring bridges from its pad
  rails to the macro's PDN wherever it reaches the boundary — standard macro
  abutment; the exact W12/N14 match is the padring's job (`A40_ACV_padring.def`).
  `a40_def_to_rtlnames.py` keeps the template's `VSS`(W12) / `VDD`(N14) entries
  so the file matches the integrator artifact, but they are **inert** (see the
  5153/5155 findings above) and have no effect on the macro's power interface.
  - **Rejected: `FP_TEMPLATE_COPY_POWER_PINS: true` (job 5155, FAILED).**
    `Odb.ApplyDEFTemplate` still discards POWER/GROUND template bterms
    ("declared as a 'POWER' pin. It will be ignored"), but the flag also drops
    the POWER/GROUND exemption from the strict cross-check, so the design's own
    `VDD`/`VSS` bterms then fail "must exist in template". It breaks matching
    without delivering the copy — the template's power pins cannot be pulled
    into the macro this way.
  - If the integrator later requires the macro to declare `VDD`/`VSS` at exactly
    M2 / N14 / W12: add explicit `odb::dbBTerm_create` + placement + a short
    connect stripe in a custom `pdn_cfg.tcl` (bypasses ApplyDEFTemplate). ~15
    lines. Only if they say abutment won't otherwise connect.
- **Grouper/AHB placement** — *not part of the integrator flow at all*: no pads,
  absent from `info.yaml`, the regenerated `A40_ACV.def` will never contain
  them. The 68 synthetic south-edge pins the script adds exist only to satisfy
  `FP_DEF_TEMPLATE`'s "every port placed" rule. Real placement is the
  **Trouper↔Grouper abutment**, agreed between those two projects.
- **Name reconciliation** — DONE: the 18 ports renamed in `src/top/trouper_top.v`
  (2026-08-28). Remaining: update the ~30 testbenches to the new port names so
  block regression / cocotb elaborates again.

## Files

- `rtl-test/ol_trouper_top/config_a40_repin.json` — hand-cfg re-pin (jobs 5146/5147)
- `rtl-test/ol_trouper_top/io_placement_a40.cfg` — full 205-pin edge/order cfg
- `rtl-test/ol_trouper_top/config_a40_fpdef.json` — `FP_DEF_TEMPLATE` dry-run (5150)
- `rtl-test/ol_trouper_top/A40_ACV_rtlnames.def` — the FP_DEF_TEMPLATE (27-pin, regenerated 2026-09-03)
- `rtl-test/ol_trouper_top/a40_integrator/` — raw generator artifacts (provenance)
- `rtl-test/scripts/regen_a40_def.sh` — regenerates the two files above
- `ip/chipathon-2026-padring-system/` — the integrator padframe tooling (submodule)
- `ip/patches/padring-system-cstdint-gcc13.patch` — GCC 13 build fix for the padring tool
- `rtl-test/scripts/a40_def_to_rtlnames.py` — the transform
- `planning/Pinout.md` → "A40 pad-control tie-offs" — tie value table
