// trouper_top.v
// Standalone Trouper top-level integration
// GF180MCU 3.3V 32 MHz — SSCS PICO Chipathon 2026
//
// Pad count: 24 signal + 2 power = 26 total (within Chipathon allocation)
//            clk/rst×2, IQ×8, remod×2, PSRAM SCK+CE_N×2,
//            SPI HOST_CS/SCK/MOSI/MISO×4,
//            IRQ_OUT×1 (dedicated pad) + PSRAM-SIO[3:0]×4 (dedicated),
//            ARRAY_ACQ_N×1 (emulated open-drain bidirectional pad).
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
//   IRQ: irq_out (sticky) → IRQ_OUT dedicated pad
//
//   The Grouper inter-project bus (GRP_* byte bus, AHB-Lite H* endpoint and
//   IRQ_GROUPER) was removed on 2026-09-01: Grouper is not taping out, so the
//   whole boundary was dead silicon.  SPI is now the sole register master.

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

    // ---- Interrupt output / shared debug pad ----
    // IRQ_OUT_OUT carries the sticky, level-high interrupt by default and the
    // selected debug source only while DBG_CTRL1.EN=1 (planning/
    // two-pin-digital-debug-plan.md).  Feed-forward: no core logic reads this
    // pad back, so debug traffic on it cannot change receiver behaviour.
    output wire        IRQ_OUT_OUT,       // → IRQ pad, shared with DBG1

    // ---- Digital debug probe (planning/two-pin-digital-debug-plan.md) ----
    // One dedicated pad (DBG0_OUT) plus the shared IRQ_OUT pad above.
    // Output-only at the logical top level; feed-forward observability with no
    // path back into the datapath, FSMs, interrupts, or register gating.
    output wire        DBG0_OUT,

    // ---- Array acquisition synchronisation (external pull-up required) ----
    output wire        ARRAY_ACQ_N_OUT, // permanently 0; OE provides open-drain emulation
    input  wire        ARRAY_ACQ_N_IN,
    output wire        ARRAY_ACQ_N_OE,

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
    // -- ARRAY_ACQ_N: bidir pad emulating open drain (OUT=0, OE=drive) --
    // -- DBG0: output on bi_t (A40 has no output-only cell); DBG1 is merged
    //    onto the IRQ_OUT pad, so it has no control ports of its own --
    input  wire        DBG0_IN,          // unused; pad is bidirectional in the padframe
    output wire        DBG0_OE,
    output wire        DBG0_IE,
    output wire        DBG0_CS,
    output wire        DBG0_SL,
    output wire        DBG0_PU,
    output wire        DBG0_PD,
    output wire        DBG0_PDRV0,
    output wire        DBG0_PDRV1,
    output wire        ARRAY_ACQ_N_IE,
    output wire        ARRAY_ACQ_N_CS,
    output wire        ARRAY_ACQ_N_SL,
    output wire        ARRAY_ACQ_N_PU,
    output wire        ARRAY_ACQ_N_PD,
    output wire        ARRAY_ACQ_N_PDRV0,
    output wire        ARRAY_ACQ_N_PDRV1,
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
    // IQ_DATA_*_raw are the raw pad values; IQ_DATA_*_neg are the negedge
    // (data-eye) samples; IQ_DATA_I/Q are the posedge-retimed, datapath-facing
    // versions (Open Risk #70).
    wire [3:0] IQ_DATA_I_raw = {IQ_DATA_I_3, IQ_DATA_I_2, IQ_DATA_I_1, IQ_DATA_I_0};
    wire [3:0] IQ_DATA_Q_raw = {IQ_DATA_Q_3, IQ_DATA_Q_2, IQ_DATA_Q_1, IQ_DATA_Q_0};
    reg  [3:0] IQ_DATA_I_neg, IQ_DATA_Q_neg;
    reg  [3:0] IQ_DATA_I, IQ_DATA_Q;
    wire [3:0] PSRAM_SIO_IN = {PSRAM_SIO_3_IN, PSRAM_SIO_2_IN,
                               PSRAM_SIO_1_IN, PSRAM_SIO_0_IN};

    // ---- PSRAM QPI pad relaunch (Open Risk #69) --------------------------
    // psram_buf_ctrl drives CE#/SIO/SIO-OE and the raw SCK gate-enable on
    // posedge clk; these negedge flops republish them at the pad boundary so
    // CE#, SIO and SCK all change while SCK is low and the PSRAM samples a
    // stable bus on the SCK rising edge (~15.6 ns setup vs ~0).  Done here,
    // NOT inside psram_buf_ctrl: an in-module negedge stage re-synthesised the
    // QPI FSM and swung SS setup timing -15..-21 ns run-to-run (jobs 5504/6/7);
    // at the pad boundary the FSM is byte-identical to pre-#69.  First command
    // nibble is published on the same negedge as the SCK enable (half-cycle
    // preload); no glitch/runt since the enable only changes while clk=0.
    wire [3:0] psram_sio_out_c, psram_sio_oe_c;   // combinational from u_psram (posedge domain)
    wire       psram_ce_n_c, psram_sck_en_c;
    reg  [3:0] psram_sio_out_q, psram_sio_oe_q;   // negedge-relaunched -> pads
    reg        psram_ce_n_q, psram_sck_en_q;
    // (the negedge relaunch process is with the other clk/rst_n logic below)

    assign {PSRAM_SIO_3_OUT, PSRAM_SIO_2_OUT,
            PSRAM_SIO_1_OUT, PSRAM_SIO_0_OUT} = psram_sio_out_q;
    assign {PSRAM_SIO_3_OE, PSRAM_SIO_2_OE,
            PSRAM_SIO_1_OE, PSRAM_SIO_0_OE} = psram_sio_oe_q;
    assign PSRAM_CE_N_OUT = psram_ce_n_q;
    // PSRAM_SCK_OUT is gated from psram_sck_en_q below (needs `clk`, declared later).

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
    assign PSRAM_SIO_0_IE = ~psram_sio_oe_q[0];
    assign PSRAM_SIO_0_CS = 1'b0;
    assign PSRAM_SIO_0_SL = 1'b0;
    assign PSRAM_SIO_0_PU = 1'b0;
    assign PSRAM_SIO_0_PD = 1'b0;
    assign PSRAM_SIO_0_PDRV0 = 1'b1;
    assign PSRAM_SIO_0_PDRV1 = 1'b1;
    assign PSRAM_SIO_1_IE = ~psram_sio_oe_q[1];
    assign PSRAM_SIO_1_CS = 1'b0;
    assign PSRAM_SIO_1_SL = 1'b0;
    assign PSRAM_SIO_1_PU = 1'b0;
    assign PSRAM_SIO_1_PD = 1'b0;
    assign PSRAM_SIO_1_PDRV0 = 1'b1;
    assign PSRAM_SIO_1_PDRV1 = 1'b1;
    assign PSRAM_SIO_2_IE = ~psram_sio_oe_q[2];
    assign PSRAM_SIO_2_CS = 1'b0;
    assign PSRAM_SIO_2_SL = 1'b0;
    assign PSRAM_SIO_2_PU = 1'b0;
    assign PSRAM_SIO_2_PD = 1'b0;
    assign PSRAM_SIO_2_PDRV0 = 1'b1;
    assign PSRAM_SIO_2_PDRV1 = 1'b1;
    assign PSRAM_SIO_3_IE = ~psram_sio_oe_q[3];
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
    // IRQ_OUT is shared with the DBG1 debug probe (planning/
    // two-pin-digital-debug-plan.md).  SL=0 FAST, not the slow host-link
    // setting used for SPI_MISO: in raw-RX debug mode this pad can toggle on
    // every 32 MHz edge.  The board carries a series-resistor footprint at the
    // pin to damp the edge into the RPi IRQ net instead (Pinout.md, A40
    // pad-control tie-offs; TRPR-SPS-008 slow-slew choice reversed 2026-09-03).
    assign IRQ_OUT_OE = 1'b1;
    assign IRQ_OUT_IE = 1'b0;
    assign IRQ_OUT_CS = 1'b0;
    assign IRQ_OUT_SL = 1'b0;
    assign IRQ_OUT_PU = 1'b0;
    assign IRQ_OUT_PD = 1'b0;
    assign IRQ_OUT_PDRV0 = 1'b1;
    assign IRQ_OUT_PDRV1 = 1'b0;
    // ARRAY_ACQ_N must have an external pull-up. The core never drives a 1:
    // OE asserts the low driver and deassertion releases the shared wire.
    wire array_acq_drive_oe;
    wire array_peer_lock_pulse;
    assign ARRAY_ACQ_N_OUT   = 1'b0;
    assign ARRAY_ACQ_N_OE    = array_acq_drive_oe;
    assign ARRAY_ACQ_N_IE    = 1'b1;
    assign ARRAY_ACQ_N_CS    = 1'b1; // Schmitt input for a board-level wire
    assign ARRAY_ACQ_N_SL    = 1'b1;
    // DBG0 pad controls. Permanently enabled output, CMOS, FAST slew and
    // mid (8 mA) drive: unlike SPI_MISO this can toggle on every 32 MHz edge
    // in raw-RX mode, so the slow-slew choice used for the host link is not
    // adequate here (see the plan's electrical contract; the board carries a
    // 0-ohm series footprint at the pin for damping instead).  DBG1 shares the
    // IRQ_OUT pad and inherits its (now equally fast) tie-offs above.
    assign DBG0_OE    = 1'b1;
    assign DBG0_IE    = 1'b0;   // output only; never turn the receiver on
    assign DBG0_CS    = 1'b0;   // CMOS
    assign DBG0_SL    = 1'b0;   // fast
    assign DBG0_PU    = 1'b0;
    assign DBG0_PD    = 1'b0;
    assign DBG0_PDRV0 = 1'b1;   // {PDRV1,PDRV0} = 01 -> 8 mA
    assign DBG0_PDRV1 = 1'b0;

    // Internal pull-up ENABLED, unlike every other input pad on this chip.
    // ARRAY_ACQ_N is the one pin a board may legitimately leave unpopulated
    // (a single-chip receiver has no array to sync with), and an undriven
    // input with IE=1 sits the receiver near mid-rail drawing static current.
    // This is belt-and-braces only: the external pull-up is still mandatory on
    // a real multi-chip net, where these internal devices sit in parallel with
    // it and must be counted in the pull-up/VOL budget (Open Risks #53).
    assign ARRAY_ACQ_N_PU    = 1'b1;
    assign ARRAY_ACQ_N_PD    = 1'b0;
    assign ARRAY_ACQ_N_PDRV0 = 1'b0; // minimum drive is enough to sink pull-up
    assign ARRAY_ACQ_N_PDRV1 = 1'b0;
    assign PSRAM_SCK_OE = 1'b1;
    assign PSRAM_SCK_IE = 1'b0;
    assign PSRAM_SCK_CS = 1'b0;
    assign PSRAM_SCK_SL = 1'b0;
    assign PSRAM_SCK_PU = 1'b0;
    assign PSRAM_SCK_PD = 1'b0;
    // Sink the unused pad-input-path nets from the output-only bidir pads.
    wire _unused_pad_in = &{1'b0, PSRAM_CE_N_IN, REMOD_A_I_IN, REMOD_A_Q_IN,
                            SPI_MISO_IN, IRQ_OUT_IN, PSRAM_SCK_IN, DBG0_IN};

    // =========================================================================
    // Global clock and reset
    // =========================================================================
    wire clk   = IQ_CLK;
    wire rst_n = RESETB;

    // ---- SX1257 IQ input capture (Open Risk #70) ---------------------------
    // The SX1257 presents its 1-bit ΣΔ I/Q streams with a data-valid
    // (setup-and-hold) window of ~25 ns centred on the FALLING edge of the
    // shared clock (DS_SX1257 §3.7.4 RX digital interface).  Two-stage capture:
    //   *_neg       — sampled on `negedge clk`, i.e. in the middle of the eye.
    //   IQ_DATA_I/Q — retimed onto `posedge clk` before the datapath sees them.
    // The negedge→posedge hop (`*_neg` → `IQ_DATA_*`) carries no logic, so it
    // clears the unavoidable half-cycle path with ~15 ns of slack, and every
    // real datapath path (CIC integrators, comb, HB) runs on the full 31.25 ns
    // period again.  A single negedge stage feeding the datapath directly put
    // the CIC 14-bit add on a half-cycle path and lost SS timing (73
    // violations, job 5504).  Cost: +1 clk latency (31 ns) — negligible at the
    // 500 kS/s output rate.  Feeds BOTH the decimator and the debug probe.
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            IQ_DATA_I_neg <= 4'd0;
            IQ_DATA_Q_neg <= 4'd0;
        end else begin
            IQ_DATA_I_neg <= IQ_DATA_I_raw;
            IQ_DATA_Q_neg <= IQ_DATA_Q_raw;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            IQ_DATA_I <= 4'd0;
            IQ_DATA_Q <= 4'd0;
        end else begin
            IQ_DATA_I <= IQ_DATA_I_neg;
            IQ_DATA_Q <= IQ_DATA_Q_neg;
        end
    end

    // ---- PSRAM QPI pad relaunch (Open Risk #69) — see decl block above -----
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psram_sio_out_q <= 4'd0;
            psram_sio_oe_q  <= 4'd0;
            psram_ce_n_q    <= 1'b1;
            psram_sck_en_q  <= 1'b0;
        end else begin
            psram_sio_out_q <= psram_sio_out_c;
            psram_sio_oe_q  <= psram_sio_oe_c;
            psram_ce_n_q    <= psram_ce_n_c;
            psram_sck_en_q  <= psram_sck_en_c;
        end
    end
    assign PSRAM_SCK_OUT = psram_sck_en_q & clk;   // gated: SCK held low across the negedge relaunch

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
    // directly by the SPI master, bypassing the CE dispatch path.  The SPI
    // slave holds its request for several clk edges, so each side effect is
    // explicitly edge-detected.
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
    wire        rb_array_sync_en;
    // Two-pin digital debug (planning/two-pin-digital-debug-plan.md)
    wire [7:0]  rb_dbg_ctrl0;   // 0x04: selector for the dedicated DBG0 pad
    wire [7:0]  rb_dbg_ctrl1;   // 0x06: selector for the shared IRQ_OUT/DBG1 pad
    wire [7:0]  rb_bringup_ctrl;      // BRINGUP_CTRL (0x10) — Open Risks #59
    wire signed [7:0] rb_bringup_ampl; // BRINGUP_AMPL (0x11)
    wire [7:0]  rb_irq_status_dbg;
    wire        sc_tdm_busy_dbg;
    wire        psram_del_rdy_dbg;
    wire [1:0]  dbg_pad_value;  // ARRAY_SYNC_CTRL[0] (0x18); resets 0 = link off
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
    wire        sc_lock_natural_pulse;
    wire        rb_sc_force_lock; // manual SC lock override (SC_FORCE_LOCK 0x19); declared here to avoid forward-reference
    wire        rb_rx_hold;       // RX_HOLD (0x1A[0]); declared here to avoid forward-reference

    // =========================================================================
    // Stage 3b: Schmidl-Cox preamble detector
    // =========================================================================
    wire [31:0] timing_ref;
    wire [15:0] sc_stat;
    wire        sc_hit_dbg;    // 1-cycle pulse: noise-window contamination latch
    wire        sc_pipe_active; // Open Risk #66: SC eval pipeline in flight
    wire        sc_eval_done_pulse; // Open Risk #66 P2: 1-cycle, an SC metric evaluation completed
    wire        sc_eval_start_pulse; // Open Risk #66 P2: 1-cycle, an SC metric evaluation launched
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
        .sc_lock_sync   (array_peer_lock_pulse),
        .sc_lock        (sc_lock),
        .sc_lock_natural_pulse (sc_lock_natural_pulse),
        .timing_ref     (timing_ref),
        .c_i0 (), .c_q0 (),
        .sc_stat              (sc_stat),
        .sc_tdm_busy_dbg      (sc_tdm_busy_dbg),
        .sc_pipe_active       (sc_pipe_active),
        .sc_eval_done_pulse   (sc_eval_done_pulse),
        .sc_eval_start_pulse  (sc_eval_start_pulse),
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
    wire               training_done;      // either-mode completion (reg_bank status / IRQ, #66 block)
    wire               training_done_pkt;  // packet-mode completion only (packet FSM + w_pending)
    wire               noise_abort;        // armed noise window cancelled by a real sc_lock
    wire [17:0]        n_acc;
    wire               training_armed;
    wire               rb_noise_trig;    // firmware-triggered noise measurement pulse
    // Declared here (driven by the Stage 7 packet FSM below) because the
    // noise-trigger qualification above needs it; Icarus rejects a net that
    // is used before its declaration.
    wire               packet_active;
    // A noise window is an idle-only operation.  It cannot replace either an
    // in-flight training window or a packet whose training window has already
    // completed: in the latter case re-arming would overwrite the Z snapshot
    // while the packet FSM still owns the packet.  Reject both cases and
    // report the rejection through reg_bank 0x1F[1].
    //
    // Qualify the RISING EDGE, not the level.  reg_bank holds a W1P output for
    // one CE period = 2 clk cycles, and training_acc arms on the same rising
    // edge -- so on the pulse's second cycle training_armed is already 1 and a
    // level-sensitive test would report the accepted trigger as rejected.
    reg                rb_noise_trig_q;
    wire               noise_trig_rise = rb_noise_trig && !rb_noise_trig_q;
    wire               noise_trig_accept = noise_trig_rise && !training_armed && !packet_active;
    wire               noise_trig_rej_now = noise_trig_rise && (training_armed || packet_active);
    // training_acc edge-detects, so the 1-cycle accept pulse is enough for it.
    // The rejection reaches reg_bank, which only samples on ce_16m -- a
    // one-cycle pulse lands on the idle phase half the time and is lost.
    // Stretch it to two clk cycles so it always covers one CE edge.
    reg                noise_trig_rej_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rb_noise_trig_q  <= 1'b0;
            noise_trig_rej_d <= 1'b0;
        end else begin
            rb_noise_trig_q  <= rb_noise_trig;
            noise_trig_rej_d <= noise_trig_rej_now;
        end
    end
    wire               noise_trig_rejected = noise_trig_rej_now || noise_trig_rej_d;

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
        .noise_trig   (noise_trig_accept),
        .Zpair_i0 (Zpair_i[0]), .Zpair_q0 (Zpair_q[0]),
        .Zpair_i1 (Zpair_i[1]), .Zpair_q1 (Zpair_q[1]),
        .Zpair_i2 (Zpair_i[2]), .Zpair_q2 (Zpair_q[2]),
        .Zpair_i3 (Zpair_i[3]), .Zpair_q3 (Zpair_q[3]),
        .Zpair_i4 (Zpair_i[4]), .Zpair_q4 (Zpair_q[4]),
        .Zpair_i5 (Zpair_i[5]), .Zpair_q5 (Zpair_q[5]),
        .Zdiag_0  (Zdiag[0]),   .Zdiag_1  (Zdiag[1]),
        .Zdiag_2  (Zdiag[2]),   .Zdiag_3  (Zdiag[3]),
        .training_done     (training_done),
        .training_done_pkt (training_done_pkt),
        .noise_abort       (noise_abort),
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
    reg         noise_window_draining;   // training_done seen; waiting for the SC
                                         // eval pipeline to drain before the verdict
    reg  [6:0]  noise_drain_cnt;         // fixed minimum drain, covers SC metric latency
    reg         noise_sc_was_active;     // Open Risk #66 (P2): sc_pipe_active seen at any
                                         // point this window -> the SC detector is live
    reg         noise_eval_armed;        // Open Risk #66 (P2): an SC evaluation has LAUNCHED
                                         // since the drain began
    reg         noise_eval_seen;         // Open Risk #66 (P2): that launched-in-drain
                                         // evaluation has now completed
    reg         sigma2_valid_r;

    // SC serial metric engine is ~57 cycles deep; hold the drain phase at least
    // this long so an evaluation that was already in flight at training_done has
    // definitely resolved (asserted sc_hit_dbg / sc_lock, or not) before we look.
    // sc_pipe_active can read low for a cycle right after training_done while the
    // contaminating evaluation is still mid-pipe -- the fixed count closes that
    // race; the !sc_pipe_active term then only extends the wait if needed.
    localparam [6:0] NOISE_DRAIN_MIN = 7'd72;

    // Firmware-triggered noise measurements reuse training_acc noise mode.
    // Accept the resulting Zdiag window only if no SC activity appeared while
    // the measurement was in flight.
    //
    // Open Risk #66: sc_hit_dbg / sc_lock are REGISTERED sc_detector outputs.
    // A non-locking hit whose evaluation overlapped the window can register its
    // sc_hit_dbg pulse a variable number of edges AFTER training_done (the
    // serial metric engine is ~57 cycles deep), so simply peeking at sc_hit_dbg
    // on the training_done edge misses it. Instead, on training_done enter a
    // drain phase -- keep noise_window_active high so the sc_hit_dbg/sc_lock
    // sampler below keeps running -- and hold the verdict until ALL of:
    //   (1) a fixed NOISE_DRAIN_MIN count has elapsed (>= metric-engine depth);
    //   (2) sc_pipe_active is low (no TDM burst / evaluation in flight);
    //   (3) IF the SC detector is live this window (noise_sc_was_active): an SC
    //       evaluation that was *launched after* the drain began has completed
    //       (noise_eval_armed -> noise_eval_seen). An evaluation only launches
    //       at a symbol boundary, so (2) alone does not prove the symbol that
    //       was accumulating at training_done has been judged; and one already
    //       in flight at training_done was fed the *previous* symbol, so it
    //       must not count (Open Risk #66 P2). If the SC detector never ran this
    //       window (PSRAM / SC-delay path disabled -> no evaluations at all),
    //       there is no contamination to wait for and (3) is skipped so
    //       NOISE_READY cannot deadlock.
    // Worst-case NOISE_READY latency grows by ~1 symbol period, irrelevant for
    // the AGC noise-EMA use. Safe-biased: a stray hit AFTER the window merely
    // suppresses this measurement (firmware retries); it can never let a
    // contaminated window through.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_window_active   <= 1'b0;
            noise_window_sc_seen  <= 1'b0;
            noise_window_draining <= 1'b0;
            noise_drain_cnt       <= 7'd0;
            noise_sc_was_active   <= 1'b0;
            noise_eval_armed      <= 1'b0;
            noise_eval_seen       <= 1'b0;
            sigma2_valid_r        <= 1'b0;
        end else begin
            sigma2_valid_r    <= 1'b0;

            // Open Risk #66/#68: ONE priority ladder. The previous two-chain
            // form let a fresh trigger accepted on the drain-release edge race
            // the old window's verdict (verdict won -> new window silently
            // lost). A fresh trigger now unconditionally wins and starts a
            // clean window, pre-empting any in-progress drain/verdict; the
            // abandoned measurement is fine (firmware asked for a new one).
            if (noise_trig_accept) begin
                noise_window_active   <= 1'b1;
                noise_window_sc_seen  <= 1'b0;
                noise_window_draining <= 1'b0;
                noise_drain_cnt       <= 7'd0;
                noise_sc_was_active   <= 1'b0;
                noise_eval_armed      <= 1'b0;
                noise_eval_seen       <= 1'b0;
            end else if (noise_window_active && noise_abort) begin
                // A real packet pre-empted this firmware noise measurement
                // (training_acc cancelled the window). Drop it with no verdict:
                // firmware's NOISE_READY wait times out and it retries once the
                // packet clears.
                noise_window_active   <= 1'b0;
                noise_window_sc_seen  <= 1'b0;
                noise_window_draining <= 1'b0;
                noise_drain_cnt       <= 7'd0;
                noise_sc_was_active   <= 1'b0;
                noise_eval_armed      <= 1'b0;
                noise_eval_seen       <= 1'b0;
            end else if (noise_window_active) begin
                if (sc_hit_dbg || sc_lock)
                    noise_window_sc_seen <= 1'b1;
                if (sc_pipe_active)
                    noise_sc_was_active <= 1'b1;   // SC detector is live this window

                if (!noise_window_draining) begin
                    if (training_done) begin
                        noise_window_draining <= 1'b1;      // start draining
                        noise_drain_cnt       <= NOISE_DRAIN_MIN;
                        noise_eval_armed      <= 1'b0;
                        noise_eval_seen       <= 1'b0;
                    end
                end else begin
                    if (noise_drain_cnt != 7'd0)
                        noise_drain_cnt <= noise_drain_cnt - 7'd1;
                    // Open Risk #66 (P2): only an evaluation that LAUNCHED after
                    // the drain began covers the symbol holding the noise-window
                    // tail. Arm on its start pulse, latch seen on its completion.
                    if (sc_eval_start_pulse)
                        noise_eval_armed <= 1'b1;
                    if (sc_eval_done_pulse && noise_eval_armed)
                        noise_eval_seen <= 1'b1;
                    if (noise_drain_cnt == 7'd0 && !sc_pipe_active &&
                            (!noise_sc_was_active || noise_eval_seen)) begin
                        sigma2_valid_r        <= ~(noise_window_sc_seen || sc_lock);
                        noise_window_active   <= 1'b0;
                        noise_window_sc_seen  <= 1'b0;
                        noise_window_draining <= 1'b0;
                        noise_sc_was_active   <= 1'b0;
                        noise_eval_armed      <= 1'b0;
                        noise_eval_seen       <= 1'b0;
                    end
                end
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
    wire        packet_active_ps;   // fanout-split duplicate, u_psram only
    wire [1:0]  active_mode;
    wire [3:0]  active_antenna_en;

    // Shared active-low board wire between coherent Trouper instances. The
    // dedicated arbiter keeps a peer request out of an active packet and makes
    // a local qualified SC lock win a simultaneous peer assertion.
    array_acq_sync u_array_acq_sync (
        .clk             (clk),
        .rst_n           (rst_n),
        .array_sync_en   (rb_array_sync_en),
        .local_lock_pulse(sc_lock_natural_pulse),
        .local_lock_level(sc_lock),
        .packet_active   (packet_active),
        .packet_done     (packet_done_pulse),
        .rx_hold         (rb_rx_hold),
        .acq_n_async     (ARRAY_ACQ_N_IN),
        .drive_oe        (array_acq_drive_oe),
        .peer_lock_pulse (array_peer_lock_pulse)
    );

    // W_valid: single authoritative copy, exported from packet_ctrl_fsm
    // (Open Risk #62). The old top-level reconstruction from the W_valid_set
    // pulse cleared on every !packet_active, so a commit consumed in IDLE left
    // the FSM copy high and this copy low -- the next packet then combined in
    // bypass with no W_MISSED_PACKET. The FSM level is now the only copy: it is
    // consumed by the combiner, the reg_bank live-weight write-lock, and the
    // debug/readback paths.
    wire W_valid;

    // W_pending: training complete but W not yet committed this packet.
    // Gated on training_done_pkt (packet-mode only) so a firmware noise-window
    // completion can never raise w_pending / advance the packet FSM.
    reg  w_pending;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)                 w_pending <= 1'b0;
        else if (training_done_pkt) w_pending <= 1'b1;
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
        .training_done   (training_done_pkt),
        .W_commit        (W_commit_hw),
        .mode_shadow     (rb_mimo_mode),
        .antenna_en_shadow (rb_antenna_en),
        .pkt_timeout_syms (rb_pkt_timeout_syms),
        .tacc_window_syms (rb_tacc_window_syms),
        .W_valid_set     (W_valid_set),
        .W_valid         (W_valid),
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
        .sck          (),                  // pre-#69 gated clock; pad SCK is built below from sck_en_o
        .sck_en_o     (psram_sck_en_c),
        .ce_n         (psram_ce_n_c),
        .sio_out      (psram_sio_out_c),
        .sio_in       (PSRAM_SIO_IN),
        .sio_oe       (psram_sio_oe_c),
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
        .del_rdy_dbg  (psram_del_rdy_dbg),
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

    // -------------------------------------------------------------------------
    // BRINGUP_SRC: deterministic first-silicon sample source.
    //
    // Proves sd_remod without a working frontend, SC acquisition, PSRAM replay
    // path or combiner.  Injected at the RE-MODULATOR INPUT (stage 9 below),
    // not at the combiner input.  See
    // planning/foundational-block-bringup-plan.md.
    //
    // The generator is declared here, next to the register decode it reads,
    // and consumed at the sd_remod instance; the mux itself lives there.
    //
    // The enable is qualified HERE, not in the generator: arming is already
    // refused by reg_bank unless cfg_wr_ok, but the level term must also hold
    // continuously, because sd_remod's integrators carry state across samples.
    // A mux that flipped mid-stream would leave the loop tracking a mixture of
    // the injected and live streams, and the recovery transient would be read
    // as modulator misbehaviour rather than as a control-plane glitch.
    // -------------------------------------------------------------------------
    wire              bringup_en_q = rb_bringup_ctrl[0] && rb_rx_hold && !packet_active;
    wire signed [7:0] bsrc_i, bsrc_q;
    wire              bsrc_valid;

    bringup_src #(.DECIM(64)) u_bringup_src (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (bringup_en_q),
        .mode      (rb_bringup_ctrl[2:1]),
        .ampl      (rb_bringup_ampl),
        .src_i     (bsrc_i),
        .src_q     (bsrc_q),
        .src_valid (bsrc_valid)
    );

    // Combiner input mux: live decimator IQ during normal/buffering, PSRAM
    // replay IQ during replay. x_valid follows the active source.
    //
    // BRINGUP_SRC is NOT an arm here.  It was, until the coverage work showed
    // the combiner insertion point bought nothing: MRC is unreachable while the
    // source is armed (W_valid is held only during a packet, the armed source
    // requires none), so the only combiner behaviour the source could reach was
    // the bypass passthrough -- a wire.  Injecting at the re-modulator input
    // instead proves exactly the same thing for a 3-point mux rather than a
    // 9-point one, and isolates sd_remod properly: a bad output stream there
    // implicates sd_remod alone, not sd_remod OR the bypass path.
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
    wire              comb_use_mrc;   // burst-aligned MRC(1)/bypass(0), Open Risk #65

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
        .y_valid(comb_y_valid),
        .use_mrc(comb_use_mrc)
    );

    // =========================================================================
    // Stage 9: ΣΔ Re-modulator → SX1302 Radio A
    // During PSRAM BUFFERING (buf_active && !replay_active): modulate zero —
    // in_valid keeps pulsing so sd_remod latches actual silence rather than
    // holding the last pre-lock sample as a DC tone (Open Risks #5 fix).
    // During REPLAY: combiner processes PSRAM replay IQ → normal remod path.
    // =========================================================================
    wire psram_silence = psram_buf_active && !psram_replay_active_w;
    // REMOD_BACKOFF_SHIFT is an MRC-path safety margin only: the combiner output
    // can exceed the sd_remod < -3 dBFS stability limit. Mode-1 / no-W_valid
    // bypass just forwards one antenna's int8 sample, which is always in range,
    // so the shift must NOT attenuate it (Open Risk #65 / TRPR-PCF-011 /
    // TRPR-RMD-008). comb_use_mrc is burst-aligned with comb_y_i/q.
    wire signed [7:0] remod_bo_i = comb_use_mrc ? ($signed(comb_y_i) >>> rb_remod_backoff_shift)
                                               : comb_y_i;
    wire signed [7:0] remod_bo_q = comb_use_mrc ? ($signed(comb_y_q) >>> rb_remod_backoff_shift)
                                               : comb_y_q;
    wire signed [7:0] remod_src_i = psram_silence ? 8'sd0 : remod_bo_i;
    wire signed [7:0] remod_src_q = psram_silence ? 8'sd0 : remod_bo_q;

    // BRINGUP_SRC injection point (Open Risks #59).  The armed source takes
    // ABSOLUTE priority -- ahead of psram_silence, the backoff shift AND the
    // comb_use_mrc bypass select -- deliberately:
    //   * psram_silence would let a buffer state zero the stimulus, and silence
    //     at the pads is indistinguishable from a dead re-modulator, which is
    //     the exact diagnosis this source exists to make possible.
    //   * the backoff shift / bypass select would make the pad signature depend
    //     on COMB_CFG / W_valid, so the reference a bring-up engineer compares
    //     against would no longer be the value they programmed.
    // Skipping the backoff is safe: the generator clamps to +/-64 of a signed-8
    // full scale (-6 dBFS), already inside sd_remod's -3 dBFS stability bound,
    // so no shift is needed to keep the NTF out of wrap-around.
    wire signed [7:0] remod_in_i = bringup_en_q ? bsrc_i : remod_src_i;
    wire signed [7:0] remod_in_q = bringup_en_q ? bsrc_q : remod_src_q;
    wire              remod_in_valid = bringup_en_q ? bsrc_valid : comb_y_valid;

    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (remod_in_i),
        .in_q     (remod_in_q),
        .in_valid (remod_in_valid),
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
    // Register bus sequencer.  SPI is the sole register master since the
    // Grouper boundary was removed (2026-09-01), so there is nothing left to
    // arbitrate against.
    //
    // A completed SPI write is a short clk-domain event and cannot be stalled
    // back at the serial pins.  Capture it in a one-entry pending slot until
    // the next CE edge can dispatch it into the register bank.
    // =========================================================================
    reg        spi_reg_we_d;
    reg        spi_wr_pending;
    reg [7:0]  spi_wr_pending_addr;
    reg [7:0]  spi_wr_pending_data;
    wire       spi_wr_new = spi_reg_we & ~spi_reg_we_d;

    // PSRAM debug-write byte port (0x79): a single push per completed SPI
    // write.  The SPI slave holds 0x79 for a burst, so this needs the one-shot
    // strobe rather than the level-qualified write enable.
    assign psram_dbg_wdata_w      = spi_reg_wdata;
    assign psram_dbg_wdata_push_w = spi_wr_new && (spi_reg_wr_addr == 8'h79);

    assign psram_dbg_data_pop_w = spi_reg_re && (spi_reg_re_addr == 8'h76);

    // CE-latched WRITE bus: addr/wdata/we are sampled TOGETHER on a CE edge and
    // captured by the CE-gated reg_bank on the next CE edge, so the whole write
    // decode is a consistent, genuine 2-cycle path (honest MCP=2).
    reg [7:0] rb_addr, rb_wdata;
    reg       rb_we;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_reg_we_d       <= 1'b0;
            spi_wr_pending     <= 1'b0;
            spi_wr_pending_addr <= 8'd0;
            spi_wr_pending_data <= 8'd0;
            rb_addr <= 8'd0; rb_wdata <= 8'd0; rb_we <= 1'b0;
        end else begin
            spi_reg_we_d <= spi_reg_we;

            if (spi_wr_new) begin
                spi_wr_pending      <= 1'b1;
                spi_wr_pending_addr <= spi_reg_wr_addr;
                spi_wr_pending_data <= spi_reg_wdata;
            end

            if (ce_16m) begin
                if (spi_wr_pending) begin
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
    // SPI is the only reader, so there is no contention for this single port.
    wire [7:0] rb_raddr = spi_reg_rd_addr;

    // reg_bank's registered read path (re/rdata/ready) existed only to give the
    // Grouper bus a wait-stated read.  SPI reads through the combinational
    // peek tap, so `re` is tied off and rdata/ready are left unconnected —
    // synthesis drops the read_valid state and its output register.
    wire       rb_re    = 1'b0;

    assign spi_reg_rdata = rb_peek_rdata_w;

    // ---- Register Bank ----
    // rb_irq_out_sticky drives the shared IRQ_OUT/DBG1 pad below, muxed with
    // the debug probe by dbg1_en_w.
    wire rb_irq_out_sticky;

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
        .noise_trig_rejected (noise_trig_rejected),
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
        .array_sync_en   (rb_array_sync_en),
        .dbg_ctrl0       (rb_dbg_ctrl0),
        .dbg_ctrl1       (rb_dbg_ctrl1),
        .bringup_ctrl    (rb_bringup_ctrl),
        .bringup_ampl    (rb_bringup_ampl),
        .dbg_pad_value   (dbg_pad_value),
        .irq_status_dbg  (rb_irq_status_dbg),
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

    // =========================================================================
    // Two-pin digital debug probe
    // =========================================================================
    // Feed-forward observability only: every input below is an already-existing
    // registered signal, and the only outputs are DBG0_OUT, the shared-pad
    // value/enable pair, and the DBG_STATUS readback.  Nothing here drives the
    // datapath, the FSMs, the interrupt tree, PSRAM ownership, or register-write
    // gating, so a stuck or shorted debug pad cannot change how the receiver
    // behaves.  Split selector: DBG_CTRL0 -> DBG0_OUT, DBG_CTRL1 -> the shared
    // IRQ_OUT/DBG1 pad.  See planning/two-pin-digital-debug-plan.md.
    wire dbg1_val_w, dbg1_en_w;
    debug_probe_mux u_dbg (
        .clk            (clk),
        .rst_n          (rst_n),
        .dbg_ctrl0      (rb_dbg_ctrl0),
        .dbg_ctrl1      (rb_dbg_ctrl1),
        // group 001 raw RX (registered inside the mux, never combinational
        // pad-to-pad)
        .iq_data_i      (IQ_DATA_I),
        .iq_data_q      (IQ_DATA_Q),
        // group 010 decimated + DC-removed IQ
        .dc_i0 (dcr_i[0]), .dc_i1 (dcr_i[1]), .dc_i2 (dcr_i[2]), .dc_i3 (dcr_i[3]),
        .dc_q0 (dcr_q[0]), .dc_q1 (dcr_q[1]), .dc_q2 (dcr_q[2]), .dc_q3 (dcr_q[3]),
        // group 011 SC
        .sc_hit         (sc_hit_dbg),
        .sc_lock        (sc_lock),
        .del_rdy        (psram_del_rdy_dbg),
        .sc_tdm_busy    (sc_tdm_busy_dbg),
        // group 100 packet / weights
        .packet_active  (packet_active),
        .training_done  (training_done),
        .w_pending      (w_pending),
        .w_valid        (W_valid),
        .packet_phase   (packet_phase),
        // group 101 PSRAM
        .psram_init_done(psram_qe_init_done),
        .qpi_busy       (|psram_state_dbg),
        .buf_active     (psram_buf_active),
        .replay_active  (psram_replay_active_w),
        .sample_skip    (psram_sample_skip),
        .replay_missed  (psram_replay_missed),
        .psram_dbg_busy (psram_dbg_busy_w),
        .qspi_owner     (rb_psram_ctrl[3]),
        // group 110 combiner (the registered int8 pair presented to sd_remod)
        .comb_i         (remod_in_i),
        .comb_q         (remod_in_q),
        // group 111 IRQ
        .irq_status     (rb_irq_status_dbg),
        .irq_out        (rb_irq_out_sticky),
        .dbg0           (DBG0_OUT),
        .dbg1_val       (dbg1_val_w),
        .dbg1_en        (dbg1_en_w)
    );
    // Shared IRQ_OUT / DBG1 pad: the sticky interrupt by default, the selected
    // debug source only while DBG_CTRL1.EN=1.  Nothing in the core reads
    // IRQ_OUT_OUT, so this mux is feed-forward and cannot perturb the receiver.
    assign IRQ_OUT_OUT   = dbg1_en_w ? dbg1_val_w : rb_irq_out_sticky;
    assign dbg_pad_value = {IRQ_OUT_OUT, DBG0_OUT};

endmodule


// Debug probe mux: DBG_CTRL -> two pads.
//
// DBG_CTRL = {EN, GROUP[2:0], ANT[1:0], SEL[1:0]}.  Reserved encodings are not
// clamped -- they drive zero, which is the same as disabled, so an unrecognised
// selection can never be mistaken for live data.
//
// The raw-RX group is the only one that needs storage: the IQ pads change on
// every 32 MHz edge, and routing them combinationally from input pad to output
// pad would create a pad-to-pad path with no flop between.  Eight dedicated
// flops sample them first, so the probe is an exact copy delayed by one cycle.
// Every other group taps a signal that is already registered upstream.
// Split-selector debug mux (planning/two-pin-digital-debug-plan.md).
//
//   DBG_CTRL0 (0x04) -> the dedicated DBG0 pad, taking the d0 column of the
//                       encoding table.
//   DBG_CTRL1 (0x06) -> the shared IRQ_OUT/DBG1 pad, taking the d1 column.
//                       dbg1_en = DBG_CTRL1.EN tells the top level whether the
//                       pad carries this value or the sticky interrupt.
//
// Each byte is {EN, GROUP[2:0], ANT[1:0], SEL[1:0]} and is decoded fully
// independently, so DBG0 and the shared pad can point at unrelated signals --
// e.g. the shared pad pinned to G_IRQ (irq_out) while DBG0 roams the other
// groups.  Bit-for-bit the same source table as the pre-split single-selector
// version; only the control fan-in changed.
module debug_probe_mux (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  dbg_ctrl0,
    input  wire [7:0]  dbg_ctrl1,
    input  wire [3:0]  iq_data_i,
    input  wire [3:0]  iq_data_q,
    input  wire signed [7:0] dc_i0, dc_i1, dc_i2, dc_i3,
    input  wire signed [7:0] dc_q0, dc_q1, dc_q2, dc_q3,
    input  wire        sc_hit,
    input  wire        sc_lock,
    input  wire        del_rdy,
    input  wire        sc_tdm_busy,
    input  wire        packet_active,
    input  wire        training_done,
    input  wire        w_pending,
    input  wire        w_valid,
    input  wire [2:0]  packet_phase,
    input  wire        psram_init_done,
    input  wire        qpi_busy,
    input  wire        buf_active,
    input  wire        replay_active,
    input  wire        sample_skip,
    input  wire        replay_missed,
    input  wire        psram_dbg_busy,
    input  wire        qspi_owner,
    input  wire signed [7:0] comb_i,
    input  wire signed [7:0] comb_q,
    input  wire [7:0]  irq_status,
    input  wire        irq_out,
    output wire        dbg0,       // dedicated DBG0 pad (d0 column, EN0-gated)
    output wire        dbg1_val,   // shared-pad debug value (d1 column, EN1-gated)
    output wire        dbg1_en     // 1 = shared pad carries dbg1_val, else IRQ
);
    localparam [2:0] G_RAW    = 3'b001;
    localparam [2:0] G_DEC    = 3'b010;
    localparam [2:0] G_SC     = 3'b011;
    localparam [2:0] G_PKT    = 3'b100;
    localparam [2:0] G_PSRAM  = 3'b101;
    localparam [2:0] G_COMB   = 3'b110;
    localparam [2:0] G_IRQ    = 3'b111;

    // Raw-RX capture flops.  Free-running: they cost the same either way and
    // keeping them out of the enable term avoids a wide enable fanout onto the
    // IQ input cone, which is the one place the plan requires this feature not
    // to disturb (see the P&R note in the plan).
    reg [3:0] raw_i_q, raw_q_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            raw_i_q <= 4'd0;
            raw_q_q <= 4'd0;
        end else begin
            raw_i_q <= iq_data_i;
            raw_q_q <= iq_data_q;
        end
    end

    // {d1, d0} for one (group, ant, sel) selection.  d0 is the DBG0-column
    // source, d1 the shared-pad-column source.  SEL maps sample-group bytes to
    // bits 7, 6, 1, 0 (sign bit first).  Reserved encodings return 0 on both
    // columns -- never clamped, so an invalid selection reads back verbatim but
    // drives its pad low.
    function [1:0] probe_pair;
        input [2:0] group;
        input [1:0] ant;
        input [1:0] sel;
        reg d0, d1;
        reg [7:0] dc_i_sel, dc_q_sel;
        reg [3:0] dc_i_lane, dc_q_lane, comb_i_lane, comb_q_lane;
        begin
            d0 = 1'b0;
            d1 = 1'b0;
            case (ant)
                2'd0: begin dc_i_sel = dc_i0; dc_q_sel = dc_q0; end
                2'd1: begin dc_i_sel = dc_i1; dc_q_sel = dc_q1; end
                2'd2: begin dc_i_sel = dc_i2; dc_q_sel = dc_q2; end
                default: begin dc_i_sel = dc_i3; dc_q_sel = dc_q3; end
            endcase
            dc_i_lane   = {dc_i_sel[0], dc_i_sel[1], dc_i_sel[6], dc_i_sel[7]};
            dc_q_lane   = {dc_q_sel[0], dc_q_sel[1], dc_q_sel[6], dc_q_sel[7]};
            comb_i_lane = {comb_i[0],   comb_i[1],   comb_i[6],   comb_i[7]};
            comb_q_lane = {comb_q[0],   comb_q[1],   comb_q[6],   comb_q[7]};
            case (group)
                G_RAW: begin
                    d0 = raw_i_q[ant];
                    d1 = raw_q_q[ant];
                end
                G_DEC: begin
                    d0 = dc_i_lane[sel];
                    d1 = dc_q_lane[sel];
                end
                G_SC: case (sel)
                    2'd0: begin d0 = sc_hit;  d1 = sc_lock;       end
                    2'd1: begin d0 = del_rdy; d1 = sc_tdm_busy;   end
                    2'd2: begin d0 = sc_lock; d1 = packet_active; end
                    default: begin d0 = 1'b0; d1 = 1'b0; end   // reserved
                endcase
                G_PKT: case (sel)
                    2'd0: begin d0 = packet_active;   d1 = training_done;   end
                    2'd1: begin d0 = w_pending;       d1 = w_valid;         end
                    2'd2: begin d0 = packet_phase[0]; d1 = packet_phase[1]; end
                    default: begin d0 = 1'b0; d1 = 1'b0; end   // reserved
                endcase
                G_PSRAM: case (sel)
                    2'd0: begin d0 = psram_init_done; d1 = qpi_busy;       end
                    2'd1: begin d0 = buf_active;      d1 = replay_active;  end
                    2'd2: begin d0 = sample_skip;     d1 = replay_missed;  end
                    default: begin d0 = psram_dbg_busy; d1 = qspi_owner;   end
                endcase
                G_COMB: begin
                    d0 = comb_i_lane[sel];
                    d1 = comb_q_lane[sel];
                end
                G_IRQ: begin
                    // SEL is 2 bits, so only irq_status[3:0] is reachable on the
                    // d0 column; the remaining sticky bits stay readable over
                    // SPI at IRQ_STATUS (0x02).
                    d0 = irq_status[sel];
                    d1 = irq_out;
                end
                default: begin d0 = 1'b0; d1 = 1'b0; end   // G_OFF and reserved
            endcase
            probe_pair = {d1, d0};
        end
    endfunction

    wire       en0   = dbg_ctrl0[7];
    wire [1:0] pair0 = probe_pair(dbg_ctrl0[6:4], dbg_ctrl0[3:2], dbg_ctrl0[1:0]);
    wire       en1   = dbg_ctrl1[7];
    wire [1:0] pair1 = probe_pair(dbg_ctrl1[6:4], dbg_ctrl1[3:2], dbg_ctrl1[1:0]);

    assign dbg0     = en0 ? pair0[0] : 1'b0;
    assign dbg1_val = en1 ? pair1[1] : 1'b0;
    assign dbg1_en  = en1;
endmodule

// Kept in this compilation unit so existing standalone top-level test targets
// (which enumerate Trouper RTL files explicitly) pick up the helper without a
// source-list change. The functional ownership remains the control plane.
module array_acq_sync (
    input  wire clk,
    input  wire rst_n,
    input  wire array_sync_en,
    input  wire local_lock_pulse,
    input  wire local_lock_level,
    input  wire packet_active,
    input  wire packet_done,
    input  wire rx_hold,
    input  wire acq_n_async,
    output reg  drive_oe,
    output reg  peer_lock_pulse
);
    reg acq_meta, acq_sync, acq_sync_d;
    reg line_idle_seen;

    wire armed = array_sync_en && !rx_hold && !packet_active && !local_lock_level;
    wire peer_fall = acq_sync_d && !acq_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acq_meta        <= 1'b1;
            acq_sync        <= 1'b1;
            acq_sync_d      <= 1'b1;
            line_idle_seen  <= 1'b0;
            drive_oe        <= 1'b0;
            peer_lock_pulse <= 1'b0;
        end else begin
            acq_meta        <= acq_n_async;
            acq_sync        <= acq_meta;
            acq_sync_d      <= acq_sync;
            peer_lock_pulse <= 1'b0;

            // Observe released-high before accepting a fresh low assertion,
            // which rejects a stale request present when this ASIC is reset.
            if (packet_done || rx_hold)
                line_idle_seen <= 1'b0;
            else if (acq_sync)
                line_idle_seen <= 1'b1;

            // The pad data is tied low. OE therefore implements open drain.
            // A diagnostic SC_FORCE_LOCK cannot reach local_lock_pulse.
            if (local_lock_pulse && array_sync_en && !rx_hold && !packet_active)
                drive_oe <= 1'b1;
            if (packet_done || rx_hold || !array_sync_en)
                drive_oe <= 1'b0;

            // A natural local lock wins over a simultaneous peer transition.
            if (peer_fall && line_idle_seen && armed && !local_lock_pulse)
                peer_lock_pulse <= 1'b1;
        end
    end
endmodule

`default_nettype wire

`endif
