# System and Integration Guide

Audience: whoever is bringing up the Trouper test PCB or firmware once
silicon (or an FPGA-emulated stand-in) is on the bench. This document is a
**procedure and protocol reference** — it tells you what to wire, what order
to power things up in, and what to send over SPI to get a first packet. It
does not re-derive the DSP chain or the design rationale: that's
[System Architecture](../planning/System%20Architecture.md) (block diagram, clock
domains, area) and the individual [blocks/](../planning/blocks) specs. It does not
catalog known bugs and open questions either: that's
[Open Risks](../planning/Open%20Risks.md), which is the authoritative, continuously
updated list — this guide only calls out the handful of risks that bite
*during bring-up specifically*, with a pointer to the full entry.

**Status:** written 2026-07-11, against the current PSRAM-based (no
on-chip SRAM), fixed-R=64-half-band, single-clock-plus-`ce_16m` RTL.
Several Open Risks items are still being closed as this is written (see
`Open Risks.md` for current state) — re-check that file before relying on
any specific timing/behavior claim here for a real bring-up session.

---

## 1. What Trouper expects to be connected to

| External part | Qty | Interface | Trouper's role |
| --- | --- | --- | --- |
| SX1257 RF front-end | 4 | 1-bit ΣΔ IQ in (`IQ_DATA_I/Q[0:3]`), shared `IQ_CLK` | Consumes the RX bitstreams; does **not** configure the SX1257s (external SPI, outside Trouper RTL) |
| SX1302 LoRa baseband | 1 | 1-bit ΣΔ IQ out (`REMOD_A_I/Q`) | Produces the MRC-combined (or bypass) re-modulated stream; Trouper never talks to SX1302 over SPI |
| APS6404L PSRAM | 1 | QPI (`PSRAM_SCK`/`PSRAM_CE_N`/`PSRAM_SIO[3:0]`) | Owns and sequences the PSRAM protocol itself (`psram_buf_ctrl`) — firmware only flips `PSRAM_CTRL.PSRAM_EN` and polls `INIT_DONE`, it never speaks QPI directly |
| Host RPi | 1 | Dedicated SPI slave (`HOST_CS`/`SPI_SCK`/`SPI_MOSI`/`SPI_MISO`), `IRQ_OUT` | Primary bring-up and register-access path; this guide's SPI recipes assume the host is the RPi |
| Grouper (PicoRV32 macro) | 1 | `GRP_*` byte bus (inter-project MPW wires, no package pads) | Priority register access over SPI; **not required** for bring-up — Trouper works standalone with the RPi driving SPI (see [System Architecture](../planning/System%20Architecture.md) "Grouper-Inactive / Host-Assisted Operation") |
| PCB clock buffer | 1 | `IQ_CLK` (to Trouper) + `XTB` ×4 (to each SX1257) | Single 32 MHz TCXO reference fanned out to Trouper and all 4 SX1257s — **not** optional or per-device; all clocks must trace to the same buffer output for the CDC-free clock architecture to hold |

Full pad-by-pad list, direction, and electrical notes: [Pinout](../planning/Pinout.md).

---

## 2. Power and reset

