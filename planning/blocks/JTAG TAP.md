# JTAG TAP (PicoRV32 Debug)

Control block. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

4-pin JTAG interface for post-silicon PicoRV32 firmware debugging. Exposes four pads (`TCK_IRQ`, `TMS_GPIO0`, `TDI_GPIO1`, `TDO_GPIO2`) to an external probe (e.g. J-Link, DAPLink, or Raspberry Pi bit-bang JTAG).

All four pads are dual-function, selected by the `JTAG_EN` config bit:

| `JTAG_EN` | `TCK_IRQ` | `TMS_GPIO0` | `TDI_GPIO1` | `TDO_GPIO2` |
|---|---|---|---|---|
| 0 (default after reset) | IRQ output (active-high interrupt to RPi) | GPIO_0 — firmware-controlled bidirectional | GPIO_1 — firmware-controlled bidirectional | GPIO_2 — firmware-controlled bidirectional |
| 1 (debug mode) | JTAG TCK input (from probe) | JTAG TMS input (from probe) | JTAG TDI input (from probe) | JTAG TDO output (to probe) |

The RPi sets `JTAG_EN=1` via SPI and reconfigures its `TCK_IRQ` GPIO as input before attaching a probe. On debug exit the RPi writes `JTAG_EN=0` and reconfigures its GPIO as rising-edge interrupt input.

---

## Interface

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `TCK_IRQ` | bidir | 1 | Output when `JTAG_EN=0` (IRQ); input when `JTAG_EN=1` (JTAG TCK from probe). IO cell output-enable controlled by `JTAG_EN`. |
| `TMS_GPIO0` | bidir | 1 | GPIO_0 when `JTAG_EN=0`; JTAG TMS input when `JTAG_EN=1`. |
| `TDI_GPIO1` | bidir | 1 | GPIO_1 when `JTAG_EN=0`; JTAG TDI input when `JTAG_EN=1`. |
| `TDO_GPIO2` | bidir | 1 | GPIO_2 when `JTAG_EN=0`; JTAG TDO output when `JTAG_EN=1`. Output-enable always asserted in debug mode. |
| `jtag_en` | in | 1 | From config register — selects pad function |
| `gpio_out` | in | 3 | GPIO_0–2 output values (used when `JTAG_EN=0` and corresponding `gpio_dir` bit = 1) |
| `gpio_dir` | in | 3 | GPIO_0–2 direction: 1=output, 0=input (used when `JTAG_EN=0`) |
| `gpio_in` | out | 3 | GPIO_0–2 sampled input values (valid when `JTAG_EN=0` and `gpio_dir` bit = 0) |
| `clk_16m` | in | — | Master clock (synchroniser) |
| `rst_n` | in | — | Active-low reset |
| `cpu_halt` | out | 1 | Halts PicoRV32 for register access |
| `cpu_reg_addr` | out | 5 | Register file address for read/write |
| `cpu_reg_rdata` | in | 32 | Register file read data |
| `cpu_reg_wdata` | out | 32 | Register file write data |
| `cpu_reg_we` | out | 1 | Register write enable |
| `mem_addr` | out | 32 | Memory access address |
| `mem_rdata` | in | 32 | Memory read data |
| `mem_wdata` | out | 32 | Memory write data |
| `mem_we` | out | 1 | Memory write enable |

---

## Implementation notes

**Scope.** RISC-V Debug Specification 0.13 DTM + DM. Required capabilities:

| Capability | Mechanism | Notes |
|---|---|---|
| Halt / resume | `haltreq` / `resumereq` in `dmcontrol` | — |
| Read/write GPRs x0–x31 | Abstract `Access Register` command | Must work without SRAM — operates only on register file |
| Single-step | `step` bit in `dcsr` | — |
| Memory read/write | Program buffer + `lw`/`sw` sequence | Used for SRAM load and diagnostic readback |
| **Program buffer** | ≥ 8 instructions (32-bit each) | **Critical for total SRAM failure recovery** — CPU fetches from DM scratchpad, not SRAM; allows diagnostic code execution independent of SRAM state |

Abstract `Access Register` and program buffer execution are the key bring-up safety net: if the CPU SRAM is completely dead, the DM can still halt the CPU, inspect all 32 GPRs and CSRs, and execute short diagnostic routines (SPI transactions, register reads) from the program buffer without any working SRAM. See [Memory Strategy](../Memory%20Strategy.md) — JTAG recovery section.

**Existing IP.** Consider adapting an existing open-source RISC-V DTM+DM implementation (e.g. from the CVA6 or ibex debug subsystem). The RISC-V Debug Spec 0.13 defines the JTAG DTM register set (`dtmcs`, `dmi`) and DM register map (`dmcontrol`, `dmstatus`, `command`, `progbuf`, `abstractcs`).

**TDO bidir.** `TDO_GPIO2` requires a bidirectional pad. In debug mode output-enable is always asserted (TAP always drives TDO). In normal mode output-enable follows `gpio_dir[2]`.

**Clock domain.** TCK is asynchronous to 16 MHz. Synchronise TCK edges into the 16 MHz domain with a 2-FF synchroniser; alternatively implement the TAP FSM entirely in the TCK domain with handshake to PicoRV32.

**Post-silicon priority.** This block is a bring-up aid, not in the functional data path. If gate budget is tight, drop it and rely on SPI register readback for debugging.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Halt + register read | cocotb JTAG model; halt PicoRV32; read PC | Correct PC value |
| Memory read | Read known IMEM contents via JTAG | Data matches what was loaded |
| Resume | Release halt | PicoRV32 continues execution |
| GPIO normal mode | `JTAG_EN=0`; drive `gpio_out`, toggle `gpio_dir` | Pad drives/reads correctly; IRQ fires on `TCK_IRQ` |
| Mode switch | Set `JTAG_EN=1`; connect JTAG model; switch back | No contention; IRQ resumes after switch |

---

## Related blocks

- [PicoRV32 Integration](PicoRV32%20Integration.md) — debug target
- [IRQ Controller](IRQ%20Controller.md) — shares `TCK_IRQ` pad in normal mode
- [System Architecture](../System%20Diagram.md) — `TCK_IRQ` / `TMS_GPIO0` / `TDI_GPIO1` / `TDO_GPIO2` pads
