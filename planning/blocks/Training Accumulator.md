# Training Accumulator

RX path block (non-FFT frontend). See [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) for context.

**Owner:** TBD
**Status:** Updated — all-pairs cross-correlator with Z_kl pairs, Z_kk diagonal, noise mode

---

## Role

Estimates one complex channel coefficient per receive branch by cross-correlating preamble samples against a nominated reference antenna. The output `Z_j` feeds weight generation directly — no FFT, no chirp LUT, no SRAM access required.

The LoRa preamble upchirps are used as the training sequence. Their constant amplitude means CFO cancels exactly in the cross-product.

---

## How it works

During the preamble, branch `j` receives:

```
rx_j[n] = h_j · s[n] + noise_j
```

where `s[n] = upchirp[n mod M] · exp(j·ω·n)` is the CFO-shifted upchirp and `ω` is the common CFO across all branches.

Cross-correlating branch `j` against the nominated reference branch `r`:

```
Z_j = Σ_n rx_j[n] · conj(rx_r[n])
    ≈ h_j · conj(h_r) · N_acc · Σ|s[n]|² / N_acc  +  noise
    = h_j · conj(h_r) · N_acc  +  noise
```

Because `|s[n]|² = 1` (constant-amplitude chirp), the CFO term `exp(j·ω·n)` cancels exactly in the product — **no CFO correction is needed at any CFO value**, including the ±8.9-bin worst case at ±20 ppm / 868 MHz / SF6.

### MRC combining from cross-correlation estimates

Setting `w_j = conj(Z_j)` and combining:

```
y[n] = Σ_j conj(Z_j) · rx_j[n]
     = h_r · Σ_j |h_j|² · s[n]  +  noise
```

The combining gain is `Σ_j |h_j|²` — full MRC gain. The `h_r` phase factor is a common rotation that the SX1302 handles downstream.

### Why the chirp-ref approach has a CFO nulling problem

The previous chirp-ref approach (`Z_j = Σ rx_j[n] · conj(chirp_ref[n mod M])`) produces a Dirichlet-kernel attenuation proportional to `|sin(π·ε·N_acc/M)| / |sin(π·ε/M)|`. At integer-bin CFO with `N_acc = k·M`, this collapses to zero. At SF6/125 kHz, the first null occurs at just 390 Hz (0.45 ppm). The cross-correlation approach has no such nulls.

---

## Reference branch selection

The reference branch is selected by the 2-bit register field `TACC_REF_SEL[1:0]`:

| `TACC_REF_SEL` | Reference branch |
|---|---|
| `00` | Branch 0 (default) |
| `01` | Branch 1 |
| `10` | Branch 2 |
| `11` | Branch 3 |

**Default is branch 0.** This is adequate for most deployments. The register allows the host or PicoRV32 to redirect the reference to a known-good antenna during bring-up, or to work around a hardware fault on branch 0.

The reference branch contributes noise to all other estimates via the cross-product. The strongest branch should be preferred as reference. Automatic reference selection (using per-branch energy) was considered but deferred: it would require running all 4×4 cross-correlators simultaneously to avoid a sequencing conflict with the energy detector window. A static register is the practical baseline.

### Effect of a weak reference

If the reference branch is in a fading null (`|h_r| ≈ 0`), all `Z_j` are noise-dominated and combining weights are poor. In a 4-branch independent Rayleigh channel the probability all branches are simultaneously weak is low, and the default branch 0 reference is adequate for almost all cases. If branch 0 has a persistent fault, `TACC_REF_SEL` redirects without firmware change.

---

## Recovering absolute channel magnitudes via E_ref

Cross-correlation gives only relative estimates `Z_j ≈ h_j · conj(h_r) · N_acc`. This means:

- Per-branch `|h_j|` is not directly available
- Fading status, per-antenna link quality, EMA smoothing across packets, and ALMMSE all require absolute magnitudes
- Host telemetry registers exporting `Z_j_scaled` would carry only relative values without further context

**Fix: accumulate reference branch energy over the same window.**

In parallel with the cross-correlation accumulators, accumulate the squared magnitude of the reference branch:

