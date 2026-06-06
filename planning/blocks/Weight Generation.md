# Weight Generation

RX path block (non-FFT frontend). See [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) for context.

**Owner:** TBD
**Status:** Updated — dual hardware/software path

---

## Role

Converts the complex channel estimates `Z_j` from the training accumulator into combining weights `W`, writes them to `W_SHADOW`, and triggers commit to `W_ACTIVE`.

Two parallel paths produce weights:

- **Hardware path** — a hardened RTL state machine that computes SC or approximate shift-MRC weights from `Z_j` with deterministic latency. Enables same-packet weight application.
- **Software path** — PicoRV32 firmware reads `Z_j` from registers, computes any weight formula (ALMMSE, EMA-smoothed, custom), and writes `W_SHADOW` directly. Existing next-packet commit mechanism applies.

A single register bit (`WGT_SRC`) selects which path commits to `W_ACTIVE`. Firmware can inspect the hardware-computed result at any time via read-only `W_HW` registers, regardless of which path is active.

### Reset-default policy

For CPU-less RX-only operation, the reset defaults for this block must select a complete hardware path:

- `WGT_SRC = AUTO`
- `WGT_AUTO_COMMIT = 1`
- `WGT_MODE = MRC`

With those defaults, `training_done` is sufficient to produce committed `W_ACTIVE` weights without any firmware servicing.

---

## Combining modes

| Mode | Weights | Computed by |
|---|---|---|
| Bypass | 1 on lowest enabled antenna, 0 elsewhere | Immediate (no arithmetic) |
| SC | 1 on max-power branch, 0 elsewhere | Hardware or software |
| MRC | Conjugate h_j scaled by a conservative shared power-of-two shift | Hardware or software |
| ALMMSE | Matrix inversion: W = (H·H^H + λI)^{-1}·H^H | Software only (PicoRV32) |

