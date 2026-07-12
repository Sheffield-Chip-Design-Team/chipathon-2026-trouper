# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Read AGENTS.md

## Project Overview

SSCS PICO Chipathon 2026 tapeout. An NT=1 NR=4 MRC MIMO LoRa gateway ASIC in GF180MCU (3.3 V core/IO), targeting September 2026. Four SX1257 front-ends feed four ΣΔ decimator branches on a single chip for ~6 dB diversity gain. The decimator is a **fixed R=64 half-band chain** (`sd_decimator_poly`: 32 MS/s 1-bit IQ → CIC-3 R=16 → HB1 ÷2 → HB2 ÷2 → int8 IQ at **500 kS/s**). Supported LoRa bandwidths: **125 kHz and 250 kHz**, selected by register `0x0A` (`BW_CFG`, `bw_sel` bit[0]; 0 = 250 kHz, 1 = 125 kHz) — *not* by changing the decimation ratio. BW selects only `sample_shift` (oversampling): 250 kHz BW is 2× oversampled (`sample_shift=1`), 125 kHz BW is 4× oversampled (`sample_shift=2`); the symbol period every block uses is `M = 1 << (SF + sample_shift)`. The half-band redesign **eliminates the previous 250 kHz droop limitation**: the old R=128 CIC-only chain put the 250 kHz chirp band edge at Nyquist (−11.8 dB droop); the HB chain holds passband droop to ≈ −0.17 dB. 1 MHz output is out of scope (PSRAM timing budget exceeded). See `planning/decimator-hb-migration-impact-plan.md` for the full migration record (Gates 0–12).

## Repository Layout

```
rtl-test/               Verilog RTL + OpenLane/LibreLane P&R configs
  rtl/                  RTL source files (synthesisable)
  tb/                   Simulation testbenches (tb_*.v)
  scripts/              Run scripts for P&R and simulation jobs
  ol_mimo_rx_top/       Top-level P&R (config_current.json is the active config)
  ol_picorv32*/         PicoRV32 core and wrapper P&R configs (several variants)
sim/                    Python behavioral models and tests
  models/               Bit-true DSP component models (fixed.py, decimator.py, receiver.py, …)
  tests/                pytest-compatible tests + debug scripts
  sims/                 Sweep scripts (BER, SQNR, MIMO)
  notebooks/            Jupyter analysis notebooks
fpga-emul/              Arty A7-100T FPGA emulation wrapper (Verilator + Vivado targets)
characterization/       SPICE sweep scripts for OCD/FD SRAM characterization
planning/               Design documents (System Architecture.md is the canonical reference)
resources/              Datasheets (SX1257, SX1302, APS6404L PSRAM)
ip/                     Third-party IPs (picorv32, AS/OCD SRAM macros, gf180mcu_as_sc_mcu7t3v3)
```

Block-level P&R dirs have been removed — synthesis is now hierarchical at the top level (`ol_mimo_rx_top`). Run outputs (`rtl-test/ol_*/runs/`) live on NFS and are referenced via symlinks; they are git-ignored.

## RTL Simulation (Verilator / iverilog)

From `rtl-test/`:

```bash
# Full DSP chain (primary)
make sim_dsp_chain

# With real captured IQ data + ΣΔ decimator
make sim_dsp_chain_real_probe

# Legacy energy / noise-floor testbench (iverilog)
make sim_dsp

# SQNR testbench (iverilog)
make sim_sqnr

# Clean build artifacts
make clean
```

FPGA emulation sims from `fpga-emul/`:

```bash
make sim_inject       # synthetic preamble → sc_lock + weights
make sim_decim_eth    # 1-bit bitstream → decimated output check
make sim_all
```

## Python Simulation

All commands run from the **repo root**:

```bash
# BER vs SNR (MRC, NT=1)
python3 -m sim.tests.run_ber --nt 1

# BER vs SNR (ALMMSE, NT=2)
python3 -m sim.tests.run_ber --nt 2

# Fixed-point bit-width sweep
python3 -m sim.tests.run_ber --fixedpoint

# Run pytest unit tests
pytest sim/tests/
```

## Physical Design (LibreLane / OpenLane)

Run inside the `hpretl/iic-osic-tools:chipathon26` Docker image — **never use `:latest` or `:2026.04`**.

### Standard FD cells (`gf180mcu_fd_sc_mcu7t5v0`) — 16 MHz only, fails 32 MHz SS

```bash
docker run --rm --user $(id -u):$(id -g) \
  -v $(pwd):/foss/designs/lora-mimo \
  hpretl/iic-osic-tools:chipathon26 \
  --skip bash -c "cd /foss/designs/lora-mimo/rtl-test && \
    librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 <block_dir>/config.json"
```

### Native 3.3 V AS cells (`gf180mcu_as_sc_mcu7t3v3`) — **not the current plan**

> **Status:** AS cells are unlikely to be used for tapeout. The library is unproven (community-maintained, not a GF-qualified foundry library) and its use carries tapeout risk. The `config_as_mcu7t3v3.json` configs and P&R history are retained for reference, but new work should target FD cells. The 32 MHz SS timing gap with FD cells is to be closed via MCP or clock-domain partitioning instead.

If AS cells are still needed for a specific experiment:

