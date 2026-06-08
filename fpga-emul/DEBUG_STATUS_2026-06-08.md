# FPGA Emulation Bring-up Status

Date: 2026-06-08

## Committed changes

- Fixed the Arty A7 Ethernet MII pin mapping in `vivado/arty_dsp_emul.xdc` to match the known-good `fpga-eth` project.
- Changed the board clock constraint to `create_clock -add` so it no longer overrides the clock-wizard constraint.
- Removed the generic PMOD input/output delay constraints that were producing implementation critical warnings.
- Updated `vivado/create_project.tcl` so `proc_sys_reset` is held inactive by a constant, matching the working `fpga-eth` reset strategy.
- Added XSDB-based board programming and firmware-loading scripts:
  - `vivado/load_fw.tcl`
  - `vivado/program_fpga.tcl`
  - `vivado/program_fw.tcl`
  - `vivado/gen_xsa.tcl`
- Added minimal firmware bring-up files under `sw/`:
  - `crt0.S`
  - `lscript.ld`
  - `build_fw.tcl`
  - `test_fw.c`
  - `uart_smoke.c`
  - `uart_smoke.S`
- Added a standalone direct-pin UART path test under `uart_pin_test/`.

## Verified results

- `fpga-emul` rebuilds cleanly with `0 Critical Warnings` and positive routed timing after the XDC cleanup.
- The known-good `fpga-eth` project runs on the board over JTAG/XSDB.
- After unplug/replug, both FTDI interfaces enumerate:
  - `if00 -> /dev/ttyUSB0`
  - `if01 -> /dev/ttyUSB1`
- The direct hardware-only UART pin test drives `A9` successfully and is visible on `/dev/ttyUSB1`.

## Current blocker

The failure is no longer the host serial path or the top-level FPGA pin routing.

Observed behavior:

- Direct-drive test on `A9` reaches `/dev/ttyUSB1`.
- In `fpga-emul`, the routed netlist shows `UART_0_txd` is driven by the UARTLite TX register and placed on `A9`.
- Despite that, both normal firmware execution and direct XSDB writes to the UARTLite TX register produce `0` bytes on `/dev/ttyUSB1`.
- A temporary local-only experiment mirrored `UART_0_txd` to a user LED; the LED stayed solid during UART register pokes, indicating the UARTLite TX net did not visibly toggle.

Conclusion:

- The remaining issue is inside the UARTLite transmit path or its effective activity, not the Linux TTY selection and not the board's `A9 -> FTDI -> /dev/ttyUSB1` path.

## Recommended next step

Add internal observability on the UARTLite path:

- Probe UARTLite TX, TX FIFO write, reset, and clock with an ILA, or
- Expose a few internal UARTLite status signals to spare pins/LEDs in a reproducible source-level way.

The last temporary LED-mirror experiment was done only in generated Vivado output and is intentionally not committed.