```
E_ref = Σ_n |rx_r[n]|²  ≈  (|h_r|² + N0) · N_acc
```

This is a single real int64 accumulator — no extra multiplier hardware (the reference branch samples are already present in the cross-multiply datapath).

At moderate-to-high SNR (`|h_r|² >> N0`):

```
|h_r|²  ≈  E_ref / N_acc

|h_j|²  ≈  |Z_j|² / (E_ref · N_acc)
```

The second identity follows from `|Z_j| ≈ |h_j| · |h_r| · N_acc`, so `|Z_j|² / (E_ref · N_acc) ≈ |h_j|² · |h_r|² · N_acc² / (|h_r|² · N_acc · N_acc) = |h_j|²`.

**What this restores:**

| Feature | Without E_ref | With E_ref |
|---|---|---|
| Per-branch `\|h_j\|` | ✗ relative only | ✓ absolute |
| Fading status / link quality | ✗ | ✓ |
| EMA smoothing across packets | ✗ drifts with `\|h_r\|` | ✓ stable absolute energy |
| Host telemetry per branch | ✗ meaningless without context | ✓ |
| ALMMSE | ✗ | ✓ (combined with N0 estimate) |

**N0 bias.** `E_ref` overestimates `|h_r|²` by `N0 · N_acc`. At low SNR this inflates the denominator, causing `|h_j|²` to be underestimated. For telemetry and EMA this bias is acceptable. For ALMMSE a separate N0 estimate (e.g. from a noise-only window before the preamble) would be needed to debias.

`E_ref` is exported as an additional output port and readable by PicoRV32 via the register map alongside `Z_j_scaled`.

---

## Timing and arming

SC lock fires approximately `(SC_HITS_REQ + 1) · M` samples after the preamble start (symbol 0). At that point, `timing_ref` is back-calculated to symbol 0.

The training accumulator is **armed on `sc_lock`**. It always starts from the current sample (lock time), but the accumulation end point depends on whether the packet is being processed in the baseline live path or in the optional PSRAM replay path.

### Baseline live path (`PSRAM_EN = 0`)

In the baseline path, weights must be ready before the live payload reaches the combiner. The accumulator therefore stops at the end of the configured preamble:

```
acc_start  = sc_lock_sample
acc_end    = timing_ref + PREAMBLE_LEN·M - 1
N_acc      = acc_end - acc_start + 1
           ≈ (PREAMBLE_LEN - SC_HITS_REQ - 1) · M
```

With the default `PREAMBLE_LEN = 8`, `SC_HITS_REQ = 2`, and SF6 (M=64):

```
N_acc ≈ 5 · 64 = 320 samples
```

This is the existing next-packet / live-same-packet timing model: stop at preamble end so `training_done` leaves the full sync/SFD interval available for weight commit before the payload.

### PSRAM replay path (`PSRAM_EN = 1`)

In the PSRAM path, SX1302 sees zeros during BUFFERING and the buffered packet is replayed only after `W_commit`. There is therefore no requirement for `training_done` to occur before the **live** payload boundary. The accumulator may extend beyond the preamble and use a larger portion of the packet:

```
acc_start  = sc_lock_sample
acc_end    = packet_end_estimate - TACC_GUARD
N_acc      = acc_end - acc_start + 1
```

where `TACC_GUARD` is a small programmable margin reserved for:

- final accumulator latch / `training_done`
- weight-generation latency
- replay-control switching before `packet_end`

This mode exploits the branch-to-branch cross-correlation property

```
Z_j = Σ_n rx_j[n] · conj(rx_r[n])  ≈  h_j · conj(h_r) · Σ_n |s[n]|²
```

which does not require chirp-template alignment and remains valid over any packet region where:

- both branches observe the same transmitted samples
- the channel is approximately constant over the accumulation window

For the target deployment (`SF6`/`SF7` only), that constant-channel assumption is considered reasonable over a packet.

`training_done` asserts when the sample counter reaches `acc_end`.

### Known limitation: early preamble symbols are missed

Symbols 0 through `SC_HITS_REQ` (approximately the first 2–3 symbols) have passed before `sc_lock` asserts and cannot be accumulated. In the baseline live path, the training gain is therefore:

