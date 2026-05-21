# Frontend Buffer Controller

RX path block. See [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) and [SF6 1kB Frontend Buffer Exploration](../SF6%201kB%20Frontend%20Buffer%20Exploration.md) for context.

**Owner:** TBD
**Status:** Draft

---

## Role

Manages the shared 1 kB frontend sample SRAM. Provides a 2-symbol rolling history of DC-removed (pre-dechirp) samples to the SC correlator during acquisition, then freezes or repurposes the memory after lock.

This block owns:

- the write pointer and circular addressing
- the read-before-write access sequence on the single-port SRAM
- the read address generation for the SC delayed-sample path
- the freeze/mode transition after `sc_lock`

It does **not** own:

- dechirping (downstream of the buffer)
- SC correlation arithmetic
- training accumulation (register-based, receives live samples independently of SRAM)

Dedicated frontend SRAM is always the primary acquisition buffer. Any use of CPU SRAM is an optional extension to this block, not the baseline architecture.

---

## Sample Rate

The decimator delivers samples at **125 kS/s** (32 MHz / R=256, 1× Nyquist — see [ΣΔ Decimator](ΣΔ%20Decimator.md)). At SF6 (M = 2^6 = 64 samples/symbol) and 16 MHz system clock:

```
iq_valid period  = 16 MHz / 125 kS/s = 128 clock cycles
Symbol period    = 64 × 128 = 8,192 cycles = 512 µs
Buffer depth     = 128 sample times = 2 symbols  (8-bit storage)
```

Samples/symbol = 2^SF exactly for all SF at 1× Nyquist — no fractional timing.

---

## Memory Organisation

Two single-port SRAM macros of 512 B each:

| Macro | Channels stored |
|---|---|
| `SRAM0` | ch0 and ch1 |
| `SRAM1` | ch2 and ch3 |

Both macros share a common write pointer. All four channels for the same sample time are read and written together.

### Physical word organisation

The `gf180mcu_fd_ip_sram__sram512x8m8wm1` macro is **8-bit wide** (512 words × 8 bits). Each sample time for two channels (I+Q per channel = 4 bytes) occupies **4 consecutive SRAM addresses**:

```
SRAM0, physical addresses 4k .. 4k+3  (sample time k, channels 0 & 1):
  4k+0:  ch0_I[7:0]
  4k+1:  ch0_Q[7:0]
  4k+2:  ch1_I[7:0]
  4k+3:  ch1_Q[7:0]

SRAM1, physical addresses 4k .. 4k+3  (sample time k, channels 2 & 3):
  4k+0:  ch2_I[7:0]
  4k+1:  ch2_Q[7:0]
  4k+2:  ch3_I[7:0]
  4k+3:  ch3_Q[7:0]
```

k ranges 0 – 127, giving 128 sample times = 2 symbols at SF6. Physical address range: 0 – 511 (9-bit address A[8:0]).

Four sequential single-byte accesses to one macro deliver the full two-channel IQ pair for one sample time. Both macros are accessed in lockstep (same address sequence each cycle), so all four channel bytes for a sample time are captured in 4 cycles total.

### Sample Width and Depth

Decimated samples are **8-bit signed** I+Q per channel.

**Word width per macro per sample time:**

| Storage | Bytes / sample time (2 ch) | Max sample times in 512 B | Max SF (D=M, see below) |
|---|---|---|---|
| 8-bit I + 8-bit Q | 4 B | 128 | **SF7** (M=128) |
| 16-bit I + 16-bit Q | 8 B | 64 | SF6 (M=64, exactly full — no margin) |

At 8-bit storage the 512-word macro supports up to **SF7** using the D=M read-before-write access pattern described below. At 16-bit storage depth falls to 64 sample times, limiting operation to SF6 with no margin; a 2-kB buffer (4 macros) is required for 16-bit SF7.

**The 2-symbol rolling window required for SC correlation only fits within 1 kB if samples are stored at 8-bit precision per component.**

