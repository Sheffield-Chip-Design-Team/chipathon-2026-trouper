#include <stdint.h>

#include "asic_regs.h"

/* ---- Fixed-point eigenvector weight computation -------------------------
 *
 * Finds the principal eigenvector of the 4×4 Hermitian channel correlation
 * matrix Z via 8 iterations of the power method, then writes conj(v) as MRC
 * combining weights to the W shadow bank.
 *
 * Fixed-point strategy (all arithmetic in int32):
 *   Off-diagonal Z_kl: int32 register values.
 *   Diagonal ZDIAG_k:  uint16 representing bits [31:16] of the 32-bit sum.
 *   Both are normalised to int12 (±4095) by a shared right-shift so that
 *   each matrix-vector accumulation (7 terms of int12×int12) stays well
 *   within int32 (7×2×4095² ≈ 235M << 2.1G = INT32_MAX).
 *
 *   Between iterations the working vector is re-normalised to ±4096 by a
 *   power-of-2 right-shift (no multiplication, no overflow risk).
 *
 *   Final Q1.15 output: conj(v) / max_component × 32767.
 *   With vr[k] ≤ 4096 and 4096×32767 = 134M < INT32_MAX, division is safe.
 */

#define EIGVEC_ITERS  8
#define EIGVEC_SCALE  12   /* normalise matrix entries to ±(2^12 - 1) */

static void compute_eigvec_weights_fw(uint16_t n_acc)
{
    if (n_acc == 0u) {
        return;
    }

    /* Read the 6 off-diagonal Z_kl complex pairs (int32 per component) */
    int32_t z01i = reg_read32_be(REG_Z01_I_3);
    int32_t z01q = reg_read32_be(REG_Z01_Q_3);
    int32_t z02i = reg_read32_be(REG_Z02_I_3);
    int32_t z02q = reg_read32_be(REG_Z02_Q_3);
    int32_t z03i = reg_read32_be(REG_Z03_I_3);
    int32_t z03q = reg_read32_be(REG_Z03_Q_3);
    int32_t z12i = reg_read32_be(REG_Z12_I_3);
    int32_t z12q = reg_read32_be(REG_Z12_Q_3);
    int32_t z13i = reg_read32_be(REG_Z13_I_3);
    int32_t z13q = reg_read32_be(REG_Z13_Q_3);
    int32_t z23i = reg_read32_be(REG_Z23_I_3);
    int32_t z23q = reg_read32_be(REG_Z23_Q_3);

    /* Read diagonal (top 16 bits of 32-bit Σ|raw_k|²; full value ≈ zdk<<16) */
    uint32_t zd0 = reg_read16_be(REG_ZDIAG_0_HI);
    uint32_t zd1 = reg_read16_be(REG_ZDIAG_1_HI);
    uint32_t zd2 = reg_read16_be(REG_ZDIAG_2_HI);
    uint32_t zd3 = reg_read16_be(REG_ZDIAG_3_HI);

    /* Find global maximum absolute value across all entries (int32 domain).
     * Diagonal stored as upper 16 bits → compare at full int32 scale zdk<<16. */
    uint32_t mx = 1u;
    uint32_t t;
#define UPD_ABS(x) do { \
    t = ((x) < 0) ? (uint32_t)(-(uint32_t)(x)) : (uint32_t)(x); \
    if (t > mx) mx = t; } while (0)
    UPD_ABS(z01i); UPD_ABS(z01q);
    UPD_ABS(z02i); UPD_ABS(z02q);
    UPD_ABS(z03i); UPD_ABS(z03q);
    UPD_ABS(z12i); UPD_ABS(z12q);
    UPD_ABS(z13i); UPD_ABS(z13q);
    UPD_ABS(z23i); UPD_ABS(z23q);
