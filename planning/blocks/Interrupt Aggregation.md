# IRQ Controller

Control block. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Collects interrupt sources from DSP blocks and routes them to PicoRV32 (internal) and to the RPi host (external GPIO pad). Provides sticky status/clear bits that are visible through the internal AHB-Lite interface and mirrored to the SPI-visible `IRQ_STATUS`/`IRQ_CLEAR` registers.

---

## Interrupt sources

| Source | Block | Description |
| --- | --- | --- |
| `corr_lock` | Correlator Bank / Packet Control FSM | Preamble detected — packet FSM entered `PREAMBLE_ACQ` |
| `training_done` | Training Accumulator / Packet Control FSM | Preamble accumulation complete — firmware should compute W |
| `W_missed_packet` | Packet Control FSM | W was not committed before packet completion; packet stayed in bypass |
| `packet_done` | Packet Control FSM | FSM returned to IDLE (packet ended or timed out) |

---

## Interface

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `corr_lock` | in | 1 | From correlator bank |
| `training_done` | in | 1 | From Training Accumulator / Packet Control FSM |
| `W_missed_packet` | in | 1 | From Packet Control FSM |
| `packet_done` | in | 1 | From Packet Control FSM (FSM returned to IDLE) |
| `irq_out` | out | 1 | Level-high IRQ to PicoRV32 (internal) and to `TCK_IRQ` pad when `JTAG_EN=0` |
| `wb_addr` | in | 8 | AHB-Lite address |
| `wb_rdata` | out | 32 | IRQ status register |
| `wb_wdata` | in | 32 | IRQ clear (write 1 to clear) |
| `wb_we` | in | 1 | — |
| `wb_stb` | in | 1 | — |
| `wb_ack` | out | 1 | — |
| `clk_16m` | in | — | Master clock |
| `rst_n` | in | — | — |

---

## Register (AHB-Lite and SPI mirror, read/clear)

Mirrors `IRQ_STATUS` (`0x32`) and `IRQ_CLEAR` (`0x33`) in the register map.

| Bit | Source | Clear |
| --- | --- | --- |
| [0] | `corr_lock` | Write 1 to bit [0] |
| [1] | `training_done` | Write 1 to bit [1] |
| [2] | `W_missed_packet` | Write 1 to bit [2] |
| [3] | `packet_done` | Write 1 to bit [3] |
| [4:6] | reserved | — |

`irq_out` = OR of all uncleared sources. `IRQ` pad mirrors `irq_out`.

The SPI-facing register map exposes the same bit layout at `IRQ_STATUS` (`0x32`) and `IRQ_CLEAR` (`0x33`). Firmware and host software should treat the IRQ wire as a doorbell: read `IRQ_STATUS` to identify the source, service the corresponding block/registers, then write 1s to `IRQ_CLEAR` for serviced bits.

---

## Implementation notes

**Level vs edge.** Sources are level signals from their respective blocks. Latch on rising edge into sticky bits. Clear by writing 1 to the corresponding bit. Source block de-asserts its signal after being consumed.

**Clock domain.** This block runs at 16 MHz, co-domain with PicoRV32 — `irq_out` is synchronous to the CPU with no CDC required on the output path.

Interrupt sources originate in DSP blocks that run at either 16 MHz or 32 MHz:

| Source | Origin domain | CDC required |
|---|---|---|
| `corr_lock` | 16 MHz (Correlator Bank / Packet Control FSM) | No |
| `training_done` | 16 MHz (Training Accumulator / Packet Control FSM) | No |
| `W_missed_packet` | 16 MHz (Packet Control FSM) | No |
| `packet_done` | 16 MHz (Packet Control FSM) | No |

Any future source generated in the 32 MHz domain (e.g. a SX1257 DIO pin, or a CIC-domain event) must pass through a 2-FF synchroniser before entering the sticky-bit latch. Do not add unsynchronised external signals directly to the IRQ OR tree.

**RPi IRQ.** `irq_out` drives the `TCK_IRQ` pad as a level-high output when `JTAG_EN=0` (normal mode). RPi GPIO should be configured for rising-edge interrupt. RPi firmware reads `IRQ_STATUS` (`0x32`) to determine source, then writes `IRQ_CLEAR` (`0x33`). When `JTAG_EN=1` (debug mode) the pad is disconnected from `irq_out` and taken over by the JTAG TAP as TCK input — the RPi must poll `IRQ_STATUS` via SPI during debug sessions instead of relying on the pad interrupt.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| corr_lock IRQ | Assert `corr_lock`; read WB register | Bit [0] set; `irq_out` high |
| training_done IRQ | Assert `training_done`; read WB register | Bit [1] set; firmware W computation can start |
| W missed IRQ | Assert `W_missed_packet`; read WB register | Bit [2] set; packet remains bypass |
| packet_done IRQ | Assert `packet_done`; read WB register | Bit [3] set |
| Clear IRQ | Write 1 to bit [0] | Bit [0] clears; `irq_out` low if no other source |
| Multiple simultaneous | Assert all sources | All bits set; `irq_out` high |
| Clear one, others remain | Clear only bit [1] | Bit [0] and [2] still set; `irq_out` still high |

---

## Related blocks

- [Correlator Bank](Correlator%20Bank.md) — `corr_lock` source
- [Training Accumulator](Training%20Accumulator.md) — `training_done` source
- [Packet Control FSM](Packet%20Control%20FSM.md) — `W_missed_packet`, `packet_done` sources
- [PicoRV32 Integration](PicoRV32%20Integration.md) — internal IRQ target
- [System Architecture](../System%20Diagram.md) — `IRQ` pad to RPi
