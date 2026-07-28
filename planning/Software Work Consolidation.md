# Software Work Consolidation

This note consolidates the software-facing work scattered across:

- [Work Allocation](Work%20Allocation.md)
- [Gantt](Gantt.md)
- [Register Map](Register%20Map.md)
- [System Architecture](System%20Architecture.md)
- [Test Plan](Test%20Plan.md)
- [blocks/PicoRV32 Integration](blocks/PicoRV32%20Integration.md)
- [MIMO Algorithms](MIMO%20Algorithms.md)

The goal is to turn "software" into an actionable backlog with clear priorities.

## Scope

For this project, "software work" splits into four lanes:

1. ASIC firmware on PicoRV32
2. RPi host control software
3. FPGA/emulation software and test harnesses
4. Python simulation, verification, and analysis tooling

These lanes are coupled by the current architecture:

- the authoritative control interface is the 8-bit ASIC SPI register map in [Register Map](Register%20Map.md)
- the baseline RX path must still work with `CPU_RESET=1`
- firmware is an enhancement path for AGC, diagnostics, startup, and software weight override
- host-side software is required even if the CPU stays in reset, because SPI configuration, boot, and bring-up still happen from the RPi

---

## Priority Split

### Tapeout-critical software

This work is required for bring-up, verification, or proving the architecture:

- RPi SPI register access library and bring-up tooling
- SX1257 startup/config sequencing
- firmware load / readback flow over SPI
- minimal PicoRV32 firmware for IRQ handling, diagnostics, and optional weight override
- FPGA emulation control/data path for live and injected tests
- Python golden-model and RTL-comparison tooling
- register-level and packet-level verification scripts

### Important but not first-wave

- AGC policy tuning and gain-state heuristics
- cross-packet EMA smoothing and branch masking policy
- ChirpStack-facing integration and demo software
- `NT=2` ALMMSE / advanced algorithm experiments
- richer post-processing notebooks and dashboarding

### Optional / stretch

- autonomous runtime adaptation between `SC`, `EGC`, `MRC`, and bypass
- `NT=2` live payload separation path
- SIC-style experiments
- polished GUI/operator tooling

---

## Workstreams

## 1. RPi Host Control Software

This is the first software dependency for real hardware bring-up.

### Required outputs

- SPI transport for 8-bit register read/write against the ASIC SPI slave
- scripted bring-up sequence:
  - read `CHIP_ID`
  - configure core RX registers
  - program SX1257 registers through `SX_TARGET`/`SX_ADDR`/`SX_DATA`/`SX_CTRL`
  - load PicoRV32 firmware when used
  - release `CPU_RESET`
- register dump / diff tool for debug
- SRAM firmware readback tool
- IRQ polling or GPIO-driven interrupt handling

### Concrete tasks

- Define a single software source of truth for register names and addresses.
- Implement host-side helpers for:
  - single-byte R/W
  - multi-byte big-endian field reads
  - bitfield update helpers
- Add boot scripts for two operating modes:
  - `cpu-held-reset` RX-only baseline
  - `cpu-enabled` firmware-managed mode
- Add SX1257 init scripts for:
  - power-up reset assumptions
  - RX gain programming
  - standby/RX transitions
  - optional TX prep/restore support
- Add bring-up diagnostics for:
  - register-map sanity
  - IRQ source visibility
  - `TRAINING_STATUS`, `PACKET_STATUS`, `ENERGY_*`, `Z*`, `W_*`

### Definition of done

- Can cold-boot the board into RX-only mode from the RPi.
- Can load firmware, read it back, and release the PicoRV32 cleanly.
- Can configure all four SX1257s from one repeatable script.

---

## 2. PicoRV32 Firmware

Firmware is not allowed to be the only path for baseline RX, but it is still a major workstream.

### Minimum viable firmware

- startup / register init
- IRQ service for `corr_lock`, `training_done`, and TX events
- software diagnostics writeback (`COND_NUM`, `SNR_0`, `NULL_QUALITY`)
- optional software weight override:
  - read `Z_j`
  - apply calibration
  - compute `W`
  - write shadow weights
  - pulse `W_COMMIT`

### Follow-on firmware

- AGC loop using `ENERGY_*` snapshots (gain is applied externally — no on-chip `RX_GAIN_*` register)
- EMA smoothing of channel estimates
- branch masking / branch health policy
- TX preparation / restore sequencing for TDD cases
- firmware-controlled fallback policy when hardware weights are late or unreliable

### Concrete tasks

- Create a proper firmware memory map / linker layout for `BANK0`-`BANK2` only.
- Build a small runtime:
  - reset/vector setup
  - interrupt dispatch
  - register access helpers
  - fixed-point complex math helpers
- Implement a reference ISR path for `IRQ_TRAINING_DONE`.
- Implement a compile-time switch between:
  - diagnostics-only firmware
  - software-weight firmware
  - AGC-enabled firmware
- Emit a map file and image artifact suitable for SPI loading.

### Definition of done

- Firmware boots from SPI-loaded image.
- IRQ handling works without corrupting the reserved borrow bank.
- Weight override fits the SF6 latency budget when enabled.

---

## 3. FPGA / Emulation Software

This is the main bridge between Python-only confidence and hardware confidence.

Current evidence already exists in [fpga-emul/sw/main.c](../fpga-emul/sw/main.c:1) and related Vivado collateral, but it needs to be treated as a structured workstream rather than ad hoc firmware.

