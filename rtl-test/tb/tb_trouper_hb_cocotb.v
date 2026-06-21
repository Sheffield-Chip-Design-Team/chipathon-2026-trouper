// tb_trouper_hb_cocotb.v — thin wrapper for cocotb integration tests of trouper_top_hb.
// Exposes only the ports cocotb needs; wires psram_model internally.
`default_nettype none

module tb_trouper_hb_cocotb (
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
    wire        psram_ce_n;
    wire [3:0]  psram_sio_out, psram_sio_oe, psram_sio_in;

    trouper_top_hb u_dut (
        .IQ_CLK        (IQ_CLK),
        .RESETB        (RESETB),
        .IQ_DATA_I     (IQ_DATA_I),
        .IQ_DATA_Q     (IQ_DATA_Q),
        .REMOD_A_I     (REMOD_A_I),
        .REMOD_A_Q     (REMOD_A_Q),
        .PSRAM_SCK     (),
        .PSRAM_CE_N    (psram_ce_n),
        .PSRAM_SIO_OUT (psram_sio_out),
        .PSRAM_SIO_IN  (psram_sio_in),
        .PSRAM_SIO_OE  (psram_sio_oe),
        .HOST_CS       (HOST_CS),
        .SPI_SCK       (SPI_SCK),
        .SPI_MOSI      (SPI_MOSI),
        .SPI_MISO      (SPI_MISO),
        .GRP_ADDR      (8'h00),
        .GRP_WDATA     (8'h00),
        .GRP_WE        (1'b0),
        .GRP_RE        (1'b0),
        .GRP_RDATA     (),
        .GRP_READY     (),
        .IRQ_OUT       (IRQ_OUT),
        .IRQ_GROUPER   ()
    );

    psram_model #(.ADDR_BITS(16), .RD_LAUNCH_SKIP(3)) u_psram (
        .clk_32m (IQ_CLK),
        .rst_n   (RESETB),
        .ce_n    (psram_ce_n),
        .sio_out (psram_sio_out),
        .sio_oe  (psram_sio_oe),
        .sio_in  (psram_sio_in)
    );

endmodule
`default_nettype wire
