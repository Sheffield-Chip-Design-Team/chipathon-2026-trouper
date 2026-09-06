#include <stdint.h>

#include "asic_regs.h"

/* ---- Fixed-point eigenvector MRC weight computation ----------------------
 *
 * Finds the principal eigenvector of the 4x4 Hermitian channel correlation
 * matrix Z via 8 iterations of the power method, then writes conj(v) as MRC
 * combining weights to the W shadow bank and pulses W_COMMIT.
 *
 * Register scale (current 7-bit map, planning/Register Map.md):
 *   - Off-diagonal Z_kl: signed 24-bit [31:8] of the int32 accumulator, at
 *     0x40-0x63 (3 bytes per I/Q component).
 *   - Diagonal ZDIAG_k:  unsigned 24-bit [31:8] at 0x64-0x6F. Same [31:8]
 *     scale as the off-diagonals, so NO alignment shift is needed between
 *     them (this matched-scale readback is the ~0.9 dB combining-gain fix;
 *     see planning/blocks/Training Accumulator.md "ZDIAG widening").
 *
 * Fixed-point strategy (all arithmetic in int32, EMC/32-bit datapath):
 *   All entries are normalised to int12 (+-4095) by a shared right-shift so
 *   each matrix-vector accumulation (7 terms of int12 x int12) stays within
 *   int32 (7*2*4095^2 ~ 235M << 2^31). Do NOT raise EIGVEC_SCALE past 12
 *   without 64-bit intermediates: the accumulation would overflow int32, and
 *   64-bit mulh on PicoRV32's slow multiplier is the one change that would
 *   materially slow the kernel. The int12 normalisation is verified against
 *   float eigh to < 0.05 deg direction error (sim/tests/test_eigvec_fw.py),
 *   so this is not a precision compromise.
 *
 * Reference model: sim/models/eigvec_fw.py::compute_eigvec_fw().
 */

#define EIGVEC_ITERS 8
#define EIGVEC_SCALE 12   /* normalise matrix entries to +-(2^12 - 1) */
#define NFE_FRAC     16   /* Q bits of the sigma2 EMA state (see note below) */
#define NFE_ALPHA_SH 4    /* EMA alpha = 2^-4 */
#define G_BITS       15   /* Q bits of the per-branch D^-1/2 scale */
#define G_MAX        ((1 << G_BITS) - 1)

/* ---- Noise-weighted MRC -------------------------------------------------
 *
 * Z_kk carries (|h_k|^2 + sigma2_k)*n_acc. With unequal branch noise that
 * pedestal biases the principal eigenvector toward the NOISIEST branch --
 * the inverse of what MRC should do. Two corrections, in increasing order:
 *
 *   de-bias     Z_kk' = max(Z_kk - sigma2_k*n_acc, 0)   -> conj(h),
 *               the EQUAL-noise optimum. Removes the bias, applies no
 *               1/sigma2_k weighting.
 *   SNR-weight  additionally iterate on D^-1/2 Z' D^-1/2 and map back
 *               through D^-1/2                          -> conj(D^-1 h),
 *               the UNEQUAL-noise optimum.
 *
 * sigma2 source: firmware arms a signal-free window with TACC_NOISE_TRIG
 * (0x1F), waits for NOISE_READY (IRQ_STATUS[4]), then reads ZDIAG_k
 * (0x64-0x6F) ~= sigma2_k * n_acc and N_ACC (0x21-0x23).
 *
 * Q16 is not arbitrary. sigma2 is the RATIO ZDIAG_k/n_acc, so a longer noise
 * window does NOT improve its resolution -- only fractional bits do. Measured
 * on real capture data (SGE job 3593): ZDIAG=[11,7,5,4] at n_acc=2048 is
 * sigma2 ~ 0.0034 ZDIAG units/sample, which underflows a Q8 state on three of
 * four branches. A PARTIALLY underflowed estimate is worse than not whitening
 * at all -- subtracting a pedestal from only some branches fabricates an
 * imbalance that was never measured -- so nfe_valid() rejects that case.
 *
 * Cost: the D^-1/2 scale is applied to the ALREADY-NORMALISED matrix, so every
 * product stays inside int32 (2^12 * 2^15 = 2^27) and only MUL is needed --
 * never MULH. That matters here: picorv32 with ENABLE_FAST_MUL=0 costs 40
 * cycles for MUL and 72 for MULH. The post-normalisation scaling itself has
 * 26 MULs; its complete measured cost, including pedestal products, divisions
 * and integer square roots, is +5841 cycles once per packet (SGE job 3608).
 * Scaling the raw matrix instead would need 32x32->64 products (~2190 cycles);
 * folding the scale into each power-iteration step would cost ~5440.
 *
 * Reference model: sim/models/eigvec_fw.py::compute_eigvec_snrw_fw() and
 * sim/models/weight_generation.py::NoiseFloorEstimator. Full record:
 * planning/noise-weighted-mrc-2026-07.md.
 */

