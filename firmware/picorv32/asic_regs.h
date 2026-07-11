#ifndef ASIC_REGS_H
#define ASIC_REGS_H

#include <stdint.h>

/*
 * Register map — authoritative source: planning/Register Map.md (7-bit space,
 * 0x00-0x7F, all registers 8-bit, multi-byte values big-endian MSB-first).
 *
 * ASIC_REG_BASE is the address at which the 128-byte register bank is decoded
 * in the CPU's address space (an SoC-integration detail — must match the
 * Grouper PicoRV32 wrapper's peripheral decode). Override at build time with
 * -DASIC_REG_BASE=... if the integration differs.
 *
 * Define ASIC_REG_TESTMEM to back the register accesses with a local array
 * (g_regfile[256]) instead of MMIO, for host/RTL-free unit testing.
 */
#ifdef ASIC_REG_TESTMEM
extern volatile uint8_t g_regfile[256];
#define ASIC_REG_BASE ((uintptr_t)g_regfile)
#else
#ifndef ASIC_REG_BASE
#define ASIC_REG_BASE 0x00010000u
#endif
#endif

#define REG8(addr)       (*(volatile uint8_t *)(uintptr_t)(addr))
#define ASIC_REG(offset) REG8(ASIC_REG_BASE + (offset))

enum {
    /* Global / IRQ (0x00-0x03) */
    REG_CHIP_ID          = 0x00,
    REG_CHIP_REV         = 0x01,
    REG_IRQ_STATUS       = 0x02,   /* R  sticky sources */
    REG_IRQ_CLEAR        = 0x03,   /* W  write-1-to-clear */

    /* RX / modem config (0x08-0x0F) */
    REG_MIMO_CTRL        = 0x08,   /* [0] MODE, [7:4] ANTENNA_EN */
    REG_SF_CFG           = 0x09,   /* [3:0] SF 7-12 */
    REG_BW_CFG           = 0x0A,
    REG_COMB_CFG         = 0x0F,   /* [2:0] COMB_POST_GAIN_SHIFT, [5:4] REMOD_BACKOFF_SHIFT */

    /* Packet / weight-path / training control (0x1C-0x23) */
    REG_PACKET_STATUS    = 0x1C,   /* [0]ACTIVE [3:1]PHASE [4]TRAINING_DONE [5]W_PENDING [6]W_VALID [7]W_MISSED */
    REG_WGT_CTRL         = 0x1E,   /* [0]W_COMMIT(W1P) [1]W_VALID [2]W_PENDING [3]W_MISSED */
    REG_TACC_NOISE_TRIG  = 0x1F,   /* [0] W1P arm noise accumulation */
    REG_TRAINING_STATUS  = 0x20,   /* [0]TRAINING_DONE [1]TRAINING_ARMED */
    REG_N_ACC_HI         = 0x21,   /* samples [17:16] (bits[1:0]) */
    REG_N_ACC_MID        = 0x22,   /* samples [15:8] */
    REG_N_ACC_LO         = 0x23,   /* samples [7:0] */

    /* W shadow bank (0x30-0x3F) — 4 complex Q1.15 pairs, big-endian.
     * Branch k: RE_HI = 0x30 + 4*k, IM_HI = 0x32 + 4*k. */
    REG_W_0_RE_HI        = 0x30,
    REG_W_0_IM_HI        = 0x32,

    /* Z_kl off-diagonal pair readback — 24-bit [31:8], 3 bytes/component (0x40-0x63).
     * Component base addresses (I then Q, MSB-first). */
    REG_Z01_I            = 0x40, REG_Z01_Q = 0x43,
    REG_Z02_I            = 0x46, REG_Z02_Q = 0x49,
    REG_Z03_I            = 0x4C, REG_Z03_Q = 0x4F,
    REG_Z12_I            = 0x52, REG_Z12_Q = 0x55,
    REG_Z13_I            = 0x58, REG_Z13_Q = 0x5B,
    REG_Z23_I            = 0x5E, REG_Z23_Q = 0x61,

    /* Z_kk diagonal — 24-bit [31:8], 3 bytes each (0x64-0x6F) */
    REG_ZDIAG_0          = 0x64,
    REG_ZDIAG_1          = 0x67,
    REG_ZDIAG_2          = 0x6A,
    REG_ZDIAG_3          = 0x6D
};

/* IRQ_STATUS / IRQ_CLEAR source bits (planning/Register Map.md 0x02) */
enum {
    IRQ_CORR_LOCK       = 1u << 0,
    IRQ_TRAINING_DONE   = 1u << 1,
    IRQ_W_MISSED_PACKET = 1u << 2,
    IRQ_PACKET_DONE     = 1u << 3,
    IRQ_NOISE_READY     = 1u << 4
};

enum { WGT_CTRL_W_COMMIT = 1u << 0 };

enum {
    PACKET_STATUS_ACTIVE_BIT        = 1u << 0,
    PACKET_STATUS_TRAINING_DONE_BIT = 1u << 4,
    PACKET_STATUS_W_PENDING_BIT     = 1u << 5,
    PACKET_STATUS_W_VALID_BIT       = 1u << 6,
    PACKET_STATUS_W_MISSED_BIT      = 1u << 7
};

static inline uint8_t reg_read8(uint32_t offset)              { return ASIC_REG(offset); }
static inline void    reg_write8(uint32_t offset, uint8_t v)  { ASIC_REG(offset) = v; }

/* Big-endian 16-bit at [hi, hi+1] */
static inline uint16_t reg_read16_be(uint32_t hi)
{
    return (uint16_t)(((uint16_t)reg_read8(hi) << 8) | reg_read8(hi + 1u));
}
static inline void reg_write16_be(uint32_t hi, uint16_t v)
{
    reg_write8(hi,      (uint8_t)(v >> 8));
    reg_write8(hi + 1u, (uint8_t)(v & 0xffu));
}

/* Big-endian signed 24-bit [b2,b1,b0] holding bits [31:8] of a signed int32
 * accumulator, returned sign-extended to int32 (i.e. the value Z_kl >> 8). */
static inline int32_t reg_read24_be_signed(uint32_t b2_off)
{
    uint32_t b2 = reg_read8(b2_off);
    uint32_t b1 = reg_read8(b2_off + 1u);
    uint32_t b0 = reg_read8(b2_off + 2u);
    int32_t v = (int32_t)((b2 << 16) | (b1 << 8) | b0);
    if (v & 0x00800000) v |= (int32_t)0xFF000000u;   /* sign-extend 24 -> 32 */
    return v;
}

/* Big-endian unsigned 24-bit [31:8] (diagonal energy, non-negative). */
static inline uint32_t reg_read24_be_unsigned(uint32_t b2_off)
{
    uint32_t b2 = reg_read8(b2_off);
    uint32_t b1 = reg_read8(b2_off + 1u);
    uint32_t b0 = reg_read8(b2_off + 2u);
    return (b2 << 16) | (b1 << 8) | b0;
}

/* 18-bit accumulation count across 0x21(HI[17:16]) / 0x22(MID) / 0x23(LO). */
static inline uint32_t reg_read_n_acc(void)
{
    uint32_t hi  = reg_read8(REG_N_ACC_HI) & 0x03u;
    uint32_t mid = reg_read8(REG_N_ACC_MID);
    uint32_t lo  = reg_read8(REG_N_ACC_LO);
    return (hi << 16) | (mid << 8) | lo;
}

#endif
