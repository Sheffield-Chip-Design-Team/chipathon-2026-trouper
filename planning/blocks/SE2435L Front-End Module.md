# SE2435L RF Front-End Module ×4

Board-level component (not part of the ASIC). See [System Architecture](../System%20Diagram.md) for context.

**Owner:** RF/analog team
**Status:** Selected — datasheet in `resources/SE2435L.pdf`

---

## Function

One SE2435L per antenna (×4). Provides external PA and LNA with integrated T/R switch, replacing the SX1257 internal PA/LNA for gateway-class power and sensitivity. Controlled directly by SX1257 TX_EN/RX_EN pins — no additional ASIC signals required.

---

## Key specifications

| Parameter | Value | Notes |
| --- | --- | --- |
| Frequency range | 860–930 MHz | Covers EU868 |
| PA output power | +27 dBm typ at VCC=4.0V | 860–870 MHz range; ETSI limit |
| PA gain | 30 dB typ | |
| PA turn-on/off | < 1 µs | From 50% CTX edge to 90% RF output |
| LNA gain | 16 dB typ | |
| LNA noise figure | 2 dB typ | |
| LNA IP1dB | −12 dBm typ | Active LNA mode |
| LNA IP1dB (bypass) | +10 dBm | Bypass mode — used during TX on other antennas |
| RX turn-on/off | < 1 µs | |
| Supply voltage | 2.0–4.8 V | Typ 4.0 V |
| Sleep current | < 1 µA | CSD=0, CTX=0, CPS=0 |
| RX supply current | 6 mA typ | LNA mode |
| TX supply current | 380 mA typ | +27 dBm output |
| Package | QFN-24, 4×4×0.9 mm | |

---

## Control pins and mode table

| Mode | CPS | CSD | CTX | ANT_SEL |
| --- | --- | --- | --- | --- |
| Sleep | 0 | 0 | 0 | X |
| RX bypass (no LNA) | 0 | 1 | 0 | X |
| RX LNA | 1 | 1 | 0 | X |
| TX (PA active) | X | 1 | 1 | X |
| Use ANT1 port | X | X | X | 0 |
| Use ANT2 port | X | X | X | 1 |

`1` = 1.6 V to VCC; `0` = 0 to 0.3 V; `X` = don't care. Control inputs are 1.6–3.6 V CMOS compatible.

---

## RF signal connections

| SE2435L pin | Connected to | Description |
| --- | --- | --- |
| `TR` | SX1257 RF port | Bidirectional — RX signal out to SX1257; TX drive in from SX1257 |
| `ANT1` or `ANT2` | Antenna | One port used; ANT_SEL ties select which |
| `PA_IN` | (via TX filter to TR path) | PA input — internal routing via TX_FLT |
| `LNA_IN` | (via RX filter from ANT) | LNA input — internal routing via RX_FLT |

The SE2435L internal T/R switch connects either the PA output or LNA input to the antenna port based on CTX.

---

## Integration with SX1257

> **OPEN ISSUE — SE2435L control source unresolved.** The SX1257 has **no TX_EN or RX_EN output pins** (verified against Table 1-1 of SX1257 datasheet v1.2). DIO0–DIO3 can only output `pll_lock_rx`, `pll_lock_tx`, and `xosc_ready` (Table 4-1) — not TX/RX enable signals. The source for SE2435L CTX and CPS signals must be decided before PCB layout. Options are listed in the per-antenna table below. **Action for board/system team.**

SE2435L control mapping:

| SE2435L pin | Effect | Source options |
| --- | --- | --- |
| `CTX` | High during TX: activates PA | SX1302 GPIO (for ant 1/2); GND tie (for ant 3/4 RX-only) |
| `CPS` | High during RX: activates LNA | SX1302 GPIO / RPi GPIO / ASIC GPIO pad (no spares) |
| `CSD` | Tie high for always-on power | VCC via pull-up resistor |
| `ANT_SEL` | Selects ANT1 | GND (tied low) |

