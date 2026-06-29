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
