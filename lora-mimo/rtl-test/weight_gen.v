// weight_gen.v
// MRC weight generation FSM: normalise, calibrate, compute MRC/SC/bypass weights
// GF180MCU, 3.3V, 16 MHz single clock domain

module weight_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        training_done,
    input  wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    /* verilator lint_off UNUSEDSIGNAL */ input  wire [9:0]  n_acc, /* verilator lint_on UNUSEDSIGNAL */
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

    // FSM states
    localparam ST_IDLE      = 3'd0;
    localparam ST_SHIFT     = 3'd1;
    localparam ST_CALIBRATE = 3'd2;
    localparam ST_COMPUTE   = 3'd3;
    localparam ST_SCALE     = 3'd4;
    localparam ST_WRITE     = 3'd5;

    reg [2:0] state;

    // Latched Z inputs
    reg signed [31:0] H_i0, H_q0, H_i1, H_q1, H_i2, H_q2, H_i3, H_q3;

    // Calibrated channel estimates
    reg signed [31:0] Hc_i0, Hc_q0, Hc_i1, Hc_q1, Hc_i2, Hc_q2, Hc_i3, Hc_q3;

    // Scaled weights before Q1.15
    reg signed [31:0] Wraw_re0, Wraw_im0, Wraw_re1, Wraw_im1;
    reg signed [31:0] Wraw_re2, Wraw_im2, Wraw_re3, Wraw_im3;

    // Shift amount K (leading zeros of max magnitude)
    // K_wire: combinatorial from blk_K; K: registered in ST_SHIFT to break the
    // blk_K priority tree from the ST_CALIBRATE multiply critical path.
    reg [4:0] K_wire;
    reg [4:0] K;
    reg [32:0] best_metric;
    reg [31:0] peak_abs;
    reg [4:0]  mrc_shift;

    // Best branch index for SC mode (lowest enabled antenna)
    reg [1:0] j_best;

    // Saturation helper function: int32 -> int16 (Q1.15)
    function signed [15:0] sat16;
        input signed [31:0] v;
        begin
            if (v > 32'sd32767)       sat16 = 16'sd32767;
            else if (v < -32'sd32768) sat16 = -16'sd32768;
            else                       sat16 = v[15:0];
        end
    endfunction

    // Reciprocal LUT retained for future NR use; not called in current FSM.
    function [15:0] recip_lut;
        input [7:0] x;
        begin
            case (x)
                8'd128: recip_lut = 16'd32768;
                8'd129: recip_lut = 16'd32512;
                8'd130: recip_lut = 16'd32258;
                8'd131: recip_lut = 16'd32008;
                8'd132: recip_lut = 16'd31760;
                8'd133: recip_lut = 16'd31515;
                8'd134: recip_lut = 16'd31274;
                8'd135: recip_lut = 16'd31037;
                8'd136: recip_lut = 16'd30802;
                8'd137: recip_lut = 16'd30571;
                8'd138: recip_lut = 16'd30342;
                8'd139: recip_lut = 16'd30117;
                8'd140: recip_lut = 16'd29895;
                8'd141: recip_lut = 16'd29677;
                8'd142: recip_lut = 16'd29461;
                8'd143: recip_lut = 16'd29248;
                8'd144: recip_lut = 16'd29038;
                8'd145: recip_lut = 16'd28832;
                8'd146: recip_lut = 16'd28627;
                8'd147: recip_lut = 16'd28427;
                8'd148: recip_lut = 16'd28228;
                8'd149: recip_lut = 16'd28033;
                8'd150: recip_lut = 16'd27840;
                8'd151: recip_lut = 16'd27650;
                8'd152: recip_lut = 16'd27462;
                8'd153: recip_lut = 16'd27277;
                8'd154: recip_lut = 16'd27095;
                8'd155: recip_lut = 16'd26915;
                8'd156: recip_lut = 16'd26738;
                8'd157: recip_lut = 16'd26563;
                8'd158: recip_lut = 16'd26390;
                8'd159: recip_lut = 16'd26220;
                8'd160: recip_lut = 16'd26052;
                8'd161: recip_lut = 16'd25886;
                8'd162: recip_lut = 16'd25722;
                8'd163: recip_lut = 16'd25561;
                8'd164: recip_lut = 16'd25401;
                8'd165: recip_lut = 16'd25244;
                8'd166: recip_lut = 16'd25088;
                8'd167: recip_lut = 16'd24935;
                8'd168: recip_lut = 16'd24784;
                8'd169: recip_lut = 16'd24635;
                8'd170: recip_lut = 16'd24488;
                8'd171: recip_lut = 16'd24342;
                8'd172: recip_lut = 16'd24199;
                8'd173: recip_lut = 16'd24057;
                8'd174: recip_lut = 16'd23918;
                8'd175: recip_lut = 16'd23780;
                8'd176: recip_lut = 16'd23644;
                8'd177: recip_lut = 16'd23510;
                8'd178: recip_lut = 16'd23378;
                8'd179: recip_lut = 16'd23247;
                8'd180: recip_lut = 16'd23118;
                8'd181: recip_lut = 16'd22991;
                8'd182: recip_lut = 16'd22865;
                8'd183: recip_lut = 16'd22740;
                8'd184: recip_lut = 16'd22618;
                8'd185: recip_lut = 16'd22496;
                8'd186: recip_lut = 16'd22377;
                8'd187: recip_lut = 16'd22259;
                8'd188: recip_lut = 16'd22142;
                8'd189: recip_lut = 16'd22027;
                8'd190: recip_lut = 16'd21914;
                8'd191: recip_lut = 16'd21801;
                8'd192: recip_lut = 16'd21691;
                8'd193: recip_lut = 16'd21581;
                8'd194: recip_lut = 16'd21473;
                8'd195: recip_lut = 16'd21366;
                8'd196: recip_lut = 16'd21261;
                8'd197: recip_lut = 16'd21157;
                8'd198: recip_lut = 16'd21054;
                8'd199: recip_lut = 16'd20952;
                8'd200: recip_lut = 16'd20852;
                8'd201: recip_lut = 16'd20753;
                8'd202: recip_lut = 16'd20655;
                8'd203: recip_lut = 16'd20558;
                8'd204: recip_lut = 16'd20462;
                8'd205: recip_lut = 16'd20368;
                8'd206: recip_lut = 16'd20274;
                8'd207: recip_lut = 16'd20182;
                8'd208: recip_lut = 16'd20091;
                8'd209: recip_lut = 16'd20001;
                8'd210: recip_lut = 16'd19912;
                8'd211: recip_lut = 16'd19824;
                8'd212: recip_lut = 16'd19737;
                8'd213: recip_lut = 16'd19651;
                8'd214: recip_lut = 16'd19566;
                8'd215: recip_lut = 16'd19482;
                8'd216: recip_lut = 16'd19399;
                8'd217: recip_lut = 16'd19317;
                8'd218: recip_lut = 16'd19236;
                8'd219: recip_lut = 16'd19155;
                8'd220: recip_lut = 16'd19076;
                8'd221: recip_lut = 16'd18998;
                8'd222: recip_lut = 16'd18920;
                8'd223: recip_lut = 16'd18843;
                8'd224: recip_lut = 16'd18768;
                8'd225: recip_lut = 16'd18693;
                8'd226: recip_lut = 16'd18618;
                8'd227: recip_lut = 16'd18545;
                8'd228: recip_lut = 16'd18473;
                8'd229: recip_lut = 16'd18401;
                8'd230: recip_lut = 16'd18330;
                8'd231: recip_lut = 16'd18260;
                8'd232: recip_lut = 16'd18191;
                8'd233: recip_lut = 16'd18123;
                8'd234: recip_lut = 16'd18055;
                8'd235: recip_lut = 16'd17988;
                8'd236: recip_lut = 16'd17922;
                8'd237: recip_lut = 16'd17857;
                8'd238: recip_lut = 16'd17792;
                8'd239: recip_lut = 16'd17728;
                8'd240: recip_lut = 16'd17665;
                8'd241: recip_lut = 16'd17602;
                8'd242: recip_lut = 16'd17540;
                8'd243: recip_lut = 16'd17479;
                8'd244: recip_lut = 16'd17418;
                8'd245: recip_lut = 16'd17358;
                8'd246: recip_lut = 16'd17299;
                8'd247: recip_lut = 16'd17240;
                8'd248: recip_lut = 16'd17182;
                8'd249: recip_lut = 16'd17125;
                8'd250: recip_lut = 16'd17068;
                8'd251: recip_lut = 16'd17012;
                8'd252: recip_lut = 16'd16957;
                8'd253: recip_lut = 16'd16902;
                8'd254: recip_lut = 16'd16848;
                8'd255: recip_lut = 16'd16794;
                default: recip_lut = 16'd32768;
            endcase
        end
    endfunction

    // Combinatorial shift and headroom — computed as always@(*) regs so that
    // Yosys does not need to elaborate functions-with-local-regs from the
    // clocked always block (this version misbehaves for those).
    reg [4:0] mrc_norm_shift;
    reg [1:0] branch_hdr;

    always @(*) begin
        mrc_norm_shift =
            peak_abs[31] ? 5'd17 :
            peak_abs[30] ? 5'd16 :
            peak_abs[29] ? 5'd15 :
            peak_abs[28] ? 5'd14 :
            peak_abs[27] ? 5'd13 :
            peak_abs[26] ? 5'd12 :
            peak_abs[25] ? 5'd11 :
            peak_abs[24] ? 5'd10 :
            peak_abs[23] ? 5'd9  :
            peak_abs[22] ? 5'd8  :
            peak_abs[21] ? 5'd7  :
            peak_abs[20] ? 5'd6  :
            peak_abs[19] ? 5'd5  :
            peak_abs[18] ? 5'd4  :
            peak_abs[17] ? 5'd3  :
            peak_abs[16] ? 5'd2  :
            peak_abs[15] ? 5'd1  :
                           5'd0;
    end

    always @(*) begin : blk_branch_hdr
        reg [2:0] cnt;
        cnt = {2'd0, antenna_en[0]} + {2'd0, antenna_en[1]}
            + {2'd0, antenna_en[2]} + {2'd0, antenna_en[3]};
        if (cnt <= 3'd1)      branch_hdr = 2'd0;
        else if (cnt == 3'd2) branch_hdr = 2'd1;
        else                  branch_hdr = 2'd2;
    end

    // Sub-cycle counter for multi-cycle FSM states
    reg [3:0] sub_st;

    // First-enabled antenna for bypass mode
    reg [1:0] lowest_ant;
    always @(*) begin
        if      (antenna_en[0]) lowest_ant = 2'd0;
        else if (antenna_en[1]) lowest_ant = 2'd1;
        else if (antenna_en[2]) lowest_ant = 2'd2;
        else                    lowest_ant = 2'd3;
    end

    reg training_done_prev;

    // K: right-shift so max |H| across all antennas fits in Q1.15.
    // n_acc is capped at 1023 in training_acc; max |H| = 1023 * 127 = 129921 < 2^17.
    // Simple 3-level lookup on n_acc avoids 8x abs32 ripple-carry adders + serial
    // comparison tree (which synthesised to >100 ns at GF180MCU SS 125C 3V).
    //   n_acc <= 256: H_max < 32512 fits in Q1.15; K=0
    //   n_acc <= 512: H_max < 65024; shift 1 gives <32512; K=1
    //   n_acc <= 1023: H_max < 129921; shift 2 gives <32481; K=2
    always @(*) begin : blk_K
        if      (n_acc >= 10'd513) K_wire = 5'd2;
        else if (n_acc >= 10'd257) K_wire = 5'd1;
        else                       K_wire = 5'd0;
    end

    // Pipeline stage-1 registers: latch shift result (sub_st N) for use by
    // the multiply-add in the following clock cycle (sub_st N+1).
    // This breaks the critical path:
    //   sub_st → mux → barrel-shift + 16x16 multiply + 32-bit add → Hc register
    // into two single-cycle paths each well within 62.5 ns at SS 125C 3V.
    reg signed [15:0] Hs_i_p1, Hs_q_p1;
    reg signed [15:0] cal_re_p1, cal_im_p1;
    reg [1:0]         p1_ant;   // antenna index for the pending write

    // Stage-2 multiply-add: purely from registered inputs — no sub_st fanout in this path.
    // Use only the upper 8 bits of cal (Q1.7 precision) to halve multiplier depth
    // at SS 125C 3V vs full 16×16.  Shift is >>>7 instead of >>>15 because the
    // lower 8 fractional bits of cal are dropped (precision ~0.4%, acceptable for MRC).
    wire signed [31:0] calib_re_p2 =
        ({{16{Hs_i_p1[15]}}, Hs_i_p1} * {{24{cal_re_p1[15]}}, cal_re_p1[15:8]}
       + {{16{Hs_q_p1[15]}}, Hs_q_p1} * {{24{cal_im_p1[15]}}, cal_im_p1[15:8]}) >>> 7;
    wire signed [31:0] calib_im_p2 =
        ({{16{Hs_q_p1[15]}}, Hs_q_p1} * {{24{cal_re_p1[15]}}, cal_re_p1[15:8]}
       - {{16{Hs_i_p1[15]}}, Hs_i_p1} * {{24{cal_im_p1[15]}}, cal_im_p1[15:8]}) >>> 7;

    // Shared single-antenna arithmetic datapath used across multi-cycle states.
    reg signed [31:0] sel_H_i, sel_H_q;
    reg signed [31:0] sel_Hc_i, sel_Hc_q;
    reg signed [15:0] sel_cal_re, sel_cal_im;
    reg               sel_ant_en;
    reg signed [15:0] Hs_i_tmp, Hs_q_tmp;  // K-shift; only [15:0] used
    reg [31:0]        abs_i_tmp, abs_q_tmp, branch_peak_tmp;
    reg [32:0]        metric_tmp;
    reg signed [31:0] wraw_re_tmp, wraw_im_tmp;

    always @(*) begin
        case (sub_st[1:0])
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

        // Stage-1 shift (result registered into Hs_i_p1/Hs_q_p1 in clocked block).
        Hs_i_tmp = sel_H_i >>> K;
        Hs_q_tmp = sel_H_q >>> K;

        // XOR-based approximate abs (no ripple-carry adder).
        // For negative v: gives v ^ 0xFFFFFFFF = -(v+1), off by 1 LSB.
        // Safe for magnitude comparison / peak detection; eliminates 100 ns ripple path.
        abs_i_tmp = sel_Hc_i[31] ? ~sel_Hc_i : sel_Hc_i;
        abs_q_tmp = sel_Hc_q[31] ? ~sel_Hc_q : sel_Hc_q;
        branch_peak_tmp = (abs_i_tmp > abs_q_tmp) ? abs_i_tmp : abs_q_tmp;
        metric_tmp = {1'b0, abs_i_tmp} + {1'b0, abs_q_tmp};

        // Simple arithmetic right shift (truncation) replacing round_ashr32.
        // 1-LSB rounding error is negligible for MRC weight quality.
        if (sel_ant_en) begin
            wraw_re_tmp = sel_Hc_i  >>> mrc_shift;
            wraw_im_tmp = (-sel_Hc_q) >>> mrc_shift;
        end else begin
            wraw_re_tmp = 32'sd0;
            wraw_im_tmp = 32'sd0;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            sub_st   <= 4'd0;
            wgen_hw_done <= 1'b0;
            wgen_active  <= 1'b0;
            W_commit     <= 1'b0;
            wgen_mode_dbg <= 2'd0;
            training_done_prev <= 1'b0;
            j_best <= 2'd0;
            H_i0 <= 32'sd0; H_q0 <= 32'sd0;
            H_i1 <= 32'sd0; H_q1 <= 32'sd0;
            H_i2 <= 32'sd0; H_q2 <= 32'sd0;
            H_i3 <= 32'sd0; H_q3 <= 32'sd0;
            Hc_i0 <= 32'sd0; Hc_q0 <= 32'sd0;
            Hc_i1 <= 32'sd0; Hc_q1 <= 32'sd0;
            Hc_i2 <= 32'sd0; Hc_q2 <= 32'sd0;
            Hc_i3 <= 32'sd0; Hc_q3 <= 32'sd0;
            Wraw_re0 <= 32'sd0; Wraw_im0 <= 32'sd0;
            Wraw_re1 <= 32'sd0; Wraw_im1 <= 32'sd0;
            Wraw_re2 <= 32'sd0; Wraw_im2 <= 32'sd0;
            Wraw_re3 <= 32'sd0; Wraw_im3 <= 32'sd0;
            K         <= 5'd0;
            best_metric <= 33'd0;
            peak_abs <= 32'd0;
            mrc_shift <= 5'd0;
            Hs_i_p1   <= 16'sd0; Hs_q_p1   <= 16'sd0;
            cal_re_p1 <= 16'sd0; cal_im_p1 <= 16'sd0;
            p1_ant    <= 2'd0;
            W_hw_re0 <= 16'sd0; W_hw_im0 <= 16'sd0;
            W_hw_re1 <= 16'sd0; W_hw_im1 <= 16'sd0;
            W_hw_re2 <= 16'sd0; W_hw_im2 <= 16'sd0;
            W_hw_re3 <= 16'sd0; W_hw_im3 <= 16'sd0;
            W_shadow_re0 <= 16'sd0; W_shadow_im0 <= 16'sd0;
            W_shadow_re1 <= 16'sd0; W_shadow_im1 <= 16'sd0;
            W_shadow_re2 <= 16'sd0; W_shadow_im2 <= 16'sd0;
            W_shadow_re3 <= 16'sd0; W_shadow_im3 <= 16'sd0;
        end else begin
            W_commit <= 1'b0;
            wgen_hw_done <= 1'b0;
            training_done_prev <= training_done;

            // Firmware weight override path (any state)
            if (wgt_src == 1'b1 && fw_W_commit) begin
                W_shadow_re0 <= fw_W_re0; W_shadow_im0 <= fw_W_im0;
                W_shadow_re1 <= fw_W_re1; W_shadow_im1 <= fw_W_im1;
                W_shadow_re2 <= fw_W_re2; W_shadow_im2 <= fw_W_im2;
                W_shadow_re3 <= fw_W_re3; W_shadow_im3 <= fw_W_im3;
                W_commit <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    wgen_active <= 1'b0;
                    wgen_mode_dbg <= wgt_mode;
                    if (training_done && !training_done_prev) begin
                        // Latch Z inputs
                        H_i0 <= Z_i0; H_q0 <= Z_q0;
                        H_i1 <= Z_i1; H_q1 <= Z_q1;
                        H_i2 <= Z_i2; H_q2 <= Z_q2;
                        H_i3 <= Z_i3; H_q3 <= Z_q3;
                        state <= ST_SHIFT;
                        wgen_active <= 1'b1;
                        sub_st <= 4'd0;
                    end
                end

                ST_SHIFT: begin
                    // Register K_wire (n_acc-based lookup) as a FF output.
                    K     <= K_wire;
                    state <= ST_CALIBRATE;
                    sub_st <= 4'd0;
                end

                ST_CALIBRATE: begin
                    // 2-stage pipeline to break the sub_st-fanout + shift + 16x16
                    // multiply + 32-bit add path (was >100 ns at SS 125C 3V).
                    //
                    // Stage 1 (sub_st 0..3): latch shift result into Hs_p1/cal_p1.
                    // Stage 2 (sub_st 1..4): write Hc from calib_re/im_p2 wires
                    //   which are purely computed from registered Hs_p1/cal_p1 inputs.
                    //
                    // sub_st  | Stage-1 action         | Stage-2 action
                    //   0     | shift ant0 → p1        | (pipeline filling)
                    //   1     | shift ant1 → p1        | write Hc0 (p1_ant=0)
                    //   2     | shift ant2 → p1        | write Hc1 (p1_ant=1)
                    //   3     | shift ant3 → p1        | write Hc2 (p1_ant=2)
                    //   4     | (no shift)             | write Hc3 (p1_ant=3) → done

                    // Stage 1: latch current antenna's shift result
                    if (sub_st <= 4'd3) begin
                        Hs_i_p1   <= Hs_i_tmp;
                        Hs_q_p1   <= Hs_q_tmp;
                        cal_re_p1 <= sel_cal_re;
                        cal_im_p1 <= sel_cal_im;
                        p1_ant    <= sub_st[1:0];
                    end

                    // Stage 2: write Hc from registered multiply-add result
                    if (sub_st >= 4'd1) begin
                        case (p1_ant)
                            2'd0: begin Hc_i0 <= calib_re_p2; Hc_q0 <= calib_im_p2; end
                            2'd1: begin Hc_i1 <= calib_re_p2; Hc_q1 <= calib_im_p2; end
                            2'd2: begin Hc_i2 <= calib_re_p2; Hc_q2 <= calib_im_p2; end
                            default: begin Hc_i3 <= calib_re_p2; Hc_q3 <= calib_im_p2; end
                        endcase
                    end

                    if (sub_st == 4'd4) begin
                        state  <= ST_COMPUTE;
                        sub_st <= 4'd0;
                    end else begin
                        sub_st <= sub_st + 4'd1;
                    end
                end

                ST_COMPUTE: begin
                    case (sub_st)
                        4'd0: begin
                            peak_abs <= sel_ant_en ? branch_peak_tmp : 32'd0;
                            best_metric <= sel_ant_en ? metric_tmp : 33'd0;
                            j_best <= sel_ant_en ? 2'd0 : lowest_ant;
                            sub_st <= 4'd1;
                        end
                        4'd1: begin
                            if (sel_ant_en) begin
                                if (branch_peak_tmp > peak_abs)
                                    peak_abs <= branch_peak_tmp;
                                if (metric_tmp > best_metric) begin
                                    best_metric <= metric_tmp;
                                    j_best <= 2'd1;
                                end
                            end
                            sub_st <= 4'd2;
                        end
                        4'd2: begin
                            if (sel_ant_en) begin
                                if (branch_peak_tmp > peak_abs)
                                    peak_abs <= branch_peak_tmp;
                                if (metric_tmp > best_metric) begin
                                    best_metric <= metric_tmp;
                                    j_best <= 2'd2;
                                end
                            end
                            sub_st <= 4'd3;
                        end
                        4'd3: begin
                            if (sel_ant_en) begin
                                if (branch_peak_tmp > peak_abs)
                                    peak_abs <= branch_peak_tmp;
                                if (metric_tmp > best_metric) begin
                                    best_metric <= metric_tmp;
                                    j_best <= 2'd3;
                                end
                            end
                            sub_st <= 4'd4;
                        end
                        4'd4: begin
                            mrc_shift <= mrc_norm_shift + {3'd0, branch_hdr};
                            state <= ST_SCALE;
                            sub_st <= 4'd0;
                        end
                        default: begin
                            state <= ST_SCALE;
                            sub_st <= 4'd0;
                        end
                    endcase
                end

                ST_SCALE: begin
                    case (wgt_mode)
                        2'b00: begin // bypass: lowest enabled antenna = 1+0j, others 0
                            Wraw_re0 <= (lowest_ant == 2'd0 && antenna_en[0]) ? 32'sd32767 : 32'sd0;
                            Wraw_im0 <= 32'sd0;
                            Wraw_re1 <= (lowest_ant == 2'd1 && antenna_en[1]) ? 32'sd32767 : 32'sd0;
                            Wraw_im1 <= 32'sd0;
                            Wraw_re2 <= (lowest_ant == 2'd2 && antenna_en[2]) ? 32'sd32767 : 32'sd0;
                            Wraw_im2 <= 32'sd0;
                            Wraw_re3 <= (lowest_ant == 2'd3 && antenna_en[3]) ? 32'sd32767 : 32'sd0;
                            Wraw_im3 <= 32'sd0;
                        end
                        2'b01: begin // SC: best branch = 1+0j
                            Wraw_re0 <= (j_best == 2'd0) ? 32'sd32767 : 32'sd0;
                            Wraw_im0 <= 32'sd0;
                            Wraw_re1 <= (j_best == 2'd1) ? 32'sd32767 : 32'sd0;
                            Wraw_im1 <= 32'sd0;
                            Wraw_re2 <= (j_best == 2'd2) ? 32'sd32767 : 32'sd0;
                            Wraw_im2 <= 32'sd0;
                            Wraw_re3 <= (j_best == 2'd3) ? 32'sd32767 : 32'sd0;
                            Wraw_im3 <= 32'sd0;
                        end
                        2'b11: begin // MRC: approximate w_j = conj(Hc_j) >> mrc_shift
                            case (sub_st[1:0])
                                2'd0: begin Wraw_re0 <= wraw_re_tmp; Wraw_im0 <= wraw_im_tmp; end
                                2'd1: begin Wraw_re1 <= wraw_re_tmp; Wraw_im1 <= wraw_im_tmp; end
                                2'd2: begin Wraw_re2 <= wraw_re_tmp; Wraw_im2 <= wraw_im_tmp; end
                                default: begin Wraw_re3 <= wraw_re_tmp; Wraw_im3 <= wraw_im_tmp; end
                            endcase
                            if (sub_st == 4'd3)
                                state <= ST_WRITE;
                            else
                                sub_st <= sub_st + 4'd1;
                        end
                        default: begin
                            Wraw_re0 <= 32'sd32767; Wraw_im0 <= 32'sd0;
                            Wraw_re1 <= 32'sd0;     Wraw_im1 <= 32'sd0;
                            Wraw_re2 <= 32'sd0;     Wraw_im2 <= 32'sd0;
                            Wraw_re3 <= 32'sd0;     Wraw_im3 <= 32'sd0;
                            state <= ST_WRITE;
                        end
                    endcase
                    if (wgt_mode != 2'b11)
                        state <= ST_WRITE;
                end

                ST_WRITE: begin
                    W_hw_re0 <= ((Wraw_re0 > 32'sd32767) ? 16'sd32767 : ((Wraw_re0 < -32'sd32768) ? -16'sd32768 : Wraw_re0[15:0])); W_hw_im0 <= ((Wraw_im0 > 32'sd32767) ? 16'sd32767 : ((Wraw_im0 < -32'sd32768) ? -16'sd32768 : Wraw_im0[15:0]));
                    W_hw_re1 <= ((Wraw_re1 > 32'sd32767) ? 16'sd32767 : ((Wraw_re1 < -32'sd32768) ? -16'sd32768 : Wraw_re1[15:0])); W_hw_im1 <= ((Wraw_im1 > 32'sd32767) ? 16'sd32767 : ((Wraw_im1 < -32'sd32768) ? -16'sd32768 : Wraw_im1[15:0]));
                    W_hw_re2 <= ((Wraw_re2 > 32'sd32767) ? 16'sd32767 : ((Wraw_re2 < -32'sd32768) ? -16'sd32768 : Wraw_re2[15:0])); W_hw_im2 <= ((Wraw_im2 > 32'sd32767) ? 16'sd32767 : ((Wraw_im2 < -32'sd32768) ? -16'sd32768 : Wraw_im2[15:0]));
                    W_hw_re3 <= ((Wraw_re3 > 32'sd32767) ? 16'sd32767 : ((Wraw_re3 < -32'sd32768) ? -16'sd32768 : Wraw_re3[15:0])); W_hw_im3 <= ((Wraw_im3 > 32'sd32767) ? 16'sd32767 : ((Wraw_im3 < -32'sd32768) ? -16'sd32768 : Wraw_im3[15:0]));

                    if (wgt_src == 1'b0 && wgt_auto_commit) begin
                        W_shadow_re0 <= ((Wraw_re0 > 32'sd32767) ? 16'sd32767 : ((Wraw_re0 < -32'sd32768) ? -16'sd32768 : Wraw_re0[15:0])); W_shadow_im0 <= ((Wraw_im0 > 32'sd32767) ? 16'sd32767 : ((Wraw_im0 < -32'sd32768) ? -16'sd32768 : Wraw_im0[15:0]));
                        W_shadow_re1 <= ((Wraw_re1 > 32'sd32767) ? 16'sd32767 : ((Wraw_re1 < -32'sd32768) ? -16'sd32768 : Wraw_re1[15:0])); W_shadow_im1 <= ((Wraw_im1 > 32'sd32767) ? 16'sd32767 : ((Wraw_im1 < -32'sd32768) ? -16'sd32768 : Wraw_im1[15:0]));
                        W_shadow_re2 <= ((Wraw_re2 > 32'sd32767) ? 16'sd32767 : ((Wraw_re2 < -32'sd32768) ? -16'sd32768 : Wraw_re2[15:0])); W_shadow_im2 <= ((Wraw_im2 > 32'sd32767) ? 16'sd32767 : ((Wraw_im2 < -32'sd32768) ? -16'sd32768 : Wraw_im2[15:0]));
                        W_shadow_re3 <= ((Wraw_re3 > 32'sd32767) ? 16'sd32767 : ((Wraw_re3 < -32'sd32768) ? -16'sd32768 : Wraw_re3[15:0])); W_shadow_im3 <= ((Wraw_im3 > 32'sd32767) ? 16'sd32767 : ((Wraw_im3 < -32'sd32768) ? -16'sd32768 : Wraw_im3[15:0]));
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
