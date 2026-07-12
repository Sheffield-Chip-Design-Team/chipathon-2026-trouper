# SPI Slave CDC and 10 MHz Timing Plan

## Purpose

Make the host SPI register interface reliable with a Raspberry Pi master at
10 MHz without relying on an undocumented chip-select hold time, and bring the
SPI paths into static-timing signoff.

The current serial/frame logic runs directly from asynchronous `SPI_SCK`, while
register writes and read side effects cross into the 32 MHz `IQ_CLK` domain.
This is the right high-level architecture for the available clock ratio, but
the current pulse crossing can lose the final write when `HOST_CS` rises soon
after the last clock edge. The production SDC also false-paths `SPI_SCK`, so it
does not prove the advertised 10 MHz interface timing.

## Clock architecture

- `SPI_SCK`: external, asynchronous, Mode 0 serial-engine clock, maximum
  10 MHz (100 ns period).
- `IQ_CLK`: the only physical local clock, 32 MHz (31.25 ns period).
- `ce_16m`: a clock enable that updates selected control-plane registers every
  other `IQ_CLK` edge. It is not a separate clock domain.

Do not replace the SCK-clocked serial engine with 32 MHz oversampling. A 10 MHz
SCK half-period is 50 ns, only 1.6 `IQ_CLK` cycles, which is insufficient for a
normal two-flop synchronizer plus reliable detection of every SCK edge.

## Reference architectures reviewed

### OpenTitan SPI Device

OpenTitan keeps serial activity in the SPI clock domain and uses asynchronous
RX/TX FIFOs between SPI and the main clock. This is the robust general solution
for arbitrary streams. Trouper's decoded register events occur at most once per
byte (800 ns at 10 MHz), so a full FIFO is unnecessary.

Reference:
<https://opentitan.org/book/hw/ip/spi_device/data/spi_device.html>

### AMD SPI slave controllers

AMD documents an alternative architecture that synchronizes SPI inputs into a
faster reference-clock domain. That approach is unsuitable at Trouper's
32 MHz-to-10 MHz ratio because there is too little sampling margin.

Reference:
<https://docs.amd.com/r/en-US/am011-versal-acap-trm/Data-Transfer>

### vSPI two-clock slave

The vSPI project demonstrates toggle-based communication in a two-clock SPI
design. It is useful as a conceptual reference, but its older FPGA-oriented RTL
and loosely coordinated crossings should not be copied directly.

Reference:
<https://github.com/mjlyons/vSPI/blob/master/src/spi_base/spiifc_twoclock.v>

### Sheffield Super-Simple-SPI-CPU

This is an internally clocked SPI master. It is useful for Mode 0 sequencing
and verification examples, but it does not address an asynchronous slave CDC.

Reference:
<https://github.com/Sheffield-Chip-Design-Team/super-simple-spi-cpu/blob/main/src/spi_read_byte.v>

## RTL redesign

### 1. Separate frame reset from event storage

`HOST_CS` may reset only transaction-local state:

- `spi_shreg`
- `spi_bit_cnt`
- `have_cmd`
- `fp_rw`
- `cur_addr`
- MISO frame/shift state

It must not clear a completed but unconsumed register event or its mailbox.
The following state must reset only from chip reset:

- `spi_we_toggle`
- `spi_wr_addr_lat`
- `spi_wdata_lat`
- `spi_re_toggle`
- `spi_re_addr_lat`

### 2. Use persistent toggle events

On completion of each write data byte in the `SPI_SCK` domain:

1. Latch address and data into the write mailbox.
2. Invert `spi_we_toggle`.

For each read-data-byte side effect:

1. Latch the side-effect address.
2. Invert `spi_re_toggle`.

Synchronize each toggle through at least two `IQ_CLK` flops. XOR consecutive
synchronized values to create exactly one destination-domain event. Unlike a
pulse, the changed toggle persists after `HOST_CS` rises and until the 32 MHz
domain observes it.

At 10 MHz, consecutive byte events are separated by 800 ns, approximately
25.6 `IQ_CLK` cycles. The destination therefore has ample time to observe each
toggle before the next event.

### 3. Treat address/data as a bundled-data mailbox

The mailbox is written before the event reaches the final synchronizer stage
and remains stable until at least the following byte completion. Capture
mailbox address/data when the synchronized toggle change is detected.

CDC/STA review must explicitly cover this bundled-data assumption; do not
blanket-false-path the mailbox without a settling/max-delay constraint.

### 4. Preserve the 16 MHz-effective write contract

The toggle edge detector naturally produces a one-`IQ_CLK` pulse. Extend
`reg_we` to two 32 MHz cycles so it necessarily overlaps a `ce_16m` edge. Keep
address and data stable throughout the extended strobe. The top-level CE latch
and `reg_bank` then retain their existing exactly-once write behavior.