```
10 · log10(N_acc / 8M)  ≈  −2 dB   (for SC_HITS_REQ = 2, SF6)
```

This is acceptable for the baseline implementation. In PSRAM mode the same early-symbol loss still occurs, but it can be offset by extending the accumulation window beyond the preamble.

---

## Accumulator arithmetic

Input samples are **8-bit signed** from the decimator (**not** the SRAM-stored samples — both are 8-bit in this design, but the training accumulator reads the live decimator path, not SRAM).

The cross-product `rx_j[n] · conj(rx_r[n])` produces:

| Quantity | Value | Type |
|---|---|---|
| Sample I or Q | ±127 | int8 |
| Cross-product component | ±2 × 127² ≈ 32K | int16 (fits int32) |
| Z_j component (sum over ~640) | ≈ ±21M | fits int32 (max ±2.1G) |

**Use 31-bit internal accumulators (32-bit output ports).** The accumulation window is 8×M samples (not N_acc). At SF12, 8×4096×2×127² = 1057M < 2^30 — fits in 31-bit signed (max ±1073M). int32 output ports are zero-padded from 31-bit internal values.

> **Note:** At SF12 with 8×M=32768 samples the true maximum overflow boundary is 2^30, not 2^31. int32 with sign bit has range ±2^31 which covers this, but the RTL uses 31-bit internal accumulators to save adder width.

Total internal register cost: 4 branches × 2 components (I, Q) × 31 bits ≈ **31 bytes**.

Total register cost: 4 branches × 2 components (I, Q) × 64 bits = **64 bytes**.

The reference branch samples `rx_r[n]` must be buffered for one clock cycle so all four cross-multipliers read the same sample. A single 2×W-bit register per component suffices.

---

## Interface

| Port | Dir | Width | Rate | Description |
|---|---|---|---|---|
| `clk` | in | 1 | 16 MHz | System clock |
| `rst_n` | in | 1 | — | Active-low reset |
| `iq_valid` | in | 1 | f_s | Sample strobe |
| `raw_j[3:0]` | in | 4×2×8 | f_s | DC-removed samples from decimator (8-bit signed per I/Q component) |
| `sc_lock` | in | 1 | per packet | Arms the accumulator |
| `timing_ref` | in | 32 | per packet | Preamble-start sample index; defines `acc_end` in baseline live mode |
| `packet_end_estimate` | in | 32 | per packet | Latest allowed accumulation boundary for PSRAM replay mode |
| `sf` | in | 3 | static | Spreading factor; sets M = 2^SF |
| `ref_sel` | in | 2 | static | Reference branch index from `TACC_REF_SEL` register |
| `psram_en` | in | 1 | static | 0 = baseline live path, 1 = extended PSRAM replay path |
| `Z_j[3:0]` | out | 4×2×32 | per packet | Complex cross-correlation estimates (int32 port, 31-bit internal signed per branch) |
| `E_ref` | out | 64 | per packet | Reference branch energy: `Σ\|rx_r[n]\|²` (int64 port, 31-bit internal). Used to recover absolute `\|h_j\|²`. |
| `training_done` | out | 1 | per packet | Asserts when accumulation is complete; triggers weight gen |
| `n_acc` | out | 10 | per packet | Number of samples accumulated (for weight gen normalisation) |

---

## Sub-blocks

1. **Reference branch mux**
   - Selects `rx_r[n]` from `raw_j[ref_sel]`
   - Output registered to align timing with other branches

2. **Complex cross-multiplier array**
   - `d_j[n] = raw_j[n] · conj(rx_r[n])` per branch (4 parallel instances)
   - For `j == ref_sel`: `d_j = |rx_r[n]|²` (real — auto-correlation of reference)
   - Operates on full-precision input samples; no LUT required

3. **Accumulator array**
   - 4 × complex int64 registers (`Z_j[0..3]`)
   - 1 × real int64 register (`E_ref`) — reference branch energy `Σ|rx_r[n]|²`
   - Reset on `sc_lock`
   - `Z_j += d_j` and `E_ref += |rx_r[n]|²` every `iq_valid` while accumulator is active
   - `E_ref` shares the reference branch sample already buffered for the cross-multipliers — no extra memory reads

