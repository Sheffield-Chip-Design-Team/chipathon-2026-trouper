// fpga_dsp_wrap.v
// FPGA emulation wrapper for the LoRa MIMO ASIC DSP chain.
// Instantiates the ASIC RTL (sd_decimator_cic_tdm8, dc_removal, psram_buf_ctrl,
// sc_detector, packet_ctrl_fsm, training_acc, mrc_combiner, sd_remod) and
// exposes a mode-selectable interface. Topology tracks trouper_top: TDM8
// decimator, firmware MRC weights via the fw_W_* registers (no on-chip
// weight_gen), noise power from training_acc Zdiag (no live noise_est), and the
// SC delay line / same-packet replay via external PSRAM (psram_buf_ctrl). The
// Arty has no PSRAM chip yet, so psram_model emulates the APS6404L in on-chip
// BRAM (validated by tb_psram_model).
//
// Mode register (mode[1:0]):
//   2'b00  DECIM_ETH  — 4× SX1257 → TDM8 decimator → eth_fifo
//                       (raw decimated I/Q, no further processing)
//   2'b01  FULL_DSP   — 4× SX1257 → full chain → combined I/Q → eth_fifo
//   2'b10  INJECT     — injected int8 I/Q (from inj FIFO) → full chain
//                       (bypasses the decimator; for pre-chip testing)
//
// Clock domain: single clock (clk = 32 MHz from MMCM).
// The ASIC RTL drives both clk_32m and clk_16m ports from the same 32 MHz
// clock, matching the strategy used in mimo_rx_top.v where "clk_16m = clk".
//
// PSRAM substitution: psram_model.v provides a BRAM-backed APS6404L QPI model
//   driven by psram_buf_ctrl, used until the external PSRAM PMOD board is ready.
//
// Source RTL directory (relative to this file): ../../rtl-test/

