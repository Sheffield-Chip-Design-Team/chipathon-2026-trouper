// weight_gen.v
// MRC weight generation FSM: normalise, calibrate, compute MRC/SC/bypass weights
// GF180MCU, 3.3V, 32 MHz single clock domain
//
// Area-reduction changes vs original:
//   H registers:    32→18 bit. Z is right-shifted by SF before latching into H,
//                   normalising across SF7-SF12. Max |Z|/2^SF ≤ 8×127² = 258k < 2^18.
//                   K_wire removed — SF normalisation replaces the old n_acc-based shift.
//   Hc registers:   32→18 bit (16×8 calibration product >>>7 → 17-bit max)
//   Wraw registers: eliminated — ST_SCALE writes directly to W_hw with inline
//                   saturation, reducing register count by 8×32 = 256 flops.
//   peak_abs:       32→18 bit; mrc_norm_shift priority encoder 17→3 levels.
//   best_metric:    33→19 bit (sum of two 18-bit abs values ≤ 262142 < 2^18).
//   Calibration:    4 simultaneous 16×8 combinational multipliers → 1 serialised
//                   16×8 multiplier, 5 cycles per antenna (calib_step 0..4).
//                   ST_CALIBRATE latency: 4 ant × 5 cycles = 20 cycles (was 5).
//                   Once-per-packet FSM — latency increase is irrelevant.

