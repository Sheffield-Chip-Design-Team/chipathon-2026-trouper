/*
 * LoRa MIMO DSP Chain FPGA Emulation Firmware
 * Arty A7-100T, MicroBlaze, 32 MHz DSP clock
 *
 * fpga_dsp_wrap now instantiates trouper_top.v directly (spi_slave + reg_bank
 * included), so this firmware talks to the ASIC's real host-SPI register
 * interface (see planning/Register Map.md) through a dedicated axi_quad_spi
 * core (axi_quad_spi_1), instead of memory-mapping a custom parallel register
 * file. Real SX1257 samples run through the full chain to REMOD_A_I/Q.
 *
 * There is no int8-level injection port on trouper_top.v itself, but
 * fpga_dsp_wrap.v has an Ethernet-fed injection path: samples pushed here are
 * ΣΔ-re-modulated (via sd_remod, the same core used for the TX path) back
 * into a 1-bit stream that replaces the real SX1257 pins, so injected signals
 * go through the real R=64 decimator and the rest of the chain — unlike the
 * old int8-level bypass. Pushed through axi_inj_ctrl (a separate small AXI
 * peripheral, not part of the ASIC register map).
 *
 * Network (direct cable):
 *   FPGA  192.168.10.2  MAC 02:12:34:56:78:9B
 *   Host  192.168.10.1
 *   UDP status port:  5006  (FPGA -> host, periodic register snapshot)
 *   UDP inject port:  5007  (host -> FPGA, int8 I/Q samples)
 *   UDP control port: 5008  (host -> FPGA, config / weight load)
 *
 * UDP status packet (port 5006):
 *   [0..3]  magic = 0x4C4D494D ("LMIM")
 *   [4]     pkt_type = 2 (status)
 *   [5]     reserved
 *   [6..7]  reserved
 *   [8..11] seq (u32 BE)
 *   [12..]  dsp_status_t (see below)
 *
 * UDP inject packet (port 5007, host -> FPGA):
 *   [0..3]  magic = 0x494E4A54 ("INJT")
 *   [4..7]  sample_count (u32 BE)
 *   [8..]   samples: each = {i0,q0,i1,q1,i2,q2,i3,q3} (8 bytes, int8)
 *
 * UDP control packet (port 5008, host -> FPGA):
 *   [0..3]  magic = 0x43544C52 ("CTLR")
 *   [4]     cmd: 1=set_sf, 2=set_sc_thr, 3=set_bw,
 *                4=load_fw_weights, 5=commit_fw_weights, 6=set_inj_en
 *   [5..]   cmd-specific payload (see handle_control_pkt())
 */

#include "xparameters.h"
#include "xstatus.h"
#include "xemaclite.h"
#include "xspi.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"
#include <string.h>

/* -----------------------------------------------------------------------
 * Network configuration
 * ----------------------------------------------------------------------- */
#define FPGA_MAC        {0x02, 0x12, 0x34, 0x56, 0x78, 0x9B}
#define FPGA_IP         {192, 168, 10, 2}
#define HOST_IP_DEFAULT {192, 168, 10, 1}
#define HOST_MAC_BCAST  {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}

#define UDP_SPORT       5006
#define UDP_STATUS_PORT 5006
#define UDP_INJECT_PORT 5007
#define UDP_CTRL_PORT   5008

/* -----------------------------------------------------------------------
 * axi_inj_ctrl register map (fpga-emul/rtl/axi_inj_ctrl.v) — FPGA-only
 * helper peripheral, NOT part of the ASIC register map.
 * ----------------------------------------------------------------------- */
#ifdef XPAR_AXI_INJ_CTRL_0_BASEADDR
  #define INJ_BASE  XPAR_AXI_INJ_CTRL_0_BASEADDR
#else
  #define INJ_BASE  0x00010000UL   /* fallback -- check Vivado address map */
#endif

#define INJ_CTRL    (INJ_BASE + 0x00)
#define INJ_STATUS  (INJ_BASE + 0x04)
#define INJ_LO      (INJ_BASE + 0x08)
#define INJ_HI      (INJ_BASE + 0x0C)
#define INJ_PERIOD  (INJ_BASE + 0x10)

#define INJ_STATUS_FIFO_EMPTY (1u << 0)
#define INJ_STATUS_FIFO_FULL  (1u << 1)
#define INJ_STATUS_UNDERRUN   (1u << 2)

#define INJ_RD(a)   Xil_In32(a)
#define INJ_WR(a,v) Xil_Out32((a),(v))

/* -----------------------------------------------------------------------
 * axi_clk_sync_mon register map (fpga-emul/rtl/axi_clk_sync_mon.v) — FPGA-only.
 * Measures whether the other three SX1257 CLK_OUTs are phase-locked to the one
 * used as the DSP sample clock (F4). See clk_sync_measure().
 * ----------------------------------------------------------------------- */
