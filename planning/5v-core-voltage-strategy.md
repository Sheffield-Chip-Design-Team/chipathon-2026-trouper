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

## 2026-08-19 — reference padring PDN ties VDD_CORE and VDD_IO to one net by default

Correction to the framing in `planning/Pinout.md` (which stated the two rails
are "separate, independently-tunable... NOT tied on-die... deliberate" — that
was wrong as a description of what's actually configured, and has been fixed
in that doc). Traced the chipathon integration reference
(`ip/sscs-chipathon-2026/resources/Integration/workshop_padring_librelane`)
and every `rtl-test/ol_trouper_top/*.json` config to see how power actually
reaches the padring:

- `gf180mcu_ws_io__dvdd` exposes `{DVDD, DVSS, VSS}` (no `VDD` pin);
  `gf180mcu_ws_io__dvss` exposes `{DVDD, DVSS, VDD}` (no `VSS` pin). The
  reference pad-ordering spec always places them as one adjacent pair per
  ring side (4 pairs total, one per edge) — that pair together is the only
  place *both* the pad-driver rail (`DVDD`/`DVSS`) and the core-logic rail
  (`VDD`/`VSS`) reach the die from off-chip. 8 physical pads total for the
  whole design.
- `config.yaml`: `VDD_NETS: [VDD]`, `GND_NETS: [VSS]` — one voltage domain,
  no secondary net declared. `PDN_CORE_RING: True` +
  `PDN_CORE_RING_CONNECT_TO_PADS: True` wires the core PDN ring straight to
  those same 4 tap pairs.
- No `brk2`/`brk5` breaker cell appears anywhere in the pad-ordering spec —
  the whole ring, core and pad rail alike, is one continuous, unsegmented
  domain as shipped.
- None of `rtl-test/ol_trouper_top/*.json` declares a second `VDD_NETS`
  entry, a `DVDD`-class net, or a second `dvdd`/`dvss` tap pair. (Most of
  those configs are core-block-only P&R runs with no padring instantiated at
  all — the padring/PDN question hasn't been exercised on a full-chip build
  yet.)

**What this does and doesn't change:** it doesn't touch §4's cell-level
finding — job 4347's SPICE characterization of `bi_24t` doing a genuine
core>pad down-shift still stands, and Open Risks #27 still tracks the
remaining structural unknowns (ESD/latch-up, sequencing, IR drop) on that
path. What changes is the layer below it: "the IO cell can do this" and "our
PDN config does this" are two different claims, and only the first was true.
Making `VDD_CORE`/`VDD_IO` actually independent means adding a real
secondary voltage domain to `pdn_cfg.tcl` (the `foreach vdd $::env(VDD_NETS)
...` secondary-net loop already in the file supports this pattern generically
— it's unused here) plus a second `dvdd`/`dvss` tap pair wired to it. That's
unbuilt PDN work, not a flag flip.

**Consequence for "raise the voltage, do we need a level shifter":** yes, as
things stand today. Push `VDD_CORE` to 4.5–5 V without doing the secondary-
domain PDN work above and `VDD_IO` rises with it on the same net — every pad
facing a 3.3 V-only external part (SX1257 ×4, APS6404L PSRAM, RPi SPI host,
the Grouper-facing signals) needs either the split-rail PDN work finished
(cell-level proven, integration-level not yet built, structural items in #27
still open) or external board-level level shifters as the fallback — and #27
already flags that fallback as hard for the high-speed bidirectional PSRAM
QSPI bus specifically (auto-direction translators don't cope with mid-
transaction direction reversal at up to 133 MHz).

**Aside, correcting a framing used earlier in this same voltage discussion:**
Grouper is not a padring-segment neighbor of Trouper. Per Open Risks #29,
Grouper and Trouper are two separately hardened MPW macros joined by an
AHB-Lite bus — not two projects sharing one physical padring. The
`brk2`/`brk5` ring-segmentation mechanism described in this repo's IO-cell
notes is real and does work as described for genuinely separate padring
citizens, but it isn't the mechanism connecting Trouper and Grouper.

## 2026-08-19 — external level-shifter part selection for the (b) fallback

Records the component-level answer for §4's option (b) — "uniform 5 V chip +
external PCB level translators" — since it's now the documented default
until the split-rail PDN work above exists. Not signal-specific analog
detail (belongs in a board/schematic doc if one exists); this is the general
selection criterion and part families, so the next person doesn't have to
re-derive it.

**The right category is dual-independent-supply, direction-controlled
translators, not auto-sensing shifters and not "regulated output" parts.**
These ICs have two separate power pins — `VCCA` (fixed low side) and `VCCB`
(variable high side) — supplied externally, not derived internally:

- `VCCA` ties to a fixed 3.3 V rail (SX1257 / APS6404L PSRAM / RPi host, all
  native 3.3 V).
- `VCCB` ties to `VDD_CORE` — 3.3 V today, 4.5–5 V if the split-rail
  contingency is ever adopted.
- `VCCA = VCCB` (3.3 V/3.3 V) is a normal spec'd operating point on these
  parts, not an edge case — it just behaves as a buffer/repeater. **This is
  the practical payoff:** populate the same BOM now; if `VDD_CORE` later
  moves to 5 V, only the net `VCCB` is tied to changes — no board respin,
  mirroring the "no silicon respin" property the split-rail contingency
  itself is chasing.

**Split by bus, matched to what's already in the RTL:**

| Signal group | Requirement | Candidate part family |
|---|---|---|
| PSRAM QPI (`SIO[3:0]`, up to 133 MHz, direction reverses mid-transaction) | Explicit `DIR` pin, not auto-sensing | TI `SN74AVC4T774` or Nexperia `74AVC4T245` (quad, one `DIR` per nibble group) |
| SPI (host + SX1257 ×4, ≤2 MHz host SPI) | Direction-controlled, lower speed | TI `SN74LVC2T45`/`SN74AVC2T245` (dual-bit) or `SN74AVC1T45` per line |
| Unidirectional (`IQ_CLK`, `IQ_DATA_*`, `RESETB`, `IRQ_OUT`) | Fixed direction, no `DIR` pin needed | Same families, `DIR` tied constant |

**Why the QPI row is the one that matters:** #27 already flags "auto-
direction translators do not cope" for this bus, and that's confirmed here
— auto-sensing parts (TXB0108/TXS0108-class) infer direction from bus
contention/edge timing and can't reliably track a direction reversal
mid-transaction at QPI speeds. A `DIR`-pin part sidesteps that by not
inferring anything: drive `DIR` from a real signal. `psram_buf_ctrl.v`
already generates exactly that signal for the QSPI ownership/direction
handover (the same signal behind the item-37 `QSPI_OWNER` fix) — wiring it
to the shifter's `DIR` pin is a direct reuse, not new design work.

**Not yet checked:** propagation delay / max toggle rate at these parts'
`VCCA=VCCB=3.3V` operating point vs `VCCB=5V` — datasheets typically show
edges a bit slower nearer the low end of the supported range. Re-verify
against the PSRAM QPI timing budget once a specific part and voltage
combination are chosen; this is a small additional timing cost stacking on
top of the SS-closure margin work, not evaluated yet either way.

**See:** Open Risks #27 (the fallback this documents), `planning/Pinout.md`,
`ss-corner-decimator-pacing-closure.md` (`u_psram` QSPI engine background).