4. **Window controller**
   - Tracks `acc_start` (latched at `sc_lock`)
   - Computes `acc_end` from the active packet path:
     - baseline live path: `timing_ref + PREAMBLE_LEN·M - 1`
     - PSRAM replay path: `packet_end_estimate - TACC_GUARD`
   - Gates accumulator enable between these bounds
   - Asserts `training_done` and latches `n_acc` when `acc_end` is reached

---

## Operating sequence

```
1. sc_lock asserts at sample N_lock.
2. acc_start = N_lock.
3. acc_end is selected by mode:
   - baseline live path: `timing_ref + PREAMBLE_LEN·M - 1`
   - PSRAM replay path: `packet_end_estimate - TACC_GUARD`
4. Accumulator resets: Z_j[0..3] = 0.
5. Reference branch latched from raw_j[ref_sel].
6. Each iq_valid: d_j = raw_j[j] · conj(rx_r); Z_j += d_j.
7. At sample acc_end: training_done asserts. Z_j and n_acc are latched.
8. Weight gen reads Z_j[0..3] and computes W = conj(Z_j) / S.
9. Accumulator idles until next sc_lock.
```

---

## Verification

| Test | Method | Pass criterion |
|---|---|---|
| Noiseless single-path | Known h_j, no noise, SF6 | `Z_j / n_acc` matches `h_j · conj(h_ref)` within rounding |
| CFO immunity — small | Inject ε = ±0.3 bins | Weight magnitudes identical to zero-CFO case |
| CFO immunity — large | Inject ε = ±8.9 bins (±20 ppm / SF6) | Weight magnitudes identical to zero-CFO case; no Dirichlet attenuation |
| CFO immunity — integer bin | Inject ε = ±1, ±2, … bins | No combining gain collapse; Z_j magnitude unaffected |
| Accumulation window, baseline mode | Check sample count | `n_acc ≈ (PREAMBLE_LEN - SC_HITS_REQ - 1) · M` |
| Accumulation window, PSRAM mode | Extend `packet_end_estimate` over a packet | `n_acc` grows to `packet_end_estimate - sc_lock_sample - TACC_GUARD + 1` |
| Overflow check | Max-amplitude 8-bit input (±127) at N_acc=640 | Z_j component ≤ ±20.6M; no int32 overflow (100× headroom) |
| Multi-branch | NR=4, independent h_j per branch | Z_j = h_j · conj(h_ref) · n_acc for each j |
| Ref branch selection | Set ref_sel = 1, 2, 3 | Correct branch used as reference; other estimates rotate accordingly |
| Weak reference | h_ref ≈ 0 (deep null) | Z_j near zero; weight gen falls back gracefully (SC selects best remaining) |

---

## Timing risks

The training window is bounded by SC lock on one side and by the active-mode `acc_end` on the other. In the baseline live path this is the end of the configured preamble; in PSRAM mode it may extend later into the packet. Three conditions can compress or corrupt the useful window.

### 1. Late SC lock at low SNR

SC lock is not guaranteed at the first opportunity. At low SNR the Schmidl-Cox metric fluctuates below threshold for several symbol periods before consecutive hits accumulate. Simulation results at SF6, NR=4, `hits_req=2`, threshold=0.90:

| SNR | Lock rate | Effect on N_acc |
|---|---|---|
| 20 dB | 100% | Always locks at 3M; full 5-symbol training in baseline mode |
| 10 dB | 85% | Mean N_acc ≈ 5 symbols in baseline mode; ~1.4% of packets lock after 6M (< 2 symbols training) |
| 6 dB | ~24% | High miss rate; when lock occurs it is often late |
| ≤ 3 dB | < 1% | Essentially no lock |

Training loss vs lock delay (SF6, N_acc referenced to ideal 5-symbol window):

| Lock time | N_acc | Training loss |
|---|---|---|
| 3M (ideal) | 5M | 0 dB |
| 5M | 3M | −2.2 dB |
| 6M | 2M | −4.0 dB |
| 7M | 1M | −7.0 dB |
| 7.5M | 0.5M | −10.0 dB |

