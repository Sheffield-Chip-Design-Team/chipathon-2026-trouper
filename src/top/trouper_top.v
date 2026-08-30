// trouper_top.v
// Standalone Trouper top-level integration
// GF180MCU 3.3V 32 MHz — SSCS PICO Chipathon 2026
//
// Pad count: 23 signal + 2 power = 25 total (within Chipathon allocation)
//            clk/rst×2, IQ×8, remod×2, PSRAM SCK+CE_N×2,
//            SPI HOST_CS/SCK/MOSI/MISO×4,
//            IRQ_OUT×1 (dedicated pad) + PSRAM-SIO[3:0]×4 (dedicated).
//            JTAG/GPIO removed — no TAP in RTL.
//            VDD_CORE/GND×2. No separate VDD_IO pad — the reference PDN
//            ties the padring to VDD_CORE (see planning/Pinout.md,
//            planning/5v-core-voltage-strategy.md §2026-08-19).
//            CS_A removed (SPI master not present).
//
// Signal flow:
//   SX1257[0..3] 1-bit IQ → sd_decimator×4 → dc_removal → psram_buf_ctrl
//   (cur/del via PSRAM) → sc_detector → training_acc → [SW weights via reg_bank] → mrc_combiner
//   → sd_remod → SX1302 Radio A (1-bit IQ)
//
// Control plane:
//   Host RPi → SPI slave (HOST_CS/SCK/MOSI/MISO pads) → reg_bank byte interface
//   Grouper  → GRP_ADDR/WDATA/WE/RE/RDATA/READY inter-chip bus → reg_bank (priority)
//   IRQ: irq_out (sticky) → IRQ_OUT dedicated pad + IRQ_GROUPER inter-chip

`ifndef TROUPER_TOP_V
`define TROUPER_TOP_V

