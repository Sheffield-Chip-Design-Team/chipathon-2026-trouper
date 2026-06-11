# PicoRV32 Firmware

Minimal bare-metal firmware for the ASIC PicoRV32 control core.

Current goals:

- boot cleanly from the `4 KiB` on-core SRAM
- use the real AHB/register-bank interface at `0x10000`
- provide a diagnostics-first firmware image
- leave a clean path for later IRQ, AGC, and weight-override work

## Memory Map

- `0x00000000`–`0x00000FFF`: unified instruction/data SRAM
- `0x00010000`–`0x000100FF`: register bank
- `0x00010100`–`0x000101FF`: SPI master slave-window
- `0x00010200`–`0x000102FF`: IRQ controller slave-window
- `0x00010300`–`0x000103FF`: JTAG/SWD TAP slave-window

The linker script in this directory assumes the whole firmware image lives in
the `4 KiB` SRAM and is loaded there byte-for-byte over the SPI firmware-load
path.

## What The Current Firmware Does

`main.c` currently implements a small polling loop that:

- reads `IRQ_STATUS`
- reacts to `corr_lock`, `training_done`, `packet_done`, and TX events
- updates the firmware-owned diagnostic registers:
  - `COND_NUM`
  - `SNR_0`
  - `NULL_QUALITY`
- keeps the CPU side structurally aligned with the current register map

This is deliberately a bring-up image, not the final AGC or ALMMSE firmware.

## Build

Expected toolchain:

- `riscv32-unknown-elf-gcc`

Build:

```bash
cd firmware/picorv32
make
```

Outputs:

- `build/picorv32_fw.elf`
- `build/picorv32_fw.bin`
- `build/picorv32_fw.map`
- `build/picorv32_fw.dump`

If your toolchain uses a different prefix:

```bash
make TOOLCHAIN_PREFIX=riscv64-unknown-elf-
```

## Next Steps

- replace polling with real PicoRV32 IRQ entry/dispatch
- add software weight override on `IRQ_TRAINING_DONE`
- add AGC policy on `IRQ_CORR_LOCK`
- add a host-side loader that pushes `picorv32_fw.bin` over the SPI firmware path
