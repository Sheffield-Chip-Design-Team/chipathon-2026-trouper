// fpga_dsp_wrap.v
// FPGA emulation wrapper for the LoRa MIMO ASIC.
// Directly instantiates trouper_top.v (the tapeout top level) — spi_slave and
// reg_bank included — instead of hand-wiring the individual DSP blocks. This
// gives 1:1 fidelity with the real ASIC's control-plane RTL: the host-SPI
// register interface, its arbiter against the Grouper inter-chip bus, and all
// register-driven config/status live in trouper_top.v exactly as they will on
// silicon.
//
// HOST_CS/SPI_SCK/SPI_MOSI/SPI_MISO are internal-only signals here — the
// Vivado block design (create_project.tcl) wires them to a dedicated
// axi_quad_spi core acting as the SPI master, so MicroBlaze firmware talks to
// trouper_top's spi_slave exactly as the real host RPi would (no external
// pins, no loopback wiring needed).
//
// GRP_* (Grouper inter-chip register bus) is tied inactive: no Grouper chip
// is present on this board. Its arbiter behaviour against the host SPI path
// is exercised separately in simulation (rtl-test/tb/tb_trouper_grp_arb.v).
//
// Dropped vs. the previous hand-wired wrapper:
//   - DECIM_ETH mode / eth_data,eth_push,eth_full: trouper_top.v exposes no
//     internal per-stage taps, only REMOD_A_I/Q and the SPI-readable register
//     map (sc_lock, Z pairs, W, energy, ...). Verification now happens by
//     having firmware read those registers over SPI.
//
// Injection (replaces the old int8-level INJECT mode, which bypassed the
// decimator entirely and so isn't reachable through trouper_top.v's real
// 1-bit ΣΔ input): when inj_en is asserted, four sd_remod instances (the same
// tapeout ΣΔ re-modulator used for the TX path) turn firmware-supplied int8
// I/Q samples (paced by axi_inj_ctrl.v at the decimator's R=64 output rate)
// back into a 1-bit stream, muxed onto hw_iq_i/hw_iq_q in place of the real
// SX1257 pins. This exercises the real decimator and the rest of the chain,
// unlike the old bypass.
//
// PSRAM substitution: psram_model.v provides a BRAM-backed APS6404L QPI model
//   driven by trouper_top's psram_buf_ctrl, used until the external PSRAM
//   PMOD board is ready.
//
// Clock domain: single clock (clk = 32 MHz from MMCM), matching trouper_top's
// single-clock-domain design (ce_16m derived internally).
//
// Source RTL directory (relative to this file): ../../src/ (definitive)

