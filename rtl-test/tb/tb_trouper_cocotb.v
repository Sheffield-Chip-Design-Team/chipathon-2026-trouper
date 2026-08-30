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
        .HOST_CS       (HOST_CS),
        .SPI_SCK       (SPI_SCK),
        .SPI_MOSI      (SPI_MOSI),
        .SPI_MISO_OUT      (SPI_MISO),
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
        .GRP_WE        (1'b0),
        .GRP_RE        (1'b0),
                .GRP_RDATA_0 (),
        .GRP_RDATA_1 (),
        .GRP_RDATA_2 (),
        .GRP_RDATA_3 (),
        .GRP_RDATA_4 (),
        .GRP_RDATA_5 (),
        .GRP_RDATA_6 (),
        .GRP_RDATA_7 (),
        .GRP_READY     (),
        // Grouper dev AHB-Lite endpoint: tied idle.  HTRANS must be driven
        // (HTRANS[1] is the adapter's request term); floating it would drive
        // ahb_we/ahb_re -- and hence grp_active -- to X.
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
        .IRQ_GROUPER   (),
        // Array acquisition sync: idle high, as the mandatory board
        // pull-up holds it. planning/array-acquisition-sync.md.
        .ARRAY_ACQ_N_IN (1'b1)
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
