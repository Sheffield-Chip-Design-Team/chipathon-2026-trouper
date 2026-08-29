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
// PSRAM: parameter USE_EXT_PSRAM selects the QPI back-end.
//   0 (default) — psram_model.v, a BRAM-backed APS6404L QPI model driven by
//     trouper_top's psram_buf_ctrl. No external pins; used by the Verilator
//     smoke tests and any bitstream built without the MISO front-end board.
//   1 — the real external APS6404L on the daughterboard (PCB J8 -> Arty JA).
//     Four IOBUFs bridge trouper_top's SIO_OUT/OE/IN to the bidirectional
//     psram_sio[3:0] pads; psram_sck/psram_ce_n become real output pins. The
//     block design (create_project.tcl) sets this to 1 and constrains the pins
//     in arty_dsp_emul.xdc. (IOBUF is a UNISIM primitive, so it must stay out
//     of the USE_EXT_PSRAM=0 path to keep the Verilator build clean.)
//
// Clock domain: single clock (clk = 32 MHz), matching trouper_top's
// single-clock-domain design (ce_16m derived internally). On the board this
// clk is the SX1257 CLK_OUT (the front-end sample clock), exactly as the ASIC's
// IQ_CLK is on silicon — the BD BUFGs CLK_OUT_2 (JD F4) into this pin. The old
// MMCM 32 MHz is no longer used.
//
// Source RTL directory (relative to this file): ../../src/ (definitive)

