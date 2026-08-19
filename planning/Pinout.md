# ASIC Pinout

GF180MCU MIMO ASIC logical pad list. Total: **24 pads** (23 signal + `VDD_CORE`;
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
now 2 pins, not 3. Either the `IRQ_OUT`-removal waiver (poll `IRQ_STATUS` over SPI instead,
−1 pin — low risk, no RTL beyond deleting the pad) needs one more pin cut alongside it, or
the validated NR=3 (3-antenna) fallback alone (−2 pins) now lands exactly on 22 without the
waiver. **See:**
`planning/1117sq-margin-reclaim-2026-08.md`, `planning/nr3-fallback-2026-08.md`, Open Risks
#46.

**Related:** [System Architecture](System%20Architecture.md), [Trouper Chip Specification](Trouper%20Chip%20Specification.md)

---

## Signal pads (23)

All signal pads use **GF180 5 V-capable IO cells**, run at **3.3 V**. There is one power
pad (`VDD_CORE`) and one shared ground (`GND`/`VSS`, not a per-project pad) — see the
supply section below for why `VDD_IO` isn't a separate listed pad. The `bi_24t` cell itself
*can* electrically support an independent pad-driver rail (`DVDD`/`DVSS`) at a different
voltage from its core-logic rail (`VDD`/`VSS`, SPICE-confirmed, Open Risks #27), but nothing
in the current PDN config uses that capability — full detail in the supply section below.

### RX data from SX1257 (8 pads, input)

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
| `SPI_SCK` | in | Host SPI SCK | SPI clock, Mode 0, up to 10 MHz |
| `HOST_CS` | in | Host SPI chip select | Active-low slave select |

### Interrupt output (1 pad, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IRQ_OUT` | out | Host RPi IRQ GPIO | Dedicated level-high sticky interrupt (packet ready, preamble lock, etc.). Mirrors the inter-project `IRQ_GROUPER` line. |

### PSRAM data bus (4 pads, bidirectional)

Dedicated PSRAM QPI data nibble. JTAG and GPIO have been removed (no TAP in RTL; see Trouper Chip Specification §4.16), so these four pads carry only `PSRAM_SIO[3:0]`.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `PSRAM_SIO[0]` | bidir | APS6404L `SIO0` | PSRAM QPI data bit 0 |
| `PSRAM_SIO[1]` | bidir | APS6404L `SIO1` | PSRAM QPI data bit 1 |
| `PSRAM_SIO[2]` | bidir | APS6404L `SIO2` | PSRAM QPI data bit 2 |
| `PSRAM_SIO[3]` | bidir | APS6404L `SIO3` | PSRAM QPI data bit 3 |

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
- **JTAG / GPIO pins:** Removed. No JTAG TAP is instantiated in the RTL and GPIO was never wired out of the macro; host debug uses the SPI register / PSRAM-readback path. See Trouper Chip Specification §4.16.
- **`sc_lock_in`/`sc_lock_out` (NR2/3 cascade OR-lock, deferred):** Previously deferred as "no pad available" against a 26-pad budget — that was against the stale 25-pad count. **2026-08-19:** with `VDD_IO` removed, current pinout is 24 pads, so there is headroom for one spare pad against the 26-pad ceiling (two, if the assigned team budget really is 22 and NR=3/IRQ_OUT-waiver work closes that gap separately — see the allocation-status note at the top of this doc). Still deferred pending an explicit decision to spend that headroom here rather than as margin, but "no pad available" is no longer the reason. The internal OR-lock logic these pins would drive already exists as a register (`SC_FORCE_LOCK`, `reg_bank` 0x19, see `planning/Register Map.md` `0x19` and `planning/NR2-multi-ASIC-cascade.md`); if this pad is allocated, bond it to `sc_lock_in` OR'd into the same internal `sc_lock_force` signal rather than adding a second mechanism. `IRQ_OUT` cannot double as this pin — it is output-only.
