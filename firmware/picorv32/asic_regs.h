#ifndef ASIC_REGS_H
#define ASIC_REGS_H

#include <stdint.h>

#define ASIC_REG_BASE           0x00010000u
#define ASIC_SPI_MASTER_BASE    0x00010100u
#define ASIC_IRQ_CTRL_BASE      0x00010200u
#define ASIC_JTAG_BASE          0x00010300u

#define REG8(addr)              (*(volatile uint8_t *)(uintptr_t)(addr))

#define ASIC_REG(offset)        REG8(ASIC_REG_BASE + (offset))
#define ASIC_IRQ_REG(offset)    REG8(ASIC_IRQ_CTRL_BASE + (offset))

enum {
    REG_CPU_RESET            = 0x02,
    REG_MIMO_CTRL            = 0x10,
    REG_SF_CFG               = 0x11,
    REG_DECIM_CFG            = 0x12,
    REG_IRQ_STATUS           = 0x32,
    REG_IRQ_CLEAR            = 0x33,
    REG_PACKET_STATUS        = 0x34,
    REG_WGT_CTRL             = 0x35,
    REG_COMB_POST_GAIN       = 0x36,
    REG_ENERGY_0_HI          = 0x40,
    REG_ENERGY_0_LO          = 0x41,
    REG_ENERGY_1_HI          = 0x42,
    REG_ENERGY_1_LO          = 0x43,
    REG_ENERGY_2_HI          = 0x44,
    REG_ENERGY_2_LO          = 0x45,
    REG_ENERGY_3_HI          = 0x46,
    REG_ENERGY_3_LO          = 0x47,
    REG_COND_NUM_HI          = 0x52,
    REG_COND_NUM_LO          = 0x53,
    REG_SNR_0_HI             = 0x54,
    REG_SNR_0_LO             = 0x55,
    REG_NULL_QUALITY_HI      = 0x56,
    REG_NULL_QUALITY_LO      = 0x57,
    REG_TRAINING_STATUS      = 0x60,
    REG_N_ACC_HI             = 0x61,
    REG_N_ACC_LO             = 0x62,
    REG_Z_SHIFT              = 0x63,
    REG_NOISE_WIN_CTRL       = 0x6A,
    REG_TACC_NOISE_TRIG      = 0x6C,
    REG_Z0_I_3               = 0x70,
    REG_Z0_I_2               = 0x71,
    REG_Z0_I_1               = 0x72,
    REG_Z0_I_0               = 0x73,
    REG_Z0_Q_3               = 0x74,
    REG_Z0_Q_2               = 0x75,
    REG_Z0_Q_1               = 0x76,
    REG_Z0_Q_0               = 0x77,
    REG_Z1_I_3               = 0x78,
    REG_Z1_I_2               = 0x79,
    REG_Z1_I_1               = 0x7A,
    REG_Z1_I_0               = 0x7B,
    REG_Z1_Q_3               = 0x7C,
    REG_Z1_Q_2               = 0x7D,
    REG_Z1_Q_1               = 0x7E,
    REG_Z1_Q_0               = 0x7F,
    REG_Z2_I_3               = 0x80,
    REG_Z2_I_2               = 0x81,
    REG_Z2_I_1               = 0x82,
    REG_Z2_I_0               = 0x83,
    REG_Z2_Q_3               = 0x84,
    REG_Z2_Q_2               = 0x85,
    REG_Z2_Q_1               = 0x86,
    REG_Z2_Q_0               = 0x87,
    REG_Z3_I_3               = 0x88,
    REG_Z3_I_2               = 0x89,
    REG_Z3_I_1               = 0x8A,
    REG_Z3_I_0               = 0x8B,
    REG_Z3_Q_3               = 0x8C,
    REG_Z3_Q_2               = 0x8D,
    REG_Z3_Q_1               = 0x8E,
    REG_Z3_Q_0               = 0x8F,

    /* W shadow bank — written by firmware, committed via WGT_CTRL.W_COMMIT */
    REG_W_0_RE_HI            = 0x90,
    REG_W_0_RE_LO            = 0x91,
    REG_W_0_IM_HI            = 0x92,
    REG_W_0_IM_LO            = 0x93,
    REG_W_1_RE_HI            = 0x94,
    REG_W_1_RE_LO            = 0x95,
    REG_W_1_IM_HI            = 0x96,
    REG_W_1_IM_LO            = 0x97,
    REG_W_2_RE_HI            = 0x98,
    REG_W_2_RE_LO            = 0x99,
    REG_W_2_IM_HI            = 0x9A,
    REG_W_2_IM_LO            = 0x9B,
    REG_W_3_RE_HI            = 0x9C,
    REG_W_3_RE_LO            = 0x9D,
    REG_W_3_IM_HI            = 0x9E,
    REG_W_3_IM_LO            = 0x9F,

