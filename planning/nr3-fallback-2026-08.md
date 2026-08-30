# NR=3 fallback — pin budget / die size contingency (2026-08-18)

> **PIN HALF SUPERSEDED 2026-08-30.** The A40 ACV allocation is confirmed at **28 pad
> slots**, not 22, so the pin-budget motivation for NR=3 is gone — Trouper fits at 25 pads
> with slots to spare. This doc is retained for the **die-size** half of the analysis and
> as the record of the NR=3 area/gain trade, which is still the reference if 4-antenna MRC
> ever has to be cut for area or timing rather than pins. See `planning/Pinout.md`
> allocation status and Open Risks #46, #52.

Records a validated fallback in case the Chipathon pin/die rules are enforced strictly:
**22 pads** (current Trouper pinout is 24: 23 signal + `VDD_CORE` — `VDD_IO` was removed
2026-08-19, see below) and a
**1117.5×1117.5 µm square die** (current signoff target is the 1200×1100 rectangle).
Neither constraint is met by the current NR=4 (4-antenna MRC) design. This doc records
that dropping to **NR=3** (3 antenna channels) closes both gaps, with real P&R evidence,
not just estimates — and records what it costs.

**Related:** [Pinout](Pinout.md), [System Architecture](System%20Architecture.md),
[Open Risks](Open%20Risks.md) #46.

---

## 1. Pin budget

Current `info.yaml`: 23 signal pads + `VDD_CORE` = **24** (`VDD_IO` removed 2026-08-19).

- `GND`/`VSS` was never a dedicated pad (shared across the whole die, per the padframe
  rules — see Pinout.md).
- **Confirmed 2026-08-19** (was speculative when this doc was first written): `VDD_IO` is
  the same net as `VDD_CORE` in the reference PDN config, not a Trouper-private second pin
  — dropping it takes the count from 25 to **24**. See
  `planning/5v-core-voltage-strategy.md` §2026-08-19.
- Dropping one antenna channel removes exactly `IQ_DATA_I_n` + `IQ_DATA_Q_n` = **2 pins**,
  landing at **22** — exactly the assigned budget, with no `IRQ_OUT` waiver needed on top.

No other pin cut gets there without cost-free tradeoffs: `IRQ_OUT` removal (poll
`IRQ_STATUS` over SPI instead) is low-risk and was the team's preferred waiver-request
option (−1 pin, needs no RTL beyond deleting the pad); a 3-wire half-duplex SPI merge of
`MOSI`/`MISO` gets a 2nd pin but touches `spi_slave.v`'s verified CDC suite and needs
host-side 3-wire support. Narrowing `PSRAM_SIO` (QPI→dual/single) or serializing the
`REMOD_A_I`/`REMOD_A_Q` outputs were both ruled out — see the pin-budget discussion this
doc supersedes for detail; not repeated here per the terse-specs convention.

## 2. Die size — real P&R evidence, not extrapolation

Three SGE jobs, same RTL base (`ebb7f1b` NR=3 cut — see §4), FD cells
(`gf180mcu_fd_sc_mcu7t5v0`), all corners run:

