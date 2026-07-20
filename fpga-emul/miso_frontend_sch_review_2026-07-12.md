# MISO Front-End Schematic Re-Review — 2026-07-12

Follow-up to `miso_frontend_pcb_review_2026-07-08.md`, reviewed at commit `e3cd106`
("add manual reset connector"). Schematic-focused per request; layout/DRC deferred.
Checked with kicad-cli 10.0 ERC (26 → 22 violations) + full netlist trace.

---

## Fixed since 2026-07-08 ✓

| # | 2026-07-08 finding | Resolution |
|---|--------------------|------------|
| 1 | +3V3_DIG no source | Now fed from PMOD J8 VCC pins 6/12 (Arty 3.3 V — correct IO domain for U6). R14 0 Ω option to +3V3_RF is **DNP** ✓ (populated it would short Arty 3V3 to the LP5907 output — keep DNP, add silk note). C57 decoupling added. |
| 3 | No XTB coupling caps | C50–C53 10 nF series caps added: U7 CLKOUT → 33 Ω → 10 nF → XTB, all four radios. Nominal swing is still exactly 1.8 Vpp (10 nF blocks DC only, no attenuation) — at the datasheet limit but AC-coupled onto XTB's self-bias, acceptable. |
| 4 | 1G139 can never deselect | Replaced with **SN74LVC139A** (dual, per-decoder Ē). 1Ē pulled up via R21 10 k → default all-deselected ✓. Second decoder tied off (inputs/Ē grounded, outputs n/c) — fine. **But see New-1: Ē is not routed to the FPGA.** |
| 5 | RFFE_RST floating | R22 100 k pull-down added + J9 header ✓ float risk gone. **But see New-2: J9 as drawn cannot generate a reset.** |
| 8 | RF inputs bare | Full match added per chain: shunt 5.6 pF ∥ 12 nH-to-GND at SMA (DC/ESD drain), series 10 pF (DC block), series 15 nH, shunt 2.7 pF at RF_IN pin. Topology sound; verify values against the Semtech 868 MHz reference before ordering. |
| 9 | J9 supply mislabel risk | Power input is now USB-C (J10) 5 V: CC 5k1 pull-downs, CM choke FL1 + feedthrough C1 → LP5907 (5.5 V max) — over-voltage brick risk eliminated ✓. Budget unchanged: ~180 mA on a 250 mA LDO, RX-only OK. |
| — | Y1 TCXO "TBD" | Real part now: OW7EL89CANUXK7YLC-32M ✓. |
| — | (new since) PSRAM nCE | R19 10 k pull-up added — good bring-up safety. |
| — | (new since) U7 decoupling | C35/C54–C56 on +1V8_RF at the buffer ✓. |

Clock chain verified end-to-end by netlist: TCXO → C36 → R1/R2 bias → U7 CLKIN;
CLKOUT1–4 → R3–R6 → C50–C53 → XTB1–4. All connected.

---

## Critical — still open / new

### Open-1. PSRAM is STILL unpowered (finding #2, one-line fix)
The PSRAM sheet **pin** in `top_level` was renamed to `3V3_DIG`, but the hierarchical
**label inside `psram.kicad_sch` is still `3V3_IN`** — they don't match, so the net
`{U5.8, C5, C6, R19}` dead-ends. ERC: `hier_label_mismatch` ×2 + U5 VDD not driven.
Fix: rename the label inside the PSRAM sheet to `3V3_DIG`.

### New-1. NSS decoder enable is not connected to the FPGA — SPI is dead as drawn
`RFFE_NSS_nEN` contains only U6 pin 1 (1Ē) and R21 pull-up. With Ē permanently high
the decoder is permanently disabled → **no radio can ever be selected**. The fix that
introduced the enable never routed it to a header. Route it to a spare PMOD pin —
J6.1/3/7/9 and J7.1/4/7/9/10 are all free (J7.4 = Arty C15-adjacent bank, any works).

