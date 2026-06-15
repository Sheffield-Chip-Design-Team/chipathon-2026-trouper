/*
 * LoRa MIMO DSP Chain FPGA Emulation Firmware
 * Arty A7-100T, MicroBlaze, 32 MHz DSP clock
 *
 * Three operating modes (controlled by CTRL register bit [1:0]):
 *
 *   MODE 0 — DECIM_ETH
 *     Raw 4-channel decimated I/Q streamed as UDP to host.
 *     Same format as the original AFE eval firmware.
 *     Use when chips arrive to characterise the SX1257 front-end.
 *
 *   MODE 1 — FULL_DSP
 *     Full ASIC DSP chain runs on live SX1257 samples.
 *     Combined I/Q output and status (sc_lock, weights, energy)
 *     streamed as separate UDP packet types.
 *     Use to verify the chain on real RF signals.
 *
 *   MODE 2 — INJECT
 *     Synthetic int8 I/Q samples injected via UDP from host PC.
 *     The hardware rate-matching timer (INJ_PERIOD register) consumes
 *     samples from the injection FIFO at the correct sample rate.
 *     Full DSP chain processes injected samples and streams results back.
 *     Use before SX1257 chips arrive to test DSP correctness.
 *
 * Network (direct cable):
 *   FPGA  192.168.10.2  MAC 02:12:34:56:78:9B
 *   Host  192.168.10.1
 *   UDP data port:    5005  (FPGA → host)
 *   UDP status port:  5006  (FPGA → host)
 *   UDP inject port:  5007  (host → FPGA, INJECT mode)
 *   UDP control port: 5008  (host → FPGA, mode control)
 *
 * UDP data packet (port 5005):
 *   [0..3]  magic = 0x4C4D494D ("LMIM")
 *   [4]     pkt_type: 0=raw_IQ, 1=combined, 2=status
 *   [5]     mode
 *   [6..7]  sample_count (u16 BE)
 *   [8..11] seq (u32 BE)
 *   [12..]  samples (type-dependent, see below)
 *
 *   pkt_type=0 (raw IQ, mode 0): each sample = {i0,q0,i1,q1,i2,q2,i3,q3} (8 bytes)
 *   pkt_type=1 (combined, mode 1/2): each sample = {y_i,y_q,flags} (3 bytes)
 *   pkt_type=2 (status, mode 1/2): 48 bytes of status (see dsp_status_pkt_t)
 *
 * UDP inject packet (port 5007, host → FPGA):
 *   [0..3]  magic = 0x494E4A54 ("INJT")
 *   [4..7]  sample_count (u32 BE)
 *   [8..]   samples: each = {i0,q0,i1,q1,i2,q2,i3,q3} (8 bytes, int8)
 *
 * UDP control packet (port 5008, host → FPGA):
 *   [0..3]  magic = 0x43544C52 ("CTLR")
 *   [4]     cmd: 0=set_mode, 1=set_sf, 2=set_sc_thr, 3=set_decim,
 *                4=load_fw_weights, 5=commit_fw_weights, 6=reset_dsp
 *   [5..]   cmd-specific payload (see handle_control())
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

#define UDP_SPORT       5005
#define UDP_DATA_PORT   5005
#define UDP_STATUS_PORT 5006
#define UDP_INJECT_PORT 5007
#define UDP_CTRL_PORT   5008

/* -----------------------------------------------------------------------
 * DSP controller register map (base from xparameters.h)
 * ----------------------------------------------------------------------- */
#ifdef XPAR_AXI_DSP_CTRL_0_BASEADDR
  #define DSP_BASE  XPAR_AXI_DSP_CTRL_0_BASEADDR
#else
  #define DSP_BASE  0x00020000UL   /* fallback — check Vivado address map */
#endif