`default_nettype none

module fpga_dsp_wrap (
    input  wire        clk,
    input  wire        rst_n,

    // -----------------------------------------------------------------------
    // Mode select
    // -----------------------------------------------------------------------
    input  wire [1:0]  mode,          // 00=DECIM_ETH, 01=FULL_DSP, 10=INJECT

    // -----------------------------------------------------------------------
    // Configuration (all quasi-static, driven by axi_dsp_ctrl)
    // -----------------------------------------------------------------------
    input  wire [1:0]  decim_ratio,   // CIC ratio: 0=R256, 1=R128, 2=R64, 3=R32
    input  wire [3:0]  dc_alpha_shift,// DC removal leakage exponent
    input  wire        dc_bypass,     // 1 = bypass dc_removal
    input  wire [3:0]  sf,            // LoRa spreading factor 6-12
    input  wire [3:0]  antenna_en,    // active antennas bitmask
    input  wire [15:0] sc_thr,        // SC detector correlation threshold
    input  wire [2:0]  sc_hits_req,   // SC detector hit count for lock
    input  wire [1:0]  wgt_mode,      // 0=MRC, 1=EGC, 2=bypass
    input  wire        wgt_src,       // 0=HW computed, 1=FW-loaded weights
    input  wire        wgt_auto_commit,
    input  wire [1:0]  mimo_mode,     // 0=4-ant MRC, 1=single-ant bypass
    input  wire [7:0]  pkt_timeout_syms,
    input  wire [15:0] noise_thresh,
    input  wire [2:0]  comb_post_gain_shift,
    // Calibration coefficients (re+im per antenna, Q1.15 format)
    input  wire signed [15:0] cal_re0, cal_im0,
    input  wire signed [15:0] cal_re1, cal_im1,
    input  wire signed [15:0] cal_re2, cal_im2,
    input  wire signed [15:0] cal_re3, cal_im3,
    // Firmware-loaded MRC weights (Q1.15 format)
    input  wire signed [15:0] fw_W_re0, fw_W_im0,
    input  wire signed [15:0] fw_W_re1, fw_W_im1,
    input  wire signed [15:0] fw_W_re2, fw_W_im2,
    input  wire signed [15:0] fw_W_re3, fw_W_im3,
    input  wire        fw_W_commit,   // 1-cycle pulse: load fw weights

    // -----------------------------------------------------------------------
    // Hardware I/Q inputs (modes 00 and 01)
    // 1-bit sigma-delta streams at clk rate (32 MS/s from SX1257)
    // -----------------------------------------------------------------------
    input  wire [3:0]  hw_iq_i,       // I_DATA from SX1257[3:0]
    input  wire [3:0]  hw_iq_q,       // Q_DATA from SX1257[3:0]

    // -----------------------------------------------------------------------
    // Injection interface (mode 10)
    // int8 I/Q samples for all 4 antennas; consumed at rate-matched pace.
    // -----------------------------------------------------------------------
    input  wire signed [7:0] inj_i0, inj_q0,
    input  wire signed [7:0] inj_i1, inj_q1,
    input  wire signed [7:0] inj_i2, inj_q2,
    input  wire signed [7:0] inj_i3, inj_q3,
    input  wire        inj_valid,     // high = injection sample valid, consume it
    output wire        inj_ready,     // high = wrapper ready for injection

    // -----------------------------------------------------------------------
    // ETH output FIFO push interface (to axi_dsp_ctrl)
    // 64-bit: {i0,q0,i1,q1,i2,q2,i3,q3} in DECIM_ETH mode
    //         {y_i,y_q,sc_lock,training_done,W_commit,packet_active,8'b0,16'b0}
    //         in FULL_DSP / INJECT mode
    // -----------------------------------------------------------------------
    output reg  [63:0] eth_data,
    output reg         eth_push,
    input  wire        eth_full,

    // -----------------------------------------------------------------------
    // Status outputs (synchronous to clk, held until next update)
    // -----------------------------------------------------------------------
    output wire        sc_lock,
    output wire [31:0] timing_ref,
    output wire        training_done,
    output wire        W_commit,
    output wire        packet_active,
    output wire signed [15:0] W_re0, W_im0,
    output wire signed [15:0] W_re1, W_im1,
    output wire signed [15:0] W_re2, W_im2,
    output wire signed [15:0] W_re3, W_im3,
    output wire [15:0] energy0, energy1, energy2, energy3,

    // -----------------------------------------------------------------------
    // ΣΔ re-modulated output (FULL_DSP / INJECT modes)
    // Route to PMOD pins for oscilloscope / SX1302 connectivity testing.
    // -----------------------------------------------------------------------
    output wire        remod_i,
    output wire        remod_q
);

    // The FPGA AXI wrapper still exposes the legacy decim_ratio field. The
    // ASIC datapath now runs a fixed-rate decimator and uses sample_shift as
    // the BW selector: 1 = 250 kHz, 2 = 125 kHz. Preserve the old reset default
    // by treating decim_ratio[0]==0 as 250 kHz.
    wire [1:0] sample_shift = decim_ratio[0] ? 2'd2 : 2'd1;
    wire [3:0] tacc_window_syms = 4'd8;

    // =========================================================================
    // Stage 1: ΣΔ Decimator — shared TDM8 CIC N=3, fixed R=128 (matches
    // trouper_top). Replaces the 4× per-branch sd_decimator with the area-shared
    // TDM8 variant: all four 1-bit IQ streams in, 4×int8 packed out. The
    // decim_ratio input is no longer used (R is fixed at 128 in this variant).
    // =========================================================================
    wire signed [7:0] dec_i [0:3];
    wire signed [7:0] dec_q [0:3];
    wire [31:0]       dec_pack_i, dec_pack_q;
    wire [3:0]        dec_valid_all;

    sd_decimator_cic_tdm8 u_dec (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .iq_in_i  (hw_iq_i),
        .iq_in_q  (hw_iq_q),
        .iq_out_i (dec_pack_i),
        .iq_out_q (dec_pack_q),
        .iq_valid (dec_valid_all)
    );

    assign dec_i[0] = dec_pack_i[7:0];   assign dec_q[0] = dec_pack_q[7:0];
    assign dec_i[1] = dec_pack_i[15:8];  assign dec_q[1] = dec_pack_q[15:8];
    assign dec_i[2] = dec_pack_i[23:16]; assign dec_q[2] = dec_pack_q[23:16];
    assign dec_i[3] = dec_pack_i[31:24]; assign dec_q[3] = dec_pack_q[31:24];

    wire hw_dec_valid = |dec_valid_all;  // all 4 lanes update together

    // =========================================================================
    // Injection mux: select data source for the full DSP chain
    // DECIM_ETH (mode 0): source doesn't feed the chain — use hw anyway (idle)
    // FULL_DSP  (mode 1): hw decimator output
    // INJECT    (mode 2): injected int8 I/Q from axi_dsp_ctrl FIFO
    // =========================================================================
    wire signed [7:0] src_i [0:3];
    wire signed [7:0] src_q [0:3];
    wire              src_valid;

    wire use_inject = (mode == 2'b10);

    assign src_i[0] = use_inject ? inj_i0 : dec_i[0];
    assign src_i[1] = use_inject ? inj_i1 : dec_i[1];
    assign src_i[2] = use_inject ? inj_i2 : dec_i[2];
    assign src_i[3] = use_inject ? inj_i3 : dec_i[3];
    assign src_q[0] = use_inject ? inj_q0 : dec_q[0];
    assign src_q[1] = use_inject ? inj_q1 : dec_q[1];
    assign src_q[2] = use_inject ? inj_q2 : dec_q[2];
    assign src_q[3] = use_inject ? inj_q3 : dec_q[3];
    assign src_valid = use_inject ? inj_valid : hw_dec_valid;

    // Injection is always ready: DSP chain consumes at src_valid rate.
    assign inj_ready = !eth_full;   // stall injection if output FIFO is full

    // =========================================================================
    // Stage 2: DC Removal (always in the path for full chain modes)
    // =========================================================================
    wire signed [7:0] dcr_i [0:3];
    wire signed [7:0] dcr_q [0:3];
    wire              dcr_valid;

    dc_removal u_dcr (
        .clk_32m   (clk),
        .rst_n     (rst_n),
        .sample_i0 (src_i[0]), .sample_i1 (src_i[1]),
        .sample_i2 (src_i[2]), .sample_i3 (src_i[3]),
        .sample_q0 (src_q[0]), .sample_q1 (src_q[1]),
        .sample_q2 (src_q[2]), .sample_q3 (src_q[3]),
        .sample_valid     (src_valid),
        .sample_out_i0 (dcr_i[0]), .sample_out_i1 (dcr_i[1]),
        .sample_out_i2 (dcr_i[2]), .sample_out_i3 (dcr_i[3]),
        .sample_out_q0 (dcr_q[0]), .sample_out_q1 (dcr_q[1]),
        .sample_out_q2 (dcr_q[2]), .sample_out_q3 (dcr_q[3]),
        .sample_out_valid (dcr_valid)
    );

    // =========================================================================
    // Stage 3: Noise power readback (from training_acc Zdiag).
    // The live noise_est block has been removed to match trouper_top, where noise
    // qualification uses training_acc noise-mode windows instead. Zdiag_k =
    // Σ|raw_k|² ≈ σ²_k·n_acc in noise mode; surface its high word on the per-
    // branch energy[] readback outputs. zdiag[] is driven by u_tacc below.
    // =========================================================================
    wire [31:0] zdiag [0:3];
    wire [15:0] energy_snap [0:3];
    assign energy_snap[0] = zdiag[0][31:16];
    assign energy_snap[1] = zdiag[1][31:16];
    assign energy_snap[2] = zdiag[2][31:16];
    assign energy_snap[3] = zdiag[3][31:16];

    assign energy0 = energy_snap[0];
    assign energy1 = energy_snap[1];
    assign energy2 = energy_snap[2];
    assign energy3 = energy_snap[3];

    // Forward declarations — these are produced by later stages (sc_detector,
    // weight stage, packet_ctrl_fsm) but consumed by the PSRAM controller below.
    // The SC delay loop is inherently feedback (psram needs sc_lock; sc_detector
    // needs cur/del); default_nettype none requires explicit forward nets.
    wire        sc_lock_int;
    wire [31:0] timing_ref_int;
    wire        W_commit_int;
    wire        packet_active_int;

    // =========================================================================
    // Stage 4: SC delay line via PSRAM (psram_buf_ctrl + BRAM-backed model).
    // Matches trouper_top: the on-chip SRAM + frontend_buf_ctrl are replaced by
    // an external-PSRAM controller that streams every sample to PSRAM and reads
    // back the branch-0 N-sample-delayed pair for the SC detector, plus a
    // same-packet replay path into the combiner. The Arty has no PSRAM chip yet,
    // so psram_model emulates the APS6404L in on-chip BRAM (see tb_psram_model).
    // =========================================================================
    wire signed [7:0] cur_i0, cur_q0;   // branch-0 current sample
    wire signed [7:0] del_i0, del_q0;   // branch-0 N-sample-delayed sample
    wire              delayed_valid;

    // QPI pad nets between controller and the BRAM PSRAM model.
    wire        psram_sck, psram_ce_n;
    wire [3:0]  psram_sio_out, psram_sio_in, psram_sio_oe;

    // Replay outputs (muxed into the combiner during same-packet replay).
    wire signed [7:0] rpl_i [0:3];
    wire signed [7:0] rpl_q [0:3];
    wire              rpl_valid, psram_replay_active;

    // Free-running 32-bit IQ sample counter (used by psram_buf_ctrl for buf_base
    // and by packet_ctrl_fsm).
    reg [31:0] sample_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         sample_count <= 32'd0;
        else if (dcr_valid) sample_count <= sample_count + 32'd1;
    end

    // packet_end pulse = falling edge of packet_active (drives PSRAM replay end).
    reg packet_active_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) packet_active_prev <= 1'b0;
        else        packet_active_prev <= packet_active_int;
    end
    wire packet_end_pulse = packet_active_prev & ~packet_active_int;

    psram_buf_ctrl u_psram (
        .clk_32m      (clk),
        .rst_n        (rst_n),
        .psram_en     (1'b1),         // always capturing on the FPGA emulation
        .init_start   (1'b1),         // run QE init at power-up
        .qspi_owner   (1'b0),         // local controller always owns the pads
        .sf           (sf),
        .sample_shift (sample_shift),
        .iq_i0 (dcr_i[0]), .iq_i1 (dcr_i[1]),
        .iq_i2 (dcr_i[2]), .iq_i3 (dcr_i[3]),
        .iq_q0 (dcr_q[0]), .iq_q1 (dcr_q[1]),
        .iq_q2 (dcr_q[2]), .iq_q3 (dcr_q[3]),
        .iq_valid     (dcr_valid),
        .sc_lock      (sc_lock_int),
        .timing_ref   (timing_ref_int),
        .iq_sample_cnt(sample_count),
        .W_commit     (W_commit_int),
        .packet_end   (packet_end_pulse),
        .packet_active(packet_active_int),
        .clr_err      (1'b0),
        .sck     (psram_sck),
        .ce_n    (psram_ce_n),
        .sio_out (psram_sio_out),
        .sio_in  (psram_sio_in),
        .sio_oe  (psram_sio_oe),
        .cur_i0 (cur_i0), .cur_q0 (cur_q0),
        .del_i0 (del_i0), .del_q0 (del_q0),
        .del_valid (delayed_valid),
        .rpl_i0 (rpl_i[0]), .rpl_i1 (rpl_i[1]),
        .rpl_i2 (rpl_i[2]), .rpl_i3 (rpl_i[3]),
        .rpl_q0 (rpl_q[0]), .rpl_q1 (rpl_q[1]),
        .rpl_q2 (rpl_q[2]), .rpl_q3 (rpl_q[3]),
        .rpl_valid (rpl_valid),
        .buf_active    (),
        .replay_active (psram_replay_active),
        .qe_init_done  (),
        .replay_missed (),
        .overflow      (),
        .sample_skip   (),
        .state_dbg     (),
        .dbg_addr      (23'd0),
        .dbg_auto_inc  (1'b0),
        .dbg_rd_trig   (1'b0),
        .dbg_data_pop  (1'b0),
        .dbg_busy      (),
        .dbg_data      ()
    );

    // BRAM-backed APS6404L model (replaces the real chip until the PSRAM board
    // is ready). sck is unused in this same-domain model.
    psram_model #(.ADDR_BITS(16)) u_psram_mem (
        .clk_32m (clk),
        .rst_n   (rst_n),
        .ce_n    (psram_ce_n),
        .sio_out (psram_sio_out),
        .sio_oe  (psram_sio_oe),
        .sio_in  (psram_sio_in)
    );

    // =========================================================================
    // Stage 5a: SC Preamble Detector
    // =========================================================================
    assign sc_lock    = sc_lock_int;
    assign timing_ref = timing_ref_int;

    sc_detector u_sc (
        .clk          (clk),
        .rst_n        (rst_n),
        .iq_valid     (dcr_valid),
        .cur_i0 (cur_i0),
        .cur_q0 (cur_q0),
        .del_i0 (del_i0),
        .del_q0 (del_q0),
        .delayed_valid  (delayed_valid),
        .sf             (sf),
        .sample_shift   (sample_shift),
        .sc_thr         (sc_thr),
        .sc_hits_req    (sc_hits_req),
        .sc_clr         (1'b0),
        .sc_lock        (sc_lock_int),
        .timing_ref     (timing_ref_int),
        .c_i0 (), .c_q0 (),
        .sc_stat              (),
        .sc_hit_dbg           (),
        .sc_hit_count_dbg     (),
        .sc_first_hit_dbg     (),
        .sc_lock_sample_dbg   ()
    );

    // =========================================================================
    // Stage 5b: Training Accumulator
    // =========================================================================
    // training_acc now emits all-pairs cross-correlations (Zpair) plus the
    // diagonal autocorrelations (Zdiag), matching the ASIC trouper_top. In the
    // firmware-weight model these feed the host/firmware eigenvector path; the
    // FPGA emulation receives committed weights back via the fw_W_* registers,
    // so the Z outputs are left unconnected here.
    wire               training_done_int;

    assign training_done = training_done_int;

    training_acc u_tacc (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .raw_i0 (dcr_i[0]), .raw_i1 (dcr_i[1]),
        .raw_i2 (dcr_i[2]), .raw_i3 (dcr_i[3]),
        .raw_q0 (dcr_q[0]), .raw_q1 (dcr_q[1]),
        .raw_q2 (dcr_q[2]), .raw_q3 (dcr_q[3]),
        .sc_lock    (sc_lock_int),
        .timing_ref (timing_ref_int),
        .sf         (sf),
        .sample_shift (sample_shift),
        .tacc_window_syms (tacc_window_syms),
        .noise_trig (1'b0),
        .Zpair_i0 (), .Zpair_q0 (),
        .Zpair_i1 (), .Zpair_q1 (),
        .Zpair_i2 (), .Zpair_q2 (),
        .Zpair_i3 (), .Zpair_q3 (),
        .Zpair_i4 (), .Zpair_q4 (),
        .Zpair_i5 (), .Zpair_q5 (),
        .Zdiag_0 (zdiag[0]), .Zdiag_1 (zdiag[1]),
        .Zdiag_2 (zdiag[2]), .Zdiag_3 (zdiag[3]),
        .training_done (training_done_int),
        .n_acc          (),
        .training_armed ()
    );

    // =========================================================================
    // Stage 6: MRC weights (firmware-computed)
    // weight_gen has been removed from the ASIC (trouper_top): the eigenvector /
    // MRC weight computation now runs in firmware (or the host), and the result
    // is delivered through the fw_W_* registers with a fw_W_commit pulse marking
    // a fresh set. We surface the committed weights on the W_* status outputs
    // for read-back/debug. wgt_mode/wgt_src/wgt_auto_commit are no longer used.
    // =========================================================================
    assign W_commit_int = fw_W_commit;
    assign W_commit = W_commit_int;

    assign W_re0 = fw_W_re0; assign W_im0 = fw_W_im0;
    assign W_re1 = fw_W_re1; assign W_im1 = fw_W_im1;
    assign W_re2 = fw_W_re2; assign W_im2 = fw_W_im2;
    assign W_re3 = fw_W_re3; assign W_im3 = fw_W_im3;

    // =========================================================================
    // Stage 7: Packet Control FSM
    // =========================================================================
    wire        W_valid_set, W_missed_packet, combiner_source, safe_switch;
    wire [2:0]  packet_phase;
    wire [1:0]  active_mode;
    wire [3:0]  active_antenna_en;
    assign packet_active = packet_active_int;

    // W_valid SR: set by W_valid_set, clear when packet_active deasserts
    reg W_valid;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           W_valid <= 1'b0;
        else if (W_valid_set) W_valid <= 1'b1;
        else if (!packet_active_int) W_valid <= 1'b0;
    end

    packet_ctrl_fsm u_pcfsm (
        .clk               (clk),
        .rst_n             (rst_n),
        .iq_valid          (dcr_valid),
        .sample_count      (sample_count),
        .sf                (sf),
        .sample_shift      (sample_shift),
        .sc_lock           (sc_lock_int),
        .timing_ref        (timing_ref_int),
        .training_done     (training_done_int),
        .W_commit          (W_commit_int),
        .mode_shadow       (mimo_mode),
        .antenna_en_shadow (antenna_en),
        .psram_en          (1'b0),
        .psram_replay_active (1'b0),
        .pkt_timeout_syms  (pkt_timeout_syms),
        .tacc_window_syms  (tacc_window_syms),
        .safe_switch        (safe_switch),
        .W_valid_set        (W_valid_set),
        .W_missed_packet    (W_missed_packet),
        .combiner_source    (combiner_source),
        .psram_packet_arm   (),
        .psram_replay_start (),
        .psram_abort        (),
        .payload_rd_base    (),
        .buf_freeze         (),   // unused: SC delay now via PSRAM, not frontend_buf
        .packet_phase       (packet_phase),
        .packet_active      (packet_active_int),
        .active_mode        (active_mode),
        .active_antenna_en  (active_antenna_en)
    );

    // =========================================================================
    // Stage 8: MRC Combiner
    // =========================================================================
    wire signed [7:0] comb_y_i, comb_y_q;
    wire              comb_y_valid;

    wire [1:0] bypass_ant = active_antenna_en[1] ? 2'd1 :
                            active_antenna_en[2] ? 2'd2 :
                            active_antenna_en[3] ? 2'd3 : 2'd0;

    // Combiner input mux: live decimator IQ normally, PSRAM replay IQ during
    // same-packet replay (matches trouper_top).
    wire signed [7:0] comb_xi [0:3];
    wire signed [7:0] comb_xq [0:3];
    genvar gc;
    generate for (gc = 0; gc < 4; gc = gc + 1) begin : g_comb_mux
        assign comb_xi[gc] = psram_replay_active ? rpl_i[gc] : dcr_i[gc];
        assign comb_xq[gc] = psram_replay_active ? rpl_q[gc] : dcr_q[gc];
    end endgenerate
    wire comb_xvalid = psram_replay_active ? rpl_valid : dcr_valid;

    mrc_combiner u_comb (
        .clk_16m (clk),
        .rst_n   (rst_n),
        .x_i0 (comb_xi[0]), .x_q0 (comb_xq[0]),
        .x_i1 (comb_xi[1]), .x_q1 (comb_xq[1]),
        .x_i2 (comb_xi[2]), .x_q2 (comb_xq[2]),
        .x_i3 (comb_xi[3]), .x_q3 (comb_xq[3]),
        .x_valid  (comb_xvalid),
        .W_re0 (fw_W_re0[15:8]), .W_im0 (fw_W_im0[15:8]),
        .W_re1 (fw_W_re1[15:8]), .W_im1 (fw_W_im1[15:8]),
        .W_re2 (fw_W_re2[15:8]), .W_im2 (fw_W_im2[15:8]),
        .W_re3 (fw_W_re3[15:8]), .W_im3 (fw_W_im3[15:8]),
        .W_valid          (W_valid),
        .mode             (active_mode[0]),
        .bypass_ant       (bypass_ant),
        .post_gain_shift  (comb_post_gain_shift),
        .y_i    (comb_y_i),
        .y_q    (comb_y_q),
        .y_valid(comb_y_valid)
    );

    // =========================================================================
    // Stage 9: ΣΔ Re-modulator
    // =========================================================================
    sd_remod u_remod (
        .clk_32m  (clk),
        .rst_n    (rst_n),
        .in_i     (comb_y_i),
        .in_q     (comb_y_q),
        .in_valid (comb_y_valid),
        .en       ((mode == 2'b01) || (mode == 2'b10)),
        .out_i    (remod_i),
        .out_q    (remod_q)
    );

    // =========================================================================
    // ETH FIFO push mux
    // DECIM_ETH (mode 0): push raw 4-ch int8 I/Q on every hw_dec_valid
    // FULL_DSP / INJECT (mode 1/2): push combined y_i/y_q on comb_y_valid
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eth_data <= 64'h0;
            eth_push <= 1'b0;
        end else begin
            eth_push <= 1'b0;

            case (mode)
                2'b00: begin
                    // DECIM_ETH: pack all 4 channels, push on decimator strobe
                    if (hw_dec_valid && !eth_full) begin
                        eth_data <= { dec_i[0], dec_q[0],
                                      dec_i[1], dec_q[1],
                                      dec_i[2], dec_q[2],
                                      dec_i[3], dec_q[3] };
                        eth_push <= 1'b1;
                    end
                end

                2'b01, 2'b10: begin
                    // FULL_DSP / INJECT: push combined output
                    if (comb_y_valid && !eth_full) begin
                        eth_data <= { comb_y_i, comb_y_q,
                                      sc_lock_int,
                                      training_done_int,
                                      W_commit_int,
                                      packet_active_int,
                                      2'b00,              // reserved
                                      8'h00,              // reserved
                                      16'h0000 };         // reserved
                        eth_push <= 1'b1;
                    end
                end

                default: eth_push <= 1'b0;
            endcase
        end
    end

endmodule
`default_nettype wire
