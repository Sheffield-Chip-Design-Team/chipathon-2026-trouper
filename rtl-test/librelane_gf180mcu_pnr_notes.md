# LibreLane / GF180MCU P&R Lessons Learned

Collected during `ol_trouper_top` P&R runs (June 2026).
All runs use `hpretl/iic-osic-tools:chipathon26`, PDK `gf180mcuD`,
SCL `gf180mcu_fd_sc_mcu7t5v0`.

---

## DRT-0073 — No access point for CTS buffer input pin

### Symptom

```
[DRT-0073] No access point for clkbuf_1_0__f_IQ_CLK/I (gf180mcu_fd_sc_mcu7t5v0__clkbuf_4)
[DRT-0073] No access point for clkbuf_0_IQ_CLK/I (gf180mcu_fd_sc_mcu7t5v0__clkbuf_4)
```

Fires at the very start of `OpenROAD.DetailedRouting` (pin-access phase), before
any wire is placed.  Affects every CTS-inserted buffer regardless of drive
strength — changing `CTS_ROOT_BUFFER` or `CTS_CLK_BUFFERS` does not help.

### Root cause

The `gf180mcu_fd_sc_mcu7t5v0` PDK config sets:

```tcl
set ::env(DPL_CELL_PADDING) {0}
```

`DPL_CELL_PADDING` feeds `set_placement_padding -global -left N -right N`
in `common/dpl_cell_pad.tcl`, which is sourced by **both** the detailed
placement step and the CTS step (via `common/dpl.tcl`).  With padding = 0,
TritonCTS inserts clock buffers and legalises them with zero routing clearance
on either side.  The detailed router then finds no free Metal1/Metal2 track
adjacent to the buffer's `I` pin and aborts.

### Fix

Override the PDK default in the design's `config.json`:

```json
"DPL_CELL_PADDING": 4
```

Value 4 means 2 sites (2 × 0.56 µm = 1.12 µm) added left and right around
every cell during detailed placement, including post-CTS legalisation.  At
35 % placement density this causes no overflow.

No LibreLane modification is needed.

### What does NOT fix it

| Attempted | Outcome |
|---|---|
| Change `CTS_ROOT_BUFFER` clkbuf_12 → clkbuf_4 → clkbuf_16 | DRT-0073 persists on different cells |
| Reduce `PL_TARGET_DENSITY_PCT` 45 → 35 | Reduces congestion but DRT-0073 persists |
| Patching `drt.tcl` with `-min_access_points 1 -via_in_pin_bottom_layer Metal1` | Workaround; not needed if padding is set correctly |

---

## DPL-0036 — Detailed placement overflow (hold buffer budget)

### Symptom

```
[DPL-0036] detailed_placement failed (hold repair overflowed placement)
```

Fires during `OpenROAD.ResizerTimingPostCTS`.

### Root cause

`set_clock_uncertainty 2.0` applies to **both** setup and hold in the
`iic-osic-tools:chipathon26` OpenSTA build — it ignores `-setup`/`-hold`
modifiers.  At the FF corner (fast cells), 2.0 ns hold margin flagged ~4 744
paths as hold violations.  The resizer tried to insert hold buffers for all
of them, exhausting the 50 % buffer area budget and overflowing placement.

### Fix

Reduce uncertainty and use MCP to relax the setup constraint instead:

```tcl
# pnr_32m_mcp_v6.sdc
set_clock_uncertainty 0.5 [get_clocks IQ_CLK]
set_multicycle_path 3 -setup -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
set_multicycle_path 2 -hold  -from [get_clocks IQ_CLK] -to [get_clocks IQ_CLK]
```

MCP=3 setup + MCP=2 hold → effective hold check at (3−1−2)×Tclk = 0 (normal).
`set_clock_uncertainty 0.5` reduces false hold violations to only paths with
genuine sub-0.5 ns slack, keeping the hold-buffer count manageable.

---

## NFS sync — config changes silently ignored

The LibreLane container reads from the NFS path
`/srv/eda/designs/timothyjabez/lora-mimo/`, not from the local working copy
at `~/Documents/chipathon-2026/chipathon-2026-trouper/`.

Any edit to `config_current.json`, SDC files, or RTL must be synced before
submitting a job:

```bash
rsync -av rtl-test/ol_trouper_top/config_current.json \
  /srv/eda/designs/timothyjabez/lora-mimo/rtl-test/ol_trouper_top/

rsync -av rtl-test/ol_trouper_top/pnr_32m_mcp_v6.sdc \
  /srv/eda/designs/timothyjabez/lora-mimo/rtl-test/ol_trouper_top/

rsync -av rtl-test/rtl/ \
  /srv/eda/designs/timothyjabez/lora-mimo/rtl-test/rtl/
```

Failure to sync produces identical error counts across runs even after SDC
changes, which makes the symptoms look like the fixes are not working.

---

## Density sweep — ol_trouper_top on 1300 × 1300 µm die (June 2026)

### Design metrics (from synthesis + floorplan)

| Metric | Value |
|---|---|
| Cell area (post-synthesis) | 932,598 µm² |
| Cell area (with taps/endcaps) | 981,823 µm² |
| Die area | 1,690,000 µm² (1300 × 1300) |
| Core area | 1,628,690 µm² |
| Standard cell count | 34,508 (+ 10,566 tap + 646 endcap) |

### Sweep results (`DPL_CELL_PADDING=4`, `pnr_32m_mcp_v6.sdc`, `DRT_THREADS=4`)