#ifdef XPAR_AXI_CLK_SYNC_MON_0_BASEADDR
  #define CSM_BASE  XPAR_AXI_CLK_SYNC_MON_0_BASEADDR
#else
  #define CSM_BASE  0x00020000UL   /* fallback -- check Vivado address map */
#endif

#define CSM_CTRL     (CSM_BASE + 0x00)   /* [0]=ARM (self-clearing) [1]=CONTINUOUS */
#define CSM_STATUS   (CSM_BASE + 0x04)   /* [0]=DONE [1]=RUNNING [10:8]=LEVEL[2:0] */
#define CSM_WINDOW   (CSM_BASE + 0x08)   /* [4:0]=window exponent (2^W cycles) */
#define CSM_TOGGLES0 (CSM_BASE + 0x10)   /* CLK_OUT_1 (F3)  toggle count */
#define CSM_TOGGLES1 (CSM_BASE + 0x14)   /* CLK_OUT_3 (D3) */
#define CSM_TOGGLES2 (CSM_BASE + 0x18)   /* CLK_OUT_4 (C15/D15) */

#define CSM_CTRL_ARM   (1u << 0)
#define CSM_STATUS_DONE (1u << 0)

/* -----------------------------------------------------------------------
 * Trouper register map (planning/Register Map.md) — 7-bit address space,
 * accessed over SPI via axi_quad_spi_1 (see reg_write/reg_read below).
 * ----------------------------------------------------------------------- */
#define REG_CHIP_ID           0x00u
#define REG_CHIP_REV          0x01u
#define REG_IRQ_STATUS        0x02u
#define REG_IRQ_CLEAR         0x03u
#define REG_MIMO_CTRL         0x08u
#define REG_SF_CFG            0x09u
#define REG_BW_CFG            0x0Au
#define REG_PKT_TIMEOUT_SYMS  0x0Bu
#define REG_SC_THR_HI         0x0Cu
#define REG_SC_THR_LO         0x0Du
#define REG_SC_HITS_REQ       0x0Eu
#define REG_COMB_CFG          0x0Fu
#define REG_PACKET_STATUS     0x1Cu
#define REG_ACTIVE_STATUS     0x1Du
#define REG_WGT_CTRL          0x1Eu
#define REG_TACC_NOISE_TRIG   0x1Fu
#define REG_TRAINING_STATUS   0x20u
#define REG_SC_DBG_FLAGS      0x26u
#define REG_W_BANK_BASE       0x30u   /* 16 bytes: 4 branches x {re_hi,re_lo,im_hi,im_lo} */
#define REG_ZDIAG_BASE        0x64u   /* 12 bytes: 4 branches x 3-byte [31:8] */

#define W_BANK_LEN            16u
#define ZDIAG_LEN             12u

/* IRQ_STATUS / IRQ_CLEAR bits */
#define IRQ_CORR_LOCK         (1u << 0)
#define IRQ_TRAINING_DONE     (1u << 1)
#define IRQ_W_MISSED_PACKET   (1u << 2)
#define IRQ_PACKET_DONE       (1u << 3)
#define IRQ_NOISE_READY       (1u << 4)

/* PACKET_STATUS bits */
#define PKT_ACTIVE            (1u << 0)
#define PKT_PHASE_MASK        (0x7u << 1)
#define PKT_TRAINING_DONE     (1u << 4)
#define PKT_W_PENDING         (1u << 5)
#define PKT_W_VALID           (1u << 6)
#define PKT_W_MISSED          (1u << 7)

/* SC_DBG_FLAGS bits */
#define SC_DBG_HIT            (1u << 0)
#define SC_DBG_LOCK           (1u << 3)

/* Defaults (match reg_bank reset values, see Register Map.md) */
#define DEFAULT_SF          7u
#define DEFAULT_BW_SEL      0u    /* 0 = 250 kHz */
#define DEFAULT_SC_THR      0x01CCu
#define DEFAULT_SC_HITS     2u
#define DEFAULT_ANT_EN      0xFu /* all 4 antennas */
#define DEFAULT_PKT_TIMEOUT 0x50u

#define MAGIC_DATA          0x4C4D494Du  /* "LMIM" */
#define MAGIC_INJECT        0x494E4A54u  /* "INJT" */
#define MAGIC_CONTROL       0x43544C52u  /* "CTLR" */
#define PKT_STATUS          2u

#define MAX_INJ_SAMPLES     512u  /* max samples per inject UDP packet */