`default_nettype none

module trouper_top (
    // ---- Clock and reset ----
    input  wire        IQ_CLK,       // 32 MHz from PCB TCXO buffer
    input  wire        RESETB,       // active-low chip reset

    // ---- SX1257 → ASIC: 1-bit sigma-delta IQ streams ----
    input  wire        IQ_DATA_I_0,  // ant0
    input  wire        IQ_DATA_I_1,  // ant1
    input  wire        IQ_DATA_I_2,  // ant2
    input  wire        IQ_DATA_I_3,  // ant3
    input  wire        IQ_DATA_Q_0,  // ant0
    input  wire        IQ_DATA_Q_1,  // ant1
    input  wire        IQ_DATA_Q_2,  // ant2
    input  wire        IQ_DATA_Q_3,  // ant3

    // ---- ASIC → SX1302: MRC-combined sigma-delta output ----
    output wire        REMOD_A_I_OUT,
    output wire        REMOD_A_Q_OUT,

    // ---- PSRAM QPI (SIO[3:0] on four dedicated pads) ----
    output wire        PSRAM_SCK_OUT,     // PSRAM clock (32 MHz, gated in psram_buf_ctrl)
    output wire        PSRAM_CE_N_OUT,
    output wire        PSRAM_SIO_0_OUT,
    output wire        PSRAM_SIO_1_OUT,
    output wire        PSRAM_SIO_2_OUT,
    output wire        PSRAM_SIO_3_OUT,
    input  wire        PSRAM_SIO_0_IN,
    input  wire        PSRAM_SIO_1_IN,
    input  wire        PSRAM_SIO_2_IN,
    input  wire        PSRAM_SIO_3_IN,
    output wire        PSRAM_SIO_0_OE,
    output wire        PSRAM_SIO_1_OE,
    output wire        PSRAM_SIO_2_OE,
    output wire        PSRAM_SIO_3_OE,

    // ---- Host SPI slave (RPi) ----
    input  wire        HOST_CS,       // active-low chip select from RPi
    input  wire        SPI_SCK,       // SPI clock (Mode 0, up to 2 MHz)
    input  wire        SPI_MOSI,
    output wire        SPI_MISO_OUT,

    // ---- Grouper inter-project register bus (priority over SPI) ----
    input  wire        GRP_ADDR_0,
    input  wire        GRP_ADDR_1,
    input  wire        GRP_ADDR_2,
    input  wire        GRP_ADDR_3,
    input  wire        GRP_ADDR_4,
    input  wire        GRP_ADDR_5,
    input  wire        GRP_ADDR_6,
    input  wire        GRP_ADDR_7,
    input  wire        GRP_WDATA_0,
    input  wire        GRP_WDATA_1,
    input  wire        GRP_WDATA_2,
    input  wire        GRP_WDATA_3,
    input  wire        GRP_WDATA_4,
    input  wire        GRP_WDATA_5,
    input  wire        GRP_WDATA_6,
    input  wire        GRP_WDATA_7,
    input  wire        GRP_WE,
    input  wire        GRP_RE,
    output wire        GRP_RDATA_0,
    output wire        GRP_RDATA_1,
    output wire        GRP_RDATA_2,
    output wire        GRP_RDATA_3,
    output wire        GRP_RDATA_4,
    output wire        GRP_RDATA_5,
    output wire        GRP_RDATA_6,
    output wire        GRP_RDATA_7,
    output wire        GRP_READY,

    // ---- Grouper dev external-peripheral AHB endpoint (8-bit) ----
    // This is the real Grouper origin/dev boundary.  It is kept alongside the
    // legacy GRP_* placeholder during the migration so existing SPI/GRP
    // regressions remain usable; integration must drive the AHB port only.
    input  wire [7:0]  HADDR,
    input  wire [2:0]  HBURST,
    input  wire        HMASTLOCK,
    input  wire [3:0]  HPROT,
    input  wire [2:0]  HSIZE,
    input  wire [1:0]  HTRANS,
    input  wire [7:0]  HWDATA,
    input  wire        HWRITE,
    output wire [7:0]  HRDATA,
    output wire        HREADY,
    output wire        HRESP,

    // ---- Interrupt outputs ----
    output wire        IRQ_OUT_OUT,       // → dedicated IRQ pad; sticky, level-high
    output wire        IRQ_GROUPER,   // → Grouper inter-project IRQ line; same signal as IRQ_OUT

    // ==== A40 padframe pad-control tie-offs =================================
    //  The A40 workshop padring has no output-only cell: every functional
    //  output sits on a bidirectional pad whose config pins are driven from
    //  this block (Option A: SPI_MISO_OE tied 1, host link is point-to-point).
    //  Pull/slew/drive values follow planning/Pinout.md; drive-strength and
    //  slew are provisional pending SI review.  See planning/Pinout.md
    //  "A40 pad-control tie-offs".
    // -- discrete input pads: pulls disabled (board supplies pull-ups) --
    output wire        IQ_CLK_PU,
    output wire        IQ_CLK_PD,
    output wire        RESETB_PU,
    output wire        RESETB_PD,
    output wire        IQ_DATA_I_0_PU,
    output wire        IQ_DATA_I_0_PD,
    output wire        IQ_DATA_I_1_PU,
    output wire        IQ_DATA_I_1_PD,
    output wire        IQ_DATA_I_2_PU,
    output wire        IQ_DATA_I_2_PD,
    output wire        IQ_DATA_I_3_PU,
    output wire        IQ_DATA_I_3_PD,
    output wire        IQ_DATA_Q_0_PU,
    output wire        IQ_DATA_Q_0_PD,
    output wire        IQ_DATA_Q_1_PU,
    output wire        IQ_DATA_Q_1_PD,
    output wire        IQ_DATA_Q_2_PU,
    output wire        IQ_DATA_Q_2_PD,
    output wire        IQ_DATA_Q_3_PU,
    output wire        IQ_DATA_Q_3_PD,
    output wire        HOST_CS_PU,
    output wire        HOST_CS_PD,
    output wire        SPI_SCK_PU,
    output wire        SPI_SCK_PD,
    output wire        SPI_MOSI_PU,
    output wire        SPI_MOSI_PD,
    // -- PSRAM_SIO[3:0]: true bidir (OUT/IN/OE above); input-enabled, max drive --
    output wire        PSRAM_SIO_0_IE,
    output wire        PSRAM_SIO_0_CS,
    output wire        PSRAM_SIO_0_SL,
    output wire        PSRAM_SIO_0_PU,
    output wire        PSRAM_SIO_0_PD,
    output wire        PSRAM_SIO_0_PDRV0,
    output wire        PSRAM_SIO_0_PDRV1,
    output wire        PSRAM_SIO_1_IE,
    output wire        PSRAM_SIO_1_CS,
    output wire        PSRAM_SIO_1_SL,
    output wire        PSRAM_SIO_1_PU,
    output wire        PSRAM_SIO_1_PD,
    output wire        PSRAM_SIO_1_PDRV0,
    output wire        PSRAM_SIO_1_PDRV1,
    output wire        PSRAM_SIO_2_IE,
    output wire        PSRAM_SIO_2_CS,
    output wire        PSRAM_SIO_2_SL,
    output wire        PSRAM_SIO_2_PU,
    output wire        PSRAM_SIO_2_PD,
    output wire        PSRAM_SIO_2_PDRV0,
    output wire        PSRAM_SIO_2_PDRV1,
    output wire        PSRAM_SIO_3_IE,
    output wire        PSRAM_SIO_3_CS,
    output wire        PSRAM_SIO_3_SL,
    output wire        PSRAM_SIO_3_PU,
    output wire        PSRAM_SIO_3_PD,
    output wire        PSRAM_SIO_3_PDRV0,
    output wire        PSRAM_SIO_3_PDRV1,
    // -- PSRAM_CE_N: output on bidir pad --
    input  wire        PSRAM_CE_N_IN,
    output wire        PSRAM_CE_N_OE,
    output wire        PSRAM_CE_N_IE,
    output wire        PSRAM_CE_N_CS,
    output wire        PSRAM_CE_N_SL,
    output wire        PSRAM_CE_N_PU,
    output wire        PSRAM_CE_N_PD,
    output wire        PSRAM_CE_N_PDRV0,
    output wire        PSRAM_CE_N_PDRV1,
    // -- REMOD_A_I: output on bidir pad --
    input  wire        REMOD_A_I_IN,
    output wire        REMOD_A_I_OE,
    output wire        REMOD_A_I_IE,
    output wire        REMOD_A_I_CS,
    output wire        REMOD_A_I_SL,
    output wire        REMOD_A_I_PU,
    output wire        REMOD_A_I_PD,
    output wire        REMOD_A_I_PDRV0,
    output wire        REMOD_A_I_PDRV1,
    // -- REMOD_A_Q: output on bidir pad --
    input  wire        REMOD_A_Q_IN,
    output wire        REMOD_A_Q_OE,
    output wire        REMOD_A_Q_IE,
    output wire        REMOD_A_Q_CS,
    output wire        REMOD_A_Q_SL,
    output wire        REMOD_A_Q_PU,
    output wire        REMOD_A_Q_PD,
    output wire        REMOD_A_Q_PDRV0,
    output wire        REMOD_A_Q_PDRV1,
    // -- SPI_MISO: output on bidir pad --
    input  wire        SPI_MISO_IN,
    output wire        SPI_MISO_OE,
    output wire        SPI_MISO_IE,
    output wire        SPI_MISO_CS,
    output wire        SPI_MISO_SL,
    output wire        SPI_MISO_PU,
    output wire        SPI_MISO_PD,
    output wire        SPI_MISO_PDRV0,
    output wire        SPI_MISO_PDRV1,
    // -- IRQ_OUT: output on bidir pad --
    input  wire        IRQ_OUT_IN,
    output wire        IRQ_OUT_OE,
    output wire        IRQ_OUT_IE,
    output wire        IRQ_OUT_CS,
    output wire        IRQ_OUT_SL,
    output wire        IRQ_OUT_PU,
    output wire        IRQ_OUT_PD,
    output wire        IRQ_OUT_PDRV0,
    output wire        IRQ_OUT_PDRV1,
    // -- PSRAM_SCK: output on 24 mA bidir pad (no PDRV select) --
    input  wire        PSRAM_SCK_IN,
    output wire        PSRAM_SCK_OE,
    output wire        PSRAM_SCK_IE,
    output wire        PSRAM_SCK_CS,
    output wire        PSRAM_SCK_SL,
    output wire        PSRAM_SCK_PU,
    output wire        PSRAM_SCK_PD
);

    // Reassemble scalar physical pins into the vectors used inside the design.
    wire [3:0] IQ_DATA_I = {IQ_DATA_I_3, IQ_DATA_I_2, IQ_DATA_I_1, IQ_DATA_I_0};
    wire [3:0] IQ_DATA_Q = {IQ_DATA_Q_3, IQ_DATA_Q_2, IQ_DATA_Q_1, IQ_DATA_Q_0};
    wire [3:0] PSRAM_SIO_OUT;
    wire [3:0] PSRAM_SIO_IN = {PSRAM_SIO_3_IN, PSRAM_SIO_2_IN,
                               PSRAM_SIO_1_IN, PSRAM_SIO_0_IN};
    wire [3:0] PSRAM_SIO_OE;
    wire [7:0] GRP_ADDR = {GRP_ADDR_7, GRP_ADDR_6, GRP_ADDR_5, GRP_ADDR_4,
                           GRP_ADDR_3, GRP_ADDR_2, GRP_ADDR_1, GRP_ADDR_0};
    wire [7:0] GRP_WDATA = {GRP_WDATA_7, GRP_WDATA_6, GRP_WDATA_5, GRP_WDATA_4,
                            GRP_WDATA_3, GRP_WDATA_2, GRP_WDATA_1, GRP_WDATA_0};
    wire [7:0] GRP_RDATA;

    assign {PSRAM_SIO_3_OUT, PSRAM_SIO_2_OUT,
            PSRAM_SIO_1_OUT, PSRAM_SIO_0_OUT} = PSRAM_SIO_OUT;
    assign {PSRAM_SIO_3_OE, PSRAM_SIO_2_OE,
            PSRAM_SIO_1_OE, PSRAM_SIO_0_OE} = PSRAM_SIO_OE;
    assign {GRP_RDATA_7, GRP_RDATA_6, GRP_RDATA_5, GRP_RDATA_4,
            GRP_RDATA_3, GRP_RDATA_2, GRP_RDATA_1, GRP_RDATA_0} = GRP_RDATA;

    // ==== A40 padframe pad-control tie-offs (see module header + Pinout.md) ===
    assign IQ_CLK_PU = 1'b0;
    assign IQ_CLK_PD = 1'b0;
    assign RESETB_PU = 1'b0;
    assign RESETB_PD = 1'b0;
    assign IQ_DATA_I_0_PU = 1'b0;
    assign IQ_DATA_I_0_PD = 1'b0;
    assign IQ_DATA_I_1_PU = 1'b0;
    assign IQ_DATA_I_1_PD = 1'b0;
    assign IQ_DATA_I_2_PU = 1'b0;
    assign IQ_DATA_I_2_PD = 1'b0;
    assign IQ_DATA_I_3_PU = 1'b0;
    assign IQ_DATA_I_3_PD = 1'b0;
    assign IQ_DATA_Q_0_PU = 1'b0;
    assign IQ_DATA_Q_0_PD = 1'b0;
    assign IQ_DATA_Q_1_PU = 1'b0;
    assign IQ_DATA_Q_1_PD = 1'b0;
    assign IQ_DATA_Q_2_PU = 1'b0;
    assign IQ_DATA_Q_2_PD = 1'b0;
    assign IQ_DATA_Q_3_PU = 1'b0;
    assign IQ_DATA_Q_3_PD = 1'b0;
    assign HOST_CS_PU = 1'b0;
    assign HOST_CS_PD = 1'b0;
    assign SPI_SCK_PU = 1'b0;
    assign SPI_SCK_PD = 1'b0;
    assign SPI_MOSI_PU = 1'b0;
    assign SPI_MOSI_PD = 1'b0;
    // gf180mcu_fd_io__bi_t does not characterize IE=OE=1.  The PSRAM
    // controller owns OE per lane, so enable the pad receiver only while
    // that lane is released to the PSRAM.
    assign PSRAM_SIO_0_IE = ~PSRAM_SIO_OE[0];
    assign PSRAM_SIO_0_CS = 1'b0;
    assign PSRAM_SIO_0_SL = 1'b0;
    assign PSRAM_SIO_0_PU = 1'b0;
    assign PSRAM_SIO_0_PD = 1'b0;
    assign PSRAM_SIO_0_PDRV0 = 1'b1;
    assign PSRAM_SIO_0_PDRV1 = 1'b1;
    assign PSRAM_SIO_1_IE = ~PSRAM_SIO_OE[1];
    assign PSRAM_SIO_1_CS = 1'b0;
    assign PSRAM_SIO_1_SL = 1'b0;
    assign PSRAM_SIO_1_PU = 1'b0;
    assign PSRAM_SIO_1_PD = 1'b0;
    assign PSRAM_SIO_1_PDRV0 = 1'b1;
    assign PSRAM_SIO_1_PDRV1 = 1'b1;
    assign PSRAM_SIO_2_IE = ~PSRAM_SIO_OE[2];
    assign PSRAM_SIO_2_CS = 1'b0;
    assign PSRAM_SIO_2_SL = 1'b0;
    assign PSRAM_SIO_2_PU = 1'b0;
    assign PSRAM_SIO_2_PD = 1'b0;
    assign PSRAM_SIO_2_PDRV0 = 1'b1;
    assign PSRAM_SIO_2_PDRV1 = 1'b1;
    assign PSRAM_SIO_3_IE = ~PSRAM_SIO_OE[3];
    assign PSRAM_SIO_3_CS = 1'b0;
    assign PSRAM_SIO_3_SL = 1'b0;
    assign PSRAM_SIO_3_PU = 1'b0;
    assign PSRAM_SIO_3_PD = 1'b0;
    assign PSRAM_SIO_3_PDRV0 = 1'b1;
    assign PSRAM_SIO_3_PDRV1 = 1'b1;
    assign PSRAM_CE_N_OE = 1'b1;
    assign PSRAM_CE_N_IE = 1'b0;
    assign PSRAM_CE_N_CS = 1'b0;
    assign PSRAM_CE_N_SL = 1'b0;
    assign PSRAM_CE_N_PU = 1'b0;
    assign PSRAM_CE_N_PD = 1'b0;
    assign PSRAM_CE_N_PDRV0 = 1'b1;
    assign PSRAM_CE_N_PDRV1 = 1'b1;
    // REMOD 16 mA (PDRV=1,1) not 8 mA: 32 MHz output into an SX1302 whose
    // input capacitance is unpublished; under-drive is unfixable post-silicon.
    assign REMOD_A_I_OE = 1'b1;
    assign REMOD_A_I_IE = 1'b0;
    assign REMOD_A_I_CS = 1'b0;
    assign REMOD_A_I_SL = 1'b0;
    assign REMOD_A_I_PU = 1'b0;
    assign REMOD_A_I_PD = 1'b0;
    assign REMOD_A_I_PDRV0 = 1'b1;
    assign REMOD_A_I_PDRV1 = 1'b1;
    assign REMOD_A_Q_OE = 1'b1;
    assign REMOD_A_Q_IE = 1'b0;
    assign REMOD_A_Q_CS = 1'b0;
    assign REMOD_A_Q_SL = 1'b0;
    assign REMOD_A_Q_PU = 1'b0;
    assign REMOD_A_Q_PD = 1'b0;
    assign REMOD_A_Q_PDRV0 = 1'b1;
    assign REMOD_A_Q_PDRV1 = 1'b1;
    assign SPI_MISO_OE = 1'b1;
    assign SPI_MISO_IE = 1'b0;
    assign SPI_MISO_CS = 1'b0;
    assign SPI_MISO_SL = 1'b1;
    assign SPI_MISO_PU = 1'b0;
    assign SPI_MISO_PD = 1'b0;
    assign SPI_MISO_PDRV0 = 1'b1;
    assign SPI_MISO_PDRV1 = 1'b0;
    assign IRQ_OUT_OE = 1'b1;
    assign IRQ_OUT_IE = 1'b0;
    assign IRQ_OUT_CS = 1'b0;
    assign IRQ_OUT_SL = 1'b1;
    assign IRQ_OUT_PU = 1'b0;
    assign IRQ_OUT_PD = 1'b0;
    assign IRQ_OUT_PDRV0 = 1'b1;
    assign IRQ_OUT_PDRV1 = 1'b0;
    assign PSRAM_SCK_OE = 1'b1;
    assign PSRAM_SCK_IE = 1'b0;
    assign PSRAM_SCK_CS = 1'b0;
    assign PSRAM_SCK_SL = 1'b0;
    assign PSRAM_SCK_PU = 1'b0;
    assign PSRAM_SCK_PD = 1'b0;
    // Sink the unused pad-input-path nets from the output-only bidir pads.
    wire _unused_pad_in = &{1'b0, PSRAM_CE_N_IN, REMOD_A_I_IN, REMOD_A_Q_IN,
                            SPI_MISO_IN, IRQ_OUT_IN, PSRAM_SCK_IN};

    // =========================================================================
    // Global clock and reset
    // =========================================================================
    wire clk   = IQ_CLK;
    wire rst_n = RESETB;

    // ---- 16 MHz clock-enable (control-plane functional domain) --------------
    // Single 32 MHz clock; CE-gated FFs update every OTHER cycle, so their
    // reg→reg paths are genuinely 2 cycles → honest MCP=2 (62.5 ns) with NO
    // second clock tree and NO async CDC.  Used to gate reg_bank: the deep
    // register-write decode (~54 ns) then closes without restructuring the
    // bank.  toggles 0,1,0,1,…
    reg ce_16m;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) ce_16m <= 1'b0;
        else        ce_16m <= ~ce_16m;

    // ---- Forward declarations (declared before first use; iverilog requires
    //      nets to be declared ahead of references) ----
    wire        dcr_valid;          // dc_removal output valid; driven below
    reg         packet_done_pulse;  // registered falling edge of packet_active
                                    // (fanout split 2026-07-19: flop Q drives the
                                    // 15-load done cone; 1-cycle-later pulse is
                                    // tolerated by all consumers)
    wire        spi_reg_re;         // SPI read-side-effect strobe; driven below
    wire [7:0]  spi_reg_re_addr;
    wire        psram_dbg_busy_w;
    wire [7:0]  psram_dbg_data_w;
    wire        psram_replay_active_w;
    // PSRAM debug byte ports (0x76 read-pop / 0x79 write-push): driven
    // directly by either register master, bypassing the CE/arbiter.  Both
    // masters can hold a request for several clk edges (in particular the
    // AHB-to-GRP bridge), hence each side effect is explicitly edge-detected.
    wire [7:0]  psram_dbg_wdata_w;
    wire        psram_dbg_wdata_push_w;
    wire        psram_dbg_data_pop_w;

    // =========================================================================
    // Free-running 32-bit sample counter (for packet_ctrl_fsm)
    // =========================================================================
    reg [31:0] sample_count;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sample_count <= 32'd0;
        else        sample_count <= sample_count + 32'd1;

    // iq_valid-based sample counter — matches timing_ref domain from sc_detector
    reg [31:0] iq_samp_cnt;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) iq_samp_cnt <= 32'd0;
        else if (dcr_valid) iq_samp_cnt <= iq_samp_cnt + 32'd1;

    // =========================================================================
    // Register bank outputs (config forwarded to DSP blocks)
    // =========================================================================
    // Declare wires for all reg_bank outputs used here; tie unused inputs below.
    wire [7:0]  cfg_rdata_w;
    wire [7:0]  rb_peek_rdata_w;
    wire        cfg_ready_w;
    wire [1:0]  rb_mimo_mode;
    wire [3:0]  rb_antenna_en;
    wire [3:0]  rb_sf_cfg;
    wire        rb_bw_sel;
    wire [1:0]  rb_sample_shift = rb_bw_sel ? 2'd2 : 2'd1;
    wire [1:0]  rb_sc_ant_sel;
    wire [15:0] rb_sc_thr;
    wire [1:0]  rb_sc_hits_req;
    wire [7:0]  rb_pkt_timeout_syms;
    wire [3:0]  rb_tacc_window_syms;
    wire [15:0] rb_replay_delay_samples;
    wire        rb_w_commit_pulse;
    wire [2:0]  rb_comb_post_gain_shift;
    wire [1:0]  rb_remod_backoff_shift;
    wire [127:0] rb_w_shadow;
    wire [3:0]  rb_psram_ctrl;
    wire [22:0] rb_psram_dbg_addr;
    wire        rb_psram_dbg_auto_inc;
    wire        rb_psram_dbg_rd_trig;
    wire        rb_psram_dbg_wr_trig;

    // =========================================================================
    // Stage 1: ΣΔ Decimator — shared TDM8 CIC N=3, fixed R=128, no FIR.
    // Boxcar-4 front end + shared CIC back end reduces area versus 4×
    // sd_decimator_cic_only.  This is the experimental TDM path.
    // Folded area-reduction: sd_decimator_poly = polyphase HB delay lines
    // (#2) + 14-bit CIC (#3), bit-exact vs the shared HB reference prototype (SGE 2099,
    // -13.8% decimator area). See planning/decimator-hb-area-reduction.md.
    // =========================================================================
    wire signed [7:0] dec_i [0:3];
    wire signed [7:0] dec_q [0:3];
    wire [31:0]      dec_pack_i;
    wire [31:0]      dec_pack_q;
    wire [3:0]       dec_valid_all;
    wire             iq_valid = |dec_valid_all;

    sd_decimator_poly u_dec (
        .clk_32m (clk),
        .rst_n   (rst_n),
        .iq_in_i (IQ_DATA_I),
        .iq_in_q (IQ_DATA_Q),
        .iq_out_i(dec_pack_i),
        .iq_out_q(dec_pack_q),
        .iq_valid(dec_valid_all)
    );

    assign dec_i[0] = dec_pack_i[7:0];
    assign dec_i[1] = dec_pack_i[15:8];
    assign dec_i[2] = dec_pack_i[23:16];
    assign dec_i[3] = dec_pack_i[31:24];
    assign dec_q[0] = dec_pack_q[7:0];
    assign dec_q[1] = dec_pack_q[15:8];
    assign dec_q[2] = dec_pack_q[23:16];
    assign dec_q[3] = dec_pack_q[31:24];

    // =========================================================================
    // Stage 2: DC Removal ×4 — simplified IIR, α=2^{-4}, 12-bit Q8.4 accumulator.
    // SX1257 is zero-IF with no on-chip receiver DC cancellation; this block
    // removes LO self-mixing offset before the correlator chain.
    // =========================================================================
    wire signed [7:0] dcr_i [0:3];
    wire signed [7:0] dcr_q [0:3];

    dc_removal u_dcr (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .sample_i0 (dec_i[0]), .sample_i1 (dec_i[1]),
        .sample_i2 (dec_i[2]), .sample_i3 (dec_i[3]),
        .sample_q0 (dec_q[0]), .sample_q1 (dec_q[1]),
        .sample_q2 (dec_q[2]), .sample_q3 (dec_q[3]),
        .sample_valid     (iq_valid),
        .sample_out_i0 (dcr_i[0]), .sample_out_i1 (dcr_i[1]),
        .sample_out_i2 (dcr_i[2]), .sample_out_i3 (dcr_i[3]),
        .sample_out_q0 (dcr_q[0]), .sample_out_q1 (dcr_q[1]),
        .sample_out_q2 (dcr_q[2]), .sample_out_q3 (dcr_q[3]),
        .sample_out_valid (dcr_valid)
    );

    // =========================================================================
    // Stage 3a: SC detector delay-line signals (now provided by psram_buf_ctrl)
    // The on-chip FD SRAM (512×8, 209K µm²) and frontend_buf_ctrl have been
    // removed.  psram_buf_ctrl writes all 8 bytes/sample to PSRAM continuously
    // and reads back del_i0/del_q0 (branch 0, N-sample delayed) in the same
    // 44-sub-cycle window; cur_i0/cur_q0 are captured from the write data.
    // =========================================================================
    wire signed [7:0] psram_cur_i0, psram_cur_q0;  // branch 0, current sample
    wire signed [7:0] psram_del_i0, psram_del_q0;  // branch 0, N-sample delayed
    wire              psram_del_valid;               // pulses when cur/del pair ready
    wire        sc_lock;    // declared here to avoid forward-reference; driven by u_sc
    wire        rb_sc_force_lock; // manual SC lock override (SC_FORCE_LOCK 0x19); declared here to avoid forward-reference
    wire        rb_rx_hold;       // RX_HOLD (0x1A[0]); declared here to avoid forward-reference

    // =========================================================================
    // Stage 3b: Schmidl-Cox preamble detector
    // =========================================================================
    wire [31:0] timing_ref;
    wire [15:0] sc_stat;
    wire        sc_hit_dbg;    // 1-cycle pulse: noise-window contamination latch
    wire        sc_hit_hold;   // held per-symbol mirror: SC_DBG_FLAGS[0] readback
    wire [1:0]  sc_hit_cnt_dbg;
    wire [31:0] sc_first_hit_dbg, sc_lock_snap_dbg;

    sc_detector u_sc (
        .clk          (clk),
        .rst_n        (rst_n),
        .iq_valid     (dcr_valid),
        .cur_i0 (psram_cur_i0),
        .cur_q0 (psram_cur_q0),
        .del_i0 (psram_del_i0),
        .del_q0 (psram_del_q0),
        .delayed_valid  (psram_del_valid),
        .sf             (rb_sf_cfg),
        .sample_shift   (rb_sample_shift),
        .sc_thr         (rb_sc_thr),
        .sc_hits_req    (rb_sc_hits_req),
        // Re-arm the detector when the packet FSM returns to IDLE, and hold it
        // cleared for as long as firmware asserts RX_HOLD.  sc_clr is
        // level-sensitive (sc_detector.v:492 holds sc_lock/hit_count/all
        // accumulators cleared while high), so the hold makes "config
        // writable" and "detector able to lock" mutually exclusive -- the
        // interlock the scoped-MCP settling exceptions rely on (Open Risks
        // #43, planning/mcp-config-settle-gate-design.md).
        .sc_clr         (packet_done_pulse | rb_rx_hold),
        .sc_lock_force  (rb_sc_force_lock),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .c_i0 (), .c_q0 (),
        .sc_stat              (sc_stat),
        .sc_hit_dbg           (sc_hit_dbg),
        .sc_hit_hold          (sc_hit_hold),
        .sc_hit_count_dbg     (sc_hit_cnt_dbg),
        .sc_first_hit_dbg     (sc_first_hit_dbg),
        .sc_lock_sample_dbg   (sc_lock_snap_dbg)
    );

    // =========================================================================
    // Stage 3c: Legacy energy-snapshot path removed.
    //
    // Noise qualification now uses training_acc noise-mode windows plus SC
    // contamination tracking instead of a live noise_est block.
    //
    // TODO(timing/logic verification): validate that the accepted-noise window
    // semantics below match firmware expectations, especially around sc_hit_dbg
    // timing versus training_done commit.
    // =========================================================================
    // =========================================================================
    // Stage 4: Training Accumulator
    // =========================================================================
    // Individual Z_kl pairs → reg_bank firmware eigenvector path
    wire signed [31:0] Zpair_i [0:5];
    wire signed [31:0] Zpair_q [0:5];
    // Z_kk diagonal autocorrelation → reg_bank noise estimation
    wire [31:0]        Zdiag [0:3];
    wire               training_done;
    wire [17:0]        n_acc;
    wire               training_armed;
    wire               rb_noise_trig;    // firmware-triggered noise measurement pulse

    training_acc u_tacc (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .raw_i0 (dcr_i[0]), .raw_i1 (dcr_i[1]),
        .raw_i2 (dcr_i[2]), .raw_i3 (dcr_i[3]),
        .raw_q0 (dcr_q[0]), .raw_q1 (dcr_q[1]),
        .raw_q2 (dcr_q[2]), .raw_q3 (dcr_q[3]),
        .sc_lock      (sc_lock),
        .timing_ref   (timing_ref),
        .sf           (rb_sf_cfg),
        .sample_shift (rb_sample_shift),
        .tacc_window_syms (rb_tacc_window_syms),
        .noise_trig   (rb_noise_trig),
        .Zpair_i0 (Zpair_i[0]), .Zpair_q0 (Zpair_q[0]),
        .Zpair_i1 (Zpair_i[1]), .Zpair_q1 (Zpair_q[1]),
        .Zpair_i2 (Zpair_i[2]), .Zpair_q2 (Zpair_q[2]),
        .Zpair_i3 (Zpair_i[3]), .Zpair_q3 (Zpair_q[3]),
        .Zpair_i4 (Zpair_i[4]), .Zpair_q4 (Zpair_q[4]),
        .Zpair_i5 (Zpair_i[5]), .Zpair_q5 (Zpair_q[5]),
        .Zdiag_0  (Zdiag[0]),   .Zdiag_1  (Zdiag[1]),
        .Zdiag_2  (Zdiag[2]),   .Zdiag_3  (Zdiag[3]),
        .training_done   (training_done),
        .n_acc           (n_acc),
        .training_armed  (training_armed)
    );

    // =========================================================================
    // Stage 5: noise-window qualification.
    // Z_23 (pair 5) is read back directly at reg_bank 0x5E–0x63 like the other
    // pairs.  sigma2_valid pulses when a firmware-triggered noise window
    // completes without SC contamination; it sets IRQ_STATUS.NOISE_READY.
    // =========================================================================
    wire        sigma2_valid;
    reg         noise_window_active;
    reg         noise_window_sc_seen;
    reg         sigma2_valid_r;

    // Firmware-triggered noise measurements reuse training_acc noise mode.
    // Accept the resulting Zdiag window only if no SC activity appeared while
    // the measurement was in flight.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_window_active  <= 1'b0;
            noise_window_sc_seen <= 1'b0;
            sigma2_valid_r       <= 1'b0;
        end else begin
            sigma2_valid_r <= 1'b0;

            if (rb_noise_trig) begin
                noise_window_active  <= 1'b1;
                noise_window_sc_seen <= 1'b0;
            end else if (noise_window_active && (sc_hit_dbg || sc_lock)) begin
                noise_window_sc_seen <= 1'b1;
            end

            if (noise_window_active && training_done) begin
                sigma2_valid_r       <= ~noise_window_sc_seen && !sc_lock;
                noise_window_active  <= 1'b0;
                noise_window_sc_seen <= 1'b0;
            end
        end
    end

    assign sigma2_valid = sigma2_valid_r;

    wire W_commit_hw = rb_w_commit_pulse;

    // =========================================================================
    // Stage 7: Packet Control FSM
    // =========================================================================
    wire        W_valid_set, W_missed_packet;
    wire        W_missed_q;   // sticky per-packet readback mirror of the pulse
    wire [2:0]  packet_phase;
    wire        packet_active;
    wire        packet_active_ps;   // fanout-split duplicate, u_psram only
    wire [1:0]  active_mode;
    wire [3:0]  active_antenna_en;

    // W_valid register: set by W_valid_set pulse, cleared at FSM IDLE entry
    reg  W_valid;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)           W_valid <= 1'b0;
        else if (W_valid_set) W_valid <= 1'b1;
        else if (!packet_active) W_valid <= 1'b0;

    // W_pending: training complete but W not yet committed this packet
    reg  w_pending;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)             w_pending <= 1'b0;
        else if (training_done) w_pending <= 1'b1;
        else if (W_commit_hw || !packet_active) w_pending <= 1'b0;

    packet_ctrl_fsm u_pcfsm (
        .clk             (clk),
        .rst_n           (rst_n),
        .sample_count    (iq_samp_cnt),
        .iq_tick         (dcr_valid),
        .sf              (rb_sf_cfg),
        .sample_shift    (rb_sample_shift),
        .sc_lock         (sc_lock),
        .timing_ref      (timing_ref),
        .training_done   (training_done),
        .W_commit        (W_commit_hw),
        .mode_shadow     (rb_mimo_mode),
        .antenna_en_shadow (rb_antenna_en),
        .pkt_timeout_syms (rb_pkt_timeout_syms),
        .tacc_window_syms (rb_tacc_window_syms),
        .W_valid_set     (W_valid_set),
        .W_missed_packet (W_missed_packet),
        .W_missed_q      (W_missed_q),
        .packet_phase      (packet_phase),
        .packet_active     (packet_active),
        .packet_active_ps  (packet_active_ps),
        .active_mode       (active_mode),
        .active_antenna_en (active_antenna_en)
    );

    // =========================================================================
    // Stage 7b: PSRAM Buffer Controller (same-packet MRC)
    // =========================================================================
    wire signed [7:0] rpl_i [0:3];
    wire signed [7:0] rpl_q [0:3];
    wire              rpl_valid;
    wire              psram_buf_active;
    wire              psram_qe_init_done, psram_replay_missed, psram_overflow;
    wire              psram_w_commit_late;
    wire              psram_sample_skip;
    wire [2:0]        psram_state_dbg;

    psram_buf_ctrl u_psram (
        .clk_32m      (clk),
        .rst_n        (rst_n),
        .psram_en     (rb_psram_ctrl[0]),
        .init_start   (rb_psram_ctrl[0] & ~rb_psram_ctrl[3]),
        .qspi_owner   (rb_psram_ctrl[3]),
        .packet_active(packet_active_ps),
        .sf           (rb_sf_cfg),
        .sample_shift (rb_sample_shift),
        .sc_ant_sel   (rb_sc_ant_sel),
        .iq_i0 (dcr_i[0]), .iq_i1 (dcr_i[1]),
        .iq_i2 (dcr_i[2]), .iq_i3 (dcr_i[3]),
        .iq_q0 (dcr_q[0]), .iq_q1 (dcr_q[1]),
        .iq_q2 (dcr_q[2]), .iq_q3 (dcr_q[3]),
        .iq_valid     (dcr_valid),
        .sc_lock      (sc_lock),
        .timing_ref   (timing_ref),
        .iq_sample_cnt(iq_samp_cnt),
        .training_done(training_done),
        .replay_delay_samples(rb_replay_delay_samples),
        .W_commit     (W_commit_hw),
        .packet_end   (packet_done_pulse),
        .clr_err      (rb_psram_ctrl[1]),
        .sck          (PSRAM_SCK_OUT),
        .ce_n         (PSRAM_CE_N_OUT),
        .sio_out      (PSRAM_SIO_OUT),
        .sio_in       (PSRAM_SIO_IN),
        .sio_oe       (PSRAM_SIO_OE),
        // SC delay-line outputs (replace frontend_buf_ctrl + on-chip SRAM)
        .cur_i0       (psram_cur_i0),
        .cur_q0       (psram_cur_q0),
        .del_i0       (psram_del_i0),
        .del_q0       (psram_del_q0),
        .del_valid    (psram_del_valid),
        // Replay outputs
        .rpl_i0 (rpl_i[0]), .rpl_i1 (rpl_i[1]),
        .rpl_i2 (rpl_i[2]), .rpl_i3 (rpl_i[3]),
        .rpl_q0 (rpl_q[0]), .rpl_q1 (rpl_q[1]),
        .rpl_q2 (rpl_q[2]), .rpl_q3 (rpl_q[3]),
        .rpl_valid    (rpl_valid),
        .buf_active   (psram_buf_active),
        .replay_active(psram_replay_active_w),
        .qe_init_done (psram_qe_init_done),
        .replay_missed(psram_replay_missed),
        .w_commit_late(psram_w_commit_late),
        .overflow     (psram_overflow),
        .sample_skip  (psram_sample_skip),
        .state_dbg    (psram_state_dbg),
        .dbg_addr     (rb_psram_dbg_addr),
        .dbg_auto_inc (rb_psram_dbg_auto_inc),
        .dbg_rd_trig  (rb_psram_dbg_rd_trig),
        .dbg_data_pop (psram_dbg_data_pop_w),
        .dbg_busy     (psram_dbg_busy_w),
        .dbg_data     (psram_dbg_data_w),
        .dbg_wdata      (psram_dbg_wdata_w),
        .dbg_wdata_push (psram_dbg_wdata_push_w),
        .dbg_wr_trig    (rb_psram_dbg_wr_trig)
    );

    // Combiner input mux: live decimator IQ during normal/buffering,
    // PSRAM replay IQ during replay. x_valid follows the active source.
    wire signed [7:0] comb_xi [0:3];
    wire signed [7:0] comb_xq [0:3];
    wire              comb_xvalid;
    genvar gi;
    generate for (gi = 0; gi < 4; gi = gi + 1) begin : g_comb_mux
        assign comb_xi[gi] = psram_replay_active_w ? rpl_i[gi] : dcr_i[gi];
        assign comb_xq[gi] = psram_replay_active_w ? rpl_q[gi] : dcr_q[gi];
    end endgenerate
    assign comb_xvalid = psram_replay_active_w ? rpl_valid : dcr_valid;

    // =========================================================================
    // Stage 8: MRC Combiner
    // =========================================================================
    wire signed [7:0] comb_y_i, comb_y_q;
    wire              comb_y_valid;

    // bypass_ant: lowest set bit of active_antenna_en. Fixed 2026-07-05 (Open
    // Risks #4): the original mux tested en[1]/en[2]/en[3] and fell back to
    // 0, never actually testing en[0] first -- so the reset default
    // active_antenna_en=0xF (all enabled) selected antenna 1, not the
    // lowest-enabled antenna TRPR-SYS-005/TRPR-MRC-005 require.
    wire [1:0] bypass_ant = active_antenna_en[0] ? 2'd0 :
                            active_antenna_en[1] ? 2'd1 :
                            active_antenna_en[2] ? 2'd2 : 2'd3;

    mrc_combiner u_comb (
        .clk_16m (clk),
        .rst_n   (rst_n),
        .x_i0 (comb_xi[0]), .x_q0 (comb_xq[0]),
        .x_i1 (comb_xi[1]), .x_q1 (comb_xq[1]),
        .x_i2 (comb_xi[2]), .x_q2 (comb_xq[2]),
        .x_i3 (comb_xi[3]), .x_q3 (comb_xq[3]),
        .x_valid  (comb_xvalid),
        .W_re0 (rb_w_shadow[127:120]), .W_im0 (rb_w_shadow[111:104]),
        .W_re1 (rb_w_shadow[95:88]),  .W_im1 (rb_w_shadow[79:72]),
        .W_re2 (rb_w_shadow[63:56]),  .W_im2 (rb_w_shadow[47:40]),
        .W_re3 (rb_w_shadow[31:24]),  .W_im3 (rb_w_shadow[15:8]),
        .W_valid   (W_valid),
        .mode      (active_mode[0]),    // 0=MRC, 1=bypass
        .bypass_ant(bypass_ant),
        .post_gain_shift(rb_comb_post_gain_shift),
        .y_i    (comb_y_i),
        .y_q    (comb_y_q),
        .y_valid(comb_y_valid)
    );

    // =========================================================================
    // Stage 9: ΣΔ Re-modulator → SX1302 Radio A
    // During PSRAM BUFFERING (buf_active && !replay_active): modulate zero —
    // in_valid keeps pulsing so sd_remod latches actual silence rather than
    // holding the last pre-lock sample as a DC tone (Open Risks #5 fix).
    // During REPLAY: combiner processes PSRAM replay IQ → normal remod path.
    // =========================================================================
    wire psram_silence = psram_buf_active && !psram_replay_active_w;
    wire signed [7:0] remod_in_i = psram_silence ? 8'sd0 : ($signed(comb_y_i) >>> rb_remod_backoff_shift);
    wire signed [7:0] remod_in_q = psram_silence ? 8'sd0 : ($signed(comb_y_q) >>> rb_remod_backoff_shift);
    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (remod_in_i),
        .in_q     (remod_in_q),
        .in_valid (comb_y_valid),
        .en       (1'b1),
        .out_i    (REMOD_A_I_OUT),
        .out_q    (REMOD_A_Q_OUT)
    );

    // =========================================================================
    // Control Plane
    // =========================================================================

    // Edge-detect packet_done (falling edge of packet_active = packet FSM returned to IDLE)
    reg packet_active_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) packet_active_r <= 1'b0;
        else        packet_active_r <= packet_active;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) packet_done_pulse <= 1'b0;
        else        packet_done_pulse <= packet_active_r && !packet_active;

    // Edge-detect the level-driven IRQ sources.  reg_bank re-ORs irq_set into
    // IRQ_STATUS every CE (reg_bank.v:141), so a held level would immediately
    // undo an IRQ_CLEAR write (TRPR-IRQ-002).  sc_lock and training_done are
    // levels held for the rest of the packet; convert them to 1-cycle
    // rising-edge pulses.  (W_missed_packet, packet_done and sigma2_valid are
    // already 1-cycle pulses.)
    reg sc_lock_r, training_done_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            sc_lock_r       <= 1'b0;
            training_done_r <= 1'b0;
        end else begin
            sc_lock_r       <= sc_lock;
            training_done_r <= training_done;
        end
    wire sc_lock_pulse       = sc_lock       && !sc_lock_r;
    wire training_done_pulse = training_done && !training_done_r;

    // irq_set for reg_bank: [0] CORR_LOCK, [1] TRAINING_DONE, [2] W_MISSED_PACKET,
    // [3] PACKET_DONE, [4] NOISE_READY (uncontaminated noise window complete)
    wire [7:0] rb_irq_set_c = {3'b000, sigma2_valid,
                             packet_done_pulse, W_missed_packet, training_done_pulse, sc_lock_pulse};
    // Stretch the 1-cycle status pulses to 2 cycles so the CE-gated reg_bank
    // (samples every other clock) cannot miss them.  irq_status is sticky-OR so
    // a 2-cycle-wide set is idempotent.
    reg [7:0] rb_irq_set_d;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rb_irq_set_d <= 8'd0;
        else        rb_irq_set_d <= rb_irq_set_c;
    wire [7:0] rb_irq_set = rb_irq_set_c | rb_irq_set_d;

    // =========================================================================
    // SPI slave instantiation
    // =========================================================================
    wire [7:0] spi_reg_wr_addr;
    wire [7:0] spi_reg_wdata;
    wire       spi_reg_we;
    wire [7:0] spi_reg_rd_addr;
    wire [7:0] spi_reg_rdata;

    spi_slave u_spi (
        .clk_32m     (clk),
        .rst_n       (rst_n),
        .HOST_CS     (HOST_CS),
        .SPI_SCK     (SPI_SCK),
        .SPI_MOSI    (SPI_MOSI),
        .SPI_MISO    (SPI_MISO_OUT),
        .reg_wr_addr (spi_reg_wr_addr),
        .reg_wdata   (spi_reg_wdata),
        .reg_we      (spi_reg_we),
        .reg_rd_addr (spi_reg_rd_addr),
        .reg_re_addr (spi_reg_re_addr),
        .reg_re      (spi_reg_re),
        .reg_rdata   (spi_reg_rdata)
    );

    // =========================================================================
    // Register bus arbiter: Grouper (GRP_*) has priority over SPI slave.
    //
    // A completed SPI write is a short clk-domain event and cannot be stalled
    // back at the serial pins.  Capture it in a one-entry pending slot until
    // the in-progress Grouper byte cycle releases the register bank.  The
    // Grouper byte-cycle contract requires that it release before a second SPI
    // data byte completes (>= 4 us at 2 MHz), so this slot cannot overflow.
    // =========================================================================
    // The AHB endpoint turns one transfer into one held byte request.  Its
    // completion is deliberately tied to the CE-domain dispatch below, not
    // merely to observing HWRITE in the address phase.
    wire [7:0] ahb_addr, ahb_wdata;
    wire       ahb_we, ahb_re, ahb_dispatch;
    wire [7:0] ahb_rdata = cfg_rdata_w;
    wire       ahb_rready = cfg_ready_w;
    trouper_ahb8_adapter u_ahb8 (
        .clk(clk), .rst_n(rst_n), .HADDR(HADDR), .HBURST(HBURST),
        .HMASTLOCK(HMASTLOCK), .HPROT(HPROT), .HSIZE(HSIZE),
        .HTRANS(HTRANS), .HWDATA(HWDATA), .HWRITE(HWRITE),
        .HRDATA(HRDATA), .HREADY(HREADY), .HRESP(HRESP),
        .csr_addr(ahb_addr), .csr_wdata(ahb_wdata), .csr_we(ahb_we),
        .csr_re(ahb_re), .csr_dispatch(ahb_dispatch),
        .csr_rdata(ahb_rdata), .csr_rready(ahb_rready)
    );

    wire grp_active = GRP_WE | GRP_RE | ahb_we | ahb_re;

    reg        spi_reg_we_d;
    reg        grp_we_d;
    reg        grp_re_d;
    reg        spi_wr_pending;
    reg [7:0]  spi_wr_pending_addr;
    reg [7:0]  spi_wr_pending_data;
    wire       spi_wr_new = spi_reg_we & ~spi_reg_we_d;

    // PSRAM debug-write byte port (0x79): a single push per completed SPI or
    // Grouper write.  The SPI slave holds 0x79 for a burst; the AHB-to-GRP
    // bridge holds GRP_WE for six clk edges, so both sources need one-shot
    // strobes rather than their level-qualified write enables.
    wire grp_dbg_wdata_push = GRP_WE && !grp_we_d && (GRP_ADDR == 8'h79);
    assign psram_dbg_wdata_w      = grp_dbg_wdata_push ? GRP_WDATA : spi_reg_wdata;
    assign psram_dbg_wdata_push_w = grp_dbg_wdata_push ||
                                    (spi_wr_new && (spi_reg_wr_addr == 8'h79));

    // Likewise, a Grouper read held by the bridge must consume exactly one
    // 0x76 byte, not one byte per held GRP_RE cycle.  Pop on release, rather
    // than assertion: reg_bank captures the current byte while GRP_RE is
    // held, and the bridge returns that captured value before this advances
    // the debug window.
    assign psram_dbg_data_pop_w = (spi_reg_re && (spi_reg_re_addr == 8'h76)) ||
                                  (!GRP_RE && grp_re_d && (GRP_ADDR == 8'h76));

    // CE-latched WRITE bus: addr/wdata/we are sampled TOGETHER on a CE edge and
    // captured by the CE-gated reg_bank on the next CE edge, so the whole write
    // decode is a consistent, genuine 2-cycle path (honest MCP=2).
    reg [7:0] rb_addr, rb_wdata;
    reg       rb_we;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_reg_we_d       <= 1'b0;
            grp_we_d           <= 1'b0;
            grp_re_d           <= 1'b0;
            spi_wr_pending     <= 1'b0;
            spi_wr_pending_addr <= 8'd0;
            spi_wr_pending_data <= 8'd0;
            rb_addr <= 8'd0; rb_wdata <= 8'd0; rb_we <= 1'b0;
        end else begin
            spi_reg_we_d <= spi_reg_we;
            grp_we_d     <= GRP_WE;
            grp_re_d     <= GRP_RE;

            if (spi_wr_new) begin
                spi_wr_pending      <= 1'b1;
                spi_wr_pending_addr <= spi_reg_wr_addr;
                spi_wr_pending_data <= spi_reg_wdata;
            end

            if (ce_16m) begin
                if (ahb_we) begin
                    rb_addr  <= ahb_addr;
                    rb_wdata <= ahb_wdata;
                    rb_we    <= 1'b1;
                end else if (GRP_WE | GRP_RE) begin
                    rb_addr  <= GRP_ADDR;
                    rb_wdata <= GRP_WDATA;
                    rb_we    <= GRP_WE;
                end else if (spi_wr_pending) begin
                    rb_addr       <= spi_wr_pending_addr;
                    rb_wdata      <= spi_wr_pending_data;
                    rb_we         <= 1'b1;
                    spi_wr_pending <= 1'b0;
                end else if (spi_wr_new) begin
                    // Direct dispatch when the event and a free CE slot align.
                    rb_addr       <= spi_reg_wr_addr;
                    rb_wdata      <= spi_reg_wdata;
                    rb_we         <= 1'b1;
                    spi_wr_pending <= 1'b0;
                end else begin
                    rb_we <= 1'b0;
                end
            end
        end
    end

    // READ address is COMBINATIONAL (separate port) so the peek read has no CE
    // latency — reads always see the current address.  The host holds rd_addr
    // stable for the whole transaction, so the peek decode is quasi-static.
    // There is only one combinational read port: a concurrent Grouper read
    // takes priority and makes that SPI read byte invalid; the SPI host retries
    // the complete read frame after GRP_RE deasserts.
    wire [7:0] rb_raddr = ahb_re ? ahb_addr :
                          (GRP_WE | GRP_RE) ? GRP_ADDR : spi_reg_rd_addr;
    wire       rb_re    = ahb_re | GRP_RE;

    // A write is accepted only on the CE edge that dispatches it into the
    // register-bank path.  Reads acknowledge through reg_bank.ready.
    assign ahb_dispatch = ce_16m & ahb_we;

    assign GRP_RDATA = cfg_rdata_w;
    assign GRP_READY = cfg_ready_w;
    assign spi_reg_rdata = rb_peek_rdata_w;

    // ---- Register Bank ----
    wire rb_irq_out_sticky;
    assign IRQ_OUT_OUT     = rb_irq_out_sticky;
    assign IRQ_GROUPER = rb_irq_out_sticky;

    reg_bank u_rb (
        .clk        (clk),
        .clk_en     (ce_16m),
        .rst_n      (rst_n),
        .addr       (rb_addr),
        .raddr      (rb_raddr),
        .wdata      (rb_wdata),
        .we         (rb_we),
        .re         (rb_re),
        .rdata      (cfg_rdata_w),
        .peek_rdata (rb_peek_rdata_w),
        .ready      (cfg_ready_w),
        .irq_out    (rb_irq_out_sticky),
        // Hardware status inputs
        .active_mode_rb   (active_mode),
        .active_antenna_en_rb (active_antenna_en),
        .packet_active    (packet_active),
        .packet_phase     (packet_phase),
        .training_done_rb (training_done),
        .w_pending_rb     (w_pending),
        .w_valid_rb       (W_valid),
        .w_missed_rb      (W_missed_q),
        .w_commit_late_rb (psram_w_commit_late),
        .irq_set          (rb_irq_set),
        .sc_stat         (sc_stat),
        .training_armed  (training_armed),
        .n_acc           (n_acc),
        .zpair_i0 (Zpair_i[0]), .zpair_q0 (Zpair_q[0]),
        .zpair_i1 (Zpair_i[1]), .zpair_q1 (Zpair_q[1]),
        .zpair_i2 (Zpair_i[2]), .zpair_q2 (Zpair_q[2]),
        .zpair_i3 (Zpair_i[3]), .zpair_q3 (Zpair_q[3]),
        .zpair_i4 (Zpair_i[4]), .zpair_q4 (Zpair_q[4]),
        .zpair_i5 (Zpair_i[5]), .zpair_q5 (Zpair_q[5]),
        .zdiag_0  (Zdiag[0]),   .zdiag_1  (Zdiag[1]),
        .zdiag_2  (Zdiag[2]),   .zdiag_3  (Zdiag[3]),
        .sc_hit_dbg          (sc_hit_hold),   // held mirror — the pulse is SPI-invisible
        .sc_hit_count_dbg    (sc_hit_cnt_dbg),
        .sc_lock_dbg         (sc_lock),
        .sc_first_hit_dbg    (sc_first_hit_dbg),
        .sc_lock_snap_dbg    (sc_lock_snap_dbg),
        // [7] BUF_ACTIVE [6] OVERFLOW [5] REPLAY_MISSED [4] REPLAY_ACTIVE
        // [3] INIT_DONE [2] SAMPLE_SKIP [1:0] STATE (only 4 states, so 2 bits)
        .psram_status_rb  ({psram_buf_active, psram_overflow,
                            psram_replay_missed, psram_replay_active_w,
                            psram_qe_init_done, psram_sample_skip,
                            psram_state_dbg[1:0]}),
        .psram_dbg_busy   (psram_dbg_busy_w),
        .psram_dbg_data   (psram_dbg_data_w),
        // Hardware control outputs
        .mimo_mode       (rb_mimo_mode),
        .antenna_en      (rb_antenna_en),
        .sf_cfg          (rb_sf_cfg),
        .bw_sel          (rb_bw_sel),
        .sc_ant_sel      (rb_sc_ant_sel),
        .sc_thr          (rb_sc_thr),
        .sc_hits_req     (rb_sc_hits_req),
        .pkt_timeout_syms(rb_pkt_timeout_syms),
        .w_commit_pulse  (rb_w_commit_pulse),
        .comb_post_gain_shift(rb_comb_post_gain_shift),
        .remod_backoff_shift(rb_remod_backoff_shift),
        .w_shadow        (rb_w_shadow),
        .psram_ctrl      (rb_psram_ctrl),
        .psram_dbg_addr  (rb_psram_dbg_addr),
        .psram_dbg_auto_inc(rb_psram_dbg_auto_inc),
        .psram_dbg_rd_trig(rb_psram_dbg_rd_trig),
        .psram_dbg_wr_trig(rb_psram_dbg_wr_trig),
        .sc_force_lock   (rb_sc_force_lock),
        .rx_hold         (rb_rx_hold),
        .noise_trig      (rb_noise_trig),
        .tacc_window_syms (rb_tacc_window_syms),
        .replay_delay_samples (rb_replay_delay_samples)
    );

endmodule

// Grouper origin/dev external-peripheral endpoint.  HSEL/HREADYIN are
// deliberately absent: Grouper's interconnect owns them internally.  This
// module is synchronous to IQ_CLK; an asynchronous deployment must terminate
// AHB in the Grouper-side CDC bridge described in the integration plan.
module trouper_ahb8_adapter (
    input wire clk, input wire rst_n,
    input wire [7:0] HADDR, input wire [2:0] HBURST,
    input wire HMASTLOCK, input wire [3:0] HPROT, input wire [2:0] HSIZE,
    input wire [1:0] HTRANS, input wire [7:0] HWDATA, input wire HWRITE,
    output reg [7:0] HRDATA, output wire HREADY, output wire HRESP,
    output wire [7:0] csr_addr, output wire [7:0] csr_wdata,
    output wire csr_we, output wire csr_re, input wire csr_dispatch,
    input wire [7:0] csr_rdata, input wire csr_rready
);
    localparam IDLE=2'd0, WRITE=2'd1, READ=2'd2, ERROR=2'd3;
    reg [1:0] state;
    reg [7:0] addr_q;
    reg write_dispatched, error_wait;
    wire request = HTRANS[1];
    wire bad_req = (HSIZE != 3'b000) || HADDR[7];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; addr_q <= 8'd0; HRDATA <= 8'd0;
            write_dispatched <= 1'b0; error_wait <= 1'b0;
        end else begin
            case (state)
                IDLE: if (request) begin
                    addr_q <= HADDR;
                    if (bad_req) begin state <= ERROR; error_wait <= 1'b0; end
                    else if (HWRITE) begin state <= WRITE; write_dispatched <= 1'b0; end
                    else state <= READ;
                end
                WRITE: if (csr_dispatch) begin
                    write_dispatched <= 1'b1;
                    state <= IDLE;
                end
                READ: if (csr_rready) begin
                    HRDATA <= csr_rdata;
                    state <= IDLE;
                end
                ERROR: if (error_wait) state <= IDLE; else error_wait <= 1'b1;
            endcase
        end
    end
    assign csr_addr = addr_q;
    assign csr_wdata = HWDATA;
    assign csr_we = (state == WRITE) & ~write_dispatched;
    assign csr_re = (state == READ);
    assign HREADY = (state == IDLE) ||
                    ((state == WRITE) && csr_dispatch) ||
                    ((state == READ) && csr_rready) ||
                    ((state == ERROR) && error_wait);
    assign HRESP = (state == ERROR);
endmodule

`default_nettype wire

`endif
