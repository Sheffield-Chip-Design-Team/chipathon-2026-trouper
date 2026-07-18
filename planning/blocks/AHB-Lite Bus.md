# AHB-Lite Bus (Grouper Project)

Control block. See [System Architecture](../System%20Architecture.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Shared `AHB-Lite` system bus fabric residing in the **Grouper** project. It provides the primary control interconnect between the PicoRV32 processor (Bus Master) and all system peripherals on the MPW, including the **Trouper** MIMO RX datapath.

The bus fabric is designed for single-master operation with multiple slave peripherals. It supports standard AHB-Lite transactions for configuration, status polling, and firmware-driven algorithm management.

---

## Slave map

| Address range | Slave | Project | Notes |
| --- | --- | --- | --- |
| `0x00000`–`0x0FFFF` | Grouper SRAM | Grouper | Unified Instruction/Data memory |
| `0x10000`–`0x100FF` | Trouper Register Bank | Trouper | ASIC config/status registers |
| `0x10200`–`0x102FF` | Trouper IRQ Controller | Trouper | Source read/clear |
| `0x10300`–`0x103FF` | Trouper JTAG/GPIO | Trouper | Debug/IO mux control |
| `0x20000`–`0x2FFFF` | Grouper Peripherals | Grouper | Timer, UART, etc. |

---

## Interface

The inter-project connection SHALL use the `slave` modport of Grouper's
`ahb3lite_intf` with `ADDR_WIDTH=32` and `DATA_WIDTH=32`. The complete
contract is:

- Slave inputs: `HADDR`, `HBURST`, `HMASTLOCK`, `HPROT`, `HSIZE`, `HTRANS`,
  `HWDATA`, `HWRITE`, `HREADYIN`, and `HSEL`.
- Slave outputs: `HRDATA`, `HREADYOUT`, and `HRESP`.

`HREADYIN` is the decoder/global input that qualifies the slave data phase;
`HREADYOUT` is the selected slave's completion output. Do not use an
ambiguous single signal named `HREADY` in this interface specification.

Trouper's internal register bank and control sub-blocks are integrated as
slaves on this fabric via a bridge/decoder that routes Grouper bus transactions
to the appropriate Trouper peripheral. Trouper accepts byte transfers only
(`HSIZE=3'b000`); its adapter accepts but ignores `HBURST`, `HMASTLOCK`, and
`HPROT`.

---

## Implementation notes

**Centralised Grouper Bus.** The AHB-Lite bus is a physical fabric in the Grouper project. Trouper connects to this bus via external pins/wires on the common MPW.

**Master side.** The PicoRV32 in Grouper is the sole bus master. A lightweight adapter converts PicoRV32 native memory accesses into AHB-Lite transactions.

**Shared Peripheral Access.** The bus allows the PicoRV32 to manage both Trouper-specific logic and Grouper-native peripherals (SRAM, timers, etc.) within a unified address space.

**Wait states.** A slave holds `HREADYOUT` low to stall completion; it observes
`HREADYIN` before advancing its data phase. Register-based slaves in Trouper
are expected to respond with zero wait states (`HREADYOUT=1` for normal
transfers). There is no active Trouper SPI-master subordinate in the current
map.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Address Decoding | cocotb: Master accesses each slave range | Correct slave selected; no aliasing |
| Trouper Register Access | cocotb: Write/read Trouper reg bank via AHB | Correct data; Trouper logic responds |
| Grouper Peripheral Access | cocotb: Access native Grouper slaves | Seamless operation on the same fabric |
| Concurrent Bus Usage | cocotb: Host SPI (via bridge) vs CPU AHB access | Correct arbitration and completion |

---

## Related blocks

- [PicoRV32 Integration](PicoRV32%20Integration.md) — Bus master
- [SPI Slave](SPI%20Slave.md) — Host bridge into the Grouper system bus
- All Trouper and Grouper peripheral blocks — Bus slaves