/* Control commands (UDP port 5008) */
#define CMD_SET_SF            1u
#define CMD_SET_SC_THR         2u
#define CMD_SET_BW             3u
#define CMD_LOAD_FW_WEIGHTS    4u
#define CMD_COMMIT_FW_WEIGHTS  5u
#define CMD_SET_INJ_EN         6u

/* -----------------------------------------------------------------------
 * Ethernet helpers (identical to AFE eval firmware)
 * ----------------------------------------------------------------------- */
#define ETH_ADDR_LEN    6
#define IP_ADDR_LEN     4
#define ETH_TYPE_ARP    0x0806u
#define ETH_TYPE_IPV4   0x0800u
#define ARP_OPER_REQ    0x0001u
#define ARP_OPER_REPLY  0x0002u
#define IPPROTO_ICMP    1u
#define IPPROTO_UDP     17u
#define ICMP_ECHO_REQ   8u
#define ICMP_ECHO_REPLY 0u
#define ETH_HDR_LEN     14u
#define IPV4_HDR_LEN    20u
#define UDP_HDR_LEN     8u
#define ARP_PKT_LEN     28u
#define MIN_ETH_LEN     60u

static u8 FpgaMac[ETH_ADDR_LEN] = FPGA_MAC;
static u8 FpgaIp[IP_ADDR_LEN]   = FPGA_IP;
static u8 HostIp[IP_ADDR_LEN]   = HOST_IP_DEFAULT;
static u8 HostMac[ETH_ADDR_LEN] = HOST_MAC_BCAST;

static XEmacLite EmacInst;
static XSpi     SpiInst;      /* axi_quad_spi_0 -> SX1257 front-ends */
static XSpi     SpiHost;      /* axi_quad_spi_1 -> trouper_top host-SPI slave */

static u8  RxBuf[XEL_MAX_FRAME_SIZE];
static u8  TxBuf[XEL_MAX_FRAME_SIZE];
static u32 udp_seq = 0;

static u16 be16r(const u8 *p) { return (u16)(((u16)p[0]<<8)|p[1]); }
static u32 be32r(const u8 *p) {
    return ((u32)p[0]<<24)|((u32)p[1]<<16)|((u32)p[2]<<8)|p[3];
}
static void be16w(u8 *p, u16 v) { p[0]=v>>8; p[1]=v&0xFF; }
static void be32w(u8 *p, u32 v) {
    p[0]=v>>24; p[1]=(v>>16)&0xFF; p[2]=(v>>8)&0xFF; p[3]=v&0xFF;
}

static u16 ip_cksum(const u8 *d, unsigned len) {
    u32 s=0; unsigned i;
    for(i=0;i+1<len;i+=2) s+=((u32)d[i]<<8)|d[i+1];
    if(len&1) s+=(u32)d[len-1]<<8;
    while(s>>16) s=(s&0xFFFF)+(s>>16);
    return (u16)~s;
}

static void eth_send(const u8 *f, unsigned len) {
    unsigned sl = (len < MIN_ETH_LEN) ? MIN_ETH_LEN : len;
    XEmacLite_Send(&EmacInst, (u8*)f, sl);
}

/* Build full Ethernet/IPv4/UDP frame into TxBuf[].
 * Returns pointer to payload start; writes headers up to that point. */
static u8 *udp_build_hdr(const u8 *dst_mac, const u8 *dst_ip,
                          u16 sport, u16 dport, u16 payload_len) {
    u8 *p = TxBuf;
    u16 ip_tot = (u16)(IPV4_HDR_LEN + UDP_HDR_LEN + payload_len);
    memcpy(p, dst_mac, ETH_ADDR_LEN); p += ETH_ADDR_LEN;
    memcpy(p, FpgaMac, ETH_ADDR_LEN); p += ETH_ADDR_LEN;
    be16w(p, ETH_TYPE_IPV4); p += 2;
    p[0]=0x45; p[1]=0;
    be16w(p+2, ip_tot);
    be16w(p+4, (u16)udp_seq);
    be16w(p+6, 0x4000);
    p[8]=64; p[9]=IPPROTO_UDP;
    be16w(p+10,0);
    memcpy(p+12, FpgaIp, IP_ADDR_LEN);
    memcpy(p+16, dst_ip, IP_ADDR_LEN);
    be16w(p+10, ip_cksum(p, IPV4_HDR_LEN));
    p += IPV4_HDR_LEN;
    be16w(p, sport); be16w(p+2, dport);
    be16w(p+4, (u16)(UDP_HDR_LEN+payload_len));
    be16w(p+6, 0);
    p += UDP_HDR_LEN;
    return p;
}

/* -----------------------------------------------------------------------
 * ARP / ICMP / host MAC learning
 * ----------------------------------------------------------------------- */