At 16-bit storage the 1 kB buffer holds only 1 symbol per macro — insufficient for a 2-symbol SC window.

### Resolution options

Three paths to resolve the depth vs precision tradeoff:

1. **Saturate to 8 bits for SRAM storage.** The SC correlator is a detection and timing block, not a precision estimator. 8-bit storage is likely acceptable for SC performance if the write path uses **saturating arithmetic** (not bitfield truncation). The training accumulator receives full-precision live samples directly and is unaffected — it does not read from SRAM. This is the preferred option if the 1 kB budget is hard.

   **Why saturation, not truncation.** Two failure modes exist if samples are stored by taking the bottom 8 bits directly:
   - *High signal / no AGC:* a strong signal with amplitude > 127 wraps around (e.g. +300 stored as +44), corrupting the SC correlation entirely.
   - *Low signal:* weak signals near the noise floor are unaffected by the choice of saturation vs truncation — quantisation noise slightly raises the SC noise floor but SC sensitivity is already SNR-limited at this point.

   The write path stores the decimator byte directly (SAMPLE_W=8 = STORE_W=8):
   ```
   stored_I = sample_I   // already 8-bit signed; no shift
   stored_Q = sample_Q
   ```

   Saturation preserves the sign and approximate magnitude of a clipped sample. SC correlation quality degrades gracefully at very high signal amplitude rather than producing random values.

   The SX1257 AGC should normally prevent consistent saturation, but saturation arithmetic is still required as a safety net for burst-level variations and AGC settling transients.

   **Required validation:** Simulate SC detection threshold, false-alarm rate, and timing accuracy with 8-bit saturated storage vs full-precision inputs, swept across the full SNR range including both weak-signal and strong-signal extremes.

2. **Increase SRAM to 2 kB.** Use 4 × 512 B macros (or 2 × 1 kB macros). Doubles area cost. Removes the precision tradeoff entirely. Choose this if 16-bit SC fidelity is required or if the SC threshold is sensitive to quantisation noise.

3. **Reduce to NR=2 in acquisition.** Only store 2 channels (one macro) at full width and use 2-antenna SC detection. Not preferred — loses detection diversity gain.

**Decimator output is 8-bit. SRAM storage is also 8-bit — no saturation shift required.** The decimator output byte is written directly to SRAM. The saturation clamp in the write path is trivially satisfied (8-bit input to 8-bit storage). Option 1 is the baseline; SC performance with 8-bit storage still requires simulation validation (see open questions).

### Optional CPU SRAM borrow mode

If additional delayed-sample depth is needed without adding more dedicated frontend SRAM macros, the controller may optionally borrow a reserved upper CPU SRAM window:

- `CPU_SRAM_BORROW_EN=0`: baseline implementation, dedicated frontend SRAM only
- `CPU_SRAM_BORROW_EN=1`: controller extends its logical delayed-sample address space into a hardware-reserved CPU SRAM bank

Rules:

- the borrowed region must be hardware-accessible by the Frontend Buffer Controller without firmware copying
- the mode is only legal when `CPU_RESET=1`, or when firmware is explicitly barred from the borrowed bank by the memory map
- when `CPU_RESET=0`, the reserved upper `1 kB` borrow bank must be excluded from the linker map and from C runtime `.bss`/stack initialization so firmware execution does not overwrite borrowed sample data
- when shared borrow is enabled with `CPU_RESET=0`, the Frontend Buffer Controller has absolute priority on the borrowed bank; Pico stalls on contention and must not disturb frontend timing
- if the borrow region is unavailable, the controller must not attempt four-branch `SF7` operation that depends on it

Fallback:

- `SF6`: always use the baseline dedicated frontend SRAM path
- `SF7`: if borrow is unavailable, allow only `NR=2` acquisition fallback using branches `1` and `3`

Open note:

- if branch `1` or `3` is disabled or failed, the exact fallback behavior is intentionally left unspecified for now

---

## Logical Address Space and Buffer Depth