    /* Z_13 pair (1,3): I[31:0] at 0xD4-0xD7, Q[31:0] at 0xD8-0xDB */
    REG_Z13_I_3              = 0xD4,
    REG_Z13_I_2              = 0xD5,
    REG_Z13_I_1              = 0xD6,
    REG_Z13_I_0              = 0xD7,
    REG_Z13_Q_3              = 0xD8,
    REG_Z13_Q_2              = 0xD9,
    REG_Z13_Q_1              = 0xDA,
    REG_Z13_Q_0              = 0xDB,

    /* Z_23 pair (2,3): I[31:0] at 0xE0-0xE3, Q[31:0] at 0xE4-0xE7 */
    REG_Z23_I_3              = 0xE0,
    REG_Z23_I_2              = 0xE1,
    REG_Z23_I_1              = 0xE2,
    REG_Z23_I_0              = 0xE3,
    REG_Z23_Q_3              = 0xE4,
    REG_Z23_Q_2              = 0xE5,
    REG_Z23_Q_1              = 0xE6,
    REG_Z23_Q_0              = 0xE7,

    /* Z_kk diagonal: top 16 bits of Σ|raw_k|² (32-bit accumulator) */
    REG_ZDIAG_0_HI           = 0xE8,
    REG_ZDIAG_0_LO           = 0xE9,
    REG_ZDIAG_1_HI           = 0xEA,
    REG_ZDIAG_1_LO           = 0xEB,
    REG_ZDIAG_2_HI           = 0xEC,
    REG_ZDIAG_2_LO           = 0xED,
    REG_ZDIAG_3_HI           = 0xEE,
    REG_ZDIAG_3_LO           = 0xEF
};

enum {
    IRQ_CORR_LOCK        = 1u << 0,
    IRQ_TRAINING_DONE    = 1u << 1,
    IRQ_W_MISSED_PACKET  = 1u << 2,
    IRQ_PACKET_DONE      = 1u << 3,
    IRQ_NOISE_READY      = 1u << 4,
    IRQ_TX_PREP          = 1u << 5,
    IRQ_TX_DONE          = 1u << 6
};

/* Aliases for Z pair registers — legacy names Z0..Z3 map to pairs (0,1)..(1,2) */
#define REG_Z01_I_3  REG_Z0_I_3
#define REG_Z01_Q_3  REG_Z0_Q_3
#define REG_Z02_I_3  REG_Z1_I_3
#define REG_Z02_Q_3  REG_Z1_Q_3
#define REG_Z03_I_3  REG_Z2_I_3
#define REG_Z03_Q_3  REG_Z2_Q_3
#define REG_Z12_I_3  REG_Z3_I_3
#define REG_Z12_Q_3  REG_Z3_Q_3

enum {
    WGT_CTRL_W_COMMIT = 1u << 0
};

enum {
    PACKET_STATUS_ACTIVE_BIT        = 1u << 0,
    PACKET_STATUS_TRAINING_DONE_BIT = 1u << 4,
    PACKET_STATUS_W_PENDING_BIT     = 1u << 5,
    PACKET_STATUS_W_VALID_BIT       = 1u << 6,
    PACKET_STATUS_W_MISSED_BIT      = 1u << 7
};

static inline uint8_t reg_read8(uint32_t offset)
{
    return ASIC_REG(offset);
}

static inline void reg_write8(uint32_t offset, uint8_t value)
{
    ASIC_REG(offset) = value;
}

static inline uint16_t reg_read16_be(uint32_t hi_offset)
{
    uint16_t hi = reg_read8(hi_offset);
    uint16_t lo = reg_read8(hi_offset + 1u);
    return (uint16_t)((hi << 8) | lo);
}

static inline void reg_write16_be(uint32_t hi_offset, uint16_t value)
{
    reg_write8(hi_offset, (uint8_t)(value >> 8));
    reg_write8(hi_offset + 1u, (uint8_t)(value & 0xffu));
}

static inline int32_t reg_read32_be(uint32_t b3_offset)
{
    uint32_t b3 = reg_read8(b3_offset);
    uint32_t b2 = reg_read8(b3_offset + 1u);
    uint32_t b1 = reg_read8(b3_offset + 2u);
    uint32_t b0 = reg_read8(b3_offset + 3u);
    return (int32_t)((b3 << 24) | (b2 << 16) | (b1 << 8) | b0);
}

#endif
