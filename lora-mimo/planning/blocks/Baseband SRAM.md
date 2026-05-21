# Baseband SRAM (544 KB)

Memory block. See [System Architecture](../System%20Diagram.md) for context.

**Owner:** TBD
**Status:** Not started

> **Non-FFT path note:** This block (544 KB FFT staging + sample capture SRAM) is **not used** in the non-FFT streaming frontend architecture. The non-FFT path replaces it with a 1 kB Frontend Buffer SRAM. This document is retained as a reference for the FFT path only. See [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) for the non-FFT replacement.

---

## Function

544 KB single-port SRAM block on GF180MCU, shared between the FFT engine and PicoRV32 firmware via a priority arbiter. Two logical regions with non-overlapping address ranges.

---

## Memory map

| Region | Address range | Size | Owner | Contents |
| --- | --- | --- | --- | --- |
| FFT staging buffer | `0x00000`–`0x3FFFF` | 256 KB reserved | FFT engine | int16 complex working buffer; live SF12 RCTSL uses 128 KB, optional 2× padded diagnostic mode uses the full 256 KB |
| Sample capture | `0x40000`–`0x87FFF` | 288 KB | Capture controller / host | Raw int8 I+Q from decimators; circular guarded preamble window and FFT input source |

Total: 0x88000 = 557,056 bytes = 544 KB.

The 288 KB capture region holds exactly `9M` SF12 samples across all four antennas:

```
9 * 4096 samples * 4 antennas * 2 bytes/int8-complex = 294,912 bytes = 288 KB
```

This implements the timing-handoff guard:

```
0.5M pre-guard + 8M preamble + 0.5M post-guard
```

---

## Interface (arbitrated)

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `addr` | in | 20 | Byte address (0x00000–0x87FFF) |
| `wdata` | in | 32 | Write data (32-bit word) |
| `rdata` | out | 32 | Read data |
| `we` | in | 1 | Write enable |
| `req` | in | 2 | Request from [0]=FFT, [1]=PicoRV32 |
| `grant` | out | 2 | Grant to each requester |
| `clk` | in | — | 16 MHz |
| `rst_n` | in | — | — |

Word-addressed access: byte address >> 2 = word address. Byte enables optional (add if needed for partial writes).

---

## Arbiter

Simple fixed-priority arbiter: FFT engine has priority over PicoRV32 during READ/COMPUTE/PEAK phases. PicoRV32 is stalled (wait-state on AHB-Lite) until granted.

```
if req[0]:   grant[0] = 1, grant[1] = 0   // FFT wins
else:        grant[0] = 0, grant[1] = 1   // PicoRV32 wins
```

**Capture/FFT region separation.** FFT staging buffer (`0x00000`–`0x3FFFF`) and capture region (`0x40000`–`0x87FFF`) are distinct address ranges. The FFT reads from capture and writes to staging buffer — no address conflict. Only the lower 128 KB of staging is required for the live unpadded SF12 RCTSL path; the upper 128 KB is reserved for optional 2× padded diagnostics/refinement.

**Capture handoff.** The capture controller continuously writes decimator output into the capture region as a circular buffer. Schmidl-Cox provides `timing_ref`, the estimated preamble-start sample index in `iq_valid` units. The controller then freezes a guarded window only after all required samples are present:

```
capture_start = timing_ref - M/2
capture_len   = 9*M samples per antenna
fft_start     = timing_ref
```

The live FFT trigger is generated when the 8-symbol RCTSL window from `timing_ref` through `timing_ref + 8M - 1` is resident, not directly by `sc_lock` and not after waiting for diagnostic post-guard. `fft_active` prevents the protected live window from being overwritten until the FFT has copied or consumed the needed samples.

The capture/FFT path must not stall the live decimator-to-combiner-to-remod stream. If capture storage is busy or a second packet would overwrite a protected window, set `CAPTURE_OVERFLOW` or `capture_busy`; do not backpressure `iq_valid`.

`timing_ref` and capture-window arithmetic use the free-running `iq_valid` sample counter modulo 2³². Address generation maps sample index differences into the 288 KB circular capture region; the pre-guard is valid only after the capture buffer has been running for at least `M/2` samples, which is already true in normal continuous RX operation.

---

## SRAM macro path

OpenRAM support for GF180MCU is not assumed to be available today, so this block is currently an enablement item rather than a solved macro choice.

Required outcomes:

- a realizable SRAM macro path for GF180MCU
- area, timing, and power estimates early enough to influence floorplan
- a simulation model that lets RTL and firmware continue before the final macro is settled

Candidate paths:

1. enable or port an OpenRAM flow that actually supports the target GF180 stack
2. use an alternative SRAM compiler / macro source compatible with the competition flow
3. split the memory into smaller macros if a monolithic 544 KB block is not practical
4. use behavioural SRAM models for simulation while the physical macro path is still being worked out

Suggested split if a single macro is not practical:

- `256 KB` FFT staging
- `288 KB` capture SRAM

If optional padded diagnostics are dropped, the live FFT staging requirement falls to `128 KB`, which reduces pressure on the macro path and should remain an available fallback.

**Action required before floorplan:** Resolve the SRAM macro path early. This is a foundational block for the project and also a useful competition contribution in its own right if a reusable GF180MCU SRAM flow is established.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Write + read back | cocotb: write known pattern, read back | Byte-identical |
| Arbiter priority | FFT + PicoRV32 simultaneous | FFT gets grant; PicoRV32 stalls then gets access |
| Full address range | Sweep all 136K words | No stuck bits |
| Capture region isolation | Write capture data; run FFT | FFT staging (0x00000–0x3FFFF) unaffected |
| Guarded capture window | Inject preamble with random offset | Frozen window contains `timing_ref-M/2` through `timing_ref+8.5M-1` |

---

## Related blocks

- [FFT Engine](FFT%20Engine.md) — primary user of FFT staging region
- [Packet Control FSM](Packet%20Control%20FSM.md) — asserts capture protection and live FFT readiness
- [PicoRV32 Integration](PicoRV32%20Integration.md) — firmware access + capture region
- [SPI Slave](SPI%20Slave.md) — host burst-reads capture region via SPI
- [System Architecture](../System%20Diagram.md) — area estimate; OpenRAM action item