SC requires one M-sample-delayed copy of each branch — **D = M sample times** is the minimum buffer depth. The current sample arrives live from the decimator; only the delayed sample requires SRAM storage.

### D = M — read-before-write (preferred, supports SF6 and SF7)

```
D = M = 2^SF

sample_ptr   =  wr_ptr mod D           // same address for read and write
physical_base = 4 * sample_ptr         // byte 0 of the 4-byte group
```

Read and write target the **same physical addresses** each sample time. The read phase (capturing the M-old delayed sample) runs first; the write phase then overwrites those addresses with the current sample. Because reads complete before writes begin, the delayed sample is captured correctly before it is overwritten — no corruption.

At SF7: D = M = 128, physical addresses 0–511 (exactly the 512-word macro capacity).  
At SF6: D = M = 64, physical addresses 0–255 (256 B used; 256 B unused).

### D = 2M — separate read/write addresses (legacy; wastes half the buffer)

```
D = 2M

sample_ptr_write   =  wr_ptr mod 2M
sample_ptr_delayed = (wr_ptr - M) mod 2M   // M positions behind write

physical_base_write   = 4 * sample_ptr_write
physical_base_delayed = 4 * sample_ptr_delayed
```

Read and write addresses are M positions apart. At SF6: D = 128, physical addresses 0–511 (full macro). **At SF7: D = 256, requires 1024 B — does not fit in the 512 B macro.** This formulation is not needed and is not used in this implementation.

### Address summary

| SF | M | D (=M) | Physical byte range | Macro utilisation |
|---|---|---|---|---|
| 6 | 64 | 64 | 0–255 | 50% |
| 7 | 128 | 128 | 0–511 | 100% |

Both SRAM0 and SRAM1 use the same `wr_ptr` and physical address sequence, accessed in lockstep each cycle.

---

## Access Protocol

The `gf180mcu_fd_ip_sram__sram512x8m8wm1` is **single-port** with a minimum cycle time of **55.6 ns** at 3.3 V. At 16 MHz (62.5 ns/cycle), the 55.6 ns minimum fits within a **single clock cycle** — no multi-cycle hold required. Each byte address may advance on the following cycle.

Each sample time requires 4 byte reads (delayed sample) then 4 byte writes (current sample) — **8 cycles total**, both macros in lockstep.

**Timing margin per decimation ratio:**

| R | f_s | Cycles/iq_valid | SRAM active | Slack | Utilisation |
|---|---|---|---|---|---|
| 256 | 125 kHz | 128 | 8 | ~118 | 6% |
| 128 | 250 kHz | 64 | 8 | ~54 | 13% |
| 64 | 500 kHz | 32 | 8 | ~22 | 27% |
| 32 | 1 MS/s | 16 | 8 | **~6** | **56%** |

Slack = cycles/iq_valid − SRAM active − ~2 cycles of pipelined control overhead (sample latch, address compute, wr_ptr increment).

**R=32 constraint (debug/wideband capture mode only):** At 1 MS/s, `iq_valid` arrives every 16 cycles and the SRAM sequence consumes 8 cycles, leaving ~6 cycles of slack. The RTL must pipeline address computation and overlap the `wr_ptr` increment with the final write cycle — a naively sequential implementation would exceed the 16-cycle budget. R=32 is not a production mode; this constraint must be noted in the RTL implementation plan.

### Per-sample-time sequence (D = M, read-before-write)

With D = M, read and write target the **same** base address. Reads run first so the M-old delayed data is captured before it is overwritten.

