# Area Cut Contingency List

> **Status: archived baseline, not the current active macro.**
>
> This note models the older `mimo_rx_top` architecture from 2026-06-03: PicoRV32, hardware `weight_gen`, `energy_meas_coarse`, and the pre-TDM decimator arrangement. It is still useful as design history, but it is **not** the correct baseline for the current active `trouper_top` hard macro.
>
> For the current synthesis-only area breakdown of the active RTL, use:
> `planning/area-reduction-roadmap.md` §1 (canonical, refreshed 2026-07-28) and
> `rtl-test/syn_mimo_per_module/out_trouper_top_current_fd/stat_hier.txt`
>
> Current active `trouper_top` synthesis totals from SGE job `3683` (`2026-07-28`, FD TT):
> - top total: `935,082.7584 µm²`
> - largest blocks: `sd_decimator_poly` `340,000 µm²`, `training_acc` `146,000 µm²`, `sc_detector` `119,000 µm²`, `psram_buf_ctrl` `74,100 µm²`, `mrc_combiner` `55,900 µm²`
>
> Use this file only for historical comparison against the superseded CPU-containing architecture.

**Date:** 2026-06-03  
**Baseline:** NR=2, PicoRV32IM, HW weight_gen, TDM CIC (no FIR), ser-IQ mrc_combiner  
**Baseline die (65% eff. density):** ~2.43 mm² stdcell ~1,167k µm², macros 0.41 mm²

### Measured top-level (job 1249, AS cells, NR=4 CIC-only, ser-IQ mrc)

Full top-level synthesis of current `mimo_rx_top.v` (NR=4, 4× `sd_decimator_cic_only`, HW weight_gen, ser-IQ `mrc_combiner`, `energy_meas_coarse`, no NFE):

| Block | µm² |
|---|---|
| PicoRV32 core (incl. mul/div) | 286,493 |
| training_acc | 139,558 |
| weight_gen | 138,649 |
| sc_detector | 112,631 |
| reg_bank | 99,306 |
| mrc_combiner (ser-IQ) | 97,632 |
| sd_decimator_cic_only (×1 shown; ×4 total) | 74,940 × 4 = 299,760 |
| energy_meas_coarse | 68,394 |
| dc_removal | 50,009 |
| psram_buf_ctrl | 46,466 |
| packet_ctrl_fsm | 32,987 |
| sd_remod | 29,262 |
| picorv32_wrap glue | 22,448 |
| frontend_buf_ctrl | 17,502 |
| spi_slave | 17,472 |
| mimo_rx_top glue | 12,052 |
| spi_master | 10,241 |
| irq_ctrl + ahb_bus | 5,036 |
| **Total stdcell (NR=4)** | **1,598,073 µm²** |

NR=2 estimate (halve NR-dependent blocks): ~1,167k µm² (see per-block table above).

All synthesis figures AS cells (gf180mcu_as_sc_mcu7t3v3) unless noted.  
✓ = measured   ~ = estimated from planning analysis

---

## Active design choices with cheaper alternative

These are already-decided features that can be reversed if area is tight.

| # | Current choice | Alternative | Stdcell saving | Macro saving | Die saving (65%) | Measured? | Risk |
|---|---|---|---|---|---|---|---|
| 1 | PicoRV32IM | SERV | ~−250k µm² | — | ~−385k mm² → ~−0.38 mm² | ~ | Firmware latency: weight_gen routine takes ~800µs vs 50µs on PicoRV32; check all FW tasks fit in timing windows |
| 2 | HW weight_gen | SW weight_gen | −105k µm² | — | ~−0.16 mm² | ✓ | None — 160× timing margin at SF7; reg_bank saves ~0 extra |
| 3 | NR=2 | NR=4 | +~335k µm² | +~110k µm² | **+0.69 mm²** | ✓ | NR=4 is an upgrade, not a cut |
| 4 | TDM CIC (no FIR) | Shift-add FIR | +~213k µm² | — | **+0.33 mm²** | ✓ | FIR is an upgrade for filter quality |

---

## Additional cuts not yet deployed

These are independent of the choices above and can be stacked.