#undef UPD_ABS
    t = zd0 << 16; if (t > mx) mx = t;
    t = zd1 << 16; if (t > mx) mx = t;
    t = zd2 << 16; if (t > mx) mx = t;
    t = zd3 << 16; if (t > mx) mx = t;

    /* Guard: no signal accumulated */
    if (mx <= 1u) {
        return;
    }

    /* Common right-shift to bring max down to EIGVEC_SCALE bits (±4095) */
    int sh = 0;
    {
        uint32_t tmp = mx;
        uint32_t thresh = (uint32_t)((1 << EIGVEC_SCALE) - 1);
        while (tmp > thresh) { tmp >>= 1; sh++; }
    }

    /* Build int16 normalised matrix entries.
     * Diagonal: (zdk << 16) >> sh.  sh was chosen from the same scale,
     * so result fits in [0, 4095] ⊆ int16 range. */
    int16_t d0, d1, d2, d3;
    {
        int net = sh - 16;  /* right-shift to apply to the raw uint16 zdk */
        if (net >= 0) {
            d0 = (int16_t)(zd0 >> net);
            d1 = (int16_t)(zd1 >> net);
            d2 = (int16_t)(zd2 >> net);
            d3 = (int16_t)(zd3 >> net);
        } else {
            /* sh < 16: left-shift but result ≤ 4095 by construction */
            d0 = (int16_t)(zd0 << (-net));
            d1 = (int16_t)(zd1 << (-net));
            d2 = (int16_t)(zd2 << (-net));
            d3 = (int16_t)(zd3 << (-net));
        }
    }

    int16_t r01 = (int16_t)(z01i >> sh), i01 = (int16_t)(z01q >> sh);
    int16_t r02 = (int16_t)(z02i >> sh), i02 = (int16_t)(z02q >> sh);
    int16_t r03 = (int16_t)(z03i >> sh), i03 = (int16_t)(z03q >> sh);
    int16_t r12 = (int16_t)(z12i >> sh), i12 = (int16_t)(z12q >> sh);
    int16_t r13 = (int16_t)(z13i >> sh), i13 = (int16_t)(z13q >> sh);
    int16_t r23 = (int16_t)(z23i >> sh), i23 = (int16_t)(z23q >> sh);

    /* Power iteration.  Start with v = [4096, 0, 0, 0]^T. */
    int32_t vr[4] = { 1 << EIGVEC_SCALE, 0, 0, 0 };
    int32_t vi[4] = { 0, 0, 0, 0 };

    for (int iter = 0; iter < EIGVEC_ITERS; iter++) {
        int32_t wr[4], wi[4];

        /* w = Z * v, Hermitian: Z[l,k] = conj(Z[k,l]) for l > k.
         *
         * Accumulation bound: 7 terms × (int12 × int12) = 7 × 4095²
         * ≈ 117M << INT32_MAX — no overflow.
         *
         * Row 0: Z[0,0]=d0 (real), Z[0,1]=(r01,i01), Z[0,2]=(r02,i02), Z[0,3]=(r03,i03) */
        wr[0] = (int32_t)d0  * vr[0]
              + (int32_t)r01 * vr[1] - (int32_t)i01 * vi[1]
              + (int32_t)r02 * vr[2] - (int32_t)i02 * vi[2]
              + (int32_t)r03 * vr[3] - (int32_t)i03 * vi[3];
        wi[0] = (int32_t)d0  * vi[0]
              + (int32_t)r01 * vi[1] + (int32_t)i01 * vr[1]
              + (int32_t)r02 * vi[2] + (int32_t)i02 * vr[2]
              + (int32_t)r03 * vi[3] + (int32_t)i03 * vr[3];

        /* Row 1: Z[1,0]=conj(M01), Z[1,1]=d1, Z[1,2]=(r12,i12), Z[1,3]=(r13,i13) */
        wr[1] = (int32_t)r01 * vr[0] + (int32_t)i01 * vi[0]
              + (int32_t)d1  * vr[1]
              + (int32_t)r12 * vr[2] - (int32_t)i12 * vi[2]
              + (int32_t)r13 * vr[3] - (int32_t)i13 * vi[3];
        wi[1] = (int32_t)r01 * vi[0] - (int32_t)i01 * vr[0]
              + (int32_t)d1  * vi[1]
              + (int32_t)r12 * vi[2] + (int32_t)i12 * vr[2]
              + (int32_t)r13 * vi[3] + (int32_t)i13 * vr[3];

        /* Row 2: Z[2,0]=conj(M02), Z[2,1]=conj(M12), Z[2,2]=d2, Z[2,3]=(r23,i23) */
        wr[2] = (int32_t)r02 * vr[0] + (int32_t)i02 * vi[0]
              + (int32_t)r12 * vr[1] + (int32_t)i12 * vi[1]
              + (int32_t)d2  * vr[2]
              + (int32_t)r23 * vr[3] - (int32_t)i23 * vi[3];
        wi[2] = (int32_t)r02 * vi[0] - (int32_t)i02 * vr[0]
              + (int32_t)r12 * vi[1] - (int32_t)i12 * vr[1]
              + (int32_t)d2  * vi[2]
              + (int32_t)r23 * vi[3] + (int32_t)i23 * vr[3];

        /* Row 3: Z[3,0]=conj(M03), Z[3,1]=conj(M13), Z[3,2]=conj(M23), Z[3,3]=d3 */
        wr[3] = (int32_t)r03 * vr[0] + (int32_t)i03 * vi[0]
              + (int32_t)r13 * vr[1] + (int32_t)i13 * vi[1]
              + (int32_t)r23 * vr[2] + (int32_t)i23 * vi[2]
              + (int32_t)d3  * vr[3];
        wi[3] = (int32_t)r03 * vi[0] - (int32_t)i03 * vr[0]
              + (int32_t)r13 * vi[1] - (int32_t)i13 * vr[1]
              + (int32_t)r23 * vi[2] - (int32_t)i23 * vr[2]
              + (int32_t)d3  * vi[3];

        /* Re-normalise w to ±4096 via power-of-2 right-shift. */
        uint32_t wmx = 1u;
        for (int k = 0; k < 4; k++) {
            t = (wr[k] < 0) ? (uint32_t)(-(uint32_t)wr[k]) : (uint32_t)wr[k];
            if (t > wmx) wmx = t;
            t = (wi[k] < 0) ? (uint32_t)(-(uint32_t)wi[k]) : (uint32_t)wi[k];
            if (t > wmx) wmx = t;
        }
        int sh2 = 0;
        {
            uint32_t tmp = wmx;
            while (tmp > (uint32_t)(1 << EIGVEC_SCALE)) { tmp >>= 1; sh2++; }
        }
        for (int k = 0; k < 4; k++) {
            vr[k] = wr[k] >> sh2;
            vi[k] = wi[k] >> sh2;
        }
    }

    /* Convert to Q1.15 MRC weights: w_k = conj(v_k) / max_component × 32767.
     * vr[k] ≤ 4096; 4096 × 32767 = 134M < INT32_MAX — no overflow. */
    uint32_t vmx = 1u;
    for (int k = 0; k < 4; k++) {
        t = (vr[k] < 0) ? (uint32_t)(-(uint32_t)vr[k]) : (uint32_t)vr[k];
        if (t > vmx) vmx = t;
        t = (vi[k] < 0) ? (uint32_t)(-(uint32_t)vi[k]) : (uint32_t)vi[k];
        if (t > vmx) vmx = t;
    }
    for (int k = 0; k < 4; k++) {
        int16_t w_re = (int16_t)((vr[k]  * 32767) / (int32_t)vmx);
        int16_t w_im = (int16_t)((-vi[k] * 32767) / (int32_t)vmx);  /* conj */
        uint32_t base = REG_W_0_RE_HI + (uint32_t)((unsigned int)k * 4u);
        reg_write16_be(base,        (uint16_t)w_re);
        reg_write16_be(base + 2u,   (uint16_t)w_im);
    }

    /* Pulse W_COMMIT to promote shadow → active at next safe boundary */
    reg_write8(REG_WGT_CTRL, WGT_CTRL_W_COMMIT);
}

