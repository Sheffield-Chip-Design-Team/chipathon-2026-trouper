# src/ — Trouper RTL & physical-design config

Synthesisable RTL for the **Trouper** ASIC (NT=1 NR=4 MRC MIMO LoRa gateway, GF180MCU),
organised one directory per functional block, plus the LibreLane/OpenLane config that builds
the top level.

## Layout

```
src/
  top/         trouper_top.v            — top-level integration
  decimator/   sd_decimator_poly.v      — ΣΔ half-band decimator chain (R=64, 1-bit → int8 @500 kS/s)
  frontend/    dc_removal.v             — IIR DC-removal (leaky integrator)
               sc_detector.v            — Schmidl-Cox preamble detector
  combiner/    training_acc.v           — all-pairs cross-correlator (Z_kl / Z_kk / W_k)
               mrc_combiner.v           — ŷ = wᴴ·x MRC combine
  remod/       sd_remod.v               — 3rd-order ΣΔ re-modulator (OSR=64, int8 → 1-bit @32 MS/s)
  control/     packet_ctrl_fsm.v        — packet control FSM (buf_freeze / W gating / safe_switch)
               reg_bank.v               — 7-bit register map (SPI/AHB accessible)
               spi_slave.v              — host SPI slave
               psram_buf_ctrl.v         — APS6404L PSRAM QPI controller
  config/      trouper_top.json         — LibreLane config (DESIGN_NAME=trouper_top)
               pnr_32m_scoped_v20.sdc   — 32 MHz timing constraints
               pdn_cfg.tcl              — power-grid definition
               io_placement_bl.cfg      — fixed PCB pad order (pads S+W, Grouper E+N)
```

`config/trouper_top.json` lists every RTL file in `VERILOG_FILES` via `dir::../<block>/<file>.v`,
so the block layout above is the source of truth for what is synthesised.

## Current signoff point

- **Die:** 1200×1100 µm (PCB-realistic floor with the fixed `io_placement_bl.cfg` pin order)
- **Cells:** `gf180mcu_fd_sc_mcu7t5v0`, 3.3 V — DRC / LVS / detailed-route clean
- SS 32 MHz timing is voltage-bound (open item; see `planning/`).

See `planning/die-shrink-routability-floor.md` for the die-size / pin-placement study behind
this config.

## Building

Inside the `hpretl/iic-osic-tools:chipathon26` container (repo mounted at `/foss/designs/lora-mimo`):

```bash
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 src/config/trouper_top.json
```