static void handle_arp(const u8 *rx, unsigned rlen) {
    const u8 *a = rx + ETH_HDR_LEN;
    u8 *ta = TxBuf + ETH_HDR_LEN;
    if (rlen < ETH_HDR_LEN+ARP_PKT_LEN) return;
    if (be16r(a)!=0x0001||be16r(a+2)!=0x0800) return;
    if (be16r(a+6)!=ARP_OPER_REQ) return;
    if (memcmp(a+24, FpgaIp, IP_ADDR_LEN)!=0) return;
    memcpy(HostMac, a+8, ETH_ADDR_LEN);
    memcpy(HostIp,  a+14, IP_ADDR_LEN);
    memcpy(TxBuf, a+8, ETH_ADDR_LEN);
    memcpy(TxBuf+6, FpgaMac, ETH_ADDR_LEN);
    be16w(TxBuf+12, ETH_TYPE_ARP);
    be16w(ta,0x0001); be16w(ta+2,0x0800);
    ta[4]=6; ta[5]=4; be16w(ta+6,ARP_OPER_REPLY);
    memcpy(ta+8, FpgaMac, ETH_ADDR_LEN); memcpy(ta+14, FpgaIp, IP_ADDR_LEN);
    memcpy(ta+18, a+8, ETH_ADDR_LEN);    memcpy(ta+24, a+14, IP_ADDR_LEN);
    xil_printf("ARP reply to %d.%d.%d.%d\r\n", a[14],a[15],a[16],a[17]);
    eth_send(TxBuf, ETH_HDR_LEN+ARP_PKT_LEN);
}

static void handle_icmp(const u8 *rx, unsigned rlen) {
    const u8 *ip = rx+ETH_HDR_LEN;
    unsigned ihl, tot, icml, txl;
    if (rlen < ETH_HDR_LEN+IPV4_HDR_LEN+8) return;
    if (memcmp(rx, FpgaMac, ETH_ADDR_LEN)!=0) return;
    if (be16r(rx+12)!=ETH_TYPE_IPV4||(ip[0]>>4)!=4) return;
    ihl=(ip[0]&0xF)*4; if(ip[9]!=IPPROTO_ICMP) return;
    if(memcmp(ip+16, FpgaIp, IP_ADDR_LEN)!=0) return;
    if(ip[ihl]!=ICMP_ECHO_REQ) return;
    tot=be16r(ip+2); icml=tot-ihl; txl=ETH_HDR_LEN+tot;
    memcpy(TxBuf, rx+6, ETH_ADDR_LEN); memcpy(TxBuf+6, FpgaMac, ETH_ADDR_LEN);
    be16w(TxBuf+12, ETH_TYPE_IPV4);
    u8 *tip=TxBuf+ETH_HDR_LEN; memcpy(tip, ip, tot);
    tip[8]=64; tip[9]=IPPROTO_ICMP;
    memcpy(tip+12, FpgaIp, IP_ADDR_LEN); memcpy(tip+16, ip+12, IP_ADDR_LEN);
    be16w(tip+10,0); be16w(tip+10, ip_cksum(tip, ihl));
    u8 *tic=tip+ihl; tic[0]=ICMP_ECHO_REPLY; tic[1]=0;
    be16w(tic+2,0); be16w(tic+2, ip_cksum(tic,icml));
    eth_send(TxBuf, txl);
}

/* -----------------------------------------------------------------------
 * Trouper host-SPI register access (axi_quad_spi_1 -> trouper_top spi_slave)
 * Frame format matches rtl-test/tb/tb_trouper_spi.v: command byte
 * {R/W#, addr[6:0]} followed by N data bytes, HOST_CS held low for the
 * whole burst (auto-increment address).
 * ----------------------------------------------------------------------- */
static void reg_write(u8 addr, u8 data) {
    u8 tx[2] = { (u8)(addr & 0x7Fu), data };
    XSpi_SetSlaveSelect(&SpiHost, 1u);
    XSpi_Transfer(&SpiHost, tx, NULL, 2);
}

static u8 reg_read(u8 addr) {
    u8 tx[2] = { (u8)(0x80u | (addr & 0x7Fu)), 0x00u };
    u8 rx[2] = { 0, 0 };
    XSpi_SetSlaveSelect(&SpiHost, 1u);
    XSpi_Transfer(&SpiHost, tx, rx, 2);
    return rx[1];
}

static void reg_write_burst(u8 addr, const u8 *data, u32 n) {
    u8 tx[1u + 16u];
    tx[0] = (u8)(addr & 0x7Fu);
    memcpy(&tx[1], data, n);
    XSpi_SetSlaveSelect(&SpiHost, 1u);
    XSpi_Transfer(&SpiHost, tx, NULL, 1u + n);
}

