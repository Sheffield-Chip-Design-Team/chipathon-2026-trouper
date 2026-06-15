// fpga_dsp_wrap.v
// FPGA emulation wrapper for the LoRa MIMO ASIC DSP chain.
// Instantiates the full ASIC RTL (sd_decimator, dc_removal, frontend_buf_ctrl,
// noise_est, sc_detector, packet_ctrl_fsm, training_acc, mrc_combiner,
// sd_remod) and exposes a mode-selectable interface. MRC weights are computed
// in firmware/host and delivered via the fw_W_* registers (no on-chip
// weight_gen, matching trouper_top).
//
// Mode register (mode[1:0]):
//   2'b00  DECIM_ETH  — 4× SX1257 → sd_decimator × 4 → eth_fifo
//                       (raw decimated I/Q, no further processing)
//   2'b01  FULL_DSP   — 4× SX1257 → full chain → combined I/Q → eth_fifo
//   2'b10  INJECT     — injected int8 I/Q (from inj FIFO) → full chain
//                       (bypasses sd_decimator; for pre-chip testing)
//
// Clock domain: single clock (clk = 32 MHz from MMCM).
// The ASIC RTL drives both clk_32m and clk_16m ports from the same 32 MHz
// clock, matching the strategy used in mimo_rx_top.v where "clk_16m = clk".
//
// SRAM substitution: fpga_sram512x8.v provides the module
//   gf180mcu_ocd_ip_sram__sram512x8m8wm1 with a BRAM implementation,
//   same interface as the ASIC macro blackbox.
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

    // =========================================================================
    // Stage 1: ΣΔ Decimators × 4
    // Both clk_32m and clk_16m tied to clk (32 MHz), matching mimo_rx_top.v.
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
                .iq_in_i     (hw_iq_i[g]),
                .iq_in_q     (hw_iq_q[g]),
                .decim_ratio (decim_ratio),
                .iq_out_i    (dec_i[g]),
                .iq_out_q    (dec_q[g]),
                .iq_valid    (dec_valid[g])
            );
        end
    endgenerate

    wire hw_dec_valid = dec_valid[0];  // all 4 are synchronous, use ch0 as strobe

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
        .raw_i0 (src_i[0]), .raw_i1 (src_i[1]),
        .raw_i2 (src_i[2]), .raw_i3 (src_i[3]),
        .raw_q0 (src_q[0]), .raw_q1 (src_q[1]),
        .raw_q2 (src_q[2]), .raw_q3 (src_q[3]),
        .raw_valid (src_valid),
        .out_i0 (dcr_i[0]), .out_i1 (dcr_i[1]),
        .out_i2 (dcr_i[2]), .out_i3 (dcr_i[3]),
        .out_q0 (dcr_q[0]), .out_q1 (dcr_q[1]),
        .out_q2 (dcr_q[2]), .out_q3 (dcr_q[3]),
        .out_valid (dcr_valid)
    );

    // =========================================================================
    // Stage 3: Noise Estimation (Manhattan norm; feeds packet_ctrl_fsm threshold)
    // noise_snap[k] is 8-bit; zero-pad to 16-bit for downstream consumers.
    // =========================================================================
    wire [7:0]  noise_snap [0:3];
    wire [15:0] energy_snap [0:3];
    assign energy_snap[0] = {noise_snap[0], 8'h0};
    assign energy_snap[1] = {noise_snap[1], 8'h0};
    assign energy_snap[2] = {noise_snap[2], 8'h0};
    assign energy_snap[3] = {noise_snap[3], 8'h0};

    noise_est u_nest (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .sc_lock    (sc_lock_int),
        .dcr_i0 (dcr_i[0]), .dcr_i1 (dcr_i[1]),
        .dcr_i2 (dcr_i[2]), .dcr_i3 (dcr_i[3]),
        .dcr_q0 (dcr_q[0]), .dcr_q1 (dcr_q[1]),
        .dcr_q2 (dcr_q[2]), .dcr_q3 (dcr_q[3]),
        .noise_snap_0 (noise_snap[0]), .noise_snap_1 (noise_snap[1]),
        .noise_snap_2 (noise_snap[2]), .noise_snap_3 (noise_snap[3])
    );

    assign energy0 = energy_snap[0];
    assign energy1 = energy_snap[1];
    assign energy2 = energy_snap[2];
    assign energy3 = energy_snap[3];

    // =========================================================================
    // Stage 4: Frontend Buffer Controller
    // Drives two 512×8 SRAMs (BRAM on FPGA, macro on ASIC).
    // =========================================================================
    wire [8:0]  sram0_A, sram1_A;
    wire [7:0]  sram0_D, sram1_D;
    wire [7:0]  sram0_Q, sram1_Q;
    wire        sram0_CEN, sram1_CEN;
    wire        sram0_GWEN, sram1_GWEN;

    gf180mcu_ocd_ip_sram__sram512x8m8wm1 u_sram0 (
        .CLK (clk), .CEN (sram0_CEN), .GWEN (sram0_GWEN),
        .WEN (8'h00), .A (sram0_A), .D (sram0_D), .Q (sram0_Q)
    );
    gf180mcu_ocd_ip_sram__sram512x8m8wm1 u_sram1 (
        .CLK (clk), .CEN (sram1_CEN), .GWEN (sram1_GWEN),
        .WEN (8'h00), .A (sram1_A), .D (sram1_D), .Q (sram1_Q)
    );

    wire signed [7:0] cur_i [0:3];
    wire signed [7:0] cur_q [0:3];
    wire signed [7:0] del_i [0:3];
    wire signed [7:0] del_q [0:3];
    wire              delayed_valid, buf_valid;
    wire [1:0]        buf_mode;
    wire [6:0]        buf_wr_ptr;
    wire              buf_freeze;  // driven by packet_ctrl_fsm

    frontend_buf_ctrl u_fbuf (
        .clk        (clk),
        .rst_n      (rst_n),
        .iq_valid   (dcr_valid),
        .in_i0 (dcr_i[0]), .in_i1 (dcr_i[1]),
        .in_i2 (dcr_i[2]), .in_i3 (dcr_i[3]),
        .in_q0 (dcr_q[0]), .in_q1 (dcr_q[1]),
        .in_q2 (dcr_q[2]), .in_q3 (dcr_q[3]),
        .sf         (sf),
        .sc_lock    (sc_lock),
        .buf_freeze (buf_freeze),
        .sram0_A  (sram0_A),  .sram0_D (sram0_D),  .sram0_Q (sram0_Q),
        .sram0_CEN(sram0_CEN),.sram0_GWEN(sram0_GWEN),
        .sram1_A  (sram1_A),  .sram1_D (sram1_D),  .sram1_Q (sram1_Q),
        .sram1_CEN(sram1_CEN),.sram1_GWEN(sram1_GWEN),
        .cur_i0 (cur_i[0]), .cur_i1 (cur_i[1]),
        .cur_i2 (cur_i[2]), .cur_i3 (cur_i[3]),
        .cur_q0 (cur_q[0]), .cur_q1 (cur_q[1]),
        .cur_q2 (cur_q[2]), .cur_q3 (cur_q[3]),
        .del_i0 (del_i[0]), .del_i1 (del_i[1]),
        .del_i2 (del_i[2]), .del_i3 (del_i[3]),
        .del_q0 (del_q[0]), .del_q1 (del_q[1]),
        .del_q2 (del_q[2]), .del_q3 (del_q[3]),
        .delayed_valid (delayed_valid),
        .buf_mode      (buf_mode),
        .buf_valid     (buf_valid),
        .wr_ptr        (buf_wr_ptr)
    );

    // =========================================================================
    // Stage 5a: SC Preamble Detector
    // =========================================================================
    wire [31:0] timing_ref_int;
    wire        sc_lock_int;
    assign sc_lock    = sc_lock_int;
    assign timing_ref = timing_ref_int;

    // Free-running 32-bit sample counter for packet_ctrl_fsm
    reg [31:0] sample_count;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sample_count <= 32'd0;
        else if (dcr_valid) sample_count <= sample_count + 32'd1;
    end

    sc_detector u_sc (
        .clk          (clk),
        .rst_n        (rst_n),
        .iq_valid     (dcr_valid),
        .cur_i0 (cur_i[0]),
        .cur_q0 (cur_q[0]),
        .del_i0 (del_i[0]),
        .del_q0 (del_q[0]),
        .delayed_valid  (delayed_valid),
        .sf             (sf),
        .sc_thr         (sc_thr),
        .sc_hits_req    (sc_hits_req),
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
        .noise_trig (1'b0),
        .Zpair_i0 (), .Zpair_q0 (),
        .Zpair_i1 (), .Zpair_q1 (),
        .Zpair_i2 (), .Zpair_q2 (),
        .Zpair_i3 (), .Zpair_q3 (),
        .Zpair_i4 (), .Zpair_q4 (),
        .Zpair_i5 (), .Zpair_q5 (),
        .Zdiag_0 (), .Zdiag_1 (), .Zdiag_2 (), .Zdiag_3 (),
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
    wire W_commit_int = fw_W_commit;
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
    wire        packet_active_int;
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
        .sc_lock           (sc_lock_int),
        .timing_ref        (timing_ref_int),
        .training_done     (training_done_int),
        .W_commit          (W_commit_int),
        .mode_shadow       (mimo_mode),
        .antenna_en_shadow (antenna_en),
        .psram_en          (1'b0),
        .psram_replay_active (1'b0),
        .pkt_timeout_syms  (pkt_timeout_syms),
        .safe_switch        (safe_switch),
        .W_valid_set        (W_valid_set),
        .W_missed_packet    (W_missed_packet),
        .combiner_source    (combiner_source),
        .psram_packet_arm   (),
        .psram_replay_start (),
        .psram_abort        (),
        .payload_rd_base    (),
        .buf_freeze         (buf_freeze),
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

    mrc_combiner u_comb (
        .clk_16m (clk),
        .rst_n   (rst_n),
        .x_i0 (dcr_i[0]), .x_q0 (dcr_q[0]),
        .x_i1 (dcr_i[1]), .x_q1 (dcr_q[1]),
        .x_i2 (dcr_i[2]), .x_q2 (dcr_q[2]),
        .x_i3 (dcr_i[3]), .x_q3 (dcr_q[3]),
        .x_valid  (dcr_valid),
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
