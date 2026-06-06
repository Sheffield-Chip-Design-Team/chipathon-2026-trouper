# Schmidl-Cox Preamble Detector

RX path block (non-FFT frontend). See [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) and [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Updated for non-FFT path

---

## Background

In the non-FFT frontend, the SC block has two roles:

1. **Packet detection and timing.** Detect the LoRa preamble and produce `sc_lock` and `timing_ref`. With a fixed 8-symbol preamble, `timing_ref` alone is sufficient to locate the full packet — no downstream FFT or sync/downchirp refiner is needed.

2. **CFO diagnostic export.** Export the per-branch complex correlator outputs `c_j` and the pooled sum `C_pool`. These are not used in the weight computation path (common CFO cancels in the weight ratios) but are exported as diagnostic registers for bring-up and characterisation.

SC is no longer a trigger for a downstream FFT stage. It is the terminal acquisition block.

**Reference implementation:** rpp0/gr-lora, `detect_preamble_autocorr()`, `decoder_impl.cc:340`.

---

## Why dechirping is not needed

The SC statistic correlates two adjacent symbol windows of dechirped samples:

```
c_j = Σ_n D_j[n] · conj(D_j[n-M])
```

where `D_j[n] = raw_j[n] · conj(chirp_ref[n mod M])`.

Expanding:

```
c_j = Σ_n raw_j[n] · conj(chirp_ref[n mod M])
          · conj(raw_j[n-M]) · chirp_ref[(n-M) mod M]
    = Σ_n raw_j[n] · conj(raw_j[n-M])
          · conj(chirp_ref[n mod M]) · chirp_ref[n mod M]
    = Σ_n raw_j[n] · conj(raw_j[n-M]) · |chirp_ref[n mod M]|²
```

Since the LoRa chirp has constant amplitude, `|chirp_ref[n mod M]|² = 1` for all n. The chirp reference cancels exactly. SC therefore operates identically on raw samples as on dechirped samples.

**The dechirp sub-block is not needed in this block.** SC receives raw DC-removed samples directly from the Frontend Buffer Controller and computes:

```
c_j = Σ_n current_j[n] · conj(delayed_j[n])
```

where `current_j[n]` and `delayed_j[n]` are the current and delayed raw samples provided by the FRONTEND_BUF. For `SF6–SF8`, this is a full-symbol delay because `L=M`. For `SF9–SF12`, the FRONTEND_BUF only stores the first `L=256` phases of each symbol block, so `delayed_j[n]` exists only on that stored phase subset rather than for every one of the `M` phases.

---

## Sample Rate and Timing

The decimator delivers samples at **f_s = 125 kS/s** (32 MHz / R=256, 1× Nyquist). At the 16 MHz system clock:

```
iq_valid period  = 128 clock cycles  (16 MHz / 125 kS/s)
SF6  M = 64 samples/symbol → symbol period = 64 × 128 = 8,192 cycles = 512 µs
SF7  M = 128                → symbol period = 16,384 cycles = 1,024 µs
```

Samples/symbol = 2^SF exactly for all SF (integer M — no fractional timing). All accumulator window lengths, timing back-calculations, and pointer arithmetic use integer M.

---

## Function

For each receive branch `j`, SC maintains a block-based complex autocorrelation over the valid stored-phase region of adjacent symbol blocks:

```
c_j = Σ_{n in stored phase set} current_j[n] · conj(delayed_j[n])
```

For `SF6–SF8`, the stored phase set spans the full symbol (`L=M`). For `SF9–SF12`, it spans only the first `256` samples of each symbol block (`L=256`), so this is not a full-symbol sliding correlator.

### Detection statistic

Incoherent combination across branches (no cross-branch phase alignment assumed):

```
Mag_SC    = Σ_j |c_j|²
Energy_Ref = Σ_j E_j_curr · E_j_del
```

where `E_j_curr = Σ |current_j[n]|²` and `E_j_del = Σ |delayed_j[n]|²`.

Lock condition (multiplication form, avoids division):

```
Mag_SC  ≥  (θ_SC)² · Energy_Ref
```

`θ_SC` is the programmable detection threshold (default 0.90).

### CFO diagnostic

After lock, the pooled correlator sum provides a coarse CFO estimate:

```
C_pool = Σ_j c_j
ω̂_diag = -angle(C_pool) / M
```

This is exported as a diagnostic only. It is not used in weight computation — common CFO cancels in the MRC/EGC weight ratios and the SX1302 handles residual CFO downstream.

### Outputs

- `sc_lock` — asserted when detection statistic exceeds threshold for `SC_HITS_REQ` consecutive symbol pairs
- `timing_ref` — estimated preamble-start sample index (back-calculated from lock event)
- `c_j[3:0]` — per-branch complex correlator value at lock (diagnostic)
- `C_pool` — pooled complex correlator sum at lock (diagnostic)
- `cfo_diag` — coarse CFO estimate in rad/sample (diagnostic register only)

### Timing back-calculation

`timing_ref` is not the lock-edge sample counter. With `N_hit` consecutive hits required, the detector has consumed approximately `N_hit + 1` symbols before asserting lock. The back-calculation is:

```
timing_ref = lock_sample_count - (N_hit + 1) · M + 1
```

With a fixed 8-symbol preamble and `SC_HITS_REQ = 2`, SC locks after seeing symbols 2–3. `timing_ref` points to symbol 0. The training accumulator uses `timing_ref` to identify symbol boundaries for all 8 preamble symbols.

**Timing accuracy:** ±2–3 samples at SF6 (M=64). No downstream refiner corrects this — it is a known limitation of the non-FFT path. For next-packet weight application this is acceptable; the SX1302 performs its own fine timing recovery on the combined output stream.

---

## Signal Flow

```
FRONTEND_BUF
  current_j[n], delayed_j[n]  (raw DC-removed samples, 8-bit saturated)
        |
        v
  Per-branch accumulator (over M samples)
        c_j     = Σ_n current_j[n] · conj(delayed_j[n])    [complex, int32]
        E_j_curr = Σ_n |current_j[n]|²                      [int32]
        E_j_del  = Σ_n |delayed_j[n]|²                      [int32]
        |
        v
  Incoherent combine
        Mag_SC     = Σ_j |c_j|²          [int64]
        Energy_Ref = Σ_j E_j_curr · E_j_del  [int64]
        |
        v
  Threshold compare
        hit = (Mag_SC >= θ_SC² · Energy_Ref)
        |
        v
  Hit counter / lock FSM
        sc_lock, timing_ref
        |
        v
  CFO diagnostic latch
        C_pool = Σ_j c_j  (latched at lock)
        cfo_diag = -angle(C_pool) / M
```

---

## Interface

| Port | Direction | Width | Rate | Description |
|---|---|---|---|---|
| `clk` | in | 1 | 32 MHz | System clock |
| `rst_n` | in | 1 | — | Active-low reset |
| `iq_valid` | in | 1 | 125 kS/s | Sample strobe from decimator (32 MHz / R=256) — used as clock enable |
| `current_j[3:0]` | in | 4×2×8 | f_s | Current raw samples from FRONTEND_BUF (I+Q per branch, 8-bit saturated) |
| `delayed_j[3:0]` | in | 4×2×8 | f_s | Delayed raw samples from FRONTEND_BUF (full-symbol delay for SF6–SF8; stored-phase subset only for SF9–SF12) |
| `delayed_valid` | in | 1 | f_s | FRONTEND_BUF delayed sample valid; high only when the stored-phase delayed sample exists |
| `sf` | in | 3 | static | Spreading factor; sets M = 2^SF |
| `sc_thr` | in | 16 | static | Detection threshold θ_SC (Q1.15); from `SC_THR` register |
| `sc_hits_req` | in | 2 | static | Consecutive hits required for lock; from `SC_HITS_REQ` register |
| `sc_lock` | out | 1 | per packet | Preamble detected |
| `timing_ref` | out | 32 | per packet | Estimated preamble-start sample index in `iq_valid` units |
| `c_j[3:0]` | out | 4×2×32 | per lock | Per-branch complex correlator at lock (I+Q, int32) — diagnostic |
| `C_pool` | out | 2×32 | per lock | Pooled complex correlator sum (I+Q, int32) — diagnostic |
| `cfo_diag` | out | 16 | per lock | Coarse CFO estimate in rad/sample (Q1.15) — diagnostic register |
| `sc_stat` | out | 16 | per symbol | Current detection statistic Λ (Q4.12) |
| `sc_hit_dbg` | out | 1 | per symbol | Debug: raw threshold-compare result |
| `sc_hit_count_dbg` | out | 2 | per symbol | Debug: consecutive-hit counter state |
| `sc_first_hit_dbg` | out | 32 | per packet | Debug: sample count at first qualifying hit |
| `sc_lock_sample_dbg` | out | 32 | per packet | Debug: sample count when `sc_lock` asserts |

---

## Parameters

| Parameter | Value | Notes |
|---|---|---|
| Detection window | 2L samples per evaluated block | `L=min(M,256)`; full-symbol for SF6–SF8, partial-window for SF9–SF12 |
| Lock hold | 1–3 consecutive hits | Runtime via `SC_HITS_REQ`; default 2 |
| Threshold θ_SC | 0.90 (default) | Programmable via `SC_THR` |
| Accumulator width | int32 for c_j, int64 for Mag_SC / Energy_Ref | See arithmetic widths below |

### Arithmetic widths (8-bit saturated input)

| Quantity | Max value | Required bits | Type |
|---|---|---|---|
| Sample I or Q | ±127 | 8 | int8 |
| Product I×I | ±16129 | 15 | int16 |
| c_j (sum over M=64) | ±1,032,256 | 21 | int32 |
| \|c_j\|² | ~1.07×10¹² | 40 | int64 |
| Mag_SC (sum of 4) | ~4.26×10¹² | 42 | int64 |
| E_j (sum of M) | ≤2,064,512 | 22 | int32 |
| E_j_curr · E_j_del | ~4.26×10¹² | 42 | int64 |
| Energy_Ref (sum of 4) | ~1.71×10¹³ | 44 | int64 |

---

## Sub-blocks

1. **Per-branch SC accumulator**
   - computes `c_j`, `E_j_curr`, `E_j_del` over each M-sample window
   - resets at each symbol boundary (tracked by `iq_valid` count mod M relative to `timing_ref`)
   - four instances (one per branch) or time-multiplexed equivalent

2. **Incoherent combiner**
   - forms `Mag_SC` and `Energy_Ref` from per-branch outputs

3. **Threshold comparator**
   - `hit = (Mag_SC >= θ_SC² · Energy_Ref)` using integer multiply only

4. **Hit counter / lock FSM**
   - counts consecutive hits
   - asserts `sc_lock` when count reaches `SC_HITS_REQ`
   - prevents re-lock on the same packet until reset

5. **Timing-ref back-calculator**
   - `timing_ref = lock_sample_count - (SC_HITS_REQ + 1) · M + 1`

6. **CFO diagnostic latch**
   - latches `c_j[3:0]` and `C_pool = Σ_j c_j` at lock
   - computes `cfo_diag` via CORDIC or lookup (diagnostic path only, not timing-critical)

7. **Status / snapshot export**
   - updates `SC_STAT` each symbol
   - latches energy values at lock for AGC snapshot

---

## Implementation Notes

**No dechirp multiplier needed.** The chirp reference cancels algebraically for constant-amplitude chirps. Removing the dechirp path eliminates 4 complex multipliers (one per branch) compared to the FFT-path SC block.

**Multiplication over division.** The threshold check uses `Mag_SC >= θ_SC² · Energy_Ref`. No divider or CORDIC needed on the detection path.

**Sensitivity controls:**

- `SC_HITS_REQ = 1`: aggressive weak-signal mode
- `SC_HITS_REQ = 2`: default
- `SC_HITS_REQ = 3`: conservative / noisy environment mode

**Preamble length dependency.** SC does not detect preamble length — it simply accumulates per symbol pair until `SC_HITS_REQ` consecutive hits occur. The hardware works correctly with any preamble length ≥ `SC_HITS_REQ + 1` symbols; no register changes are needed for longer preambles.

The interaction between `SC_HITS_REQ` and preamble length governs two things:

1. **Training accumulator N_acc.** Lock asserts after consuming `SC_HITS_REQ + 1` symbols. The training accumulator then collects the remaining preamble symbols. Remaining symbols = preamble_length − (SC_HITS_REQ + 1). For the default 8-symbol preamble with SC_HITS_REQ=2: N_acc ≈ 5·M. For a 16-symbol preamble with SC_HITS_REQ=2: N_acc ≈ 13·M — channel estimates improve by √(13/5) ≈ 1.6× in amplitude SNR. In practice, 5·M already gives well above-unity channel estimate SNR at the LoRa sensitivity threshold for SF≥7, so the gain is negligible there. The benefit is most pronounced at SF6 near the sensitivity limit where the estimation margin is tightest.

2. **SC_HITS_REQ headroom.** With an 8-symbol preamble and SC_HITS_REQ=2, only 3 preamble symbols are consumed before lock — leaving 5 for training. Raising SC_HITS_REQ to 3 consumes 4 symbols, leaving 4 for training (N_acc ≈ 4·M). This is still adequate for SF≥7 at the sensitivity threshold. A 16-symbol preamble allows SC_HITS_REQ=3 with 12 symbols remaining for training — recommended for noisy urban deployments where false-alarm suppression matters.

**Minimum preamble constraint:** preamble_length ≥ SC_HITS_REQ + 2 (at least 1 symbol of training headroom after lock). With SC_HITS_REQ=2, minimum preamble is 4 symbols. With SC_HITS_REQ=3, minimum is 5 symbols. Shorter preambles will lock late or miss the payload window entirely.

**Deployment recommendation:** configure SC_HITS_REQ=3 when the deployment uses ≥ 10-symbol preambles (available via LoRaWAN NS preamble length parameter). This reduces false-alarm rate without meaningful training loss at SF≥7.

**Clock gating.** Block is always-on between packets. Gate all accumulators by `iq_valid` and additionally gate by `delayed_valid` (from FRONTEND_BUF) to suppress spurious accumulation before the buffer has filled.

---

## Verification

| Test | Method | Pass criterion |
|---|---|---|
| Noiseless lock | Pure upchirp preamble, NR=4, SF6 | `sc_lock` asserts within `N_hit + 1` symbols |
| CFO immunity | Inject ε = ±19 kHz (worst case: 20 ppm TX + 2 ppm RX gateway at 868 MHz) | `sc_lock` still asserts; timing_ref within ±3 samples |
| Timing immunity | Random timing offset n₀ ∈ [0, M) | `sc_lock` asserts consistently |
| False-alarm rate (float) | White noise input, 10,000 windows | `sc_lock` rate < 0.1% |
| **8-bit vs float false-alarm** | **White noise, 8-bit quantised vs float, SF6 M=64, 10,000 windows** | **False-alarm rate difference < 0.01%; no noise-noise cross-product bias visible above float baseline** |
| Chirp-cancel equivalence | Compare raw-sample SC vs dechirped SC | Identical `sc_lock`, `timing_ref`, `c_j` values |
| 8-bit saturation | Strong signal clipped to ±127 at SRAM write | `sc_lock` still asserts; no wrap-around corruption |
| C_pool diagnostic | Known channel, known CFO | `cfo_diag` within ±1 bin of true CFO |
| Hit-count sweep | `SC_HITS_REQ = 1, 2, 3` | Lock latency and false-alarm match expectation |
| Accumulator overflow | Max-amplitude input, M=64 | No overflow in int32 accumulators; int64 headroom confirmed |

---

## Open items

**Simulate SC false-alarm rate with 8-bit quantised inputs at SF6.** The 8-bit quantisation decision was validated for the training accumulator path but SC detection performance with 8-bit SRAM samples has not been simulated. The concern is the noise-noise cross-product term `q[n]·q*[n-M]` in the autocorrelation — for i.i.d. quantisation errors this has zero mean but could shift the false-alarm floor relative to the float model, particularly at SF6 where M=64 provides the least averaging. Simulate:
- 10,000 noise-only windows at SF6 (M=64), 8-bit quantised vs float
- Compare false-alarm rate at θ_SC = 0.90 and 0.75
- Pass criterion: false-alarm rate difference < 0.01%; if larger, raise threshold or add SF6-specific `SC_HITS_REQ=3` recommendation

This should be included in the GNU Radio sweep alongside the BER validation in the ΣΔ Decimator spec.

---

## Related Blocks

- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) — provides `current_j`, `delayed_j`, `delayed_valid`
- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides `iq_valid`
- [Packet Control FSM](Packet%20Control%20FSM.md) — receives `sc_lock`, `timing_ref`; manages packet phase
- [Register Map](../Register%20Map.md) — `SC_THR`, `SC_HITS_REQ`, `SC_STAT`, `C_POOL`, `CFO_DIAG` registers
