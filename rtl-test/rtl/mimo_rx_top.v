// mimo_rx_top.v
// Legacy compatibility wrapper around the radio-only Trouper hard macro.

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
    output wire [1:0]  CS_A,
    output wire        TCK_IRQ,
    input  wire        TMS_GPIO0,
    input  wire        TDI_GPIO1,
    output wire        TDO_GPIO2
);

    wire [7:0] cfg_rdata_unused;
    wire       cfg_ready_unused;
    wire       irq_out;

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
        .CFG_ADDR    (8'h00),
        .CFG_WDATA   (8'h00),
        .CFG_WE      (1'b0),
        .CFG_RE      (1'b0),
        .CFG_RDATA   (cfg_rdata_unused),
        .CFG_READY   (cfg_ready_unused),
        .IRQ_OUT     (irq_out)
    );

    assign SPI_MISO  = 1'b0;
    assign CS_A      = 2'b00;
    assign TCK_IRQ   = irq_out;
    assign TDO_GPIO2 = 1'b0;

endmodule