**Mitigation:** the hardware combiner falls back to bypass (`w^H x → sign_extend(x[bypass_sel])`) until `W_valid` asserts. A late lock produces degraded weights rather than a broken receiver — the SX1302 continues seeing a valid single-antenna stream. No explicit guard needed; the fallback path handles it automatically.

### 2. Short preamble

LoRa allows preamble lengths shorter than the default 8 upchirps (minimum configurable). In the baseline live path, if a transmitter uses a 6-symbol preamble, `acc_end = timing_ref + 6M − 1` and `N_acc ≤ 3M` even with an ideal early lock — a −2.2 dB training loss from the baseline. The live-path accumulator spec therefore needs `PREAMBLE_LEN` tracking. In PSRAM mode, this constraint is relaxed because accumulation may continue beyond the preamble if desired.

**Mitigation:** make `TACC_PREAMBLE_LEN` a configurable register (range 6–16 symbols) so baseline-mode `acc_end` tracks the actual preamble length rather than assuming 8. For the demo deployment, preamble length is set to 16 symbols, giving up to 13 symbols of training accumulation with `SC_HITS_REQ=2` — approximately +4 dB vs the 5-symbol baseline. In PSRAM mode, optionally replace the preamble-bounded stop with `packet_end_estimate - TACC_GUARD` to trade added latency for higher estimate SNR.

### 3. First-packet saturation at maximum gain

The AGC architecture prevents mid-training gain steps by design: new gain applies only at `safe_switch` (IDLE between packets), so training always accumulates under a fixed gain within a packet. There is no risk of a gain step corrupting `Z_j` mid-accumulation.

The real risk is the **first packet after power-on or after a large path-loss change**. The SX1257 starts at maximum gain (LNA_G1, BB_MAX). If the received signal is strong, decimated samples will saturate before the AGC has had a chance to step gain down. Saturated samples in training produce a `Z_j` whose magnitude does not reflect the true channel — the weights derived from it will be wrong.

The AGC fires at `CORR_LOCK` and queues a gain step to apply at the next IDLE boundary. The saturated first packet cannot be recovered, but the second packet runs at the corrected gain.

**Mitigation:** the combiner falls back to bypass until `W_valid` asserts. A corrupted `Z_j` from a saturated first packet produces poor weights; the Packet Control FSM will not assert `W_valid` if weight generation detects an anomaly (or if firmware rejects it). The second packet then produces clean training under the corrected gain. No explicit guard in the training accumulator is needed — the existing bypass fallback and next-packet weight application cover this case.

---

## Known Limitations

- **Early preamble symbols missed.** Approximately `(SC_HITS_REQ + 1)` preamble symbols are not accumulated. Training SNR is reduced by ~2 dB vs ideal (5 of 8 symbols with `SC_HITS_REQ = 2`).
- **Mode-dependent windowing.** The baseline live path intentionally constrains accumulation to the preamble so weights are ready before live payload. This is an architectural timing choice, not a mathematical requirement of the branch-reference estimator. When PSRAM replay is enabled, the accumulation window may be extended later into the packet.
- **Relative estimates only (combining).** `Z_j` estimates `h_j · conj(h_ref)`, not `h_j` independently. This is sufficient for MRC/EGC/SC combining. Absolute per-branch magnitude is recovered from `E_ref` — see Recovering absolute channel magnitudes. N0 bias in `E_ref` affects ALMMSE at low SNR; a separate noise-floor estimate is needed to debias for that use case.
- **Weak reference degrades all estimates.** If `h_ref ≈ 0`, all `Z_j` are noise-dominated. Mitigated by static `TACC_REF_SEL` pointing to the best-known antenna for the deployment.
- **Frontend-buffer limited, not accumulator-limited.** Accumulator register cost scales with NR only (not M). All SFs (SF6–SF12) are supported with the block-based fixed-L=256 frontend buffer using one 512×8 SRAM macro. ~~The CPU SRAM borrow path and NR=2 SF7 fallback are removed~~ — see Memory Strategy deprecation notice.
- **int32 accumulators sufficient.** With 8-bit inputs and N_acc up to 640 (16-symbol preamble), Z_j ≤ ±20.6M — well within int32 (±2.1G). ~100× headroom.