| Job | Config | Die | Result |
|---|---|---|---|
| 4480 | `config_1117sq.json`, NR=4 | 1117.5×1117.5 (1,248,806 µm²) | **FAILS — `DPL-0036`** detailed placement failure. `GPL-0302`: target density 0.88 too low for the available free area. Never reaches global routing. |
| 4482 | `config_1117sq.json`, NR=3 | 1117.5×1117.5 (1,248,806 µm²) | **PASSES.** Routes clean, `route__drc_errors` settles to 0 across iterations, **Magic DRC = 0, LVS = 0**. 4 antenna-violating nets / 5 pins outstanding (minor, not blocking, no diodes inserted yet). Setup WNS: nom/ff corners **0.0 (meets)**; `max_ss_125C_3v00` **−11.39 ns** — the pre-existing voltage-bound SS gap tracked project-wide (Open Risks #1), unrelated to channel count, not a new problem. |
| 4483 | `config_current_signoff.json`, NR=3 | 1200×1100 (signoff baseline) | **PASSES**, DRC=0/LVS=0. Included to get a clean area delta against the known NR=4 baseline (job 4376, same config) rather than only a pass/fail at the tight square target. |

**This directly answers the motivating question: at NR=3 the 1117.5×1117.5 square die is
placeable and routable; at NR=4 it fails outright at placement, before routing is even
attempted.**

## 3. Area delta (clean baseline comparison, job 4483 vs job 4376)

| | NR=4 (job 4376, `config_current_signoff.json`, 1200×1100) | NR=3 (job 4483, same config) |
|---|---|---|
| Stdcell area | 1,090,880 µm² | 992,757 µm² |
| Reduction | — | **9.0%** |
| Magic DRC / LVS | 0 / 0 | 0 / 0 |
| Setup WNS, `max_ss_125C_3v00` | −20.12 ns | −16.54 ns (+3.58 ns, still open) |

The 9.0% is an **understatement** of the true achievable NR=3 area saving — see §4, only
the decimator and `dc_removal` were actually resized; `training_acc` and `mrc_combiner`
still carry their full NR=4-shaped cross-correlator/combiner hardware, tied to a constant
rather than removed.

## 4. What was actually changed (throwaway probe, not a functional candidate)

Branch `worktree-agent-ab14bf8d5b76b53d4` (commit `ebb7f1b`, not merged, not intended to
be — this is a die-size/pin-count feasibility probe only, NOT bit-exact-verified, NOT
timing-re-derived for a true 3-slot TDM schedule):

- **`src/decimator/sd_decimator_poly.v`** — real resize. Per-channel arrays `[0:3]→[0:2]`,
  loop bounds `<4→<3`, TDM `STREAM_LAST` 7→6 with an explicit skip in the stream counter to
  avoid the old channel-3 slot encoding, `iq_valid` mask 4'hf→3'h7. This is the block that
  actually shrinks (it dominates decimator area; the shared HB1/HB2 MAC itself doesn't
  shrink with channel count, only the per-channel CIC front end and polyphase delay-line
  storage do).
- **`src/frontend/dc_removal.v`** — real resize. Only 3 `dc_removal_chan` instances now;
  channel-3 output tied to constant zero. Low-risk, each channel is fully independent.
- **`src/top/trouper_top.v`** — rewires the above; **all 8 top-level IQ pads
  (`IQ_DATA_I/Q_0..3`) left untouched**, so this RTL change alone does not require the pin
  cut in §1 — the two are independent levers that happen to combine to hit both budgets.
- **`src/combiner/training_acc.v`, `src/combiner/mrc_combiner.v`** — **deliberately left
  unmodified.** Antenna-3's contribution ties to a constant at the top level rather than
  being structurally removed, so their area is NOT reduced in this probe (understates real
  NR=3 savings — a full cut would also resize `training_acc`'s C(4,2)→C(3,2) cross-pair
  hardware and `mrc_combiner`'s 4-tap→3-tap sum).
- **Untouched, on purpose:** `reg_bank.v`, `psram_buf_ctrl.v`, `sc_detector.v`,
  `spi_slave.v`, `packet_ctrl_fsm.v` — kept out of scope to avoid touching blocks with
  existing verified test suites / tuned SS timing margins for what was meant to be a
  fast feasibility signal.

**A real NR=3 submission is a substantially bigger lift than this probe**: `training_acc`
register-map re-layout (Z-bank 0x40–0x6F shrinks 10→6 entries), `mrc_combiner` real 3-tap
resize, TDM burst-window re-derivation and SDC multicycle re-check for the changed
decimator schedule, and a full cocotb re-regression (the SF sweep and capture-playback
ZDIAG-ranking tests assume 4 branches). This doc is evidence the option is *viable*, not
a spec for executing it.

## 5. MRC cost of NR=3 (from first-principles, not measured — see conversation history)

- Combining gain: `10·log10(4) = 6.02 dB` (NR=4, matches the project's stated "~6 dB
  diversity gain") → `10·log10(3) = 4.77 dB` (NR=3). **Net loss ≈ 1.25 dB.**
- Diversity order drops 4→3: BER floor in fading channels degrades roughly as
  `SNR^-3` instead of `SNR^-4` at high SNR; deep-fade outage probability scales worse.
  Compounds with the existing ant0 SC-lock deep-fade SPOF ([[project_sc_detector_ant0_fade]]
  / Open Risks item on `sc_detector`) rather than mitigating it.

## Bottom line

If the 22-pin / 1117.5² rules are enforced strictly, **NR=3 is a real, P&R-validated
fallback** — not just theoretically feasible. Cost: ~9%+ area saved, ~1.25 dB MRC gain and
one diversity order given up, plus the RTL/verification lift in §4 to turn the throwaway
probe into a signoff-quality change. Preferred path remains the pin waiver
(drop `IRQ_OUT`, poll status instead) to keep NR=4 if the rule allows a 1-pin exception —
this doc exists so the NR=3 option is ready and evidenced if it doesn't.