```
Cycle 0:  iq_valid asserts. Latch incoming raw sample.
            base = 4 * (wr_ptr mod M)    // same address for read and write

Cycle 1:  Read byte 0 (CEN=0, GWEN=1, A=base+0; 1-cycle access at 16 MHz).
            Q → ch0_I_del (SRAM0), ch2_I_del (SRAM1). Latch at cycle 1.
Cycle 2:  Read byte 1 (A=base+1). Q → ch0_Q_del, ch2_Q_del.
Cycle 3:  Read byte 2 (A=base+2). Q → ch1_I_del, ch3_I_del.
Cycle 4:  Read byte 3 (A=base+3). Q → ch1_Q_del, ch3_Q_del.
            All 4 delayed bytes captured and held for SC correlator.

Cycle 5:  Write byte 0 (CEN=0, GWEN=0, A=base+0, D=ch0_I_cur / ch2_I_cur).
Cycle 6:  Write byte 1 (A=base+1, D=ch0_Q_cur / ch2_Q_cur).
Cycle 7:  Write byte 2 (A=base+2, D=ch1_I_cur / ch3_I_cur).
Cycle 8:  Write byte 3 (A=base+3, D=ch1_Q_cur / ch3_Q_cur).

Cycles 9+: CEN=1 (macros idle) until next iq_valid.
```

**Why read-before-write is safe.** The SRAM outputs the value stored at `base` during cycles 1–8 — this is the sample written M `iq_valid` periods ago (the desired delayed sample). The write on cycles 9–16 then replaces it with the current sample. No data hazard.

---

## Operating Modes

### Mode 1 — Acquisition (rolling)

Default state after reset and between packets.

- `wr_ptr` increments every `iq_valid`
- SRAM written with current incoming sample
- SRAM read returns `(wr_ptr - M + 1) mod D` for SC correlator
- SC correlator receives current sample (live) and delayed sample (from SRAM) every cycle

### Mode 2 — Locked / Freeze

Entered when `sc_lock` asserts.

- `wr_ptr` stops incrementing (or increments into a separate post-lock capture region)
- SRAM contents are frozen at the lock boundary
- The 2M samples preceding `timing_ref` are preserved for optional post-lock use (short timing confirmation or diagnostic readback)
- SC correlator no longer needs SRAM reads; block can gate SRAM clock if power saving is desired

### Mode 3 — Post-lock Observation (optional)

If the post-lock Sync/SFD region needs a short sample snapshot:

- Re-enable `wr_ptr` increment for up to `2M` samples after lock
- Overwrites acquisition history with post-lock samples
- Useful for a short downchirp/sync timing confirmation step if added later

This mode is optional and not required for the baseline non-FFT path.

### Mode 4 — Idle / Reset

Between packets, before first acquisition. `wr_ptr` may run but SC output is gated by a minimum fill count (buffer must have at least M valid samples before SC reads are meaningful).

Minimum fill requirement:

```
buf_valid = (sample_count >= M)
```

SC correlator enable gated by `buf_valid`.

### Mode 5 — SRAM Dump

Entered when `SRAM_DUMP_START` is written while in Mode 2 (Locked). The dump sequencer takes over SRAM0 and SRAM1 access from the acquisition controller. The acquisition controller releases the SRAM bus in Locked state, so there is no contention.

See Hardware Dump Sequencer section below.

---

## Hardware Dump Sequencer

Provides host-readable access to the frozen SRAM contents after `sc_lock`. Captures the raw IQ sample window that the SC correlator locked on — useful for offline channel estimation, SC timing verification, and debugging combining anomalies.

### Timing

After `sc_lock` and before the payload starts, the window available for a dump is approximately **5M samples** at SF7/125 kHz = **5 ms**. A full dual-macro dump takes:

```
2 macros × 512 bytes × 1 cycle/byte = 1024 cycles = 64 µs
```

The SPI readback is the bottleneck: 1024 bytes at 10 MHz SPI = ~820 µs. Both fit within the 5 ms window.

### Interface

The dump controller exposes a register-mapped byte-access interface. The host controls the read address; the hardware performs the 2-cycle SRAM access and presents the result:

