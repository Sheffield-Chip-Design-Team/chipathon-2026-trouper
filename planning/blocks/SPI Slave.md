# SPI Slave (Trouper Host Interface)

Control block. See [System Architecture](../System%20Architecture.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Dedicated SPI slave providing an external host (e.g., Raspberry Pi) with direct access to **Trouper's** internal configuration and status registers. This interface operates in parallel with the **AHB-Lite Slave** interface used for inter-project communication with Grouper.

Key features:
- byte-wide register read/write access to Trouper's register bank.
- firmware load path into the local unified CPU SRAM (typically managed by Grouper's PicoRV32 but physically accessible for MPW-level bring-up).

> **Dual Control Model:** Trouper can be managed either via this SPI Slave (external host) or via the AHB-Lite Bus (internal Grouper master). Register access is arbitrated between these two masters, with Grouper usually having priority during normal operation.

---

## Interface

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `HOST_CS` | in | 1 | Active-low chip select from RPi SPI0 CE1 |
| `HOST_SCK` | in | 1 | SPI clock from RPi (up to 2 MHz) |
| `HOST_MOSI` | in | 1 | Data from RPi |
| `HOST_MISO` | out | 1 | Data to RPi |
| `clk_32m` | in | — | Master clock (register domain) |
| `rst_n` | in | — | Active-low reset |
| `reg_addr` | out | 8 | Decoded register address |
| `reg_wdata` | out | 8 | Write data |
| `reg_we` | out | 1 | Write enable to register bank |
| `reg_rdata` | in | 8 | Read data from register bank |
| `fw_ld_addr` | out | 12 | Byte address into unified CPU SRAM (`0x000`–`0xFFF`) |
| `fw_ld_wdata` | out | 8 | Firmware-load write data byte |
| `fw_ld_we` | out | 1 | Firmware-load write strobe |
| `fw_ld_rdata` | in | 8 | Optional firmware-readback byte for debug / verification |
| `fw_ld_req` | out | 1 | Firmware-load request |
| `fw_ld_ready` | in | 1 | Firmware-load port ready / accepted |

---

## Protocol

**SPI mode:** Mode 0 (CPOL=0, CPHA=0). MSB first.

### Single register access (2 bytes)

```
Byte 0: [7] R/W̄  [6:0] address
Byte 1: data (write) or don't-care (read)
MISO byte 1: register contents (read) or 0x00 (write)
```

Rules:

- Every normal register transaction is exactly 2 bytes under one `HOST_CS` assertion.
- If Byte 0 is anything other than `0x7F`, the slave interprets the transaction as a normal 2-byte register access.
- Address value `0x7F` is reserved as an extended-command escape and must not be assigned to a normal register.
- The active register set for tapeout is the register map in [Register Map](../Register%20Map.md).

### Extended command escape

If Byte 0 is `0x7F`, the SPI slave does **not** treat it as a register address. Instead, `0x7F` is the command escape byte that tells the parser to enter extended-command mode:

```
Byte 0: 0x7F                // escape
Byte 1: opcode
Byte 2: addr_hi[3:0]        // start address bits [11:8] in low nibble; high nibble = 0
Byte 3: addr_lo[7:0]        // start address bits [7:0]
Byte 4: len_minus_1         // transfer length = 1..256 bytes
Byte 5...: payload or dummy bytes depending on opcode
```

Parser rule:

```text
Byte 0 != 0x7F  -> normal 2-byte register transaction
Byte 0 == 0x7F  -> extended-command transaction
```

`HOST_CS` must remain asserted for the entire extended command. If `HOST_CS` deasserts before the declared payload length completes, the command is aborted and any partial final byte is discarded.

### Extended opcode `0x01` — firmware load write

```
Byte 0: 0x7F
Byte 1: 0x01
Byte 2: addr_hi
Byte 3: addr_lo
Byte 4: len_minus_1
Bytes 5...(5+N-1): payload bytes written to CPU SRAM, starting at the specified start address and auto-incrementing after each byte
```

Semantics:

- Valid address range is `0x000`–`0xFFF` only.
- The slave auto-increments `fw_ld_addr` after each accepted byte.
- Writes beyond `0x0FFF` are ignored once the address reaches the top of the 4 kB CPU SRAM window.
- Firmware writes are only permitted while `CPU_RESET[0] = 1`. Host software must assert `CPU_RESET` before issuing this command.
- MISO returns `0x00` for all bytes of a write command.

### Extended opcode `0x02` — firmware readback

Optional but recommended for bring-up and cocotb verification.

```
Byte 0: 0x7F
Byte 1: 0x02
Byte 2: addr_hi
Byte 3: addr_lo
Byte 4: len_minus_1
Bytes 5...(5+N-1): host sends dummy bytes; MISO returns CPU SRAM bytes, starting at the specified start address and auto-incrementing after each byte
```

### Boot sequence

`CPU_RESET` is a normal register write to address `0x02`, not an extended command.

```
1. Host writes CPU_RESET = 1 via register 0x02
2. Host issues one or more extended opcode 0x01 firmware-load writes starting at address 0x000
3. Host optionally verifies contents with extended opcode 0x02
4. Host writes CPU_RESET = 0 via register 0x02
5. PicoRV32 fetches from 0x00000
```

---

## Implementation notes

**Parallel Control Paths.** This SPI slave is a dedicated physical interface on the MPW, allowing host control of Trouper even if the Grouper project is inactive or held in reset.

**Arbitration.** Grouper has priority. A completed SPI write that overlaps one
Grouper byte cycle is retained in a one-entry pending slot and committed after
the Grouper request releases. The Grouper cycle must release before a second SPI
data byte completes (at least 4 µs at the 2 MHz limit). Pin-level SPI has no
WAIT response and the current register bank has one combinational read port, so
an SPI read byte overlapping `GRP_RE=1` is invalid; the host retries the complete
read frame after the Grouper request releases.

**Clock domain crossing.** SPI clock (up to 2 MHz) and the 32 MHz system clock are asynchronous. Run the SPI shifter and frame parser in the SPI clock domain, then cross completed register operations and firmware-load bytes into the core domain with a small handshake or async FIFO.

**MISO drive.** `HOST_MISO` is a dedicated Trouper output in the selected
pinout. Drive it low whenever `HOST_CS` is deasserted; no output-enable or
tri-state behavior is required.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| CHIP_ID read | cocotb SPI master; read 0x00 | Returns 0xA7 |
| Register write + readback | Write known pattern to all R/W registers; read back | Byte-identical readback |
| Extended-command decode | Send `0x7F` frame with opcode `0x01` and `0x02` | Correct command selected; normal register path not triggered |
| Concurrent Access | SPI Slave vs AHB-Lite access to same register | Correct data returned to both; arbitration verified |
| CPU_RESET sequence | Assert, load, de-assert via SPI; monitor fetch | Trouper/Grouper initialisation follows expected flow |

---

## Related blocks

- [Register Map](../Register%20Map.md) — authoritative register set
- [PicoRV32 Integration](PicoRV32%20Integration.md) — firmware load target
- [AHB-Lite Bus](AHB-Lite%20Bus.md) — parallel control path from Grouper
