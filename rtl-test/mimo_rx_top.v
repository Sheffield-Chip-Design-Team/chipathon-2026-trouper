// mimo_rx_top.v
// Top-level integration: NT=1 NR=4 MRC MIMO receive-only ASIC
// GF180MCU 3.3V 32 MHz — SSCS PICO Chipathon 2026
//
// Pad count: 2+8+2+6+6+4 = 28 signal pads (clk/rst, IQ×8, remod×2,
//            PSRAM SCK+CE_N+SIO×4, SPI HOST_CS/SCK/MOSI/MISO/CS_A×2,
//            JTAG/IRQ TCK_IRQ/TMS/TDI/TDO)
//
// Signal flow:
//   SX1257[0..3] 1-bit IQ → sd_decimator×4 → dc_removal → frontend_buf_ctrl
//   → sc_detector → training_acc → [SW weights via reg_bank] → mrc_combiner
//   → sd_remod → SX1302 Radio A (1-bit IQ)
//
// Control plane:
//   spi_slave (RPi) → reg_bank ← ahb_lite_bus ← picorv32_wrap
//   irq_ctrl → PicoRV32 IRQ + TCK_IRQ pad
//   spi_master → SX1257 SPI config

`default_nettype none

module mimo_rx_top (
    // ---- Clock and reset ----
    input  wire        IQ_CLK,       // 32 MHz from PCB TCXO buffer
    input  wire        RESETB,       // active-low chip reset

    // ---- SX1257 → ASIC: 1-bit sigma-delta IQ streams ----
    input  wire [3:0]  IQ_DATA_I,    // [0]=ant0 .. [3]=ant3
    input  wire [3:0]  IQ_DATA_Q,

    // ---- ASIC → SX1302: MRC-combined sigma-delta output ----
    output wire        REMOD_A_I,
    output wire        REMOD_A_Q,

    // ---- PSRAM QPI (shared with JTAG pads at padframe level) ----
    output wire        PSRAM_SCK,     // PSRAM clock (32 MHz, gated in psram_buf_ctrl)
    output wire        PSRAM_CE_N,
    output wire [3:0]  PSRAM_SIO_OUT,
    input  wire [3:0]  PSRAM_SIO_IN,
    output wire [3:0]  PSRAM_SIO_OE,

    // ---- Shared SPI bus (host ↔ ASIC ↔ SX1257) ----
    input  wire        HOST_CS,      // active-low, RPi SPI0 CS1
    input  wire        SPI_SCK,      // bidirectional: host drives in / ASIC drives out
    input  wire        SPI_MOSI,
    output wire        SPI_MISO,
    output wire [1:0]  CS_A,         // to board-level 74HC139 → SX1257_0..3 NSS

    // ---- IRQ / JTAG muxed pads (JTAG_EN=0 → IRQ mode) ----
    output wire        TCK_IRQ,      // IRQ to RPi when JTAG_EN=0
    input  wire        TMS_GPIO0,
    input  wire        TDI_GPIO1,
    output wire        TDO_GPIO2
);

    // =========================================================================
    // Global clock and reset
    // =========================================================================
    wire clk   = IQ_CLK;
    wire rst_n = RESETB;

    // =========================================================================
    // Free-running 32-bit sample counter (for packet_ctrl_fsm)
    // =========================================================================
    reg [31:0] sample_count;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sample_count <= 32'd0;
        else        sample_count <= sample_count + 32'd1;

    // iq_valid-based sample counter — matches timing_ref domain from sc_detector
    reg [31:0] iq_samp_cnt;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) iq_samp_cnt <= 32'd0;
        else if (dcr_valid) iq_samp_cnt <= iq_samp_cnt + 32'd1;

    // =========================================================================
    // Register bank outputs (config forwarded to DSP blocks)
    // =========================================================================
    // Declare wires for all reg_bank outputs used here; tie unused inputs below.
    wire        rb_cpu_reset, rb_jtag_en;
    wire [2:0]  rb_gpio_dir, rb_gpio_out;
    wire [1:0]  rb_cpu_sram_ctrl;
    wire [2:0]  rb_tx_ctrl;
    wire [7:0]  rb_low_bat_thr;
    wire [1:0]  rb_mimo_mode;
    wire [3:0]  rb_antenna_en;
    wire [3:0]  rb_sf_cfg;
    wire [1:0]  rb_decim_ratio;
    wire        rb_bist_run;
    wire [15:0] rb_sc_thr;
    wire [1:0]  rb_sc_hits_req;
    wire        rb_energy_gate_en;
    wire [15:0] rb_energy_thr;
    wire [7:0]  rb_pkt_timeout_syms;
    wire [7:0]  rb_rx_gain_shadow_0, rb_rx_gain_shadow_1,
                rb_rx_gain_shadow_2, rb_rx_gain_shadow_3;
    wire [7:0]  rb_tx_gain_0, rb_tx_gain_1;
    wire        rb_rx_gain_commit;
    wire        rb_w_commit_pulse;
    wire [2:0]  rb_comb_post_gain_shift;
    wire [1:0]  rb_remod_backoff_shift;
    wire [127:0] rb_w_shadow;
    wire [2:0]  rb_psram_ctrl;
    wire [1:0]  rb_sx_target;
    wire [6:0]  rb_sx_addr;
    wire [7:0]  rb_sx_data_wr;
    wire        rb_sx_rnw, rb_sx_start;
    wire        rb_sram_dump_start;
    wire [9:0]  rb_sram_dump_addr;
    wire        rb_sigma2_src;
    wire [2:0]  rb_noise_alpha_shift;
    wire [15:0] rb_noise_thresh;
    wire        rb_sigma2_commit;
    wire [63:0] rb_sigma2_sw;
    wire [1:0]  rb_ref_sel;

    // =========================================================================
    // Stage 1: ΣΔ Decimators — CIC N=3 only, no FIR (×4 sd_decimator_cic_only)
    // Zero multipliers. −3.15 dB average droop vs FIR-compensated path; chirp
    // processing gain makes this irrelevant for LoRa demodulation (42+ dB margin
    // at SF=7, all BWs).  See planning/cic-only-decimator-findings.md.
    //
    // Pass-through comparison for MIMO demo: set rb_mimo_mode to select
    // mrc_combiner.mode=1 (single-antenna bypass) vs mode=0 (4-antenna MRC).
    //
    // TDM+FIR upgrade (−86 k µm² vs this, full sensitivity): see
    // planning/blocks/ΣΔ Decimator.md, section Optional FIR Upgrade — implement if area/time permit.
    // =========================================================================
    wire signed [7:0] dec_i [0:3];
    wire signed [7:0] dec_q [0:3];
    wire [3:0]        dec_valid_all;
    wire              iq_valid = dec_valid_all[0];

    sd_decimator_cic_only u_dec_0 (
        .clk_32m(clk), .clk_16m(clk), .rst_n(rst_n),
        .iq_in_i(IQ_DATA_I[0]), .iq_in_q(IQ_DATA_Q[0]),
        .decim_ratio(rb_decim_ratio),
        .iq_out_i(dec_i[0]), .iq_out_q(dec_q[0]), .iq_valid(dec_valid_all[0]));
    sd_decimator_cic_only u_dec_1 (
        .clk_32m(clk), .clk_16m(clk), .rst_n(rst_n),
        .iq_in_i(IQ_DATA_I[1]), .iq_in_q(IQ_DATA_Q[1]),
        .decim_ratio(rb_decim_ratio),
        .iq_out_i(dec_i[1]), .iq_out_q(dec_q[1]), .iq_valid(dec_valid_all[1]));
    sd_decimator_cic_only u_dec_2 (
        .clk_32m(clk), .clk_16m(clk), .rst_n(rst_n),
        .iq_in_i(IQ_DATA_I[2]), .iq_in_q(IQ_DATA_Q[2]),
        .decim_ratio(rb_decim_ratio),
        .iq_out_i(dec_i[2]), .iq_out_q(dec_q[2]), .iq_valid(dec_valid_all[2]));
    sd_decimator_cic_only u_dec_3 (
        .clk_32m(clk), .clk_16m(clk), .rst_n(rst_n),
        .iq_in_i(IQ_DATA_I[3]), .iq_in_q(IQ_DATA_Q[3]),
        .decim_ratio(rb_decim_ratio),
        .iq_out_i(dec_i[3]), .iq_out_q(dec_q[3]), .iq_valid(dec_valid_all[3]));

    // =========================================================================
    // Stage 2: DC Removal ×4 — simplified IIR, α=2^{-4}, 12-bit Q8.4 accumulator.
    // SX1257 is zero-IF with no on-chip receiver DC cancellation; this block
    // removes LO self-mixing offset before the correlator chain.
    // =========================================================================
    wire signed [7:0] dcr_i [0:3];
    wire signed [7:0] dcr_q [0:3];
    wire              dcr_valid;

    dc_removal u_dcr (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .raw_i0 (dec_i[0]), .raw_i1 (dec_i[1]),
        .raw_i2 (dec_i[2]), .raw_i3 (dec_i[3]),
        .raw_q0 (dec_q[0]), .raw_q1 (dec_q[1]),
        .raw_q2 (dec_q[2]), .raw_q3 (dec_q[3]),
        .raw_valid  (iq_valid),
        .out_i0 (dcr_i[0]), .out_i1 (dcr_i[1]),
        .out_i2 (dcr_i[2]), .out_i3 (dcr_i[3]),
        .out_q0 (dcr_q[0]), .out_q1 (dcr_q[1]),
        .out_q2 (dcr_q[2]), .out_q3 (dcr_q[3]),
        .out_valid  (dcr_valid)
    );

    // =========================================================================
    // Stage 3a: Frontend Buffer Controller (rolling SRAM window)
    // =========================================================================
    // Frontend buffer SRAM — single 512x8 macro. All 4 branches are written;
    // SC detector reads only branch 0 (cur/del). Second SRAM macro omitted.
    wire [8:0]  sram0_A, sram1_A;
    wire [7:0]  sram0_D, sram1_D;
    wire [7:0]  sram0_Q;
    wire [7:0]  sram1_Q = 8'h00;
    wire        sram0_CEN, sram1_CEN;
    wire        sram0_GWEN, sram1_GWEN;

    gf180mcu_fd_ip_sram__sram512x8m8wm1 u_sram0 (
        .CLK  (clk),
        .CEN  (sram0_CEN),
        .GWEN (sram0_GWEN),
        .WEN  (8'h00),
        .A    (sram0_A),
        .D    (sram0_D),
        .Q    (sram0_Q)
    );

    // No second frontend SRAM macro in the current area-reduced top build.
    // The unused sram1 read data is tied to zero above.

    wire signed [7:0] cur_i [0:3];
    wire signed [7:0] cur_q [0:3];
    wire signed [7:0] del_i [0:3];
    wire signed [7:0] del_q [0:3];
    wire        delayed_valid;
    wire [1:0]  buf_mode;
    wire        buf_valid;
    wire [6:0]  buf_wr_ptr;
    wire        buf_freeze;  // driven by packet_ctrl_fsm
    wire        sc_lock;    // declared here to avoid forward-reference; driven by u_sc

    frontend_buf_ctrl u_fbuf (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .in_i0 (dcr_i[0]), .in_i1 (dcr_i[1]),
        .in_i2 (dcr_i[2]), .in_i3 (dcr_i[3]),
        .in_q0 (dcr_q[0]), .in_q1 (dcr_q[1]),
        .in_q2 (dcr_q[2]), .in_q3 (dcr_q[3]),
        .sf         (rb_sf_cfg),
        .sc_lock    (sc_lock),
        .buf_freeze (buf_freeze),
        .sram0_A    (sram0_A),  .sram0_D (sram0_D),  .sram0_Q (sram0_Q),
        .sram0_CEN  (sram0_CEN),.sram0_GWEN(sram0_GWEN),
        .sram1_A    (sram1_A),  .sram1_D (sram1_D),  .sram1_Q (sram1_Q),
        .sram1_CEN  (sram1_CEN),.sram1_GWEN(sram1_GWEN),
        .cur_i0 (cur_i[0]), .cur_i1 (cur_i[1]),
        .cur_i2 (cur_i[2]), .cur_i3 (cur_i[3]),
        .cur_q0 (cur_q[0]), .cur_q1 (cur_q[1]),
        .cur_q2 (cur_q[2]), .cur_q3 (cur_q[3]),
        .del_i0 (del_i[0]), .del_i1 (del_i[1]),
        .del_i2 (del_i[2]), .del_i3 (del_i[3]),
        .del_q0 (del_q[0]), .del_q1 (del_q[1]),
        .del_q2 (del_q[2]), .del_q3 (del_q[3]),
        .delayed_valid  (delayed_valid),
        .buf_mode       (buf_mode),
        .buf_valid      (buf_valid),
        .wr_ptr         (buf_wr_ptr)
    );

    // =========================================================================
    // Stage 3b: Schmidl-Cox preamble detector
    // =========================================================================
    wire [31:0] timing_ref;
    wire signed [31:0] sc_c_i0, sc_c_q0;
    wire [15:0] sc_stat;
    wire        sc_hit_dbg;
    wire [1:0]  sc_hit_cnt_dbg;
    wire [31:0] sc_first_hit_dbg, sc_lock_snap_dbg;

    sc_detector u_sc (
        .clk          (clk),
        .rst_n        (rst_n),
        .iq_valid     (dcr_valid),
        .cur_i0 (cur_i[0]),
        .cur_q0 (cur_q[0]),
        .del_i0 (del_i[0]),
        .del_q0 (del_q[0]),
        .delayed_valid  (delayed_valid),
        .sf             (rb_sf_cfg),
        .sc_thr         (rb_sc_thr),
        .sc_hits_req    (rb_sc_hits_req),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .c_i0 (sc_c_i0), .c_q0 (sc_c_q0),
        .sc_stat              (sc_stat),
        .sc_hit_dbg           (sc_hit_dbg),
        .sc_hit_count_dbg     (sc_hit_cnt_dbg),
        .sc_first_hit_dbg     (sc_first_hit_dbg),
        .sc_lock_sample_dbg   (sc_lock_snap_dbg)
    );

    // =========================================================================
    // Stage 3c: Noise estimation — noise_est (Manhattan norm, no multipliers)
    // replaces the old energy_meas block. noise_snap[k] forwarded to reg_bank
    // via energy_snap (zero-padded to 16-bit) at 0x40–0x47.
    // =========================================================================
    wire [7:0]  noise_snap  [0:3];
    // energy_snap zero-padded to 16-bit for downstream consumers (packet_ctrl_fsm, reg_bank)
    wire [15:0] energy_snap [0:3];
    assign energy_snap[0] = {noise_snap[0], 8'h0};
    assign energy_snap[1] = {noise_snap[1], 8'h0};
    assign energy_snap[2] = {noise_snap[2], 8'h0};
    assign energy_snap[3] = {noise_snap[3], 8'h0};
    wire [9:0]  noise_metric [0:3];
    wire        noise_metric_valid;
    assign noise_metric[0] = 10'h0; assign noise_metric[1] = 10'h0;
    assign noise_metric[2] = 10'h0; assign noise_metric[3] = 10'h0;
    assign noise_metric_valid = 1'b0;

    noise_est u_nest (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .sc_lock    (sc_lock),
        .dcr_i0 (dcr_i[0]), .dcr_i1 (dcr_i[1]),
        .dcr_i2 (dcr_i[2]), .dcr_i3 (dcr_i[3]),
        .dcr_q0 (dcr_q[0]), .dcr_q1 (dcr_q[1]),
        .dcr_q2 (dcr_q[2]), .dcr_q3 (dcr_q[3]),
        .noise_snap_0 (noise_snap[0]),  .noise_snap_1 (noise_snap[1]),
        .noise_snap_2 (noise_snap[2]),  .noise_snap_3 (noise_snap[3])
    );

    // =========================================================================
    // Stage 4: Training Accumulator
    // =========================================================================
    wire signed [31:0] Z_i [0:3];
    wire signed [31:0] Z_q [0:3];
    wire               training_done;
    wire [9:0]         n_acc;

    training_acc u_tacc (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .raw_i0 (dcr_i[0]), .raw_i1 (dcr_i[1]),
        .raw_i2 (dcr_i[2]), .raw_i3 (dcr_i[3]),
        .raw_q0 (dcr_q[0]), .raw_q1 (dcr_q[1]),
        .raw_q2 (dcr_q[2]), .raw_q3 (dcr_q[3]),
        .sc_lock    (sc_lock),
        .timing_ref (timing_ref),
        .sf         (rb_sf_cfg),
        .Z_i0 (Z_i[0]), .Z_q0 (Z_q[0]),
        .Z_i1 (Z_i[1]), .Z_q1 (Z_q[1]),
        .Z_i2 (Z_i[2]), .Z_q2 (Z_q[2]),
        .Z_i3 (Z_i[3]), .Z_q3 (Z_q[3]),
        .training_done (training_done),
        .n_acc       (n_acc)
    );

    // =========================================================================
    // Stage 5: sigma2 register path — noise_metric[] currently tied to 0 so
    // sigma2_hw/sigma2_valid always read zero. Scaffolding retained for future
    // HW noise estimator; firmware reads coarse noise via energy_snap instead.
    // =========================================================================
    wire [15:0] sigma2_hw [0:3];
    wire        sigma2_valid;
    wire        noise_sample_en;   // driven by packet_ctrl_fsm; retained for FW timing/IRQ use

    assign sigma2_hw[0] = {6'd0, noise_metric[0]};
    assign sigma2_hw[1] = {6'd0, noise_metric[1]};
    assign sigma2_hw[2] = {6'd0, noise_metric[2]};
    assign sigma2_hw[3] = {6'd0, noise_metric[3]};

    reg sigma2_valid_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)              sigma2_valid_r <= 1'b0;
        else if (noise_metric_valid) sigma2_valid_r <= 1'b1;

    assign sigma2_valid = sigma2_valid_r;

    // =========================================================================
    // Stage 6: HW weight_gen removed — SW weight gen via firmware + reg_bank.
    // Firmware writes 8-bit weights to the HIGH byte of each W shadow register,
    // then strobes W_commit (reg_bank → rb_w_commit_pulse) to arm the combiner.
    // =========================================================================
    wire W_commit_hw = rb_w_commit_pulse;

    // =========================================================================
    // Stage 7: Packet Control FSM
    // =========================================================================
    wire        safe_switch, W_valid_set, W_missed_packet;
    wire        combiner_source;
    wire [2:0]  packet_phase;
    wire        packet_active;
    wire [1:0]  active_mode;
    wire [3:0]  active_antenna_en;

    // W_valid register: set by W_valid_set pulse, cleared at FSM IDLE entry
    reg  W_valid;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)           W_valid <= 1'b0;
        else if (W_valid_set) W_valid <= 1'b1;
        else if (!packet_active) W_valid <= 1'b0;

    packet_ctrl_fsm u_pcfsm (
        .clk             (clk),
        .rst_n           (rst_n),
        .iq_valid        (dcr_valid),
        .sample_count    (sample_count),
        .sf              (rb_sf_cfg),
        .sc_lock         (sc_lock),
        .timing_ref      (timing_ref),
        .training_done   (training_done),
        .W_commit        (W_commit_hw),
        .mode_shadow     (rb_mimo_mode),
        .antenna_en_shadow (rb_antenna_en),
        .psram_en        (rb_psram_ctrl[0]),
        .psram_replay_active (1'b0),
        .pkt_timeout_syms (rb_pkt_timeout_syms),
        .noise_thresh    (rb_noise_thresh),
        .energy0         (energy_snap[0]), .energy1 (energy_snap[1]),
        .energy2         (energy_snap[2]), .energy3 (energy_snap[3]),
        .safe_switch     (safe_switch),
        .W_valid_set     (W_valid_set),
        .W_missed_packet (W_missed_packet),
        .combiner_source (combiner_source),
        .psram_packet_arm  (),
        .psram_replay_start(),
        .psram_abort       (),
        .payload_rd_base   (),
        .buf_freeze        (buf_freeze),
        .packet_phase      (packet_phase),
        .packet_active     (packet_active),
        .active_mode       (active_mode),
        .active_antenna_en (active_antenna_en),
        .noise_sample_en   (noise_sample_en)
    );

    // =========================================================================
    // Stage 7b: PSRAM Buffer Controller (same-packet MRC)
    // =========================================================================
    wire signed [7:0] rpl_i [0:3];
    wire signed [7:0] rpl_q [0:3];
    wire              rpl_valid;
    wire              psram_buf_active, psram_replay_active_w;
    wire              psram_qe_init_done, psram_replay_missed, psram_overflow;
    wire [2:0]        psram_state_dbg;

    psram_buf_ctrl u_psram (
        .clk_32m      (clk),
        .rst_n        (rst_n),
        .psram_en     (rb_psram_ctrl[0]),
        .init_start   (rb_psram_ctrl[2]),  // firmware strobes bit[2] after tPU
        .iq_i0 (dcr_i[0]), .iq_i1 (dcr_i[1]),
        .iq_i2 (dcr_i[2]), .iq_i3 (dcr_i[3]),
        .iq_q0 (dcr_q[0]), .iq_q1 (dcr_q[1]),
        .iq_q2 (dcr_q[2]), .iq_q3 (dcr_q[3]),
        .iq_valid     (dcr_valid),
        .sc_lock      (sc_lock),
        .timing_ref   (timing_ref),
        .iq_sample_cnt(iq_samp_cnt),
        .W_commit     (W_commit_hw),
        .packet_end   (packet_done_pulse),
        .sck          (PSRAM_SCK),
        .ce_n         (PSRAM_CE_N),
        .sio_out      (PSRAM_SIO_OUT),
        .sio_in       (PSRAM_SIO_IN),
        .sio_oe       (PSRAM_SIO_OE),
        .rpl_i0 (rpl_i[0]), .rpl_i1 (rpl_i[1]),
        .rpl_i2 (rpl_i[2]), .rpl_i3 (rpl_i[3]),
        .rpl_q0 (rpl_q[0]), .rpl_q1 (rpl_q[1]),
        .rpl_q2 (rpl_q[2]), .rpl_q3 (rpl_q[3]),
        .rpl_valid    (rpl_valid),
        .buf_active   (psram_buf_active),
        .replay_active(psram_replay_active_w),
        .qe_init_done (psram_qe_init_done),
        .replay_missed(psram_replay_missed),
        .overflow     (psram_overflow),
        .state_dbg    (psram_state_dbg)
    );

    // Combiner input mux: live decimator IQ during normal/buffering,
    // PSRAM replay IQ during replay. x_valid follows the active source.
    wire signed [7:0] comb_xi [0:3];
    wire signed [7:0] comb_xq [0:3];
    wire              comb_xvalid;
    genvar gi;
    generate for (gi = 0; gi < 4; gi = gi + 1) begin : g_comb_mux
        assign comb_xi[gi] = psram_replay_active_w ? rpl_i[gi] : dcr_i[gi];
        assign comb_xq[gi] = psram_replay_active_w ? rpl_q[gi] : dcr_q[gi];
    end endgenerate
    assign comb_xvalid = psram_replay_active_w ? rpl_valid : dcr_valid;

    // =========================================================================
    // Stage 8: MRC Combiner
    // =========================================================================
    wire signed [7:0] comb_y_i, comb_y_q;
    wire              comb_y_valid;

    // bypass_ant: lowest set bit of active_antenna_en
    wire [1:0] bypass_ant = active_antenna_en[1] ? 2'd1 :
                            active_antenna_en[2] ? 2'd2 :
                            active_antenna_en[3] ? 2'd3 : 2'd0;

    mrc_combiner u_comb (
        .clk_16m (clk),
        .rst_n   (rst_n),
        .x_i0 (comb_xi[0]), .x_q0 (comb_xq[0]),
        .x_i1 (comb_xi[1]), .x_q1 (comb_xq[1]),
        .x_i2 (comb_xi[2]), .x_q2 (comb_xq[2]),
        .x_i3 (comb_xi[3]), .x_q3 (comb_xq[3]),
        .x_valid  (comb_xvalid),
        .W_re0 (rb_w_shadow[127:120]), .W_im0 (rb_w_shadow[111:104]),
        .W_re1 (rb_w_shadow[95:88]),  .W_im1 (rb_w_shadow[79:72]),
        .W_re2 (rb_w_shadow[63:56]),  .W_im2 (rb_w_shadow[47:40]),
        .W_re3 (rb_w_shadow[31:24]),  .W_im3 (rb_w_shadow[15:8]),
        .W_valid   (W_valid),
        .mode      (active_mode[0]),    // 0=MRC, 1=bypass
        .bypass_ant(bypass_ant),
        .post_gain_shift(rb_comb_post_gain_shift),
        .y_i    (comb_y_i),
        .y_q    (comb_y_q),
        .y_valid(comb_y_valid)
    );

    // =========================================================================
    // Stage 9: ΣΔ Re-modulator → SX1302 Radio A
    // During PSRAM BUFFERING (buf_active && !replay_active): silence output.
    // During REPLAY: combiner processes PSRAM replay IQ → normal remod path.
    // =========================================================================
    wire psram_silence = psram_buf_active && !psram_replay_active_w;
    wire signed [7:0] remod_in_i = psram_silence ? 8'sd0 :
                                   (active_mode[0] ? comb_y_i : ($signed(comb_y_i) >>> rb_remod_backoff_shift));
    wire signed [7:0] remod_in_q = psram_silence ? 8'sd0 :
                                   (active_mode[0] ? comb_y_q : ($signed(comb_y_q) >>> rb_remod_backoff_shift));
    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (remod_in_i),
        .in_q     (remod_in_q),
        .in_valid (psram_silence ? 1'b0  : comb_y_valid),
        .en       (1'b1),
        .out_i    (REMOD_A_I),
        .out_q    (REMOD_A_Q)
    );

    // =========================================================================
    // Control Plane
    // =========================================================================

    // ---- AHB-Lite master/slave wires ----
    wire [31:0] cpu_HADDR;
    wire [1:0]  cpu_HTRANS;
    wire        cpu_HWRITE;
    wire [2:0]  cpu_HSIZE, cpu_HBURST;
    wire [31:0] cpu_HWDATA, cpu_HRDATA;
    wire        cpu_HREADY, cpu_HRESP;

    // Slave 0: reg_bank
    wire [7:0] s0_addr, s0_wdata, s0_rdata;
    wire       s0_we, s0_re, s0_ready;

    // Slave 1: spi_master
    wire [7:0] s1_addr, s1_wdata, s1_rdata;
    wire       s1_we, s1_re, s1_ready;

    // Slave 2: irq_ctrl
    wire [7:0] s2_addr, s2_wdata, s2_rdata;
    wire       s2_we, s2_re, s2_ready;

    // Slave 3: unused (tie ready/rdata)
    wire [7:0] s3_rdata = 8'h00;
    wire       s3_ready = 1'b1;

    // ---- IRQ source signals ----
    wire irq_out;

    // Edge-detect packet_done (falling edge of packet_active = packet FSM returned to IDLE)
    reg packet_active_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) packet_active_r <= 1'b0;
        else        packet_active_r <= packet_active;
    wire packet_done_pulse = packet_active_r && !packet_active;

    // irq_set for reg_bank: level signals; reg_bank latches rising edges internally
    wire [7:0] rb_irq_set = {1'b0, rb_tx_ctrl[1], rb_tx_ctrl[0], 1'b0,
                             packet_done_pulse, W_missed_packet, training_done, sc_lock};

    // ---- Register Bank ----
    reg_bank u_rb (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (s0_addr),
        .wdata      (s0_wdata),
        .we         (s0_we),
        .re         (s0_re),
        .rdata      (s0_rdata),
        .ready      (s0_ready),
        // Hardware status inputs
        .gpio_in    ({TDI_GPIO1, TMS_GPIO0, 1'b0}),
        .cpu_sram_status (6'd0),
        .buf_mode        (buf_mode),
        .buf_valid       (buf_valid),
        .sram0_bist_pass (1'b1),
        .sram1_bist_pass (1'b1),
        .buf_freeze      (buf_freeze),
        .buf_wr_ptr      (buf_wr_ptr),
        .rx_gain_active_0 (8'h3E), .rx_gain_active_1 (8'h3E),
        .rx_gain_active_2 (8'h3E), .rx_gain_active_3 (8'h3E),
        .rx_gain_pending  (1'b0),
        .rx_gain_owner    (1'b0),
        .rx_gain_error    (1'b0),
        .active_mode_rb   (active_mode),
        .active_antenna_en_rb (active_antenna_en),
        .packet_active    (packet_active),
        .packet_phase     (packet_phase),
        .training_done_rb (training_done),
        .w_pending_rb     (1'b0),
        .w_valid_rb       (W_valid),
        .w_missed_rb      (W_missed_packet),
        .irq_set          (rb_irq_set),
        .energy_0 (energy_snap[0]), .energy_1 (energy_snap[1]),
        .energy_2 (energy_snap[2]), .energy_3 (energy_snap[3]),
        .corr_mag_0 (16'd0), .corr_mag_1 (16'd0),
        .corr_mag_2 (16'd0), .corr_mag_3 (16'd0),
        .sc_stat         (sc_stat),
        .training_armed  (1'b0),
        .n_acc           (n_acc),
        .z_shift         (6'd0),
        .c_pool_i        (16'd0),
        .c_pool_q        (16'd0),
        .cfo_diag        (16'd0),
        .z0_i (Z_i[0]), .z0_q (Z_q[0]),
        .z1_i (Z_i[1]), .z1_q (Z_q[1]),
        .z2_i (Z_i[2]), .z2_q (Z_q[2]),
        .z3_i (Z_i[3]), .z3_q (Z_q[3]),
        .sc_hit_dbg          (sc_hit_dbg),
        .sc_hit_count_dbg    (sc_hit_cnt_dbg),
        .sc_lock_dbg         (sc_lock),
        .sc_first_hit_dbg    (sc_first_hit_dbg),
        .sc_lock_snap_dbg    (sc_lock_snap_dbg),
        .sram_dump_done      (1'b0),
        .sram_dump_data      (8'd0),
        .sigma2_valid        (sigma2_valid),
        .sigma2_hw_0 (sigma2_hw[0]), .sigma2_hw_1 (sigma2_hw[1]),
        .sigma2_hw_2 (sigma2_hw[2]), .sigma2_hw_3 (sigma2_hw[3]),
        // PSRAM status → reg_bank 0xB1:
        //   [2:0]=state_dbg [3]=qe_init_done [4]=replay_active
        //   [5]=replay_missed [6]=overflow [7]=buf_active
        .psram_status_rb  ({psram_buf_active, psram_overflow,
                            psram_replay_missed, psram_replay_active_w,
                            psram_qe_init_done, psram_state_dbg}),
        .psram_pkt_bytes  (16'd0),
        .psram_rd_offset  (8'd0),
        // Hardware control outputs
        .cpu_reset       (rb_cpu_reset),
        .jtag_en         (rb_jtag_en),
        .gpio_dir        (rb_gpio_dir),
        .gpio_out        (rb_gpio_out),
        .cpu_sram_ctrl   (rb_cpu_sram_ctrl),
        .tx_ctrl         (rb_tx_ctrl),
        .low_bat_thr     (rb_low_bat_thr),
        .mimo_mode       (rb_mimo_mode),
        .antenna_en      (rb_antenna_en),
        .sf_cfg          (rb_sf_cfg),
        .decim_ratio     (rb_decim_ratio),
        .bist_run        (rb_bist_run),
        .sc_thr          (rb_sc_thr),
        .sc_hits_req     (rb_sc_hits_req),
        .energy_gate_en  (rb_energy_gate_en),
        .energy_thr      (rb_energy_thr),
        .pkt_timeout_syms(rb_pkt_timeout_syms),
        .rx_gain_shadow_0(rb_rx_gain_shadow_0),
        .rx_gain_shadow_1(rb_rx_gain_shadow_1),
        .rx_gain_shadow_2(rb_rx_gain_shadow_2),
        .rx_gain_shadow_3(rb_rx_gain_shadow_3),
        .tx_gain_0       (rb_tx_gain_0),
        .tx_gain_1       (rb_tx_gain_1),
        .rx_gain_commit  (rb_rx_gain_commit),
        .wgt_src         (),
        .wgt_auto_commit (),
        .wgt_mode        (),
        .w_commit_pulse  (rb_w_commit_pulse),
        .comb_post_gain_shift(rb_comb_post_gain_shift),
        .remod_backoff_shift(rb_remod_backoff_shift),
        .w_shadow        (rb_w_shadow),
        .cal_coeff       (),
        .psram_ctrl      (rb_psram_ctrl),
        .sx_target       (rb_sx_target),
        .sx_addr         (rb_sx_addr),
        .sx_data_wr      (rb_sx_data_wr),
        .sx_rnw          (rb_sx_rnw),
        .sx_start        (rb_sx_start),
        .sram_dump_start (rb_sram_dump_start),
        .sram_dump_addr  (rb_sram_dump_addr),
        .sigma2_src      (rb_sigma2_src),
        .noise_alpha_shift(rb_noise_alpha_shift),
        .noise_thresh    (rb_noise_thresh),
        .sigma2_commit   (rb_sigma2_commit),
        .sigma2_sw       (rb_sigma2_sw),
        .noise_en        (),
        .ref_sel         (rb_ref_sel)
    );

    // ---- SPI Master (→ SX1257) ----
    wire spim_busy;
    wire [7:0] sx_rdata_back;
    wire       sx_rdata_valid;
    wire       spim_SCK, spim_MOSI;

    spi_master u_spim (
        .clk_32m     (clk),
        .rst_n       (rst_n),
        .s_addr      (s1_addr),
        .s_wdata     (s1_wdata),
        .s_we        (s1_we),
        .s_re        (s1_re),
        .s_rdata     (s1_rdata),
        .s_ready     (s1_ready),
        .sx_start    (rb_sx_start),
        .sx_rnw      (rb_sx_rnw),
        .sx_target   (rb_sx_target),
        .sx_addr_in  (rb_sx_addr),
        .sx_wdata_in (rb_sx_data_wr),
        .sx_rdata_out  (sx_rdata_back),
        .sx_rdata_valid(sx_rdata_valid),
        .SPI_SCK  (spim_SCK),
        .SPI_MOSI (spim_MOSI),
        .SPI_MISO (SPI_MISO),   // shared MISO pad
        .CS_A     (CS_A),
        .busy     (spim_busy)
    );

    // ---- IRQ Controller (AHB-Lite slave 2) ----
    irq_ctrl u_irqc (
        .clk_32m        (clk),
        .rst_n          (rst_n),
        .corr_lock      (sc_lock),
        .training_done  (training_done),
        .W_missed_packet(W_missed_packet),
        .packet_done    (packet_done_pulse),
        .noise_ready    (1'b0),
        .tx_prep        (rb_tx_ctrl[0]),
        .tx_done        (rb_tx_ctrl[1]),
        .irq_out        (irq_out),
        .s_addr         (s2_addr),
        .s_wdata        (s2_wdata),
        .s_we           (s2_we),
        .s_re           (s2_re),
        .s_rdata        (s2_rdata),
        .s_ready        (s2_ready)
    );

    // ---- AHB-Lite Bus ----
    ahb_lite_bus u_ahb (
        .HCLK     (clk),
        .HRESETn  (rst_n),
        .HADDR    (cpu_HADDR),
        .HTRANS   (cpu_HTRANS),
        .HWRITE   (cpu_HWRITE),
        .HSIZE    (cpu_HSIZE),
        .HBURST   (cpu_HBURST),
        .HWDATA   (cpu_HWDATA),
        .HRDATA   (cpu_HRDATA),
        .HREADY   (cpu_HREADY),
        .HRESP    (cpu_HRESP),
        // Slave 0: reg_bank
        .s0_addr  (s0_addr),  .s0_wdata (s0_wdata),
        .s0_we    (s0_we),    .s0_re    (s0_re),
        .s0_rdata (s0_rdata), .s0_ready (s0_ready),
        // Slave 1: spi_master
        .s1_addr  (s1_addr),  .s1_wdata (s1_wdata),
        .s1_we    (s1_we),    .s1_re    (s1_re),
        .s1_rdata (s1_rdata), .s1_ready (s1_ready),
        // Slave 2: irq_ctrl
        .s2_addr  (s2_addr),  .s2_wdata (s2_wdata),
        .s2_we    (s2_we),    .s2_re    (s2_re),
        .s2_rdata (s2_rdata), .s2_ready (s2_ready),
        // Slave 3: unused
        .s3_addr  (), .s3_wdata (), .s3_we (), .s3_re (),
        .s3_rdata (s3_rdata), .s3_ready (s3_ready)
    );

    // ---- PicoRV32 Wrapper ----
    wire [11:0] fw_ld_addr_w;
    wire [7:0]  fw_ld_wdata_w, fw_ld_rdata_w;
    wire        fw_ld_we_w, fw_ld_req_w, fw_ld_ready_w;

    picorv32_wrap u_cpu (
        .clk_32m   (clk),
        .rst_n     (rst_n),
        .cpu_reset (rb_cpu_reset),
        .irq_in    (irq_out),
        .HADDR     (cpu_HADDR),
        .HTRANS    (cpu_HTRANS),
        .HWRITE    (cpu_HWRITE),
        .HSIZE     (cpu_HSIZE),
        .HBURST    (cpu_HBURST),
        .HWDATA    (cpu_HWDATA),
        .HRDATA    (cpu_HRDATA),
        .HREADY    (cpu_HREADY),
        .HRESP     (cpu_HRESP),
        .fw_ld_addr  (fw_ld_addr_w),
        .fw_ld_wdata (fw_ld_wdata_w),
        .fw_ld_we    (fw_ld_we_w),
        .fw_ld_rdata (fw_ld_rdata_w),
        .fw_ld_ready (fw_ld_ready_w)
    );

    // ---- SPI Slave (host RPi interface) ----
    wire [7:0]  spi_slave_reg_addr, spi_slave_reg_wdata;
    wire        spi_slave_reg_we;

    spi_slave u_spis (
        .clk_32m   (clk),
        .rst_n     (rst_n),
        .HOST_CS   (HOST_CS),
        .SPI_SCK   (SPI_SCK),
        .SPI_MOSI  (SPI_MOSI),
        .SPI_MISO  (SPI_MISO),
        .reg_addr  (spi_slave_reg_addr),
        .reg_wdata (spi_slave_reg_wdata),
        .reg_we    (spi_slave_reg_we),
        .reg_rdata (s0_rdata),           // read from reg_bank output (same port)
        .fw_ld_addr  (fw_ld_addr_w),
        .fw_ld_wdata (fw_ld_wdata_w),
        .fw_ld_we    (fw_ld_we_w),
        .fw_ld_rdata (fw_ld_rdata_w),
        .fw_ld_req   (fw_ld_req_w),
        .fw_ld_ready (fw_ld_ready_w)
    );

    // =========================================================================
    // Pad mux: TCK_IRQ and GPIO/JTAG
    // IRQ mode (JTAG_EN=0): TCK_IRQ = irq_out; TMS/TDI/TDO = GPIO
    // JTAG mode (JTAG_EN=1): pads handed to JTAG TAP (not implemented here)
    // =========================================================================
    assign TCK_IRQ  = rb_jtag_en ? 1'b0 : irq_out;
    assign TDO_GPIO2 = rb_jtag_en ? 1'b0 : rb_gpio_out[2];

    // =========================================================================
    // SPI bus mux: host drives SCK/MOSI when HOST_CS=0; ASIC drives when busy
    // MISO is open-drain: spi_slave drives when HOST_CS=0, spi_master when busy
    // =========================================================================
    // (Pad tristate logic; in GF180MCU this is handled by IO cell configuration)
    // For RTL purposes, SPI_MISO is driven by whichever master is active.
    // This is resolved at IO ring level; both blocks share the same SPI_MISO port.

endmodule

`default_nettype wire