| Register | R/W | Description |
|---|---|---|
| `SRAM_DUMP_ADDR[9:0]` | R/W | Byte address to read (bits [8:0]) + macro select (bit [9]: 0=SRAM0, 1=SRAM1) |
| `SRAM_DUMP_DATA[7:0]` | R | Byte at `SRAM_DUMP_ADDR`; valid one SPI transaction after address write |
| `SRAM_DUMP_START` | W | Write 1 to enter dump mode; only accepted in Locked state |
| `SRAM_DUMP_DONE` | R | 1 = dump controller is idle and SRAM_DUMP_DATA is valid |

**Access sequence (per byte):**
```
1. Host writes SRAM_DUMP_ADDR via SPI.
2. Dump controller issues a 2-cycle SRAM read at that address.
3. Host reads SRAM_DUMP_DATA (SRAM read always completes before the next SPI transaction arrives).
4. Repeat with incremented address.
```

Step 3 is always safe: the minimum SPI transaction time (at 10 MHz, 16-bit transaction ≈ 1.6 µs) is much longer than the 1-cycle SRAM read (62.5 ns). No polling of `SRAM_DUMP_DONE` is needed for single-byte reads; it is useful only if the host pipelines address writes.

### Full dump sequence

```
Host writes SRAM_DUMP_START = 1
  ↓
For addr = 0..511:               // SRAM0: ch0/ch1 samples
  write SRAM_DUMP_ADDR = addr
  read  SRAM_DUMP_DATA → buf0[addr]

For addr = 0..511:               // SRAM1: ch2/ch3 samples
  write SRAM_DUMP_ADDR = 0x200 | addr
  read  SRAM_DUMP_DATA → buf1[addr]
```

**Data format** (512 bytes per macro, 128 sample times each):
```
SRAM0 addr 4k+0: ch0_I[k]   SRAM1 addr 4k+0: ch2_I[k]
SRAM0 addr 4k+1: ch0_Q[k]   SRAM1 addr 4k+1: ch2_Q[k]
SRAM0 addr 4k+2: ch1_I[k]   SRAM1 addr 4k+2: ch3_I[k]
SRAM0 addr 4k+3: ch1_Q[k]   SRAM1 addr 4k+3: ch3_Q[k]
```

k = 0..127 gives 128 sample times = 1 full symbol of rolling history across all 4 antennas, frozen at `sc_lock`.

### Constraints

- Dump is only valid in Locked state. Writing `SRAM_DUMP_START` outside of Locked state is ignored.
- The acquisition controller holds SRAM bus ownership in all other states; the dump controller must not contend.
- The dump does not modify SRAM contents (read-only access).
- After the packet ends (Packet Control FSM returns to IDLE), the acquisition controller reclaims the SRAM and `SRAM_DUMP_DONE` clears.

---

## Interface

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | 16 MHz system clock |
| `rst_n` | in | 1 | Active-low reset |
| `iq_valid` | in | 1 | Decimator sample strobe — 125 kS/s, one pulse per 128 clock cycles at SF6 |
| `sample_in[NR][8]` | in | 4×8 | Incoming DC-removed samples, 8-bit signed I+Q per component |
| `sf` | in | 3 | Spreading factor; sets M = 2^SF |
| `sc_lock` | in | 1 | From SC detector; triggers freeze |
| `buf_mode` | out | 2 | Current operating mode (acquisition / locked / post-lock / idle) |
| `buf_valid` | out | 1 | Buffer has ≥ M valid samples; gates SC enable |
| `current_sample[NR][8]` | out | 4×8 | Current sample (live, to SC and dechirp) |
| `delayed_sample[NR][8]` | out | 4×8 | Sample from M times ago (from SRAM) |
| `delayed_valid` | out | 1 | Delayed sample read is valid this cycle |
| `wr_ptr` | out | 7 | Current write pointer in sample-time units (0–127) |
| `sram0_A` | out | 9 | Byte address to SRAM0 (A[8:0], 0–511) |
| `sram0_D` | out | 8 | Write data byte to SRAM0 (D[7:0]) |
| `sram0_Q` | in | 8 | Read data byte from SRAM0 (Q[7:0]) |
| `sram0_CEN` | out | 1 | SRAM0 chip enable (active-low; 1 = idle) |
| `sram0_GWEN` | out | 1 | SRAM0 global write enable (active-low; 0 = write, 1 = read) |
| `sram1_A` | out | 9 | Byte address to SRAM1 |
| `sram1_D` | out | 8 | Write data byte to SRAM1 |
| `sram1_Q` | in | 8 | Read data byte from SRAM1 |
| `sram1_CEN` | out | 1 | SRAM1 chip enable (active-low) |
| `sram1_GWEN` | out | 1 | SRAM1 global write enable (active-low) |

