# MISO Front-End Test PCB Review — 2026-07-08

Review of `~/Documents/chipathon-2026/miso_frontend` (KiCad 10, reviewed at commit
`8dbbe8e` "update sch pdf", which includes `7b66aed` "sch: add power tree, 3V3,1V8 LDOs").
Checked with `kicad-cli sch erc` / `pcb drc` (KiCad 10.0.4), netlist-level analysis, and
primary datasheets: SX1257 V1.2, 5PB12xx, APS6404L-3SQR (all in trouper `resources/`),
plus TI LP5907 and SN74LVC1G139 datasheets (fetched).

Board state: schematic largely complete, layout at prelim placement (94 unrouted items
expected). ERC: 135 violations. DRC: 342 violations.

---

## Critical — board will not function as drawn

### 1. `+3V3_DIG` rail has no source (new with power tree)
U6 (NSS decoder) is the only thing on `+3V3_DIG`; the power sheet has a `3V3_DIG` sheet
pin but no matching hierarchical label inside — the rail dead-ends. Since U6 is driven by
FPGA GPIOs, powering it from the PMOD `3V3_IN` puts it in the correct IO domain and also
gives the currently-unused PMOD VCC pins a purpose.

### 2. PSRAM lost its supply (new with power tree)
The PSRAM sheet's local `3V3_IN` label (U5.8 + C5/C6) has no matching sheet pin in the
parent. U5 is unpowered. Tie to PMOD `3V3_IN` (FPGA drives its QPI bus) or `+3V3_RF`.

### 3. No coupling capacitors into XTB (all four radios)
U7 CLKOUTs drive SX1257 XTB DC-coupled through 33 Ω only (R3–R6). SX1257 datasheet
Fig 3-1 requires a series coupling cap CD, and the input "must never exceed 1.8 Vpp" —
a 1.8 V-supplied LVCMOS buffer swings exactly 1.8 Vpp, so any overshoot violates spec.
Add 4× series caps; consider slight attenuation.

### 4. NSS decoder (U6, 74LVC1G139) can never deselect all radios
Datasheet-confirmed: the 1G139 has **no enable pin** (A, B, Y0–Y3, GND, VCC only), so
exactly one NSS output is always low. SX1257 SPI frames are terminated by the NSS rising
edge, so firmware must "park" the select on another chip, and there is no all-idle state.
Fix: SN74LVC1G138 (3-to-8 w/ enables) or one half of SN74LVC139A (has per-decoder Ē),
with Ē driven by an FPGA "SPI active" GPIO or the SS line.

---

## Serious — fix before fab

### 5. RFFE_RST floats with no driver and no connector pin
Net joins the four SX1257 pin-9 resets and nothing else. Floating is OK for POR
(datasheet §6.2.1) but manual reset (pulse high ≥100 µs, §6.2.2) is impossible, and a
long floating trace across four chips invites spurious resets. J6/J7 have 4 spare PMOD
pins — route it to one.

### 6. PCB PMOD pinout diverges from fpga-emul XDC
XDC expects: JA = I/Q chips 0/1, JB = quad-SPI (4 discrete `ss_io[3:0]`), JC = I/Q
chips 2/3, JD = remod. PCB has: J5 = SPI + CLK_OUT_1..3 + IQ1, J6 = IQ2/3, J7 = IQ4 +
CLK_OUT_4, J8 = PSRAM + 2-bit NSS address. Also 4 discrete SS vs 2-bit encoded address.
One side must be reworked; header-to-header mapping (J5..J8 ↔ JA..JD) is undocumented.

### 7. Clock-capable / high-speed pin planning (Arty)
Only JB and JD have clock-capable pins; JA/JD have 200 Ω series resistors, JB/JC are
0 Ω. Board mounts with header order reversed: J5→JD, J6→JC, J7→JB, J8→JA (see pin map
below). Under this mapping all four CLK_OUTs land on MRCC clock-capable pins — good,
because SX1257 CLK_OUT should be the I/Q sampling clock (the FPGA's own 32 MHz is not
frequency-locked to the board TCXO; free-running sampling will bit-slip). CLK_OUT_1–3
are behind JD's 200 Ω series resistors (check edges at 32 MHz); CLK_OUT_4 on 0 Ω JB is
the cleanest. PSRAM lands on JA behind 200 Ω — acceptable since the system drives
SCLK at 32 MHz max (31 ns period; 200 Ω into ~15 pF pin+trace ≈ 3 ns RC, ~6 ns extra
round-trip on reads: fits, but include it in the read-timing budget alongside PSRAM
tCO). The APS6404L's higher ratings (84–109 MHz) are not needed here.