### Required outputs

- stable FPGA control firmware for the three existing modes:
  - `DECIM_ETH`
  - `FULL_DSP`
  - `INJECT`
- host-side UDP tools for:
  - sample injection
  - combined-output capture
  - status-packet decode
- reproducible FPGA programming / run instructions

### Concrete tasks

- Freeze and document the FPGA UDP protocol currently embedded in `main.c`.
- Add host utilities for:
  - inject-file playback
  - live sample capture to disk
  - status decode into human-readable logs
- Add regression scripts for:
  - injected-vector DSP correctness
  - status register transitions during packet flow
  - overflow / underrun / FIFO error handling
- Separate "board bring-up firmware" from "DSP emulation firmware" so test scope is explicit.

### Definition of done

- A developer can reproduce injected-vector and live-capture tests from one README.
- FPGA mode control and status decode are scriptable, not manual.

---

## 4. Python Simulation And Verification Tooling

This is already the strongest software asset in the repo. The missing piece is turning it into a disciplined acceptance harness for RTL and firmware.

### Existing base

- system models in `sim/models/`
- sweeps in `sim/sims/`
- targeted tests in `sim/tests/`
- verification references in [sim/README.md](../sim/README.md:1) and [sim/VERIFICATION_REPORT.md](../sim/VERIFICATION_REPORT.md:1)

### Required outputs

- canonical packet-level golden reference for the non-FFT architecture
- reproducible block-level comparisons against RTL
- algorithm study harness for `SC`, `EGC`, `MRC`, and `NT=2` candidates
- captured-data replay tooling for SX1257 and FPGA data

### Concrete tasks

- Consolidate the current simulation entry points into a documented regression set.
- Mark legacy FFT-path tests clearly as historical/reference-only.
- Add direct mappings from Python outputs to register-visible RTL quantities:
  - `ENERGY_*`
  - `SC_STAT`
  - `Z_j`
  - `W_*`
  - packet timing / lock events
- Add regression artifacts for fixed-point acceptance:
  - pass/fail thresholds
  - known-good plots or numeric summaries
- Add firmware-facing helpers that generate test vectors and expected register values for IRQ-driven flows.

### Definition of done

- For each critical block, there is one documented command that produces a reference result and one documented command that checks RTL against it.

---

## 5. Register-Map And Tooling Unification

The register map is now detailed enough that hand-maintained constants across Python, C firmware, FPGA firmware, and host tools will become a failure source.

### Required outputs

- one machine-readable register definition source
- generated constants for:
  - host Python
  - PicoRV32 firmware C headers
  - FPGA emulation firmware C headers
- generated field masks/shifts where possible

### Concrete tasks

- Choose a source format such as YAML/JSON/TOML.
- Generate:
  - `asic_regs.h`
  - `asic_regs.py`
  - optional markdown table fragments
- Validate generated output against [Register Map](Register%20Map.md).

### Definition of done

- No new software component hardcodes register addresses manually.

---

## 6. Verification Automation

The current [Test Plan](Test%20Plan.md) is strong on intent but still needs software scaffolding to become executable.

### Required outputs

- runnable regressions for block and integration checks
- pass/fail summaries suitable for review
- captured-data and FPGA-in-the-loop automation

### Concrete tasks

- Convert the software-relevant parts of the test plan into scripts:
  - SPI slave register tests
  - firmware load/readback tests
  - PicoRV32 weight-override tests
  - FPGA injection regressions
  - SX1257 AFE characterization data processing
- Standardize result locations and report formats.
- Add a short "known-good sequence" for pre-silicon and post-silicon testing.

### Definition of done

- The team can answer "what software-backed evidence do we have for this block?" without manual notebook archaeology.

---

## Recommended Execution Order

1. Host SPI/register tooling
2. Register-map code generation
3. Minimal PicoRV32 firmware boot/load/readback
4. FPGA host tools and emulation protocol cleanup
5. Python-to-RTL regression consolidation
6. AGC and firmware weight override
7. ChirpStack/demo integration

Reason:

- host tooling is required for both silicon bring-up and firmware boot
- register-map unification removes duplicated constants before codebases diverge further
- minimal firmware should be proven before adding algorithmic policy
- FPGA tooling and Python regressions are the fastest path to de-risking the control plane

---

## Owner Split

If the team wants clean ownership boundaries, the software work can be assigned as:

- Embedded/control:
  - PicoRV32 firmware
  - register headers
  - IRQ / AGC / weight override logic
- Host/bring-up:
  - RPi SPI tools
  - SX1257 startup scripts
  - firmware loader
  - post-silicon debug scripts
- Verification/tooling:
  - Python regressions
  - FPGA host harness
  - data processing and report generation

One person can own more than one lane, but the interfaces should stay explicit.

---

## Immediate Next Actions

The smallest useful software plan from here is:

1. Define a generated register-description source and emit C/Python headers.
2. Build the RPi-side SPI/register utility layer around that generated source.
3. Stand up a minimal PicoRV32 firmware image that only proves boot, IRQ entry, and diagnostics.
4. Package the FPGA emulation host tools so injected-vector regressions are one command.
5. Convert the software-relevant parts of the test plan into runnable scripts with fixed outputs.

That gives the team a coherent software backbone before deeper AGC and algorithm work starts.