Use a one-cycle `reg_re` only for consumers that update on every `IQ_CLK` edge.
Stretch it similarly if any destination is `ce_16m` gated.

### 5. Review reset-domain behavior

Both toggle endpoints must start at the same value. Verify asynchronous reset
assertion and deassertion recovery/removal for the SCK- and `IQ_CLK`-domain
flops. If the implementation flow requires it, use asynchronous assertion and
synchronous deassertion separately in each clock domain.

## Static-timing constraints

The production SDC must describe the external SPI interface instead of globally
false-pathing `SPI_SCK`:

1. Add `create_clock -name SPI_SCK -period 100.0 [get_ports SPI_SCK]`.
2. Add realistic board/master input delays for `SPI_MOSI` relative to the
   rising SCK edge.
3. Add `SPI_MISO` output delay requirements for the Raspberry Pi's following
   rising-edge sample. Mode 0 changes MISO on falling edges.
4. Declare `SPI_SCK` and `IQ_CLK` asynchronous.
5. False-path only the intentional CDC into the first toggle synchronizer
   stage, not every path launched by `SPI_SCK`.
6. Constrain the bundled mailbox so address/data settles before the synchronized
   event is consumed.
7. Time the SCK-domain rising-edge state paths normally.
8. Prove the command-to-first-read-bit path: the address is completed on the
   eighth rising edge, `reg_bank` combinational peek data settles, and MISO loads
   on the following falling edge. The internal budget is at most 50 ns before
   pad, board, and host setup margins.
9. Run setup and hold analysis at all signoff PVT corners and report
   unconstrained endpoints.

Exact input/output delay numbers must come from the chosen Raspberry Pi model,
PCB flight-time estimate, and GF180 pad timing. Do not substitute the existing
`IQ_CLK`-relative `SPI_MOSI` constraint.

## Verification plan

### Directed RTL tests

- Mode 0 single-register write and read at exactly 10 MHz.
- Raise CS at the earliest legal time after the final falling edge; confirm the
  write is committed exactly once.
- Back-to-back write transactions with minimum CS-high time.
- Continuous burst writes with no inter-byte gap.
- Burst reads, including address wrap and the `0x76` no-increment exception.
- First transaction after reset without a warm-up transaction.
- Reset asserted during command and data phases.
- Read side effects occur once per returned byte.
- W1P registers see one write, never two, despite the two-cycle `reg_we`.

### Randomized CDC tests

- Randomize the phase between `SPI_SCK` and `IQ_CLK` over the full relative
  phase range.
- Randomize CS setup, hold, and inter-transaction spacing within the supported
  protocol limits.
- Sweep SCK below and through 10 MHz.
- Use a scoreboard to require a one-to-one mapping between completed SPI data
  bytes and destination `reg_we`/`reg_re` events.

### Assertions

- Every completed write byte eventually produces exactly one `reg_we`.
- No `reg_we` occurs without a completed write byte.
- Mailbox address/data remains stable from toggle generation through
  destination capture.
- No two source events occur before the destination can distinguish them under
  the supported 10 MHz/32 MHz clocks.
- CS deassertion clears frame state without changing an outstanding toggle or
  mailbox.

### Gate-level/signoff checks

- Post-synthesis simulation of the minimum-CS-hold final write.
- Post-route timing report for SCK rising-edge, falling-edge MISO, and mailbox
  CDC paths.
- CDC and reset-domain-crossing reports reviewed with intentional crossings
  documented.
- Bench confirmation at 10 MHz with a Raspberry Pi and oscilloscope/logic
  analyzer, including measured CS timing and MISO setup margin.

## Acceptance criteria

- No host-side CS hold extension is required beyond normal Raspberry Pi SPI
  behavior.
- Every valid write at up to 10 MHz commits exactly once for all tested clock
  phases.
- Every read returns the addressed byte with valid first-bit timing.
- No unintended CDC/RDC warnings remain.
- SPI paths are constrained, have non-negative setup/hold slack at the agreed
  signoff corners, and are not hidden by a blanket false path.
- Existing register-bank W1P, burst, reset, and PSRAM debug-port tests pass.

## Implementation order

1. Add failing tests for immediate CS deassertion and randomized clock phase.
2. Refactor frame state and persistent mailbox/toggle state.
3. Add toggle synchronizers and two-cycle `reg_we` extension.
4. Apply the same discipline to read-side-effect events.
5. Run RTL regression and CDC/RDC checks.
6. Replace the blanket SCK false path with explicit SPI constraints.
7. Run PnR/signoff STA and inspect the command-to-MISO half-cycle path.
8. Verify on Raspberry Pi hardware at 10 MHz.