`default_nettype none

module fpga_dsp_wrap (
    input  wire        clk,
    input  wire        rst_n,

    // -----------------------------------------------------------------------
    // Hardware I/Q inputs — 1-bit sigma-delta streams at clk rate (32 MS/s
    // from SX1257[3:0]). Overridden by the injection path below when
    // inj_en is asserted.
    // -----------------------------------------------------------------------
    input  wire [3:0]  hw_iq_i,
    input  wire [3:0]  hw_iq_q,

    // -----------------------------------------------------------------------
    // Injection path (from axi_inj_ctrl.v, dsp_clk domain). When inj_en is
    // high, four sd_remod instances turn inj_i/q into a 1-bit stream that
    // replaces hw_iq_i/hw_iq_q feeding trouper_top.
    // -----------------------------------------------------------------------
    input  wire        inj_en,
    input  wire        inj_valid,
    input  wire signed [7:0] inj_i0, inj_q0,
    input  wire signed [7:0] inj_i1, inj_q1,
    input  wire signed [7:0] inj_i2, inj_q2,
    input  wire signed [7:0] inj_i3, inj_q3,

    // -----------------------------------------------------------------------
    // ΣΔ re-modulated output. Route to PMOD pins for oscilloscope / SX1302
    // connectivity testing.
    // -----------------------------------------------------------------------
    output wire        remod_i,
    output wire        remod_q,

    // -----------------------------------------------------------------------
    // Host-SPI register interface — internal-only; wired to a dedicated
    // axi_quad_spi core (SPI master) in the Vivado block design so MicroBlaze
    // firmware drives it exactly as the real RPi host would.
    // -----------------------------------------------------------------------
    input  wire        host_cs,
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output wire        spi_miso,

    // -----------------------------------------------------------------------
    // Sticky IRQ (IRQ_OUT / IRQ_GROUPER are the same signal on trouper_top)
    // -----------------------------------------------------------------------
    output wire        irq
);

    // No Grouper chip on this board — GRP bus stays idle so the host-SPI path
    // always wins arbitration (see trouper_top.v's grp_active priority mux).
    localparam [7:0] GRP_IDLE_ADDR  = 8'h00;
    localparam [7:0] GRP_IDLE_WDATA = 8'h00;

    wire [7:0] grp_rdata_unused;
    wire       grp_ready_unused;

    // QPI pad nets between trouper_top's psram_buf_ctrl and the BRAM PSRAM model.
    wire        psram_sck, psram_ce_n;
    wire [3:0]  psram_sio_out, psram_sio_in, psram_sio_oe;

    // =========================================================================
    // Injection path: 4x sd_remod turn paced int8 samples into a 1-bit stream,
    // muxed onto hw_iq_i/hw_iq_q in place of the real SX1257 pins.
    // =========================================================================
    wire [3:0] inj_mod_i, inj_mod_q;

    sd_remod u_inj_remod0 (.clk_32m(clk), .rst_n(rst_n), .in_i(inj_i0), .in_q(inj_q0),
                            .in_valid(inj_valid), .en(inj_en),
                            .out_i(inj_mod_i[0]), .out_q(inj_mod_q[0]));
    sd_remod u_inj_remod1 (.clk_32m(clk), .rst_n(rst_n), .in_i(inj_i1), .in_q(inj_q1),
                            .in_valid(inj_valid), .en(inj_en),
                            .out_i(inj_mod_i[1]), .out_q(inj_mod_q[1]));
    sd_remod u_inj_remod2 (.clk_32m(clk), .rst_n(rst_n), .in_i(inj_i2), .in_q(inj_q2),
                            .in_valid(inj_valid), .en(inj_en),
                            .out_i(inj_mod_i[2]), .out_q(inj_mod_q[2]));
    sd_remod u_inj_remod3 (.clk_32m(clk), .rst_n(rst_n), .in_i(inj_i3), .in_q(inj_q3),
                            .in_valid(inj_valid), .en(inj_en),
                            .out_i(inj_mod_i[3]), .out_q(inj_mod_q[3]));

    wire [3:0] muxed_iq_i = inj_en ? inj_mod_i : hw_iq_i;
    wire [3:0] muxed_iq_q = inj_en ? inj_mod_q : hw_iq_q;

    trouper_top u_top (
        .IQ_CLK        (clk),
        .RESETB        (rst_n),
        .IQ_DATA_I     (muxed_iq_i),
        .IQ_DATA_Q     (muxed_iq_q),
        .REMOD_A_I     (remod_i),
        .REMOD_A_Q     (remod_q),
        .PSRAM_SCK     (psram_sck),
        .PSRAM_CE_N    (psram_ce_n),
        .PSRAM_SIO_OUT (psram_sio_out),
        .PSRAM_SIO_IN  (psram_sio_in),
        .PSRAM_SIO_OE  (psram_sio_oe),
        .HOST_CS       (host_cs),
        .SPI_SCK       (spi_sck),
        .SPI_MOSI      (spi_mosi),
        .SPI_MISO      (spi_miso),
        .GRP_ADDR      (GRP_IDLE_ADDR),
        .GRP_WDATA     (GRP_IDLE_WDATA),
        .GRP_WE        (1'b0),
        .GRP_RE        (1'b0),
        .GRP_RDATA     (grp_rdata_unused),
        .GRP_READY     (grp_ready_unused),
        .IRQ_OUT       (irq),
        .IRQ_GROUPER   ()
    );

    // BRAM-backed APS6404L model (replaces the real chip until the PSRAM
    // board is ready). sck is unused in this same-domain model.
    psram_model #(.ADDR_BITS(16)) u_psram_mem (
        .clk_32m (clk),
        .rst_n   (rst_n),
        .ce_n    (psram_ce_n),
        .sio_out (psram_sio_out),
        .sio_oe  (psram_sio_oe),
        .sio_in  (psram_sio_in)
    );

endmodule
`default_nettype wire