---

## Alternative: chirp-reference accumulation

The original design correlated against an internally generated chirp LUT:

```
Z_j = Σ raw_j[n] · conj(chirp_ref[n mod M])
```

This gives absolute `h_j` estimates but is susceptible to Dirichlet-kernel attenuation at large CFO. At ±20 ppm / 868 MHz / SF6 (±8.9 bins), accumulation over 5 complete symbols produces nulls whenever CFO crosses an integer bin boundary. The cross-correlation scheme above was adopted as the primary path because it is CFO-immune with no additional hardware cost (cross-multipliers replace the LUT multiply; the LUT itself is eliminated).

The chirp-ref path remains viable if absolute `h_j` is required for a future feature (e.g. ALMMSE, per-branch telemetry). It can be re-enabled by routing `chirp_ref[n mod M]` into the reference input of the cross-multiplier array in place of `raw_j[ref_sel]`.

---

## Area history

All figures: Yosys synthesis, `gf180mcu_as_sc_mcu7t3v3` TT/25°C/3.3 V, top-module total including `signed_mul8_pipe` instances.

| Version | Yosys area | Change | Notes |
|---------|-----------|--------|-------|
| Original (4 parallel multipliers per antenna cycle) | 211 k µm² | — | Baseline |
| Round 2: TDM — 1 antenna per cycle, 4 shared muls | 119 k µm² | −92 k | Standalone local-area figure; ~153 k total in hier context |
| Round 3: 4 muls → 2 muls, 2 sub-cycles per antenna | **132 k µm²** | **−21 k** | SGE job 1143; 4 × signed_mul8_pipe → 2 × signed_mul8_pipe |

### Round 3 changes (2026-06-01)

**4 multipliers → 2 multipliers** by splitting each antenna TDM state into two sub-cycles:

| Sub-cycle | mul_0 | mul_1 | Result |
|-----------|-------|-------|--------|
| 0 (zi) | `I_k × ref_i` | `Q_k × ref_q` | `zi_latch = mul_0 + mul_1` |
| 1 (zq) | `Q_k × ref_i` | `I_k × ref_q` | `zq = mul_0 − mul_1`; accumulate both |

State 5 (E\_ref = `ref_i² + ref_q²`) retains a single sub-cycle — both products are ready in one clock.

**Timing budget:**
- Active cycles per sample: 4 antennas × 2 sub-steps + 1 E_ref = 9
- Pipeline drain: 2 cycles
- Total: **11 cycles per sample**
- iq\_valid interval: ≥ 20 cycles — fits with 9-cycle margin

**Removed pipeline stage:** the `prod_zi_q / prod_zq_q / prod_state_q / prod_valid_q / prod_last_q` register bank (37 bits) is eliminated; zi and zq are accumulated directly from the pipeline output, with `zi_latch` (16-bit) bridging the two sub-cycles.

**Verified:** all 7 tb\_dsp\_chain self-checks pass (SGE job 1141).

---

## All-pairs cross-correlator (current RTL)

> **Note:** The RTL has been updated from the single-reference cross-correlator described above to an all-pairs accumulator. The role description and interface table below are superseded; see `rtl-test/rtl/training_acc.v` for the current implementation. This section documents the new architecture.

Instead of correlating each branch against a single nominated reference, `training_acc.v` now computes the full C(4,2)=6 branch-pair cross-correlations plus the 4 autocorrelation diagonals:

```
Z_kl = Σ_n raw_k[n] · conj(raw_l[n])   for all k < l   (6 complex pairs)
Z_kk = Σ_n |raw_k[n]|²                  for k=0..3      (4 real diagonals)
W_k  = Σ_{l≠k} Z_kl                     per branch       (useful firmware row-sum MRC seed)
```

This gives firmware access to the full 4×4 Hermitian channel covariance matrix Z ≈ h·h^H·n_acc + σ²·I, enabling a firmware eigenvector MRC path that is significantly better than the simple W_k row-sum approximation.

