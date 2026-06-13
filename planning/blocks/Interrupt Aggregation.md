# Interrupt Aggregation (in `reg_bank.v`)

Control function. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Implemented inside `reg_bank.v`

> **Note:** Interrupt aggregation is **not a standalone module**. The logic lives
> inside `reg_bank.v`. The former `irq_ctrl.v` block was never instantiated in any
> top (`trouper_top` or the legacy `mimo_rx_top`) and has been removed, along with
> its references in the LibreLane `VERILOG_FILES` lists. This doc describes the
> reg_bank-internal implementation; the authoritative register definitions are in
> [Register Map](../Register%20Map.md).

---

## Function

`reg_bank` collects interrupt-source pulses from the DSP/control blocks, latches
them into the sticky `IRQ_STATUS` register, and OR-reduces them into a single
level-high `irq_out`. That signal is fanned out in `trouper_top` to two
destinations: the dedicated `IRQ_OUT` package pad (host RPi) and the inter-project
`IRQ_GROUPER` wire (to the Grouper PicoRV32). Both carry the same level.

---

## Interrupt sources

The event pulses are assembled in `trouper_top` into the `irq_set[7:0]` bus and
passed to `reg_bank.irq_set` (see `trouper_top.v`, `rb_irq_set`):

| Bit | Source | Block | Description |
| --- | --- | --- | --- |
| [0] | `corr_lock` (`sc_lock`) | SC Detector / Packet Control FSM | Preamble detected — packet FSM entered `PREAMBLE_ACQ` |
| [1] | `training_done` | Training Accumulator / Packet Control FSM | Preamble accumulation complete — firmware should compute W |
| [2] | `W_missed_packet` | Packet Control FSM | W was not committed before packet completion; packet stayed in bypass |
| [3] | `packet_done` | Packet Control FSM | FSM returned to IDLE (packet ended or timed out) |
| [4] | `noise_ready` (`sigma2_valid`) | Noise-window qualifier (`trouper_top`) | Uncontaminated firmware-triggered noise window completed |
| [7:5] | reserved | — | — |

---

## Implementation (inside `reg_bank.v`)

There is no separate port-level interface, Wishbone/AHB bridge, or extra clock
domain — the IRQ logic is part of the register bank and shares its single
`IQ_CLK` (32 MHz) domain. The relevant signals:

| Signal | Direction (reg_bank) | Description |
| --- | --- | --- |
| `irq_set[7:0]` | in | One-cycle event pulses from `trouper_top` (table above) |
| `irq_status` | internal `reg [7:0]` | Sticky latch: `irq_status <= irq_status \| irq_set` |
| `irq_out` | out | `assign irq_out = \|irq_status;` (level-high) |

Register access uses the same paths as every other reg_bank register: the Grouper
bus via the `re`/`rdata`/`ready` handshake, and the host SPI via the combinational
`peek_rdata` tap. No CDC is required on the output path because `irq_out` is
generated in the core clock domain.

---

## Register (read / clear)

`IRQ_STATUS` and `IRQ_CLEAR` are defined in [Register Map](../Register%20Map.md)
(`0x02` / `0x03`). Clearing is write-1-to-clear, applied in the same cycle as any
incoming event:

```
irq_status <= (irq_status | irq_set) & ~wdata;   // on IRQ_CLEAR write
```

| Bit | Source | Clear |
| --- | --- | --- |
| [0] | `corr_lock` | Write 1 to bit [0] of `IRQ_CLEAR` |
| [1] | `training_done` | Write 1 to bit [1] |
| [2] | `W_missed_packet` | Write 1 to bit [2] |
| [3] | `packet_done` | Write 1 to bit [3] |
| [4] | `noise_ready` | Write 1 to bit [4] |
| [7:5] | reserved | — |

`irq_out` = OR of all uncleared sources. Both the `IRQ_OUT` pad and `IRQ_GROUPER`
mirror `irq_out`. Firmware/host treat the IRQ as a doorbell: read `IRQ_STATUS` to
identify the source, service the corresponding block, then write 1s to
`IRQ_CLEAR` for serviced bits.

---

## Implementation notes

**Level vs edge.** Sources are one-cycle pulses (or levels) from their respective
blocks, latched into sticky bits. A bit stays set until firmware writes 1 to the
corresponding `IRQ_CLEAR` bit. Because clear and set are combined in one
expression, an event arriving in the same cycle as a clear is not lost.

**Clock domain.** All sources are generated in the single 32 MHz `IQ_CLK` domain
(blocks update on `iq_valid`, but the flops are clocked by `IQ_CLK`). `irq_out` is
therefore synchronous with no CDC on the output path. Any future source generated
asynchronously (e.g. an SX1257 DIO pin) must pass through a 2-FF synchroniser
before entering the sticky-bit latch — do not add unsynchronised external signals
directly to the IRQ OR tree.

**Host IRQ.** `irq_out` drives the dedicated `IRQ_OUT` pad as a level-high output;
the RPi GPIO should be configured for rising-edge interrupt. JTAG/GPIO have been
removed (no TAP in RTL), so the IRQ pad is dedicated and never muxed away.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| corr_lock IRQ | Pulse `sc_lock`; read `IRQ_STATUS` | Bit [0] set; `irq_out` high |
| training_done IRQ | Pulse `training_done`; read `IRQ_STATUS` | Bit [1] set; firmware W computation can start |
| W missed IRQ | Pulse `W_missed_packet`; read `IRQ_STATUS` | Bit [2] set; packet remains bypass |
| packet_done IRQ | Pulse `packet_done`; read `IRQ_STATUS` | Bit [3] set |
| noise_ready IRQ | Complete a clean noise window; read `IRQ_STATUS` | Bit [4] set |
| Clear IRQ | Write 1 to bit [0] of `IRQ_CLEAR` | Bit [0] clears; `irq_out` low if no other source |
| Multiple simultaneous | Assert all sources | All bits set; `irq_out` high |
| Clear one, others remain | Clear only bit [1] | Bits [0] and [2] still set; `irq_out` still high |

---

## Related blocks

- [SC Detector](SC%20Detector.md) — `sc_lock` (`corr_lock`) source
- [Training Accumulator](Training%20Accumulator.md) — `training_done` source
- [Packet Control FSM](Packet%20Control%20FSM.md) — `W_missed_packet`, `packet_done` sources
- [Register Bank](Register%20Bank.md) — hosts the IRQ logic; authoritative register interface
- [PicoRV32 Integration](PicoRV32%20Integration.md) — Grouper-side IRQ target (`IRQ_GROUPER`)
- [System Architecture](../System%20Diagram.md) — `IRQ_OUT` pad to RPi