#define DSP_CTRL        (DSP_BASE + 0x00)
#define DSP_STATUS      (DSP_BASE + 0x04)
#define DSP_ETH_LO      (DSP_BASE + 0x08)
#define DSP_ETH_HI      (DSP_BASE + 0x0C)
#define DSP_INJ_LO      (DSP_BASE + 0x10)
#define DSP_INJ_HI      (DSP_BASE + 0x14)
#define DSP_INJ_PERIOD  (DSP_BASE + 0x18)
#define DSP_TIMING_REF  (DSP_BASE + 0x1C)
#define DSP_W_RE01      (DSP_BASE + 0x20)
#define DSP_W_IM01      (DSP_BASE + 0x24)
#define DSP_W_RE23      (DSP_BASE + 0x28)
#define DSP_W_IM23      (DSP_BASE + 0x2C)
#define DSP_ENERGY01    (DSP_BASE + 0x30)
#define DSP_ENERGY23    (DSP_BASE + 0x34)
#define DSP_FW_W_RE01   (DSP_BASE + 0x38)
#define DSP_FW_W_IM01   (DSP_BASE + 0x3C)
#define DSP_FW_W_RE23   (DSP_BASE + 0x40)
#define DSP_FW_W_IM23   (DSP_BASE + 0x44)
#define DSP_SC_CFG      (DSP_BASE + 0x48)
#define DSP_NOISE_CFG   (DSP_BASE + 0x4C)
#define DSP_CAL_RE01    (DSP_BASE + 0x50)
#define DSP_CAL_IM01    (DSP_BASE + 0x54)
#define DSP_CAL_RE23    (DSP_BASE + 0x58)
#define DSP_CAL_IM23    (DSP_BASE + 0x5C)
#define DSP_FW_W_COMMIT (DSP_BASE + 0x60)
#define DSP_COMBINED    (DSP_BASE + 0x64)

/* CTRL bit fields */
#define CTRL_MODE_SHIFT       0
#define CTRL_MODE_MASK        0x3u
#define CTRL_RST_DSP          (1u << 2)
#define CTRL_INJ_RATE_EN      (1u << 3)
#define CTRL_DECIM_SHIFT      4
#define CTRL_DC_ALPHA_SHIFT   6
#define CTRL_DC_BYPASS        (1u << 10)
#define CTRL_SF_SHIFT         11
#define CTRL_ANT_EN_SHIFT     15
#define CTRL_WGT_MODE_SHIFT   19
#define CTRL_WGT_AUTO_CMT     (1u << 21)
#define CTRL_POST_GAIN_SHIFT  22
#define CTRL_WGT_SRC          (1u << 27)
#define CTRL_MIMO_MODE        (1u << 28)

/* STATUS bit fields */
#define STATUS_SC_LOCK        (1u << 0)
#define STATUS_TRAIN_DONE     (1u << 1)
#define STATUS_W_COMMIT       (1u << 2)
#define STATUS_PKT_ACTIVE     (1u << 3)
#define STATUS_ETH_EMPTY      (1u << 8)
#define STATUS_ETH_HALF       (1u << 9)
#define STATUS_ETH_FULL       (1u << 10)
#define STATUS_INJ_EMPTY      (1u << 16)
#define STATUS_INJ_FULL       (1u << 17)
#define STATUS_INJ_UNDERRUN   (1u << 18)
#define STATUS_ETH_OVERFLOW   (1u << 19)

/* Mode values */
#define MODE_DECIM_ETH  0u
#define MODE_FULL_DSP   1u
#define MODE_INJECT     2u

/* Defaults */
#define DEFAULT_SF          7u
#define DEFAULT_DECIM_RATIO 0u   /* R=256 → 125 kS/s */
#define DEFAULT_DC_ALPHA    8u
#define DEFAULT_SC_THR      4000u
#define DEFAULT_SC_HITS     3u
#define DEFAULT_ANT_EN      0xFu /* all 4 antennas */
#define INJ_PERIOD_125K     256u /* 32 MHz / 256 = 125 kHz */

/* UDP packet parameters */
#define SAMPLES_PER_PKT     64u
#define MAX_INJ_SAMPLES     512u  /* max samples per inject UDP packet */
#define MAGIC_DATA          0x4C4D494Du  /* "LMIM" */
#define MAGIC_INJECT        0x494E4A54u  /* "INJT" */
#define MAGIC_CONTROL       0x43544C52u  /* "CTLR" */

/* PKT types */
#define PKT_RAW_IQ   0u
#define PKT_COMBINED 1u
#define PKT_STATUS   2u

/* Control commands */
#define CMD_SET_MODE       0u
#define CMD_SET_SF         1u
#define CMD_SET_SC_THR     2u
#define CMD_SET_DECIM      3u
#define CMD_LOAD_FW_WEIGHTS 4u
#define CMD_COMMIT_FW_WEIGHTS 5u
#define CMD_RESET_DSP      6u

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
static XSpi     SpiInst;

