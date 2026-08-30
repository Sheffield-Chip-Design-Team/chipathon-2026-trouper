# ASIC Pinout

GF180MCU MIMO ASIC logical pad list. Total: **25 pads** (24 signal + `VDD_CORE`;
`GND`/`VSS` is shared across the whole die, not a per-project pad, not counted here).
**`VDD_IO` removed 2026-08-19** — it is the same net as `VDD_CORE` in every current PDN
config (no independent IO rail is actually built), so it isn't a second pin. See
`planning/5v-core-voltage-strategy.md` §2026-08-19, Open Risks #27.

**Allocation status (2026-08-19): possibly tighter than previously assumed, but one pin
closer than before.** This doc's pinout was drafted against a **<=26 pads** limit; the
team's actual assigned budget may be **22 pads**, and the signoff die (1200×1100) fails at
a stricter **1117.5×1117.5 µm** square target with default P&R settings — though a
floorplan-margin fix reopens NR=4 there too (clean signoff, timing closure still open; see
below). The `VDD_IO` removal above drops the count from 25 to **24**, so the gap to 22 is
now 2 pins, not 3 — but see `ARRAY_ACQ_N` below, added 2026-08-30, which spends one of
those pins back and moves the count to **25**. Either the `IRQ_OUT`-removal waiver (poll `IRQ_STATUS` over SPI instead,
−1 pin — low risk, no RTL beyond deleting the pad) needs one more pin cut alongside it, or
the validated NR=3 (3-antenna) fallback alone (−2 pins) now lands exactly on 22 without the
waiver. **See:**
`planning/1117sq-margin-reclaim-2026-08.md`, `planning/nr3-fallback-2026-08.md`, Open Risks
#46.

**Related:** [System Architecture](System%20Architecture.md), [Trouper Chip Specification](Trouper%20Chip%20Specification.md)

---

## Signal pads (24)

