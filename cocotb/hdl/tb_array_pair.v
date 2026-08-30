// cocotb/hdl/tb_array_pair.v
//
// Two complete trouper_top instances sharing one ARRAY_ACQ_N net, for the
// multi-ASIC acquisition-sync suite (cocotb/array_sync).
//
// This is the only bench that exercises what planning/array-acquisition-sync.md
// actually claims: that a chip which never sees a preamble can be started by a
// peer that did.  The single-DUT harness (tb_trouper_cocotb.v) cannot show
// that -- it holds ARRAY_ACQ_N_IN at its idle level and has no second chip to
// generate the event.
//
// The shared net is modelled behaviourally rather than with tri/pullup:
//
//     assign array_acq_n = force_bus_high ? 1'b1 : ~(a_oe | b_oe);
//
// Both chips tie ARRAY_ACQ_N_OUT to 0 and signal only through OE, so "any OE
// asserted => net low, else pulled high" is exactly the wired-AND the board
// builds with one external pull-up.  It is also portable: Verilator's tri
// handling is weak, and this suite must run under the same Verilator default
// as the rest of cocotb/.  test_array_sync.py asserts both _OUT pins are 0
// every cycle, which is the property that makes the simplification valid --
// if either chip ever drove a 1 the model would be wrong AND the silicon would
// have bus contention.
//
// force_bus_high is the control for the negative test: hold the net at its
// idle level and chip B must NOT lock, proving a passing sync test came from
// the wire and not from B's own detector.

`timescale 1ns/1ps
`default_nettype none

module tb_array_pair #(
    parameter integer PSRAM_ADDR_BITS = 16
) (
    input  wire        IQ_CLK,
    input  wire        RESETB,

    // Chip A -- the chip that receives a preamble.
    input  wire [3:0]  A_IQ_DATA_I,
    input  wire [3:0]  A_IQ_DATA_Q,
    input  wire        A_HOST_CS,
    input  wire        A_SPI_SCK,
    input  wire        A_SPI_MOSI,
    output wire        A_SPI_MISO,
    output wire        A_IRQ_OUT,
    output wire        A_REMOD_A_I,
    output wire        A_REMOD_A_Q,
    output wire        A_ARRAY_ACQ_N_OUT,
    output wire        A_ARRAY_ACQ_N_OE,
    output wire        A_ARRAY_ACQ_N_IE,
    output wire        A_ARRAY_ACQ_N_CS,
    output wire        A_ARRAY_ACQ_N_SL,
    output wire        A_ARRAY_ACQ_N_PU,
    output wire        A_ARRAY_ACQ_N_PD,
    output wire        A_ARRAY_ACQ_N_PDRV0,
    output wire        A_ARRAY_ACQ_N_PDRV1,

    // Chip B -- deliberately starved of RF input.
    input  wire [3:0]  B_IQ_DATA_I,
    input  wire [3:0]  B_IQ_DATA_Q,
    input  wire        B_HOST_CS,
    input  wire        B_SPI_SCK,
    input  wire        B_SPI_MOSI,
    output wire        B_SPI_MISO,
    output wire        B_IRQ_OUT,
    output wire        B_REMOD_A_I,
    output wire        B_REMOD_A_Q,
    output wire        B_ARRAY_ACQ_N_OUT,
    output wire        B_ARRAY_ACQ_N_OE,

    output wire        ARRAY_ACQ_N
);
    // Held by the external pull-up when nobody drives.  A test sets this to
    // isolate the two chips without changing anything else.
    reg force_bus_high = 1'b0;

    assign ARRAY_ACQ_N = force_bus_high ? 1'b1
                                        : ~(A_ARRAY_ACQ_N_OE | B_ARRAY_ACQ_N_OE);

    trouper_chip #(.PSRAM_ADDR_BITS(PSRAM_ADDR_BITS)) u_a (
        .clk               (IQ_CLK),
        .rst_n             (RESETB),
        .IQ_DATA_I         (A_IQ_DATA_I),
        .IQ_DATA_Q         (A_IQ_DATA_Q),
        .HOST_CS           (A_HOST_CS),
        .SPI_SCK           (A_SPI_SCK),
        .SPI_MOSI          (A_SPI_MOSI),
        .SPI_MISO          (A_SPI_MISO),
        .IRQ_OUT           (A_IRQ_OUT),
        .REMOD_A_I         (A_REMOD_A_I),
        .REMOD_A_Q         (A_REMOD_A_Q),
        .ARRAY_ACQ_N_IN    (ARRAY_ACQ_N),
        .ARRAY_ACQ_N_OUT   (A_ARRAY_ACQ_N_OUT),
        .ARRAY_ACQ_N_OE    (A_ARRAY_ACQ_N_OE),
        .ARRAY_ACQ_N_IE    (A_ARRAY_ACQ_N_IE),
        .ARRAY_ACQ_N_CS    (A_ARRAY_ACQ_N_CS),
        .ARRAY_ACQ_N_SL    (A_ARRAY_ACQ_N_SL),
        .ARRAY_ACQ_N_PU    (A_ARRAY_ACQ_N_PU),
        .ARRAY_ACQ_N_PD    (A_ARRAY_ACQ_N_PD),
        .ARRAY_ACQ_N_PDRV0 (A_ARRAY_ACQ_N_PDRV0),
        .ARRAY_ACQ_N_PDRV1 (A_ARRAY_ACQ_N_PDRV1)
    );

    trouper_chip #(.PSRAM_ADDR_BITS(PSRAM_ADDR_BITS)) u_b (
        .clk               (IQ_CLK),
        .rst_n             (RESETB),
        .IQ_DATA_I         (B_IQ_DATA_I),
        .IQ_DATA_Q         (B_IQ_DATA_Q),
        .HOST_CS           (B_HOST_CS),
        .SPI_SCK           (B_SPI_SCK),
        .SPI_MOSI          (B_SPI_MOSI),
        .SPI_MISO          (B_SPI_MISO),
        .IRQ_OUT           (B_IRQ_OUT),
        .REMOD_A_I         (B_REMOD_A_I),
        .REMOD_A_Q         (B_REMOD_A_Q),
        .ARRAY_ACQ_N_IN    (ARRAY_ACQ_N),
        .ARRAY_ACQ_N_OUT   (B_ARRAY_ACQ_N_OUT),
        .ARRAY_ACQ_N_OE    (B_ARRAY_ACQ_N_OE),
        .ARRAY_ACQ_N_IE    (),
        .ARRAY_ACQ_N_CS    (),
        .ARRAY_ACQ_N_SL    (),
        .ARRAY_ACQ_N_PU    (),
        .ARRAY_ACQ_N_PD    (),
        .ARRAY_ACQ_N_PDRV0 (),
        .ARRAY_ACQ_N_PDRV1 ()
    );