#### PMOD pin map: PCB vs fpga-emul XDC

Mapping: the board mounts over the Arty with the header order reversed —
**J5→JD, J6→JC, J7→JB, J8→JA** (pin 1 mates with pin 1 within each header).
Pins 5/11 are GND and 6/12 are `3V3_IN` on every PCB header (matching PMOD spec) and
are omitted. "CC" = clock-capable (MRCC/SRCC). JA/JD have 200 Ω series resistors on
the Arty; JB/JC are 0 Ω high-speed.

| Hdr | Pin | PCB net | Arty pin | CC / series R | XDC currently assigns |
|-----|-----|---------------------|----------|----------------|-----------------------|
| J5→JD | 1 | RFFE_SCK | D4 | SRCC / 200 Ω | `remod_i` |
| J5→JD | 2 | CLK_OUT_3 | D3 | MRCC / 200 Ω | `remod_q` |
| J5→JD | 3 | CLK_OUT_2 | F4 | MRCC / 200 Ω | (unused) |
| J5→JD | 4 | CLK_OUT_1 | F3 | MRCC / 200 Ω | (unused) |
| J5→JD | 7 | RFFE_MOSI | E2 | SRCC / 200 Ω | (unused) |
| J5→JD | 8 | RFFE_MISO | D2 | SRCC / 200 Ω | (unused) |
| J5→JD | 9 | Q_OUT_1 | H2 | — / 200 Ω | (unused) |
| J5→JD | 10 | I_OUT_1 | G2 | — / 200 Ω | (unused) |
| J6→JC | 1 | (n/c) | U12 | — / 0 Ω | `hw_iq_i[2]` |
| J6→JC | 2 | I_OUT_3 | V12 | — / 0 Ω | `hw_iq_q[2]` |
| J6→JC | 3 | (n/c) | V10 | — / 0 Ω | `hw_iq_i[3]` |
| J6→JC | 4 | I_OUT_2 | V11 | — / 0 Ω | `hw_iq_q[3]` |
| J6→JC | 7 | (n/c) | U14 | — / 0 Ω | (unused) |
| J6→JC | 8 | Q_OUT_3 | V14 | — / 0 Ω | (unused) |
| J6→JC | 9 | (n/c) | T13 | — / 0 Ω | (unused) |
| J6→JC | 10 | Q_OUT_2 | U13 | — / 0 Ω | (unused) |
| J7→JB | 1 | (n/c) | E15 | SRCC / 0 Ω | (unused) |
| J7→JB | 2 | I_OUT_4 | E16 | SRCC / 0 Ω | `SPI_0_0_io0` (MOSI) |
| J7→JB | 3 | (n/c) | D15 | MRCC / 0 Ω | (unused) |
| J7→JB | 4 | CLK_OUT_4 | C15 | MRCC / 0 Ω | `SPI_0_0_io1` (MISO) |
| J7→JB | 7 | (n/c) | J17 | — / 0 Ω | `SPI_0_0_ss_io[0]` |
| J7→JB | 8 | Q_OUT_4 | J18 | — / 0 Ω | `SPI_0_0_ss_io[1]` |
| J7→JB | 9 | (n/c) | K15 | — / 0 Ω | `SPI_0_0_ss_io[2]` |
| J7→JB | 10 | (n/c) | J15 | — / 0 Ω | `SPI_0_0_ss_io[3]` |
| J8→JA | 1 | PSRAM_SO_SIO1 | G13 | — / 200 Ω | `hw_iq_i[0]` |
| J8→JA | 2 | PSRAM_SIO2 | B11 | — / 200 Ω | `hw_iq_q[0]` |
| J8→JA | 3 | PSRAM_SI_SIO0 | A11 | — / 200 Ω | `hw_iq_i[1]` |
| J8→JA | 4 | PSRAM_SCLK | D12 | — / 200 Ω | `hw_iq_q[1]` |
| J8→JA | 7 | PSRAM_nCE | D13 | — / 200 Ω | (unused) |
| J8→JA | 8 | RFFE_NSS_A1 | B18 | — / 200 Ω | (unused) |
| J8→JA | 9 | RFFE_NSS_A0 | A18 | — / 200 Ω | (unused) |
| J8→JA | 10 | PSRAM_SIO3 | K16 | — / 200 Ω | (unused) |