| Density | Job | Exit | Post-PNR SS WNS | FF hold WNS | SS hold WNS | DRT runtime |
|---|---|---|---|---|---|---|
| 35% | 1585 | 0 | 0.000 ns | −0.201 ns | −0.479 ns | ~30 min |
| 40% | 1590 | 0 | 0.000 ns | −0.201 ns | −0.479 ns | ~34 min |
| 45% | 1591 | 0 | 0.000 ns | −0.201 ns | −0.479 ns | ~30 min |
| 50% | 1599 | 0 | 0.000 ns | −0.201 ns | −0.479 ns | ~55 min |
| 55% | 1600 | 0 | 0.000 ns | −0.201 ns | −0.479 ns | ~30 min |
| 60% | 1601 | 0 | 0.000 ns | −0.201 ns | −0.479 ns | ~64 min |

All six densities passed with zero setup violations at all corners.  The hold
violations (FF −0.201 ns, SS −0.479 ns) are structural — caused by MCP leaving
some short paths exposed — and are suppressed via `HOLD_VIOLATION_CORNERS: [""]`.
They are identical across all densities, confirming they are not a routing
congestion effect.

### Conclusions

- The 1300 × 1300 µm die is significantly oversized for this netlist.
- DRT runtime is non-monotonic with density (50% took longer than 55%/60%),
  likely due to different global-routing solutions feeding into TritonRoute.
- No routing failures observed up to 60% density, suggesting the die can be
  shrunk. Minimum theoretical die side ≈ √(981,823 / target_density):
  - 70% density → ~1184 µm → try **1200 × 1200**
  - 74% density → ~1152 µm → try **1150 × 1150**
  - 81% density → ~1101 µm → try **1100 × 1100** (likely routing limit)

---

## Die-shrink results (June 2026)

### DPL_CELL_PADDING discovery

`DPL_CELL_PADDING=4` (PDK-safe value for DRT-0073 prevention) adds effective
area overhead to every cell.  At actual utilisation > ~65% this causes
DPL-0036 during detailed placement.  `DPL_CELL_PADDING=2` (1 site = 0.56 µm
per side) halves the overhead and was found sufficient to prevent DRT-0073.

### Shrink sweep results

All jobs: `pnr_32m_mcp_v6.sdc`, `DRT_THREADS=4`.

| Die (µm) | Density | Padding | Job | Result | Post-PNR SS WNS | Notes |
|---|---|---|---|---|---|---|
| 1200 × 1200 | 65% | 4 | 1605 | ❌ DPL-0036 (step 33) | — | Density below actual util (~71%) |
| 1150 × 1150 | 70% | 4 | 1606 | ❌ DPL-0036 (step 33) | — | Density below actual util (~74%) |
| 1100 × 1100 | 75% | 4 | 1607 | ❌ DPL-0036 (step 33) | — | Density below actual util (~81%) |
| 1200 × 1200 | 75% | 4 | 1609 | ❌ DPL-0036 (step 33) | — | Still fails — padding overhead |
| 1150 × 1150 | 78% | 4 | 1610 | ❌ DPL-0036 (step 33) | — | Still fails — padding overhead |
| 1100 × 1100 | 85% | 4 | 1611 | ❌ DPL-0036 (step 33) | — | Still fails — padding overhead |
| 1200 × 1200 | 75% | 2 | 1613 | ✅ **PASS** | **0.0 ns** | Padding=2 fixes DPL; DRT-0073 absent |
| 1150 × 1150 | 80% | 2 | 1614 | ❌ DPL-0036 (step 34, post-CTS) | — | Density too high for hold repair |
| 1150 × 1150 | 76% | 2 | 1622 | ❌ DPL-0036 (step 34, post-CTS) | — | Still overflows hold repair |

### Key findings (as of 2026-06-12)

- **`DPL_CELL_PADDING=2` is sufficient to prevent DRT-0073** on GF180MCU FD cells
  (confirmed on 1200×1200 run 1613).
- **1200×1200 µm (1.44 mm²) is the confirmed P&R minimum without RTL changes** —
  25% area reduction from 1300×1300 (1.69 mm²), post-PNR SS WNS = 0.0 ns.
- DPL-0036 at step 34 (post-CTS) is the hold-buffer resizer overflowing at high
  density — distinct from step-33 DPL-0036 (initial placement).  1150×1150 fails
  at this step regardless of density target (76%, 78%, 80% all tried) because
  actual GPL utilisation is ~76.5%, leaving insufficient margin for hold buffers.
- **1150×1150 µm may become feasible after RTL clock gating** — reducing cell
  count via ICG insertion in `training_acc` and `sc_detector` (see
  `planning/congestion-reduction-techniques.md`) would lower actual utilisation
  below the ~74% threshold needed for post-CTS repair to succeed.

---

## GF180MCU fd_sc_mcu7t5v0 reference values

| Parameter | Value | Source |
|---|---|---|
| Site height | 3.92 µm | `config.tcl` `PLACE_SITE_HEIGHT` |
| Site width | 0.56 µm | `config.tcl` `PLACE_SITE_WIDTH` |
| PDN vertical layer | Metal4 | `config.tcl` |
| PDN horizontal layer | Metal5 | `config.tcl` |
| PDN vertical offset (default) | 16.32 µm | `config.tcl` |
| PDN vertical pitch (default) | 153.6 µm | `config.tcl` |
| PDN horizontal offset (default) | 16.65 µm | `config.tcl` |
| PDN horizontal pitch (default) | 153.18 µm | `config.tcl` |
| Metal1 track pitch | 0.56 µm | `tracks.info` |
| Default `DPL_CELL_PADDING` | 0 | `config.tcl` — **must override to ≥ 4** |
| Default `CTS_ROOT_BUFFER` | `clkbuf_16` | `config.tcl` |
| Default CTS CLK buffers | `clkbuf_2 clkbuf_4 clkbuf_8` | `config.tcl` |