static void reg_read_burst(u8 addr, u8 *data, u32 n) {
    u8 tx[1u + 16u];
    u8 rx[1u + 16u];
    tx[0] = (u8)(0x80u | (addr & 0x7Fu));
    memset(&tx[1], 0, n);
    XSpi_SetSlaveSelect(&SpiHost, 1u);
    XSpi_Transfer(&SpiHost, tx, rx, 1u + n);
    memcpy(data, &rx[1], n);
}

/* -----------------------------------------------------------------------
 * UDP: send DSP status packet (port 5006)
 * ----------------------------------------------------------------------- */
typedef struct {
    u32 seq;
    u8  packet_status;   /* PACKET_STATUS (0x1C) */
    u8  sc_dbg_flags;    /* SC_DBG_FLAGS (0x26) */
    u8  irq_status;      /* IRQ_STATUS (0x02), cleared after read */
    u8  reserved;
    u8  w_bank[W_BANK_LEN];   /* 0x30-0x3F, raw big-endian int16 pairs */
    u8  zdiag[ZDIAG_LEN];     /* 0x64-0x6F, 4 x 24-bit big-endian */
} dsp_status_t;

static void send_status_pkt(void) {
    dsp_status_t s;
    s.seq           = udp_seq;
    s.packet_status = reg_read(REG_PACKET_STATUS);
    s.sc_dbg_flags  = reg_read(REG_SC_DBG_FLAGS);
    s.irq_status    = reg_read(REG_IRQ_STATUS);
    s.reserved      = 0;
    reg_read_burst(REG_W_BANK_BASE, s.w_bank, W_BANK_LEN);
    reg_read_burst(REG_ZDIAG_BASE,  s.zdiag,  ZDIAG_LEN);

    /* Ack any sticky IRQ bits we just observed */
    if (s.irq_status) reg_write(REG_IRQ_CLEAR, s.irq_status);

    u16 payload_len = (u16)(12u + sizeof(dsp_status_t));
    u8 *p = udp_build_hdr(HostMac, HostIp, UDP_SPORT, UDP_STATUS_PORT, payload_len);
    be32w(p, MAGIC_DATA); p[4]=PKT_STATUS; p[5]=0;
    be16w(p+6, 1); be32w(p+8, udp_seq);
    p += 12;
    memcpy(p, &s, sizeof(s));
    udp_seq++;
    eth_send(TxBuf, (unsigned)(p - TxBuf + sizeof(dsp_status_t)));

    if (s.irq_status & IRQ_CORR_LOCK)
        xil_printf("[IRQ] CORR_LOCK\r\n");
    if (s.irq_status & IRQ_TRAINING_DONE)
        xil_printf("[IRQ] TRAINING_DONE\r\n");
    if (s.irq_status & IRQ_W_MISSED_PACKET)
        xil_printf("[IRQ] W_MISSED_PACKET\r\n");
    if (s.irq_status & IRQ_PACKET_DONE)
        xil_printf("[IRQ] PACKET_DONE\r\n");
    if (s.irq_status & IRQ_NOISE_READY)
        xil_printf("[IRQ] NOISE_READY\r\n");
}

/* -----------------------------------------------------------------------
 * Handle inject packet: host -> FPGA samples for the axi_inj_ctrl FIFO
 * (fpga_dsp_wrap's SD-modulator injection path -- see file header)
 * ----------------------------------------------------------------------- */
static void handle_inject_pkt(const u8 *payload, unsigned plen) {
    u32 n_samples, i;
    const u8 *sp;

    if (plen < 8) return;
    if (be32r(payload) != MAGIC_INJECT) return;
    n_samples = be32r(payload+4);
    if (n_samples > MAX_INJ_SAMPLES) n_samples = MAX_INJ_SAMPLES;
    if (plen < 8u + n_samples*8u) return;

    sp = payload + 8;
    for (i=0; i<n_samples; i++) {
        /* Wait if FIFO full (back-pressure) */
        u32 timeout = 100000;
        while ((INJ_RD(INJ_STATUS) & INJ_STATUS_FIFO_FULL) && --timeout);

        /* Write {i0,q0,i1,q1} to INJ_LO, then {i2,q2,i3,q3} to INJ_HI.
         * INJ_HI write pushes the 64-bit entry into the FIFO. */
        u32 lo = ((u32)(u8)sp[0]<<24)|((u32)(u8)sp[1]<<16)|
                 ((u32)(u8)sp[2]<<8) |(u8)sp[3];
        u32 hi = ((u32)(u8)sp[4]<<24)|((u32)(u8)sp[5]<<16)|
                 ((u32)(u8)sp[6]<<8) |(u8)sp[7];
        INJ_WR(INJ_LO, lo);
        INJ_WR(INJ_HI, hi);
        sp += 8;
    }
    xil_printf("INJ: pushed %u samples\r\n", (unsigned)n_samples);
}