typedef struct {
    uint16_t energy[4];
    int32_t z_i[4];
    int32_t z_q[4];
    uint16_t n_acc;
    uint8_t z_shift;
    uint8_t packet_status;
    uint8_t irq_seen;
} diag_state_t;

static diag_state_t g_diag;

static uint16_t abs16_diff(uint16_t a, uint16_t b)
{
    return (a >= b) ? (uint16_t)(a - b) : (uint16_t)(b - a);
}

static void load_energy_snapshot(uint16_t energy[4])
{
    energy[0] = reg_read16_be(REG_ENERGY_0_HI);
    energy[1] = reg_read16_be(REG_ENERGY_1_HI);
    energy[2] = reg_read16_be(REG_ENERGY_2_HI);
    energy[3] = reg_read16_be(REG_ENERGY_3_HI);
}

static void load_training_snapshot(diag_state_t *diag)
{
    diag->n_acc = reg_read16_be(REG_N_ACC_HI);
    diag->z_shift = reg_read8(REG_Z_SHIFT);
    diag->z_i[0] = reg_read32_be(REG_Z0_I_3);
    diag->z_q[0] = reg_read32_be(REG_Z0_Q_3);
    diag->z_i[1] = reg_read32_be(REG_Z1_I_3);
    diag->z_q[1] = reg_read32_be(REG_Z1_Q_3);
    diag->z_i[2] = reg_read32_be(REG_Z2_I_3);
    diag->z_q[2] = reg_read32_be(REG_Z2_Q_3);
    diag->z_i[3] = reg_read32_be(REG_Z3_I_3);
    diag->z_q[3] = reg_read32_be(REG_Z3_Q_3);
}

