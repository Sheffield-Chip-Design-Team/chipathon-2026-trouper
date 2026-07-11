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
    for (;;) {
        uint8_t irq_bits = reg_read8(REG_IRQ_STATUS);
        if (irq_bits == 0u) continue;

        if (irq_bits & IRQ_TRAINING_DONE) handle_training_done();
        /* CORR_LOCK / PACKET_DONE / NOISE_READY: no on-chip action in this
         * image — AGC and noise-EMA policy are host/Grouper-side (see
         * planning/Register Map.md 0x1F / 0x64-0x6F notes). */

        reg_write8(REG_IRQ_CLEAR, irq_bits);
    }
}
#endif
