# AFE Characterisation Board

Prototype PCB for early RF / analog-front-end bring-up before the full ASIC control plane is ready.

---

## Purpose

Provide a simple 4-channel receive front end that can be interfaced directly to the Arty A100 FPGA for:

- SX1257 bring-up
- shared-clock / coherence validation across 4 RX channels
- baseband capture for Schmidl-Cox and FFT bring-up
- analog front-end characterisation before ASIC integration

This board is a lab and architecture-risk-reduction platform, not the final product PCB.

---

## Planned Contents

- 4 × SX1257
- 1 × TCXO fanout / buffer device
  - exact part number TBD
  - intended to distribute one common reference to all 4 SX1257 devices via **XTB** (pin 8); XTA (pin 6) left open per datasheet Section 3.3.1
  - peak-peak amplitude must not exceed 1.8 V at XTB
- 1 × SMA or header for **external reference clock input**
  - allows substitution of the on-board TCXO with a lab signal generator or external reference for controlled characterisation measurements
  - should include a bypass/select option (e.g. 0 Ω resistor or jumper) to switch between on-board TCXO and external SMA reference feeding the same XTB fanout network
- SMA connectors for RF inputs
- headers for baseband / digital interfacing to the Arty A100 FPGA
- power, reset, and SPI access needed for basic SX1257 configuration

### SX1257 Clock Architecture Notes

The SX1257 supports three clock input modes:

| Mode | Pins used | Notes |
|---|---|---|
| Internal crystal | XTA + XTB | 36 MHz crystal across both pins; each device has its own independent clock — **not suitable for multi-channel coherence** |
| External TCXO / sinewave | XTB only (XTA open) | Shared reference distributed to all 4 devices; **this is the intended mode for this board** |
| Digital clock input | CLK_IN (pin 11) | Separate 36 MHz digital clock path; independent of XTA/XTB |

The shared-TCXO-via-XTB path is the correct choice for validating cross-channel coherence. Per-device crystals would introduce independent CFOs on each channel and defeat the purpose of this board.

---

## Why This Board Exists

The main goal is to decouple AFE characterisation from the rest of the ASIC schedule.

This lets the team test:

- whether 4 SX1257 channels can be clocked coherently from a shared reference
- gain / phase consistency across channels
- packet-to-packet CFO / phase stability
- real Schmidl-Cox trigger behavior on live hardware
- FFT capture / estimation behavior with realistic front-end impairments

without waiting for the full ASIC control plane, SPI path, or combiner integration to be complete.

---

## Key Interface Questions

Before schematic freeze, define at least:

- FPGA header pinout
  - signal naming
  - lane ordering
  - bank allocation on Arty A100
- logic voltage standard
  - ensure SX1257 digital I/O levels and FPGA bank standards are compatible
- baseband format
  - exact exported signal type
  - sample clocking relationship
  - whether the FPGA sees parallel sample buses, bitstreams, or another intermediate format
- reset / enable strategy
  - per-device versus shared reset
- SPI programming path
  - how the FPGA or host configures all 4 SX1257s deterministically

---

## Bring-Up Measurements

This board should be used to gather at least the following:

- reference-clock quality at the TCXO output and at each SX1257 clock input
- channel-to-channel phase offset and stability
- channel-to-channel gain spread
- noise floor and spur profile per channel
- packet detect repeatability with shared-clock 4-channel capture
- timing relationship between channels at the FPGA header
- inter-channel CFO spread: measure CFO independently per channel on the same received packet and record the variation across channels, across packets, and across temperature/power-cycle conditions
- **DC offset vs LNA gain, per channel:** mean I and mean Q at the decimator output (int8 counts, terminated antenna input) across the full SX1257 LNA gain range, plus the DC step size across each adjacent gain transition. Decides `dc_removal` output-clamp change R2 in `planning/dsp-block-review-changes-2026-07.md`: the DCR subtract wraps (full sign flip) whenever signal peak + |DC| > 127, a cliff at |DC| ≈ 38 counts with the −3 dBFS AGC contract. **Pass: |DC| < 20 counts on both I and Q at max gain on all 4 channels** (clamp unnecessary, TRPR-DCR-007 closed by measured margin); |DC| ≥ 20 counts anywhere → implement R2. Record alongside the noise-floor measurement (same captures usable: σ and mean of the same terminated-input record).

Recommended early tests:

1. Single-channel RX bring-up on one SX1257.
2. Shared-clock validation across all 4 channels.
3. Same-signal injection into multiple channels and measure relative phase / amplitude.
4. Capture LoRa preambles into the FPGA and validate `sc_lock`, `timing_ref`, and FFT acquisition.
5. **Cross-channel CFO consistency check.** Receive the same LoRa transmission on all 4 channels simultaneously and measure the CFO estimate on each channel independently. The non-FFT combining architecture assumes a single common CFO across all branches — if inter-channel CFO spread is significant (e.g. due to per-SX1257 LO pulling or reference distribution skew), the assumption that common CFO cancels in the weight ratios breaks down and per-branch CFO correction may be needed. Record CFO spread across channels over multiple packets and temperature/power-cycle conditions.

---

## Design Considerations

- Keep the TCXO fanout path symmetric and low-jitter.
- Preserve clean grounding and supply partitioning for RF, clocking, and digital sections.
- Add enough test access to debug clock, SPI, reset, and at least one representative baseband path.
- If possible, make the baseband header mapping simple and probe-friendly rather than pin-count-optimal.

---

## PSRAM Validation Footprint (ACTION REQUIRED)

The next board revision must add an **APS6404L-3SQR** (AP Memory, 64 Mbit QPI PSRAM) footprint to validate the ASIC PSRAM buffer controller before tapeout.

**Package:** SOP-8, 1.27 mm pitch  
**Pins:** VDD, VSS, CE#, SCK, SIO[0–3]

**PCB requirements:**
- 1 µF + 100 nF decoupling on VDD within 1 mm of device
- SIO[0–3] and SCK traces short and matched-length — 32 MHz signal integrity matters
- SIO[0–3] connect to FPGA pins that will also map to the ASIC JTAG pad positions (TCK/TMS/TDI/TDO) — route to a header for flexibility
- CE# routed via the existing SPI CS mux header or independently for initial bring-up

**What to validate:**
- QPI init sequence, write timing at 125/250/500 kHz, read latency at 32 MHz
- Interleaved read+write at 500 kHz (10-cycle margin — must be confirmed on hardware)
- Signal integrity of SIO[0–3] at 32 MHz on the actual PCB

The PSRAM RTL will not be finalised for tapeout without this hardware validation. See memory note `psram-validation-plan`.

---

## Relationship To ASIC Work

This board supports:

- Schmidl-Cox threshold / hit-count tuning on real hardware
- validation of the 8-symbol FFT acquisition assumptions
- assessment of whether next-packet versus same-packet weight application is likely to matter in practice
- early confidence in multi-channel coherence before committing further RTL / architecture effort
- **PSRAM buffer controller validation** — critical path item before tapeout

It should be treated as an input to the ASIC architecture, not only as a lab tool.