static u8  RxBuf[XEL_MAX_FRAME_SIZE];
static u8  TxBuf[XEL_MAX_FRAME_SIZE];
static u32 udp_seq     = 0;
static u32 current_mode = MODE_DECIM_ETH;
static u32 current_ctrl = 0;

#define DSP_RD(a)     Xil_In32(a)
#define DSP_WR(a,v)   Xil_Out32((a),(v))

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
 * DSP controller helpers
 * ----------------------------------------------------------------------- */
static void dsp_set_ctrl(u32 val) {
    current_ctrl = val;
    DSP_WR(DSP_CTRL, val);
}

static u32 dsp_build_ctrl(u32 mode, u32 sf, u32 decim, u32 dc_alpha,
                           u32 antenna_en, u32 wgt_mode, u32 post_gain,
                           int inj_rate_en) {
    return (mode         & 0x3u)
         | ((u32)inj_rate_en << 3)
         | ((decim       & 0x3u) << CTRL_DECIM_SHIFT)
         | ((dc_alpha    & 0xFu) << CTRL_DC_ALPHA_SHIFT)
         | ((sf          & 0xFu) << CTRL_SF_SHIFT)
         | ((antenna_en  & 0xFu) << CTRL_ANT_EN_SHIFT)
         | ((wgt_mode    & 0x3u) << CTRL_WGT_MODE_SHIFT)
         | CTRL_WGT_AUTO_CMT
         | ((post_gain   & 0x7u) << CTRL_POST_GAIN_SHIFT);
}

/* -----------------------------------------------------------------------
 * UDP: send raw I/Q packet (mode 0, DECIM_ETH)
 * samples: array of SAMPLES_PER_PKT entries, each 8 bytes {i0,q0,i1,q1,i2,q2,i3,q3}
 * ----------------------------------------------------------------------- */
static void send_raw_iq_pkt(u8 samples[][8], u32 count) {
    u16 payload_len = (u16)(12u + count*8u);
    u8 *p = udp_build_hdr(HostMac, HostIp, UDP_SPORT, UDP_DATA_PORT, payload_len);
    be32w(p, MAGIC_DATA); p[4]=PKT_RAW_IQ; p[5]=(u8)current_mode;
    be16w(p+6, (u16)count); be32w(p+8, udp_seq);
    p += 12;
    u32 i;
    for (i=0; i<count; i++) { memcpy(p, samples[i], 8); p+=8; }
    udp_seq++;
    eth_send(TxBuf, (unsigned)(p - TxBuf));
}

/* -----------------------------------------------------------------------
 * UDP: send combined output packet (mode 1/2, FULL_DSP/INJECT)
 * samples: array of SAMPLES_PER_PKT entries, each 4 bytes {y_i,y_q,flags,0}
 * ----------------------------------------------------------------------- */
static void send_combined_pkt(u8 samples[][4], u32 count) {
    u16 payload_len = (u16)(12u + count*4u);
    u8 *p = udp_build_hdr(HostMac, HostIp, UDP_SPORT, UDP_DATA_PORT, payload_len);
    be32w(p, MAGIC_DATA); p[4]=PKT_COMBINED; p[5]=(u8)current_mode;
    be16w(p+6, (u16)count); be32w(p+8, udp_seq);
    p += 12;
    u32 i;
    for (i=0; i<count; i++) { memcpy(p, samples[i], 4); p+=4; }
    udp_seq++;
    eth_send(TxBuf, (unsigned)(p - TxBuf));
}

/* -----------------------------------------------------------------------
 * UDP: send DSP status packet (mode 1/2)
 * ----------------------------------------------------------------------- */
typedef struct {
    u32 seq;
    u32 status;         /* raw STATUS register */
    u32 timing_ref;
    u16 W_re[4];
    u16 W_im[4];
    u16 energy[4];
} dsp_status_t;         /* 48 bytes */

