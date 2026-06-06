# wafer.space `ws-run1` Project Audit

This table summarizes the public `ws-run1` projects inspected so far.

Notes:
- `Density` is the configured target from checked-in flow configs, usually `PL_TARGET_DENSITY_PCT` or `FP_CORE_UTIL` for small macros.
- `Density` is not final achieved utilization.
- `Frequency` is included only when the repo explicitly published a timing/frequency note in checked-in docs.
- Blank fields mean I did not find an explicit published value in the inspected files.

| Code | Project | Cell library | Density target | Frequency note |
|---|---|---|---:|---|
| `OCD1` | `openframe_caravel_picorv32` | `gf180mcu_as_sc_mcu7t3v3` plus `gf180mcu_ocd_io`, `gf180mcu_ocd_ip_sram`, and some `gf180mcu_fd_sc_mcu7t5v0` |  |  |
| `OCD2` | `ocd_sram_test` | `gf180mcu_ocd_ip_sram` plus `gf180mcu_as_sc_mcu7t3v3` and some `gf180mcu_fd_sc_mcu7t5v0` |  |  |
| `TQVA/B/C` | `TinyQV` | `gf180mcu_fd_sc_mcu7t5v0` | `50` | Intended for `24 MHz` at `3.3 V` at nominal corner; around `40 MHz` at `5 V` claimed in README |
| `KIAN` | `KianV` | `gf180mcu_fd_sc_mcu9t5v0` | `30.2` |  |
| `CAFE` | `FazyRV Hachure` | `gf180mcu_fd_sc_mcu7t5v0` | top: `38`; macros: `55`, `60`, `65` |  |
| `JKU1` | `gf180mcu-jku-projects` | top-level config references `gf180mcu_fd_sc_mcu7t5v0` buffers; individual macros vary | `35` | top-level `CLOCK_PERIOD: 25 ns` (`40 MHz`); README says several macros still have SS setup violations |
| `JKU2` | `gf180mcu-jku-atbs-adc` | top-level library not explicitly pinned in checked config; likely `fd_sc`-based LibreLane flow | `25` | top-level `CLOCK_PERIOD: 125 ns` (`~8 MHz`); README says top-level and ADC are pass/no violations |
| `MOLE` | `gf180mcu-fabulous-fpga` | top-level config references `gf180mcu_fd_sc_mcu7t5v0` buffers; also uses `gf180mcu_fd_ip_sram` macros | `35` | top-level `CLOCK_PERIOD: 40 ns` (`25 MHz`) |
| `GD04` | `Racquet Wide 1x0.5` | `gf180mcu_fd_sc_mcu9t5v0` |  |  |
| `GD03` | `Racquet r2p0` | not explicit in checked top-level config; no `as_sc` use found | `65` | top-level `CLOCK_PERIOD: 100 ns` (`10 MHz`) |
| `GD02` | `Racquet Half r1p0` | not explicit in checked top-level config; no `as_sc` use found | `65` | top-level `CLOCK_PERIOD: 100 ns` (`10 MHz`) |
| `RBOY` | `RISCBoy-180` | `gf180mcu_fd_sc_mcu9t5v0` | `50` | Early note: `-5 ns` WNS at `25 MHz`; later notes say `24 MHz` should be fine and final chosen feature set meets timing |
| `BTAP` | `BreakingTTAPs` | `gf180mcu_fd_sc_mcu9t5v0` | `45` |  |
| `CHES` | `chess-move-generator` | not explicit in checked config; no `as_sc` use found | `35` | top-level `CLOCK_PERIOD: 40 ns` (`25 MHz`) |
| `2975` | `Cloneless1` | `gf180mcu_fd_sc_mcu7t5v0` | top: `65`; macro `FP_CORE_UTIL`: `29`, `45`, `49`, `59`, `65` | top-level `CLOCK_PERIOD: 250 ns` (`4 MHz`) |
| `RZ80` / `HZ80` | `ws0-z80-open-silicon-gf180mcu` | `gf180mcu_fd_sc_mcu9t5v0` | `20` | top-level `CLOCK_PERIOD: 40 ns` (`25 MHz`) |
| `AS03` | `ws-submission-2025` | mixed; checked macro configs include `gf180mcu_fd_sc_mcu9t5v0`, top-level sources reference `mcu7t5v0`, and one macro also pulls in `gf180mcu_as_ex_mcu7t5v0` |  |  |
| `ISHI` | `ISHI-KAI's Multiple Users Project` | not yet extracted; manifest describes a mostly analog multi-project die |  |  |
| `MOS2` | `AutoMOS-chipathon2025` | not yet extracted |  |  |
| `TTP2` | `tinytapeout-gf-0p2` | not yet extracted |  |  |
| `TTPG` | `tinytapeout-gf-0p2` power-gated variant | not yet extracted |  |  |
| `TZ01` | `gf180mcu-testchip2025` | not yet extracted |  |  |
| `TRID` | `gf180mcu-project-trident-gf180-teststructure` | not yet extracted; likely test-structure oriented rather than a standard-cell-heavy digital design |  |  |
| `WSLG` | `ws-logo-die` | not yet extracted; likely layout/art-focused rather than a standard-cell-heavy digital design |  |  |

