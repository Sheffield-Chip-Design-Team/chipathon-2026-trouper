# Work Allocation Summary

This note turns the block specs into assignable workstreams. The intent is to make it obvious who can own what, where the subblocks are, and what each lane must deliver.

## 1. Acquisition DSP (Trouper Project)

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

## 2. Training Accumulator & Weight Generation (Trouper hardware)

Blocks:
- `Training Accumulator`
- `Frontend Buffer Controller`

Subblocks:
- preamble window and symbol boundary tracker
- per-branch cross-correlation accumulator (`Z_j`)
- `training_done` signal and handoff to software weight generation
- hardware bypass path
- `Z_j` readback registers for firmware weight computation
- safe-switch gating at packet boundaries

Responsibilities:
- deliver `Z_j` and `training_done` after `sc_lock`
- ensure register bank correctly exposes correlation metrics to the AHB-Lite bus
- handle late SC lock and reduced preamble accumulation cases

Deliverables:
- stable `Z_j` and per-packet channel estimate
- hardware bypass/combined switching logic
- Python-to-RTL comparison for `Z_j` and channel estimation

## 3. Live Combining / Remodulation (Trouper hardware)

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
- MRC and EGC output paths
- bypass fallback behavior
- fixed-point gain and saturation checks

## 4. Control Plane (Inter-Project Integration)

Blocks:
- `AHB-Lite Bus (Grouper)`
- `PicoRV32 Integration (Grouper)`
- `Trouper AHB-Lite Slave`
- `Trouper SPI Slave (Host)`
- `Trouper SPI Master (SX1257)`
- `IRQ Controller`
- `Status Register Bank`

Subblocks:
- custom PicoRV32-to-AHB-Lite wrapper (Grouper)
- slave decode and register access (Trouper)
- inter-project AHB-Lite interface (MPW-level)
- host SPI transaction sequencing (Trouper)
- IRQ latch/clear path (Trouper-to-Grouper)

Responsibilities:
- deliver the central Grouper system bus and CPU macro.
- ensure Trouper correctly integrates as an AHB-Lite peripheral.
- support dual control: Host SPI (Trouper-only) vs AHB-Lite (Grouper-mastered).
- avoid bus contention and wait-state bugs across projects.

Deliverables:
- Grouper AHB-Lite system bus and PicoRV32 wrapper.
- Trouper AHB-Lite slave interface and register bank.
- interrupt handling path (Trouper-to-Grouper).

## 5. Firmware / Algorithms (Grouper Project)

Blocks / notes:
- `PicoRV32 RV32IM Integration (Grouper)`
- `AGC Firmware`
- `MIMO Algorithms`

Subblocks:
- W computation for `NT=1` (MRC, EGC, SC) using RV32IM hardware MUL
- AGC loop managing Trouper SX1257 gains via AHB-Lite
- branch enable / disable policy
- IRQ handling from Trouper events
- algorithm selection and adaptation policy

Responsibilities:
- own the control-policy layer for the entire MPW.
- manage Trouper's MIMO RX state via firmware running in Grouper.
- keep the firmware logic feasible on PicoRV32 (timing and memory footprint).

Deliverables:
- firmware control loop (residing in Grouper).
- Trouper AGC convergence behavior.
- algorithm-comparison results (MRC vs SC vs EGC).
- in-the-loop control policy documentation.

## 6. System Simulation / Algorithms

Blocks / notes:
- `MIMO Algorithms`
- `01_dsp_chain_walkthrough.ipynb`

Subblocks:
- Python system model (bit-exact reference)
- algorithm comparison harness
- threshold and hit-count sweeps
- MRC / SC / EGC comparisons
- fallback-policy simulation

Responsibilities:
- define the behavioral truth before RTL implementation
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
- end-to-end packet regressions (Trouper hardware)
- RTL-vs-Python comparison
- inter-project bus verification (Grouper-Trouper AHB access)
- AFE capture-path testing

Responsibilities:
- prove the implementation matches the spec
- catch packet handoff, fixed-point, and bus bugs early
- verify inter-project communication protocols

Deliverables:
- block test coverage
- integration simulation (full MPW model)
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
- floorplan / P&R (Trouper and Grouper separate runs)

Subblocks:
- macro placement (Grouper PicoRV32/SRAM, Trouper DSP SRAMs)
- area/timing/power closure for each project
- MPW-level routing for AHB-Lite bus
- 25-pad constraint management (Trouper)

Responsibilities:
- keep each project within its timing and area budgets
- coordinate inter-project signal routing with the integration team
- manage pad budget rigorously (≤26 pads for Trouper)

Deliverables:
- physical GDS for Trouper and Grouper
- timing-signed-off netlists
- MPW-level top-level routing plan

## Assignment Rule

For each workstream, assign one owner who is accountable for the block/spec closure and one reviewer who is accountable for cross-checking interfaces with adjacent workstreams.