/* -----------------------------------------------------------------------
 * Handle control packet (UDP port 5008)
 * ----------------------------------------------------------------------- */
static void handle_control_pkt(const u8 *payload, unsigned plen) {
    u8 cmd;
    if (plen < 6) return;
    if (be32r(payload) != MAGIC_CONTROL) return;
    cmd = payload[4];

    switch (cmd) {
    case CMD_SET_SF: {
        u8 val = payload[5] & 0xFu;
        if (val < 7u || val > 12u) val = DEFAULT_SF;
        reg_write(REG_SF_CFG, val);
        xil_printf("CTRL: SF=%u\r\n", (unsigned)val);
        break;
    }

    case CMD_SET_SC_THR: {
        if (plen < 10) return;
        u16 thr  = be16r(payload+6) & 0x0FFFu;
        u8  hits = payload[8] & 0x3u;
        if (hits == 0u) hits = 1u;
        reg_write(REG_SC_THR_HI, (u8)(thr >> 8));
        reg_write(REG_SC_THR_LO, (u8)(thr & 0xFF));
        reg_write(REG_SC_HITS_REQ, hits);
        xil_printf("CTRL: sc_thr=0x%03X hits=%u\r\n",
                   (unsigned)thr, (unsigned)hits);
        break;
    }

    case CMD_SET_BW: {
        u8 bw_sel = payload[5] & 0x1u;  /* 0=250 kHz, 1=125 kHz */
        reg_write(REG_BW_CFG, bw_sel);
        xil_printf("CTRL: bw_sel=%u\r\n", (unsigned)bw_sel);
        break;
    }

    case CMD_LOAD_FW_WEIGHTS: {
        /* Payload[5..20]: W_0_re,W_0_im,...,W_3_re,W_3_im (4x2xint16 BE) ==
         * 16 bytes, written directly into the 0x30-0x3F shadow bank. */
        if (plen < 5u + W_BANK_LEN) return;
        reg_write_burst(REG_W_BANK_BASE, payload+5, W_BANK_LEN);
        xil_printf("CTRL: fw weights loaded\r\n");
        break;
    }

    case CMD_COMMIT_FW_WEIGHTS:
        reg_write(REG_WGT_CTRL, 0x01u);   /* W1P */
        xil_printf("CTRL: fw weights committed\r\n");
        break;

    case CMD_SET_INJ_EN: {
        u32 en = payload[5] & 0x1u;
        INJ_WR(INJ_CTRL, en);
        xil_printf("CTRL: inj_en=%u (%s)\r\n", (unsigned)en,
                   en ? "injected samples -> hw_iq" : "real SX1257 pins -> hw_iq");
        break;
    }

    default:
        xil_printf("CTRL: unknown cmd %u\r\n", (unsigned)cmd);
        break;
    }
}

/* -----------------------------------------------------------------------
 * Ethernet frame dispatch
 * ----------------------------------------------------------------------- */
static void handle_udp(const u8 *rx, unsigned rlen) {
    const u8 *ip  = rx + ETH_HDR_LEN;
    unsigned   ihl, udplen;
    const u8  *udp, *payload;
    u16        dport;

    if (rlen < ETH_HDR_LEN+IPV4_HDR_LEN+UDP_HDR_LEN) return;
    if ((ip[0]>>4)!=4) return;
    if (memcmp(ip+16, FpgaIp, IP_ADDR_LEN)!=0) return;
    if (ip[9]!=IPPROTO_UDP) return;
    ihl = (ip[0]&0xF)*4;
    udp = ip+ihl;
    dport  = be16r(udp+2);
    udplen = be16r(udp+4);
    if (udplen < UDP_HDR_LEN) return;
    payload = udp+UDP_HDR_LEN;
    unsigned plen = udplen-UDP_HDR_LEN;

    /* Learn host addresses from any incoming UDP */
    memcpy(HostMac, rx+6, ETH_ADDR_LEN);
    memcpy(HostIp,  ip+12, IP_ADDR_LEN);

    if      (dport == UDP_INJECT_PORT) handle_inject_pkt(payload, plen);
    else if (dport == UDP_CTRL_PORT)   handle_control_pkt(payload, plen);
}

static void process_rx(unsigned rlen) {
    if (rlen < ETH_HDR_LEN) return;
    u16 etype = be16r(RxBuf+12);
    if      (etype == ETH_TYPE_ARP)  handle_arp(RxBuf, rlen);
    else if (etype == ETH_TYPE_IPV4) {
        const u8 *ip = RxBuf+ETH_HDR_LEN;
        if ((ip[0]>>4)==4) {
            if      (ip[9]==IPPROTO_ICMP) handle_icmp(RxBuf, rlen);
            else if (ip[9]==IPPROTO_UDP)  handle_udp(RxBuf, rlen);
        }
    }
}