In the SX1302+SX1257 reference gateway design, the SX1302 provides dedicated GPIO pins for TX_EN and RX_EN to control the external FEM. **For antennas 1/2** (TX+RX), CTX and CPS should be driven by SX1302 GPIO, which is already part of the SX1302 HAL FEM control path. **For antennas 3/4** (RX-only), see note below.

---

## Per-antenna configuration

| SE2435L | Antenna | Role | CTX source | CPS source | Notes |
| --- | --- | --- | --- | --- | --- |
| SE2435L_1 | Ant 1 | TX + RX | SX1302 GPIO (TX_EN) | SX1302 GPIO (RX_EN) | Driven by SX1302 HAL FEM path |
| SE2435L_2 | Ant 2 | TX + RX | SX1302 GPIO (TX_EN) | SX1302 GPIO (RX_EN) | Driven by SX1302 HAL FEM path |
| SE2435L_3 | Ant 3 | RX only | GND (tied low) | **TBD** — see note | RX-only, LNA protection needed during TX |
| SE2435L_4 | Ant 4 | RX only | GND (tied low) | **TBD** — see note | RX-only, LNA protection needed during TX |

**SE2435L_3/4 CPS source (open issue):** During the TX window, SE2435L_3/4 CPS must go low to put the LNA into bypass mode (IP1dB +10 dBm vs −12 dBm active). The ASIC has 0 spare pads, so a dedicated ASIC GPIO is not available. Options:
- RPi GPIO (2 extra pins): reliable but adds RPi-side TDD timing; RPi must assert CPS=0 before step 5 in the TX sequence.
- Hard-tie CPS high permanently and rely solely on SX1257_3/4 standby to stop corrupt IQ data, accepting the LNA compression risk (safe only if board isolation >37 dB — see below).
- SX1257_3/4 DIO pin: cannot output CPS/RX_EN per Table 4-1; not viable.

---

## TX isolation — LNA protection on RX antennas

During TX on antennas 1/2, SE2435L_3/4 remain in the RX path. The active LNA IP1dB is −12 dBm; at +27 dBm TX and ≥40 dB board isolation this puts −13 dBm at the LNA input — at or beyond compression.

**Plan A (CPS controllable):** Assert CPS=0 on SE2435L_3/4 during `tx_prep`. Bypass IP1dB = +10 dBm, which survives −13 dBm with 23 dB margin. SX1257_3/4 are also put into standby (`RegMode=0x01`) by firmware to stop corrupt IQ data regardless.

**Plan B (CPS hard-tied high):** Rely on board isolation only. Safe if isolation >37 dB (−10 dBm at LNA input < IP1dB −12 dBm). Firmware still puts SX1257_3/4 into standby to suppress corrupt IQ. LNA may experience mild compression but survives; SX1257 ADC output is gated by standby mode so no effect on received data.

**Decision needed:** Confirm CPS control mechanism before PCB layout; if RPi GPIO approach is used, add it to the TX sequence in [PicoRV32 Integration](PicoRV32%20Integration.md).

**Action for RF/analog team:** characterise actual board isolation at 868 MHz for the chosen antenna layout. If isolation exceeds 50 dB, Plan B is safe without any LNA bypass mechanism. If isolation is <37 dB and CPS cannot be driven, additional measures (limiter diode, or SE2435L_3/4 full sleep) are required.

---

## Ordering

| Variant | Part number | Notes |
| --- | --- | --- |
| ETSI EU868 +27 dBm | SE2435L (EK2 eval board) | 868–880 MHz, ETSI compliant |
| FCC 915 MHz +30 dBm | SE2435L (EK1 eval board) | 900–930 MHz |

For EU868 use the ETSI-matched version. Consult Skyworks for Gerber files before PCB layout.

---

## Related blocks

- [System Architecture](../System%20Diagram.md) — TX signal chain, RF isolation note
- [PicoRV32 Integration](PicoRV32%20Integration.md) — tx_prep/tx_done firmware sequences
- Datasheet: `resources/SE2435L.pdf`
