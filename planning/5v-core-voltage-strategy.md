# 5 V Core Voltage — Candidate Strategy (UNCONFIRMED)

**Status:** OPTION under consideration, NOT yet committed. Date: 2026-06-24.

A candidate that appears to dissolve several of the hardest open problems at once.
Keep open; confirm the items in §4 before adopting.

## Why it's attractive

Measured (OpenSTA on v15g's already-routed design, identical netlist/SPEF/SDC,
only cell liberty swapped — job 2201):

| Corner | SS WNS @ 32 MHz |
|---|---|
| ss_125C_3v00 (3.0 V) | **−17.02 ns** (fails — our whole battle) |
| ss_125C_4v50 (4.5 V) | **+0.52 ns** (MEETS, zero TNS) |

`gf180mcu_fd_sc_mcu7t5v0` is a **5 V-designed** library run at 3.0 V — far below
native. At its 5 V operating point, worst-case slow/125 °C silicon closes 32 MHz
with margin and **no MCP, pacing, or barrel-shift tricks**.

## Problems it potentially solves simultaneously

1. **SS-corner timing** — closes outright (the central tapeout risk).
2. **Die area** — at 5 V the timing-repair buffering (which bloats area *and*
   congestion at 3.0 V, and makes SS *worse* when shrinking — v15f 1380 = −33 ns)
   largely vanishes → likely routes at a *smaller* die. **Quantified (2026-06-24):**
   placed cell area at 3.0 V is **~1.16 M µm²**, of which **~190 K is P&R timing-repair
   buffering + CTS** (vs the 973 K Yosys synth base). That ~190 K is voltage-dependent,
   so 5 V should cut util at a given die and *may lower the placement floor itself*
   (the 3.0 V floor is 1380×1100 @ **76.2%** util — the buffering is part of what
   sets it). Being tested: v20 (5 V corners; failed DPL at 1300/1320/1380 d50 —
   the 5 V default corner perturbs CTS/placement — retrying at 1450×1100, job 2207).
3. **Design complexity** — removes the need for the MCP/pacing/honest-SDC work
   (the DRT-1231 CTS fix still stands; it's routing-side, voltage-independent).

## §4 — Open items to CONFIRM before committing

- **IO voltage crossing.** Core 5 V must talk to 3.3 V SX1257 + APS6404L PSRAM.
  Two sub-options:
  - **(a) On-chip dual-rail (5 V core / 3.3 V IO).** GF180 IO cells (`bi_24t`)
    DO have separate core (VDD) + pad (DVDD) rails with level shifting, char'd at
    2.5/3.3/5 V. BUT the PDK only characterizes *single*-voltage IO (VDD=DVDD); a
    split rail — especially **core > pad** (the unusual down-shift direction) — is
    OFF the characterized envelope. Needs GF180 IO databook + SPICE + likely
    foundry confirmation. No IO databook shipped in the PDK to settle it.
  - **(b) Uniform 5 V chip + external PCB level translators** to the 3.3 V parts
    (SX1257 SPI ~4 sig, PSRAM QSPI ~6 sig). Keeps the die on one fully-characterized
    5 V domain; pushes the crossing off-chip where it's cheap/proven. **Lower risk;
    preferred if 5 V is adopted.**
- **Hold timing** re-signoff in the 5 V *fast* corner (ff_*_5v50) — higher V =
  faster = more hold risk.
- **Power** — P ∝ V²; 5 V vs 3.3 V is ~2.3× dynamic power. Check budget/IR-drop.
- **3.6 V is NOT enough** on a single 3.3 V rail — interpolating 3.0→4.5 V, 3.6 V
  only reaches ~−10 ns. Must get into the 5 V domain.
- **v20 result** (5 V @ 1300×1100) — confirm it both routes and closes; read the
  cell-area/util delta vs 3.0 V to quantify the buffering saving.

## Decision posture

Treat as the leading *alternative* to grinding honest-MCP closure at 3.0 V. Don't
commit until §4 items (esp. IO crossing path a-vs-b and the v20 PnR) resolve.
Relevant memory: [[project_vdd_closes_ss_timing]]. Related: planning/
area-reduction-roadmap.md, sge-pnr-scheduling-lessons.md.

## 2026-07-05 re-confirmation on the current 1200×1100 signoff netlist

Re-ran the same OpenSTA liberty-swap check (netlist/SPEF/SDC unchanged, only
the cell `.lib` swapped) against `RUN_2026-07-05_00-56-34`
(`ol_trouper_top`, 1200×1100, the current signoff run — DRC=0, LVS=0). Also
checked the corners GF180 actually ships for "less pessimistic than
`ss_125C_3v00`", since the PDK has **no SS corner at 25 °C** (only 125 °C and
−40 °C are characterized for SS):

| Corner | Setup WNS | Hold WS | TNS |
|---|---|---|---|
| ss_125C_3v00 (official signoff) | **−25.39 ns** | +0.25 ns | (large −) |
| ss_125C_4v50 | −7.10 ns | +1.13 ns | −640.01 ns |
| ss_n40C_4v50 | **+3.28 ns MET** | +0.63 ns | 0.00 |
| tt_025C_5v00 | **+9.10 ns MET** | +0.37 ns | 0.00 |

