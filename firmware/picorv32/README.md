# PicoRV32 Firmware

Bare-metal firmware for the **Grouper PicoRV32 control core (RV32EMC)**. On a
Trouper-only tapeout there is no on-chip CPU (host RPi / external MCU over SPI
does weight computation); this image targets the Grouper core, or an external
RV32EMC MCU as the backup weight-commit path.

## Target ISA — RV32EMC (fixed)

The Grouper core is `ENABLE_REGS_16_31(0)` + `COMPRESSED_ISA(1)` +
`ENABLE_MUL(1)` → **`-march=rv32emc -mabi=ilp32e`**. The `Makefile` targets this.

> Do **not** build `rv32im/ilp32` (32 registers): that image traps on the
> 16-register RV32E core the moment it touches x16–x31.

## Memory Map

- `0x00000000`–`0x00000FFF`: unified instruction/data SRAM (4 KiB)
- `ASIC_REG_BASE` (default `0x00010000`): 128-byte register bank (`0x00`–`0x7F`
  of `planning/Register Map.md`).

`ASIC_REG_BASE` is the address at which the register bank is decoded in the CPU
address space — an SoC-integration detail that **must match the Grouper
PicoRV32 wrapper's peripheral decode**. Override with `-DASIC_REG_BASE=…` in
`CFLAGS` if the integration differs.

The linker script assumes the whole image lives in the 4 KiB SRAM, loaded
byte-for-byte over the SPI firmware-load path.

## What The Firmware Does

`main.c` is a polling loop that, on `IRQ_TRAINING_DONE`, runs
`compute_eigvec_weights_fw()`:

- reads the 4×4 Hermitian channel matrix Z — 6 off-diagonal `Z_kl` pairs
  (`0x40`–`0x63`, signed 24-bit `[31:8]`) + 4 diagonal `ZDIAG_k`
  (`0x64`–`0x6F`, unsigned 24-bit `[31:8]`, matched scale — no alignment shift);
- finds the principal eigenvector by 8 iterations of the fixed-point power
  method (int12 normalisation, int32 datapath — verified to < 0.05° vs float
  `eigh`, `sim/tests/test_eigvec_fw.py`);
- writes `conj(v)` as Q1.15 MRC weights to the W shadow bank (`0x30`–`0x3F`)
  and pulses `WGT_CTRL.W_COMMIT` (`0x1E`).

Reference model: `sim/models/eigvec_fw.py`. AGC and noise-EMA policy are
external-board-controller-side (see `planning/Register Map.md` `0x1F` /
`0x64`–`0x6F`); Grouper is not taped out alongside Trouper.

### Timing (cycle-accurate, PicoRV32 @16 MHz)

8-iteration compute costs **~36.5k cycles ≈ 2.28 ms** on rv32emc (measured, SGE
jobs 3333–3337; `planning/blocks/Eigenvector Weight Computation.md` Timing
Budget). This misses the live-mode deadline at SF7/SF8 — **PSRAM replay mode is
the required path there** under worst-case low-SNR; live mode only closes SF9+.
Iteration count cannot be cut (the low-SNR corner needs all 8). The int12
internal precision is *not* the limiter and must not be widened past 12 bits
(int32 accumulation ceiling → would force slow 64-bit `mulh`).

## Build

Toolchain: `riscv32-unknown-elf-gcc` (or `riscv64-…` multilib with the prefix
override — the CI/SGE image ships `riscv64-unknown-elf-gcc`):

```bash
cd firmware/picorv32
make                                    # riscv32-unknown-elf- default
make TOOLCHAIN_PREFIX=riscv64-unknown-elf-
```

Outputs: `build/picorv32_fw.{elf,bin,map,dump}`.

## Next Steps

- confirm `ASIC_REG_BASE` against the Grouper SoC peripheral decode
- replace polling with real PicoRV32 IRQ entry/dispatch
- host-side loader to push `picorv32_fw.bin` over the SPI firmware-load path
- functional bring-up against the real `reg_bank` in cocotb (current
  verification covers the Python reference model and cycle-accurate PicoRV32
  benchmark harness)
