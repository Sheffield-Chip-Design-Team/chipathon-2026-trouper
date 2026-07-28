# PicoRV32 Integration (Grouper Project)

Control block. See [System Architecture](../System%20Architecture.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Hardened **PicoRV32 RV32IM** processor macro residing in the **Grouper** project. It serves as the primary system controller for the MPW, providing control-plane and algorithm support for the **Trouper** MIMO RX ASIC. It runs firmware loaded over a dedicated SPI interface by the RPi host and manages peripherals via the shared `AHB-Lite` system bus.

Baseline RX packet reception in Trouper must not depend on this block being operational. If the PicoRV32 is held in reset, stalled, or absent, Trouper's hardware receive path remains functional, supporting:

- Preamble detection
- Training data accumulation
- Baseline hardware weighting
- Packet phase control
- Direct bypass or combined output to the ΣΔ re-modulator

PicoRV32 provides non-critical but high-performance enhancements for:

- Software weight algorithms (e.g., Eigenvector power iteration)
- Cross-packet EMA smoothing
- Advanced AGC policies
- Comprehensive diagnostics and telemetry
- TDD TX/RX switching orchestration

**Bus decision.** The project uses a single-master `AHB-Lite` system bus. The PicoRV32 (Master) connects to this bus via a custom wrapper that translates native CPU memory accesses into AHB-Lite transactions.

**Why RV32IM (not RV32I):** Hardware MUL/DIV (the M extension) is essential for keeping complex control-loop tasks (weight computation, statistics) within the tight timing budgets required for real-time packet processing.

---

## Firmware tasks

These are optional enhancements unless otherwise noted in the TX path. None of the RX-only tasks below may be a single point of failure for baseline reception.

| Task | Trigger | Latency budget |
| --- | --- | --- |
| Weight computation override (ALMMSE / EMA / custom SW policy) | `training_done` IRQ (`IRQ_TRAINING_DONE`) | < 2.2 ms at SF6/125 kHz (~70,400 cycles) |
| TX preparation (RX→TX) | `tx_prep` IRQ from TX_CTRL[0] | < 1 ms (LoRaWAN RX1 budget = 1 s) |
| TX restore (TX→RX) | `tx_done` IRQ from TX_CTRL[1] | < 1 ms |
| AGC loop | `corr_lock` IRQ (`IRQ_CORR_LOCK`) | < 1 packet |
| Null steering — DOA estimation + null weight commit | `noise_ready` IRQ (`IRQ_NOISE_READY`) | < 1 ms — must complete before preamble training starts |
| SX1257 init on power-up | Startup when CPU-managed mode is used | Before first RX |

### Weight computation override

Triggered by `IRQ_TRAINING_DONE` for the current MRC path. There is no baseline hardware weight-generation path in the tapeout plan, so PicoRV32 or an equivalent host-side weight engine must service this flow whenever MRC combining is required.

Firmware reads the training accumulator readback registers, computes combining weights for the active mode, writes W_SHADOW (`0x90`–`0xAF`), then pulses W_COMMIT.

The training accumulator readback preserves relative magnitudes and phases, so firmware can compute weights directly from the exported Z matrix without dividing by `n_acc` for the usual MRC/eigenvector paths.

```c
// Read Z_j_scaled (int32 I+Q per branch, big-endian) from 0x70-0x8F
// Apply calibration: H_j = Z_j * conj(cal_j)   (complex multiply, Q1.15 cal)
// Then compute weights by mode:

// MRC: w_j = conj(H_j) / S,  S = Σ_k |H_k|²
int64 S = 0;
for (int j = 0; j < 4; j++)
    S += (int64)H_re[j]*H_re[j] + (int64)H_im[j]*H_im[j];
for (int j = 0; j < 4; j++) {
    W_re[j] = (int16)((int64)H_re[j] * 32767 / S);   // Q1.15 normalise
    W_im[j] = (int16)(-(int64)H_im[j] * 32767 / S);  // conjugate
}

// EGC: w_j = conj(H_j) / |H_j|  (unit magnitude, conjugate phase)
// SC:  w_j = 1 for argmax_j |H_j|², 0 for others
// Bypass: w_j = 1 for lowest enabled antenna, 0 for others
```

After writing W_SHADOW and pulsing W_COMMIT, the Packet Control FSM promotes W_SHADOW → W_ACTIVE at the next `safe_switch` (IDLE boundary). See [Firmware Spec](../Firmware%20Spec.md) and [Eigenvector Weight Computation](Eigenvector%20Weight%20Computation.md) for the active arithmetic detail.

### TX preparation (RX → TX)

Triggered by `tx_prep` IRQ (host writes `TX_CTRL[0]=1`). Disables RX on TX antennas before switching them to transmit, preventing corrupted inputs reaching the combiner.

```c
void tx_prep_handler() {
    // 1. Gate TX antennas out of combiner immediately
    uint8_t ctrl = read_reg(MIMO_CTRL);
    write_reg(MIMO_CTRL, ctrl & ~0b11110000);  // clear ANTENNA_EN[0:1]
                                                // (antennas 2,3 remain active)

    // 2. Put SX1257_3/4 to standby (StandbyEnable only = 0x01)
    //    Stops SX1257_3/4 outputting corrupt IQ during TX window
    spi_master_write(2, REG_MODE, 0x01);  // SX1257_3 standby
    spi_master_write(3, REG_MODE, 0x01);  // SX1257_4 standby

    // 3. Switch SX1257_1/2 to TX (PADriverEnable|TxEnable|StandbyEnable = 0x0D)
    spi_master_write(0, REG_MODE, 0x0D);  // SX1257_1 TX
    spi_master_write(1, REG_MODE, 0x0D);  // SX1257_2 TX
    // ~12 µs SPI (4 writes) + 120 µs TS_TR; well within 1 s RX1 budget

    // 4. Mark TX active; clear IRQ; signal RPi
    write_reg(TX_CTRL, 0x04);  // TX_ACTIVE=1, TX_PREP=0
    clear_irq(IRQ_TX_PREP);
}
```

**W recomputation not required.** During TX the SX1302 is transmitting — it does not process the ASIC re-mod output. Combined output quality during TX is irrelevant.

**SE2435L LNA protection.** Standby on SX1257_3/4 stops corrupt IQ data reaching the ASIC. SE2435L_3/4 CPS (LNA enable) is a separate signal whose source is TBD — see [SE2435L Front-End Module](SE2435L%20Front-End%20Module.md) for the open decision. If CPS cannot be driven low during TX, the LNA may compress at −13 dBm input (40 dB board isolation, +27 dBm TX); safe only if board isolation >37 dB.

### TX restore (TX → RX)

Triggered by `tx_done` IRQ (host writes `TX_CTRL[1]=1` after `lgw_send()` completes).

```c
void tx_done_handler() {
    // 1. Switch SX1257_1/2 back to RX (RxEnable|StandbyEnable = 0x03)
    spi_master_write(0, REG_MODE, 0x03);  // SX1257_1 RX
    spi_master_write(1, REG_MODE, 0x03);  // SX1257_2 RX

    // 2. Restore SX1257_3/4 to RX
    spi_master_write(2, REG_MODE, 0x03);  // SX1257_3 RX
    spi_master_write(3, REG_MODE, 0x03);  // SX1257_4 RX

    // 3. Wait TS_RE — SX1257 standby/TX → RX wake-up (typ 100 µs)
    delay_us(150);  // conservative margin; covers all 4 SX1257s

    // 5. Re-enable all antennas
    uint8_t ctrl = read_reg(MIMO_CTRL);
    write_reg(MIMO_CTRL, ctrl | 0b11110000);  // restore ANTENNA_EN[0:1]

    // 6. Clear TX_ACTIVE; clear IRQ
    write_reg(TX_CTRL, 0x00);
    clear_irq(IRQ_TX_DONE);

    // 7. Invalidate W — correlator will recompute on next preamble
    //    (channel may have changed while TX antennas were gated)
    w_valid = 0;
}
```

**Note on W invalidation.** After TX, the channel estimate from before TX may be stale. Setting `w_valid=0` causes the combiner to coast on the old W until the next correlator lock recomputes it. For a static gateway this is fine; channel coherence time >> TX window duration.

### Flat-fading-per-packet assumption

The design assumes the channel is constant across one packet — `h_hat` estimated from the preamble is applied unchanged to the payload. This holds when the channel coherence time >> packet duration.

**When the assumption can break:**

| Scenario | Risk | Notes |
| --- | --- | --- |
| Mobile node (walking, ~1.5 m/s, 868 MHz) | Coherence time ~200 ms | SF12 packets (~2.5 s) exceed this; SF7 (~50 ms) is safe |
| Dense urban / industrial multipath | High Doppler spread | Even slow nodes can see fast fading |
| SF12 at 125 kHz | Highest risk | 2.5 s exposure — longest packet by far |
| SF7–SF9 static sensors | Negligible | Packets short enough for assumption to hold comfortably |

**Impact:** If the channel changes between preamble and payload, `h_hat` is stale. MRC degrades gracefully (loses some combining gain) rather than failing catastrophically — the argmax demodulator is robust to partial phase misalignment.

**EMA interaction:** The cross-packet EMA averaging makes staleness worse for mobile nodes by blending old channel estimates into the current one. EMA should be disabled (`ALPHA_SHIFT=0`) or given a very short window for mobile deployments.

**Verification implication:** BER vs SNR sweeps should include a time-varying channel test at SF12 to characterise the degradation boundary.

---

### Channel estimate averaging (EMA)

Z_j is estimated once per preamble. On a stable channel this is sufficient; on a slowly varying channel, averaging Z_j across packets reduces noise on the channel estimate and stabilises weights.

Firmware implements an exponential moving average of the normalised channel estimate H_j (= Z_j_scaled, the int32 right-shifted value from registers) in DMEM — no RTL changes required:

```c
// DMEM: 32 bytes for H_prev (int32 I+Q per branch)
int32_t H_prev_re[4], H_prev_im[4];

// IRQ_STATUS bits (non-FFT path):
#define IRQ_CORR_LOCK        (1u << 0)
#define IRQ_TRAINING_DONE    (1u << 1)
#define IRQ_W_MISSED_PACKET  (1u << 2)
#define IRQ_PACKET_DONE      (1u << 3)

void irq_handler() {
    uint8_t irq = read_reg(IRQ_STATUS);

    if (irq & IRQ_CORR_LOCK) {
        agc_update();
        clear_irq(IRQ_CORR_LOCK);
    }

    if (irq & IRQ_TRAINING_DONE) {
        // Saturation check: if any antenna was saturating, discard this packet
        bool saturated = false;
        for (int n = 0; n < 4; n++)
            if (read_energy(n) > AGC_SAT_GUARD) { saturated = true; break; }

        if (!saturated) {
            read_Zj_registers(H_new_re, H_new_im);  // Z_j_scaled from 0x70-0x8F

            // EMA: reset if any antenna's gain changed (Z_j scales with gain)
            if (ema_reset_pending) {
                memcpy(H_prev_re, H_new_re, sizeof(H_prev_re));
                memcpy(H_prev_im, H_new_im, sizeof(H_prev_im));
                ema_reset_pending = false;
            } else {
                // H_avg = H_prev + (H_new - H_prev) >> ALPHA_SHIFT
                for (int j = 0; j < 4; j++) {
                    H_prev_re[j] += (H_new_re[j] - H_prev_re[j]) >> ALPHA_SHIFT;
                    H_prev_im[j] += (H_new_im[j] - H_prev_im[j]) >> ALPHA_SHIFT;
                }
            }

            compute_W(H_prev_re, H_prev_im);  // uses active combining mode
            write_W_shadow_registers(W);       // to 0x90-0xAF
            write_reg(WGT_CTRL, 1u << 4);   // pulse W_COMMIT
        }

        clear_irq(IRQ_TRAINING_DONE);
    }

    if (irq & IRQ_W_MISSED_PACKET) {
        stats.w_missed++;
        clear_irq(IRQ_W_MISSED_PACKET);
    }
}
```

`ALPHA_SHIFT` is a firmware compile-time constant. To disable averaging set `ALPHA_SHIFT=0`.

Per-branch noise floor estimation is handled by the **Noise Floor Estimator** RTL block (see [Noise Floor Estimator](Noise%20Floor%20Estimator.md)), not by firmware. Firmware uses the hardware estimates via `SIGMA2_SRC=HW` (default) or supplies override values via `SIGMA2_SHADOW` registers if needed.

**Timing:** Weight computation (MRC path including 1/S division) ~50 cycles at 32 MHz. Budget from `training_done` to payload start is ~70,400 cycles at SF6/125 kHz — margin >1000×.


### AGC loop

Triggered at each `IRQ_STATUS.CORR_LOCK`, independent of the later `IRQ_STATUS.TRAINING_DONE` W-computation path. Reads per-antenna energy latched at preamble lock by the Energy Measurement and adjusts each SX1257's `RegRxAnaGain` (0x0C) independently.

**SX1257 RegRxAnaGain (0x0C) layout:**

| Bits | Field | Range | Step |
| --- | --- | --- | --- |
| [7:5] | `RxLnaGain` | 1 (G1, max) – 6 (G6, min) | 6 dB for G1–G3; **12 dB** for G3–G6 |
| [4:1] | `RxBbGain` | 0 (min) – 15 (max) | 2 dB (gain = −24 + 2×val dB) |
| [0] | `LnaZin` | keep 0 (50 Ω) | — |

Note: `RxLnaGain` is inverted — a higher register value means less gain (G1=0 dB ref, G2=−6, G3=−12, G4=−24, G5=−36, G6=−48 dB). Steps are **non-uniform**: 6 dB between G1–G3, 12 dB between G3–G6. Total range: 48 dB (LNA) + 30 dB (BB) = 78 dB; spec quotes 70 dB usable.

**Control strategy:** Use BB gain for fine tracking (±2 dB/packet). Step LNA gain only when BB hits its limit, restoring BB to mid-scale to maintain headroom. Note that a single LNA step near G3/G4 is 12 dB — if crossing that boundary, two BB steps will not fully compensate; convergence may take 2 packets instead of 1.

```c
// RegRxAnaGain bit packing
#define LNA_G1  1   // maximum LNA gain (0 dB ref)
#define LNA_G6  6   // minimum LNA gain (−48 dB)
#define BB_MAX  15  // maximum BB gain
#define BB_MIN  0   // minimum BB gain
#define BB_MID  7   // restore point after LNA step

// Energy thresholds (ENERGY register: int16 unsigned, Σ|x|² over 8 symbols)
#define AGC_TARGET_LO  0x0800   // ~3%  of full scale — increase gain
#define AGC_TARGET_HI  0x6000   // ~38% of full scale — decrease gain
#define AGC_SAT_GUARD  0xE000   // ~88% of full scale — emergency LNA step

// Start at full gain (G1 + BB_MAX) for maximum sensitivity on the first packet.
// Weak/distant nodes may only just trigger correlator lock — any gain reduction
// at startup risks missing them entirely. Strong-signal saturation is handled
// by discarding corrupted H estimates rather than reducing starting gain.
// Host may override lna_gain[]/bb_gain[] directly before releasing CPU_RESET;
// Trouper has no on-chip gain-shadow/commit register to stage this through.
static uint8_t lna_gain[4] = {LNA_G1,  LNA_G1,  LNA_G1,  LNA_G1};
static uint8_t bb_gain[4]  = {BB_MAX,  BB_MAX,  BB_MAX,  BB_MAX};
bool ema_reset_pending = false;  // set when any gain changes; consumed by irq_handler

static void agc_write(int n) {
    uint8_t reg = (lna_gain[n] << 5) | (bb_gain[n] << 1);  // LnaZin=0
    spi_master_write(n, 0x0C, reg);  // applied directly to the SX1257 (board-level SPI master)
}

void agc_update() {
    if (read_reg(TX_CTRL) & 0x04) return;  // skip during TX window

    for (int n = 0; n < 4; n++) {
        uint16_t e = read_energy(n);
        bool changed = true;

        if (e > AGC_SAT_GUARD) {
            // Saturation: step LNA down immediately (−6 dB), restore BB to mid
            if      (lna_gain[n] < LNA_G6)  { lna_gain[n]++; bb_gain[n] = BB_MID; }
            else if (bb_gain[n]  > BB_MIN)   { bb_gain[n] = BB_MIN; }
            else                             { changed = false; }  // already at floor
        } else if (e > AGC_TARGET_HI) {
            // Too hot: reduce BB by 2 dB; step LNA if BB exhausted
            if      (bb_gain[n] > BB_MIN)    { bb_gain[n]--; }
            else if (lna_gain[n] < LNA_G6)   { lna_gain[n]++; bb_gain[n] = BB_MAX; }
            else                             { changed = false; }
        } else if (e < AGC_TARGET_LO) {
            // Too cold: increase BB by 2 dB; step LNA if BB exhausted
            if      (bb_gain[n] < BB_MAX)    { bb_gain[n]++; }
            else if (lna_gain[n] > LNA_G1)   { lna_gain[n]--; bb_gain[n] = BB_MIN; }
            else                             { changed = false; }
        } else {
            changed = false;  // within window
        }

        if (changed) { agc_write(n); ema_reset_pending = true; }
    }
}
```

**Convergence.** Starting at G1+BB_MAX gives maximum sensitivity for weak first packets. For a saturating close-range node, `AGC_SAT_GUARD` steps the LNA immediately and H is discarded for that packet — the combiner coasts on the previous W (or waits for the first clean packet if no prior W exists). Fine tracking once in the target window converges in 1–2 packets. For a known deployment, pre-set `lna_gain[]`/`bb_gain[]` and write them directly to each SX1257 before releasing `CPU_RESET` to skip convergence entirely.

**No-packets limitation.** AGC only runs at correlator lock — between packets, gain is frozen at its current setting. This is intentional: maximum gain during silence maximises the chance of detecting the next transmission. The saturation-discard path handles the first strong packet cleanly without reducing idle sensitivity.

**Interaction with W.** Gain changes take effect at the start of the next packet. H and N₀ are latched at correlator lock so they are always self-consistent within a packet — no mid-packet gain shift occurs.

**EMA invalidation on gain change.** H scales with receive gain, so `H_prev` (estimated at gain G_N) and `H_new` (at gain G_{N+1}) are not comparable. If any antenna's gain changed this packet, set `ema_reset_pending = true`. On the following correlator lock, skip the EMA and seed `H_prev = H_new` directly, then clear the flag. This ensures the EMA only ever averages estimates from the same gain setting.

**TX guard.** `agc_update()` returns immediately if `TX_ACTIVE` is set. Energy latched during TX is meaningless (combiner has gated antennas 0/1 and antennas 2/3 are receiving TX leakage, not node signal).

**Threshold calibration.** `AGC_TARGET_LO / AGC_TARGET_HI` are initial values; calibrate on silicon against measured ADC output levels from the decimator. `AGC_SAT_GUARD` should be set just below the int8 decimator output saturation point.

---

### Null steering — interference DOA and weight projection

Interference suppression by placing a spatial null in the direction of the dominant interferer. Not MUSIC or ESPRIT (those require eigendecomposition, not feasible on PicoRV32) — uses inter-antenna cross-correlations and a single vector projection.

**When it runs.** The noise window is the period before the SC correlator fires (`!sync_found`). The training accumulator runs in noise mode during this window (antenna 0 as self-reference instead of the chirp reference), accumulating cross-correlations R_10, R_20, R_30. When the window closes, `IRQ_NOISE_READY` fires. Firmware reads the three complex cross-correlations from `NOISE_Z` registers, computes the interferer angle, projects the MRC weights, and commits the null weights before preamble training begins.

**This is not within-packet tracking.** Once the packet preamble starts, null weights are fixed for the duration of that packet. Inter-packet tracking is automatic — the noise window re-runs every inter-packet gap, so the null re-points each cycle. For a static or slow-moving interferer this converges in one gap (~100 ms or less). True within-packet tracking would require decision-directed feedback from the demodulator and is not implemented.

**RTL requirements** (not yet in RTL):
- Training accumulator: add `NOISE_MODE` control bit — when set, use `x_0` as the accumulator reference instead of the chirp reference.
- New registers: `NOISE_WIN_CTRL` (enable + window length), `NOISE_Z_RE1/IM1`, `NOISE_Z_RE2/IM2`, `NOISE_Z_RE3/IM3` (int32 cross-correlations R_10, R_20, R_30).
- New IRQ: `IRQ_NOISE_READY` — fires when the noise accumulation window closes.
- Optional: `NULL_QUALITY` register — ratio of post-combining power with vs without null applied (16-bit, firmware-readable) for diagnostics.

**Assumption — interferer must dominate thermal noise.** The cross-correlation `R_j0 = Σ x_j · conj(x_0)` has a coherent interferer contribution with magnitude proportional to interferer power, and an incoherent noise cross-term with variance `σ²_0 · σ²_j · N_acc`. The phase estimate is only reliable when the interferer-to-noise ratio (INR) at the antenna input is high enough that the coherent term dominates: `INR · N_acc >> 1`. If the dominant "noise" is thermal rather than a directional interferer, the estimated angle is meaningless and applying the null projection will degrade MRC gain. A quality gate on `|R_10|²` vs the hardware `SIGMA2` estimate guards against this — see code below.

**Algorithm (firmware):**

```c
// DOA estimation constants
// For a ULA with d = λ/2: phase between adjacent antennas = π·sin(θ)
// Use a 64-entry sin/cos LUT at Q1.15 resolution.

#define NULL_ANGLE_STEPS  64          // scan resolution; ~2.8° per step
#define NULL_ENABLE_BIT   (1u << 0)   // NOISE_WIN_CTRL

// Step 1: read cross-correlations R_j0 = E[x_j · conj(x_0)] (int32 I+Q)
int32_t R_re[3], R_im[3];   // R_10, R_20, R_30

void noise_ready_handler() {
    R_re[0] = read_reg32(NOISE_Z_RE1);  R_im[0] = read_reg32(NOISE_Z_IM1);
    R_re[1] = read_reg32(NOISE_Z_RE2);  R_im[1] = read_reg32(NOISE_Z_IM2);
    R_re[2] = read_reg32(NOISE_Z_RE3);  R_im[2] = read_reg32(NOISE_Z_IM3);

    // Quality gate: cross-correlation only gives reliable DOA when the interferer
    // dominates thermal noise.  R_j0 = interferer_contribution + noise_cross_term;
    // the noise cross-term has zero mean but variance σ²_0 · σ²_j · N_acc.
    // Check |R_10|² > NULL_INR_THRESHOLD · σ²_ant0 · N_acc before proceeding.
    // If the interferer is too weak, skip null steering and use plain MRC weights —
    // projecting onto a noise-derived null would degrade combining gain for no benefit.
    uint32_t inr_proxy = (uint32_t)(R_re[0]/256)*(R_re[0]/256)
                       + (uint32_t)(R_im[0]/256)*(R_im[0]/256);  // |R_10|² scaled
    uint32_t noise_ref = (uint32_t)read_reg16(SIGMA2_0_HW)
                       * (uint32_t)read_reg16(N_ACC);             // σ²·N_acc
    if (inr_proxy < NULL_INR_THRESHOLD * noise_ref) {
        // Interferer below threshold — null would point at noise, not interferer.
        // Commit plain MRC weights and return.
        write_W_shadow_registers(W_re, W_im);
        write_reg(WGT_CTRL, 1u << 4);
        clear_irq(IRQ_NOISE_READY);
        return;
    }

    // Step 2: estimate phase slope Δφ = π·sin(θ) from the three cross-correlation phases.
    // Phase of R_j0 = j·Δφ for antenna j=1,2,3.  Weighted average reduces noise:
    //   Δφ_est = (arg(R_10) + arg(R_20)/2 + arg(R_30)/3) / 3
    // atan2 computed via a 256-entry Q1.15 LUT; shift right to bring into [-π, π).
    int32_t phi1 = atan2_lut(R_im[0], R_re[0]);          // Q2.13 fixed-point
    int32_t phi2 = atan2_lut(R_im[1], R_re[1]) / 2;
    int32_t phi3 = atan2_lut(R_im[2], R_re[2]) / 3;
    int32_t dphi = (phi1 + phi2 + phi3) / 3;             // Q2.13

    // Step 3: build interference steering vector a(θ) = [1, e^(j·dphi), e^(j·2·dphi), e^(j·3·dphi)]
    // sin/cos from LUT indexed by (dphi * 64 / π) modulo 64.
    int16_t a_re[4], a_im[4];
    a_re[0] = 0x7FFF; a_im[0] = 0;   // a[0] = 1+0j
    for (int k = 1; k < 4; k++) {
        int idx = ((int64_t)dphi * k * 64 / PI_Q213) & 63;
        a_re[k] = cos_lut[idx];   // Q1.15
        a_im[k] = sin_lut[idx];
    }

    // Step 4: null projection  w_null = w_mrc − (aᴴ·w_mrc / aᴴ·a) · a
    // aᴴ·a = 4 (unit-magnitude elements, always 4 for a 4-element ULA)
    // aᴴ·w_mrc: one complex dot product (4 multiply-adds)
    int32_t dot_re = 0, dot_im = 0;
    for (int j = 0; j < 4; j++) {
        // aᴴ[j] = conj(a[j]) = a_re[j] - j·a_im[j]
        dot_re += ((int64_t)a_re[j] * W_re[j] + (int64_t)a_im[j] * W_im[j]) >> 15;
        dot_im += ((int64_t)a_re[j] * W_im[j] - (int64_t)a_im[j] * W_re[j]) >> 15;
    }
    // scalar = (aᴴ·w_mrc) / 4  (divide by aᴴ·a = 4)
    int32_t sc_re = dot_re >> 2;
    int32_t sc_im = dot_im >> 2;

    // w_null[j] = w_mrc[j] − scalar · a[j]
    int16_t W_null_re[4], W_null_im[4];
    for (int j = 0; j < 4; j++) {
        int32_t proj_re = ((int64_t)sc_re * a_re[j] - (int64_t)sc_im * a_im[j]) >> 15;
        int32_t proj_im = ((int64_t)sc_re * a_im[j] + (int64_t)sc_im * a_re[j]) >> 15;
        W_null_re[j] = sat16(W_re[j] - proj_re);
        W_null_im[j] = sat16(W_im[j] - proj_im);
    }

    // Step 5: commit null weights via firmware override path
    write_W_shadow_registers(W_null_re, W_null_im);
    write_reg(WGT_CTRL, 1u << 4);   // pulse W_COMMIT

    clear_irq(IRQ_NOISE_READY);
}
```

**Timing.** The null projection is ~50 multiply-accumulate operations on int32 values. At 16 MHz with RV32IM hardware multiply: ~200 cycles = 12.5 µs — well within the budget before preamble training starts.

**Null depth.** For a 4-element ULA with a single point source at an angle away from the desired signal: ~20–30 dB suppression at the null centre. Degrades if the interferer has angular spread wider than the null (~22° HPBW) or if the desired signal and interferer are within ~10° of each other.

**Interaction with EMA.** Null weights replace MRC weights before the preamble, so `H_prev` (used for EMA) should be stored as the pre-null MRC weights, not the null weights. Otherwise the null projection accumulates across EMA rounds and distorts the channel estimate. Keep two weight buffers: `W_mrc[]` (EMA-smoothed MRC weights, internal firmware state) and `W_active[]` (null-projected, committed to hardware).

**Null disable.** Set `NOISE_WIN_CTRL = 0` to disable noise accumulation. Firmware then skips `irq_handler` for `IRQ_NOISE_READY` and the standard MRC weights are committed as usual.

---

## Memory map

| Address | Region | Size | Macro | Notes |
| --- | --- | --- | --- | --- |
| `0x00000` | Unified SRAM (text + data + stack) | 4 KB | `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` ×4 | Loaded by host via SPI; `.text` at low addresses, `.data`/`.bss`/stack at high addresses |
| `0x01000` | AHB-Lite peripherals | — | — | Register bank, SPI master, IRQ, JTAG |

A single unified SRAM replaces separate IMEM and DMEM. The linker places `.text` at `0x00000` and `.data`/`.bss`/stack at the top of the 4 KB window. One AHB-Lite port, one BIST instance. This CPU memory uses the experimental `gf180mcu_ocd_ip_sram` library, while the DSP/frontend buffer uses the official GF `gf180mcu_fd_ip_sram` 512x8 macros; see [Memory Strategy](../Memory%20Strategy.md) for the mixed-library rationale and BIST architecture.

---

## CPU SRAM BIST

BIST runs at power-on with `CPU_RESET` held high by the host. March C- on the unified 4 KB SRAM (1 K × 32-bit words). Reports the first failing word address and bit mask.

**Timing:** ~44 ms per macro at 32 MHz (≈ 1.4 M cycles). Total ≈ 88 ms — acceptable at boot.

| Register | Width | Description |
|---|---|---|
| `IMEM_BIST_PASS` | 1 | 1 = no faults found |
| `IMEM_BIST_FAIL_ADDR` | 15 | Word address (×4 = byte address) of first bad IMEM word |
| `IMEM_BIST_FAIL_BITS` | 32 | Failing bit mask at `IMEM_BIST_FAIL_ADDR` |
| `DMEM_BIST_PASS` | 1 | 1 = no faults found |
| `DMEM_BIST_FAIL_ADDR` | 15 | Word address of first bad DMEM word |
| `DMEM_BIST_FAIL_BITS` | 32 | Failing bit mask at `DMEM_BIST_FAIL_ADDR` |

**Boot sequence:**

```
Power-on → DSP SRAM BIST → IMEM BIST → DMEM BIST
  → host reads results via SPI
  → host programs overlay if needed (see below)
  → host loads firmware into IMEM via SPI
  → host releases CPU_RESET
```

---

## Bad-word overlay

Writing a correct value to a stuck SRAM cell does not fix it — the cell overrides the write on every subsequent read. The overlay intercepts reads to known-bad addresses and returns the correct data from a small register file, bypassing the SRAM output.

### Structure

Each macro has a 16-entry CAM overlay:

```
Entry: { valid[1], addr[14:0], data[31:0] }   (16 entries per macro)
```

On every IMEM or DMEM read:

```
if any valid CAM entry matches read_addr → return CAM data  (SRAM output ignored)
else                                     → return SRAM data
```

The CAM lookup is combinational (priority encoder over 16 entries) and adds ≤ 1 pipeline stage — within the 2-cycle AHB-Lite read budget at 32 MHz.

### Programming the overlay

When `IMEM_BIST_PASS = 0`:

1. Host reads `IMEM_BIST_FAIL_ADDR` and `IMEM_BIST_FAIL_BITS`.
2. Host relinks firmware with a linker memory map that excludes the bad word address from `.text` (instruction placed at all other addresses; bad address left as a gap).
3. Host writes the correct instruction for the bad address into `IMEM_OVERLAY_n_ADDR / DATA / VALID` registers via SPI.
4. Host loads firmware into IMEM via SPI (existing burst-write path). The write to the bad address may not stick in silicon, but the overlay will override on read.
5. Host releases `CPU_RESET`. CPU boots; reads to bad addresses return overlay data.

For DMEM faults: adjust stack pointer and linker `.data` / `.bss` placement to avoid the bad region; patch any required variables at bad addresses with DMEM overlay CAM entries.

### Overlay registers

| Register | R/W | Description |
|---|---|---|
| `IMEM_OVERLAY_n_ADDR` (n=0..15) | R/W | IMEM overlay CAM entry n word address |
| `IMEM_OVERLAY_n_DATA` (n=0..15) | R/W | IMEM overlay CAM entry n 32-bit data |
| `IMEM_OVERLAY_n_VALID` (n=0..15) | R/W | 1 = this entry is active |
| `DMEM_OVERLAY_n_ADDR` (n=0..15) | R/W | DMEM overlay CAM entry n word address |
| `DMEM_OVERLAY_n_DATA` (n=0..15) | R/W | DMEM overlay CAM entry n 32-bit data |
| `DMEM_OVERLAY_n_VALID` (n=0..15) | R/W | 1 = this entry is active |

### Coverage

| Scenario | Outcome |
|---|---|
| ≤ 16 isolated bad words, not at reset vector (0x00000) | Recoverable — overlay + firmware relink |
| DMEM bad words outside stack/data regions | Recoverable — linker avoidance |
| Fault at reset vector (first instruction fetch) | Unrecoverable — CPU cannot boot |
| > 16 bad words in a contiguous block | Overlay exhausted — chip cannot execute firmware |

---

## Interface (AHB-Lite)

| Peripheral | WB Address | Notes |
| --- | --- | --- |
| Register bank | `0x10000` | All ASIC config/status registers |
| SPI master | `0x10100` | SX1257 register writes |
| IRQ controller | `0x10200` | IRQ source read/clear |

---

## Implementation notes

**PicoRV32 IP source.** Use the upstream PicoRV32 repo (Clifford Wolf). Enable `ENABLE_MUL`, `ENABLE_DIV`, `ENABLE_IRQ`. Disable `ENABLE_FAST_MUL` to save gates (iterative MUL is fine for firmware latency budget).

**Firmware load flow:**
```
1. Host asserts CPU_RESET=1 via SPI register write
2. Host burst-writes firmware.bin to IMEM (0x00000)
3. Host de-asserts CPU_RESET=0
4. PicoRV32 fetches from 0x00000; executes SX1257 init, then waits for IRQ
```

**IRQ.** Schmidl-Cox lock fires `IRQ_CORR_LOCK` (AGC). Training accumulator completion fires `IRQ_TRAINING_DONE` — this is the W computation trigger for the software path. Firmware reads the all-pairs Z matrix from registers (`0x70`–`0xEF`), computes W, writes `W_SHADOW` (`0x90`–`0xAF`), then asserts the W commit strobe. There is no hardware Weight Generation FSM in the current tapeout plan. Hardware copies `W_SHADOW` into `W_ACTIVE` atomically at the next idle boundary and sets `W_valid`. The live combiner falls back to the selected bypass antenna until `W_valid` is set.

---

## Physical design status

**Latest corrected LibreLane sweep (2026-05-25, GF180MCU 3.3V, MCP SDC):**

| Target | Setup WNS (ns) | Setup violations | Hold WNS (ns) | Hold violations | Magic DRC | Status |
| --- | --- | --- | --- | --- | --- | --- |
| 18 MHz | `+10.94` | `0` | `-0.262` | `9` | `0` | Setup clean |
| 20 MHz | `+5.39` | `0` | `-0.262` | `9` | `0` | Setup clean |
| 22 MHz | `+0.84` | `0` | `-0.262` | `9` | `0` | Setup clean |
| 24 MHz | `-2.34` | `5` | `-0.224` | `8` | `0` | Setup fail |
| 26 MHz | `-5.84` | `13` | `-0.264` | `9` | `0` | Setup fail |
| 28 MHz | `-8.34` | `26` | `-0.287` | `11` | `0` | Setup fail |
| 30 MHz | `-10.08` | `64` | `-0.292` | `8` | `0` | Setup fail |

**Current conclusion:** `22 MHz` is the highest setup-clean operating point for the present PicoRV32 wrapper + MCP constraint set. `24 MHz` and above fail setup.

**Hold note:** hold WNS stays negative across the entire sweep because the failing paths are the very short `irq[*] -> first internal flop` input paths, not the long CPU reg-to-reg datapaths. Relaxing the clock period helps setup but has little effect on same-edge hold checks. This is therefore an IRQ interface timing problem, not evidence that the core datapath still needs a lower frequency.

### Wrapper area comparison: `RV32IM` vs `RV32I`

Both variants were run at the same `16 MHz` wrapper target with the same 4 CPU SRAM macros and the same macro-floorplan strategy, so this is a direct core-option comparison rather than a memory/floorplan comparison.

| Variant | Run | Die area (mm^2) | Instance area (um^2) | Stdcell area (um^2) | Setup WNS (ns) | Hold WNS (ns) | Hold violations | Antenna violations | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `RV32IM` | `RUN_2026-05-25_03-20-32` | `2.94` | `2,798,570` | `515,628` | `0` | `0` | `0` | `3` | Clean successful wrapper run |
| `RV32I` | `RUN_2026-05-25_16-04-58` | `2.74` | `2,603,240` | `438,195` | `0` | `-0.485` | `18` | `0` | Flow completes, but hold-cleanliness regresses |

**Observed delta (`RV32I` relative to `RV32IM`):**

- total instance area improves by about `195,330 um^2` (`-7.0%`)
- stdcell area improves by about `77,433 um^2` (`-15.0%`)
- die area improves by about `0.20 mm^2` (`-6.8%`)
- setup remains clean at `16 MHz`
- hold degrades from `0` to `-0.485 ns` with `18` violations

**Decision-useful conclusion:** removing MUL/DIV is a real but limited area lever. It helps the wrapper, but it does not remove the fixed CPU SRAM cost and it is not yet a drop-in replacement because the current `RV32I` wrapper run is not hold-clean. This option is worth keeping on the table, but it should be treated as a medium lever, not the main path to a `~2 mm^2` top-level target.

### Wrapper area comparison: `RV32IM` dual-port vs `RV32IM` single-port regfile

This comparison keeps MUL/DIV enabled and changes only `ENABLE_REGS_DUALPORT`, so it isolates the regfile-porting tradeoff.

| Variant | Run | Die area (mm^2) | Instance area (um^2) | Stdcell area (um^2) | Setup WNS (ns) | Hold WNS (ns) | Hold violations | Antenna violations | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `RV32IM` dual-port | `RUN_2026-05-25_03-20-32` | `2.94` | `2,798,570` | `515,628` | `0` | `0` | `0` | `3` | Clean successful wrapper run |
| `RV32IM` single-port | `RUN_2026-05-25_18-12-37` | `2.86` | `2,721,480` | `490,596` | `0` | `-0.474` | `1` | `4` | Flow completes, but hold regresses slightly |

**Observed delta (`single-port` relative to `dual-port`):**

- total instance area improves by about `77,090 um^2` (`-2.75%`)
- stdcell area improves by about `25,032 um^2` (`-4.85%`)
- die area improves by about `0.077 mm^2` (`-2.6%`)
- setup remains clean at `16 MHz`
- hold degrades from `0` to `-0.474 ns` with `1` violation

**Decision-useful conclusion:** single-port regfile mode is a smaller lever than removing MUL/DIV. It does save area, but only modestly, and it still introduces a hold-cleanliness regression in the current wrapper flow. This is a minor-to-medium lever, not a decisive area reduction path by itself.

### SRAM macro pin geometry (2026-05-28)

For all `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` macros: **every signal pin is on the bottom edge** of the macro on Metal2 (LEF y=0..3 µm strip). 36 pins total (`A[9:0]`, `CLK`, `CEN`, `GWEN`, `WEN[7:0]`, `D[7:0]`, `Q[7:0]`).

Within the 301.30 µm bottom edge the pins cluster into three bands:
- x≈7–84 µm: `D/Q/WEN[0..3]` (low byte half)
- x≈98–197 µm: `CLK, A[9:0], CEN, GWEN` (control + address)
- x≈214–291 µm: `D/Q/WEN[4..7]` (high byte half)

VDD/VSS are on top-side rings (handled by `PDN_MACRO_CONNECTIONS`). This means **only the `N`/`FS` orientations are practically useful** — pins either face down (N) or up (FS). Side-facing orientations (E/W) require routing all signals around the macro footprint.

### Placement-topology sweep (2026-05-28)

Six 4-macro arrangements were tried on top of the baseline P&R config. Results:

| Variant | Layout | Result | Failure |
| --- | --- | --- | --- |
| baseline 2×2 | all N, 2-row 2-col | clean | — |
| `bottom_row` | 4×1 all N, tight 5.9 µm gap | fail | DRT-0073 clkbuf_8 (halos overlap) |
| `row1x4` | 4×1 all N, 60 µm gaps | clean (+19 ns slack) | — |
| `b23_flipped` | 2×2, b2/b3 FS pins-up | fail | DRT-1231/0073 clkbuf_12 |
| `cpu_middle` | 2×2 split rows, CPU between, b2/b3 FS | fail | DRT-0073 clkbuf_12+16 |
| `col4x1` (W) | 4×1 column at x=50, W orientation (pins right) | fail | DRT-1231 clkbuf_regs_0_clk_32m/Z |
| `col4x1_e` | 4×1 column at x=860, E orientation (pins left, macros on right of die) | routes clean; **hold fail at TT** | post-flow `Hold violations found in nom_tt_025C_3v30` |

**Macros oriented FS or W (placed left side of die) consistently break the detailed router.** Root cause: with FS or W orientation and macros packed near one die edge, the macro CLK pin ends up adjacent to a tight std-cell strip; CTS lands a clkbuf in that strip; detailed router can't reach the buffer's input pin through the constrained Metal2 access tracks.

**E orientation with macros on the *opposite* die edge (col4x1_e) routes cleanly** — the std-cell strip is now spacious because it occupies most of the die. But this variant has hold-time violations at TT corner that the current `HOLD_VIOLATION_CORNERS=""` setting does not fix. Adding `nom_tt_025C_3v30` to `HOLD_VIOLATION_CORNERS` is expected to close it; not yet tested.

**Practical implication:** keep all 4 macros in N orientation by default. `row1x4`, baseline `2×2`, and `col4x1_e` (with hold-fix enabled) are the routable layouts found. Of these, baseline `2×2` has the best setup slack (+22 vs +19 vs +19.4 ns) and is the proven configuration.

### Synthesis/PD area-knob sweep (2026-05-28, baseline 2×2 placement)

All variants use the same RTL, same macro placement (baseline), same `CLOCK_PERIOD=62.5 ns` (16 MHz), and corner set `[tt 25C 3v3, ss 125C 3v0, ff -40C 3v6]`. Only the listed knobs change.

| Variant | SYNTH | util/dens | fanout | GRT buf | CTS root | Die (mm²) | Slack SS (ns) | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline (RUN_2026-05-26_11-09-06) | DELAY 0 | 35/42 | 8 | 100 | clkbuf_16 | 3.06 | +22.78 | clean (reference) |
| `area_t1` (Tier 1) | **AREA 0** | **50/60** | 8 | 100 | clkbuf_16 | **2.02** | +0.95 | clean — **31% die area** |
| `area_t12` (Tier 1+2 smaller bufs) | AREA 0 | 50/60 | 16 | 30 | **clkbuf_12** | — | — | fail DRT-0073 clkbuf_4 |
| `area_t12b` (Tier 1+2, larger bufs) | AREA 0 | 50/60 | 16 | 30 | clkbuf_16 | 2.02 | +0.95 | clean — **bit-identical to t1** |
| `area_mpw` (drop SS, push) | AREA 0 | **60/70** | 32 | 0 | clkbuf_16 | — | — | fail DRT-0073 clkbuf_12 |

**Findings:**

1. **`SYNTH_STRATEGY: "AREA 0"` is the dominant lever.** It alone (with util 50/density 60) gives the 31% area win. Tier 2 buffer/fanout knobs produce bit-identical metrics — confirming that with AREA-0 synthesis, fanout-8 was never binding and the repair stage never used >30% of its buffer budget.
2. **Density above ~60% breaks detailed routing.** Every variant pushing util≥60 or density≥70 hits `DRT-0073` (no access point) on a clock buffer. The trap fires regardless of which CTS buffer cell is used (clkbuf_4, clkbuf_8, clkbuf_12, clkbuf_16 have all been observed failing). The wall is **routability, not timing**.
3. **Dropping SS corner (mpw variant) does not help if density is also raised** — the failure is access-point geometry, not timing slack.
4. **Critical-path shape changes drastically under AREA 0.** Baseline DELAY-0 path: 10 levels of fat AOI/OAI/NAND/NOR through `aoi222`+`nand3`+`nand4`+`oai21` with a 5-buffer slew-repair chain at the start (high-fanout repair). AREA-0 path: **22+ levels of 4-input gates** (`and4`, `nand4`, `nor4`) with no slew-repair buffers and 1–2 fanout per stage. Both paths are CPU-internal — neither touches the SRAM macros, confirming the design is logic-depth bound, not memory-pin bound.

### Lab-test voltage strategy (MPW signoff considerations)

The stdcell library is `gf180mcu_fd_sc_mcu7t5v0` — the 5V silicon-rated variant, currently signed off at 3.0/3.3/3.6 V (SS/TT/FF). For an MPW characterization chip:

- **Cells are silicon-rated to ~5.5 V.** Lab-bumping VDD to 3.6 V is fully covered by FF.lib characterization; 4.0 V is uncharacterized but well within process spec.
- **2× speedup typical from 3.3 → 4.0 V** at 180 nm (well-known for older planar CMOS).
- **Cost: +19% dynamic power at 3.6 V, +47% at 4.0 V.** Bench supplies handle this; PDN IR-drop margin should be re-checked at higher I.
- **Reliability:** TDDB over years matters for shipping product; over MPW-test weeks it is negligible.

Strategy for area: drop SS from signoff (corners `[TT, FF]` only), allowing lab-bumping to compensate if silicon comes back slow. **But** this does not change the DRT-0073 routability floor — the access-point wall is a layout/router limit, not a timing limit. The `area_t1` configuration appears to be the practical area floor for this design + PDK + library + standard PDN settings.

### SRAM density: OCD vs FD compilers

For the chipathon shuttle, two SRAM compilers are available:

| Compiler | Macro | Bits | Area (mm²) | Density (Kb/mm²) | Silicon-proven |
| --- | --- | --- | --- | --- | --- |
| `gf180mcu_fd_ip_sram__` (FD = foundry default) | `sram64x8` | 512 | 0.101 | 5.1 | ✓ yes |
| FD | `sram128x8` | 1,024 | 0.116 | 8.8 | ✓ yes |
| FD | `sram512x8` | 4,096 | 0.209 | 19.6 | ✓ yes (used by DSP/frontend buffer) |
| `gf180mcu_ocd_ip_sram__` (OCD = OnChip Designs, third party) | `sram256x8` | 2,048 | 0.068 | 30.2 | ✗ not in qualified IP list |
| OCD | `sram1024x8` | 8,192 | 0.155 | **52.7** | ✗ — used by PicoRV32 RAM |

OCD is **2.7× denser** than FD at comparable depths, but FD is silicon-proven on this PDK. For tapeout safety, the conservative move is to switch the PicoRV32 unified 4 KB RAM to FD `sram512x8 × 8` (1.67 mm² for memory alone vs current 0.62 mm²) or accept smaller RAM (`4× sram512x8` = 2 KB at 0.84 mm²) if firmware fits. Track this against the `~2 mm²` top-level target.

### Tier-classification of area levers (PicoRV32 wrapper, 16 MHz, GF180MCU 3.3 V)

From most to least impactful, with measured deltas where available:

| Tier | Lever | Effect | Measured | Risk |
| --- | --- | --- | --- | --- |
| 1 | `SYNTH_STRATEGY: AREA 0` + util 50 + density 60 | core area reduction via shallower mapping + tighter packing | **−31% die area** vs baseline | none — clean STA at SS |
| 1 | Drop SS corner signoff | enables further density push only if router allows | not realized — DRT wall hit | MPW-only, lab needs adjustable VDD |
| 2 | Halo shrink (macro 10→5, PDN 5→3) | does NOT reduce die area (util determines die); gives router more room near pins | **+4.3 ns slack recovered** (0.95 → 5.22 ns) at same 2.02 mm² | low (PDN-to-macro DRC) |
| 3 | RV32IM → RV32I (disable MUL/DIV) | drops `pcpi_mul` block | **−7.0% instance area, −15.0% stdcell** | hold-cleanliness regression |
| 3 | Single-port regfile | halves regfile flops | **−2.75% instance area** | minor hold regression |
| 3 | Disable ENABLE_IRQ | trims IRQ state machine | not measured | firmware loses interrupts |
| — | Tier 2 buffer/fanout knobs | `MAX_FANOUT 16`, smaller CTS root, `GRT_RESIZER 30` | **no effect** vs Tier 1 alone | none |
| — | Macro orientation flips (FS, W, E) | none — fails detailed routing | DRT-0073/1231 | layout-only failures |
| — | OCD → FD SRAM | silicon-proven RAM | **+1.05 mm² memory area** | drops 2.7× density |

**Current best:** `area_t1` config — 2.02 mm² die, +0.95 ns SS slack at 16 MHz. Beyond this, only RTL changes (Tier 3) or library swaps move the needle, both with cost.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Firmware load + boot | Load minimal test binary via SPI; monitor WB bus | CPU fetches from 0x00000 after CPU_RESET=0 |
| MRC weight computation | Pre-load Z_j_scaled registers; assert IRQ_TRAINING_DONE | W matches Python `H* / Σ\|H\|²` to ±2 LSB |
| EGC weight computation | Pre-load Z_j_scaled registers | \|w_j\| = 1, angle(w_j) = −angle(h_j) |
| SC weight computation | Pre-load Z_j with one dominant branch | w_j = 1 on correct branch, 0 elsewhere |
| AGC loop | Static channel; vary SX1257 gain via WB | Gain converges within 3 packets |
| EMA reset on gain change | Trigger AGC step; check ema_reset_pending | Next packet seeds H_prev = H_new, skips blend |
| AHB-Lite bus | Back-to-back peripheral accesses | No missed ack; correct data |
| IMEM BIST — clean | Inject fault-free IMEM model | `IMEM_BIST_PASS=1`; BIST completes within 90 ms |
| IMEM BIST — single stuck-at-0 | Force one IMEM bit to 0 in sim | `IMEM_BIST_PASS=0`; `IMEM_BIST_FAIL_ADDR` matches injected address; `IMEM_BIST_FAIL_BITS` has exactly one bit set |
| DMEM BIST — single stuck-at-1 | Force one DMEM bit to 1 in sim | `DMEM_BIST_PASS=0`; correct address and bit mask reported |
| Overlay — single bad IMEM word | Inject stuck bit; program overlay CAM; load firmware; boot | CPU executes correctly; JTAG readback of bad address returns overlay data |
| Overlay — CAM miss | Access IMEM address not in overlay | SRAM data returned (no CAM interference) |
| Overlay — 16 entries full | Program all 16 entries; access 17th bad address | 17th fault returns bad SRAM data (CAM exhausted); no hang |
| Reset vector fault | Force stuck bit at 0x00000 | CPU halts or crashes; `IMEM_BIST_FAIL_ADDR=0`; recovery impossible (expected) |

---

## Related blocks

- [AHB-Lite Bus](AHB-Lite%20Bus.md) — interconnect
- [SPI Master](SPI%20Master.md) — SX1257 config
- [Interrupt Aggregation](Interrupt%20Aggregation.md) — `training_done`, `corr_lock`, and other IRQ sources (in reg_bank)
- [Packet Control FSM](Packet%20Control%20FSM.md) — packet phase, safe W commit, W missed status
- [Training Accumulator](Training%20Accumulator.md) — Z_j source; triggers `IRQ_TRAINING_DONE`; noise-mode cross-correlations for null steering (`IRQ_NOISE_READY`)
- [Weight Generation](Weight%20Generation.md) — archived hardware exploration note
- [MRC Combiner](MRC%20Combiner.md) — W register target
- [Register Map](../Register%20Map.md) — Z_j registers and training diagnostics
- [Register Map](../Register%20Map.md) — `CPU_RESET` at `0x02`
- [Memory Strategy](../Memory%20Strategy.md) — macro selection, BIST architecture, overlay fallback
- [JTAG TAP](JTAG%20TAP.md) — diagnostic complement: halted-CPU memory readback and single-step