endmodule


// One chip: trouper_top plus its private PSRAM model, with the ~170 pad
// tie-off and inter-project ports that this suite does not exercise reduced to
// a compact interface.  Unused inputs are tied to 0 explicitly rather than
// left dangling -- a floating input here would show up as an X inside the
// decimator and quietly poison the acquisition being measured.
module trouper_chip #(
    parameter integer PSRAM_ADDR_BITS = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  IQ_DATA_I,
    input  wire [3:0]  IQ_DATA_Q,
    input  wire        HOST_CS,
    input  wire        SPI_SCK,
    input  wire        SPI_MOSI,
    output wire        SPI_MISO,
    output wire        IRQ_OUT,
    output wire        REMOD_A_I,
    output wire        REMOD_A_Q,
    input  wire        ARRAY_ACQ_N_IN,
    output wire        ARRAY_ACQ_N_OUT,
    output wire        ARRAY_ACQ_N_OE,
    output wire        ARRAY_ACQ_N_IE,
    output wire        ARRAY_ACQ_N_CS,
    output wire        ARRAY_ACQ_N_SL,
    output wire        ARRAY_ACQ_N_PU,
    output wire        ARRAY_ACQ_N_PD,
    output wire        ARRAY_ACQ_N_PDRV0,
    output wire        ARRAY_ACQ_N_PDRV1
);
    wire       psram_ce_n;
    wire [3:0] psram_sio_out, psram_sio_oe, psram_sio_in, psram_sio_ie;
    wire [3:0] psram_sio_drive;

    assign psram_sio_in = psram_sio_drive;

    trouper_top u_dut (
        .IQ_CLK              (clk),
        .RESETB              (rst_n),
        .IQ_DATA_I_0         (IQ_DATA_I[0]),
        .IQ_DATA_I_1         (IQ_DATA_I[1]),
        .IQ_DATA_I_2         (IQ_DATA_I[2]),
        .IQ_DATA_I_3         (IQ_DATA_I[3]),
        .IQ_DATA_Q_0         (IQ_DATA_Q[0]),
        .IQ_DATA_Q_1         (IQ_DATA_Q[1]),
        .IQ_DATA_Q_2         (IQ_DATA_Q[2]),
        .IQ_DATA_Q_3         (IQ_DATA_Q[3]),
        .REMOD_A_I_OUT       (REMOD_A_I),
        .REMOD_A_Q_OUT       (REMOD_A_Q),
        .PSRAM_SCK_OUT       (),
        .PSRAM_CE_N_OUT      (psram_ce_n),
        .PSRAM_SIO_0_OUT     (psram_sio_out[0]),
        .PSRAM_SIO_1_OUT     (psram_sio_out[1]),
        .PSRAM_SIO_2_OUT     (psram_sio_out[2]),
        .PSRAM_SIO_3_OUT     (psram_sio_out[3]),
        .PSRAM_SIO_0_IN      (psram_sio_in[0]),
        .PSRAM_SIO_1_IN      (psram_sio_in[1]),
        .PSRAM_SIO_2_IN      (psram_sio_in[2]),
        .PSRAM_SIO_3_IN      (psram_sio_in[3]),
        .PSRAM_SIO_0_OE      (psram_sio_oe[0]),
        .PSRAM_SIO_1_OE      (psram_sio_oe[1]),
        .PSRAM_SIO_2_OE      (psram_sio_oe[2]),
        .PSRAM_SIO_3_OE      (psram_sio_oe[3]),
        .HOST_CS             (HOST_CS),
        .SPI_SCK             (SPI_SCK),
        .SPI_MOSI            (SPI_MOSI),
        .SPI_MISO_OUT        (SPI_MISO),
        .GRP_ADDR_0          (1'd0),
        .GRP_ADDR_1          (1'd0),
        .GRP_ADDR_2          (1'd0),
        .GRP_ADDR_3          (1'd0),
        .GRP_ADDR_4          (1'd0),
        .GRP_ADDR_5          (1'd0),
        .GRP_ADDR_6          (1'd0),
        .GRP_ADDR_7          (1'd0),
        .GRP_WDATA_0         (1'd0),
        .GRP_WDATA_1         (1'd0),
        .GRP_WDATA_2         (1'd0),
        .GRP_WDATA_3         (1'd0),
        .GRP_WDATA_4         (1'd0),
        .GRP_WDATA_5         (1'd0),
        .GRP_WDATA_6         (1'd0),
        .GRP_WDATA_7         (1'd0),
        .GRP_WE              (1'd0),
        .GRP_RE              (1'd0),
        .GRP_RDATA_0         (),
        .GRP_RDATA_1         (),
        .GRP_RDATA_2         (),
        .GRP_RDATA_3         (),
        .GRP_RDATA_4         (),
        .GRP_RDATA_5         (),
        .GRP_RDATA_6         (),
        .GRP_RDATA_7         (),
        .GRP_READY           (),
        .HADDR               (8'd0),
        .HBURST              (3'd0),
        .HMASTLOCK           (1'd0),
        .HPROT               (4'd0),
        .HSIZE               (3'd0),
        .HTRANS              (2'd0),
        .HWDATA              (8'd0),
        .HWRITE              (1'd0),
        .HRDATA              (),
        .HREADY              (),
        .HRESP               (),
        .IRQ_OUT_OUT         (IRQ_OUT),
        .IRQ_GROUPER         (),
        .ARRAY_ACQ_N_OUT     (ARRAY_ACQ_N_OUT),
        .ARRAY_ACQ_N_IN      (ARRAY_ACQ_N_IN),
        .ARRAY_ACQ_N_OE      (ARRAY_ACQ_N_OE),
        .IQ_CLK_PU           (),
        .IQ_CLK_PD           (),
        .RESETB_PU           (),
        .RESETB_PD           (),
        .IQ_DATA_I_0_PU      (),
        .IQ_DATA_I_0_PD      (),
        .IQ_DATA_I_1_PU      (),
        .IQ_DATA_I_1_PD      (),
        .IQ_DATA_I_2_PU      (),
        .IQ_DATA_I_2_PD      (),
        .IQ_DATA_I_3_PU      (),
        .IQ_DATA_I_3_PD      (),
        .IQ_DATA_Q_0_PU      (),
        .IQ_DATA_Q_0_PD      (),
        .IQ_DATA_Q_1_PU      (),
        .IQ_DATA_Q_1_PD      (),
        .IQ_DATA_Q_2_PU      (),
        .IQ_DATA_Q_2_PD      (),
        .IQ_DATA_Q_3_PU      (),
        .IQ_DATA_Q_3_PD      (),
        .HOST_CS_PU          (),
        .HOST_CS_PD          (),
        .SPI_SCK_PU          (),
        .SPI_SCK_PD          (),
        .SPI_MOSI_PU         (),
        .SPI_MOSI_PD         (),
        .PSRAM_SIO_0_IE      (psram_sio_ie[0]),
        .PSRAM_SIO_0_CS      (),
        .PSRAM_SIO_0_SL      (),
        .PSRAM_SIO_0_PU      (),
        .PSRAM_SIO_0_PD      (),
        .PSRAM_SIO_0_PDRV0   (),
        .PSRAM_SIO_0_PDRV1   (),
        .PSRAM_SIO_1_IE      (psram_sio_ie[1]),
        .PSRAM_SIO_1_CS      (),
        .PSRAM_SIO_1_SL      (),
        .PSRAM_SIO_1_PU      (),
        .PSRAM_SIO_1_PD      (),
        .PSRAM_SIO_1_PDRV0   (),
        .PSRAM_SIO_1_PDRV1   (),
        .PSRAM_SIO_2_IE      (psram_sio_ie[2]),
        .PSRAM_SIO_2_CS      (),
        .PSRAM_SIO_2_SL      (),
        .PSRAM_SIO_2_PU      (),
        .PSRAM_SIO_2_PD      (),
        .PSRAM_SIO_2_PDRV0   (),
        .PSRAM_SIO_2_PDRV1   (),
        .PSRAM_SIO_3_IE      (psram_sio_ie[3]),
        .PSRAM_SIO_3_CS      (),
        .PSRAM_SIO_3_SL      (),
        .PSRAM_SIO_3_PU      (),
        .PSRAM_SIO_3_PD      (),
        .PSRAM_SIO_3_PDRV0   (),
        .PSRAM_SIO_3_PDRV1   (),
        .PSRAM_CE_N_IN       (1'd0),
        .PSRAM_CE_N_OE       (),
        .PSRAM_CE_N_IE       (),
        .PSRAM_CE_N_CS       (),
        .PSRAM_CE_N_SL       (),
        .PSRAM_CE_N_PU       (),
        .PSRAM_CE_N_PD       (),
        .PSRAM_CE_N_PDRV0    (),
        .PSRAM_CE_N_PDRV1    (),
        .REMOD_A_I_IN        (1'd0),
        .REMOD_A_I_OE        (),
        .REMOD_A_I_IE        (),
        .REMOD_A_I_CS        (),
        .REMOD_A_I_SL        (),
        .REMOD_A_I_PU        (),
        .REMOD_A_I_PD        (),
        .REMOD_A_I_PDRV0     (),
        .REMOD_A_I_PDRV1     (),
        .REMOD_A_Q_IN        (1'd0),
        .REMOD_A_Q_OE        (),
        .REMOD_A_Q_IE        (),
        .REMOD_A_Q_CS        (),
        .REMOD_A_Q_SL        (),
        .REMOD_A_Q_PU        (),
        .REMOD_A_Q_PD        (),
        .REMOD_A_Q_PDRV0     (),
        .REMOD_A_Q_PDRV1     (),
        .SPI_MISO_IN         (1'd0),
        .SPI_MISO_OE         (),
        .SPI_MISO_IE         (),
        .SPI_MISO_CS         (),
        .SPI_MISO_SL         (),
        .SPI_MISO_PU         (),
        .SPI_MISO_PD         (),
        .SPI_MISO_PDRV0      (),
        .SPI_MISO_PDRV1      (),
        .IRQ_OUT_IN          (1'd0),
        .IRQ_OUT_OE          (),
        .IRQ_OUT_IE          (),
        .IRQ_OUT_CS          (),
        .IRQ_OUT_SL          (),
        .IRQ_OUT_PU          (),
        .IRQ_OUT_PD          (),
        .IRQ_OUT_PDRV0       (),
        .IRQ_OUT_PDRV1       (),
        .ARRAY_ACQ_N_IE      (ARRAY_ACQ_N_IE),
        .ARRAY_ACQ_N_CS      (ARRAY_ACQ_N_CS),
        .ARRAY_ACQ_N_SL      (ARRAY_ACQ_N_SL),
        .ARRAY_ACQ_N_PU      (ARRAY_ACQ_N_PU),
        .ARRAY_ACQ_N_PD      (ARRAY_ACQ_N_PD),
        .ARRAY_ACQ_N_PDRV0   (ARRAY_ACQ_N_PDRV0),
        .ARRAY_ACQ_N_PDRV1   (ARRAY_ACQ_N_PDRV1),
        .PSRAM_SCK_IN        (1'd0),
        .PSRAM_SCK_OE        (),
        .PSRAM_SCK_IE        (),
        .PSRAM_SCK_CS        (),
        .PSRAM_SCK_SL        (),
        .PSRAM_SCK_PU        (),
        .PSRAM_SCK_PD        ()
    );

    psram_model #(.ADDR_BITS(PSRAM_ADDR_BITS), .RD_LAUNCH_SKIP(3)) u_psram (
        .clk_32m (clk),
        .rst_n   (rst_n),
        .ce_n    (psram_ce_n),
        .sio_out (psram_sio_out),
        .sio_oe  (psram_sio_oe),
        .sio_in  (psram_sio_drive)
    );
endmodule
`default_nettype wire
