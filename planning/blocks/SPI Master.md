# SPI Master (Removed from current Trouper revision)

Control block. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Archived / removed from current tapeout plan

---

## Function

This document is retained as design history only. The current Trouper revision does not instantiate an on-chip SPI master, does not expose `CS_A[1:0]`, and does not implement the `SX_TARGET` / `SX_ADDR` / `SX_DATA` / `SX_CTRL` pass-through register window.

AFE configuration is handled outside Trouper by board/system logic or companion-controller software.

---

## Current status

The active Trouper contract is:

- no on-chip AFE SPI master block
- no `CS_A[1:0]` Trouper outputs
- no SPI-master subordinate window on the Grouper AHB-Lite map
- no hardware `RX_GAIN_COMMIT` sequencer inside Trouper

Any legacy references below describe the superseded architecture and must not be treated as implementation requirements. See [Trouper Chip Specification](../Trouper%20Chip%20Specification.md), [Register Map](../Register%20Map.md), and [System Architecture](../System%20Architecture.md) for the active design.

---

## Legacy note

Earlier revisions explored a Trouper-resident SPI master with:

- `CS_A[1:0]` AFE-select outputs
- `SX_TARGET` / `SX_ADDR` / `SX_DATA` / `SX_CTRL` pass-through registers
- an internal `RX_GAIN_COMMIT` sequencer for SX1257 gain writes

That architecture is superseded and must not be treated as a current interface contract.

For active documentation, use:

- [Trouper Chip Specification](../Trouper%20Chip%20Specification.md)
- [Register Map](../Register%20Map.md)
- [System Architecture](../System%20Architecture.md)
- [AHB-Lite Bus](AHB-Lite%20Bus.md)
