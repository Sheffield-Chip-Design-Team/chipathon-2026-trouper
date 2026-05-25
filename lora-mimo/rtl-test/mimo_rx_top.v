// mimo_rx_top.v
// Top-level integration: NT=1 NR=4 MRC MIMO receive-only ASIC
// GF180MCU 3.3V 32 MHz — SSCS PICO Chipathon 2026
//
// Pad count: 4+4+1+2+3+2+1+1+4 = 22 signal pads + 2 VDD + 1 GND = 25 total
//
// Signal flow:
//   SX1257[0..3] 1-bit IQ → sd_decimator×4 → dc_removal → frontend_buf_ctrl
//   → sc_detector → training_acc → weight_gen → mrc_combiner → sd_remod
//   → SX1302 Radio A (1-bit IQ)
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
    wire [7:0]  rb_rx_gain_shadow_0, rb_rx_gain_shadow_1;
    wire [7:0]  rb_tx_gain_0, rb_tx_gain_1;
    wire        rb_rx_gain_commit;
    wire        rb_wgt_src, rb_wgt_auto_commit;
    wire [1:0]  rb_wgt_mode;
    wire        rb_w_commit_pulse;
    wire [2:0]  rb_comb_post_gain_shift;
    wire [127:0] rb_w_shadow;
    wire [127:0] rb_cal_coeff;
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

    // =========================================================================
    // Stage 1: ΣΔ Decimators ×4
    // =========================================================================
    wire signed [7:0] dec_i [0:3];
    wire signed [7:0] dec_q [0:3];
    wire              dec_valid [0:3];

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_dec
            sd_decimator u_dec (
                .clk_32m     (clk),
                .clk_16m     (clk),
                .rst_n       (rst_n),
                .iq_in_i     (IQ_DATA_I[g]),
                .iq_in_q     (IQ_DATA_Q[g]),
                .decim_ratio (rb_decim_ratio),
                .iq_out_i    (dec_i[g]),
                .iq_out_q    (dec_q[g]),
                .iq_valid    (dec_valid[g])
            );
        end
    endgenerate

    // All decimators share the same ratio and are synchronous to the same clock,
    // so dec_valid[0] is representative — use it as the common iq_valid strobe.
    wire iq_valid = dec_valid[0];

    // =========================================================================
    // Stage 2: DC Removal ×4 (single module, all 4 branches)
    // =========================================================================
    wire signed [7:0] dcr_i [0:3];
    wire signed [7:0] dcr_q [0:3];
    wire              dcr_valid;

    // DC_ALPHA_SHIFT hardwired to 8 per spec (can be made reg_bank config)
    localparam DC_ALPHA_SHIFT = 4'd8;

    dc_removal u_dcr (
        .clk_32m       (clk),
        .rst_n         (rst_n),
        .raw_i0 (dec_i[0]), .raw_i1 (dec_i[1]),
        .raw_i2 (dec_i[2]), .raw_i3 (dec_i[3]),
        .raw_q0 (dec_q[0]), .raw_q1 (dec_q[1]),
        .raw_q2 (dec_q[2]), .raw_q3 (dec_q[3]),
        .raw_valid     (iq_valid),
        .dc_alpha_shift(DC_ALPHA_SHIFT),
        .dc_bypass     (1'b0),
        .out_i0 (dcr_i[0]), .out_i1 (dcr_i[1]),
        .out_i2 (dcr_i[2]), .out_i3 (dcr_i[3]),
        .out_q0 (dcr_q[0]), .out_q1 (dcr_q[1]),
        .out_q2 (dcr_q[2]), .out_q3 (dcr_q[3]),
        .out_valid     (dcr_valid),
        .dc_est_i0 (), .dc_est_i1 (), .dc_est_i2 (), .dc_est_i3 (),
        .dc_est_q0 (), .dc_est_q1 (), .dc_est_q2 (), .dc_est_q3 ()
    );

    // =========================================================================
    // Stage 3a: Frontend Buffer Controller (rolling SRAM window)
    // =========================================================================
    // Frontend buffer SRAMs — gf180mcu_fd_ip_sram__sram512x8m8wm1 macros
    wire [8:0]  sram0_A, sram1_A;
    wire [7:0]  sram0_D, sram1_D;
    wire [7:0]  sram0_Q, sram1_Q;
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

    gf180mcu_fd_ip_sram__sram512x8m8wm1 u_sram1 (
        .CLK  (clk),
        .CEN  (sram1_CEN),
        .GWEN (sram1_GWEN),
        .WEN  (8'h00),
        .A    (sram1_A),
        .D    (sram1_D),
        .Q    (sram1_Q)
    );

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
    wire signed [31:0] sc_c_i0, sc_c_q0, sc_c_i1, sc_c_q1;
    wire [15:0] sc_stat;
    wire        sc_hit_dbg;
    wire [1:0]  sc_hit_cnt_dbg;
    wire [31:0] sc_first_hit_dbg, sc_lock_snap_dbg;

    sc_detector u_sc (
        .clk          (clk),
        .rst_n        (rst_n),
        .iq_valid     (dcr_valid),
        .cur_i0 (cur_i[0]), .cur_i1 (cur_i[1]),
        .cur_q0 (cur_q[0]), .cur_q1 (cur_q[1]),
        .del_i0 (del_i[0]), .del_i1 (del_i[1]),
        .del_q0 (del_q[0]), .del_q1 (del_q[1]),
        .delayed_valid  (delayed_valid),
        .sf             (rb_sf_cfg),
        .sc_thr         (rb_sc_thr),
        .sc_hits_req    (rb_sc_hits_req),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .c_i0 (sc_c_i0), .c_q0 (sc_c_q0),
        .c_i1 (sc_c_i1), .c_q1 (sc_c_q1),
        .sc_stat              (sc_stat),
        .sc_hit_dbg           (sc_hit_dbg),
        .sc_hit_count_dbg     (sc_hit_cnt_dbg),
        .sc_first_hit_dbg     (sc_first_hit_dbg),
        .sc_lock_sample_dbg   (sc_lock_snap_dbg)
    );

    // =========================================================================
    // Stage 3c: Energy Measurement (feeds AGC snapshot + NFE)
    // =========================================================================
    wire [31:0] energy_sum [0:3];
    wire [15:0] energy_snap [0:3];
    wire        energy_valid, energy_snapshot_valid;

    energy_meas u_em (
        .clk_32m     (clk),
        .rst_n       (rst_n),
        .iq_i_0 (dcr_i[0]), .iq_i_1 (dcr_i[1]),
        .iq_i_2 (dcr_i[2]), .iq_i_3 (dcr_i[3]),
        .iq_q_0 (dcr_q[0]), .iq_q_1 (dcr_q[1]),
        .iq_q_2 (dcr_q[2]), .iq_q_3 (dcr_q[3]),
        .iq_valid    (dcr_valid),
        .sf          (rb_sf_cfg),
        .sc_lock     (sc_lock),
        .energy_sum_0 (energy_sum[0]), .energy_sum_1 (energy_sum[1]),
        .energy_sum_2 (energy_sum[2]), .energy_sum_3 (energy_sum[3]),
        .energy_0 (energy_snap[0]), .energy_1 (energy_snap[1]),
        .energy_2 (energy_snap[2]), .energy_3 (energy_snap[3]),
        .energy_valid           (energy_valid),
        .energy_snapshot_valid  (energy_snapshot_valid)
    );

    // =========================================================================
    // Stage 4: Training Accumulator
    // =========================================================================
    wire signed [31:0] Z_i [0:3];
    wire signed [31:0] Z_q [0:3];
    wire signed [63:0] E_ref;
    wire               training_done;
    wire               noise_ready;
    wire [9:0]         n_acc;
    wire               rb_noise_en;

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
        .ref_sel    (2'b00),       // branch 0 is reference
        .noise_en   (rb_noise_en),
        .Z_i0 (Z_i[0]), .Z_q0 (Z_q[0]),
        .Z_i1 (Z_i[1]), .Z_q1 (Z_q[1]),
        .Z_i2 (Z_i[2]), .Z_q2 (Z_q[2]),
        .Z_i3 (Z_i[3]), .Z_q3 (Z_q[3]),
        .E_ref       (E_ref),
        .training_done (training_done),
        .noise_ready (noise_ready),
        .n_acc       (n_acc)
    );

    // =========================================================================
    // Stage 5: Noise Floor Estimator (feeds NW-MRC weight scaling)
    // =========================================================================
    wire [15:0] sigma2_hw [0:3];
    wire [15:0] sigma2_active [0:3];
    wire        sigma2_valid;
    wire [7:0]  n_updates_nfe;
    wire        noise_sample_en;   // driven by packet_ctrl_fsm

    noise_floor_est u_nfe (
        .clk_32m    (clk),
        .rst_n      (rst_n),
        .energy_sum_0 (energy_sum[0]), .energy_sum_1 (energy_sum[1]),
        .energy_sum_2 (energy_sum[2]), .energy_sum_3 (energy_sum[3]),
        .noise_sample_en   (noise_sample_en),
        .sf                (rb_sf_cfg),
        .noise_alpha_shift (rb_noise_alpha_shift),
        .sigma2_sw_0 (rb_sigma2_sw[63:48]),
        .sigma2_sw_1 (rb_sigma2_sw[47:32]),
        .sigma2_sw_2 (rb_sigma2_sw[31:16]),
        .sigma2_sw_3 (rb_sigma2_sw[15:0]),
        .sigma2_commit     (rb_sigma2_commit),
        .sigma2_src        (rb_sigma2_src),
        .agc_gain_changed  (1'b0),    // driven by AGC firmware via reg write; tie low for HW-only mode
        .sigma2_hw_0 (sigma2_hw[0]),  .sigma2_hw_1 (sigma2_hw[1]),
        .sigma2_hw_2 (sigma2_hw[2]),  .sigma2_hw_3 (sigma2_hw[3]),
        .sigma2_active_0 (sigma2_active[0]), .sigma2_active_1 (sigma2_active[1]),
        .sigma2_active_2 (sigma2_active[2]), .sigma2_active_3 (sigma2_active[3]),
        .sigma2_valid  (sigma2_valid),
        .n_updates     (n_updates_nfe)
    );

    // =========================================================================
    // Stage 6: Weight Generation FSM
    // =========================================================================
    wire signed [15:0] W_hw_re [0:3];
    wire signed [15:0] W_hw_im [0:3];
    wire               W_commit_hw;
    wire               wgen_hw_done;

    weight_gen u_wgen (
        .clk           (clk),
        .rst_n         (rst_n),
        .training_done (training_done),
        .Z_i0 (Z_i[0]), .Z_q0 (Z_q[0]),
        .Z_i1 (Z_i[1]), .Z_q1 (Z_q[1]),
        .Z_i2 (Z_i[2]), .Z_q2 (Z_q[2]),
        .Z_i3 (Z_i[3]), .Z_q3 (Z_q[3]),
        .n_acc         (n_acc),
        .wgt_src       (rb_wgt_src),
        .wgt_auto_commit (rb_wgt_auto_commit),
        .wgt_mode      (rb_wgt_mode),
        .antenna_en    (rb_antenna_en),
        // Calibration coefficients from reg_bank (4 branches × 2 bytes I + 2 bytes Q)
        .cal_re0 (rb_cal_coeff[127:112]),
        .cal_im0 (rb_cal_coeff[111:96]),
        .cal_re1 (rb_cal_coeff[95:80]),
        .cal_im1 (rb_cal_coeff[79:64]),
        .cal_re2 (rb_cal_coeff[63:48]),
        .cal_im2 (rb_cal_coeff[47:32]),
        .cal_re3 (rb_cal_coeff[31:16]),
        .cal_im3 (rb_cal_coeff[15:0]),
        // FW weight shadow from reg_bank (4 branches × re_hi/re_lo/im_hi/im_lo)
        .fw_W_re0 (rb_w_shadow[127:112]),
        .fw_W_im0 (rb_w_shadow[111:96]),
        .fw_W_re1 (rb_w_shadow[95:80]),
        .fw_W_im1 (rb_w_shadow[79:64]),
        .fw_W_re2 (rb_w_shadow[63:48]),
        .fw_W_im2 (rb_w_shadow[47:32]),
        .fw_W_re3 (rb_w_shadow[31:16]),
        .fw_W_im3 (rb_w_shadow[15:0]),
        .fw_W_commit   (rb_w_commit_pulse),
        .W_hw_re0 (W_hw_re[0]), .W_hw_im0 (W_hw_im[0]),
        .W_hw_re1 (W_hw_re[1]), .W_hw_im1 (W_hw_im[1]),
        .W_hw_re2 (W_hw_re[2]), .W_hw_im2 (W_hw_im[2]),
        .W_hw_re3 (W_hw_re[3]), .W_hw_im3 (W_hw_im[3]),
        .W_shadow_re0 (), .W_shadow_im0 (),
        .W_shadow_re1 (), .W_shadow_im1 (),
        .W_shadow_re2 (), .W_shadow_im2 (),
        .W_shadow_re3 (), .W_shadow_im3 (),
        .W_commit      (W_commit_hw),
        .wgen_hw_done  (wgen_hw_done),
        .wgen_active   (),
        .wgen_mode_dbg ()
    );

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
        .x_i0 (dcr_i[0]), .x_q0 (dcr_q[0]),
        .x_i1 (dcr_i[1]), .x_q1 (dcr_q[1]),
        .x_i2 (dcr_i[2]), .x_q2 (dcr_q[2]),
        .x_i3 (dcr_i[3]), .x_q3 (dcr_q[3]),
        .x_valid  (dcr_valid),
        .W_re0 (W_hw_re[0]), .W_im0 (W_hw_im[0]),
        .W_re1 (W_hw_re[1]), .W_im1 (W_hw_im[1]),
        .W_re2 (W_hw_re[2]), .W_im2 (W_hw_im[2]),
        .W_re3 (W_hw_re[3]), .W_im3 (W_hw_im[3]),
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
    // =========================================================================
    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (comb_y_i),
        .in_q     (comb_y_q),
        .in_valid (comb_y_valid),
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
        .psram_status_rb  (8'd0),
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
        .tx_gain_0       (rb_tx_gain_0),
        .tx_gain_1       (rb_tx_gain_1),
        .rx_gain_commit  (rb_rx_gain_commit),
        .wgt_src         (rb_wgt_src),
        .wgt_auto_commit (rb_wgt_auto_commit),
        .wgt_mode        (rb_wgt_mode),
        .w_commit_pulse  (rb_w_commit_pulse),
        .comb_post_gain_shift(rb_comb_post_gain_shift),
        .w_shadow        (rb_w_shadow),
        .cal_coeff       (rb_cal_coeff),
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
        .noise_en        (rb_noise_en)
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
        .noise_ready    (noise_ready),
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