All signal pads use **GF180 5 V-capable IO cells**, run at **3.3 V**. There is one power
pad (`VDD_CORE`) and one shared ground (`GND`/`VSS`, not a per-project pad) — see the
supply section below for why `VDD_IO` isn't a separate listed pad. The `bi_24t` cell itself
*can* electrically support an independent pad-driver rail (`DVDD`/`DVSS`) at a different
voltage from its core-logic rail (`VDD`/`VSS`, SPICE-confirmed, Open Risks #27), but nothing
in the current PDN config uses that capability — full detail in the supply section below.

### RX data from SX1257 (8 pads, input)

See "Board wiring — I/Q orientation through the RX chain" below for the pin-level mapping and the SX1257 datasheet erratum.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_DATA_I[0]` | in | SX1257_0 I_OUT | 1-bit ΣΔ RX I stream, antenna 0 |
| `IQ_DATA_Q[0]` | in | SX1257_0 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 0 |
| `IQ_DATA_I[1]` | in | SX1257_1 I_OUT | 1-bit ΣΔ RX I stream, antenna 1 |
| `IQ_DATA_Q[1]` | in | SX1257_1 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 1 |
| `IQ_DATA_I[2]` | in | SX1257_2 I_OUT | 1-bit ΣΔ RX I stream, antenna 2 |
| `IQ_DATA_Q[2]` | in | SX1257_2 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 2 |
| `IQ_DATA_I[3]` | in | SX1257_3 I_OUT | 1-bit ΣΔ RX I stream, antenna 3 |
| `IQ_DATA_Q[3]` | in | SX1257_3 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 3 |

### Clock and reset (2 pads, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_CLK` | in | PCB TCXO buffer | 32 MHz master clock shared by ASIC and SX1257 receivers |
| `RESETB` | in | PCB reset / host | Active-low global reset |

### ΣΔ re-mod outputs to SX1302 (2 pads, output)

See "Board wiring — I/Q orientation through the RX chain" below for the pin-level mapping and the SX1257 datasheet erratum.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `REMOD_A_I` | out | SX1302 Radio A I | 1-bit ΣΔ MRC-combined output stream (I) |
| `REMOD_A_Q` | out | SX1302 Radio A Q | 1-bit ΣΔ MRC-combined output stream (Q) |

### PSRAM dedicated control (2 pads, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `PSRAM_SCK` | out | APS6404L `CLK` | PSRAM serial clock |
| `PSRAM_CE_N` | out | APS6404L `CE#` | PSRAM active-low chip enable |

### Host SPI (4 pads)

Dedicated interface for external register access and bring-up.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `SPI_MOSI` | in | Host SPI MOSI | Host-to-Trouper register writes and commands |
| `SPI_MISO` | out | Host SPI MISO | Trouper-to-host readback |
| `SPI_SCK` | in | Host SPI SCK | SPI clock, Mode 0, up to 2 MHz |
| `HOST_CS` | in | Host SPI chip select | Active-low slave select |

### Interrupt output (1 pad, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IRQ_OUT` | out | Host RPi IRQ GPIO | Dedicated level-high sticky interrupt (packet ready, preamble lock, etc.). Mirrors the inter-project `IRQ_GROUPER` line. |

### Array acquisition sync (1 pad, bidirectional) — NOT YET COMMITTED

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `ARRAY_ACQ_N` | bidir | Shared board net, one external pull-up | Active-low wired-AND acquisition-sync line between Trouper instances in one array. A chip pulls it low on a natural SC lock; an idle peer takes the falling edge as `sc_lock_sync`. Open drain is *emulated* — `A` is tied 0 and `OE` selects drive-low vs. Hi-Z. No device may drive it high. |

Acquisition aid only: it carries no sample data, phase, weights, or clock, and it
does not add spatial degrees of freedom to a single chip. Protocol, coherency
prerequisites, and the firmware-side combining story are in
`planning/array-acquisition-sync.md`.

**Status:** declared last in `info.yaml` (A40 slot N15, after `VDD`, so no
existing pin moves), but the slot is unconfirmed by the integrator and the pad
has had no electrical review. Open Risks #52 and #53. Drop this entry if the
slot is refused — nothing else in the design depends on it.

### PSRAM data bus (4 pads, bidirectional)

Dedicated PSRAM QPI data nibble. JTAG and GPIO have been removed (no TAP in RTL; see Trouper Chip Specification §4.16), so these four pads carry only `PSRAM_SIO[3:0]`.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `PSRAM_SIO[0]` | bidir | APS6404L `SIO0` | PSRAM QPI data bit 0 |
| `PSRAM_SIO[1]` | bidir | APS6404L `SIO1` | PSRAM QPI data bit 1 |
| `PSRAM_SIO[2]` | bidir | APS6404L `SIO2` | PSRAM QPI data bit 2 |
| `PSRAM_SIO[3]` | bidir | APS6404L `SIO3` | PSRAM QPI data bit 3 |

---

## Board wiring — I/Q orientation through the RX chain (2026-08-30)

Trouper sits between four SX1257s and the SX1302, replacing what would otherwise
be a direct radio→concentrator link. I and Q are **not interchangeable**:
swapping them conjugates the signal, which inverts the LoRa chirp direction. The
pad order below is already correct and **must not be "tidied"** — see the
non-adjacency and erratum notes.

### The rule: wire by pin *name*, end to end

| Signal | SX1257 pin | → Trouper pad | → SX1302 pin |
|---|---|---|---|
| I, antenna 0 | 15 `I_OUT` | `IQ_DATA_I_0` (W13) | — |
| Q, antenna 0 | 14 `Q_OUT` | `IQ_DATA_Q_0` (W14) | — |
| I, antenna 1 | 15 `I_OUT` | `IQ_DATA_I_1` (W15) | — |
| Q, antenna 1 | 14 `Q_OUT` | `IQ_DATA_Q_1` (W16) | — |
| I, antenna 2 | 15 `I_OUT` | `IQ_DATA_I_2` (W17) | — |
| Q, antenna 2 | 14 `Q_OUT` | `IQ_DATA_Q_2` (W18) | — |
| I, antenna 3 | 15 `I_OUT` | `IQ_DATA_I_3` (W19) | — |
| Q, antenna 3 | 14 `Q_OUT` | `IQ_DATA_Q_3` (W20) | — |
| Combined I | — | `REMOD_A_I` (N01) | 41 `RADIO_A_IQ[3]` |
| Combined Q | — | `REMOD_A_Q` (N02) | 44 `RADIO_A_IQ[0]` |
| 32 MHz clock | 10 `CLK_OUT` | `IQ_CLK` (W21) | 43 `RADIO_A_CLK_I` |

Name-based wiring reproduces Semtech's own reference topology: the SX1302
datasheet's Table 2-1 peer column maps `RADIO_A_IQ[3]` ← SX125x `DIO4`/`I_OUT`
and `RADIO_A_IQ[0]` ← `DIO1`/`Q_OUT`, i.e. by name. Inserting Trouper in the
middle preserves that as long as both halves follow names.

SX1302 pins 45 / 48 / 49 (`IQ[1]`, `IQ[4]`, `IQ[2]` — TX `I_IN`, `Q_IN`,
`CLK_IN`) are unused: Trouper is receive-only.

### ⚠ Erratum — the SX1257 pin table contradicts itself

`DS_SX1257_V1.2.pdf` pin list, verbatim:

```
14   Q_OUT   O   Digital baseband data output from I (inphase) channel ADC
15   I_OUT   O   Digital baseband data output from Q (quadrature) channel ADC
```

The pin **named** `Q_OUT` is **described** as carrying I, and vice versa. The
table above follows the **names**, because the SX1302 side is name-consistent and
name-based wiring reproduces the reference design. **Do not re-derive this from
the description column.** Resolve it by measurement at bring-up (see
`Test Plan.md` → "I/Q orientation check"), never from the document.

Compounding the trap: pins 14/15 are adjacent in **Q-then-I** ascending order,
while Trouper's pads ascend **I-then-Q**. The visually tidy, non-crossing fanout
at the SX1257 is therefore the **wrong** one. Each antenna's pair must cross.

### SX1302 I and Q are not adjacent — this is fine

Pins 41 and 44 straddle `RADIO_A_MISO` (42) and `RADIO_A_CLK_I` (43), so no pad
ordering yields a clean parallel two-wire run; the pair must fan around two pins
at the SX1302 end regardless. That is a trivial routing cost and **not** a reason
to reorder pads. What matters is that the ascending order matches — I on the
lower pin, Q on the higher — so `N01→41`, `N02→44` routes **without crossing**.

The west-edge interleave (`I0,Q0,I1,Q1,…`) is likewise deliberate: four separate
SX1257s each fan out to one adjacent pad pair. Grouping all I then all Q would
drive every Q trace across four pads.

### Consequences of getting it wrong

There is **no I/Q swap or invert control in the RTL or register map** — this was
considered on 2026-08-30 and deliberately rejected (see below). A wiring error is
a board rework, so it is worth catching at bring-up rather than in a PER sweep.

- **Uniform swap (all four antennas)** — `Z → conj(Z)`, `w → conj(w)`, output
  conjugated. Benign-ish and consistent: a uniform spectral inversion.
- **Per-antenna swap (one branch only)** — the dangerous case. `Z_kl` between a
  swapped and an unswapped branch becomes a pseudo-correlation averaging toward
  zero over random phase, so **that branch gets ≈zero MRC weight while its
  `ZDIAG` power reading stays healthy**. No crash, no flag — a silent drop from
  4-branch to 3-branch diversity (≈1.2 dB) that a bench test would not notice.

**Why no swap register bit:** a mux pair at the combiner *output* is downstream
of the combining, so it can fix only the uniform case — which is equally fixable
by the board rework that caused it — and cannot un-swap a single input branch,
which is the case that actually costs diversity. The mitigation is the bring-up
`Z_kl` check in `Test Plan.md`, which catches both cases at zero silicon cost.

### Clock note

`IQ_CLK` (W21), SX1302 pin 43 and the SX1257s all need the same 32 MHz. That is a
multi-load net, and `IQ_CLK` is `input_cmos` with no hysteresis precisely because
the duty-cycle budget has no margin (see "Pad cell type selection" below) — so
this net wants the fanout buffer (`resources/DS_5PB12xx_ClockBuffer.pdf`) rather
than a daisy chain. Separately **to be confirmed**: the SX1257 pin table calls
`CLK_OUT` a "36 MHz digital clock output" while the whole design assumes 32 MHz;
check this against the XTAL/TCXO plan, not against the datasheet line.

---

## A40 pad-control tie-offs (shared-padframe integration, 2026-08-28)

The A40 (ACV) workshop padring exposes each pad's full IO-cell control interface to
the core, and has **no output-only cell** — every functional output sits on a
bidirectional pad. `trouper_top.v` therefore drives all pad-control pins itself
(`src/top/trouper_top.v`, "A40 padframe pad-control tie-offs" block) so integration
is a straight wire-up with no assumptions about a padring wrapper. 106 added ports:
100 constant outputs + 6 unused `_IN` inputs.

**Drive-strength encoding.** `PDRV` is a 2-bit code on `bi_t`. Written below in
`info.yaml`-legacy order as `PDRV0,PDRV1` — note this is the *reverse* of the
binary code, so read carefully:

| `{PDRV1,PDRV0}` | written below as | Drive | Measured edge @12 pF (10–90%) |
|---|---|---|---|
| `00` | `0,0` | 4 mA | 4.78 ns |
| `01` | `1,0` | 8 mA | 2.44 ns |
| `10` | `0,1` | 12 mA | 1.68 ns |
| `11` | `1,1` | 16 mA | 1.31 ns |

`bi_24t` (`PSRAM_SCK` only) has no `PDRV` — fixed 24 mA. The mA values come from
a peer project's annotations and are **not** confirmed against a GF180 IO
databook, but they are corroborated by the PDK's own liberty transition times:
the measured edges scale 1.00 / 1.94 / 2.78 / 3.50 against an ideal 1 / 2 / 3 / 4.

Slew `SL` is provisional pending SI review **except `PSRAM_SCK_SL`, which is
fixed** — see the constraint note below the table.

| Pad group | Added control pins (per pad) | Tie value |
|---|---|---|
| 13 input pads (`IQ_DATA_{I,Q}_0..3`, `IQ_CLK`, `RESETB`, `HOST_CS`, `SPI_SCK`, `SPI_MOSI`) | `_PU`, `_PD` | `0`, `0` — on-chip pulls off; board supplies SPI-CS / reset pull-ups |
| `PSRAM_SIO_0..3` (true bidir; `_OUT/_IN/_OE` already existed) | `_IE`, `_CS`, `_SL`, `_PU`, `_PD`, `_PDRV0`, `_PDRV1` | `_IE=~_OE`, `_CS=0`, `_SL=0`, `_PU=0`, `_PD=0`, `_PDRV0=1`, `_PDRV1=1` — input enabled only while the lane is released, CMOS, fast, no pull, max drive. This prevents the uncharacterized `IE=OE=1` state of `gf180mcu_fd_io__bi_t`. |
| `PSRAM_CE_N` (output on `bi_t`) | `_IN`(unused), `_OE`,`_IE`,`_CS`,`_SL`,`_PU`,`_PD`,`_PDRV0`,`_PDRV1` | `_OE=1`, `_SL=0` fast, drive `1,1` max, rest `0` |
| `PSRAM_SCK` (output on `bi_24t`, drive fixed) | `_IN`(unused), `_OE`,`_IE`,`_CS`,`_SL`,`_PU`,`_PD` | `_OE=1`, `_SL=0` fast, rest `0` |
| `REMOD_A_I`, `REMOD_A_Q` (output on `bi_t`) | as `PSRAM_CE_N` | `_OE=1`, `_SL=0` fast, drive `1,1` **max (16 mA, raised from `1,0`/8 mA on 2026-08-30)**, rest `0` |
| `SPI_MISO`, `IRQ_OUT` (output on `bi_t`) | as `PSRAM_CE_N` | `_OE=1` (Option A: host link point-to-point, per TRPR-SPS-008), `_SL=1` slow, drive `1,0` mid, rest `0` |
| `ARRAY_ACQ_N` (emulated open drain on `bi_t`) | `_OUT`,`_IN`,`_OE`,`_IE`,`_CS`,`_SL`,`_PU`,`_PD`,`_PDRV0`,`_PDRV1` | `_OUT=0` always, `_OE` = core drive request (this is the open-drain emulation), `_IE=1`, `_CS=1` **Schmitt** (long shared board net), `_SL=1` slow, `_PU=0`/`_PD=0` (board pull-up is mandatory), drive `0,0` min 4 mA |

**`PSRAM_SCK_SL = 0` is a hard constraint, not a provisional value.** The
APS6404L specifies `t_KHKL` (CLK rise/fall time) as a **maximum of 1.5 ns**,
measured 20–80%. Liberty transitions are 10–90%, so the limit is ≈2.0 ns at
10–90% (`t₂₀₋₈₀ ≈ 0.75 × t₁₀₋₉₀` for a linear ramp). On `bi_24t` at a realistic
~13.6 pF load: `SL=0` gives 1.12 ns (0.84 ns at 20–80%, ~44% margin), while
`SL=1` gives 2.19 ns (1.64 ns at 20–80%) — **a datasheet violation**. `SL=0`
holds up to roughly 28 pF. Do not slow this pad to damp ringing; use a series
resistor instead, and keep it ≲33 Ω so the added RC stays inside `t_KHKL`.

**Why the PSRAM lanes are at max drive.** Under-drive is unfixable once the die
exists — nothing on a board can speed up a weak driver — whereas an over-driven
net can be damped with a series resistor. Drive is therefore biased high
deliberately. For calibration: every silicon-proven design on wafer.space Run 1
(shuttle G801) ran **24 mA** on all bidirectional pads via `bi_24t`, including
several booting from external SPI flash, so 16 mA here is *below* proven-working
drive rather than above it. Series-resistor footprints (0402, populated 0 Ω)
close to the ASIC pin on `SIO[3:0]`, `CE_N`, `SCK` and `REMOD_A_{I,Q}` are the
intended post-silicon lever and should be on the PCB.

**Verification (2026-08-29).** These values are asserted against this table by
`cocotb/pad_tieoffs` (`cocotb/tests/test_pad_tieoffs.py`, job 5223) — all 96
constants in reset and re-checked every clock through live QPI traffic, plus
`PSRAM_SIO_n_IE == ~_OE` per lane — and structurally by
`sim/tests/test_pad_tieoff_ports.py` (no undriven pad-control output). The
suite was negative-controlled against three injected faults (job 5225). **If a
value in the table below changes, update the RTL, this table, and the expected
table in `test_pad_tieoffs.py` together** — the test reads this document as the
source of truth, not the RTL. See `planning/Traceability.md` §"A40 pad-control
tie-offs".

`SPI_MISO_OE` is tied `1` (not gated by `HOST_CS`): the SPI slave already drives
`SPI_MISO=0` when deselected (TRPR-SPS-008) and the host MISO net is point-to-point.
Flip to `~HOST_CS` only if the integrator confirms a shared host-SPI MISO bus.

As of 2026-08-28 the 18 functional ports in `src/top/trouper_top.v` were renamed
to the A40 generator convention `<pad>_<terminal>` — `PSRAM_SIO_{n}_OUT/_IN/_OE`,
`REMOD_A_{I,Q}_OUT`, `PSRAM_SCK_OUT`, `PSRAM_CE_N_OUT`, `SPI_MISO_OUT`,
`IRQ_OUT_OUT` — so the integrator's `A40_ACV.def` matches `trouper_top` verbatim
(no name mapping on hook-up). Testbenches still use the old names and are being
updated separately. Grouper `GRP_*` / AHB `H*` / `IRQ_GROUPER` are die-internal
(south abutment edge), not pads.

---

## Pad cell type selection (`info.yaml` `io_type`) — reviewed 2026-08-30

`io_type` in `info.yaml` selects the physical IO cell. **This is Trouper's
choice, not the integrator's** — unlike the pull/slew/drive tie-offs above,
there is no core-side pin for it, so it can only be changed here, and only
while `info.yaml` is still open.

| `io_type` | Cell | Core-side control pins |
|---|---|---|
| `input_cmos` | `gf180mcu_fd_io__in_c` | `PU`, `PD` only |
| `input_schmitt` | `gf180mcu_fd_io__in_s` | `PU`, `PD` only |
| `bidirectional` | `gf180mcu_fd_io__bi_t` | full set incl. `CS`, `SL`, `PDRV[1:0]` |
| `bidirectional_24ma` | `gf180mcu_fd_io__bi_24t` | as above but **no `PDRV`** (24 mA fixed) |

Note the asymmetry: on **bidirectional** pads CMOS-vs-Schmitt is a runtime pin
(`CS`, tied 0 = CMOS on all ten). On **input** pads it is not a pin at all —
`in_c` and `in_s` have identical `PU/PD/PAD/Y` interfaces, so the choice exists
only in `info.yaml`. The two cells are both **75 × 350 µm**, so switching one is
a drop-in with no padring geometry or DEF pin change.

### `IQ_CLK` is `input_cmos` — deliberate, do not "fix" to Schmitt

**Decision 2026-08-30: keep CMOS; guarantee edge quality at the board instead.**

`psram_buf_ctrl.v` derives the PSRAM clock as a gated copy of the core clock
(`assign sck = sck_en & clk_32m`) — it does **not** regenerate the waveform, so
`PSRAM_SCK` inherits `IQ_CLK`'s duty cycle directly. The APS6404L requires
`t_CH`/`t_CL` = 0.45–0.55 × `t_CLK` (45–55%). A Schmitt input's rise/fall delays
are deliberately asymmetric, and that asymmetry grows as the process slows:

| Corner | `in_c` duty @32 MHz | `in_s` duty @32 MHz |
|---|---|---|
| FF −40 °C 3v63 | 49.70% | 50.86% |
| TT 25 °C 3v30 | 49.88% | 52.13% |
| **SS 125 °C 2v97** | **50.20%** | **54.90%** ⚠️ |

`in_s` at SS lands 0.1% from the PSRAM's 55% limit — and that assumes a perfect
50% input, before any TCXO duty tolerance. `in_c` holds within 0.3% of ideal at
every corner. CMOS is also the lower-jitter choice, and `IQ_CLK` is both the ΣΔ
sampling clock and the source of the QPI timing budget.

**The board-side obligation this creates:** CMOS has no hysteresis, so a slow or
noisy clock edge can produce *multiple* transitions — extra clock edges, a hard
failure rather than a degradation. Therefore **keep the `IQ_CLK` path short and
buffered close to the package** (`resources/DS_5PB12xx_ClockBuffer.pdf`). If a
breadboard-compatible package is used, the TCXO buffer belongs on the carrier
next to the chip, **not** at the far end of a jumper wire. Fixing a degraded
clock edge with a Schmitt input is the wrong trade: it spends duty-cycle margin
that the table above shows does not exist.

### Host SPI inputs are all `input_schmitt`

`HOST_CS`, `SPI_SCK` and **`SPI_MOSI`** (changed from `input_cmos` 2026-08-30)
are Schmitt. Rationale: all three arrive from the RPi on the same cable, which
may be long jumper wire, so they share the same degraded-edge exposure. `SPI_SCK`
and `HOST_CS` are the most sensitive (a glitch manufactures a clock edge or
aborts a frame), but `MOSI` was made consistent with them since the cell swap is
free and same-size. None of these feed a duty-cycle-critical path, so the
`IQ_CLK` argument above does not apply to them.

`IQ_DATA_{I,Q}_0..3` remain `input_cmos`: short board traces from the SX1257s,
where minimising delay and jitter matters more than hysteresis.

---

## Supply pad (1 pad; GND/VSS shared chip-wide, not a Trouper pad)

| Pad name | Voltage | Count | Description |
|---|---|---|---|
| `VDD_CORE` | 3.3 V (baseline) | 1 | Core + pad-driver supply. Feeds both the digital core and the padring — there is no separate `VDD_IO` pin; see below. |
| `GND`/`VSS` | 0 V | — (not counted) | Shared ground across the whole die. The reference IO cell library gives no way to isolate/segment `VSS` even if desired — it is the one rail every pad, every voltage domain, and (per Open Risks #29) every macro on the MPW shares unconditionally. |

> **Voltage plan (corrected 2026-08-19):** `VDD_CORE` (this pad) also feeds the padring —
> `VDD_NETS`/`GND_NETS` declare one voltage domain and the reference padring template ties
> the core PDN ring straight to the padring's power taps, with no secondary DVDD net or
> extra tap pair instantiated anywhere. 3.3 V baseline (all external parts native 3.3 V),
> so removing the separate `VDD_IO` pad doesn't change baseline behavior — one voltage
> either way, now one pin instead of two. The open item is that 32 MHz SS timing does not close at the 3.0 V slow corner (Open Risks item 1). The **contingency** — split-rail **5 V core / 3.6 V IO** — is *not* a config flip: it needs (a) a genuine secondary voltage domain + its own `dvdd`/`dvss` taps added to the PDN (not present in any current config), and (b) the remaining structural unknowns in Open Risks #27 (ESD/latch-up across the split, power-on rail sequencing, pad-ring IR drop) resolved. The cell-level down-shift itself is SPICE-proven safe (SS = +1.40 ns, DRC/LVS clean, `bi_24t` characterization job 4347). Until the PDN split is actually built, raising core voltage raises the pad rail too — external board-level level shifters on every 3.3 V-only-facing pad are the fallback. See [Open Risks](Open%20Risks.md) #27, `planning/5v-core-voltage-strategy.md` §2026-08-19.

---

## Inter-Project Interconnect (No ASIC Pads)

The following signals connect Trouper to the Grouper project on the same MPW. They are internal interconnects and do not consume Trouper package pads.

| Interface | Signals | Description |
|---|---|---|
| Grouper register bus (AHB-Lite slave) | target: `HSEL/HADDR/HTRANS/HWRITE/HSIZE/HWDATA/HRDATA/HREADYOUT/HRESP`; current placeholder: `GRP_ADDR[7:0]`, `GRP_WDATA[7:0]`, `GRP_WE`, `GRP_RE`, `GRP_RDATA[7:0]`, `GRP_READY` | Grouper (AHB-Lite master) accesses Trouper's reg_bank as an AHB-Lite slave peripheral via a small adapter. **Inter-project MPW wires only — not bonded to any package pad.** Current RTL still exposes the simplified `GRP_*` byte bus pending the adapter (see Trouper Chip Specification §5.2). |
| Interrupt | `IRQ_GROUPER` | Internal interrupt line from Trouper to Grouper (mirrors the dedicated `IRQ_OUT` pad) |

---

## Pads Not Allocated

- **SX1257 DIO pins:** Not connected to Trouper pads. AFE polling and bring-up remain external to Trouper.
- **SX1257 `CLK_IN`:** Not connected; the radios and ASIC share the board clock reference instead.
- **AFE chip-select / configuration pins:** Not allocated to Trouper package pads in the current revision.
- **Additional PSRAM control pins:** Not required. The current allocation uses dedicated `PSRAM_SCK` and `PSRAM_CE_N`, with `PSRAM_SIO[3:0]` on four dedicated data pads.
- **`sc_lock_in`/`sc_lock_out` (NR2/3 cascade OR-lock):** superseded 2026-08-30 by the
  `ARRAY_ACQ_N` pad above, which does the same job on one bidirectional wired-AND pin
  instead of two unidirectional ones. See the deferred entry at the end of this section
  for the original framing.
- **JTAG / GPIO pins:** Removed. No JTAG TAP is instantiated in the RTL and GPIO was never wired out of the macro; host debug uses the SPI register / PSRAM-readback path. See Trouper Chip Specification §4.16.
- **`sc_lock_in`/`sc_lock_out` (NR2/3 cascade OR-lock, deferred):** Previously deferred as "no pad available" against a 26-pad budget — that was against the stale 25-pad count. **2026-08-19:** with `VDD_IO` removed, current pinout is 24 pads, so there is headroom for one spare pad against the 26-pad ceiling (two, if the assigned team budget really is 22 and NR=3/IRQ_OUT-waiver work closes that gap separately — see the allocation-status note at the top of this doc). Still deferred pending an explicit decision to spend that headroom here rather than as margin, but "no pad available" is no longer the reason. The internal OR-lock logic these pins would drive already exists as a register (`SC_FORCE_LOCK`, `reg_bank` 0x19, see `planning/Register Map.md` `0x19` and `planning/NR2-multi-ASIC-cascade.md`); if this pad is allocated, bond it to `sc_lock_in` OR'd into the same internal `sc_lock_force` signal rather than adding a second mechanism. `IRQ_OUT` cannot double as this pin — it is output-only.
