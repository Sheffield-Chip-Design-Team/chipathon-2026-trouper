# Work Allocation Summary

This note turns the block specs into assignable workstreams. The intent is to make it obvious who can own what, where the subblocks are, and what each lane must deliver.

## 1. Acquisition DSP (Trouper Project)

Blocks:
- `ΣΔ Decimator ×4`
- `DC Removal ×4`
- `Schmidl-Cox Preamble Detector`
- `PSRAM Buffer Controller`

Subblocks:
- decimator ratio control and `iq_valid` timing
- downchirp reference / dechirp front end
- symbol window manager
- per-antenna SC correlator
- `SC_HITS_REQ` lock FSM
- `timing_ref` back-calculator
- status export for `SC_STAT`
- PSRAM QSPI interface and replay FSM

Responsibilities:
- produce stable packet-detection and lock timing
- tune `SC_THR` and `SC_HITS_REQ` sensitivity behavior
- define the handoff from detection to capture
- manage the PSRAM delay line and replay buffer

Deliverables:
- `sc_lock`, `timing_ref`, and PSRAM replay behavior
- threshold and hit-count verification
- Python reference model for SC and PSRAM replay
- correlation against live hardware captured from the [AFE Characterisation Board](AFE%20Characterisation%20Board.md)

## 2. Parameter Extraction & Training (Trouper Project)

**Goal:** Extract channel statistics and energy metrics for the weight computation loop.

Blocks:
- `Training Accumulator`

Subblocks:
- preamble window and symbol boundary tracker
- per-branch cross-correlation accumulator (`Z_kl`) for **channel estimates**
- per-branch auto-correlation accumulator (`Z_kk`) for **energy estimate** (noise/signal power)
- `training_done` signal and handoff to software weight generation
- `Z_kl` and `Z_kk` readback registers for firmware weight computation

Responsibilities:
- deliver `Z_kl`, `Z_kk` (energy), and `training_done` after `sc_lock`
- ensure register bank correctly exposes correlation metrics to the AHB-Lite bus
- handle late SC lock and reduced preamble accumulation cases

Deliverables:
- stable channel covariance matrix (`Z`) and per-packet energy metrics
- Python-to-RTL comparison for `Z_kl` and `Z_kk`

## 3. Combining & Modulation (Trouper Project)

Blocks:
- `MRC Combiner`
- `ΣΔ Re-modulator`

Subblocks:
- weight-bank readout (shadow/active)
- bypass fallback selection
- complex MAC datapath
- int32 accumulation and saturation
- remodulator stability and scaling

Responsibilities:
- implement the live sample-by-sample combiner
- preserve no-glitch switching between bypass and combined modes
- make bypass behavior explicit when W is late or invalid
- keep remodulated output within stable range

Deliverables:
- MRC output path and bypass fallback behavior
- fixed-point gain and saturation checks
- End-to-end SNR validation (Python ref vs RTL remod output)

## 4. Control Plane & Integration (Trouper Project)

Blocks:
- `Trouper AHB-Lite Slave`
- `Trouper SPI Slave (Host)`
- `IRQ Controller`
- `Status Register Bank`
- `Packet Control FSM`

Subblocks:
- slave decode and register access (Trouper)
- host SPI transaction sequencing (Trouper)
- IRQ latch/clear path (Trouper-to-Grouper)
- sequencing of training vs combining (Packet Control FSM)

Responsibilities:
- ensure Trouper correctly integrates as an AHB-Lite peripheral.
- support dual control: Host SPI (Trouper-only) vs AHB-Lite (Grouper-mastered).
- avoid bus contention and wait-state bugs.

Deliverables:
- `trouper_top` RTL with all DSP blocks integrated
- Register map documentation
- Chip-level cocotb smoke test

## 5. PicoRV32 Integration (Grouper Project)

Blocks:
- `PicoRV32 RV32IM core`
- `AHB-Lite Bus Fabric`
- `4 KB Unified SRAM (OCD macros)`
- `BIST controller and overlay CAM`

Subblocks:
- custom PicoRV32-to-AHB-Lite wrapper (Grouper)
- inter-project AHB-Lite interface (MPW-level)
- BIST qualified banks and CAM logic

Responsibilities:
- deliver the central Grouper system bus and CPU macro.
- handle bootloader / SPI-load functionality.

Deliverables:
- `grouper_top` hardened macro RTL/GDS
- BIST verification report

## 6. PicoRV32 Firmware & Algorithms

Blocks / notes:
- `AGC Firmware`
- `MIMO Algorithms`
- `SX1257 Initialization`

Subblocks:
- W computation for `NT=1` (MRC, EGC) using RV32IM hardware MUL
- AGC loop managing SX1257 gains via SPI slave (host assist or Grouper)
- SX1257 initialization and mode control
- branch enable / disable policy
- IRQ handling from Trouper events

Responsibilities:
- own the control-policy layer for the entire MPW.
- manage Trouper's MIMO RX state via firmware running in Grouper.
- keep the firmware logic feasible on PicoRV32 (timing and memory footprint).

Deliverables:
- firmware control loop (residing in Grouper).
- Trouper AGC convergence behavior.
- algorithm selection results (MRC vs SC vs EGC).
- compiled ELF/Hex for SRAM loading.

## 7. System Simulation & Models

Blocks / notes:
- Python system model (bit-exact reference)
- Algorithm selection report

Subblocks:
- bit-accurate dsp chain walkthrough
- algorithm comparison harness
- threshold and hit-count sweeps
- CFO estimation and compensation models

Responsibilities:
- define the behavioral truth before RTL implementation
- produce the reference model for verification
- define algorithm selection (Shift-MRC vs Oracle)

Deliverables:
- Python-first simulation ladder
- algorithm recommendations
- golden test vectors for cocotb

## 8. Verification

Blocks / notes:
- `Test Plan`
- cocotb block tests
- FPGA characterization path

Subblocks:
- block-level testbenches
- end-to-end packet regressions (Trouper hardware)
- RTL-vs-Python comparison
- inter-project bus verification (Grouper-Trouper AHB access)

Responsibilities:
- prove the implementation matches the spec
- catch packet handoff, fixed-point, and bus bugs early
- verify inter-project communication protocols

Deliverables:
- block test coverage
- integration simulation (full MPW model)
- FPGA bring-up and common-tone AFE characterization

## 9. Physical Design & Floorplan

Blocks / notes:
- floorplan / P&R (Trouper and Grouper separate runs)

Subblocks:
- macro placement (Grouper PicoRV32/SRAM)
- area/timing/power closure for each project
- MPW-level routing for AHB-Lite bus
- 28-pad constraint management (Trouper)

Responsibilities:
- keep each project within its timing and area budgets
- manage pad budget rigorously (≤28 pads for Trouper; 25 used as of 2026-08-30)
- deliver GDSII / LEF for both macros

Deliverables:
- physical GDS for Trouper and Grouper
- timing sign-off (32 MHz)
- power analysis

## 10. Hardware & Characterization

Blocks / notes:
- `AFE Characterisation Board`
- Silicon bring-up notes

Subblocks:
- branch gain/phase stability
- LO drift measurement
- compression / blocker response

Responsibilities:
- characterize the analog front end before full-system dependence
- characterize silicon performance (shmoo plots)

Deliverables:
- Schematic/Layout for test PCB
- FPGA bitstream and driver
- Characterization report

## Assignment Rule

For each workstream, assign one owner who is accountable for the block/spec closure and one reviewer who is accountable for cross-checking interfaces with adjacent workstreams.