Read-off from the table (J5→JD mapping): considerably better than the naive order —
CLK_OUT_1/2/3 land on MRCC clock-capable pins (F3/F4/D3) and CLK_OUT_4 on MRCC C15,
so any of the four can be the I/Q sampling clock, though CLK_OUT_1–3 sit behind JD's
200 Ω series resistors (RC lowpass with pin/cable capacitance at 32 MHz — measure edge
quality; CLK_OUT_4 on 0 Ω JB is the cleanest candidate). The PSRAM QPI bus lands on JA
behind 200 Ω, which is fine for the system's 32 MHz max SCLK (adds ~3 ns per crossing
to the read-timing budget; the APS6404L's 84–109 MHz headline rates are not used).
The one hard consequence: **the XDC matches nowhere** — every populated FPGA
assignment (remod, quad-SPI, hw_iq[0..3]) points at a pin the PCB uses for something
else, so the XDC/BD needs a full re-pin regardless (finding 6).

### 8. RF inputs bare
SMA pin → 9 mm trace → RF_IN (pin 27), no DC-block, no matching, no ESD. LNA is
common-gate 50 Ω/200 Ω selectable, but the pin carries LNA bias — Semtech reference
designs use at least a series DC-block cap. Check against SX1257 eval / CoreCell
reference schematic.

### 9. LP5907 budget check
U8 (LP5907-3.3, 250 mA max) carries 4× SX1257 RX (~35–40 mA each ≈ 150 mA) plus all of
U9's 1V8 load (buffer + TCXO ~20–30 mA) ≈ 180 mA total. Works, thin margin if TX or
higher TCXO drive is ever used. LP5907 VIN max is 5.5 V — label J9 for 5 V on silk
(9/12 V bricks would kill it).

---

## Housekeeping (ERC/DRC)

- `RF` netclass referenced by 5 directive labels but not defined in the project → RF
  nets get default width/clearance rules.
- 20 copper-edge clearance errors: edge-mount SMA pads at 0.4 mm vs 0.5 mm board rule —
  expected for edge-launch; add a rule exception.
- 83 solder-mask-bridge errors, mostly hand-drawn F.Mask segments near the SMAs —
  confirm the graphic mask openings are intentional.
- Unused SX1257 pins (I_IN, Q_IN, CLK_IN, RF_ON/OP, DIO0–3) and J7 pin 10 need
  no-connect flags.
- Y1 (TCXO) value still "TBD"; 58 lib-symbol + 52 lib-footprint mismatch warnings —
  re-sync project libraries before layout finalizes.
- 7 dangling tracks (RF feeds, PSRAM_nCE/SO, Q_OUT_3) — expected mid-route.

---

## Verified-good

- XTB (not XTA) used for external clock, XTA left open — per datasheet.
- TCXO → C36 AC-coupling → R1/R2 bias → U7 CLKIN — exactly the 5PB12xx-recommended
  input network (≥0.8 Vpp clipped-sine at VDD=1.8 V).
- 5PB1204 on 1.8 V is **mandatory** (1.8 V-only variant; 5PB1214 is the 3.3 V part) ✓.
- OE1–4 pull-ups (R7–R10) correct: OE pins are active-high with internal 120 kΩ
  pull-downs.
- VR_ANA/VR_DIG/VR_PA decoupling present on all four radios.
- PSRAM decoupling C5/C6 = 100 nF + 1 µF, exactly per APS6404L datasheet; wiring
  matches pinout; VDD 2.7–3.6 V so 3.3 V is fine.
- All four radios share one TCXO — coherent reference, required for MRC combining.
- Power tree architecture sound: J9 → LP5907-3.3 → `+3V3_RF` → LP5907-1.8 → `+1V8_RF`;
  radios on a clean LDO rail separate from PMOD supply.
- Shared MISO is safe: exactly one chip selected at a time (see #4 for the flip side).

## Status of findings across pulls

| # | Finding | First review | After power-tree pull |
|---|---------|--------------|----------------------|
| — | Radios/buffer/TCXO unpowered (+3V3/+1V8 no source) | Critical | **Fixed** (LDO tree) |
| 1 | +3V3_DIG no source | — | New |
| 2 | PSRAM unpowered | — | New (regression) |
| 3 | XTB coupling caps | Open | Open |
| 4 | 1G139 no-deselect | Open | Open (datasheet-confirmed) |
| 5 | RFFE_RST floating | Open | Open |
| 6 | PMOD pinout vs XDC | Open | Open |
| 7 | Clock-capable pin mapping | Open | Open |
| 8 | RF input bare | Open | Open |
| 9 | LDO budget / J9 voltage label | — | New (informational) |