```bash
librelane --pdk-root /foss/designs/pdk_overlay_as \
          --pdk gf180mcuD --scl gf180mcu_as_sc_mcu7t3v3 \
          <block_dir>/config_as_mcu7t3v3.json
```

AS-cell configs must use `clkbuff_*` for CTS (not `buff_*` — causes DRT-0073), set `FP_CORE_UTIL` to **50–60%**.

### Reading P&R results

```bash
# Post-PNR SS timing WNS
cat rtl-test/ol_<block>/runs/RUN_*/56-openroad-stapostpnr/max_ss_125C_3v00/wns.max.rpt

# Magic DRC error count
python3 -c "
import json, glob
f = sorted(glob.glob('rtl-test/ol_<block>/runs/RUN_*/66-checker-magicdrc/state_out.json'))[-1]
print(json.load(open(f)).get('metrics',{}).get('magic__drc_error__count','not found'))"
```

## Homelab SGE (EDA job scheduler)

```bash
export HLAB_SGE_URL=http://nas.home:4783
```

Submit jobs via `hqsub`, monitor via `hqstat --json` or `curl $HLAB_SGE_URL/api/jobs/<ID>`. Terminal states: `DONE`, `FAILED`, `CANCELLED`. Job stdout/stderr at `/srv/eda/logs/timothyn/job-<ID>.o/.e`. Input files go to `/srv/eda/designs/timothyjabez/lora-mimo/` (NFS-persistent), visible inside the container at `/foss/designs/`. See `AGENTS.md` for complete examples.

## System Architecture Summary

The ASIC digital signal chain (all synchronous at 32 MHz):

1. **ΣΔ Decimator** (`sd_decimator_poly.v`) — half-band chain R=64 (CIC-3 R=16 → HB1 ÷2 → HB2 ÷2), polyphase HB delay lines + 14-bit CIC, 1-bit → int8 at 500 kS/s, ×4 branches (TDM)
2. **DC Removal** (`dc_removal.v`) — IIR leaky integrator, α=2^{−5} (13-bit Q8.5 acc), ×4
3. **Schmidl-Cox Detector** (`sc_detector.v`) — sliding autocorr, produces `sc_lock` + `timing_ref`
4. **PSRAM Buffer Controller** (`psram_buf_ctrl.v`) — APS6404L QPI controller: circular capture, SC delay-line reads at `write_ptr − M`, same-packet replay as a never-rewinding delay line starting at `training_done + REPLAY_DELAY_SAMPLES` (regs 0x77/0x78; `W_COMMIT` only gates weights — late/never commits degrade to bypass) (replaces the removed `frontend_buf_ctrl.v`/on-chip SRAM)
5. **Noise Estimation** — `noise_est.v` removed; firmware-triggered `training_acc` noise mode (`TACC_NOISE_TRIG`) + SC-contamination gate (`NOISE_READY` IRQ) replace it
6. **Training Accumulator** (`training_acc.v`) — all-pairs cross-correlator: 6 Z_kl pairs (C(4,2)) + 4 Z_kk diagonal. Z_kl pairs → firmware weight computation (MRC row-sum or eigenvector) via reg_bank 0x40–0x63 (24-bit [31:8] readback; Zdiag at 0x64–0x6F). Noise mode: firmware write to TACC_NOISE_TRIG (0x1F) arms accumulator without sc_lock; Z_kk ≈ σ²_k·n_acc for noise EMA. Register map is 7-bit (0x00–0x7F) — see planning/Register Map.md.
7. **Packet Control FSM** (`packet_ctrl_fsm.v`) — controls buf_freeze, W gating, safe_switch
8. **Weight Generation** — firmware-only (no `weight_gen.v` in RTL, TRPR-WGN-001): Grouper/host reads Z over SPI/GRP bus, computes W (MRC row-sum or power-iteration eigenvector, `sim/models/eigvec_fw.py`), writes the W shadow (0x30–0x3F) and pulses `WGT_CTRL.W_COMMIT`
9. **MRC Combiner** (`mrc_combiner.v`) — ŷ[n] = w^H·x[n], int32→int8 (÷2 guard shift)
10. **ΣΔ Re-modulator** (`sd_remod.v`) — 3rd-order NTF synthesised for **OSR=64** (int8 in at 500 kS/s, 1-bit out at 32 MS/s), input must be < −3 dBFS (wrap-around causes permanent instability)

**Control plane:** no on-chip CPU, SPI master, or JTAG. Host SPI slave (RPi) and the Grouper inter-project register bus (`GRP_*`, priority over SPI) arbitrate into a hand-written `reg_bank.v` (7-bit map 0x00–0x7F; *not* Python-generated — see TRPR-REG-005 note in planning/Traceability.md); sticky IRQ_STATUS drives the `IRQ_OUT` pad and `IRQ_GROUPER`. SX1257 configuration is external (TRPR-SPM-001). Top-level integration: `src/top/trouper_top.v`.

**Key constraint:** The `gf180mcu_fd_sc_mcu7t5v0` standard cell library is characterised at 3 V SS but designed for 5 V — it fails 32 MHz timing on all blocks at the SS corner. AS cells (`gf180mcu_as_sc_mcu7t3v3`) close SS timing but are unproven and not the current tapeout plan; the preferred path is FD cells with MCP or clock-domain partitioning to meet 32 MHz.