- There is **one power pad, `VDD_CORE`**, at **3.3 V baseline** (matches all
  four external parts' native voltage). It feeds both the digital core and
  the padring — there is no separate `VDD_IO` pad; the reference PDN config
  ties them to one net (**corrected 2026-08-19**, was previously documented
  here as two independent rails — see [Pinout](../planning/Pinout.md) and
  [5V core voltage strategy](../planning/5v-core-voltage-strategy.md)
  §2026-08-19). The 5 V-core contingency (see
  [Open Risks](../planning/Open%20Risks.md) #27) would need a genuine second
  voltage domain built into the PDN first — it isn't a rail you can already
  dial independently at bring-up.
- `RESETB` is the **raw, unsynchronized, active-low** reset pin — there is
  no on-chip POR or deglitch circuit (Open Risks #27, item 3). Hold it low
  through the entire power-up transient before releasing.
- The very first SPI transaction after `RESETB` release is now safe (Open
  Risks item 26, closed 2026-07-02) — you do **not** need a dummy/throwaway
  read before the first real register access.
- **PSRAM power-up timing is entirely a host/firmware discipline
  requirement, not something Trouper enforces in hardware** (Open Risks #27,
  item 1): the APS6404L needs ≥150 µs after its own power-up before its
  `RSTEN`/`RST` sequence is safe, and nothing in the RTL times this — do not
  write `PSRAM_CTRL.PSRAM_EN=1` immediately on release of `RESETB`; wait for
  the PSRAM's own power-up spec first.

---

## 3. Clock architecture (what you need to know to wire it, not why)

- One external reference: `IQ_CLK`, 32 MHz, from the shared PCB TCXO buffer.
  The same buffer output also drives all 4 SX1257 `XTB` pins (**max 1.8 V
  pk-pk** on that path — see [Pinout](../planning/Pinout.md) if inserting a buffer/divider).
- SX1302's clock is **not** driven by Trouper — it comes from SX1257_1's
  `CLK_OUT` pin directly on the PCB (System Architecture §"ASIC → SX1302").
- Internally Trouper derives a `ce_16m` clock-enable (not a second clock
  tree) for the control-plane blocks; this is invisible from the outside —
  nothing to wire, mentioned only so you don't go looking for a `CLK_16M`
  pad that doesn't exist.

---

## 4. Protocol quickstarts

### 4.1 Host SPI register access

Mode 0, up to 2 MHz `SPI_SCK`. Frame format:

```
Byte 0 (command): bit[7] = R/W# (1=read, 0=write), bits[6:0] = register address (0x00-0x7F)
Byte 1 (data):    write value, or 0xFF dummy on read (MISO drives the real value back)
```

- While `HOST_CS` stays low after byte 1, each additional byte accesses the
  **next** address (auto-increment, wraps mod 128) — useful for burst reads
  of the `Z` bank or a burst write of the `W_SHADOW` bank. Exception:
  `PSRAM_DBG_DATA` (`0x76`) does not auto-increment.
- `0x7F` is permanently reserved (protocol-escape code) — never write it as
  a register address.
- Full map: [Register Map](../planning/Register%20Map.md). It is the single
  authoritative source — do not use `firmware/picorv32/asic_regs.h` (stale,
  Open Risks #20) or `Trouper Chip Specification.md`'s register-address
  prose (drifted in places, Open Risks #24).

### 4.2 Grouper bus

Only relevant if Grouper firmware is driving register access instead of the
RPi. Same register map, priority arbitration over SPI (a `GRP_WE`/`GRP_RE`
overlapping an SPI write window silently drops the SPI write — Open Risks
#16). **Before relying on this path**, confirm with the Grouper team whether
their bus clock is provably phase-aligned to Trouper's `IQ_CLK` — there is
no CDC synchronizer on this bus today (Open Risks #29). For RPi-only
bring-up, ignore this bus entirely and tie `GRP_WE`/`GRP_RE` low.

### 4.3 PSRAM QPI

You never speak this protocol directly. `psram_buf_ctrl` runs its own
`RSTEN(0x66) → RST(0x99) → tRST wait → Enter QPI(0x35)` sequence
automatically once `PSRAM_CTRL.PSRAM_EN` (`0x70[0]`) is set — poll
`PSRAM_STATUS.INIT_DONE` (`0x71[3]`) and proceed once it reads 1. The
debug-readback path (`0x72`–`0x76`) lets you read arbitrary PSRAM bytes over
SPI without firmware — handy for confirming real captured samples during
bring-up (see Register Map `0x72`–`0x76` section).

---

## 5. Bring-up sequence

This is the minimum path from power-on to a first locked/replayed packet,
driving everything from the host RPi over SPI (no Grouper firmware needed).

1. **Power up** both rails at 3.3 V with `RESETB` held low; release
   `RESETB` only after both rails and the PSRAM's own power-up transient
   have settled.
2. **Confirm SPI is alive**: read `CHIP_ID` (`0x00`) — expect `0xA7`.
3. **Configure the modem** (all write-gated OFF while `PACKET_ACTIVE=1`, so
   do this before the first lock, or between packets):
   - `SF_CFG` (`0x09`) — spreading factor 7–12
   - `BW_CFG` (`0x0A`) — `bw_sel` (bit 0: 0=250 kHz, 1=125 kHz) and
     `sc_ant_sel` (`SC_ANT_SEL` 0x1B[1:0]: which antenna feeds the SC correlator, default
     0 — see Register Map `0x0A`)
   - `PKT_TIMEOUT_SYMS` (`0x0B`), SC threshold/hits (`0x0C`–`0x0E`)
   - `MIMO_CTRL` (`0x08`) — mode + `ANTENNA_EN`, must land **before** the
     first `sc_lock` (latched at the lock edge)
4. **Enable PSRAM**: write `PSRAM_CTRL.PSRAM_EN=1` (`0x70[0]`), poll
   `PSRAM_STATUS.INIT_DONE` (`0x71[3]`). This is required even if you don't
   care about same-packet replay — PSRAM is also the SC detector's delay
   line, so `sc_lock` cannot fire without it.
5. **Wait for acquisition**: poll `IRQ_STATUS` (`0x02`) bit 0
   (`IRQ_CORR_LOCK`), or watch the `IRQ_OUT` pad. Remember the SC correlator
   only evaluates the antenna selected by `sc_ant_sel` (default 0) — if
   that antenna is dead or deep-faded on your bench setup, acquisition will
   silently never happen (Open Risks #9).
6. **On `IRQ_TRAINING_DONE`** (`IRQ_STATUS` bit 1): read the `Z_kl`/`Z_kk`
   bank (`0x40`–`0x6F`), compute weights externally (see
   `sim/models/eigvec_fw.py` for the reference algorithm), write them to
   `W_SHADOW` (`0x30`–`0x3F`, burst write is convenient here), then pulse
   `WGT_CTRL.W_COMMIT` (`0x1E[0]`).
7. **Monitor `PACKET_STATUS`** (`0x1C`) / `IRQ_STATUS` for `PACKET_DONE`,
   then repeat from step 5 for the next packet — `sc_lock` re-arms
   automatically at packet end.

For a debug-only bring-up (confirming the RX chain sees real samples before
wiring up the SC/training/weight loop at all), the PSRAM debug-read path
(§4.3) lets you dump raw captured IQ bytes over SPI with no packet logic
involved.

---

## 6. Bring-up-specific hazards

This is **not** a substitute for [Open Risks](../planning/Open%20Risks.md) — it is the
subset of entries most likely to actually bite you during initial bring-up,
so you don't have to read the whole file to get started. Check the full
file for current status before treating any of these as settled.

| Risk | What you'll observe | Ref |
| --- | --- | --- |
| No on-chip PSRAM tPU wait / no POR | Random first-boot corruption or PSRAM init failure if `RESETB`/power sequencing isn't disciplined by the host | Open Risks #27 (startup items 1, 3) |
| SC correlator is single-antenna (`sc_ant_sel`, default 0) | Never acquiring lock even with good SNR on antennas 1-3, if antenna 0 is dead/disconnected on the bench | Open Risks #9 |
| "Silence" during PSRAM buffering is actually a DC tone | SX1302 sees an unexpected tone instead of silence between preamble lock and `W_COMMIT` | Open Risks #5 |
| Grouper bus has no CDC | Only relevant once Grouper firmware is in the loop — confirm clock relationship before trusting register writes over `GRP_*` | Open Risks #29 |
| Final SPI write lost if `HOST_CS` rises too soon after the last `SCK` edge | An occasional silently-dropped last byte of a burst write | Open Risks #15 |

---

## References

- [System Architecture](../planning/System%20Architecture.md) — block diagram, clock
  domains, gate/area summary, operating modes
- [Pinout](../planning/Pinout.md) — full pad list, electrical notes, SX1257 board-level
  pin dispositions
- [Register Map](../planning/Register%20Map.md) — authoritative register reference
- [Open Risks](../planning/Open%20Risks.md) — full, continuously-updated risk register
- [Trouper Chip Specification](../planning/Trouper%20Chip%20Specification.md) — formal
  requirements (TRPR-* IDs); note some sections have drifted from RTL, see
  Open Risks #24
- `cocotb/tests/test_startup.py` — the regression coverage behind §2's
  power/reset claims