/* Per-branch sigma2 EMA, Q(NFE_FRAC), in ZDIAG register units per sample --
 * deliberately the same scale as the Z_kl pairs (both are bits [31:8]), so
 * sigma2*n_acc subtracts straight from a ZDIAG-scale diagonal. */
static uint32_t nfe_sigma2_q[4];
static uint8_t  nfe_n_updates;

/* Weight mode. TODO(policy): with de-biasing alone, whitening cost slightly at
 * MATCHED noise (estimator error against a correction that is a no-op in
 * direction), so gating on measured branch imbalance mattered. With full SNR
 * weighting the upside under imbalance is far larger and the threshold is much
 * less delicate -- but no imbalance threshold has been agreed. Default is
 * SNR-weight whenever the estimate is usable; see planning doc section 7. */
#define NW_MODE_OFF   0
#define NW_MODE_DEBIAS 1
#define NW_MODE_SNRW  2
static uint8_t nw_mode = NW_MODE_SNRW;

/* Integer square root, bit-by-bit. No multiply, no float -- mirrors
 * sim/models/eigvec_fw.py::_isqrt32() so the model stays bit-accurate. */
static uint32_t isqrt32(uint32_t v)
{
    uint32_t root = 0u, bit = 1u << 30, x = v;
    if (v == 0u) return 0u;
    while (bit > x) bit >>= 2;
    while (bit) {
        if (x >= root + bit) { x -= root + bit; root = (root >> 1) + bit; }
        else                 { root >>= 1; }
        bit >>= 2;
    }
    return root;
}

/* True if the estimate is safe to whiten with: either every branch resolved,
 * or none did (all-zero makes whitening an exact no-op). A mix is the
 * dangerous case. */
static int nfe_valid(void)
{
    int nz = 0;
    if (nfe_n_updates == 0u) return 0;
    for (int k = 0; k < 4; k++) if (nfe_sigma2_q[k] != 0u) nz++;
    return (nz == 0) || (nz == 4);
}

/* Fold one completed noise window into the per-branch EMA.
 * Call on NOISE_READY, i.e. an accumulation the hardware certified free of
 * SC contamination. */
void update_noise_floor_fw(void)
{
    uint32_t n_acc = reg_read_n_acc();
    uint32_t zd[4];
    if (n_acc == 0u) return;

    zd[0] = reg_read24_be_unsigned(REG_ZDIAG_0);
    zd[1] = reg_read24_be_unsigned(REG_ZDIAG_1);
    zd[2] = reg_read24_be_unsigned(REG_ZDIAG_2);
    zd[3] = reg_read24_be_unsigned(REG_ZDIAG_3);

    for (int k = 0; k < 4; k++) {
        /* x_q = (zdiag << 16) / n_acc, computed with 32-bit divides only.
         *
         * The direct form reaches 2^40 for a 24-bit ZDIAG and would pull in
         * __udivdi3 -- which is NOT available here: the link uses -nostdlib,
         * so libgcc is not linked and that would be an undefined symbol.
         *
         * Staged long division instead, 8 fractional bits at a time. Each
         * remainder is < n_acc <= 2^18, so (r << 8) <= 2^26 stays in 32 bits.
         * Bit-exact with floor((zdiag << 16)/n_acc), hence with the reference
         * model:  (z<<16)/n = q1<<16 + (r1<<16)/n = q1<<16 + q2<<8 + q3      */
        uint32_t q1 = zd[k] / n_acc, r1 = zd[k] % n_acc;
        uint32_t q2 = (r1 << 8) / n_acc, r2 = (r1 << 8) % n_acc;
        uint32_t q3 = (r2 << 8) / n_acc;
        uint32_t x_q = (q1 << NFE_FRAC) + (q2 << 8) + q3;
        if (nfe_n_updates == 0u) {
            nfe_sigma2_q[k] = x_q;              /* cold start: seed, don't decay up */
        } else {
            int32_t diff = (int32_t)x_q - (int32_t)nfe_sigma2_q[k];
            nfe_sigma2_q[k] = (uint32_t)((int32_t)nfe_sigma2_q[k]
                                         + (diff >> NFE_ALPHA_SH));
        }
    }
    if (nfe_n_updates < 255u) nfe_n_updates++;
}