static void send_status_pkt(void) {
    dsp_status_t s;
    u32 w;
    s.seq        = udp_seq;
    s.status     = DSP_RD(DSP_STATUS);
    s.timing_ref = DSP_RD(DSP_TIMING_REF);
    w=DSP_RD(DSP_W_RE01); s.W_re[0]=(u16)(w&0xFFFF); s.W_re[1]=(u16)(w>>16);
    w=DSP_RD(DSP_W_RE23); s.W_re[2]=(u16)(w&0xFFFF); s.W_re[3]=(u16)(w>>16);
    w=DSP_RD(DSP_W_IM01); s.W_im[0]=(u16)(w&0xFFFF); s.W_im[1]=(u16)(w>>16);
    w=DSP_RD(DSP_W_IM23); s.W_im[2]=(u16)(w&0xFFFF); s.W_im[3]=(u16)(w>>16);
    w=DSP_RD(DSP_ENERGY01); s.energy[0]=(u16)(w&0xFFFF); s.energy[1]=(u16)(w>>16);
    w=DSP_RD(DSP_ENERGY23); s.energy[2]=(u16)(w&0xFFFF); s.energy[3]=(u16)(w>>16);

    u16 payload_len = (u16)(12u + sizeof(dsp_status_t));
    u8 *p = udp_build_hdr(HostMac, HostIp, UDP_SPORT, UDP_STATUS_PORT, payload_len);
    be32w(p, MAGIC_DATA); p[4]=PKT_STATUS; p[5]=(u8)current_mode;
    be16w(p+6, 1); be32w(p+8, udp_seq);
    p += 12;
    memcpy(p, &s, sizeof(s));
    udp_seq++;
    eth_send(TxBuf, (unsigned)(p - TxBuf + sizeof(dsp_status_t)));
}

/* -----------------------------------------------------------------------
 * Handle inject packet: host → FPGA samples for injection FIFO
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
        while ((DSP_RD(DSP_STATUS) & STATUS_INJ_FULL) && --timeout);

        /* Write {i0,q0,i1,q1} to INJ_LO, then {i2,q2,i3,q3} to INJ_HI.
         * INJ_HI write pushes the 64-bit entry into the FIFO. */
        u32 lo = ((u32)(u8)sp[0]<<24)|((u32)(u8)sp[1]<<16)|
                 ((u32)(u8)sp[2]<<8) |(u8)sp[3];
        u32 hi = ((u32)(u8)sp[4]<<24)|((u32)(u8)sp[5]<<16)|
                 ((u32)(u8)sp[6]<<8) |(u8)sp[7];
        DSP_WR(DSP_INJ_LO, lo);
        DSP_WR(DSP_INJ_HI, hi);
        sp += 8;
    }
    xil_printf("INJ: pushed %u samples\r\n", (unsigned)n_samples);
}

/* -----------------------------------------------------------------------
 * Handle control packet
 * ----------------------------------------------------------------------- */