## Source notes

- `OCD1` library callout: [ip/ws-run1/README.md](../ip/ws-run1/README.md)
- `TinyQV`: `/tmp/ws-tinyqv/librelane/config.yaml`, `/tmp/ws-tinyqv/README.md`
- `KianV`: `/tmp/ws-kianv/librelane/config.yaml`
- `FazyRV Hachure`: `/tmp/ws-fazyrv/librelane/config.yaml`, `/tmp/ws-fazyrv/macros/*/config.yaml`
- `JKU1`: `git -C /tmp/ws-scan/gf180mcu-jku-projects show HEAD:librelane/config.yaml`, `.../README.md`
- `JKU2`: `git -C /tmp/ws-scan/gf180mcu-jku-atbs-adc show HEAD:librelane/config.yaml`, `.../README.md`
- `MOLE`: `git -C /tmp/ws-scan/gf180mcu-fabulous-fpga show HEAD:librelane/config.yaml`, `.../README.md`
- `Racquet Wide 1x0.5`: `/tmp/ws-racquet-1x0.5/librelane/slots/slot_1x0p5.yaml`
- `Racquet r2p0`: `/tmp/ws-scan/gf180mcu-racquet/librelane/config.yaml`
- `Racquet Half r1p0`: `/tmp/ws-scan/gf180mcu-racquet-0.5x1/librelane/config.yaml`
- `RISCBoy-180`: `/tmp/ws-scan/riscboy-180/librelane/config.yaml`, `/tmp/ws-riscboy/notes.md`
- `BreakingTTAPs`: `/tmp/ws-scan/BreakingTTAPs/librelane/config.yaml`
- `chess-move-generator`: `/tmp/ws-scan/gf180mcu-chess/librelane/config.yaml`
- `Cloneless1`: `/tmp/ws-scan/Cloneless1/chip_top.yaml`, `/tmp/ws-scan/Cloneless1/Makefile`, `/tmp/ws-scan/Cloneless1/macros/*/*.yaml`
- `ws0-z80-open-silicon-gf180mcu`: `/tmp/ws-scan/ws0-z80-open-silicon-gf180mcu/librelane/config.yaml`
- `ws-submission-2025`: `/tmp/ws-scan/ws-submission-2025/macros/*/config.yaml`, `/tmp/ws-scan/ws-submission-2025/src/chip_top.sv`
- `OCD2`: `git -C /tmp/ws-scan/gf180mcu_ocd_sram_test ls-tree -r --name-only HEAD`, `git -C /tmp/ws-scan/gf180mcu_ocd_sram_test grep -n ... HEAD --`