void compute_eigvec_weights_fw(uint32_t n_acc)
{
    if (n_acc == 0u) return;

    /* Off-diagonal pairs (Z_kl >> 8, signed int32) */
    int32_t r01 = reg_read24_be_signed(REG_Z01_I), q01 = reg_read24_be_signed(REG_Z01_Q);
    int32_t r02 = reg_read24_be_signed(REG_Z02_I), q02 = reg_read24_be_signed(REG_Z02_Q);
    int32_t r03 = reg_read24_be_signed(REG_Z03_I), q03 = reg_read24_be_signed(REG_Z03_Q);
    int32_t r12 = reg_read24_be_signed(REG_Z12_I), q12 = reg_read24_be_signed(REG_Z12_Q);
    int32_t r13 = reg_read24_be_signed(REG_Z13_I), q13 = reg_read24_be_signed(REG_Z13_Q);
    int32_t r23 = reg_read24_be_signed(REG_Z23_I), q23 = reg_read24_be_signed(REG_Z23_Q);

    /* Diagonals (ZDIAG_k >> 8, unsigned) — same [31:8] scale as off-diagonals */
    uint32_t zd0 = reg_read24_be_unsigned(REG_ZDIAG_0);
    uint32_t zd1 = reg_read24_be_unsigned(REG_ZDIAG_1);
    uint32_t zd2 = reg_read24_be_unsigned(REG_ZDIAG_2);
    uint32_t zd3 = reg_read24_be_unsigned(REG_ZDIAG_3);

    /* ---- Noise whitening: remove the sigma2_k * n_acc pedestal ----------
     * Applied at the raw ZDIAG scale, before the normalisation shift below.
     * Clamped at 0 per branch: a negative diagonal would let the power
     * iteration lock onto a negative eigenvalue, since it converges on the
     * largest |lambda|, not the largest lambda. */
    int use_nw = (nw_mode != NW_MODE_OFF) && nfe_valid();
    if (use_nw) {
        uint32_t zdw[4];
        uint32_t zd_in[4];
        uint32_t any = 0u;
        /* Elementwise, not an aggregate initialiser: GCC lowers those to a
         * memcpy from .rodata, and -nostdlib provides no memcpy. */
        zd_in[0] = zd0; zd_in[1] = zd1; zd_in[2] = zd2; zd_in[3] = zd3;
        for (int k = 0; k < 4; k++) {
            /* pedestal = sigma2_q * n_acc >> 16; 2^22 * 2^18 exceeds 32 bits,
             * so this one multiply is 64-bit (MUL+MULHU). 4x per packet. */
            uint32_t ped = (uint32_t)(((uint64_t)nfe_sigma2_q[k] * n_acc) >> NFE_FRAC);
            zdw[k] = (zd_in[k] > ped) ? (zd_in[k] - ped) : 0u;
            any |= zdw[k];
        }
        /* Full-cancellation guard: if whitening flattens every diagonal the
         * matrix carries no usable scale, so keep the raw one. */
        if (any != 0u) { zd0 = zdw[0]; zd1 = zdw[1]; zd2 = zdw[2]; zd3 = zdw[3]; }
        else           { use_nw = 0; }
    }

    /* Global max abs across all entries (all already at the same [31:8] scale) */
    uint32_t mx = 1u, t;
#define UPD_ABS(x) do { t = ((x) < 0) ? (uint32_t)(-(uint32_t)(x)) : (uint32_t)(x); if (t > mx) mx = t; } while (0)
    UPD_ABS(r01); UPD_ABS(q01); UPD_ABS(r02); UPD_ABS(q02); UPD_ABS(r03); UPD_ABS(q03);
    UPD_ABS(r12); UPD_ABS(q12); UPD_ABS(r13); UPD_ABS(q13); UPD_ABS(r23); UPD_ABS(q23);
#undef UPD_ABS
    if (zd0 > mx) mx = zd0;
    if (zd1 > mx) mx = zd1;
    if (zd2 > mx) mx = zd2;
    if (zd3 > mx) mx = zd3;

    if (mx <= 1u) return;

    /* Shared normalisation shift: max >> sh <= 4095 */
    int sh = 0;
    {
        uint32_t tmp = mx, thresh = (uint32_t)((1 << EIGVEC_SCALE) - 1);
        while (tmp > thresh) { tmp >>= 1; sh++; }
    }

    int16_t d0 = (int16_t)(zd0 >> sh), d1 = (int16_t)(zd1 >> sh);
    int16_t d2 = (int16_t)(zd2 >> sh), d3 = (int16_t)(zd3 >> sh);

    int16_t m01r = (int16_t)(r01 >> sh), m01i = (int16_t)(q01 >> sh);
    int16_t m02r = (int16_t)(r02 >> sh), m02i = (int16_t)(q02 >> sh);
    int16_t m03r = (int16_t)(r03 >> sh), m03i = (int16_t)(q03 >> sh);
    int16_t m12r = (int16_t)(r12 >> sh), m12i = (int16_t)(q12 >> sh);
    int16_t m13r = (int16_t)(r13 >> sh), m13i = (int16_t)(q13 >> sh);
    int16_t m23r = (int16_t)(r23 >> sh), m23i = (int16_t)(q23 >> sh);

    /* ---- Full SNR weighting: Z~ = G Z' G, G = diag(g), g_k ~ 1/sqrt(sigma2_k)
     * Built ONCE here from the already-normalised matrix, so every product is
     * <= 2^12 * 2^15 = 2^27 and needs only MUL -- no MULH (72 cyc) anywhere.
     * The power iteration below is then completely untouched, so its existing
     * int32 overflow argument still holds verbatim. */
    uint32_t g[4];
    g[0] = G_MAX; g[1] = G_MAX; g[2] = G_MAX; g[3] = G_MAX;   /* see memcpy note above */
    int use_snrw = use_nw && (nw_mode == NW_MODE_SNRW);
    if (use_snrw) {
        uint32_t sq[4], s_min;
        for (int k = 0; k < 4; k++) {
            uint32_t v = nfe_sigma2_q[k] ? nfe_sigma2_q[k] : 1u;
            sq[k] = isqrt32(v);
            if (sq[k] == 0u) sq[k] = 1u;
        }
        s_min = sq[0];
        for (int k = 1; k < 4; k++) if (sq[k] < s_min) s_min = sq[k];
        /* g_k = GMAX * s_min / s_k  <= GMAX. GMAX * s_min <= 2^15 * 2^11 fits. */
        for (int k = 0; k < 4; k++) {
            uint32_t gk = ((uint32_t)G_MAX * s_min) / sq[k];
            if (gk == 0u)   gk = 1u;
            if (gk > G_MAX) gk = G_MAX;
            g[k] = gk;
        }

        {
            /* gg_kl = (g_k*g_l) >> 15; entry *= gg >> 15. All 32-bit. */
            uint32_t gg;
            gg = (g[0]*g[0]) >> G_BITS; d0   = (int16_t)(((int32_t)d0   * (int32_t)gg) >> G_BITS);
            gg = (g[1]*g[1]) >> G_BITS; d1   = (int16_t)(((int32_t)d1   * (int32_t)gg) >> G_BITS);
            gg = (g[2]*g[2]) >> G_BITS; d2   = (int16_t)(((int32_t)d2   * (int32_t)gg) >> G_BITS);
            gg = (g[3]*g[3]) >> G_BITS; d3   = (int16_t)(((int32_t)d3   * (int32_t)gg) >> G_BITS);
            gg = (g[0]*g[1]) >> G_BITS; m01r = (int16_t)(((int32_t)m01r * (int32_t)gg) >> G_BITS);
                                        m01i = (int16_t)(((int32_t)m01i * (int32_t)gg) >> G_BITS);
            gg = (g[0]*g[2]) >> G_BITS; m02r = (int16_t)(((int32_t)m02r * (int32_t)gg) >> G_BITS);
                                        m02i = (int16_t)(((int32_t)m02i * (int32_t)gg) >> G_BITS);
            gg = (g[0]*g[3]) >> G_BITS; m03r = (int16_t)(((int32_t)m03r * (int32_t)gg) >> G_BITS);
                                        m03i = (int16_t)(((int32_t)m03i * (int32_t)gg) >> G_BITS);
            gg = (g[1]*g[2]) >> G_BITS; m12r = (int16_t)(((int32_t)m12r * (int32_t)gg) >> G_BITS);
                                        m12i = (int16_t)(((int32_t)m12i * (int32_t)gg) >> G_BITS);
            gg = (g[1]*g[3]) >> G_BITS; m13r = (int16_t)(((int32_t)m13r * (int32_t)gg) >> G_BITS);
                                        m13i = (int16_t)(((int32_t)m13i * (int32_t)gg) >> G_BITS);
            gg = (g[2]*g[3]) >> G_BITS; m23r = (int16_t)(((int32_t)m23r * (int32_t)gg) >> G_BITS);
                                        m23i = (int16_t)(((int32_t)m23i * (int32_t)gg) >> G_BITS);
        }
    }

    /* Power iteration. Start v = [4096, 0, 0, 0]^T. */
    int32_t vr[4] = { 1 << EIGVEC_SCALE, 0, 0, 0 };
    int32_t vi[4] = { 0, 0, 0, 0 };

    for (int iter = 0; iter < EIGVEC_ITERS; iter++) {
        int32_t wr[4], wi[4];
        /* w = Z * v, Hermitian: Z[l,k] = conj(Z[k,l]) for l > k. */
        wr[0] = (int32_t)d0*vr[0] + (int32_t)m01r*vr[1]-(int32_t)m01i*vi[1] + (int32_t)m02r*vr[2]-(int32_t)m02i*vi[2] + (int32_t)m03r*vr[3]-(int32_t)m03i*vi[3];
        wi[0] = (int32_t)d0*vi[0] + (int32_t)m01r*vi[1]+(int32_t)m01i*vr[1] + (int32_t)m02r*vi[2]+(int32_t)m02i*vr[2] + (int32_t)m03r*vi[3]+(int32_t)m03i*vr[3];
        wr[1] = (int32_t)m01r*vr[0]+(int32_t)m01i*vi[0] + (int32_t)d1*vr[1] + (int32_t)m12r*vr[2]-(int32_t)m12i*vi[2] + (int32_t)m13r*vr[3]-(int32_t)m13i*vi[3];
        wi[1] = (int32_t)m01r*vi[0]-(int32_t)m01i*vr[0] + (int32_t)d1*vi[1] + (int32_t)m12r*vi[2]+(int32_t)m12i*vr[2] + (int32_t)m13r*vi[3]+(int32_t)m13i*vr[3];
        wr[2] = (int32_t)m02r*vr[0]+(int32_t)m02i*vi[0] + (int32_t)m12r*vr[1]+(int32_t)m12i*vi[1] + (int32_t)d2*vr[2] + (int32_t)m23r*vr[3]-(int32_t)m23i*vi[3];
        wi[2] = (int32_t)m02r*vi[0]-(int32_t)m02i*vr[0] + (int32_t)m12r*vi[1]-(int32_t)m12i*vr[1] + (int32_t)d2*vi[2] + (int32_t)m23r*vi[3]+(int32_t)m23i*vr[3];
        wr[3] = (int32_t)m03r*vr[0]+(int32_t)m03i*vi[0] + (int32_t)m13r*vr[1]+(int32_t)m13i*vi[1] + (int32_t)m23r*vr[2]+(int32_t)m23i*vi[2] + (int32_t)d3*vr[3];
        wi[3] = (int32_t)m03r*vi[0]-(int32_t)m03i*vr[0] + (int32_t)m13r*vi[1]-(int32_t)m13i*vr[1] + (int32_t)m23r*vi[2]-(int32_t)m23i*vr[2] + (int32_t)d3*vi[3];

        uint32_t wmx = 1u;
        for (int k = 0; k < 4; k++) {
            t = (wr[k] < 0) ? (uint32_t)(-(uint32_t)wr[k]) : (uint32_t)wr[k]; if (t > wmx) wmx = t;
            t = (wi[k] < 0) ? (uint32_t)(-(uint32_t)wi[k]) : (uint32_t)wi[k]; if (t > wmx) wmx = t;
        }
        int sh2 = 0;
        { uint32_t tmp = wmx; while (tmp > (uint32_t)(1 << EIGVEC_SCALE)) { tmp >>= 1; sh2++; } }
        for (int k = 0; k < 4; k++) { vr[k] = wr[k] >> sh2; vi[k] = wi[k] >> sh2; }
    }

    /* Map the converged eigenvector of Z~ back through D^-1/2: w = G v~.
     * One scaling, 8 MUL; operands are <= 2^12 so this stays 32-bit too. */
    if (use_snrw) {
        for (int k = 0; k < 4; k++) {
            vr[k] = (vr[k] * (int32_t)g[k]) >> G_BITS;
            vi[k] = (vi[k] * (int32_t)g[k]) >> G_BITS;
        }
    }

    /* Convert conj(v) to Q1.15: w_k = conj(v_k) / max_component * 32767. */
    uint32_t vmx = 1u;
    for (int k = 0; k < 4; k++) {
        t = (vr[k] < 0) ? (uint32_t)(-(uint32_t)vr[k]) : (uint32_t)vr[k]; if (t > vmx) vmx = t;
        t = (vi[k] < 0) ? (uint32_t)(-(uint32_t)vi[k]) : (uint32_t)vi[k]; if (t > vmx) vmx = t;
    }
    for (int k = 0; k < 4; k++) {
        int16_t w_re = (int16_t)((vr[k]  * 32767) / (int32_t)vmx);
        int16_t w_im = (int16_t)((-vi[k] * 32767) / (int32_t)vmx);  /* conj */
        uint32_t base = (uint32_t)(REG_W_0_RE_HI + (unsigned)k * 4u);
        reg_write16_be(base,      (uint16_t)w_re);
        reg_write16_be(base + 2u, (uint16_t)w_im);
    }

    reg_write8(REG_WGT_CTRL, WGT_CTRL_W_COMMIT);   /* promote shadow -> active at safe boundary */
}