EGC is not implemented in hardware. See [Future extensions](#future-extensions).

---

## Dual-path architecture

```
Training Accumulator
   Z_j[3:0] (int32 port, 31-bit internal), n_acc, sf, training_done
        |
        v
 ┌──────────────────────┐   W_HW[3:0]  ──────► read-only registers
 │  Hardware Weight Gen │   (Q1.15)             (firmware can read or copy)
 │  FSM + shift scaler  │─────────────────────────────────────┐
 └──────────────────────┘                                     │
                                                              │  WGT_SRC = AUTO
        |  training_done IRQ                                  │
        v                                                     │
   PicoRV32 firmware                                          │
   (ALMMSE, EMA, custom)                                      │
        │                                                     │
        └──────── write W_SHADOW ◄────────────────────────────┘
                       │              WGT_SRC = SW: firmware writes
                       │              WGT_SRC = AUTO: hardware writes
                       ▼
                  W_COMMIT (auto or manual pulse)
                       │
                       ▼
                  W_ACTIVE  ──►  Combiner MAC
```

### Register control bits (`WGT_CTRL`, address `0x35`)

| Bit(s) | Field | Values | Description |
|---|---|---|---|
| 0 | `WGT_SRC` | 0=AUTO, 1=SW | Selects which path writes W_SHADOW and commits. AUTO: hardware FSM. SW: PicoRV32. |
| 1 | `WGT_AUTO_COMMIT` | 0/1 | When `WGT_SRC=AUTO`: 1 = hardware commits W_HW → W_ACTIVE immediately on completion (same-packet). 0 = hardware writes W_HW but waits for firmware W_COMMIT pulse. |
| 3:2 | `WGT_MODE` | 00=bypass, 01=SC, 10=reserved, 11=MRC | Combining formula used by the hardware path. Ignored when `WGT_SRC=SW`. Value 10 is reserved for a future EGC extension. |
| 4 | `W_COMMIT` | write-1 pulse | Shared commit request into the Packet Control FSM after W_SHADOW has been fully written. |
| 5 | `W_VALID` | read-only | Active W bank is valid. |
| 6 | `W_PENDING` | read-only | A commit has been requested but not yet activated at `safe_switch`. |
| 7 | `W_MISSED_PACKET` | read-only | Commit arrived too late for the current packet payload window. |

Recommended reset value for `WGT_CTRL`: `0b00001110`

- `WGT_SRC=0` (`AUTO`)
- `WGT_AUTO_COMMIT=1`
- `WGT_MODE=11` (`MRC`)

In other words, `0x35` is not only a mode register. It is the authoritative software-visible handshake point between Weight Generation and the Packet Control FSM.

### W_HW registers

Read-only. The hardware FSM always writes its computed result here regardless of `WGT_SRC`. Firmware can read W_HW for:
- Inspection / diagnostics
- EMA smoothing: read W_HW, compute smoothed version, write back to W_SHADOW in SW mode

Layout: 4 branches × 2 words (I, Q) × int16 Q1.15 = 8 × 16-bit registers.

---

## Input normalisation

The training accumulator outputs `Z_j` (32-bit port, 31-bit internal signed) and `n_acc`. The hardware path receives `sf` (spreading factor) as an additional input.

Before calibration, `Z_j` is right-shifted by `sf` bits to normalise across SF7–SF12:

```
H_j = Z_j >>> sf
```

`Z_j` accumulates over 8×M samples, where M=2^sf. At SF12, max|Z_j| ≈ 1057M < 2^30; after shifting right by sf=12, max|H_j| ≈ 258k < 2^18. This gives a consistent 18-bit range for all SFs with no per-packet K computation required.

> **Implementation note:** The previous K-based normalisation (`K` derived from leading-zero count, K_wire from n_acc) has been removed. The SF shift replaces it entirely and is correct for all supported SFs.

---

## Calibration

Static per-branch gain and phase mismatch correction applied before weight computation:

```
H_j_cal = H_j · conj(cal_j)
```

`cal_j` are complex Q1.15 coefficients stored in a register bank (default 1+0j — no correction). Written by host or firmware via SPI; static across packets.

---

## Hardware path — weight computation by mode

### Bypass

```
w_j = 1  for j = lowest set bit of ANTENNA_EN
w_j = 0  otherwise
```

No arithmetic. Completes in 1 cycle.

### SC — Selection Combining

```
j_best = argmax_j |H_j_cal|²
w_j    = 1  if j == j_best,  else  0
```

Four magnitude-squared computations, 4-way compare. ~4 cycles.

### MRC — Shift-Based Maximum Ratio Combining

```
peak       = max_j(|H_j_cal.I|, |H_j_cal.Q|)
base_shift = max(0, floor(log2(peak)) - 14)
headroom   = ceil_log2(number_of_enabled_antennas)   // 0, 1, or 2 for NR<=4
mrc_shift  = base_shift + headroom
w_j        = conj(H_j_cal) >>> mrc_shift
```

This preserves the MRC branch ratios and conjugate phases while replacing exact division by a shared power-of-two scale. The `headroom` term is deliberately conservative: it leaves room for coherent addition of 2 or 4 strong branches and avoids relying on post-combine saturation as the normal operating point.

The exact normalized form,

```
w_j = conj(H_j_cal) / Σ_k |H_k_cal|²
```

remains available in firmware/software simulations, but it is not hardened in the AUTO hardware path.

Implementation:

1. For each enabled branch, compute an approximate selection metric `|I| + |Q|` for SC and a peak component for MRC scaling.
2. Track the maximum peak component across enabled branches.
3. Compute `mrc_shift = base_shift + branch_headroom`.
4. Emit rounded `conj(H_j_cal) >>> mrc_shift`, saturating to int16 Q1.15.

Total hardware latency: ~16 cycles from `training_done` to `W_COMMIT` in RTL chain simulation.

### ALMMSE

Not implemented in hardware. Requires matrix inversion for a 4×2 system — complexity disproportionate to the hardware budget. Firmware (PicoRV32) handles this via the SW path. `WGT_SRC` must be set to SW when using ALMMSE.

---

## Hardware FSM state sequence

```
IDLE
  ↓  training_done asserts
SHIFT          — compute K, right-shift Z_j → H_j   (~4 cycles)
  ↓
CALIBRATE      — H_j_cal = H_j · conj(cal_j)         (~8 cycles, 4 complex muls)
  ↓
COMPUTE        — mode-dependent metric/shift compute  (~5 cycles)
  ↓
SCALE          — round to Q1.15, saturate            (~2 cycles)
  ↓
WRITE          — write W_HW[3:0]; if WGT_AUTO_COMMIT: write W_SHADOW, pulse W_COMMIT
  ↓
IDLE
```

Total hardware latency from `training_done` to `W_COMMIT`: ~13–16 cycles in the current RTL chain simulations (under 1 µs at 16 MHz). Removing the reciprocal/divider path also removes the previous long arithmetic timing path.

---

## Output scaling to Q1.15

All modes output int16 Q1.15 (range ±1.0, i.e. ±32767):

```
w_j_Q15 = round(w_j · 2^15)   clamped to ±32767
```

For hardware MRC, scaling is conservative rather than exact unit-norm. The shared shift preserves relative branch weights, and the branch-count headroom limits worst-case coherent addition. Final amplitude is adjusted by the combiner post-gain register (`COMB_POST_GAIN`, address `0x36`).

### Why the hardware path avoids division

A trial LibreLane physical-design run of the exact reciprocal/divide MRC implementation at the 16 MHz block clock showed post-CTS setup slack around -150 ns, far outside the 62.5 ns cycle. The issue was architectural, not placement tuning: exact normalization introduced wide reciprocal state and a 32×64 scale multiply on the weight path.

The shift-MRC implementation keeps the important part of MRC, `w_j ∝ conj(H_j)`, while moving absolute gain control to cheap shifts and saturation. A quick generic Yosys comparison for `weight_gen` dropped from 32,799 cells for the reciprocal version to 17,516 cells for shift-MRC. This is the tapeout-oriented hardware path; exact normalized MRC remains a software/oracle model for analysis.

---

## W_SHADOW write and commit

After weights are computed, both paths write to `W_SHADOW` and pulse `W_COMMIT`:

```
W_SHADOW[j].I = w_j_Q15.I   for j = 0..3
W_SHADOW[j].Q = w_j_Q15.Q
W_COMMIT       = 1           (one cycle pulse)
```

The Packet Control FSM copies `W_SHADOW` → `W_ACTIVE` at the next `safe_switch` boundary.

### Same-packet vs next-packet

| `WGT_AUTO_COMMIT` | Behaviour |
|---|---|
| 1 | Hardware commits immediately when WRITE state completes. Weights may become active before the payload starts — **same-packet application** if the hardware latency (~40 cycles) fits before the payload window (see Timing section). |
| 0 | Hardware writes W_HW, raises `wgen_hw_done` interrupt. Firmware can inspect W_HW, optionally modify, then pulse W_COMMIT manually. Effectively next-packet (firmware scheduling adds latency). |

If `W_COMMIT` fires while a packet is active, the Packet Control FSM defers activation to the next idle boundary and sets `W_MISSED_PACKET`. This is expected next-packet behaviour, not an error.

---

## Timing

### LoRa packet structure and payload start

The payload start sample is determined by the standard LoRa air-frame structure following the preamble:

```
timing_ref (preamble symbol 0)
  │
  ├─  8M   upchirp preamble (symbols 0–7)
  ├─  2M   downchirp sync word
  ├─  0.25M  quarter-upchirp SFD marker
  └─  2M   network sync upchirps
                                    ──────────────────────
  total pre-payload:  12.25M        payload starts at timing_ref + 12.25M
```

This is fixed for a standard LoRa explicit-mode packet and is independent of SF or BW — the 12.25-symbol overhead scales with M.

For the demo deployment (16-symbol preamble), the pre-payload overhead becomes 16 + 4.25 = 20.25M.

### Same-packet weight commit window

This section describes the **baseline live path** (`PSRAM_EN = 0`) only.

`training_done` fires at `timing_ref + 8M − 1` (end of the 8-symbol preamble). For weights to apply to the **current** packet's payload in the baseline live path, `W_COMMIT` must fire and `W_ACTIVE` must be updated before the combiner processes `timing_ref + 12.25M`.

```
sc_lock
  ↓
Training accumulator collects preamble (5 of 8 symbols with SC_HITS_REQ=2)
  ↓  training_done  (at timing_ref + 8M − 1 samples)
Hardware FSM: ~50 cycles → W_COMMIT
  ↓  [4.25M sample window]
Payload starts at timing_ref + 12.25M samples
```

At SF6 (M=64, f_s = 125 kS/s, 128 clock cycles/sample at 16 MHz):

```
training_done    =  timing_ref + 512 samples   =  65,536 cycles from preamble start
payload start    =  timing_ref + 784 samples   =  100,352 cycles from preamble start

commit window    =  272 samples  =  34,816 cycles  ≈  2.2 ms
```

| Path | Latency | Margin (cycles) | Margin (×) |
|---|---|---|---|
| Hardware FSM | ~40 cycles | ~34,776 | ~869× |
| Software (PicoRV32) | ~1,000–5,000 cycles | ~30,000–34,000 | ~7–30× |
| Demo (16-symbol preamble) | ~5,000 cycles | ~100,000 | ~20× |

The margin is the time available for weight computation in the baseline live path. Missing the window is not fatal: the Packet Control FSM sets `W_MISSED_PACKET` and activates the new weights at the next `safe_switch` (next packet idle boundary). The combiner uses the previous packet's weights or bypass for the current payload.

When `PSRAM_EN = 1`, this live-payload deadline is replaced by the replay deadline: `W_COMMIT` must arrive before `packet_end` so the controller can begin replay of the buffered packet.

---

## Interface

| Port | Dir | Width | Rate | Description |
|---|---|---|---|---|
| `clk` | in | 1 | 16 MHz | System clock |
| `rst_n` | in | 1 | — | Active-low reset |
| `training_done` | in | 1 | per packet | Trigger from training accumulator |
| `Z_j[3:0]` | in | 4×2×32 | per packet | Complex channel estimates (int32 port, 31-bit internal signed per branch) |
| `n_acc` | in | 10 | per packet | Number of samples in Z_j (informational for firmware; hardware uses `sf` for normalisation) |
| `sf` | in | 4 | static | Spreading factor (6–12); used for Z_j SF-normalisation shift |
| `wgt_src` | in | 1 | static | 0=hardware auto, 1=software override; from `WGT_CTRL[0]` |
| `wgt_auto_commit` | in | 1 | static | 1=hardware auto-commits; from `WGT_CTRL[1]` |
| `wgt_mode` | in | 2 | static | Hardware combining mode: 00=bypass, 01=SC, 10=reserved, 11=MRC; from `WGT_CTRL[3:2]` |
| `antenna_en` | in | 4 | static | Enabled branch mask |
| `cal_j[3:0]` | in | 4×2×16 | static | Calibration coefficients (Q1.15 I+Q per branch, default 1+0j) |
| `W_hw[3:0]` | out | 4×2×16 | per packet | Hardware-computed weights (Q1.15 I+Q); always written by hardware FSM; exported to read-only `W_HW` registers |
| `W_shadow[3:0]` | out | 4×2×16 | per packet | Weights to W_SHADOW bank (from hardware or firmware depending on WGT_SRC) |
| `W_commit` | out | 1 | per packet | One-cycle strobe to Packet Control FSM |
| `wgen_hw_done` | out | 1 | per packet | Hardware FSM completed; W_HW is valid; IRQ source for firmware |
| `wgen_active` | out | 1 | per packet | Weight computation in progress (hardware FSM running) |
| `wgen_mode_dbg` | out | 2 | per packet | Combining mode used for the current W |

---

## Sub-blocks

1. **Shift normaliser**
   - Finds leading-zero count of max component across all branches
   - Right-shifts all Z_j by `sf` bits → H_j fits 18-bit range for all SF7–SF12

2. **Calibration multiplier**
   - 4 × complex multiply: H_j_cal = H_j · conj(cal_j)
   - Q1.15 calibration coefficients; result kept in int32

3. **MRC shift scaler**
   - Tracks peak calibrated I/Q component across enabled branches
   - Adds branch-count headroom: 0 for one branch, 1 for two branches, 2 for three/four branches
   - Emits rounded `conj(H_j_cal) >>> mrc_shift`

4. **SC comparator**
   - 4 × magnitude-squared, 4-way maximum selector
   - Integer logic only; no division

5. **Output scaler and saturator**
   - Rounds to int16 Q1.15; saturates to ±32767

6. **FSM controller**
   - Sequences SHIFT → CALIBRATE → COMPUTE → SCALE → WRITE states
   - Gated by wgt_src (hardware path only active when WGT_SRC=AUTO)
   - Raises wgen_hw_done; auto-commits if WGT_AUTO_COMMIT=1

---

## Parameters

| Parameter | Value | Notes |
|---|---|---|
| `NR` | 4 | Number of receive branches |
| `W_OUT_BITS` | 16 | Q1.15 output width |
| `MRC_BRANCH_HEADROOM` | enabled-count based | 0/1/2 bit coherent-add guard for 1/2/3-4 enabled branches |

---

## Verification

| Test | Method | Pass criterion |
|---|---|---|
| MRC noiseless | Known h_j, exact Z_j | w_j has phase `-angle(H_j_cal)` and preserves branch magnitude ratios after shared shift |
| SC noiseless | One strong branch | w_j = 1 on correct branch, 0 elsewhere |
| Bypass | Any input | w_j = 1 on lowest enabled antenna |
| Calibration | Load non-unity cal_j | H_j_cal = H_j · conj(cal_j) before weight compute |
| HW auto-commit | WGT_SRC=0, WGT_AUTO_COMMIT=1 | W_COMMIT fires within 60 cycles of training_done; W_HW matches W_SHADOW |
| SW override | WGT_SRC=1; firmware writes W_SHADOW | W_HW still updated by hardware FSM; W_SHADOW reflects firmware values; W_COMMIT from firmware pulse only |
| EMA via W_HW | WGT_SRC=1; firmware reads W_HW, smooths, writes W_SHADOW | W_ACTIVE reflects EMA-smoothed weights, not raw hardware output |
| ALMMSE (SW) | WGT_SRC=1; firmware computes ALMMSE weights | W_SHADOW and W_ACTIVE contain ALMMSE weights; W_HW contains MRC result (diagnostic) |
| W_SHADOW write | Check register after wgen_active falls | All 8 half-words match expected Q1.15 values |
| W_COMMIT timing | Check FSM interaction | Packet Control FSM defers to next idle boundary if packet is active; W_MISSED_PACKET set |
| Shift normalisation | Z_j with large dynamic range | K computed correctly; no overflow in H_j after shift |
| All branches equal | \|Z_j\| identical for j=0..3 | MRC weights equal-magnitude across all branches |
| Same-packet margin, baseline live path | SF6, WGT_AUTO_COMMIT=1 | W_COMMIT fires before payload start (timing_ref + 12.25·M samples) |
| MRC shift scaling | Sweep peak and antenna_en | `mrc_shift = base_shift + branch_headroom`; disabled branches are zero |

---

## Known Limitations

- **ALMMSE is software-only.** Matrix inversion for a 4×2 system is not hardened. `WGT_SRC` must be SW for ALMMSE. The hardware FSM still runs and writes W_HW (MRC result) as a diagnostic.
- **No exact divide normalization in hardware path.** The hardware FSM uses proportional shift-MRC. Exact normalized MRC and NW-MRC are available via the SW path when firmware can spend the cycles.
- **No per-branch noise weighting in hardware path.** The hardware FSM uses an equal per-branch noise assumption. NW-MRC (`w_j = conj(Z_j) / σ²_j`) is available via the SW path using estimates from the Noise Floor Estimator block. See noise floor estimation section below.
- **Calibration is static.** Per-branch coefficients do not update at runtime. Temperature drift requires manual SPI recalibration.
- **EMA smoothing is firmware responsibility.** Hardware computes fresh per-packet weights only. Cross-packet smoothing (EMA) must be implemented in firmware using the W_HW readback path.
- **Same-packet application requires WGT_AUTO_COMMIT=1.** If firmware scheduling is delayed (e.g. busy with AGC), the hardware path fires deterministically but the software path may miss the payload window.

---

## Per-branch noise floor estimation

Per-branch noise power estimates `σ²_j` are produced by the **Noise Floor Estimator** RTL block. The block runs a per-branch EMA on idle symbol-window energies gated by the Packet Control FSM (`noise_sample_en`).

See [Noise Floor Estimator](Noise%20Floor%20Estimator.md) for the full block spec including interface, fixed-point format, and verification plan.

### How estimates reach the weight computation path

The active estimates `sigma2_active_j[0..3]` are driven by the NFE block onto a dedicated bus, selectable by `SIGMA2_SRC`:

- **`SIGMA2_SRC=HW`** (default): hardware EMA output — updated automatically each valid idle symbol
- **`SIGMA2_SRC=SW`**: firmware-supplied values via `SIGMA2_SHADOW` registers and `SIGMA2_COMMIT` strobe — same shadow/commit pattern as `W_SHADOW`/`W_COMMIT`

### NW-MRC weight formula (SW path)

Once `sigma2_active_j` is valid (`sigma2_valid=1`), firmware computes NW-MRC via `WGT_SRC=SW`:

```
w_j = conj(Z_j) / sigma2_active_j
```

When `sigma2_j` is equal across branches this is exactly proportional to plain MRC. When branches differ, high-noise branches are suppressed. See [sim/models/weight_generation.py](../../sim/models/weight_generation.py) — `compute_nw_mrc_weights()`.

Note: the per-branch MMSE form `conj(Z_j) / (|Z_j|² + sigma2_j * n_acc)` gives a signal-dependent denominator per branch and does **not** reduce to plain MRC even with equal noise — it is a different estimator and should not be confused with NW-MRC.

The hardware path (`WGT_SRC=AUTO`) continues to use the equal-noise approximation and remains available as a fallback if `sigma2_valid=0`.

---

## Alternative normalization options under consideration

The current hardware MRC path uses a shared shift-based backoff, but it is not a true output-bounding normalization. Coherent equal-strength branches can still drive the combiner into `int8` saturation before the remod input backoff stage. Two follow-on options are being considered:

### Option A — stronger shift normalization in hardware

Keep the current no-divider philosophy, but tighten the shared hardware scaling so the combined MRC output is bounded more conservatively before the `int8` combiner saturator. The intent is:

- preserve MRC branch ratios
- avoid reciprocal/divider hardware
- reduce or eliminate combiner clipping in the equal-strong-branch corner

Possible implementation directions:

- increase the existing `mrc_shift` rule in `weight_gen` based on a more conservative coherent-sum bound
- or add an additional linear right shift in the MRC datapath before final `int8` saturation

This is still linear scaling, so it avoids the SNR/EVM damage of hard clipping. The trade-off is reduced remod-side SQNR from additional backoff.

### Option B — full normalized weights in software

Leave the hardened RTL path simple and move normalized weight computation to PicoRV32 firmware using `WGT_SRC=SW`. Firmware would:

- read `Z_j`
- compute normalized weights
- write `W_SHADOW`
- commit via the existing control path

This keeps the hardware datapath simple and allows exact or near-exact normalization, but same-packet timing margin must be validated in firmware.

At the moment, Option A is retained as a viable hardware fallback, while Option B remains the cleaner architectural path if firmware timing is acceptable.

## Future extensions

### EGC — Equal Gain Combining

EGC (`w_j = conj(H_j_cal) / |H_j_cal|`) was considered for the hardware path and dropped in favour of MRC. Reasons:

- MRC is the optimal linear combiner and is ~1 dB better than EGC at NR=4
- EGC requires a 16-stage × 4-branch CORDIC (the largest datapath element); the current hardware path intentionally avoids comparably wide normalization arithmetic
- The one advantage of EGC — robustness to amplitude estimation noise — is not significant with 5+ preamble symbols of training
- EGC is available via the software path (`WGT_SRC=SW`) for any deployment that needs it

If EGC hardware acceleration is added in a future revision:

- Add a 16-stage CORDIC per branch (or one time-multiplexed instance for all 4 branches)
- CORDIC vectoring mode extracts `φ_j = atan2(Q_j, I_j)` from `H_j_cal`; rotation mode synthesises `(cos φ_j, −sin φ_j)` — two passes, ~32 cycles total
- Assign `WGT_MODE = 2'b10` (currently reserved)
- The magnitude approximation `|z| ≈ max(|I|,|Q|) + (3/8)·min(|I|,|Q|)` (~3% error, shifts and adds only) is an alternative if a full CORDIC is not justified

---

## Related Blocks

- [Training Accumulator](Training%20Accumulator.md) — provides `Z_j`, `n_acc`, `training_done`
- [Noise Floor Estimator](Noise%20Floor%20Estimator.md) — provides `sigma2_active_j` for NW-MRC
- [ALMMSE-MRC Combiner](ALMMSE-MRC%20Combiner.md) — consumes `W_ACTIVE` at sample rate
- [Packet Control FSM](Packet%20Control%20FSM.md) — receives `W_COMMIT`, manages `safe_switch`
- [PicoRV32 Integration](PicoRV32%20Integration.md) — software path; reads `Z_j`, `W_HW` via register map; writes `W_SHADOW`
- [Register Map](../Register%20Map.md) — `WGT_CTRL`, `W_HW[3:0]`, `W_SHADOW[3:0]`, `W_COMMIT`, `MIMO_CTRL`, `cal_j` registers
- [Frontend Calibration Procedure](../Frontend%20Calibration%20Procedure.md) — step-by-step derivation and SPI write sequence for `cal_j`
