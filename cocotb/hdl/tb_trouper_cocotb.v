// tb_trouper_cocotb.v — thin Verilog wrapper for cocotb integration tests.
// Exposes only the ports cocotb needs to drive; wires psram_model internally
// so Python code doesn't have to implement the PSRAM QPI protocol.
`default_nettype none

module tb_trouper_cocotb #(
    // The default keeps short regressions compact.  Long measured captures
    // override this to model enough non-wrapping PSRAM address space.
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
    output wire        IRQ_OUT,
    output wire        IRQ_GROUPER,
    // ---- A40 pad-control tie-offs, exposed for cocotb/pad_tieoffs.
    //      Passed straight through from trouper_top so Verilator cannot
    //      constant-fold them out of the VPI hierarchy.
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
    output wire        PSRAM_SIO_0_CS,
    output wire        PSRAM_SIO_0_SL,
    output wire        PSRAM_SIO_0_PU,
    output wire        PSRAM_SIO_0_PD,
    output wire        PSRAM_SIO_0_PDRV0,
    output wire        PSRAM_SIO_0_PDRV1,
    output wire        PSRAM_SIO_1_CS,
    output wire        PSRAM_SIO_1_SL,
    output wire        PSRAM_SIO_1_PU,
    output wire        PSRAM_SIO_1_PD,
    output wire        PSRAM_SIO_1_PDRV0,
    output wire        PSRAM_SIO_1_PDRV1,
    output wire        PSRAM_SIO_2_CS,
    output wire        PSRAM_SIO_2_SL,
    output wire        PSRAM_SIO_2_PU,
    output wire        PSRAM_SIO_2_PD,
    output wire        PSRAM_SIO_2_PDRV0,
    output wire        PSRAM_SIO_2_PDRV1,
    output wire        PSRAM_SIO_3_CS,
    output wire        PSRAM_SIO_3_SL,
    output wire        PSRAM_SIO_3_PU,
    output wire        PSRAM_SIO_3_PD,
    output wire        PSRAM_SIO_3_PDRV0,
    output wire        PSRAM_SIO_3_PDRV1,
    output wire        PSRAM_CE_N_OE,
    output wire        PSRAM_CE_N_IE,
    output wire        PSRAM_CE_N_CS,
    output wire        PSRAM_CE_N_SL,
    output wire        PSRAM_CE_N_PU,
    output wire        PSRAM_CE_N_PD,
    output wire        PSRAM_CE_N_PDRV0,
    output wire        PSRAM_CE_N_PDRV1,
    output wire        REMOD_A_I_OE,
    output wire        REMOD_A_I_IE,
    output wire        REMOD_A_I_CS,
    output wire        REMOD_A_I_SL,
    output wire        REMOD_A_I_PU,
    output wire        REMOD_A_I_PD,
    output wire        REMOD_A_I_PDRV0,
    output wire        REMOD_A_I_PDRV1,
    output wire        REMOD_A_Q_OE,
    output wire        REMOD_A_Q_IE,
    output wire        REMOD_A_Q_CS,
    output wire        REMOD_A_Q_SL,
    output wire        REMOD_A_Q_PU,
    output wire        REMOD_A_Q_PD,
    output wire        REMOD_A_Q_PDRV0,
    output wire        REMOD_A_Q_PDRV1,
    output wire        SPI_MISO_OE,
    output wire        SPI_MISO_IE,
    output wire        SPI_MISO_CS,
    output wire        SPI_MISO_SL,
    output wire        SPI_MISO_PU,
    output wire        SPI_MISO_PD,
    output wire        SPI_MISO_PDRV0,
    output wire        SPI_MISO_PDRV1,
    output wire        IRQ_OUT_OE,
    output wire        IRQ_OUT_IE,
    output wire        IRQ_OUT_CS,
    output wire        IRQ_OUT_SL,
    output wire        IRQ_OUT_PU,
    output wire        IRQ_OUT_PD,
    output wire        IRQ_OUT_PDRV0,
    output wire        IRQ_OUT_PDRV1,
    output wire        PSRAM_SCK_OE,
    output wire        PSRAM_SCK_IE,
    output wire        PSRAM_SCK_CS,
    output wire        PSRAM_SCK_SL,
    output wire        PSRAM_SCK_PU,
    output wire        PSRAM_SCK_PD
);
    wire        psram_ce_n;
    wire [3:0]  psram_sio_out, psram_sio_oe, psram_sio_in, psram_sio_ie;
    wire [3:0]  psram_sio_drive;
`ifdef GF180_IO_MODEL
    tri  [3:0]  psram_sio_pad;