---

## Parameters

| Parameter | Values | Notes |
|---|---|---|
| `SAMPLE_W` | 8 | Bit width per I or Q component from decimator. Matches STORE_W — no saturation shift required. |
| `STORE_W` | 8 or 16 | Bits stored per component in SRAM after saturation/truncation. 8 = SF7 max. 16 = SF6 max (512 B exactly full, no margin). |
| `NR` | 4 | Number of receive branches. |
| `SF_MAX` | 7 | Maximum supported SF with 8-bit storage and D=M read-before-write. SF8+ requires additional macros. |
| `ZERO_SUB_CAM_DEPTH` | 16 | Number of bad sample-time entries the zero-substitution CAM can hold per macro. Macros with more faults than this threshold fall back to NR=2. |

---

## BIST

SRAM0 and SRAM1 use **`gf180mcu_fd_ip_sram__sram512x8m8wm1`** — the silicon-proven GF180MCU PDK macro (512 words × 8 bits, "5V Green" transistor class, operating range 1.62 V – 5.50 V). Both macros are operated at **3.3 V**, placing them on the same supply rail as the digital logic with no level shifters required. BIST runs at power-on before acquisition mode is entered. See [Memory Strategy](../Memory%20Strategy.md) for the full BIST and fallback architecture.

March-5N write/read pattern on each 512 B macro independently. BIST reports faults at **sample-time granularity** (groups of 4 consecutive bytes). If any byte within a 4-byte sample-time group fails, the entire sample time is marked bad. The host programs bad sample-time addresses into the zero-substitution CAM after BIST completes.

### Zero-substitution CAM

Rather than discarding a macro on the first fault, the controller contains a `ZERO_SUB_CAM_DEPTH`-entry CAM per macro. During acquisition, before forwarding a delayed sample to the SC correlator, the controller checks whether the current read address matches any CAM entry. On a match, zero is returned instead of the SRAM output.

**Why zero is safe for SC correlation.** The SC statistic is an accumulation:

```
c_j = Σ_{n=0}^{M-1} current_j[n] · conj(delayed_j[n])
```

A zeroed delayed sample contributes nothing to the sum — the term drops out rather than corrupting it. Substituting zero for a bad delayed sample is equivalent to a slightly shorter integration window. At SF7 (M=128), one bad sample time reduces effective integration to 127/128 — a loss of ~0.03 dB, negligible against the LoRa link budget.

The SC lock condition `Mag_SC >= θ_SC² · Energy_Ref` is also unaffected in ratio: both the cross-product term and the corresponding energy term at a bad address are zeroed, so numerator and denominator lose the same contribution and the ratio is preserved. No threshold adjustment is needed for a small number of bad sample times.

**SF-range awareness.** Only bad sample times within `[0, M)` consume a CAM entry; faults at addresses `≥ M` are irrelevant (never accessed by the circular buffer at the current SF) and must not be counted against the CAM budget. At SF6 (M=64) the upper half of each macro (addresses 64–127) is unused — faults there are free.

### Programming sequence

```
BIST completes
    ↓
Host reads SRAMx_BAD_SAMPLE_COUNT via SPI
    ↓
If count ≤ ZERO_SUB_CAM_DEPTH:
    Host programs SRAMx_ZERO_SUB_n_ADDR / _VALID for each bad address
    Enable NR=4 with zero-substitution active
Else:
    NR=2 fallback on the healthy macro
```

### Results readable via SPI

