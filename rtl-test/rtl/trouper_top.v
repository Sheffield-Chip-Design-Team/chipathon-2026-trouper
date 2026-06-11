// trouper_top.v
// Standalone Trouper top-level integration
// GF180MCU 3.3V 32 MHz — SSCS PICO Chipathon 2026
//
// Pad count: 22 signal + 3 power = 25 total (at Chipathon limit)
//            clk/rst×2, IQ×8, remod×2, PSRAM SCK+CE_N×2,
//            SPI HOST_CS/SCK/MOSI/MISO×4,
//            JTAG/PSRAM-SIO/IRQ TCK_IRQ/TMS/TDI/TDO×4 (shared pads)
//            VDD_IO/VDD_CORE/GND×3. CS_A removed (SPI master not present).
//
// Signal flow:
//   SX1257[0..3] 1-bit IQ → sd_decimator×4 → dc_removal → psram_buf_ctrl
//   (cur/del via PSRAM) → sc_detector → training_acc → [SW weights via reg_bank] → mrc_combiner
//   → sd_remod → SX1302 Radio A (1-bit IQ)
//
// Control plane:
//   Host RPi → SPI slave (HOST_CS/SCK/MOSI/MISO pads) → reg_bank byte interface
//   Grouper  → GRP_ADDR/WDATA/WE/RE/RDATA/READY inter-chip bus → reg_bank (priority)
//   IRQ: irq_out (sticky) → IRQ_OUT pad (TCK_IRQ when JTAG_EN=0) + IRQ_GROUPER inter-chip

`ifndef TROUPER_TOP_V
`define TROUPER_TOP_V