module weight_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        training_done,
    input  wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    /* verilator lint_off UNUSEDSIGNAL */ input  wire [9:0]  n_acc, /* verilator lint_on UNUSEDSIGNAL */
    input  wire [3:0]  sf,
    input  wire        wgt_src,
    input  wire        wgt_auto_commit,
    input  wire [1:0]  wgt_mode,
    input  wire [3:0]  antenna_en,
    input  wire signed [15:0] cal_re0, cal_im0, cal_re1, cal_im1,
    input  wire signed [15:0] cal_re2, cal_im2, cal_re3, cal_im3,
    input  wire signed [15:0] fw_W_re0, fw_W_im0, fw_W_re1, fw_W_im1,
    input  wire signed [15:0] fw_W_re2, fw_W_im2, fw_W_re3, fw_W_im3,
    input  wire        fw_W_commit,
    output reg  signed [15:0] W_hw_re0, W_hw_im0, W_hw_re1, W_hw_im1,
    output reg  signed [15:0] W_hw_re2, W_hw_im2, W_hw_re3, W_hw_im3,
    output reg  signed [15:0] W_shadow_re0, W_shadow_im0,
    output reg  signed [15:0] W_shadow_re1, W_shadow_im1,
    output reg  signed [15:0] W_shadow_re2, W_shadow_im2,
    output reg  signed [15:0] W_shadow_re3, W_shadow_im3,
    output reg         W_commit,
    output reg         wgen_hw_done,
    output reg         wgen_active,
    output reg  [1:0]  wgen_mode_dbg
);

    localparam ST_IDLE      = 3'd0;
    localparam ST_SHIFT     = 3'd1;
    localparam ST_CALIBRATE = 3'd2;
    localparam ST_COMPUTE   = 3'd3;
    localparam ST_SCALE     = 3'd4;
    localparam ST_WRITE     = 3'd5;

    reg [2:0] state;

    reg signed [17:0] H_i0, H_q0, H_i1, H_q1, H_i2, H_q2, H_i3, H_q3;
    reg signed [17:0] Hc_i0, Hc_q0, Hc_i1, Hc_q1, Hc_i2, Hc_q2, Hc_i3, Hc_q3;

    reg [4:0] K;          // always 0 — SF normalisation applied at Z latch
    reg [18:0] best_metric;
    reg [17:0] peak_abs;
    reg [4:0]  mrc_shift;
    reg [1:0]  j_best;

    function signed [15:0] sat16;
        input signed [31:0] v;
        sat16 = (v > 32'sd32767)  ? 16'sd32767  :
                (v < -32'sd32768) ? -16'sd32768 : v[15:0];
    endfunction

    reg [4:0] mrc_norm_shift;
    always @(*) begin
        mrc_norm_shift =
            peak_abs[17] ? 5'd2 :
            peak_abs[16] ? 5'd1 :
                           5'd0;
    end

    reg [1:0] branch_hdr;
    always @(*) begin : blk_branch_hdr
        reg [2:0] cnt;
        cnt = {2'd0, antenna_en[0]} + {2'd0, antenna_en[1]}
            + {2'd0, antenna_en[2]} + {2'd0, antenna_en[3]};
        if (cnt <= 3'd1)      branch_hdr = 2'd0;
        else if (cnt == 3'd2) branch_hdr = 2'd1;
        else                  branch_hdr = 2'd2;
    end

    reg [3:0] sub_st;

    reg [1:0] lowest_ant;
    always @(*) begin
        if      (antenna_en[0]) lowest_ant = 2'd0;
        else if (antenna_en[1]) lowest_ant = 2'd1;
        else if (antenna_en[2]) lowest_ant = 2'd2;
        else                    lowest_ant = 2'd3;
    end

    reg training_done_prev;

    // K is held at 0; Z is pre-normalised by SF when latched into H.
    // Intermediate wires for SF-normalised Z (Verilog-2001: no part-select on expr).
    wire signed [31:0] Z_i0_n = $signed(Z_i0) >>> sf;
    wire signed [31:0] Z_q0_n = $signed(Z_q0) >>> sf;
    wire signed [31:0] Z_i1_n = $signed(Z_i1) >>> sf;
    wire signed [31:0] Z_q1_n = $signed(Z_q1) >>> sf;
    wire signed [31:0] Z_i2_n = $signed(Z_i2) >>> sf;
    wire signed [31:0] Z_q2_n = $signed(Z_q2) >>> sf;
    wire signed [31:0] Z_i3_n = $signed(Z_i3) >>> sf;
    wire signed [31:0] Z_q3_n = $signed(Z_q3) >>> sf;

    // -----------------------------------------------------------------------
    // Serialised calibration multiplier
    // One 16×8 multiplier stepped through 4 multiplications per antenna.
    // calib_ant[1:0]: current antenna being processed (0..3)
    // calib_step[2:0]: 0=latch+issue p0, 1=issue p1, 2=acc re+issue p2,
    //                  3=issue p3, 4=commit Hc
    // -----------------------------------------------------------------------
    reg [1:0]  calib_ant;
    reg [2:0]  calib_step;

    // cmul inputs: registered mux outputs
    reg signed [15:0] cmul_a;
    reg        [7:0]  cmul_b;     // upper 8 bits of cal coefficient

    // Single 16×8 combinational multiplier
    wire signed [23:0] cmul_p = cmul_a * $signed({1'b0, cmul_b});

    reg signed [23:0] cmul_p_r;       // registered product (= product of previous step)
    reg signed [24:0] calib_re_acc;   // P0 + P1 before >>7
    // At calib_step 4: cmul_p_r=P2 (OLD NB), cmul_p=P3 (comb) → Hc_im = (P2-P3)>>7
    wire signed [24:0] calib_im_result = {{1{cmul_p_r[23]}}, cmul_p_r} -
                                          {{1{cmul_p[23]}},   cmul_p};

    // -----------------------------------------------------------------------
    // Combinational per-antenna mux — keyed by calib_ant in ST_CALIBRATE,
    // sub_st[1:0] in all other states.
    // -----------------------------------------------------------------------
    wire [1:0] mux_key = (state == ST_CALIBRATE) ? calib_ant : sub_st[1:0];

    reg signed [17:0] sel_H_i, sel_H_q;
    reg signed [17:0] sel_Hc_i, sel_Hc_q;
    reg signed [15:0] sel_cal_re, sel_cal_im;
    reg               sel_ant_en;
    reg signed [15:0] Hs_i_tmp, Hs_q_tmp;
    reg [17:0]        abs_i_tmp, abs_q_tmp, branch_peak_tmp;
    reg [18:0]        metric_tmp;
    reg signed [17:0] wraw_re_tmp, wraw_im_tmp;

    // Pipelined H inputs (latched at calib_step 0 for use in steps 1..4)
    reg signed [15:0] Hs_i_p1, Hs_q_p1;
    reg signed [15:0] cal_re_p1, cal_im_p1;
    reg [1:0]         p1_ant;

    always @(*) begin
        case (mux_key)
            2'd0: begin
                sel_H_i = H_i0; sel_H_q = H_q0;
                sel_Hc_i = Hc_i0; sel_Hc_q = Hc_q0;
                sel_cal_re = cal_re0; sel_cal_im = cal_im0;
                sel_ant_en = antenna_en[0];
            end
            2'd1: begin
                sel_H_i = H_i1; sel_H_q = H_q1;
                sel_Hc_i = Hc_i1; sel_Hc_q = Hc_q1;
                sel_cal_re = cal_re1; sel_cal_im = cal_im1;
                sel_ant_en = antenna_en[1];
            end
            2'd2: begin
                sel_H_i = H_i2; sel_H_q = H_q2;
                sel_Hc_i = Hc_i2; sel_Hc_q = Hc_q2;
                sel_cal_re = cal_re2; sel_cal_im = cal_im2;
                sel_ant_en = antenna_en[2];
            end
            default: begin
                sel_H_i = H_i3; sel_H_q = H_q3;
                sel_Hc_i = Hc_i3; sel_Hc_q = Hc_q3;
                sel_cal_re = cal_re3; sel_cal_im = cal_im3;
                sel_ant_en = antenna_en[3];
            end
        endcase

        Hs_i_tmp = sel_H_i[15:0] >>> K;
        Hs_q_tmp = sel_H_q[15:0] >>> K;

        abs_i_tmp = sel_Hc_i[17] ? ~sel_Hc_i : sel_Hc_i;
        abs_q_tmp = sel_Hc_q[17] ? ~sel_Hc_q : sel_Hc_q;
        branch_peak_tmp = (abs_i_tmp > abs_q_tmp) ? abs_i_tmp : abs_q_tmp;
        metric_tmp = {1'b0, abs_i_tmp} + {1'b0, abs_q_tmp};

        if (sel_ant_en) begin
            wraw_re_tmp = sel_Hc_i  >>> mrc_shift;
            wraw_im_tmp = (-sel_Hc_q) >>> mrc_shift;
        end else begin
            wraw_re_tmp = 18'sd0;
            wraw_im_tmp = 18'sd0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            sub_st   <= 4'd0;
            wgen_hw_done     <= 1'b0;
            wgen_active      <= 1'b0;
            W_commit         <= 1'b0;
            wgen_mode_dbg    <= 2'd0;
            training_done_prev <= 1'b0;
            j_best   <= 2'd0;
            H_i0 <= 18'sd0; H_q0 <= 18'sd0;
            H_i1 <= 18'sd0; H_q1 <= 18'sd0;
            H_i2 <= 18'sd0; H_q2 <= 18'sd0;
            H_i3 <= 18'sd0; H_q3 <= 18'sd0;
            Hc_i0 <= 18'sd0; Hc_q0 <= 18'sd0;
            Hc_i1 <= 18'sd0; Hc_q1 <= 18'sd0;
            Hc_i2 <= 18'sd0; Hc_q2 <= 18'sd0;
            Hc_i3 <= 18'sd0; Hc_q3 <= 18'sd0;
            K         <= 5'd0;
            best_metric <= 19'd0;
            peak_abs    <= 18'd0;
            mrc_shift   <= 5'd0;
            Hs_i_p1   <= 16'sd0; Hs_q_p1   <= 16'sd0;
            cal_re_p1 <= 16'sd0; cal_im_p1 <= 16'sd0;
            p1_ant    <= 2'd0;
            calib_ant  <= 2'd0;
            calib_step <= 3'd0;
            cmul_a     <= 16'sd0; cmul_b <= 8'd0;
            cmul_p_r   <= 24'sd0;
            calib_re_acc <= 25'sd0;
            W_hw_re0 <= 16'sd0; W_hw_im0 <= 16'sd0;
            W_hw_re1 <= 16'sd0; W_hw_im1 <= 16'sd0;
            W_hw_re2 <= 16'sd0; W_hw_im2 <= 16'sd0;
            W_hw_re3 <= 16'sd0; W_hw_im3 <= 16'sd0;
            W_shadow_re0 <= 16'sd0; W_shadow_im0 <= 16'sd0;
            W_shadow_re1 <= 16'sd0; W_shadow_im1 <= 16'sd0;
            W_shadow_re2 <= 16'sd0; W_shadow_im2 <= 16'sd0;
            W_shadow_re3 <= 16'sd0; W_shadow_im3 <= 16'sd0;
        end else begin
            W_commit         <= 1'b0;
            wgen_hw_done     <= 1'b0;
            training_done_prev <= training_done;

            if (wgt_src == 1'b1 && fw_W_commit) begin
                W_shadow_re0 <= fw_W_re0; W_shadow_im0 <= fw_W_im0;
                W_shadow_re1 <= fw_W_re1; W_shadow_im1 <= fw_W_im1;
                W_shadow_re2 <= fw_W_re2; W_shadow_im2 <= fw_W_im2;
                W_shadow_re3 <= fw_W_re3; W_shadow_im3 <= fw_W_im3;
                W_commit <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    wgen_active   <= 1'b0;
                    wgen_mode_dbg <= wgt_mode;
                    if (training_done && !training_done_prev) begin
                        // Right-shift Z by SF to normalise across SF7-SF12.
                        // Max |Z|>>SF = 8×127² = 258k < 2^18 for all SFs.
                        H_i0 <= Z_i0_n[17:0]; H_q0 <= Z_q0_n[17:0];
                        H_i1 <= Z_i1_n[17:0]; H_q1 <= Z_q1_n[17:0];
                        H_i2 <= Z_i2_n[17:0]; H_q2 <= Z_q2_n[17:0];
                        H_i3 <= Z_i3_n[17:0]; H_q3 <= Z_q3_n[17:0];
                        state       <= ST_SHIFT;
                        wgen_active <= 1'b1;
                        sub_st      <= 4'd0;
                    end
                end

                ST_SHIFT: begin
                    K     <= 5'd0;   // SF normalisation already applied at H latch
                    state <= ST_CALIBRATE;
                    sub_st <= 4'd0;
                    calib_ant  <= 2'd0;
                    calib_step <= 3'd0;
                end

                ST_CALIBRATE: begin
                    // Serialised 16×8 complex multiply: 5 cycles per antenna.
                    // Pipeline timing (non-blocking):
                    //   At step N posedge: cmul_p_r ← cmul_p (= product of step N)
                    //   During step N+1: cmul_p_r = P_N, cmul_p (comb) = P_{N+1}
                    cmul_p_r <= cmul_p;

                    case (calib_step)
                        3'd0: begin
                            // Latch this antenna's H and cal; issue p0: A=Hs_i, B=cal_re
                            Hs_i_p1   <= Hs_i_tmp;
                            Hs_q_p1   <= Hs_q_tmp;
                            cal_re_p1 <= sel_cal_re;
                            cal_im_p1 <= sel_cal_im;
                            p1_ant    <= calib_ant;
                            cmul_a    <= Hs_i_tmp;
                            cmul_b    <= sel_cal_re[15:8];
                            calib_step <= 3'd1;
                        end
                        3'd1: begin
                            // cmul_p_r = P0; issue p1: A=Hs_q, B=cal_im
                            cmul_a    <= Hs_q_p1;
                            cmul_b    <= cal_im_p1[15:8];
                            calib_step <= 3'd2;
                        end
                        3'd2: begin
                            // calib_re_acc = P0 + P1 (cmul_p_r=P0 OLD, cmul_p=P1 comb)
                            // Issue p2: A=Hs_q, B=cal_re
                            calib_re_acc <= {{1{cmul_p_r[23]}}, cmul_p_r} +
                                            {{1{cmul_p[23]}},   cmul_p};
                            cmul_a    <= Hs_q_p1;
                            cmul_b    <= cal_re_p1[15:8];
                            calib_step <= 3'd3;
                        end
                        3'd3: begin
                            // cmul_p_r = P2; issue p3: A=Hs_i, B=cal_im
                            cmul_a    <= Hs_i_p1;
                            cmul_b    <= cal_im_p1[15:8];
                            calib_step <= 3'd4;
                        end
                        default: begin  // step 4: commit
                            // cmul_p_r = P2 (OLD NB value), cmul_p = P3 (comb)
                            // Hc_re = (P0+P1) >> 7 = calib_re_acc[24:7]
                            // Hc_im = (P2-P3) >> 7 = (cmul_p_r - cmul_p) >> 7
                            case (p1_ant)
                                2'd0: begin
                                    Hc_i0 <= calib_re_acc[24:7];
                                    Hc_q0 <= calib_im_result[24:7];
                                end
                                2'd1: begin
                                    Hc_i1 <= calib_re_acc[24:7];
                                    Hc_q1 <= calib_im_result[24:7];
                                end
                                2'd2: begin
                                    Hc_i2 <= calib_re_acc[24:7];
                                    Hc_q2 <= calib_im_result[24:7];
                                end
                                default: begin
                                    Hc_i3 <= calib_re_acc[24:7];
                                    Hc_q3 <= calib_im_result[24:7];
                                end
                            endcase
                            calib_step <= 3'd0;
                            if (p1_ant == 2'd3) begin
                                state  <= ST_COMPUTE;
                                sub_st <= 4'd0;
                            end else begin
                                calib_ant <= calib_ant + 2'd1;
                            end
                        end
                    endcase
                end

                ST_COMPUTE: begin
                    case (sub_st)
                        4'd0: begin
                            peak_abs    <= sel_ant_en ? branch_peak_tmp : 18'd0;
                            best_metric <= sel_ant_en ? metric_tmp : 19'd0;
                            j_best      <= sel_ant_en ? 2'd0 : lowest_ant;
                            sub_st <= 4'd1;
                        end
                        4'd1: begin
                            if (sel_ant_en) begin
                                if (branch_peak_tmp > peak_abs) peak_abs <= branch_peak_tmp;
                                if (metric_tmp > best_metric) begin
                                    best_metric <= metric_tmp;
                                    j_best <= 2'd1;
                                end
                            end
                            sub_st <= 4'd2;
                        end
                        4'd2: begin
                            if (sel_ant_en) begin
                                if (branch_peak_tmp > peak_abs) peak_abs <= branch_peak_tmp;
                                if (metric_tmp > best_metric) begin
                                    best_metric <= metric_tmp;
                                    j_best <= 2'd2;
                                end
                            end
                            sub_st <= 4'd3;
                        end
                        4'd3: begin
                            if (sel_ant_en) begin
                                if (branch_peak_tmp > peak_abs) peak_abs <= branch_peak_tmp;
                                if (metric_tmp > best_metric) begin
                                    best_metric <= metric_tmp;
                                    j_best <= 2'd3;
                                end
                            end
                            sub_st <= 4'd4;
                        end
                        4'd4: begin
                            mrc_shift <= mrc_norm_shift + {3'd0, branch_hdr};
                            state  <= ST_SCALE;
                            sub_st <= 4'd0;
                        end
                        default: begin state <= ST_SCALE; sub_st <= 4'd0; end
                    endcase
                end

                ST_SCALE: begin
                    case (wgt_mode)
                        2'b00: begin
                            W_hw_re0 <= (lowest_ant==2'd0 && antenna_en[0]) ? 16'sd32767 : 16'sd0;
                            W_hw_im0 <= 16'sd0;
                            W_hw_re1 <= (lowest_ant==2'd1 && antenna_en[1]) ? 16'sd32767 : 16'sd0;
                            W_hw_im1 <= 16'sd0;
                            W_hw_re2 <= (lowest_ant==2'd2 && antenna_en[2]) ? 16'sd32767 : 16'sd0;
                            W_hw_im2 <= 16'sd0;
                            W_hw_re3 <= (lowest_ant==2'd3 && antenna_en[3]) ? 16'sd32767 : 16'sd0;
                            W_hw_im3 <= 16'sd0;
                        end
                        2'b01: begin
                            W_hw_re0 <= (j_best==2'd0) ? 16'sd32767 : 16'sd0; W_hw_im0 <= 16'sd0;
                            W_hw_re1 <= (j_best==2'd1) ? 16'sd32767 : 16'sd0; W_hw_im1 <= 16'sd0;
                            W_hw_re2 <= (j_best==2'd2) ? 16'sd32767 : 16'sd0; W_hw_im2 <= 16'sd0;
                            W_hw_re3 <= (j_best==2'd3) ? 16'sd32767 : 16'sd0; W_hw_im3 <= 16'sd0;
                        end
                        2'b11: begin
                            case (sub_st[1:0])
                                2'd0: begin
                                    W_hw_re0 <= sat16({{14{wraw_re_tmp[17]}}, wraw_re_tmp});
                                    W_hw_im0 <= sat16({{14{wraw_im_tmp[17]}}, wraw_im_tmp});
                                end
                                2'd1: begin
                                    W_hw_re1 <= sat16({{14{wraw_re_tmp[17]}}, wraw_re_tmp});
                                    W_hw_im1 <= sat16({{14{wraw_im_tmp[17]}}, wraw_im_tmp});
                                end
                                2'd2: begin
                                    W_hw_re2 <= sat16({{14{wraw_re_tmp[17]}}, wraw_re_tmp});
                                    W_hw_im2 <= sat16({{14{wraw_im_tmp[17]}}, wraw_im_tmp});
                                end
                                default: begin
                                    W_hw_re3 <= sat16({{14{wraw_re_tmp[17]}}, wraw_re_tmp});
                                    W_hw_im3 <= sat16({{14{wraw_im_tmp[17]}}, wraw_im_tmp});
                                end
                            endcase
                            if (sub_st == 4'd3)
                                state <= ST_WRITE;
                            else
                                sub_st <= sub_st + 4'd1;
                        end
                        default: begin
                            W_hw_re0 <= 16'sd32767; W_hw_im0 <= 16'sd0;
                            W_hw_re1 <= 16'sd0;     W_hw_im1 <= 16'sd0;
                            W_hw_re2 <= 16'sd0;     W_hw_im2 <= 16'sd0;
                            W_hw_re3 <= 16'sd0;     W_hw_im3 <= 16'sd0;
                        end
                    endcase
                    if (wgt_mode != 2'b11)
                        state <= ST_WRITE;
                end

                ST_WRITE: begin
                    if (wgt_src == 1'b0 && wgt_auto_commit) begin
                        W_shadow_re0 <= W_hw_re0; W_shadow_im0 <= W_hw_im0;
                        W_shadow_re1 <= W_hw_re1; W_shadow_im1 <= W_hw_im1;
                        W_shadow_re2 <= W_hw_re2; W_shadow_im2 <= W_hw_im2;
                        W_shadow_re3 <= W_hw_re3; W_shadow_im3 <= W_hw_im3;
                        W_commit <= 1'b1;
                    end
                    wgen_hw_done <= 1'b1;
                    wgen_active  <= 1'b0;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
