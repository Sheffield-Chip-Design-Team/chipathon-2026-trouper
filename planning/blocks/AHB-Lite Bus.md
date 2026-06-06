# AHB-Lite Bus

Control block. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Custom single-master `AHB-Lite` interconnect connecting PicoRV32-side logic to all on-chip peripherals and SRAM-facing slaves.

The project decision is to use `AHB-Lite`, not Wishbone. Because PicoRV32 is not a native AHB master, the master side will be implemented with a custom wrapper/bridge around PicoRV32.

---

## Slave map

| Address range | Slave | Notes |
| --- | --- | --- |
| `0x10000`–`0x100FF` | Register bank | ASIC config/status registers |
| `0x10100`–`0x101FF` | SPI master | SX1257 config writes |
| `0x10200`–`0x102FF` | IRQ controller | Source read/clear |
| `0x10300`–`0x103FF` | SWD TAP | Debug interface |

---

## Interface

Top-level bus signals follow standard AHB-Lite naming:

- `HADDR`
- `HWRITE`
- `HTRANS`
- `HSIZE`
- `HBURST`
- `HWDATA`
- `HRDATA`
- `HREADY`
- `HRESP`

Current peripheral block notes may still show local `wb_*`-style placeholder register strobes. Treat those as provisional local slave-interface names pending cleanup to the final AHB-Lite wrapper signals.

---

## Implementation notes

**Single master.** The PicoRV32 wrapper is the only AHB-Lite master — no multi-master arbitration is needed.

**Custom PicoRV32 wrapper.** Implement a lightweight adapter that converts PicoRV32 memory/peripheral accesses into AHB-Lite transactions. This is intentionally custom rather than adopting a pre-existing Wishbone-centric integration.

**Wait states.** Register bank and IRQ controller should respond in one transfer when possible. SPI master may insert wait states through `HREADY` deassertion while a SPI transaction completes; the PicoRV32 wrapper must stall cleanly until the transfer completes.

**Shared bus reset.** Slaves return idle-ready behavior after reset. The PicoRV32 wrapper must not issue valid transfers until reset is released and SRAM/SPI macros are stable.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Register R/W via AHB-Lite | cocotb: PicoRV32 wrapper writes/reads each slave | Correct data; `HRDATA/HREADY` behavior as expected |
| Wait state handling | SRAM with 2-cycle latency | PicoRV32 wrapper stalls until `HREADY`; data correct |
| Address decode | Access each slave address range | No aliasing; correct slave responds |
| Wrapper sanity | Back-to-back PicoRV32 peripheral accesses | No dropped transfers; correct ordering |

---

## Related blocks

- [PicoRV32 Integration](PicoRV32%20Integration.md) — custom PicoRV32-to-AHB-Lite master side
- All peripheral blocks — bus slaves
