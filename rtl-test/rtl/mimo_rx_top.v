// mimo_rx_top.v
// DEPRECATED: legacy compatibility wrapper around trouper_top.
//
// Do not use this module for new RTL, synthesis, or P&R work.
// Canonical top: rtl-test/rtl/trouper_top.v
//
// This wrapper is retained only so archived scripts/configs/netlists that
// still name mimo_rx_top can elaborate. Its extra TCK/TMS/TDI/TDO ports are
// compatibility stubs around the newer dedicated IRQ + PSRAM-SIO boundary.

`default_nettype none
`include "trouper_top.v"

module mimo_rx_top (
    input  wire        IQ_CLK,
    input  wire        RESETB,
    input  wire [3:0]  IQ_DATA_I,
    input  wire [3:0]  IQ_DATA_Q,
    output wire        REMOD_A_I,
    output wire        REMOD_A_Q,
    output wire        PSRAM_SCK,
    output wire        PSRAM_CE_N,
    output wire [3:0]  PSRAM_SIO_OUT,
    input  wire [3:0]  PSRAM_SIO_IN,
    output wire [3:0]  PSRAM_SIO_OE,
    input  wire        HOST_CS,
    input  wire        SPI_SCK,
    input  wire        SPI_MOSI,
    output wire        SPI_MISO,
    output wire        TCK_IRQ,
    input  wire        TMS_GPIO0,
    input  wire        TDI_GPIO1,
    output wire        TDO_GPIO2
);

    wire       irq_out;
    wire       irq_grouper_unused;

    trouper_top u_trouper_top (
        .IQ_CLK      (IQ_CLK),
        .RESETB      (RESETB),
        .IQ_DATA_I   (IQ_DATA_I),
        .IQ_DATA_Q   (IQ_DATA_Q),
        .REMOD_A_I   (REMOD_A_I),
        .REMOD_A_Q   (REMOD_A_Q),
        .PSRAM_SCK   (PSRAM_SCK),
        .PSRAM_CE_N  (PSRAM_CE_N),
        .PSRAM_SIO_OUT(PSRAM_SIO_OUT),
        .PSRAM_SIO_IN(PSRAM_SIO_IN),
        .PSRAM_SIO_OE(PSRAM_SIO_OE),
        .HOST_CS     (HOST_CS),
        .SPI_SCK     (SPI_SCK),
        .SPI_MOSI    (SPI_MOSI),
        .SPI_MISO    (SPI_MISO),
        .GRP_ADDR    (8'h00),
        .GRP_WDATA   (8'h00),
        .GRP_WE      (1'b0),
        .GRP_RE      (1'b0),
        .GRP_RDATA   (),
        .GRP_READY   (),
        .IRQ_OUT     (irq_out),
        .IRQ_GROUPER (irq_grouper_unused)
    );

    assign TCK_IRQ   = irq_out;
    assign TDO_GPIO2 = 1'b0;

endmodule