| # | Block | Cut | Stdcell saving | Measured? | Prerequisite | Risk |
|---|---|---|---|---|---|---|
| 5 | ~~noise_floor_est~~ | ~~Remove entirely~~ | ~~−34k µm²~~ | **Already done** | NFE (`noise_floor_est.v`) is not instantiated in `mimo_rx_top.v` — cut already taken. sigma2 path is energy_meas_coarse → noise_metric → reg_bank directly. | — |
| 6 | energy_meas_coarse | Remove entirely | −70k µm² | ✓ (baseline) | See removal notes below. Per-branch AGC via SX1302 branch-cycling (see [per-branch-rssi-via-sx1302.md](per-branch-rssi-via-sx1302.md)) — **zero new hardware, works without PicoRV32**. | **Low** |
| 7 | mrc_combiner | 16-bit → 12-bit weights (Option B) | ~−30k µm² | ~ | Narrow weight_gen output ports + reg_bank W shadow | Low — 12-bit gives 72 dB weight SNR |
| 8 | ~~DMEM SRAM~~ | ~~OCD 1024×8 → OCD 512×8~~ | — | — | ~~−58k µm² macro~~ | **Deprioritised — do not resize** |
| 9 | dc_removal | Remove entirely | ~−25k µm² | ~ | Confirm ADC DC offset acceptable | Low for AC-coupled RF path |
| 10 | spi_slave | Remove | −17k µm² | ✓ (baseline) | Host must always be SPI master | Low |
| 11 | psram_buf_ctrl | Remove | −46k µm² | ✓ (baseline) | Requires different lock-detect architecture | High — architectural change |

### energy_meas removal — implementation notes (#6)

`energy_meas_coarse` has three downstream consumers in `mimo_rx_top.v`:

| Consumer | Signal | Removal action |
|---|---|---|
| `packet_ctrl_fsm` | `energy_snap[0..3]` | Tie to `16'h0000`. Energy gating (`energy_gate_en`) is off by default (reg default = 0) so packet detection is unaffected. |
| `reg_bank` | `energy_snap[0..3]` | Tie to `16'h0000`. Firmware readback (0x40–0x47) returns 0 — acceptable if firmware doesn't use energy for decisions. |
| sigma2 path | `noise_metric[0..3]` | Tie to `10'h000`. sigma2_hw in reg_bank returns 0. |

**RTL change:** ~5 lines in `mimo_rx_top.v` — delete `u_em` instantiation, add four `assign energy_snap[k] = 16'h0;` and `assign noise_metric[k] = 10'h0;` lines. Tie `energy_valid`, `energy_snapshot_valid`, `noise_metric_valid` to `1'b0`.

No changes needed to `packet_ctrl_fsm`, `reg_bank` RTL — all handle zero inputs correctly.

### NW-MRC dependency on energy_meas_coarse

**Current hardware does standard MRC, not NW-MRC.** `sigma2_hw` (from `noise_metric`) is firmware-readback only — `weight_gen.v` does not consume σ² at all. NW-MRC is a firmware-only feature planned for the software weight computation path.

For NW-MRC, firmware needs per-branch noise estimates σ²_j. Without `energy_meas_coarse`:

| Option | Source | Per-branch? | Notes |
|---|---|---|---|
| Keep `energy_meas_coarse` | `noise_metric[j]` via reg_bank | ✓ Yes | Hardware path — lowest firmware overhead |
| PSRAM readback (firmware) | Σ(i²+q²)/M from buffered samples | ✓ Yes | See [psram-software-energy-meas.md](psram-software-energy-meas.md). Replaces both AGC and NW-MRC. 3.5–7% firmware budget. |
| `training_acc` noise_en window | `E_ref/M` from reg_bank | ✗ Ref-ant only | Arms before packet; gives σ²_ref only, not per-branch |
| Equal-noise assumption | — | N/A | Falls back to standard MRC: w_j ∝ conj(H_j) |
| ~~SX1257 RSSI via SPI~~ | ~~SX1257 register~~ | — | **Not available** — SX1257 has no RSSI register (confirmed from datasheet v1.2) |

**For co-located antennas** (both NR=2 antennas on the same PCB), LNA and ADC thermal noise is nearly identical across branches. Standard MRC is optimal when σ²_j are equal — the NW-MRC gain only materialises when one branch is significantly noisier than the other (e.g., near an interference source).

**Per-branch AGC dependency — critical constraint:**

`energy_meas_coarse` is the **only hardware source of per-branch signal level**. Neither the SX1302 nor the SX1257 provides per-branch RSSI:
- SX1302 RSSI: combined (post-MRC) output only — cannot drive per-SX1257 gain control
- SX1257: no RSSI register (confirmed from datasheet v1.2)

Without per-branch energy, all SX1257 gains must be set equally (fixed or from combined RSSI), which degrades performance when branch signal levels differ.

**Removal is safe only when PicoRV32 is present** and firmware uses live IQ polling or PSRAM readback for per-branch energy. In CPU-less configurations, `energy_meas_coarse` must be kept.

**Recommendation:** If deployment is co-located antennas with PicoRV32 present, remove `energy_meas_coarse` and use live IQ register polling for AGC (see [live-iq-agc-calibration.md](live-iq-agc-calibration.md)). If CPU-less operation or distributed antennas are required, keep the block.

### Software energy measurement via PSRAM — feasibility note

PSRAM stores decimated 8-bit IQ samples continuously (8 bytes per iq_valid, all branches). PicoRV32 could compute per-branch energy Σ(i² + q²) by reading back a symbol window from PSRAM — **replacing energy_meas_coarse entirely while keeping NW-MRC capability**.

