// tb_trouper_padring.v -- cocotb wrapper that drives trouper_top THROUGH the
// real A40 shared padring (A40_ACV_padring.v) and the foundry gf180mcu_fd_io
// cell models, at the physical pad nets.
//
// Contrast with tb_trouper_cocotb.v: there the 132 pad-control ports are wired
// straight through and only the 4 PSRAM SIO lanes can optionally see a bi_t
// cell.  Here every Trouper slot goes through its real cell:
//   in_c   W13..W21  IQ_DATA_{I,Q}_0..3, IQ_CLK
//   in_s   W22,N09..N11  RESETB, HOST_CS, SPI_SCK, SPI_MOSI
//   bi_t   N01,N02,N04..N08,N12,N13,N15,N16
//   bi_24t N03  PSRAM_SCK
//   dvdd/dvss N14 / W12
//
// icarus only -- the gf180 IO primitives do not elaborate under Verilator.
//
// The top-level port names match tb_trouper_cocotb.v's driving side exactly
// (IQ_CLK, RESETB, IQ_DATA_I/Q[3:0], HOST_CS, SPI_SCK, SPI_MOSI, SPI_MISO,
// IRQ_OUT, REMOD_A_I, REMOD_A_Q) and the DUT / PSRAM instances keep the names
// u_dut / u_psram, so cocotb/tests/test_trouper_top.py helpers (spi_*,
// release_rx_hold, sdm_driver, run_scenario) work unmodified.
`default_nettype none

module tb_trouper_padring #(
    parameter integer PSRAM_ADDR_BITS = 16
) (
    input  wire        IQ_CLK,
    input  wire        RESETB,
    input  wire [3:0]  IQ_DATA_I,
    input  wire [3:0]  IQ_DATA_Q,
    output wire        REMOD_A_I,
    output wire        REMOD_A_Q,
    input  wire        HOST_CS,
    input  wire        SPI_SCK,
    input  wire        SPI_MOSI,
    output wire        SPI_MISO,
    output wire        IRQ_OUT
);
    // ---------------------------------------------------------------- pad nets
    tri  PAD_W13, PAD_W14, PAD_W15, PAD_W16, PAD_W17, PAD_W18, PAD_W19, PAD_W20;
    tri  PAD_W21, PAD_W22;
    tri  PAD_N01, PAD_N02, PAD_N03, PAD_N04, PAD_N05, PAD_N06, PAD_N07, PAD_N08;
    tri  PAD_N09, PAD_N10, PAD_N11, PAD_N12, PAD_N13, PAD_N15, PAD_N16;
    tri  PAD_N14, PAD_W12;                       // supply slots

    // Supply pads: N14 = VDD rail, W12 = VSS rail (functional sim: hard-tie).
    assign PAD_N14 = 1'b1;
    assign PAD_W12 = 1'b0;

    // Input pads are driven only by this bench (the in_c / in_s cells never
    // drive PAD), so a continuous assign is safe.
    assign PAD_W13 = IQ_DATA_I[0];
    assign PAD_W15 = IQ_DATA_I[1];
    assign PAD_W17 = IQ_DATA_I[2];
    assign PAD_W19 = IQ_DATA_I[3];
    assign PAD_W14 = IQ_DATA_Q[0];
    assign PAD_W16 = IQ_DATA_Q[1];
    assign PAD_W18 = IQ_DATA_Q[2];
    assign PAD_W20 = IQ_DATA_Q[3];
    assign PAD_W21 = IQ_CLK;
    assign PAD_W22 = RESETB;
    assign PAD_N09 = HOST_CS;
    assign PAD_N10 = SPI_SCK;
    assign PAD_N11 = SPI_MOSI;

    // ARRAY_ACQ_N (N15): mandatory external pull-up, emulated open drain.
    pullup (PAD_N15);

    // Functional outputs picked off the pad nets.
    assign REMOD_A_I = PAD_N01;
    assign REMOD_A_Q = PAD_N02;
    assign SPI_MISO  = PAD_N12;
    assign IRQ_OUT   = PAD_N13;

    // ---------------------------------------------- trouper_top <-> padring wires
    // Names == trouper_top port names.  Pad-control outputs of the core:
    wire IQ_CLK_PU, IQ_CLK_PD, RESETB_PU, RESETB_PD;
    wire IQ_DATA_I_0_PU, IQ_DATA_I_0_PD, IQ_DATA_I_1_PU, IQ_DATA_I_1_PD;
    wire IQ_DATA_I_2_PU, IQ_DATA_I_2_PD, IQ_DATA_I_3_PU, IQ_DATA_I_3_PD;
    wire IQ_DATA_Q_0_PU, IQ_DATA_Q_0_PD, IQ_DATA_Q_1_PU, IQ_DATA_Q_1_PD;
    wire IQ_DATA_Q_2_PU, IQ_DATA_Q_2_PD, IQ_DATA_Q_3_PU, IQ_DATA_Q_3_PD;
    wire HOST_CS_PU, HOST_CS_PD, SPI_SCK_PU, SPI_SCK_PD, SPI_MOSI_PU, SPI_MOSI_PD;

    wire REMOD_A_I_OUT, REMOD_A_I_IN;
    wire REMOD_A_I_OE, REMOD_A_I_IE, REMOD_A_I_CS, REMOD_A_I_SL, REMOD_A_I_PU, REMOD_A_I_PD, REMOD_A_I_PDRV0, REMOD_A_I_PDRV1;
    wire REMOD_A_Q_OUT, REMOD_A_Q_IN;
    wire REMOD_A_Q_OE, REMOD_A_Q_IE, REMOD_A_Q_CS, REMOD_A_Q_SL, REMOD_A_Q_PU, REMOD_A_Q_PD, REMOD_A_Q_PDRV0, REMOD_A_Q_PDRV1;

    wire PSRAM_SCK_OUT, PSRAM_SCK_IN;
    wire PSRAM_SCK_OE, PSRAM_SCK_IE, PSRAM_SCK_CS, PSRAM_SCK_SL, PSRAM_SCK_PU, PSRAM_SCK_PD;
    wire PSRAM_CE_N_OUT, PSRAM_CE_N_IN;
    wire PSRAM_CE_N_OE, PSRAM_CE_N_IE, PSRAM_CE_N_CS, PSRAM_CE_N_SL, PSRAM_CE_N_PU, PSRAM_CE_N_PD, PSRAM_CE_N_PDRV0, PSRAM_CE_N_PDRV1;

    wire [3:0] PSRAM_SIO_OUT, PSRAM_SIO_IN, PSRAM_SIO_OE, PSRAM_SIO_IE;
    wire [3:0] PSRAM_SIO_CS, PSRAM_SIO_SL, PSRAM_SIO_PU, PSRAM_SIO_PD, PSRAM_SIO_PDRV0, PSRAM_SIO_PDRV1;

    wire SPI_MISO_OUT, SPI_MISO_IN;
    wire SPI_MISO_OE, SPI_MISO_IE, SPI_MISO_CS, SPI_MISO_SL, SPI_MISO_PU, SPI_MISO_PD, SPI_MISO_PDRV0, SPI_MISO_PDRV1;
    wire IRQ_OUT_OUT, IRQ_OUT_IN;
    wire IRQ_OUT_OE, IRQ_OUT_IE, IRQ_OUT_CS, IRQ_OUT_SL, IRQ_OUT_PU, IRQ_OUT_PD, IRQ_OUT_PDRV0, IRQ_OUT_PDRV1;

    wire ARRAY_ACQ_N_OUT, ARRAY_ACQ_N_IN;
    wire ARRAY_ACQ_N_OE, ARRAY_ACQ_N_IE, ARRAY_ACQ_N_CS, ARRAY_ACQ_N_SL, ARRAY_ACQ_N_PU, ARRAY_ACQ_N_PD, ARRAY_ACQ_N_PDRV0, ARRAY_ACQ_N_PDRV1;
    wire DBG0_OUT, DBG0_IN;
    wire DBG0_OE, DBG0_IE, DBG0_CS, DBG0_SL, DBG0_PU, DBG0_PD, DBG0_PDRV0, DBG0_PDRV1;

    // Receiver returns from the input pads into the core datapath.
    wire IQ_CLK_rx, RESETB_rx, HOST_CS_rx, SPI_SCK_rx, SPI_MOSI_rx;
    wire IQ_DATA_I_0_rx, IQ_DATA_I_1_rx, IQ_DATA_I_2_rx, IQ_DATA_I_3_rx;
    wire IQ_DATA_Q_0_rx, IQ_DATA_Q_1_rx, IQ_DATA_Q_2_rx, IQ_DATA_Q_3_rx;

    // ------------------------------------------------------------------ the DUT
    trouper_top u_dut (
        .IQ_CLK        (IQ_CLK_rx),
        .RESETB        (RESETB_rx),
        .IQ_DATA_I_0   (IQ_DATA_I_0_rx),
        .IQ_DATA_I_1   (IQ_DATA_I_1_rx),
        .IQ_DATA_I_2   (IQ_DATA_I_2_rx),
        .IQ_DATA_I_3   (IQ_DATA_I_3_rx),
        .IQ_DATA_Q_0   (IQ_DATA_Q_0_rx),
        .IQ_DATA_Q_1   (IQ_DATA_Q_1_rx),
        .IQ_DATA_Q_2   (IQ_DATA_Q_2_rx),
        .IQ_DATA_Q_3   (IQ_DATA_Q_3_rx),
        .REMOD_A_I_OUT (REMOD_A_I_OUT),
        .REMOD_A_Q_OUT (REMOD_A_Q_OUT),
        .PSRAM_SCK_OUT (PSRAM_SCK_OUT),
        .PSRAM_CE_N_OUT(PSRAM_CE_N_OUT),
        .PSRAM_SIO_0_OUT(PSRAM_SIO_OUT[0]),
        .PSRAM_SIO_1_OUT(PSRAM_SIO_OUT[1]),
        .PSRAM_SIO_2_OUT(PSRAM_SIO_OUT[2]),
        .PSRAM_SIO_3_OUT(PSRAM_SIO_OUT[3]),
        .PSRAM_SIO_0_IN (PSRAM_SIO_IN[0]),
        .PSRAM_SIO_1_IN (PSRAM_SIO_IN[1]),
        .PSRAM_SIO_2_IN (PSRAM_SIO_IN[2]),
        .PSRAM_SIO_3_IN (PSRAM_SIO_IN[3]),
        .PSRAM_SIO_0_OE (PSRAM_SIO_OE[0]),
        .PSRAM_SIO_1_OE (PSRAM_SIO_OE[1]),
        .PSRAM_SIO_2_OE (PSRAM_SIO_OE[2]),
        .PSRAM_SIO_3_OE (PSRAM_SIO_OE[3]),
        .PSRAM_SIO_0_IE (PSRAM_SIO_IE[0]),
        .PSRAM_SIO_1_IE (PSRAM_SIO_IE[1]),
        .PSRAM_SIO_2_IE (PSRAM_SIO_IE[2]),
        .PSRAM_SIO_3_IE (PSRAM_SIO_IE[3]),
        .HOST_CS       (HOST_CS_rx),
        .SPI_SCK       (SPI_SCK_rx),
        .SPI_MOSI      (SPI_MOSI_rx),
        .SPI_MISO_OUT  (SPI_MISO_OUT),
        .IRQ_OUT_OUT   (IRQ_OUT_OUT),
        .IQ_CLK_PU     (IQ_CLK_PU),      .IQ_CLK_PD     (IQ_CLK_PD),
        .RESETB_PU     (RESETB_PU),      .RESETB_PD     (RESETB_PD),
        .IQ_DATA_I_0_PU(IQ_DATA_I_0_PU), .IQ_DATA_I_0_PD(IQ_DATA_I_0_PD),
        .IQ_DATA_I_1_PU(IQ_DATA_I_1_PU), .IQ_DATA_I_1_PD(IQ_DATA_I_1_PD),
        .IQ_DATA_I_2_PU(IQ_DATA_I_2_PU), .IQ_DATA_I_2_PD(IQ_DATA_I_2_PD),
        .IQ_DATA_I_3_PU(IQ_DATA_I_3_PU), .IQ_DATA_I_3_PD(IQ_DATA_I_3_PD),
        .IQ_DATA_Q_0_PU(IQ_DATA_Q_0_PU), .IQ_DATA_Q_0_PD(IQ_DATA_Q_0_PD),
        .IQ_DATA_Q_1_PU(IQ_DATA_Q_1_PU), .IQ_DATA_Q_1_PD(IQ_DATA_Q_1_PD),
        .IQ_DATA_Q_2_PU(IQ_DATA_Q_2_PU), .IQ_DATA_Q_2_PD(IQ_DATA_Q_2_PD),
        .IQ_DATA_Q_3_PU(IQ_DATA_Q_3_PU), .IQ_DATA_Q_3_PD(IQ_DATA_Q_3_PD),
        .HOST_CS_PU    (HOST_CS_PU),     .HOST_CS_PD    (HOST_CS_PD),
        .SPI_SCK_PU    (SPI_SCK_PU),     .SPI_SCK_PD    (SPI_SCK_PD),
        .SPI_MOSI_PU   (SPI_MOSI_PU),    .SPI_MOSI_PD   (SPI_MOSI_PD),
        .PSRAM_SIO_0_CS(PSRAM_SIO_CS[0]), .PSRAM_SIO_0_SL(PSRAM_SIO_SL[0]),
        .PSRAM_SIO_0_PU(PSRAM_SIO_PU[0]), .PSRAM_SIO_0_PD(PSRAM_SIO_PD[0]),
        .PSRAM_SIO_0_PDRV0(PSRAM_SIO_PDRV0[0]), .PSRAM_SIO_0_PDRV1(PSRAM_SIO_PDRV1[0]),
        .PSRAM_SIO_1_CS(PSRAM_SIO_CS[1]), .PSRAM_SIO_1_SL(PSRAM_SIO_SL[1]),
        .PSRAM_SIO_1_PU(PSRAM_SIO_PU[1]), .PSRAM_SIO_1_PD(PSRAM_SIO_PD[1]),
        .PSRAM_SIO_1_PDRV0(PSRAM_SIO_PDRV0[1]), .PSRAM_SIO_1_PDRV1(PSRAM_SIO_PDRV1[1]),
        .PSRAM_SIO_2_CS(PSRAM_SIO_CS[2]), .PSRAM_SIO_2_SL(PSRAM_SIO_SL[2]),
        .PSRAM_SIO_2_PU(PSRAM_SIO_PU[2]), .PSRAM_SIO_2_PD(PSRAM_SIO_PD[2]),
        .PSRAM_SIO_2_PDRV0(PSRAM_SIO_PDRV0[2]), .PSRAM_SIO_2_PDRV1(PSRAM_SIO_PDRV1[2]),
        .PSRAM_SIO_3_CS(PSRAM_SIO_CS[3]), .PSRAM_SIO_3_SL(PSRAM_SIO_SL[3]),
        .PSRAM_SIO_3_PU(PSRAM_SIO_PU[3]), .PSRAM_SIO_3_PD(PSRAM_SIO_PD[3]),
        .PSRAM_SIO_3_PDRV0(PSRAM_SIO_PDRV0[3]), .PSRAM_SIO_3_PDRV1(PSRAM_SIO_PDRV1[3]),
        .PSRAM_CE_N_IN (PSRAM_CE_N_IN),
        .PSRAM_CE_N_OE (PSRAM_CE_N_OE), .PSRAM_CE_N_IE (PSRAM_CE_N_IE),
        .PSRAM_CE_N_CS (PSRAM_CE_N_CS), .PSRAM_CE_N_SL (PSRAM_CE_N_SL),
        .PSRAM_CE_N_PU (PSRAM_CE_N_PU), .PSRAM_CE_N_PD (PSRAM_CE_N_PD),
        .PSRAM_CE_N_PDRV0(PSRAM_CE_N_PDRV0), .PSRAM_CE_N_PDRV1(PSRAM_CE_N_PDRV1),
        .REMOD_A_I_IN  (REMOD_A_I_IN),
        .REMOD_A_I_OE  (REMOD_A_I_OE), .REMOD_A_I_IE  (REMOD_A_I_IE),
        .REMOD_A_I_CS  (REMOD_A_I_CS), .REMOD_A_I_SL  (REMOD_A_I_SL),
        .REMOD_A_I_PU  (REMOD_A_I_PU), .REMOD_A_I_PD  (REMOD_A_I_PD),
        .REMOD_A_I_PDRV0(REMOD_A_I_PDRV0), .REMOD_A_I_PDRV1(REMOD_A_I_PDRV1),
        .REMOD_A_Q_IN  (REMOD_A_Q_IN),
        .REMOD_A_Q_OE  (REMOD_A_Q_OE), .REMOD_A_Q_IE  (REMOD_A_Q_IE),
        .REMOD_A_Q_CS  (REMOD_A_Q_CS), .REMOD_A_Q_SL  (REMOD_A_Q_SL),
        .REMOD_A_Q_PU  (REMOD_A_Q_PU), .REMOD_A_Q_PD  (REMOD_A_Q_PD),
        .REMOD_A_Q_PDRV0(REMOD_A_Q_PDRV0), .REMOD_A_Q_PDRV1(REMOD_A_Q_PDRV1),
        .SPI_MISO_IN   (SPI_MISO_IN),
        .SPI_MISO_OE   (SPI_MISO_OE), .SPI_MISO_IE   (SPI_MISO_IE),
        .SPI_MISO_CS   (SPI_MISO_CS), .SPI_MISO_SL   (SPI_MISO_SL),
        .SPI_MISO_PU   (SPI_MISO_PU), .SPI_MISO_PD   (SPI_MISO_PD),
        .SPI_MISO_PDRV0(SPI_MISO_PDRV0), .SPI_MISO_PDRV1(SPI_MISO_PDRV1),
        .IRQ_OUT_IN    (IRQ_OUT_IN),
        .IRQ_OUT_OE    (IRQ_OUT_OE), .IRQ_OUT_IE    (IRQ_OUT_IE),
        .IRQ_OUT_CS    (IRQ_OUT_CS), .IRQ_OUT_SL    (IRQ_OUT_SL),
        .IRQ_OUT_PU    (IRQ_OUT_PU), .IRQ_OUT_PD    (IRQ_OUT_PD),
        .IRQ_OUT_PDRV0 (IRQ_OUT_PDRV0), .IRQ_OUT_PDRV1 (IRQ_OUT_PDRV1),
        .PSRAM_SCK_IN  (PSRAM_SCK_IN),
        .PSRAM_SCK_OE  (PSRAM_SCK_OE), .PSRAM_SCK_IE  (PSRAM_SCK_IE),
        .PSRAM_SCK_CS  (PSRAM_SCK_CS), .PSRAM_SCK_SL  (PSRAM_SCK_SL),
        .PSRAM_SCK_PU  (PSRAM_SCK_PU), .PSRAM_SCK_PD  (PSRAM_SCK_PD),
        .ARRAY_ACQ_N_IN(ARRAY_ACQ_N_IN),
        .ARRAY_ACQ_N_OUT(ARRAY_ACQ_N_OUT), .ARRAY_ACQ_N_OE(ARRAY_ACQ_N_OE),
        .ARRAY_ACQ_N_IE(ARRAY_ACQ_N_IE), .ARRAY_ACQ_N_CS(ARRAY_ACQ_N_CS),
        .ARRAY_ACQ_N_SL(ARRAY_ACQ_N_SL), .ARRAY_ACQ_N_PU(ARRAY_ACQ_N_PU),
        .ARRAY_ACQ_N_PD(ARRAY_ACQ_N_PD), .ARRAY_ACQ_N_PDRV0(ARRAY_ACQ_N_PDRV0),
        .ARRAY_ACQ_N_PDRV1(ARRAY_ACQ_N_PDRV1),
        .DBG0_IN       (DBG0_IN),
        .DBG0_OUT      (DBG0_OUT),
        .DBG0_OE       (DBG0_OE), .DBG0_IE       (DBG0_IE),
        .DBG0_CS       (DBG0_CS), .DBG0_SL       (DBG0_SL),
        .DBG0_PU       (DBG0_PU), .DBG0_PD       (DBG0_PD),
        .DBG0_PDRV0    (DBG0_PDRV0), .DBG0_PDRV1    (DBG0_PDRV1)
    );

    // -------------------------------------------------------------- the padring
    // Slot <-> signal from A40_ACV_pad_map.yaml.  Only Trouper's active slots
    // are connected; the other edges' bare inout ports float.
    A40_ACV_padring u_padring (
        // ---- input pads (in_c / in_s): PU, PD in ; Y out ; PAD inout ----
        .W13(PAD_W13), .W13_PU(IQ_DATA_I_0_PU), .W13_PD(IQ_DATA_I_0_PD), .W13_Y(IQ_DATA_I_0_rx),
        .W14(PAD_W14), .W14_PU(IQ_DATA_Q_0_PU), .W14_PD(IQ_DATA_Q_0_PD), .W14_Y(IQ_DATA_Q_0_rx),
        .W15(PAD_W15), .W15_PU(IQ_DATA_I_1_PU), .W15_PD(IQ_DATA_I_1_PD), .W15_Y(IQ_DATA_I_1_rx),
        .W16(PAD_W16), .W16_PU(IQ_DATA_Q_1_PU), .W16_PD(IQ_DATA_Q_1_PD), .W16_Y(IQ_DATA_Q_1_rx),
        .W17(PAD_W17), .W17_PU(IQ_DATA_I_2_PU), .W17_PD(IQ_DATA_I_2_PD), .W17_Y(IQ_DATA_I_2_rx),
        .W18(PAD_W18), .W18_PU(IQ_DATA_Q_2_PU), .W18_PD(IQ_DATA_Q_2_PD), .W18_Y(IQ_DATA_Q_2_rx),
        .W19(PAD_W19), .W19_PU(IQ_DATA_I_3_PU), .W19_PD(IQ_DATA_I_3_PD), .W19_Y(IQ_DATA_I_3_rx),
        .W20(PAD_W20), .W20_PU(IQ_DATA_Q_3_PU), .W20_PD(IQ_DATA_Q_3_PD), .W20_Y(IQ_DATA_Q_3_rx),
        .W21(PAD_W21), .W21_PU(IQ_CLK_PU),      .W21_PD(IQ_CLK_PD),      .W21_Y(IQ_CLK_rx),
        .W22(PAD_W22), .W22_PU(RESETB_PU),      .W22_PD(RESETB_PD),      .W22_Y(RESETB_rx),
        .N09(PAD_N09), .N09_PU(HOST_CS_PU),     .N09_PD(HOST_CS_PD),     .N09_Y(HOST_CS_rx),
        .N10(PAD_N10), .N10_PU(SPI_SCK_PU),     .N10_PD(SPI_SCK_PD),     .N10_Y(SPI_SCK_rx),
        .N11(PAD_N11), .N11_PU(SPI_MOSI_PU),    .N11_PD(SPI_MOSI_PD),    .N11_Y(SPI_MOSI_rx),

        // ---- bi_t pads: CS SL IE OE PU PD A PDRV0 PDRV1 in ; Y out ; PAD inout ----
        .N01(PAD_N01), .N01_A(REMOD_A_I_OUT), .N01_OE(REMOD_A_I_OE), .N01_IE(REMOD_A_I_IE),
        .N01_CS(REMOD_A_I_CS), .N01_SL(REMOD_A_I_SL), .N01_PU(REMOD_A_I_PU), .N01_PD(REMOD_A_I_PD),
        .N01_PDRV0(REMOD_A_I_PDRV0), .N01_PDRV1(REMOD_A_I_PDRV1), .N01_Y(REMOD_A_I_IN),
        .N02(PAD_N02), .N02_A(REMOD_A_Q_OUT), .N02_OE(REMOD_A_Q_OE), .N02_IE(REMOD_A_Q_IE),
        .N02_CS(REMOD_A_Q_CS), .N02_SL(REMOD_A_Q_SL), .N02_PU(REMOD_A_Q_PU), .N02_PD(REMOD_A_Q_PD),
        .N02_PDRV0(REMOD_A_Q_PDRV0), .N02_PDRV1(REMOD_A_Q_PDRV1), .N02_Y(REMOD_A_Q_IN),
        .N04(PAD_N04), .N04_A(PSRAM_CE_N_OUT), .N04_OE(PSRAM_CE_N_OE), .N04_IE(PSRAM_CE_N_IE),
        .N04_CS(PSRAM_CE_N_CS), .N04_SL(PSRAM_CE_N_SL), .N04_PU(PSRAM_CE_N_PU), .N04_PD(PSRAM_CE_N_PD),
        .N04_PDRV0(PSRAM_CE_N_PDRV0), .N04_PDRV1(PSRAM_CE_N_PDRV1), .N04_Y(PSRAM_CE_N_IN),
        .N05(PAD_N05), .N05_A(PSRAM_SIO_OUT[0]), .N05_OE(PSRAM_SIO_OE[0]), .N05_IE(PSRAM_SIO_IE[0]),
        .N05_CS(PSRAM_SIO_CS[0]), .N05_SL(PSRAM_SIO_SL[0]), .N05_PU(PSRAM_SIO_PU[0]), .N05_PD(PSRAM_SIO_PD[0]),
        .N05_PDRV0(PSRAM_SIO_PDRV0[0]), .N05_PDRV1(PSRAM_SIO_PDRV1[0]), .N05_Y(PSRAM_SIO_IN[0]),
        .N06(PAD_N06), .N06_A(PSRAM_SIO_OUT[1]), .N06_OE(PSRAM_SIO_OE[1]), .N06_IE(PSRAM_SIO_IE[1]),
        .N06_CS(PSRAM_SIO_CS[1]), .N06_SL(PSRAM_SIO_SL[1]), .N06_PU(PSRAM_SIO_PU[1]), .N06_PD(PSRAM_SIO_PD[1]),
        .N06_PDRV0(PSRAM_SIO_PDRV0[1]), .N06_PDRV1(PSRAM_SIO_PDRV1[1]), .N06_Y(PSRAM_SIO_IN[1]),
        .N07(PAD_N07), .N07_A(PSRAM_SIO_OUT[2]), .N07_OE(PSRAM_SIO_OE[2]), .N07_IE(PSRAM_SIO_IE[2]),
        .N07_CS(PSRAM_SIO_CS[2]), .N07_SL(PSRAM_SIO_SL[2]), .N07_PU(PSRAM_SIO_PU[2]), .N07_PD(PSRAM_SIO_PD[2]),
        .N07_PDRV0(PSRAM_SIO_PDRV0[2]), .N07_PDRV1(PSRAM_SIO_PDRV1[2]), .N07_Y(PSRAM_SIO_IN[2]),
        .N08(PAD_N08), .N08_A(PSRAM_SIO_OUT[3]), .N08_OE(PSRAM_SIO_OE[3]), .N08_IE(PSRAM_SIO_IE[3]),
        .N08_CS(PSRAM_SIO_CS[3]), .N08_SL(PSRAM_SIO_SL[3]), .N08_PU(PSRAM_SIO_PU[3]), .N08_PD(PSRAM_SIO_PD[3]),
        .N08_PDRV0(PSRAM_SIO_PDRV0[3]), .N08_PDRV1(PSRAM_SIO_PDRV1[3]), .N08_Y(PSRAM_SIO_IN[3]),
        .N12(PAD_N12), .N12_A(SPI_MISO_OUT), .N12_OE(SPI_MISO_OE), .N12_IE(SPI_MISO_IE),
        .N12_CS(SPI_MISO_CS), .N12_SL(SPI_MISO_SL), .N12_PU(SPI_MISO_PU), .N12_PD(SPI_MISO_PD),
        .N12_PDRV0(SPI_MISO_PDRV0), .N12_PDRV1(SPI_MISO_PDRV1), .N12_Y(SPI_MISO_IN),
        .N13(PAD_N13), .N13_A(IRQ_OUT_OUT), .N13_OE(IRQ_OUT_OE), .N13_IE(IRQ_OUT_IE),
        .N13_CS(IRQ_OUT_CS), .N13_SL(IRQ_OUT_SL), .N13_PU(IRQ_OUT_PU), .N13_PD(IRQ_OUT_PD),
        .N13_PDRV0(IRQ_OUT_PDRV0), .N13_PDRV1(IRQ_OUT_PDRV1), .N13_Y(IRQ_OUT_IN),
        .N15(PAD_N15), .N15_A(ARRAY_ACQ_N_OUT), .N15_OE(ARRAY_ACQ_N_OE), .N15_IE(ARRAY_ACQ_N_IE),
        .N15_CS(ARRAY_ACQ_N_CS), .N15_SL(ARRAY_ACQ_N_SL), .N15_PU(ARRAY_ACQ_N_PU), .N15_PD(ARRAY_ACQ_N_PD),
        .N15_PDRV0(ARRAY_ACQ_N_PDRV0), .N15_PDRV1(ARRAY_ACQ_N_PDRV1), .N15_Y(ARRAY_ACQ_N_IN),
        .N16(PAD_N16), .N16_A(DBG0_OUT), .N16_OE(DBG0_OE), .N16_IE(DBG0_IE),
        .N16_CS(DBG0_CS), .N16_SL(DBG0_SL), .N16_PU(DBG0_PU), .N16_PD(DBG0_PD),
        .N16_PDRV0(DBG0_PDRV0), .N16_PDRV1(DBG0_PDRV1), .N16_Y(DBG0_IN),

        // ---- bi_24t pad (PSRAM_SCK): as bi_t but no PDRV ----
        .N03(PAD_N03), .N03_A(PSRAM_SCK_OUT), .N03_OE(PSRAM_SCK_OE), .N03_IE(PSRAM_SCK_IE),
        .N03_CS(PSRAM_SCK_CS), .N03_SL(PSRAM_SCK_SL), .N03_PU(PSRAM_SCK_PU), .N03_PD(PSRAM_SCK_PD),
        .N03_Y(PSRAM_SCK_IN),

        // ---- supply slots ----
        .N14(PAD_N14),
        .W12(PAD_W12)
    );

    // ------------------------------------------------------------ PSRAM device
    // Behaves as the external APS6404L on the physical bus: drives PAD_N05..N08
    // while the chip is selected and the controller has released all four lanes
    // (mirrors the tb_trouper_cocotb.v GF180_IO_MODEL wrapper).
    wire [3:0] psram_sio_drive;
    assign {PAD_N08, PAD_N07, PAD_N06, PAD_N05} =
        (!PSRAM_CE_N_OUT && !PSRAM_SIO_OE) ? psram_sio_drive : 4'bz;

    psram_model #(.ADDR_BITS(PSRAM_ADDR_BITS), .RD_LAUNCH_SKIP(5)) u_psram (
        .clk_32m (IQ_CLK),
        .rst_n   (RESETB),
        .ce_n    (PSRAM_CE_N_OUT),
        .sio_out (PSRAM_SIO_OUT),
        .sio_oe  (PSRAM_SIO_OE),
        .sio_in  (psram_sio_drive),
        .sck     (PSRAM_SCK_OUT),
        .sck_en  (u_dut.psram_sck_en_q)
    );

    // gf180mcu_fd_io__bi_t / bi_24t leave IE=OE=1 uncharacterized -- it must
    // never occur on any output/bidir slot.  ARRAY_ACQ_N is exempt: its
    // documented open-drain emulation holds IE=1 and pulses OE (Pinout.md,
    // "A40 pad-control tie-offs"; Open Risk #53).
    always @(posedge IQ_CLK) begin
        #1;
        if (|(PSRAM_SIO_IE & PSRAM_SIO_OE))
            $fatal(1, "padring: PSRAM SIO slot has IE=OE=1");
        if ((PSRAM_CE_N_IE & PSRAM_CE_N_OE) | (PSRAM_SCK_IE & PSRAM_SCK_OE) |
            (REMOD_A_I_IE & REMOD_A_I_OE) | (REMOD_A_Q_IE & REMOD_A_Q_OE)  |
            (SPI_MISO_IE & SPI_MISO_OE)   | (IRQ_OUT_IE & IRQ_OUT_OE)      |
            (DBG0_IE & DBG0_OE))
            $fatal(1, "padring: an output-only slot has IE=OE=1");
    end

endmodule
`default_nettype wire