static void handle_training_done(void)
{
    compute_eigvec_weights_fw(reg_read_n_acc());
}

#ifndef ASIC_REG_TESTMEM
int main(void)
{
    /* RX_HOLD (0x1A[0]) is SET out of reset: the SC detector is held cleared
     * and cannot lock until firmware releases it, so without this the loop
     * below would poll an IRQ_STATUS that never changes.  This image writes no
     * gated config (SF/BW/timeouts are host-provisioned over SPI before the
     * CPU is released), so it only needs the release half of the bracket --
     * anything that DOES write those registers must use
     * asic_cfg_begin()/asic_cfg_commit() around them.  See
     * planning/Firmware Spec.md §0 and planning/mcp-config-settle-gate-design.md. */
    asic_cfg_commit();

    for (;;) {
        uint8_t irq_bits = reg_read8(REG_IRQ_STATUS);
        if (irq_bits == 0u) continue;

        /* NOISE_READY first: a noise window that completed in the same poll
         * as a training_done must fold into the EMA before the weights that
         * will consume it are computed. */
        if (irq_bits & IRQ_NOISE_READY)   update_noise_floor_fw();
        if (irq_bits & IRQ_TRAINING_DONE) handle_training_done();
        /* CORR_LOCK / PACKET_DONE: no on-chip action in this image; AGC gain
         * stepping remains entirely external-board-controller-side, with no on-chip gain
         * register at all (RX_GAIN_SHADOW/ACTIVE/CTRL at 0x10-0x18 removed
         * 2026-07-28, see planning/blocks/AGC.md). */

        reg_write8(REG_IRQ_CLEAR, irq_bits);
    }
}
#endif
