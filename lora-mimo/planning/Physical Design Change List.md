# Physical Design Change List

This page tracks the remaining work required before the current `rtl-test/mimo_rx_top.v` can support a meaningful full physical-design flow with SRAM macros and the intended `32 MHz` I/O plus `16 MHz` internal architecture.

---

## Current state

The current top-level RTL is not yet a true dual-rate implementation.

- `mimo_rx_top.v` is still effectively a single-clock top driven from `IQ_CLK`
- several block ports are named `clk_32m` and `clk_16m`, but are currently tied to the same net
- the existing top trial config relaxes timing to `62.5 ns`, which is not the same thing as implementing `32 MHz` I/O with `16 MHz` internal logic
- frontend SRAMs are now instantiated as `gf180mcu_fd_ip_sram__sram512x8m8wm1` macros in the top-level RTL
- CPU SRAM in `picorv32_wrap.v` is now instantiated as 4 × `gf180mcu_ocd_ip_sram__sram1024x8m8wm1`, one macro per byte lane

Because of that, a top-level PD run today would still be useful mainly as a macro-aware floorplan/sizing experiment, not yet as proof that the intended dual-rate architecture is implementable.

---

## Progress made

### Completed in this pass

- replaced the behavioral CPU SRAM array in `rtl-test/picorv32_wrap.v` with 4 explicit `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` instances
- added a `rtl-test/sram1024x8_bb.v` synthesis blackbox for the CPU SRAM macro
- aligned the frontend buffer RTL to the planned `gf180mcu_fd_ip_sram__sram512x8m8wm1` family
- updated `rtl-test/sram512x8_bb.v` to match the `fd_ip` frontend SRAM macro name
- updated `rtl-test/ol_picorv32_wrap/config.json` to include the CPU SRAM blackbox plus LEF/LIB views
- updated `rtl-test/ol_mimo_rx_top/config.json` to include both SRAM blackboxes plus LEF/LIB views
- parse-checked `picorv32_wrap` and `mimo_rx_top` successfully in the `chipathon26` container with Yosys

### Still intentionally not solved in this pass

- real `32 MHz` / `16 MHz` clock partitioning
- CDC structure between those domains
- macro placement strategy for the top-level SRAM instances
- extracted timing validation of the SRAM assumptions
- cleanup of the firmware-load/readback interface beyond preserving a PD-ready macro-backed structure

---

## Main blockers

### 1. No real `clk_16m`

- add a real `/2` clock-generation point from `IQ_CLK`
- expose the generated net clearly enough for STA and implementation tools
- stop tying all `clk_16m` ports to the raw `32 MHz` net

### 2. No real internal clock partition

- define exactly which logic remains in the `32 MHz` domain
- define exactly which logic moves to `16 MHz`
- verify that every affected instantiated block is actually wired to the intended domain

### 3. Missing CDC implementation

- add explicit crossings for every `32 MHz -> 16 MHz` interface
- add explicit crossings for every `16 MHz -> 32 MHz` interface
- do not rely on SDC-only treatment for functional clock-domain crossings

### 4. CPU SRAM integration needs refinement, not first-principles replacement

The behavioral CPU SRAM has been removed, but a few details still need architecture cleanup:

- review firmware-load readback behavior against the SPI-side protocol
- decide whether CPU SRAM remains a `32 MHz` interface with multicycle access or becomes a true `16 MHz` block
- validate that the macro-access latency model matches the intended SDC treatment

### 5. Top-level constraints are not aligned with the intended architecture

- the current top-level SDC intent and `ol_mimo_rx_top/config.json` do not reflect a real dual-rate netlist
- `SPI_SCK` should be treated according to the implemented crossing method, not simply as a normal synchronous secondary clock
- SRAM multicycle assumptions must match the actual controller implementation and extracted timing assumptions

---

## Required RTL work

### Clocking

- add a real `clk_16m` generator in the top-level RTL
- distribute `clk_32m` and `clk_16m` intentionally instead of by port naming convention
- decide whether some blocks are better kept in the `32 MHz` domain with clock-enables instead of moving them to a separate clock domain

### Domain partition

Likely `32 MHz` candidates:
- SX1257 input capture
- sigma-delta decimators
- sigma-delta remodulator
- pad-facing interface wrappers

Likely `16 MHz` candidates:
- PicoRV32 wrapper and AHB-Lite control plane, if supported by the memory/latency model
- slower DSP/control blocks that are not bitstream-rate-critical

This partition must be validated block by block rather than assumed from the architecture sketch.

### CDC

For each crossing, choose and implement one mechanism:
- synchronizer for static control
- pulse-stretch + acknowledge for event signals
- registered rate-change bridge or FIFO for sample-bearing interfaces
- no unconstrained direct combinational crossing between the two domains

### SRAM integration

- frontend buffer SRAMs: finalize wrapper details and later macro placement strategy
- CPU SRAM: review the firmware-loader behavior now that the storage is macro-backed
- keep macro interfaces stable enough that PD can proceed before the final firmware is frozen

---

## Required physical-design work

### Top config cleanup

- update `rtl-test/ol_mimo_rx_top/config.json` so the clock period and SDC match the actual top-level clocking architecture
- define macro placement strategy for frontend SRAM and CPU SRAM blocks
- re-enable signoff checks incrementally once the architecture is coherent enough for meaningful reports

### Dual-rate SDC rewrite

The final top-level SDC must:
- create the `32 MHz` source clock on `IQ_CLK`
- create the generated `16 MHz` clock on the actual divider output
- constrain CDC paths according to the implemented bridges
- constrain SRAM multicycle behavior according to the chosen controller timing model
- constrain pad timing for the `32 MHz` input/output-facing logic separately from the `16 MHz` internal logic

### Pre-PD validation

Before launching a full top PD run:
- lint the netlist for accidental single-clock wiring
- run RTL simulation with the real dual-rate clocking and CDC logic
- run top-level trial STA and verify that the clock graph matches intent
- confirm that SRAM macro names in RTL match the physical collateral that PD will use

---

## Recommended execution order

1. Add the real `clk_16m` generation point.
2. Partition the top into explicit `32 MHz` and `16 MHz` regions.
3. Implement CDC logic for all inter-domain paths.
4. Rewrite the top-level SDC around the actual generated clock net and real crossings.
5. Update `ol_mimo_rx_top/config.json` further if the clocking split changes macro/timing assumptions.
6. Run a fresh top-level trial PD flow.
7. Only after that treat full top-level PD results as architecture evidence.

---

## Bottom line

The netlist is now materially closer to a meaningful macro-aware PD run because both the frontend SRAMs and CPU SRAM are represented as hard macros in the RTL and configs.

But the architecture question is still open. Until the top gets a real `32 MHz` / `16 MHz` split with explicit CDC and matching SDC, a full top-level PD run would still answer only a limited question: whether the current single-clock approximation with real SRAM macros can be placed and routed.
