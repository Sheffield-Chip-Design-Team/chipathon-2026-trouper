# SX1257 Clock and Reset Synchronization

This note records what can and cannot be assumed when operating four SX1257
AFEs from one reference clock. It is based on:

- `resources/DS_SX1257_V1.2.pdf`, especially §§3.3.1, 3.5.2, 3.7.4 and 6.2
- `resources/DS_5PB12xx_ClockBuffer.pdf`

## Conclusion

A common reset is useful for repeatable initialization, but the SX1257
datasheet does **not** specify that simultaneous reset aligns the digital
sampling-clock phase, internal divider state, ADC latency, or RF PLL phase
between devices.

The common TCXO distributed to all four XTB inputs is what establishes common
frequency and closely aligned reference-clock edges. Reset must not be treated
as a substitute for that clock architecture or as a documented phase-alignment
mechanism.

## Datasheet-supported behaviour

### Reference and data clocks

- The reference oscillator supplies the TX/RX frequency synthesizers and the
  digital-processing clock.
- With an external TCXO or clock source, drive XTB (pin 8) and leave XTA
  (pin 6) open. The XTB input must not exceed 1.8 V peak-to-peak.
- RX `I_OUT` and `Q_OUT` are timed from the reference sampling clock.
- `CLK_IN` (pin 11) is the external clock selection for the TX DAC. It is not
  an RX-ADC synchronization input.
- `CLK_OUT` activity may be used to determine that the oscillator and device
  are ready.

### Reset

For manual reset:

1. Drive RESET (pin 9) high for more than 100 us.
2. Release the pin to high impedance.
3. Wait at least 5 ms before accessing the device.

The datasheet does not relate RESET assertion or release to an XTB clock edge,
and it provides no inter-device phase or latency guarantee. During power-on
reset, RESET must be left floating. A shared reset driver therefore needs a
high-impedance state; an open-drain or explicitly tri-stated implementation is
appropriate.

The datasheet also warns that driving RESET high can add approximately 10 mA
of VDD current per device. Four devices may therefore add approximately 40 mA
while reset is asserted.

## Board clock distribution

The intended topology is:

```text
TCXO -> 5PB1204 fanout
        +-> SX1257_1 XTB
        +-> SX1257_2 XTB
        +-> SX1257_3 XTB
        +-> SX1257_4 XTB
```

The 5PB12xx datasheet specifies 20 ps typical and 50 ps maximum
output-to-output skew with equal loading. At 32 MHz, 50 ps is 0.16% of a
31.25 ns period. This requires identical terminations, loads and trace
geometries. The datasheet notes that changing one nominal 33-ohm series
termination to 30 ohms can add at least 15 ps of skew.

This specification applies to fanout-buffer output edges. It does not bound
undocumented phase or latency differences inside separate SX1257 devices.

## FPGA-emulation implications

The FPGA currently uses one SX1257 `CLK_OUT` as `dsp_clk` and samples all four
AFEs in that domain. This is the architecture under test, not a fact proven by
the shared TCXO.

The following distinctions must be maintained:

| Property | Expected source | Status |
|---|---|---|
| Common frequency / no long-term clock drift | Shared TCXO into all XTB pins | Required and datasheet-supported |
| Small PCB reference-edge skew | 5PB1204 plus matched routes and loads | Specified at fanout outputs |
| Deterministic SX1257 digital clock phase | Not specified | Must be measured |
| Equal RX I/Q pipeline latency after reset | Not specified | Must be measured |
| Equal RF LO phase after reset or relock | Not specified | Must not be assumed |

Simultaneously resetting all four devices remains worthwhile because it reduces
startup variation and makes the experiment repeatable. A successful result,
however, is an empirical property of the tested devices and operating
conditions rather than a Semtech datasheet guarantee.

## Required validation

Implement the clock-sync measurement harness described in `TODO.md`, then:

1. Drive all four RESET pins from one tri-state-capable signal.
2. Assert RESET high for more than 100 us, release to high impedance, and wait
   at least 5 ms.
3. Program all four devices identically and enable RX using a controlled SPI
   sequence.
4. Measure all four `CLK_OUT` signals against the selected FPGA `dsp_clk`.
5. Inject one common CW signal through a four-way splitter and capture all four
   I/Q streams concurrently.
6. Measure sample-index alignment, relative phase and relative latency.
7. Repeat across manual resets, full power cycles, RX disable/enable cycles,
   PLL relocks, temperature and multiple boards/devices.

Acceptance criteria must be defined from the FPGA input timing margin and the
DSP algorithm's allowable sample/phase error. Until this test passes, treat the
four I/Q interfaces as source-related but not proven cycle-aligned.

