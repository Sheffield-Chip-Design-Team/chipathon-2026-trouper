# FFT Engine

RX path stage 4. See [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Updated for RCTSL support

---

## Function

Multi-lane radix-2 FFT on dechirped complex I+Q samples for all 4 antennas.

**Goal:** Transform dechirped preamble symbols into the frequency domain for fine frequency (CFO) refinement, timing alignment, and channel estimation.

**Preamble Acquisition Flow (3-pass):**
1. **Pass 1 — Fine CFO (RCTSL):** Concatenates 8 dechirped symbols and performs an **unpadded live FFT**. Applies the RCTSL quadratic correction to find `eps_sub`. A 2× zero-padded mode is optional for SF7/SF8 validation or diagnostics, not required for the live path.
2. **Pass 2 — Coarse Integer Bin:** Performs a standard length-$M$ FFT on dechirped samples (corrected by `eps_sub` in the time domain) to find the integer bin `k_peak`.
3. **Pass 3 — Coherent Channel Estimation:** Accumulates $D_j[s][k\_peak]$ across symbols to produce the final channel matrix `H`.

The FFT engine starts only after the capture controller has made the 8-symbol live RCTSL window resident in SRAM. Schmidl-Cox lock is a capture event, not an immediate FFT-compute event, and diagnostic post-guard capture must not block the live FFT trigger.

---

## Interface

| Port | Direction | Width | Rate | Description |
| --- | --- | --- | --- | --- |
| `trigger` | in | 1 | — | From live capture-ready FSM (preamble acq) or firmware (payload/diagnostics) |
| `timing_ref` | in | 32 | — | Estimated preamble-start sample index from Schmidl-Cox, in `iq_valid` units |
| `sf` | in | 3 | static | Spreading factor: 0=SF5 … 7=SF12 |
| `iq_valid` | in | 1 | $f_s$ | Master sample strobe — used as **Clock Enable** |
| `fft_active` | out | 1 | — | High during READ/COMPUTE/PEAK — capture window is already frozen |
| `clk_32m` | in | — | 32 MHz | Master clock |
| `rst_n` | in | — | — | Active-low reset |
| `fft_done` | out | 1 | — | Pulses high when all 4 antennas computed |
| `sram_addr` | out | 20 | — | Address into Baseband SRAM |
| `sram_wdata` | out | 32 | — | Write data |
| `sram_rdata` | in | 32 | — | Read data |
| `sram_we` | out | 1 | — | Write enable |
| `eps_sub` | out | 16 signed Q1.15 | — | Fractional CFO estimate from Pass 1 |

---

## Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| Live max FFT size ($N_{max}$) | 32,768 points | 8-symbol unpadded RCTSL for SF12 (`8 × 4096`) |
| Optional padded FFT size | 65,536 points | 2× zero-padded diagnostic/refinement mode, not live-path mandatory |
| Live FFT working buffer | 128 KB | 32,768 complex int16 |
| Optional padded buffer | 256 KB | Required only if 65,536-point diagnostic mode is implemented |
| Butterfly lanes | 2 minimum, 4 preferred | Shared controller with multiple radix-2 butterfly lanes |
| Live SF12 4-antenna compute target | ≤30 ms at 32 MHz | Stretch target ≤15 ms |
| Capture guard | 0.5M pre + 0.5M post | Capture window is 9M samples per antenna |

---

## Implementation notes

### Natural sub-blocks

Even if the FFT engine is implemented as one top-level RTL block, it naturally decomposes into the following sub-blocks:

1. **Capture read / address generator**
   - reads the correct samples from capture SRAM
   - uses `timing_ref`, `M`, pass number, symbol index, and antenna index

2. **Dechirp / pre-rotation front end**
   - multiplies by the LoRa downchirp reference
   - applies `eps_sub` time-domain phase correction in later passes

3. **Pass controller / acquisition FSM**
   - orchestrates Pass 1 (RCTSL), Pass 2 (integer bin), and Pass 3 (channel accumulation)
   - iterates across antennas and controls staging-buffer reuse

4. **FFT datapath core**
   - radix-2 butterfly lanes
   - twiddle-factor generation or storage
   - stage scheduler and bit-reversal / stride sequencing

5. **Working-buffer / SRAM interface**
   - reads and writes staging data
   - supports in-place transform access patterns
   - must be organized so multi-lane butterfly parallelism is actually usable

6. **Peak search / magnitude engine**
   - computes magnitude or magnitude-squared
   - finds `k0` / `k_peak` from FFT output

7. **RCTSL interpolation block**
   - uses the bins around the peak, e.g. `Y[-1]`, `Y[0]`, `Y[+1]`
   - computes sub-bin `eps_sub`

8. **Channel accumulation block**
   - accumulates `D_j[s][k_peak]` across symbols
   - produces the final `H` entries

9. **Result / status export**
   - drives `eps_sub`, `fft_done`, and status / debug outputs
   - writes final `H` and related outputs to the visible register / SRAM region

**Flexible Transform Length.** The live FSM must handle $N$ ranging from 32 (SF5 single-symbol passes) to 32,768 (8-symbol RCTSL SF12). If optional padded mode is implemented, it must also handle 65,536-point transforms. The number of passes is $\log_2(N)$.

**RCTSL Pass.** Pass 1 reads 8 symbols from capture SRAM, dechirps them into the live staging buffer, performs the unpadded FFT, and then the PicoRV32 (or a hardwired quadratic block) computes `eps_sub` using the magnitudes around the peak. Zero padding does not add information; it only samples the same spectrum more densely, so it is reserved for optional diagnostics or low-SF validation if timing and SRAM budget allow.

The 8 symbols are addressed relative to `timing_ref`, not relative to the Schmidl-Cox lock edge:

```
symbol0_addr = capture_addr(timing_ref)
symbol_s_addr = capture_addr(timing_ref + s*M)
```

The capture window itself begins at `timing_ref - M/2`, so the FFT can tolerate residual Schmidl-Cox timing error and still read a deterministic 8-symbol slice.

**Integer Bin Pass.** Pass 2 uses `eps_sub` to apply a phase rotation during the dechirp read phase, then performs a standard single-symbol FFT to find the integer peak.

**Butterfly parallelism.** The live implementation should not be a one-butterfly serial engine. Use a shared FFT controller with at least 2 butterfly lanes; 4 lanes is preferred if staging SRAM banking and area allow. The staging memory must be organized so the extra lanes are useful rather than blocked by a single-port bottleneck.

**Memory Reuse.** The live 128 KB buffer is used for all three passes. Pass 1 uses it for the 8-symbol RCTSL FFT; Pass 2 and 3 use it for single-symbol FFT staging and result storage. If optional padded mode is implemented, the staging region may grow to 256 KB.

**Live capture handoff.** The preamble-acquisition FSM sequence is:

1. Schmidl-Cox asserts `sc_lock` and provides `timing_ref`.
2. Capture controller waits until the 8-symbol live RCTSL window (`timing_ref` through `timing_ref + 8M - 1`) is resident in sample capture SRAM.
3. Capture controller freezes or protects the live window and asserts FFT `trigger`.
4. FFT reads the 8-symbol RCTSL input starting at `timing_ref`.
5. Capture may continue filling diagnostic pre/post guard samples, but those samples must not delay live RCTSL.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| **RCTSL Accuracy** | Inject ±0.3 bin CFO | Live unpadded RCTSL `eps_sub` estimate within target error; compare optional 2× padded mode if implemented |
| **FFT Butterfly** | Inject single-bin pulse | Output matches `np.fft.fft()` to ±2 LSB |
| **Bit-Reversal** | Verify buffer ordering | Data indexed correctly for butterfly stages |
| **In-place SRAM** | Run full COMPUTE sequence | Buffer transformed without data corruption |
| **Lane parallelism** | Run SF12 4-antenna RCTSL | Completes within ≤30 ms at 32 MHz |
| **Capture handoff** | Synthetic preamble with random timing offset | `sc_lock` → live 8-symbol window ready → FFT reads 8 symbols from `timing_ref` |
| **3-Pass Sequence** | Synthetic LoRa preamble | Capture trigger → Correct H matrix and `eps_sub` produced |

---

## Related blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides `iq_valid`
- [Packet Control FSM](Packet%20Control%20FSM.md) — triggers live RCTSL when the 8-symbol window is resident
- [Schmidl-Cox Preamble Detector](Correlator%20Bank.md) — asserts `sc_lock` and provides `timing_ref`
- [Baseband SRAM](Baseband%20SRAM.md) — provides live FFT staging and guarded capture storage
- [Register Map](../Register%20Map.md) — `sf` and peak diagnostic registers
