# Work Allocation Summary

This note turns the block specs into assignable workstreams. The intent is to make it obvious who can own what, where the subblocks are, and what each lane must deliver.

## 1. Acquisition DSP

Blocks:

- `ΣΔ Decimator ×4`
- `Schmidl-Cox Preamble Detector`
- `Energy Measurement`

Subblocks:

- decimator ratio control and `iq_valid` timing
- downchirp reference / dechirp front end
- symbol window manager
- per-antenna SC correlator
- per-antenna energy measurement
- normalizer / threshold comparator
- `SC_HITS_REQ` lock FSM
- `timing_ref` back-calculator
- status export for `SC_STAT` and `ENERGY[0..3]`

Responsibilities:

- produce stable packet-detection and lock timing
- tune `SC_THR` and `SC_HITS_REQ` sensitivity behavior
- keep energy snapshots consistent for AGC
- define the handoff from detection to capture

Deliverables:

- `sc_lock`, `timing_ref`, and energy snapshot behavior
- threshold and hit-count verification
- Python reference model for SC and energy estimation
- correlation against live hardware captured from the [AFE Characterisation Board](AFE%20Characterisation%20Board.md)

## 2. Training Accumulator & Weight Generation

Blocks:

- `Training Accumulator`
- `Weight Generation`
- `Frontend Buffer Controller`

Subblocks:

- preamble window and symbol boundary tracker
- per-branch cross-correlation accumulator (`Z_j`)
- reference-branch energy accumulation (`E_ref`)
- `training_done` signal and handoff to weight generation
- hardware weight path: SHIFT → CALIBRATE → COMPUTE → SCALE
- software weight path: IRQ-driven `W_SHADOW` / `W_COMMIT`
- `W_HW` readback registers for firmware EMA smoothing
- `WGT_AUTO_COMMIT` policy and safe-switch gating

Responsibilities:

- deliver `Z_j` and `training_done` after `sc_lock`
- ensure hardware weight commit within ~50 cycles of `training_done`
- keep `W_HW` readable for firmware at all times
- handle late SC lock and reduced preamble accumulation cases

Deliverables:

- stable `Z_j` and per-packet channel estimate
- hardware weight commit timing verified against SF6 payload window
- Python-to-RTL comparison for `Z_j`, `W_HW`, and EMA smoothing

## 3. Live Combining / Remodulation

Blocks:

- `ALMMSE/MRC Combiner`
- `ΣΔ Re-mod ×2`

Subblocks:

- weight-bank readout
- bypass fallback selection
- complex MAC datapath
- int32 accumulation and saturation
- active/ shadow W commit logic
- remodulator stability and scaling

Responsibilities:

- implement the live sample-by-sample combiner
- preserve no-glitch switching
- make bypass behavior explicit when W is late or invalid
- keep remodulated output within stable range

Deliverables:

- MRC and ALMMSE output paths
- bypass fallback behavior
- fixed-point gain and saturation checks

## 4. Control Plane

Blocks:

- `AHB-Lite Bus`
- `SPI Slave`
- `SPI Master`
- `IRQ Controller`
- `Status Register Bank`
- `SWD TAP`

Subblocks:

- custom PicoRV32-to-AHB-Lite wrapper/master side
- slave decode and register access
- SPI transaction sequencing
- IRQ latch/clear path
- debug access path

Responsibilities:

- keep the control plane coherent and easy to debug
- support firmware load and register access
- surface status, IRQs, and control safely
- avoid bus contention and wait-state bugs

Deliverables:

- AHB-Lite wrapper and interconnect
- clean register read/write path
- interrupt handling path
- debug access for bring-up

## 5. Firmware / Algorithms

Blocks / notes:

- `PicoRV32 RV32IM integration`
- `AGC`
- `MIMO Algorithms`

Subblocks:

- W computation for `NT=1` and `NT=2`
- AGC loop
- branch enable / disable policy
- IRQ handling and packet-state control
- branch-health / fallback policy
- algorithm selection and adaptation policy

Responsibilities:

- own the control-policy layer
- decide when to trust MRC, EGC, SC, or bypass
- manage per-antenna gain and health state
- keep the firmware logic feasible on PicoRV32

Deliverables:

- firmware control loop
- AGC convergence behavior
- algorithm-comparison results
- in-the-loop control policy

## 6. System Simulation / Algorithms

Blocks / notes:

- `MIMO Algorithms`
- `01_dsp_chain_walkthrough.ipynb`
- `02_nt2_detector_comparison.ipynb`

Subblocks:

- Python system model
- algorithm comparison harness
- threshold and hit-count sweeps
- MRC / SC / EGC comparisons
- `NT=2` extension studies
- fallback-policy simulation

Responsibilities:

- define the behavioral truth before RTL
- keep algorithm choice separate from hardware implementation
- produce the reference model for verification

Deliverables:

- Python-first simulation ladder
- algorithm recommendations
- parameter sweeps and corner cases

## 7. Verification

Blocks / notes:

- `Test Plan`
- cocotb block tests
- FPGA characterization path

Subblocks:

- block-level testbenches
- end-to-end packet regressions
- RTL-vs-Python comparison
- register and handoff verification
- AFE capture-path testing
- in-the-loop checks

Responsibilities:

- prove the implementation matches the spec
- catch packet handoff, fixed-point, and bus bugs early
- keep the FPGA tests staged and focused

Deliverables:

- block test coverage
- integration simulation
- FPGA bring-up and common-tone AFE characterization

## 8. RF / Hardware

Blocks / notes:

- `SE2435L Front-End Module`
- AFE characterization notes in `IDEAS.md`

Subblocks:

- branch gain/phase stability
- LO drift measurement
- compression / blocker response
- antenna correlation / placement sensitivity
- branch health and masking policy

Responsibilities:

- characterize the analog front end before full-system dependence
- define what is calibratable versus what requires fallback
- de-risk coherent combining

Deliverables:

- common-tone FPGA capture plan
- branch-mismatch metrics
- calibration and fallback thresholds

## 9. Physical Design

Blocks / notes:

- `Baseband SRAM`
- floorplan / P&R

Subblocks:

- SRAM macro path
- area/timing/power closure
- clock distribution
- placement constraints

Responsibilities:

- resolve the SRAM path early
- keep the design within timing and area budgets
- feed back implementation constraints to the RTL owners

Deliverables:

- workable SRAM macro strategy
- floorplan-ready estimates
- timing-risk reduction

## Assignment Rule

For each workstream, assign one owner who is accountable for the block/spec closure and one reviewer who is accountable for cross-checking interfaces with adjacent workstreams.
