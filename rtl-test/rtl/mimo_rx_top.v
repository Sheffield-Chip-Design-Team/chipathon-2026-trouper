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
                .IQ_DATA_I_0 (IQ_DATA_I[0]),
        .IQ_DATA_I_1 (IQ_DATA_I[1]),
        .IQ_DATA_I_2 (IQ_DATA_I[2]),
        .IQ_DATA_I_3 (IQ_DATA_I[3]),
                .IQ_DATA_Q_0 (IQ_DATA_Q[0]),
        .IQ_DATA_Q_1 (IQ_DATA_Q[1]),
        .IQ_DATA_Q_2 (IQ_DATA_Q[2]),
        .IQ_DATA_Q_3 (IQ_DATA_Q[3]),
        .REMOD_A_I   (REMOD_A_I),
        .REMOD_A_Q   (REMOD_A_Q),
        .PSRAM_SCK   (PSRAM_SCK),
        .PSRAM_CE_N  (PSRAM_CE_N),
                .PSRAM_SIO_OUT_0 (PSRAM_SIO_OUT[0]),
        .PSRAM_SIO_OUT_1 (PSRAM_SIO_OUT[1]),
        .PSRAM_SIO_OUT_2 (PSRAM_SIO_OUT[2]),
        .PSRAM_SIO_OUT_3 (PSRAM_SIO_OUT[3]),
                .PSRAM_SIO_IN_0 (PSRAM_SIO_IN[0]),
        .PSRAM_SIO_IN_1 (PSRAM_SIO_IN[1]),
        .PSRAM_SIO_IN_2 (PSRAM_SIO_IN[2]),
        .PSRAM_SIO_IN_3 (PSRAM_SIO_IN[3]),
                .PSRAM_SIO_OE_0 (PSRAM_SIO_OE[0]),
        .PSRAM_SIO_OE_1 (PSRAM_SIO_OE[1]),
        .PSRAM_SIO_OE_2 (PSRAM_SIO_OE[2]),
        .PSRAM_SIO_OE_3 (PSRAM_SIO_OE[3]),
        .HOST_CS     (HOST_CS),
        .SPI_SCK     (SPI_SCK),
        .SPI_MOSI    (SPI_MOSI),
        .SPI_MISO    (SPI_MISO),
                .GRP_ADDR_0 (1'b0),
        .GRP_ADDR_1 (1'b0),
        .GRP_ADDR_2 (1'b0),
        .GRP_ADDR_3 (1'b0),
        .GRP_ADDR_4 (1'b0),
        .GRP_ADDR_5 (1'b0),
        .GRP_ADDR_6 (1'b0),
        .GRP_ADDR_7 (1'b0),
                .GRP_WDATA_0 (1'b0),
        .GRP_WDATA_1 (1'b0),
        .GRP_WDATA_2 (1'b0),
        .GRP_WDATA_3 (1'b0),
        .GRP_WDATA_4 (1'b0),
        .GRP_WDATA_5 (1'b0),
        .GRP_WDATA_6 (1'b0),
        .GRP_WDATA_7 (1'b0),
        .GRP_WE      (1'b0),
        .GRP_RE      (1'b0),
                .GRP_RDATA_0 (),
        .GRP_RDATA_1 (),
        .GRP_RDATA_2 (),
        .GRP_RDATA_3 (),
        .GRP_RDATA_4 (),
        .GRP_RDATA_5 (),
        .GRP_RDATA_6 (),
        .GRP_RDATA_7 (),
        .GRP_READY   (),
        .IRQ_OUT     (irq_out),
        .IRQ_GROUPER (irq_grouper_unused)
    );

    assign TCK_IRQ   = irq_out;
    assign TDO_GPIO2 = 1'b0;

endmodule