`default_nettype none

module trouper_top (
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

    // ---- Host SPI slave (RPi) ----
    input  wire        HOST_CS,       // active-low chip select from RPi
    input  wire        SPI_SCK,       // SPI clock (Mode 0, up to 10 MHz)
    input  wire        SPI_MOSI,
    output wire        SPI_MISO,

    // ---- Grouper inter-project register bus (priority over SPI) ----
    input  wire [7:0]  GRP_ADDR,
    input  wire [7:0]  GRP_WDATA,
    input  wire        GRP_WE,
    input  wire        GRP_RE,
    output wire [7:0]  GRP_RDATA,
    output wire        GRP_READY,

    // ---- Interrupt outputs ----
    output wire        IRQ_OUT,       // → TCK_IRQ pad (when JTAG_EN=0); sticky, level-high
    output wire        IRQ_GROUPER    // → Grouper inter-project IRQ line; same signal as IRQ_OUT
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
    wire [7:0]  cfg_rdata_w;
    wire [7:0]  rb_peek_rdata_w;
    wire        cfg_ready_w;
    wire [1:0]  rb_mimo_mode;
    wire [3:0]  rb_antenna_en;
    wire [3:0]  rb_sf_cfg;
    wire [1:0]  rb_decim_ratio;
    wire [15:0] rb_sc_thr;
    wire [1:0]  rb_sc_hits_req;
    wire [7:0]  rb_pkt_timeout_syms;
    wire [7:0]  rb_rx_gain_shadow_0, rb_rx_gain_shadow_1,
                rb_rx_gain_shadow_2, rb_rx_gain_shadow_3;
    wire        rb_rx_gain_commit;
    reg  [7:0]  rx_gain_active_r [0:3];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_gain_active_r[0] <= 8'h3E;
            rx_gain_active_r[1] <= 8'h3E;
            rx_gain_active_r[2] <= 8'h3E;
            rx_gain_active_r[3] <= 8'h3E;
        end else if (rb_rx_gain_commit) begin
            rx_gain_active_r[0] <= rb_rx_gain_shadow_0;
            rx_gain_active_r[1] <= rb_rx_gain_shadow_1;
            rx_gain_active_r[2] <= rb_rx_gain_shadow_2;
            rx_gain_active_r[3] <= rb_rx_gain_shadow_3;
        end
    end
    wire        rb_w_commit_pulse;
    wire [2:0]  rb_comb_post_gain_shift;
    wire [1:0]  rb_remod_backoff_shift;
    wire [127:0] rb_w_shadow;
    wire [3:0]  rb_psram_ctrl;
    wire [22:0] rb_psram_dbg_addr;
    wire        rb_psram_dbg_auto_inc;
    wire        rb_psram_dbg_rd_trig;
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
    // Stage 3a: SC detector delay-line signals (now provided by psram_buf_ctrl)
    // The on-chip FD SRAM (512×8, 209K µm²) and frontend_buf_ctrl have been
    // removed.  psram_buf_ctrl writes all 8 bytes/sample to PSRAM continuously
    // and reads back del_i0/del_q0 (branch 0, N-sample delayed) in the same
    // 44-sub-cycle window; cur_i0/cur_q0 are captured from the write data.
    // =========================================================================
    wire signed [7:0] psram_cur_i0, psram_cur_q0;  // branch 0, current sample
    wire signed [7:0] psram_del_i0, psram_del_q0;  // branch 0, N-sample delayed
    wire              psram_del_valid;               // pulses when cur/del pair ready
    wire        buf_freeze;  // driven by packet_ctrl_fsm (unused without fbuf, kept for FSM)
    wire        sc_lock;    // declared here to avoid forward-reference; driven by u_sc

    // =========================================================================
    // Stage 3b: Schmidl-Cox preamble detector
    // =========================================================================
    wire [31:0] timing_ref;
    wire [15:0] sc_stat;
    wire        sc_hit_dbg;
    wire [1:0]  sc_hit_cnt_dbg;
    wire [31:0] sc_first_hit_dbg, sc_lock_snap_dbg;

    sc_detector u_sc (
        .clk          (clk),
        .rst_n        (rst_n),
        .iq_valid     (dcr_valid),
        .cur_i0 (psram_cur_i0),
        .cur_q0 (psram_cur_q0),
        .del_i0 (psram_del_i0),
        .del_q0 (psram_del_q0),
        .delayed_valid  (psram_del_valid),
        .sf             (rb_sf_cfg),
        .sc_thr         (rb_sc_thr),
        .sc_hits_req    (rb_sc_hits_req),
        .sc_lock        (sc_lock),
        .timing_ref     (timing_ref),
        .c_i0 (), .c_q0 (),
        .sc_stat              (sc_stat),
        .sc_hit_dbg           (sc_hit_dbg),
        .sc_hit_count_dbg     (sc_hit_cnt_dbg),
        .sc_first_hit_dbg     (sc_first_hit_dbg),
        .sc_lock_sample_dbg   (sc_lock_snap_dbg)
    );

    // =========================================================================
    // Stage 3c: Legacy energy-snapshot path removed.
    //
    // Noise qualification now uses training_acc noise-mode windows plus SC
    // contamination tracking instead of a live noise_est block.
    //
    // TODO(timing/logic verification): validate that the accepted-noise window
    // semantics below match firmware expectations, especially around sc_hit_dbg
    // timing versus training_done commit.
    // =========================================================================
    // =========================================================================
    // Stage 4: Training Accumulator
    // =========================================================================
    // Individual Z_kl pairs → reg_bank firmware eigenvector path
    wire signed [31:0] Zpair_i [0:5];
    wire signed [31:0] Zpair_q [0:5];
    // Z_kk diagonal autocorrelation → reg_bank noise estimation
    wire [31:0]        Zdiag [0:3];
    wire               training_done;
    wire [14:0]        n_acc;
    wire               training_armed;
    wire               rb_noise_trig;    // firmware-triggered noise measurement pulse

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
        .noise_trig (rb_noise_trig),
        .Zpair_i0 (Zpair_i[0]), .Zpair_q0 (Zpair_q[0]),
        .Zpair_i1 (Zpair_i[1]), .Zpair_q1 (Zpair_q[1]),
        .Zpair_i2 (Zpair_i[2]), .Zpair_q2 (Zpair_q[2]),
        .Zpair_i3 (Zpair_i[3]), .Zpair_q3 (Zpair_q[3]),
        .Zpair_i4 (Zpair_i[4]), .Zpair_q4 (Zpair_q[4]),
        .Zpair_i5 (Zpair_i[5]), .Zpair_q5 (Zpair_q[5]),
        .Zdiag_0  (Zdiag[0]),   .Zdiag_1  (Zdiag[1]),
        .Zdiag_2  (Zdiag[2]),   .Zdiag_3  (Zdiag[3]),
        .training_done   (training_done),
        .n_acc           (n_acc),
        .training_armed  (training_armed)
    );

    // =========================================================================
    // Stage 5: sigma2 register path.
    // sigma2_hw[0..3] are repurposed to carry Z_23 (pair 5) at reg_bank 0xE0-0xE7:
    //   sigma2_hw[0] = Zpair_i5[31:16], [1] = Zpair_i5[15:0]
    //   sigma2_hw[2] = Zpair_q5[31:16], [3] = Zpair_q5[15:0]
    // sigma2_valid pulses when a firmware-triggered noise window completes without SC contamination.
    // =========================================================================
    wire [15:0] sigma2_hw [0:3];
    wire        sigma2_valid;
    reg         noise_window_active;
    reg         noise_window_sc_seen;
    reg         sigma2_valid_r;

    assign sigma2_hw[0] = Zpair_i[5][31:16];
    assign sigma2_hw[1] = Zpair_i[5][15:0];
    assign sigma2_hw[2] = Zpair_q[5][31:16];
    assign sigma2_hw[3] = Zpair_q[5][15:0];

    // Firmware-triggered noise measurements reuse training_acc noise mode.
    // Accept the resulting Zdiag window only if no SC activity appeared while
    // the measurement was in flight.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_window_active  <= 1'b0;
            noise_window_sc_seen <= 1'b0;
            sigma2_valid_r       <= 1'b0;
        end else begin
            sigma2_valid_r <= 1'b0;

            if (rb_noise_trig) begin
                noise_window_active  <= 1'b1;
                noise_window_sc_seen <= 1'b0;
            end else if (noise_window_active && (sc_hit_dbg || sc_lock)) begin
                noise_window_sc_seen <= 1'b1;
            end

            if (noise_window_active && training_done) begin
                sigma2_valid_r       <= ~noise_window_sc_seen && !sc_lock;
                noise_window_active  <= 1'b0;
                noise_window_sc_seen <= 1'b0;
            end
        end
    end

    assign sigma2_valid = sigma2_valid_r;

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
        .active_antenna_en (active_antenna_en)
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
        .init_start   (rb_psram_ctrl[0] & ~rb_psram_ctrl[3]),
        .qspi_owner   (rb_psram_ctrl[3]),
        .packet_active(packet_active),
        .sf           (rb_sf_cfg),
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
        // SC delay-line outputs (replace frontend_buf_ctrl + on-chip SRAM)
        .cur_i0       (psram_cur_i0),
        .cur_q0       (psram_cur_q0),
        .del_i0       (psram_del_i0),
        .del_q0       (psram_del_q0),
        .del_valid    (psram_del_valid),
        // Replay outputs
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
        .state_dbg    (psram_state_dbg),
        .dbg_addr     (rb_psram_dbg_addr),
        .dbg_auto_inc (rb_psram_dbg_auto_inc),
        .dbg_rd_trig  (rb_psram_dbg_rd_trig),
        .dbg_data_pop (spi_reg_re && (spi_reg_re_addr == 8'hB9)),
        .dbg_busy     (psram_dbg_busy_w),
        .dbg_data     (psram_dbg_data_w)
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

    // Edge-detect packet_done (falling edge of packet_active = packet FSM returned to IDLE)
    reg packet_active_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) packet_active_r <= 1'b0;
        else        packet_active_r <= packet_active;
    wire packet_done_pulse = packet_active_r && !packet_active;

    // irq_set for reg_bank: level signals; reg_bank latches rising edges into sticky bits
    wire [7:0] rb_irq_set = {1'b0, 1'b0, 1'b0, 1'b0,
                             packet_done_pulse, W_missed_packet, training_done, sc_lock};

    // =========================================================================
    // SPI slave instantiation
    // =========================================================================
    wire [7:0] spi_reg_wr_addr;
    wire [7:0] spi_reg_wdata;
    wire       spi_reg_we;
    wire [7:0] spi_reg_rd_addr;
    wire [7:0] spi_reg_re_addr;
    wire       spi_reg_re;
    wire [7:0] spi_reg_rdata;
    wire       psram_dbg_busy_w;
    wire [7:0] psram_dbg_data_w;

    spi_slave u_spi (
        .clk_32m     (clk),
        .rst_n       (rst_n),
        .HOST_CS     (HOST_CS),
        .SPI_SCK     (SPI_SCK),
        .SPI_MOSI    (SPI_MOSI),
        .SPI_MISO    (SPI_MISO),
        .reg_wr_addr (spi_reg_wr_addr),
        .reg_wdata   (spi_reg_wdata),
        .reg_we      (spi_reg_we),
        .reg_rd_addr (spi_reg_rd_addr),
        .reg_re_addr (spi_reg_re_addr),
        .reg_re      (spi_reg_re),
        .reg_rdata   (spi_reg_rdata),
        // Firmware-load port: not connected (no on-chip CPU SRAM in Trouper)
        .fw_ld_addr  (),
        .fw_ld_wdata (),
        .fw_ld_we    (),
        .fw_ld_rdata (8'h00),
        .fw_ld_req   (),
        .fw_ld_ready (1'b1)
    );

    // =========================================================================
    // Register bus arbiter: Grouper (GRP_*) has priority over SPI slave
    // =========================================================================
    wire grp_active = GRP_WE | GRP_RE;

    wire [7:0] rb_addr  = grp_active ? GRP_ADDR :
                          (spi_reg_we ? spi_reg_wr_addr : spi_reg_rd_addr);
    wire [7:0] rb_wdata = grp_active ? GRP_WDATA : spi_reg_wdata;
    wire       rb_we    = grp_active ? GRP_WE    : spi_reg_we;
    wire       rb_re    = GRP_RE;

    assign GRP_RDATA = cfg_rdata_w;
    assign GRP_READY = cfg_ready_w;
    assign spi_reg_rdata = rb_peek_rdata_w;

    // ---- Register Bank ----
    wire rb_irq_out_sticky;
    assign IRQ_OUT     = rb_irq_out_sticky;
    assign IRQ_GROUPER = rb_irq_out_sticky;

    reg_bank u_rb (
        .clk        (clk),
        .rst_n      (rst_n),
        .addr       (rb_addr),
        .wdata      (rb_wdata),
        .we         (rb_we),
        .re         (rb_re),
        .rdata      (cfg_rdata_w),
        .peek_rdata (rb_peek_rdata_w),
        .ready      (cfg_ready_w),
        .irq_out    (rb_irq_out_sticky),
        // Hardware status inputs
        .gpio_in    (3'b000),
        .cpu_sram_status (6'd0),
        .buf_mode        (2'b00),   // frontend_buf_ctrl removed
        .buf_valid       (1'b0),
        .sram0_bist_pass (1'b1),
        .sram1_bist_pass (1'b1),
        .buf_freeze      (buf_freeze),
        .buf_wr_ptr      (7'd0),
        .rx_gain_active_0 (rx_gain_active_r[0]), .rx_gain_active_1 (rx_gain_active_r[1]),
        .rx_gain_active_2 (rx_gain_active_r[2]), .rx_gain_active_3 (rx_gain_active_r[3]),
        .rx_gain_pending  (rb_rx_gain_commit),
        .rx_gain_owner    (1'b1),
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
        .corr_mag_0 (16'd0), .corr_mag_1 (16'd0),
        .corr_mag_2 (16'd0), .corr_mag_3 (16'd0),
        .sc_stat         (sc_stat),
        .training_armed  (training_armed),
        .n_acc           (n_acc),
        .z_shift         (6'd0),
        .c_pool_i        (16'd0),
        .c_pool_q        (16'd0),
        .cfo_diag        (16'd0),
        .zpair_i0 (Zpair_i[0]), .zpair_q0 (Zpair_q[0]),
        .zpair_i1 (Zpair_i[1]), .zpair_q1 (Zpair_q[1]),
        .zpair_i2 (Zpair_i[2]), .zpair_q2 (Zpair_q[2]),
        .zpair_i3 (Zpair_i[3]), .zpair_q3 (Zpair_q[3]),
        .zpair_i4 (Zpair_i[4]), .zpair_q4 (Zpair_q[4]),
        .zdiag_0  (Zdiag[0]),   .zdiag_1  (Zdiag[1]),
        .zdiag_2  (Zdiag[2]),   .zdiag_3  (Zdiag[3]),
        .sc_hit_dbg          (sc_hit_dbg),
        .sc_hit_count_dbg    (sc_hit_cnt_dbg),
        .sc_lock_dbg         (sc_lock),
        .sc_first_hit_dbg    (sc_first_hit_dbg),
        .sc_lock_snap_dbg    (sc_lock_snap_dbg),
        .sigma2_hw_0 (sigma2_hw[0]), .sigma2_hw_1 (sigma2_hw[1]),
        .sigma2_hw_2 (sigma2_hw[2]), .sigma2_hw_3 (sigma2_hw[3]),
        .psram_status_rb  ({psram_buf_active, psram_overflow,
                            psram_replay_missed, psram_replay_active_w,
                            psram_qe_init_done, psram_state_dbg}),
        .psram_pkt_bytes  (16'd0),
        .psram_rd_offset  (8'd0),
        .psram_dbg_busy   (psram_dbg_busy_w),
        .psram_dbg_data   (psram_dbg_data_w),
        // Hardware control outputs
        .cpu_reset       (rb_cpu_reset),
        .jtag_en         (rb_jtag_en),
        .gpio_dir        (rb_gpio_dir),
        .gpio_out        (rb_gpio_out),
        .cpu_sram_ctrl   (rb_cpu_sram_ctrl),
        .mimo_mode       (rb_mimo_mode),
        .antenna_en      (rb_antenna_en),
        .sf_cfg          (rb_sf_cfg),
        .decim_ratio     (rb_decim_ratio),
        .bist_run        (),
        .sc_thr          (rb_sc_thr),
        .sc_hits_req     (rb_sc_hits_req),
        .energy_gate_en  (),
        .energy_thr      (),
        .pkt_timeout_syms(rb_pkt_timeout_syms),
        .rx_gain_shadow_0(rb_rx_gain_shadow_0),
        .rx_gain_shadow_1(rb_rx_gain_shadow_1),
        .rx_gain_shadow_2(rb_rx_gain_shadow_2),
        .rx_gain_shadow_3(rb_rx_gain_shadow_3),
        .rx_gain_commit  (rb_rx_gain_commit),
        .wgt_src         (),
        .wgt_auto_commit (),
        .wgt_mode        (),
        .w_commit_pulse  (rb_w_commit_pulse),
        .comb_post_gain_shift(rb_comb_post_gain_shift),
        .remod_backoff_shift(rb_remod_backoff_shift),
        .w_shadow        (rb_w_shadow),
        .psram_ctrl      (rb_psram_ctrl),
        .psram_dbg_addr  (rb_psram_dbg_addr),
        .psram_dbg_auto_inc(rb_psram_dbg_auto_inc),
        .psram_dbg_rd_trig(rb_psram_dbg_rd_trig),
        .noise_en        (),
        .ref_sel         (rb_ref_sel),
        .noise_trig      (rb_noise_trig)
    );

endmodule

`default_nettype wire

`endif