static void handle_control_pkt(const u8 *payload, unsigned plen) {
    u8 cmd;
    u32 val;
    if (plen < 6) return;
    if (be32r(payload) != MAGIC_CONTROL) return;
    cmd = payload[4];

    switch (cmd) {
    case CMD_SET_MODE:
        if (plen < 6) return;
        val = payload[5] & 0x3u;
        current_mode = val;
        current_ctrl = (current_ctrl & ~CTRL_MODE_MASK) | val;
        /* Enable rate-matching timer when switching to INJECT */
        if (val == MODE_INJECT)
            current_ctrl |= CTRL_INJ_RATE_EN;
        else
            current_ctrl &= ~CTRL_INJ_RATE_EN;
        dsp_set_ctrl(current_ctrl);
        xil_printf("CTRL: mode=%u\r\n", (unsigned)val);
        break;

    case CMD_SET_SF:
        if (plen < 6) return;
        val = payload[5] & 0xFu;
        if (val < 6u || val > 12u) val = DEFAULT_SF;
        current_ctrl = (current_ctrl & ~(0xFu<<CTRL_SF_SHIFT))|(val<<CTRL_SF_SHIFT);
        dsp_set_ctrl(current_ctrl);
        DSP_WR(DSP_INJ_PERIOD, 1u<<val);  /* update injection period = 2^sf cycles */
        xil_printf("CTRL: SF=%u, inj_period=%u\r\n", (unsigned)val, 1u<<val);
        break;

    case CMD_SET_SC_THR:
        if (plen < 10) return;
        {
            u16 thr   = (u16)be16r(payload+6);
            u8  hits  = payload[8] & 0x7u;
            DSP_WR(DSP_SC_CFG, ((u32)hits<<16)|(u32)thr);
            xil_printf("CTRL: sc_thr=%u hits=%u\r\n",
                       (unsigned)thr, (unsigned)hits);
        }
        break;

    case CMD_SET_DECIM:
        if (plen < 6) return;
        val = payload[5] & 0x3u;  /* 0=R256, 1=R128, 2=R64, 3=R32 */
        current_ctrl = (current_ctrl & ~(0x3u<<CTRL_DECIM_SHIFT))
                     | (val<<CTRL_DECIM_SHIFT);
        dsp_set_ctrl(current_ctrl);
        xil_printf("CTRL: decim_ratio=%u\r\n", (unsigned)val);
        break;

    case CMD_LOAD_FW_WEIGHTS:
        /* Payload[5..36]: W_re0,W_im0,...,W_re3,W_im3 (4×2×int16 BE) */
        if (plen < 5u+32u) return;
        {
            const u8 *wp = payload+5;
            u32 re01 = ((u32)(u16)be16r(wp+2)<<16)|(u16)be16r(wp+0);
            u32 im01 = ((u32)(u16)be16r(wp+6)<<16)|(u16)be16r(wp+4);
            u32 re23 = ((u32)(u16)be16r(wp+10)<<16)|(u16)be16r(wp+8);
            u32 im23 = ((u32)(u16)be16r(wp+14)<<16)|(u16)be16r(wp+12);
            DSP_WR(DSP_FW_W_RE01, re01);
            DSP_WR(DSP_FW_W_IM01, im01);
            DSP_WR(DSP_FW_W_RE23, re23);
            DSP_WR(DSP_FW_W_IM23, im23);
            xil_printf("CTRL: fw weights loaded\r\n");
        }
        break;

    case CMD_COMMIT_FW_WEIGHTS:
        DSP_WR(DSP_FW_W_COMMIT, 1u);
        xil_printf("CTRL: fw weights committed\r\n");
        break;

    case CMD_RESET_DSP:
        /* Assert RST, wait, deassert */
        DSP_WR(DSP_CTRL, current_ctrl | CTRL_RST_DSP);
        usleep(100);
        DSP_WR(DSP_CTRL, current_ctrl & ~CTRL_RST_DSP);
        xil_printf("CTRL: DSP reset\r\n");
        break;

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
 * SX1257 helpers (same as AFE eval firmware)
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

    /* ---- SPI ---- */
    {
        XSpi_Config *sc = XSpi_LookupConfig(
#ifdef SDT
            XPAR_XSPI_0_BASEADDR
#else
            XPAR_SPI_0_DEVICE_ID
#endif
        );
        if (!sc) { xil_printf("SPI config fail\r\n"); return XST_FAILURE; }
        XSpi_CfgInitialize(&SpiInst, sc, sc->BaseAddress);
        XSpi_SetOptions(&SpiInst, XSP_MASTER_OPTION|XSP_MANUAL_SSELECT_OPTION);
        XSpi_Start(&SpiInst);
        XSpi_IntrGlobalDisable(&SpiInst);
    }

    /* ---- Reset DSP chain ---- */
    DSP_WR(DSP_CTRL, CTRL_RST_DSP);
    usleep(100);

    /* ---- Configure defaults ---- */
    DSP_WR(DSP_SC_CFG,    ((u32)DEFAULT_SC_HITS<<16)|(u32)DEFAULT_SC_THR);
    DSP_WR(DSP_NOISE_CFG, (20u<<16)|200u);
    DSP_WR(DSP_INJ_PERIOD, INJ_PERIOD_125K);

    /* Default CTRL: MODE=DECIM_ETH, SF=7, R=256, DC_alpha=8, all ants */
    current_ctrl = dsp_build_ctrl(MODE_DECIM_ETH, DEFAULT_SF, DEFAULT_DECIM_RATIO,
                                  DEFAULT_DC_ALPHA, DEFAULT_ANT_EN, 0, 2, 0);
    current_mode = MODE_DECIM_ETH;
    DSP_WR(DSP_CTRL, current_ctrl);  /* deassert rst_dsp */

#ifdef NO_SX1257
    xil_printf("NO_SX1257: SX1257 init skipped (inject/emulation only)\r\n");
#else
    {
        u8 chip;
        for (chip=0; chip<4; chip++) sx1257_init_chip(chip);
    }
#endif

    xil_printf("Ready. Mode=%u (0=DECIM_ETH, 1=FULL_DSP, 2=INJECT)\r\n",
               (unsigned)current_mode);
    xil_printf("Send to UDP 5008 to change mode / load weights\r\n");
    xil_printf("Send to UDP 5007 to inject I/Q samples (mode 2)\r\n");

    /* =========================================================================
     * Main loop
     * ========================================================================= */
    static u8 raw_samples[SAMPLES_PER_PKT][8];
    static u8 comb_samples[SAMPLES_PER_PKT][4];
    u32 raw_cnt  = 0;
    u32 comb_cnt = 0;
    u32 loop_cnt = 0;
    u32 last_status_seq = 0;

    while (1) {
        /* --- Poll Ethernet --- */
        unsigned rlen = XEmacLite_Recv(&EmacInst, RxBuf);
        if (rlen) process_rx(rlen);

        /* --- Read DSP STATUS --- */
        u32 status = DSP_RD(DSP_STATUS);

        /* --- Drain ETH output FIFO --- */
        while (!(status & STATUS_ETH_EMPTY)) {
            u32 lo, hi;
            /* Read ETH_LO: pops FIFO entry into shadow, returns shadow[63:32]
             * (previous entry low word on first read). Protocol: read ETH_LO
             * to trigger pop, read ETH_HI for high word (both same entry). */
            lo = DSP_RD(DSP_ETH_LO);
            hi = DSP_RD(DSP_ETH_HI);

            if (current_mode == MODE_DECIM_ETH) {
                /* lo = {i0,q0,i1,q1}  hi = {i2,q2,i3,q3} */
                raw_samples[raw_cnt][0] = (u8)(lo>>24);
                raw_samples[raw_cnt][1] = (u8)(lo>>16);
                raw_samples[raw_cnt][2] = (u8)(lo>>8);
                raw_samples[raw_cnt][3] = (u8)(lo);
                raw_samples[raw_cnt][4] = (u8)(hi>>24);
                raw_samples[raw_cnt][5] = (u8)(hi>>16);
                raw_samples[raw_cnt][6] = (u8)(hi>>8);
                raw_samples[raw_cnt][7] = (u8)(hi);
                raw_cnt++;
                if (raw_cnt >= SAMPLES_PER_PKT) {
                    send_raw_iq_pkt(raw_samples, raw_cnt);
                    raw_cnt = 0;
                }
            } else {
                /* Mode 1/2: lo[63:56]=y_i, lo[55:48]=y_q, lo[47]=sc_lock,
                 *           lo[46]=training_done, lo[45]=W_commit, lo[44]=pkt_active */
                comb_samples[comb_cnt][0] = (u8)(lo>>24);   /* y_i */
                comb_samples[comb_cnt][1] = (u8)(lo>>16);   /* y_q */
                comb_samples[comb_cnt][2] = (u8)(lo>>8);    /* flags byte */
                comb_samples[comb_cnt][3] = 0;
                comb_cnt++;
                if (comb_cnt >= SAMPLES_PER_PKT) {
                    send_combined_pkt(comb_samples, comb_cnt);
                    comb_cnt = 0;
                }
            }

            status = DSP_RD(DSP_STATUS);
        }

        /* Flush partial packets every ~1000 iterations to avoid stale data */
        loop_cnt++;
        if (loop_cnt >= 1000u) {
            loop_cnt = 0;
            if (raw_cnt > 0 && current_mode == MODE_DECIM_ETH) {
                send_raw_iq_pkt(raw_samples, raw_cnt);
                raw_cnt = 0;
            }
            if (comb_cnt > 0 && current_mode != MODE_DECIM_ETH) {
                send_combined_pkt(comb_samples, comb_cnt);
                comb_cnt = 0;
            }
        }

        /* Send status packet periodically in FULL_DSP/INJECT modes */
        if (current_mode != MODE_DECIM_ETH &&
            (udp_seq - last_status_seq) >= 50u) {
            send_status_pkt();
            last_status_seq = udp_seq;
        }

        /* Log SC lock / training events to UART */
        if (status & STATUS_SC_LOCK)
            xil_printf("[SC] lock  timing_ref=0x%08X\r\n",
                       (unsigned)DSP_RD(DSP_TIMING_REF));
        if (status & STATUS_W_COMMIT)
            xil_printf("[W]  weights committed\r\n");
        if (status & STATUS_ETH_OVERFLOW)
            xil_printf("[!]  ETH FIFO overflow\r\n");
        if (status & STATUS_INJ_UNDERRUN)
            xil_printf("[!]  injection FIFO underrun\r\n");
    }

    return 0;
}