`endif

    // Grouper inter-chip bus (GRP_*). Not brought out as a top-level cocotb
    // port -- almost every suite never touches it and relies on it being
    // tied low, exactly as it was wired below before these signals existed.
    // Declaring them as regs initialized to 0 keeps that tie-low behaviour
    // identical for every other suite while giving the SPI/Grouper
    // arbitration test in test_spi_cdc.py a hierarchical handle
    // (dut.GRP_ADDR/.GRP_WDATA/.GRP_WE/.GRP_RE) it can drive directly, the
    // same way existing tests already reach into dut.u_dut.u_spi.* signals.
    reg  [7:0] GRP_ADDR  = 8'h00;
    reg  [7:0] GRP_WDATA = 8'h00;
    reg        GRP_WE    = 1'b0;
    reg        GRP_RE    = 1'b0;
    wire [7:0] GRP_RDATA;
    wire       GRP_READY;

    trouper_top u_dut (
        .IQ_CLK        (IQ_CLK),
        .RESETB        (RESETB),
                .IQ_DATA_I_0 (IQ_DATA_I[0]),
        .IQ_DATA_I_1 (IQ_DATA_I[1]),
        .IQ_DATA_I_2 (IQ_DATA_I[2]),
        .IQ_DATA_I_3 (IQ_DATA_I[3]),
                .IQ_DATA_Q_0 (IQ_DATA_Q[0]),
        .IQ_DATA_Q_1 (IQ_DATA_Q[1]),
        .IQ_DATA_Q_2 (IQ_DATA_Q[2]),
        .IQ_DATA_Q_3 (IQ_DATA_Q[3]),
        .REMOD_A_I_OUT     (REMOD_A_I),
        .REMOD_A_Q_OUT     (REMOD_A_Q),
        .PSRAM_SCK_OUT     (),
        .PSRAM_CE_N_OUT    (psram_ce_n),
                .PSRAM_SIO_0_OUT (psram_sio_out[0]),
        .PSRAM_SIO_1_OUT (psram_sio_out[1]),
        .PSRAM_SIO_2_OUT (psram_sio_out[2]),
        .PSRAM_SIO_3_OUT (psram_sio_out[3]),
                .PSRAM_SIO_0_IN (psram_sio_in[0]),
        .PSRAM_SIO_1_IN (psram_sio_in[1]),
        .PSRAM_SIO_2_IN (psram_sio_in[2]),
        .PSRAM_SIO_3_IN (psram_sio_in[3]),
        .PSRAM_SIO_0_OE (psram_sio_oe[0]),
        .PSRAM_SIO_1_OE (psram_sio_oe[1]),
        .PSRAM_SIO_2_OE (psram_sio_oe[2]),
        .PSRAM_SIO_3_OE (psram_sio_oe[3]),
        .PSRAM_SIO_0_IE (psram_sio_ie[0]),
        .PSRAM_SIO_1_IE (psram_sio_ie[1]),
        .PSRAM_SIO_2_IE (psram_sio_ie[2]),
        .PSRAM_SIO_3_IE (psram_sio_ie[3]),
        .HOST_CS       (HOST_CS),
        .SPI_SCK       (SPI_SCK),
        .SPI_MOSI      (SPI_MOSI),
        .SPI_MISO_OUT      (SPI_MISO),
                .GRP_ADDR_0 (GRP_ADDR[0]),
        .GRP_ADDR_1 (GRP_ADDR[1]),
        .GRP_ADDR_2 (GRP_ADDR[2]),
        .GRP_ADDR_3 (GRP_ADDR[3]),
        .GRP_ADDR_4 (GRP_ADDR[4]),
        .GRP_ADDR_5 (GRP_ADDR[5]),
        .GRP_ADDR_6 (GRP_ADDR[6]),
        .GRP_ADDR_7 (GRP_ADDR[7]),
                .GRP_WDATA_0 (GRP_WDATA[0]),
        .GRP_WDATA_1 (GRP_WDATA[1]),
        .GRP_WDATA_2 (GRP_WDATA[2]),
        .GRP_WDATA_3 (GRP_WDATA[3]),
        .GRP_WDATA_4 (GRP_WDATA[4]),
        .GRP_WDATA_5 (GRP_WDATA[5]),
        .GRP_WDATA_6 (GRP_WDATA[6]),
        .GRP_WDATA_7 (GRP_WDATA[7]),
        .GRP_WE        (GRP_WE),
        .GRP_RE        (GRP_RE),
                .GRP_RDATA_0 (GRP_RDATA[0]),
        .GRP_RDATA_1 (GRP_RDATA[1]),
        .GRP_RDATA_2 (GRP_RDATA[2]),
        .GRP_RDATA_3 (GRP_RDATA[3]),
        .GRP_RDATA_4 (GRP_RDATA[4]),
        .GRP_RDATA_5 (GRP_RDATA[5]),
        .GRP_RDATA_6 (GRP_RDATA[6]),
        .GRP_RDATA_7 (GRP_RDATA[7]),
        .GRP_READY     (GRP_READY),
        .HADDR         (8'd0),
        .HBURST        (3'd0),
        .HMASTLOCK     (1'b0),
        .HPROT         (4'd0),
        .HSIZE         (3'd0),
        .HTRANS        (2'd0),
        .HWDATA        (8'd0),
        .HWRITE        (1'b0),
        .HRDATA        (),
        .HREADY        (),
        .HRESP         (),
        .IRQ_OUT_OUT       (IRQ_OUT),
        .IRQ_GROUPER   (IRQ_GROUPER),
        .IQ_CLK_PU           (IQ_CLK_PU),
        .IQ_CLK_PD           (IQ_CLK_PD),
        .RESETB_PU           (RESETB_PU),
        .RESETB_PD           (RESETB_PD),
        .IQ_DATA_I_0_PU      (IQ_DATA_I_0_PU),
        .IQ_DATA_I_0_PD      (IQ_DATA_I_0_PD),
        .IQ_DATA_I_1_PU      (IQ_DATA_I_1_PU),
        .IQ_DATA_I_1_PD      (IQ_DATA_I_1_PD),
        .IQ_DATA_I_2_PU      (IQ_DATA_I_2_PU),
        .IQ_DATA_I_2_PD      (IQ_DATA_I_2_PD),
        .IQ_DATA_I_3_PU      (IQ_DATA_I_3_PU),
        .IQ_DATA_I_3_PD      (IQ_DATA_I_3_PD),
        .IQ_DATA_Q_0_PU      (IQ_DATA_Q_0_PU),
        .IQ_DATA_Q_0_PD      (IQ_DATA_Q_0_PD),
        .IQ_DATA_Q_1_PU      (IQ_DATA_Q_1_PU),
        .IQ_DATA_Q_1_PD      (IQ_DATA_Q_1_PD),
        .IQ_DATA_Q_2_PU      (IQ_DATA_Q_2_PU),
        .IQ_DATA_Q_2_PD      (IQ_DATA_Q_2_PD),
        .IQ_DATA_Q_3_PU      (IQ_DATA_Q_3_PU),
        .IQ_DATA_Q_3_PD      (IQ_DATA_Q_3_PD),
        .HOST_CS_PU          (HOST_CS_PU),
        .HOST_CS_PD          (HOST_CS_PD),
        .SPI_SCK_PU          (SPI_SCK_PU),
        .SPI_SCK_PD          (SPI_SCK_PD),
        .SPI_MOSI_PU         (SPI_MOSI_PU),
        .SPI_MOSI_PD         (SPI_MOSI_PD),
        .PSRAM_SIO_0_CS      (PSRAM_SIO_0_CS),
        .PSRAM_SIO_0_SL      (PSRAM_SIO_0_SL),
        .PSRAM_SIO_0_PU      (PSRAM_SIO_0_PU),
        .PSRAM_SIO_0_PD      (PSRAM_SIO_0_PD),
        .PSRAM_SIO_0_PDRV0   (PSRAM_SIO_0_PDRV0),
        .PSRAM_SIO_0_PDRV1   (PSRAM_SIO_0_PDRV1),
        .PSRAM_SIO_1_CS      (PSRAM_SIO_1_CS),
        .PSRAM_SIO_1_SL      (PSRAM_SIO_1_SL),
        .PSRAM_SIO_1_PU      (PSRAM_SIO_1_PU),
        .PSRAM_SIO_1_PD      (PSRAM_SIO_1_PD),
        .PSRAM_SIO_1_PDRV0   (PSRAM_SIO_1_PDRV0),
        .PSRAM_SIO_1_PDRV1   (PSRAM_SIO_1_PDRV1),
        .PSRAM_SIO_2_CS      (PSRAM_SIO_2_CS),
        .PSRAM_SIO_2_SL      (PSRAM_SIO_2_SL),
        .PSRAM_SIO_2_PU      (PSRAM_SIO_2_PU),
        .PSRAM_SIO_2_PD      (PSRAM_SIO_2_PD),
        .PSRAM_SIO_2_PDRV0   (PSRAM_SIO_2_PDRV0),
        .PSRAM_SIO_2_PDRV1   (PSRAM_SIO_2_PDRV1),
        .PSRAM_SIO_3_CS      (PSRAM_SIO_3_CS),
        .PSRAM_SIO_3_SL      (PSRAM_SIO_3_SL),
        .PSRAM_SIO_3_PU      (PSRAM_SIO_3_PU),
        .PSRAM_SIO_3_PD      (PSRAM_SIO_3_PD),
        .PSRAM_SIO_3_PDRV0   (PSRAM_SIO_3_PDRV0),
        .PSRAM_SIO_3_PDRV1   (PSRAM_SIO_3_PDRV1),
        .PSRAM_CE_N_OE       (PSRAM_CE_N_OE),
        .PSRAM_CE_N_IE       (PSRAM_CE_N_IE),
        .PSRAM_CE_N_CS       (PSRAM_CE_N_CS),
        .PSRAM_CE_N_SL       (PSRAM_CE_N_SL),
        .PSRAM_CE_N_PU       (PSRAM_CE_N_PU),
        .PSRAM_CE_N_PD       (PSRAM_CE_N_PD),
        .PSRAM_CE_N_PDRV0    (PSRAM_CE_N_PDRV0),
        .PSRAM_CE_N_PDRV1    (PSRAM_CE_N_PDRV1),
        .REMOD_A_I_OE        (REMOD_A_I_OE),
        .REMOD_A_I_IE        (REMOD_A_I_IE),
        .REMOD_A_I_CS        (REMOD_A_I_CS),
        .REMOD_A_I_SL        (REMOD_A_I_SL),
        .REMOD_A_I_PU        (REMOD_A_I_PU),
        .REMOD_A_I_PD        (REMOD_A_I_PD),
        .REMOD_A_I_PDRV0     (REMOD_A_I_PDRV0),
        .REMOD_A_I_PDRV1     (REMOD_A_I_PDRV1),
        .REMOD_A_Q_OE        (REMOD_A_Q_OE),
        .REMOD_A_Q_IE        (REMOD_A_Q_IE),
        .REMOD_A_Q_CS        (REMOD_A_Q_CS),
        .REMOD_A_Q_SL        (REMOD_A_Q_SL),
        .REMOD_A_Q_PU        (REMOD_A_Q_PU),
        .REMOD_A_Q_PD        (REMOD_A_Q_PD),
        .REMOD_A_Q_PDRV0     (REMOD_A_Q_PDRV0),
        .REMOD_A_Q_PDRV1     (REMOD_A_Q_PDRV1),
        .SPI_MISO_OE         (SPI_MISO_OE),
        .SPI_MISO_IE         (SPI_MISO_IE),
        .SPI_MISO_CS         (SPI_MISO_CS),
        .SPI_MISO_SL         (SPI_MISO_SL),
        .SPI_MISO_PU         (SPI_MISO_PU),
        .SPI_MISO_PD         (SPI_MISO_PD),
        .SPI_MISO_PDRV0      (SPI_MISO_PDRV0),
        .SPI_MISO_PDRV1      (SPI_MISO_PDRV1),
        .IRQ_OUT_OE          (IRQ_OUT_OE),
        .IRQ_OUT_IE          (IRQ_OUT_IE),
        .IRQ_OUT_CS          (IRQ_OUT_CS),
        .IRQ_OUT_SL          (IRQ_OUT_SL),
        .IRQ_OUT_PU          (IRQ_OUT_PU),
        .IRQ_OUT_PD          (IRQ_OUT_PD),
        .IRQ_OUT_PDRV0       (IRQ_OUT_PDRV0),
        .IRQ_OUT_PDRV1       (IRQ_OUT_PDRV1),
        .PSRAM_SCK_OE        (PSRAM_SCK_OE),
        .PSRAM_SCK_IE        (PSRAM_SCK_IE),
        .PSRAM_SCK_CS        (PSRAM_SCK_CS),
        .PSRAM_SCK_SL        (PSRAM_SCK_SL),
        .PSRAM_SCK_PU        (PSRAM_SCK_PU),
        .PSRAM_SCK_PD        (PSRAM_SCK_PD)
    );

`ifdef GF180_IO_MODEL
    // Optional physical-pad wrapper for the PSRAM regression.  The external
    // PSRAM model drives PAD only while selected and after the ASIC releases
    // it; in the default fast wrapper the same signal is connected directly.
    assign psram_sio_pad = (!psram_ce_n && !psram_sio_oe) ? psram_sio_drive : 4'bz;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_psram_sio_pad
            gf180mcu_fd_io__bi_t u_pad (
                .CS(1'b0), .SL(1'b0), .IE(psram_sio_ie[gi]),
                .OE(psram_sio_oe[gi]), .PU(1'b0), .PD(1'b0),
                .A(psram_sio_out[gi]), .PDRV0(1'b1), .PDRV1(1'b1),
                .PAD(psram_sio_pad[gi]), .Y(psram_sio_in[gi]),
                .DVDD(), .DVSS(), .VDD(), .VSS()
            );
        end
    endgenerate
`else
    assign psram_sio_in = psram_sio_drive;
`endif

    psram_model #(.ADDR_BITS(PSRAM_ADDR_BITS), .RD_LAUNCH_SKIP(3)) u_psram (
        .clk_32m (IQ_CLK),
        .rst_n   (RESETB),
        .ce_n    (psram_ce_n),
        .sio_out (psram_sio_out),
        .sio_oe  (psram_sio_oe),
        .sio_in  (psram_sio_drive)
    );

    // The GF180 bi_t cell leaves IE=OE=1 uncharacterized.  Keep this
    // top-level check in the functional PSRAM wrapper, independent of the
    // separate foundry-I/O-cell model smoke test.
    always @(posedge IQ_CLK) begin
        #1; // allow OE's continuous inverse onto IE to settle
        if (|(psram_sio_ie & psram_sio_oe))
            $fatal(1, "PSRAM SIO pad has IE=OE=1");
    end

endmodule
`default_nettype wire