/* -----------------------------------------------------------------------
 * SX1257 helpers (same as AFE eval firmware) — unchanged, still on
 * axi_quad_spi_0 (SpiInst)
 * ----------------------------------------------------------------------- */
#define SX1257_REG_MODE    0x01
#define SX1257_REG_FRF_MSB 0x04
#define SX1257_REG_FRF_MID 0x05
#define SX1257_REG_FRF_LSB 0x06
#define SX1257_MODE_RX     0x05
/* FRF for 868 MHz: 0xD90000 */

static void sx1257_write(u8 chip, u8 reg, u8 val) {
    u8 buf[2] = {(u8)(reg|0x80u), val};
    XSpi_SetSlaveSelect(&SpiInst, 1u<<chip);
    XSpi_Transfer(&SpiInst, buf, NULL, 2);
}

static void sx1257_init_chip(u8 chip) {
    sx1257_write(chip, SX1257_REG_MODE,    0x01); /* standby */
    usleep(1000);
    sx1257_write(chip, SX1257_REG_FRF_MSB, 0xD9);
    sx1257_write(chip, SX1257_REG_FRF_MID, 0x00);
    sx1257_write(chip, SX1257_REG_FRF_LSB, 0x00);
    sx1257_write(chip, SX1257_REG_MODE,    SX1257_MODE_RX);
    usleep(5000);
    xil_printf("SX1257[%u] init done\r\n", (unsigned)chip);
}

/* -----------------------------------------------------------------------
 * clk_sync_measure — run one CLK_OUT phase-lock measurement window and print
 * the result over UART. win_exp selects the window length (2^win_exp dsp_clk
 * cycles); e.g. 25 ~= 1.05 s at 32 MHz. A locked channel reads ~0 toggles; an
 * unlocked one reads a large count that scales with the window.
 * Requires the SX1257s configured and their CLK_OUTs running first.
 * ----------------------------------------------------------------------- */
static void clk_sync_measure(unsigned win_exp) {
    u32 st, t0, t1, t2;
    u32 spins = 0;

    Xil_Out32(CSM_WINDOW, win_exp & 0x1Fu);
    Xil_Out32(CSM_CTRL,   CSM_CTRL_ARM);        /* one-shot */

    /* Poll DONE. Bounded so a dead sample clock can't hang the CPU forever. */
    do {
        st = Xil_In32(CSM_STATUS);
    } while (!(st & CSM_STATUS_DONE) && (++spins < 200000000u));

    if (!(st & CSM_STATUS_DONE)) {
        xil_printf("CLKSYNC: TIMEOUT (no DONE) - is the DSP sample clock (F4 "
                   "CLK_OUT) running? status=0x%08X\r\n", (unsigned)st);
        return;
    }

    t0 = Xil_In32(CSM_TOGGLES0);
    t1 = Xil_In32(CSM_TOGGLES1);
    t2 = Xil_In32(CSM_TOGGLES2);

    xil_printf("CLKSYNC win=2^%u  levels=%u%u%u\r\n",
               win_exp & 0x1Fu,
               (unsigned)((st >> 10) & 1u),
               (unsigned)((st >> 9)  & 1u),
               (unsigned)((st >> 8)  & 1u));
    xil_printf("  CLK_OUT_1(F3)      toggles=%u  %s\r\n",
               (unsigned)t0, t0 == 0 ? "LOCKED" : "NOT-LOCKED");
    xil_printf("  CLK_OUT_3(D3)      toggles=%u  %s\r\n",
               (unsigned)t1, t1 == 0 ? "LOCKED" : "NOT-LOCKED");
    xil_printf("  CLK_OUT_4(C15/D15) toggles=%u  %s\r\n",
               (unsigned)t2, t2 == 0 ? "LOCKED" : "NOT-LOCKED");
    xil_printf("  (a handful of toggles = locked but sampled near the edge; a "
               "large count that grows with the window = truly not locked)\r\n");
}

/* -----------------------------------------------------------------------
 * main
 * ----------------------------------------------------------------------- */