Confirms the 2026-06-24 finding still holds on the current 1200×1100 die: the
32 MHz SS wall is dominated by the 125 °C/3.0 V corner's pessimism, not a
structural timing problem. Both a realistic-silicon corner (TT 25 °C/5.0 V)
and a less-pessimistic SS point (−40 °C/4.5 V) close outright on the
as-routed 3.0 V-optimized netlist, with zero re-optimization. Bare
`ss_125C_4v50` (hot, 4.5 V) still doesn't fully close for the same reason as
the earlier B1 finding — the resizer under-drove paths that only look
critical at the corner it was targeting (3.0 V); a full re-PnR targeting
4.5 V, or the `-setup_margin ~9` resizer trick, previously recovered this to
+1.4 ns (job 3237) and is expected to do so again here.

**This does not close the risk** — it's still an open sign-off-corner policy
question (how much margin to require between "guaranteed worst-case" and
"realistic operating window"), not something OpenSTA resolves on its own.
See `planning/Open Risks.md` item 1.

## 2026-07-31 — first real 4.5 V-targeted full P&R closes clean (not just a reload)

Baseline for this round: `config_current_signoff.json` full signoff, job 3733,
`ss_125C_3v00` WNS **−18.18 ns** (worse starting point than the item-39 netlist
used in the 2026-07-13 entry above). An OpenSTA liberty-swap reload of that
exact netlist (`ss_125C_3v00` → `ss_125C_4v50`, no re-optimization, job 3736)
landed at **−1.13 ns**, TNS −3.18 — a ~17 ns delta consistent with prior
reloads, but for the first time landing *short* of MET because the 3.0 V
starting point was worse.

Two real full P&R runs against `STA_CORNERS` swapped to `max_ss_125C_4v50`
(same die 1200×1100, same `pnr_32m_scoped_v25_b6.sdc`, same
`config_current_signoff*.json` base, only the SS corner + LIB entry changed):

| Run | Config | `PL/GRT_RESIZER_SETUP_SLACK_MARGIN` | `ss_125C_4v50` WNS | TNS | DRC | LVS |
|---|---|---|---|---|---|---|
| Job 3737 | `config_current_signoff_4v50.json` | none (bare corner swap) | **−2.74 ns** | (nonzero, fails) | — | — |
| Job 3738 | `config_current_signoff_4v50_margin.json` | 9.0 ns | **0.0 ns (MET), worst slack +3.17 ns** | **0** | **0** | **clean** |

Job 3738 is a genuine full-signoff pass, not a reload trick: worst setup
slack +3.17 ns at `ss_125C_4v50`, 0 setup TNS at all three `STA_CORNERS`
(`nom_tt_025C_3v30`, `ss_125C_4v50`, `ff_n40C_3v60`), Magic DRC 0 errors, LVS
clean, 84.9% utilization — same die size as the current 3.0 V signoff.

This confirms the "bare swap under-drives, `~9 ns` resizer margin recovers
it" pattern (previously only shown at older die sizes/SDC — `config_ss45_
margin.json`/`config_current_signoff_bigger_margin.json`, both on the stale
1300–1380×1100 / `pnr_32m_scoped_v20.sdc` combination) now reproduces on the
**current** 1200×1100 / `v25_b6` signoff baseline. Configs, run scripts, and
raw run directories:

- `rtl-test/ol_trouper_top/config_current_signoff_4v50.json` (bare)
- `rtl-test/ol_trouper_top/config_current_signoff_4v50_margin.json` (+9 ns margin)
- Run dirs: `/srv/eda/runs/timothyn-dev/lora-mimo/3737/trouper_top_4v50_bare/run`,
  `/srv/eda/runs/timothyn-dev/lora-mimo/3738/trouper_top_4v50_margin/run`

**Cross-check (job 3739):** reloading job 3738's 4.5V+9ns-margin-optimized
netlist back against the original `ss_125C_3v00` liberty gives worst slack
**−12.08 ns**, TNS −3344.61 — better than the 3.0 V baseline (−18.18 ns, job
3733) by ~6 ns (the extra setup buffering the resizer added while targeting
4.5 V partially carries over), but nowhere near closing 3.0 V outright. The
two corners need genuinely different drive strength, not just "more
buffers everywhere":

| Netlist optimized for | WNS @ `ss_125C_3v00` | WNS @ `ss_125C_4v50` |
|---|---|---|
| 3.0 V (job 3733 baseline) | −18.18 ns | −1.13 ns (reload, job 3736) |
| 4.5 V + 9 ns margin (job 3738) | −12.08 ns (reload, job 3739) | **+3.17 ns MET** |

**Not yet checked:** hold margin at the fast corner (`ff_n40C_3v60`) with the
extra setup buffering the 9 ns margin adds — worst hold in job 3738 was
+0.164 ns at `ff_n40C_3v60` (positive, but noticeably tighter than typical;
worth a dedicated look before treating this as fully signed off). Still an
open corner-*policy* decision (3.0 V vs 4.5 V/dual-rail) per Open Risks item 1,
not a closed risk — this entry only proves 4.5 V P&R closure is now
demonstrated end-to-end on the current baseline, with a repeatable recipe.