**Timing budget (SF7, 125 kHz, 16 MHz PicoRV32):**

| Step | Operations | Cycles |
|---|---|---|
| PSRAM read (128 samples × 8 bytes, QPI burst) | ~128 × 15 cycles | ~1,920 |
| Software i² + q² per branch (128 × 4 multiplies) | ~512 × 5 cycles | ~2,560 |
| **Total** | | **~4,480 cycles = ~280 µs** |

Symbol budget at SF7 = 128,000 cycles (8 ms). Energy computation uses **3.5% of budget**. Scales linearly with SF — SF12 (4096 samples) uses 143,360 cycles = 9 ms, but the SF12 symbol period is 131 ms, so still <7% of budget.

**RTL additions required (small):**

1. **Expose full 23-bit write pointer to reg_bank:** `psram_buf_ctrl` outputs `wr_ptr` internally but only 7 bits reach reg_bank (reg 0x15). Need a 3-byte register (24 bits) for firmware to read the current write pointer and compute `energy_base = wr_ptr - M×8`.

2. **Firmware-triggered read mode in `psram_buf_ctrl`:** Current read mode only replays from `buf_base` set at sc_lock. Need a second "diagnostic read" mode: firmware writes a start address + byte count to reg_bank, psram_buf_ctrl reads that window and exposes bytes via a data register (or byte-at-a-time AHB read).

**Flow for NW-MRC with PSRAM energy:**
1. Packet detected (`sc_lock`). PSRAM has been buffering pre-preamble noise samples.
2. After `training_done`: firmware reads `wr_ptr` from reg_bank.
3. Firmware triggers diagnostic read of `M×8` bytes at `(wr_ptr - preamble_offset - M×8)` — the pre-preamble noise window.
4. Firmware computes σ²_j = Σ(i²+q²)/M per branch from noise samples.
5. Firmware computes NW-MRC weights: `w_j = conj(Z_j) / σ²_j`, writes to W shadow, commits.

**Net area impact:** Remove energy_meas_coarse (−70k µm²). Add ~5–10k µm² for the two reg_bank/psram_buf_ctrl additions. **Net: ~−60–65k µm².**

**Status:** Feasible, requires moderate RTL addition. Not yet implemented. Blocks energy_meas removal without losing NW-MRC.

---

## Stack analysis — how far can we go?

Starting from baseline ~2.43 mm² (ser-IQ already applied):

| Cuts applied | Stdcell | Macros | Die (65%) |
|---|---|---|---|
NFE (`noise_floor_est`) is already removed from the design — baseline already reflects this.

| Cuts applied | Stdcell | Macros | Die (65%) |
|---|---|---|---|
| Baseline (NR=2 + TDM CIC + ser-IQ, NFE already removed) | 1,167k | 0.41 mm² | **~2.43 mm²** |
| + SW weight_gen (#2) | 1,062k | 0.41 mm² | **~2.27 mm²** |
| + Remove energy_meas_coarse (#6) | 992k | 0.41 mm² | **~2.16 mm²** |
| + mrc 12-bit weights (#7) | 962k | 0.41 mm² | **~2.11 mm²** |
| + SERV (#1) on top of all above | 712k | 0.41 mm² | **~1.73 mm²** |

Sub-2.2 mm² achievable without SERV. Sub-1.8 mm² requires SERV.

---

## What is NOT worth cutting

| Block | Why not |
|---|---|
| mrc_combiner opt-C (fix post_gain_shift) | Measured: only −4k µm² — not worth register map change |
| energy_meas_coarse (vs remove) | Measured: coarse saves only −1.2k vs baseline; remove saves −70k |
| noise_floor_est_coarse (vs remove) | Coarse saves −8k, removal saves −34k — go all the way or not at all |
| CIC order reduction 3→2 | Marginal saving (~5k per instance); degrades alias rejection |
| reg_bank trimming | Measured: NR=2 reduction only −9k; sw weight_gen saves ~0 extra |
| spi_master | Needed for SX1257 configuration — cannot remove |
| frontend_buf_ctrl | Needed for SC detector delay buffer — cannot remove |
| packet_ctrl_fsm | Core control logic — cannot simplify significantly |

---

## Decision order if area is tight

Apply in this order (largest saving, lowest risk first):

1. **SW weight_gen** — zero risk, 160× timing margin. Do this first.
2. **Remove NFE** — if sigma2 path confirmed unused in final system.
3. **Remove energy_meas** — if AGC via firmware polling is acceptable.
4. **mrc 12-bit weights** — if weight_gen port change is acceptable.
5. **DMEM → 512B** — measure firmware footprint with all SW additions first.
6. **SERV** — last resort; validate all firmware timing windows before committing.