static uint16_t estimate_spread_metric(const uint16_t energy[4])
{
    uint16_t min_v = energy[0];
    uint16_t max_v = energy[0];
    uint16_t v;

    v = energy[1];
    if (v < min_v) min_v = v;
    if (v > max_v) max_v = v;

    v = energy[2];
    if (v < min_v) min_v = v;
    if (v > max_v) max_v = v;

    v = energy[3];
    if (v < min_v) min_v = v;
    if (v > max_v) max_v = v;

    return (uint16_t)(max_v - min_v);
}

static uint16_t estimate_packet_snr_like(const uint16_t energy[4], uint16_t n_acc)
{
    uint16_t total = (uint16_t)(energy[0] + energy[1] + energy[2] + energy[3]);
    uint16_t avg = (uint16_t)(total >> 2);
    uint16_t guard = (n_acc == 0u) ? 0u : (uint16_t)(n_acc & 0x00ffu);
    return (uint16_t)(avg + guard);
}

static uint16_t estimate_null_quality(const uint16_t energy[4])
{
    uint16_t d01 = abs16_diff(energy[0], energy[1]);
    uint16_t d23 = abs16_diff(energy[2], energy[3]);
    return (uint16_t)(d01 + d23);
}

static void update_diag_registers(const diag_state_t *diag)
{
    uint16_t cond_num = estimate_spread_metric(diag->energy);
    uint16_t snr_like = estimate_packet_snr_like(diag->energy, diag->n_acc);
    uint16_t null_quality = estimate_null_quality(diag->energy);

    reg_write16_be(REG_COND_NUM_HI, cond_num);
    reg_write16_be(REG_SNR_0_HI, snr_like);
    reg_write16_be(REG_NULL_QUALITY_HI, null_quality);
}

static void handle_corr_lock(diag_state_t *diag)
{
    load_energy_snapshot(diag->energy);
    diag->packet_status = reg_read8(REG_PACKET_STATUS);
}

static void handle_training_done(diag_state_t *diag)
{
    load_energy_snapshot(diag->energy);
    load_training_snapshot(diag);
    diag->packet_status = reg_read8(REG_PACKET_STATUS);
    compute_eigvec_weights_fw(diag->n_acc);
    update_diag_registers(diag);
}

static void handle_packet_done(diag_state_t *diag)
{
    diag->packet_status = reg_read8(REG_PACKET_STATUS);
}

static void handle_tx_event(diag_state_t *diag, uint8_t irq_bits)
{
    diag->irq_seen = irq_bits;
    diag->packet_status = reg_read8(REG_PACKET_STATUS);
}

static void firmware_init(void)
{
    reg_write16_be(REG_COND_NUM_HI, 0u);
    reg_write16_be(REG_SNR_0_HI, 0u);
    reg_write16_be(REG_NULL_QUALITY_HI, 0u);
}

int main(void)
{
    firmware_init();

    for (;;) {
        uint8_t irq_bits = reg_read8(REG_IRQ_STATUS);
        if (irq_bits == 0u) {
            continue;
        }

        g_diag.irq_seen = irq_bits;

        if ((irq_bits & IRQ_CORR_LOCK) != 0u) {
            handle_corr_lock(&g_diag);
        }

        if ((irq_bits & IRQ_TRAINING_DONE) != 0u) {
            handle_training_done(&g_diag);
        }

        if ((irq_bits & IRQ_PACKET_DONE) != 0u) {
            handle_packet_done(&g_diag);
        }

        if ((irq_bits & (IRQ_TX_PREP | IRQ_TX_DONE | IRQ_W_MISSED_PACKET | IRQ_NOISE_READY)) != 0u) {
            handle_tx_event(&g_diag, irq_bits);
        }

        reg_write8(REG_IRQ_CLEAR, irq_bits);
    }
}