`default_nettype none

module fpga_dsp_wrap #(
    // 0 = internal BRAM PSRAM model (sim / no-daughterboard); 1 = external
    // APS6404L via IOBUFs on psram_sio/psram_sck/psram_ce_n (board bitstream).
    parameter USE_EXT_PSRAM = 0
) (
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
    // External APS6404L PSRAM QPI bus (only driven when USE_EXT_PSRAM=1; tied
    // off / high-Z otherwise). psram_sio is bidirectional (SIO0..3); direction
    // is set per-bit by trouper_top's psram_buf_ctrl via the IOBUF T inputs.
    // -----------------------------------------------------------------------
    output wire        psram_sck,
    output wire        psram_ce_n,
    inout  wire [3:0]  psram_sio,

    // -----------------------------------------------------------------------
    // Host-SPI register interface. Two possible masters, selected by spi_sel:
    //   spi_sel=0 (default): the internal axi_quad_spi core (MicroBlaze plays
    //     the RPi host over host_cs/spi_sck/spi_mosi; spi_miso feeds back). This
    //     is the self-contained path used by CI / regression.
    //   spi_sel=1: a REAL external host (RPi) on the ext_* pins, so the actual
    //     host<->ASIC SPI link (10 MHz timing, CS framing, MISO drive, IRQ
    //     handshake) is validated on hardware. spi_sel is a static board switch.
    // Note: SPI_SCK is muxed BEFORE it becomes the spi_slave clock, so the
    // external ext_spi_sck pin is an ordinary data input into the mux LUT (the
    // BUFG sits on the mux output) — it does NOT need a clock-capable pin.
    // -----------------------------------------------------------------------
    input  wire        spi_sel,        // 0 = internal master, 1 = external RPi

    input  wire        host_cs,        // internal master (from axi_quad_spi)
    input  wire        spi_sck,
    input  wire        spi_mosi,
    output wire        spi_miso,        // to internal master's io1_i

    input  wire        ext_host_cs,    // external RPi host pins
    input  wire        ext_spi_sck,
    input  wire        ext_spi_mosi,
    output wire        ext_spi_miso,

    // -----------------------------------------------------------------------
    // Sticky IRQ (IRQ_OUT / IRQ_GROUPER are the same signal on trouper_top).
    // irq feeds the internal AXI GPIO (firmware poll); ext_irq is the same
    // signal on a pin for a real external host.
    // -----------------------------------------------------------------------
    output wire        irq,
    output wire        ext_irq
);

    // No Grouper chip on this board — GRP bus stays idle so the host-SPI path
    // always wins arbitration (see trouper_top.v's grp_active priority mux).
    localparam [7:0] GRP_IDLE_ADDR  = 8'h00;
    localparam [7:0] GRP_IDLE_WDATA = 8'h00;

    wire [7:0] grp_rdata_unused;
    wire       grp_ready_unused;

    // QPI pad nets between trouper_top's psram_buf_ctrl and the selected
    // back-end (internal BRAM model or external IOBUFs — see generate below).
    wire        ps_sck, ps_ce_n;
    wire [3:0]  ps_sio_out, ps_sio_in, ps_sio_oe;

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

    // Host-SPI source select. spi_sel is static (board switch); the 3 slave
    // inputs mux internal (axi_quad_spi) vs external (RPi) here, ahead of
    // spi_slave. spi_slave clocks on SPI_SCK, so the sck mux output becomes a
    // clock (fabric->BUFG), keeping the external ext_spi_sck pin non-clock.
    wire sel_host_cs = spi_sel ? ext_host_cs  : host_cs;
    wire sel_spi_sck = spi_sel ? ext_spi_sck  : spi_sck;
    wire sel_spi_mosi= spi_sel ? ext_spi_mosi : spi_mosi;

    // trouper_top SPI-slave output + IRQ, fanned out to both internal and pins.
    wire miso_w, irq_w;
    assign spi_miso     = miso_w;   // to internal axi_quad_spi io1_i
    assign ext_spi_miso = miso_w;   // to external RPi pin
    assign irq          = irq_w;    // to internal AXI GPIO
    assign ext_irq      = irq_w;    // to external IRQ pin

    trouper_top u_top (
        .IQ_CLK        (clk),
        .RESETB        (rst_n),
                .IQ_DATA_I_0 (muxed_iq_i[0]),
        .IQ_DATA_I_1 (muxed_iq_i[1]),
        .IQ_DATA_I_2 (muxed_iq_i[2]),
        .IQ_DATA_I_3 (muxed_iq_i[3]),
                .IQ_DATA_Q_0 (muxed_iq_q[0]),
        .IQ_DATA_Q_1 (muxed_iq_q[1]),
        .IQ_DATA_Q_2 (muxed_iq_q[2]),
        .IQ_DATA_Q_3 (muxed_iq_q[3]),
        .REMOD_A_I_OUT     (remod_i),
        .REMOD_A_Q_OUT     (remod_q),
        .PSRAM_SCK_OUT     (ps_sck),
        .PSRAM_CE_N_OUT    (ps_ce_n),
                .PSRAM_SIO_0_OUT (ps_sio_out[0]),
        .PSRAM_SIO_1_OUT (ps_sio_out[1]),
        .PSRAM_SIO_2_OUT (ps_sio_out[2]),
        .PSRAM_SIO_3_OUT (ps_sio_out[3]),
                .PSRAM_SIO_0_IN (ps_sio_in[0]),
        .PSRAM_SIO_1_IN (ps_sio_in[1]),
        .PSRAM_SIO_2_IN (ps_sio_in[2]),
        .PSRAM_SIO_3_IN (ps_sio_in[3]),
                .PSRAM_SIO_0_OE (ps_sio_oe[0]),
        .PSRAM_SIO_1_OE (ps_sio_oe[1]),
        .PSRAM_SIO_2_OE (ps_sio_oe[2]),
        .PSRAM_SIO_3_OE (ps_sio_oe[3]),
        .HOST_CS       (sel_host_cs),
        .SPI_SCK       (sel_spi_sck),
        .SPI_MOSI      (sel_spi_mosi),
        .SPI_MISO_OUT      (miso_w),
                .GRP_ADDR_0 (GRP_IDLE_ADDR[0]),
        .GRP_ADDR_1 (GRP_IDLE_ADDR[1]),
        .GRP_ADDR_2 (GRP_IDLE_ADDR[2]),
        .GRP_ADDR_3 (GRP_IDLE_ADDR[3]),
        .GRP_ADDR_4 (GRP_IDLE_ADDR[4]),
        .GRP_ADDR_5 (GRP_IDLE_ADDR[5]),
        .GRP_ADDR_6 (GRP_IDLE_ADDR[6]),
        .GRP_ADDR_7 (GRP_IDLE_ADDR[7]),
                .GRP_WDATA_0 (GRP_IDLE_WDATA[0]),
        .GRP_WDATA_1 (GRP_IDLE_WDATA[1]),
        .GRP_WDATA_2 (GRP_IDLE_WDATA[2]),
        .GRP_WDATA_3 (GRP_IDLE_WDATA[3]),
        .GRP_WDATA_4 (GRP_IDLE_WDATA[4]),
        .GRP_WDATA_5 (GRP_IDLE_WDATA[5]),
        .GRP_WDATA_6 (GRP_IDLE_WDATA[6]),
        .GRP_WDATA_7 (GRP_IDLE_WDATA[7]),
        .GRP_WE        (1'b0),
        .GRP_RE        (1'b0),
                .GRP_RDATA_0 (grp_rdata_unused[0]),
        .GRP_RDATA_1 (grp_rdata_unused[1]),
        .GRP_RDATA_2 (grp_rdata_unused[2]),
        .GRP_RDATA_3 (grp_rdata_unused[3]),
        .GRP_RDATA_4 (grp_rdata_unused[4]),
        .GRP_RDATA_5 (grp_rdata_unused[5]),
        .GRP_RDATA_6 (grp_rdata_unused[6]),
        .GRP_RDATA_7 (grp_rdata_unused[7]),
        .GRP_READY     (grp_ready_unused),
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
        .IRQ_OUT_OUT       (irq_w),
        .IRQ_GROUPER   ()
    );

    // =========================================================================
    // PSRAM back-end select.
    //   USE_EXT_PSRAM=1 : real APS6404L on the daughterboard. Four IOBUFs make
    //     psram_sio[3:0] bidirectional — T=~oe so the controller drives the pad
    //     when psram_buf_ctrl asserts the per-bit output enable, and samples the
    //     chip's read data on ps_sio_in otherwise. sck/ce_n are plain outputs.
    //   USE_EXT_PSRAM=0 : BRAM-backed model, no external pins. The board pads
    //     are parked (sck low, ce_n high, sio high-Z) so an unconstrained/
    //     unconnected build is still safe. sck is unused by the same-domain
    //     model. (No IOBUF here → Verilator/iverilog clean.)
    // =========================================================================
    generate
    if (USE_EXT_PSRAM) begin : g_ext_psram
        assign psram_sck  = ps_sck;
        assign psram_ce_n = ps_ce_n;
        genvar gi;
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_sio_iobuf
            IOBUF u_iobuf (
                .I  (ps_sio_out[gi]),   // controller → pad
                .O  (ps_sio_in[gi]),    // pad → controller
                .T  (~ps_sio_oe[gi]),   // T=0 drives; oe=1 means drive
                .IO (psram_sio[gi])
            );
        end
    end else begin : g_int_psram
        assign psram_sck  = 1'b0;
        assign psram_ce_n = 1'b1;
        assign psram_sio  = 4'bzzzz;
        psram_model #(.ADDR_BITS(16)) u_psram_mem (
            .clk_32m (clk),
            .rst_n   (rst_n),
            .ce_n    (ps_ce_n),
            .sio_out (ps_sio_out),
            .sio_oe  (ps_sio_oe),
            .sio_in  (ps_sio_in)
        );
    end
    endgenerate

endmodule
`default_nettype wire