int main(void) {
    xil_printf("\r\n===== LoRa MIMO DSP Emulation =====\r\n");
    xil_printf("FPGA 192.168.10.2  MAC 02:12:34:56:78:9B\r\n");

    /* ---- Ethernet ---- */
    {
        XEmacLite_Config *ec = XEmacLite_LookupConfig(
#ifdef SDT
            XPAR_XEMACLITE_0_BASEADDR
#else
            XPAR_EMACLITE_0_DEVICE_ID
#endif
        );
        if (!ec) { xil_printf("EmacLite config fail\r\n"); return XST_FAILURE; }
        XEmacLite_CfgInitialize(&EmacInst, ec, ec->BaseAddress);
        XEmacLite_SetMacAddress(&EmacInst, FpgaMac);
        XEmacLite_FlushReceive(&EmacInst);
    }

    /* ---- SPI: SX1257 front-ends (axi_quad_spi_0) ---- */
    {
        XSpi_Config *sc = XSpi_LookupConfig(
#ifdef SDT
            XPAR_XSPI_0_BASEADDR
#else
            XPAR_SPI_0_DEVICE_ID
#endif
        );
        if (!sc) { xil_printf("SPI0 config fail\r\n"); return XST_FAILURE; }
        XSpi_CfgInitialize(&SpiInst, sc, sc->BaseAddress);
        XSpi_SetOptions(&SpiInst, XSP_MASTER_OPTION|XSP_MANUAL_SSELECT_OPTION);
        XSpi_Start(&SpiInst);
        XSpi_IntrGlobalDisable(&SpiInst);
    }

    /* ---- SPI: trouper_top host-SPI slave (axi_quad_spi_1) ---- */
    {
        XSpi_Config *sc = XSpi_LookupConfig(
#ifdef SDT
            XPAR_XSPI_1_BASEADDR
#else
            XPAR_SPI_1_DEVICE_ID
#endif
        );
        if (!sc) { xil_printf("SPI1 (host) config fail\r\n"); return XST_FAILURE; }
        XSpi_CfgInitialize(&SpiHost, sc, sc->BaseAddress);
        XSpi_SetOptions(&SpiHost, XSP_MASTER_OPTION|XSP_MANUAL_SSELECT_OPTION);
        XSpi_Start(&SpiHost);
        XSpi_IntrGlobalDisable(&SpiHost);
    }

    /* ---- Verify the host-SPI link is alive before configuring ---- */
    {
        u8 chip_id  = reg_read(REG_CHIP_ID);
        u8 chip_rev = reg_read(REG_CHIP_REV);
        xil_printf("trouper_top: CHIP_ID=0x%02X CHIP_REV=0x%02X %s\r\n",
                   (unsigned)chip_id, (unsigned)chip_rev,
                   (chip_id == 0xA7) ? "OK" : "MISMATCH");
    }

    /* ---- Configure defaults over the host-SPI link ---- */
    reg_write(REG_MIMO_CTRL, (u8)(DEFAULT_ANT_EN << 4));  /* MODE=MRC, all ants */
    reg_write(REG_SF_CFG, DEFAULT_SF);
    reg_write(REG_BW_CFG, DEFAULT_BW_SEL);
    reg_write(REG_PKT_TIMEOUT_SYMS, DEFAULT_PKT_TIMEOUT);
    reg_write(REG_SC_THR_HI, (u8)(DEFAULT_SC_THR >> 8));
    reg_write(REG_SC_THR_LO, (u8)(DEFAULT_SC_THR & 0xFF));
    reg_write(REG_SC_HITS_REQ, DEFAULT_SC_HITS);
    /* COMB_CFG left at its reset default (0x10). */

#ifdef NO_SX1257
    xil_printf("NO_SX1257: SX1257 init skipped (register-link bring-up only)\r\n");
#else
    {
        u8 chip;
        for (chip=0; chip<4; chip++) sx1257_init_chip(chip);
    }
#endif

    /* CLK_OUT phase-lock check: the SX1257s are configured and their CLK_OUTs
     * are running, so measure whether the other three are locked to the F4
     * sample clock that drives the DSP domain. Short window (2^20 ~= 33 ms) at
     * startup; re-run with a longer window over UDP/JTAG for a tighter bound. */
    clk_sync_measure(20u);

    xil_printf("Ready. Send to UDP 5008 to configure / load weights.\r\n");
    xil_printf("Send to UDP 5007 to inject I/Q samples (see CMD_SET_INJ_EN).\r\n");
    xil_printf("Status snapshots streamed to UDP 5006.\r\n");

    /* =========================================================================
     * Main loop — poll Ethernet, periodically snapshot registers over SPI
     * ========================================================================= */
    u32 loop_cnt = 0;

    while (1) {
        unsigned rlen = XEmacLite_Recv(&EmacInst, RxBuf);
        if (rlen) process_rx(rlen);

        /* Send a status snapshot roughly every ~50k loop iterations */
        loop_cnt++;
        if (loop_cnt >= 50000u) {
            loop_cnt = 0;
            send_status_pkt();
        }
    }

    return 0;
}