### New-2. J9 "manual reset" cannot reset anything
SX1257 reset is **active-high** (≥100 µs high pulse, datasheet §6.2.2) and R22 already
holds the net low. J9 pin 2 is **GND**, so shorting the jumper does nothing. Change
J9 pin 2 to **+3V3_RF** so a jumper short pulses the four RST pins high. (Keep R22 —
it defines the idle level.)

---

## Housekeeping (remaining ERC)

- **PWR_FLAG** needed on `+3V3_DIG` (sourced by connector J8) and `+5V_IN` (sourced by
  J10) — clears the 6 `power_pin_not_driven` errors (incl. U5 VSS, which is just GND
  lacking a flag on that sheet path).
- `RF` netclass referenced by 5 directive labels, still not defined in project settings
  — RF nets will route with default width/clearance.
- 8 `label_dangling` on `REF_CLK_1..4` (×2 each). Netlist connectivity is intact, so
  these are duplicate/offset label instances — worth cleaning so real dangles stay
  visible.
- U4 references missing library `sch_library` (lib_symbol_issues warning) — re-sync
  before layout.

## Deferred (not schematic)

- Findings #6/#7 (PMOD ↔ fpga-emul XDC mismatch, clock-capable pins): **CLOSED
  2026-07-12.** Pin positions moved again — CLK_OUT_1/2/3 stay at J5 pins 4/3/2,
  CLK_OUT_4 moved to J7 pin 3; under the reversed mating (J5→JD, J7→JB) all four
  land on MRCC-capable Arty pins. `vivado/arty_dsp_emul.xdc` `clk_meas[2]` was
  still pinned to the pre-respin pin (C15) after the CLK_OUT_4 move to D15 —
  fixed (`fpga-emul/vivado/arty_dsp_emul.xdc:212`) and cross-checked pin-by-pin
  against the full J5–J8 table above; every other assignment (I/Q data ×4,
  SPI MOSI/MISO/NSS, PSRAM ×6) already matched. Rebuilt BD (`make vivado_project`)
  and re-ran synth/impl/bitstream (`make vivado_synth`): 0 DRC errors, all timing
  constraints met (WNS +1.174 ns), bitstream written to `arty_dsp_emul.bit` —
  D15 placed and routed as a legal MRCC clock input, confirming the respin
  reasoning. Not yet validated on real hardware (JTAG bring-up / phase-lock
  measurement still pending).
- **Mounting orientation verified 2026-07-12** — the reversed header-order
  mapping (J5→JD, J6→JC, J7→JB, J8→JA) was a review assumption; confirmed
  correct two independent ways rather than taken on faith:
  1. **Silkscreen intent**: J5–J8 each carry a KiBuzzard label reading "PMOD D"
     / "PMOD C" / "PMOD B" / "PMOD A" respectively (label text recovered from
     the footprints' base64-encoded `kb_params` metadata, since KiBuzzard
     renders letters as silkscreen vector art, not searchable text) —
     `miso_frontend.kicad_pcb`, footprints `kibuzzard-6A4A80F1/80E4/8102/810E`.
     This is the designer's own stated intent, matching the review's mapping
     exactly.
  2. **Pin-for-pin correspondence**: cross-checked all 32 routed pins (8
     signal pins × 4 headers) against Digilent's official Arty A7 JA/JB/JC/JD
     pin-1…pin-10 table (`resources/Arty A7 Reference Manual - Digilent
     Reference.html`, §10 Pmod Connectors — also confirms Arty's own PMOD
     sockets are right-angle female connectors, matching this board's male
     right-angle headers). Every pin matched exactly (e.g. J5 pin1 → D4 = JD
     pin1; J5 pin10 → G2 = JD pin10), with **no pin1↔pinN inversion** —
     mechanically plausible for a rigid re-orientation but not what was
     actually built. Pin 1 mates with pin 1 throughout; the XDC re-pin is
     orientation-correct.
- DRC (copper-edge/mask-bridge/courtyard etc.) unchanged in character; re-review at
  layout completion.
