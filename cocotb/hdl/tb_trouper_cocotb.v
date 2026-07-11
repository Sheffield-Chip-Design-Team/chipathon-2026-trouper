// tb_trouper_cocotb.v — thin Verilog wrapper for cocotb integration tests.
// Exposes only the ports cocotb needs to drive; wires psram_model internally
// so Python code doesn't have to implement the PSRAM QPI protocol.
`default_nettype none

module tb_trouper_cocotb (
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

    trouper_top u_dut (
        .IQ_CLK        (IQ_CLK),
        .RESETB        (RESETB),
                .IQ_DATA_I_0 (IQ_DATA_I[0]),
        .IQ_DATA_I_1 (IQ_DATA_I[1]),
        .IQ_DATA_I_2 (IQ_DATA_I[2]),
        .IQ_DATA_I_3 (IQ_DATA_I[3]),,
                .IQ_DATA_Q_0 (IQ_DATA_Q[0]),
        .IQ_DATA_Q_1 (IQ_DATA_Q[1]),
        .IQ_DATA_Q_2 (IQ_DATA_Q[2]),
        .IQ_DATA_Q_3 (IQ_DATA_Q[3]),,
        .REMOD_A_I     (REMOD_A_I),
        .REMOD_A_Q     (REMOD_A_Q),
        .PSRAM_SCK     (),
        .PSRAM_CE_N    (psram_ce_n),
                .PSRAM_SIO_OUT_0 (psram_sio_out[0]),
        .PSRAM_SIO_OUT_1 (psram_sio_out[1]),
        .PSRAM_SIO_OUT_2 (psram_sio_out[2]),
        .PSRAM_SIO_OUT_3 (psram_sio_out[3]),,
                .PSRAM_SIO_IN_0 (psram_sio_in[0]),
        .PSRAM_SIO_IN_1 (psram_sio_in[1]),
        .PSRAM_SIO_IN_2 (psram_sio_in[2]),
        .PSRAM_SIO_IN_3 (psram_sio_in[3]),,
                .PSRAM_SIO_OE_0 (psram_sio_oe[0]),
        .PSRAM_SIO_OE_1 (psram_sio_oe[1]),
        .PSRAM_SIO_OE_2 (psram_sio_oe[2]),
        .PSRAM_SIO_OE_3 (psram_sio_oe[3]),,
        .HOST_CS       (HOST_CS),
        .SPI_SCK       (SPI_SCK),
        .SPI_MOSI      (SPI_MOSI),
        .SPI_MISO      (SPI_MISO),
                .GRP_ADDR_0 (1'b0),
        .GRP_ADDR_1 (1'b0),
        .GRP_ADDR_2 (1'b0),
        .GRP_ADDR_3 (1'b0),
        .GRP_ADDR_4 (1'b0),
        .GRP_ADDR_5 (1'b0),
        .GRP_ADDR_6 (1'b0),
        .GRP_ADDR_7 (1'b0),,
                .GRP_WDATA_0 (1'b0),
        .GRP_WDATA_1 (1'b0),
        .GRP_WDATA_2 (1'b0),
        .GRP_WDATA_3 (1'b0),
        .GRP_WDATA_4 (1'b0),
        .GRP_WDATA_5 (1'b0),
        .GRP_WDATA_6 (1'b0),
        .GRP_WDATA_7 (1'b0),,
        .GRP_WE        (1'b0),
        .GRP_RE        (1'b0),
                .GRP_RDATA_0 (),
        .GRP_RDATA_1 (),
        .GRP_RDATA_2 (),
        .GRP_RDATA_3 (),
        .GRP_RDATA_4 (),
        .GRP_RDATA_5 (),
        .GRP_RDATA_6 (),
        .GRP_RDATA_7 (),,
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