**Current RTL note (2026-06-10):** the active standalone `trouper_top` no longer retains or exports the legacy per-branch row-sum outputs `W_k` / `Z_i*` / `Z_q*`. Only `Zpair_*`, `Zdiag_*`, `training_done`, and `n_acc` remain live because the current combiner path is firmware-driven. The separate `noise_est` block was also removed; firmware-triggered `noise_trig` windows now reuse `training_acc` noise mode, and `sigma2_valid` is generated only when a completed noise window was not contaminated by `sc_hit_dbg` or `sc_lock`. This acceptance timing still needs further directed verification.

### New register outputs (current RTL)

All Z_kl pair readbacks are the top 24 bits [31:8] of the signed int32 accumulators (3 bytes per component, big-endian) under the 7-bit register-map constraint — see `planning/Register Map.md`.

| Registers | Address | Content |
|-----------|---------|---------|
| Z_01 I/Q | 0x40–0x45 | Zpair_i0, Zpair_q0 [31:8] |
| Z_02 I/Q | 0x46–0x4B | Zpair_i1, Zpair_q1 [31:8] |
| Z_03 I/Q | 0x4C–0x51 | Zpair_i2, Zpair_q2 [31:8] |
| Z_12 I/Q | 0x52–0x57 | Zpair_i3, Zpair_q3 [31:8] |
| Z_13 I/Q | 0x58–0x5D | Zpair_i4, Zpair_q4 [31:8] |
| Z_23 I/Q | 0x5E–0x63 | Zpair_i5, Zpair_q5 [31:8] (via sigma2_hw repurpose) |
| Zdiag top-16 | 0x64–0x6B | Zdiag_0..3 [31:16] |
| TACC_NOISE_TRIG | 0x1F[0] | W1P — arms accumulator without sc_lock |

### Noise mode

Writing 1 to TACC_NOISE_TRIG (0x1F[0]) arms the accumulator without waiting for sc_lock, accumulating for 8 symbols. During this window (no signal): Z_kl ≈ 0 for k≠l, and Z_kk ≈ σ²_k · n_acc. The diagonal readback at 0x64–0x6B therefore gives per-branch noise power, which firmware can use for noise-whitened eigenvector combining (subtract σ²·n_acc·I from Z before eigendecomposition).

### Combining method performance (SF=7, NR=4, 2000 packets/point)

| SNR | Oracle MRC | Eigvec PSRAM (50-sym payload) | Eigvec preamble-only | W_k HW |
|-----|-----------|------------------------------|---------------------|--------|
| −16 dB | 13.4% | 17.6% | 30.9% | 60.1% |
| −14 dB | 4.9% | 6.6% | 14.0% | 45.5% |
| −12 dB | 1.4% | 2.1% | 3.7% | 28.9% |
| −10 dB | 0.4% | **0.4%** | 0.9% | 20.3% |
| −8 dB | ~0% | ~0% | 0.2% | 12.8% |

Key findings:
- Increasing weight precision beyond Q1.15 gives **zero improvement** — the gap to oracle is entirely channel estimation noise, not quantization.
- PSRAM accumulation (7.2× more samples: preamble + 50 payload symbols) closes 1–4 dB of the estimation gap; matches oracle at −10 dB.
- Noise whitening (subtract σ²·I before eigdecomp) adds no additional benefit at this accumulation depth — the bias is negligible with 7424 samples.
- W_k row-sum (HW path) is 10–20 dB worse than eigvec in the target SNR range; the eigvec FW path is strongly preferred for any deployment where firmware is available.

Source: `sim/sims/compare_mrc_methods.py` (SGE jobs 1368–1371).

---

## Related Blocks

- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) — holds rolling sample history; training accumulator reads from the decimator directly, not from SRAM
- [Correlator Bank (SC)](Correlator%20Bank.md) — provides `sc_lock`, `timing_ref`
- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides `raw_j` and `iq_valid`
- [Weight Generation](Weight%20Generation.md) — historical block note; current tapeout uses firmware-only weight generation
- Register Map — `TACC_REF_SEL[1:0]` field selects reference branch