| Register | Description |
|---|---|
| `SRAM0_BIST_PASS` | 1 = SRAM0 passed all March-5N patterns with no faults |
| `SRAM0_BAD_SAMPLE_COUNT` | Number of bad sample-time addresses found in SRAM0 (within `[0, 127]`) |
| `SRAM0_ZERO_SUB_n_ADDR` (n=0..15) | Sample-time address (7-bit, 0–127) of bad entry n in SRAM0 CAM |
| `SRAM0_ZERO_SUB_n_VALID` (n=0..15) | Enable bit for SRAM0 CAM entry n |
| `SRAM1_BIST_PASS` | 1 = SRAM1 passed all March-5N patterns with no faults |
| `SRAM1_BAD_SAMPLE_COUNT` | Number of bad sample-time addresses found in SRAM1 |
| `SRAM1_ZERO_SUB_n_ADDR` (n=0..15) | Sample-time address of bad entry n in SRAM1 CAM |
| `SRAM1_ZERO_SUB_n_VALID` (n=0..15) | Enable bit for SRAM1 CAM entry n |

### Degraded-mode policy

| SRAM status | Operating mode |
|---|---|
| Both pass (count = 0) | Full NR=4, no substitution |
| Either macro: count ≤ 16 (within `[0, M)`) | NR=4 with zero-substitution on bad sample times; slight integration loss |
| SRAM0: count > 16 within `[0, M)` | NR=2 using ch2/ch3 only (SRAM1) |
| SRAM1: count > 16 within `[0, M)` | NR=2 using ch0/ch1 only (SRAM0) |
| Both macros: count > 16 within `[0, M)` | Bypass mode only; acquisition disabled |

---

## Open Questions

1. **DSP SRAM defect rate — check with wafer.space tapeout 1 participants.** The zero-substitution CAM depth (currently 16) and the NR=2 fallback threshold depend on knowing what defect rates look like in practice for the `gf180mcu_fd_ip_sram__sram512x8m8wm1` macro on this process. Contact participants from the wafer.space tapeout 1 who included this SRAM macro and ask for their observed bad-cell counts and fault distribution. Use that data to validate or revise the CAM depth and to decide whether the SF7 NR=4 operating point is realistic.

2. **8-bit storage acceptable for SC?** Decimator output is already 8-bit; no truncation occurs. Is SC detection quality adequate across the full SNR range with 8-bit samples? **Must be validated in simulation** — sweep SC detection threshold, false-alarm rate, and timing accuracy at both weak-signal and strong-signal extremes. Note that naive bitfield truncation (taking LSBs) is not acceptable — strong signals wrap around and corrupt the correlation. Saturation (clamp to ±127) is mandatory. Training accumulator is unaffected (receives live full-precision samples).

3. **Post-lock observation mode needed?** The baseline non-FFT path does not require it. Include only if a sync/SFD timing confirmation step is added later.

4. **SF8 and above?** SF8 requires M=256 sample times × 4 bytes = 1024 B per macro — exceeds the 512 B proven macro. SF8 support requires 4 macros (2 kB). No architectural blocker; just area cost.

---

## Known Limitations

- **SF7 is the maximum with 2 × 512 B macros and 8-bit storage.** At SF7 the macro is exactly full (D=M=128, 512 B used). The read-before-write access pattern is required — D=2M does not fit.
- **SF8+ requires more macros.** SF8 needs D=M=256 → 1024 B per macro pair → 4 macros total (2 kB). No architectural change needed beyond adding macros and widening the address counter.
- Same-packet weight application is not supported by this buffer. Next-packet weights are the baseline.

---

## Related Blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides `iq_valid` and `sample_in`
- [Correlator Bank (SC)](Correlator%20Bank.md) — consumes `current_sample` and `delayed_sample`
- [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) — overall chain context
- [SF6 1kB Frontend Buffer Exploration](../SF6%201kB%20Frontend%20Buffer%20Exploration.md) — memory budget rationale
