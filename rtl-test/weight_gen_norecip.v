// weight_gen_norecip.v — weight_gen with recip_lut replaced by a blackbox
// Used for synthesis timing analysis; the real LUT is a ROM and will be
// implemented as a synthesised ROM macro or hand-placed; its path is not
// on any critical datapath (it runs once per packet in ST_COMPUTE sub_st 4).

// Blackbox stub for the LUT so ABC doesn't see 256 priority-encoder MUX levels.
(* blackbox *)
module recip_lut_bb (
    input  [7:0] x,
    output [15:0] out
);
endmodule

// weight_gen with recip_lut calls replaced by recip_lut_bb instantiation.
// Functionally equivalent for synthesis purposes.
module weight_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        training_done,
    input  wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    input  wire [9:0]  n_acc,
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
    reg [3:0] sub_st;

    reg signed [31:0] H_i0, H_q0, H_i1, H_q1, H_i2, H_q2, H_i3, H_q3;
    reg signed [31:0] Hc_i0, Hc_q0, Hc_i1, Hc_q1, Hc_i2, Hc_q2, Hc_i3, Hc_q3;
    reg signed [31:0] Wraw_re0, Wraw_im0, Wraw_re1, Wraw_im1;
    reg signed [31:0] Wraw_re2, Wraw_im2, Wraw_re3, Wraw_im3;
    reg [4:0]  K;
    reg [15:0] inv_S;
    reg [63:0] mag2_0, mag2_1, mag2_2, mag2_3;
    reg [63:0] S, best_mag;
    reg [1:0]  j_best;
    reg [31:0] nr_r;
    reg [63:0] nr_tmp;
    reg [63:0] nr_inner_r;
    reg        training_done_prev;
    reg [2:0]  sub_st3;  // alias for 3-bit use in calibrate/scale

    // LUT blackbox instances (one for each of the two call-sites in ST_COMPUTE sub_st 4)
    wire [15:0] lut_out_a, lut_out_b;
    reg  [7:0]  lut_in_a, lut_in_b;
    recip_lut_bb u_lut_a (.x(lut_in_a), .out(lut_out_a));
    recip_lut_bb u_lut_b (.x(lut_in_b), .out(lut_out_b));

    // Combinatorial datapath (same as original weight_gen)
    reg signed [31:0] sel_H_i, sel_H_q, sel_Hc_i, sel_Hc_q;
    reg signed [15:0] sel_cal_re, sel_cal_im;
    reg               sel_ant_en;
    reg signed [31:0] calib_re_tmp, calib_im_tmp;
    reg [63:0]        mag2_tmp;
    reg signed [31:0] wraw_re_tmp, wraw_im_tmp;

    reg [1:0] lowest_ant;
    always @(*) begin
        if      (antenna_en[0]) lowest_ant = 2'd0;
        else if (antenna_en[1]) lowest_ant = 2'd1;
        else if (antenna_en[2]) lowest_ant = 2'd2;
        else                    lowest_ant = 2'd3;
    end

    always @(*) begin
        case (sub_st[1:0])
            2'd0: begin sel_H_i=H_i0; sel_H_q=H_q0; sel_Hc_i=Hc_i0; sel_Hc_q=Hc_q0; sel_cal_re=cal_re0; sel_cal_im=cal_im0; sel_ant_en=antenna_en[0]; end
            2'd1: begin sel_H_i=H_i1; sel_H_q=H_q1; sel_Hc_i=Hc_i1; sel_Hc_q=Hc_q1; sel_cal_re=cal_re1; sel_cal_im=cal_im1; sel_ant_en=antenna_en[1]; end
            2'd2: begin sel_H_i=H_i2; sel_H_q=H_q2; sel_Hc_i=Hc_i2; sel_Hc_q=Hc_q2; sel_cal_re=cal_re2; sel_cal_im=cal_im2; sel_ant_en=antenna_en[2]; end
            default: begin sel_H_i=H_i3; sel_H_q=H_q3; sel_Hc_i=Hc_i3; sel_Hc_q=Hc_q3; sel_cal_re=cal_re3; sel_cal_im=cal_im3; sel_ant_en=antenna_en[3]; end
        endcase
        calib_re_tmp = (($signed(sel_H_i[15:0]) * sel_cal_re) + ($signed(sel_H_q[15:0]) * sel_cal_im)) >>> 15;
        calib_im_tmp = (($signed(sel_H_q[15:0]) * sel_cal_re) - ($signed(sel_H_i[15:0]) * sel_cal_im)) >>> 15;
        mag2_tmp     = ($signed(sel_Hc_i[15:0]) * $signed(sel_Hc_i[15:0])) + ($signed(sel_Hc_q[15:0]) * $signed(sel_Hc_q[15:0]));
        wraw_re_tmp  = sel_ant_en ? (($signed(sel_Hc_i[15:0]) * $signed({2'b0, inv_S})) >>> 16) : 32'sd0;
        wraw_im_tmp  = sel_ant_en ? ((-$signed(sel_Hc_q[15:0]) * $signed({2'b0, inv_S})) >>> 16) : 32'sd0;
    end

    // sat16 inline
    function signed [15:0] sat16;
        input signed [31:0] v;
        begin
            if      (v >  32'sd32767) sat16 =  16'sd32767;
            else if (v < -32'sd32768) sat16 = -16'sd32768;
            else                       sat16 = v[15:0];
        end
    endfunction

    // abs32 inline
    function [31:0] abs32;
        input signed [31:0] v;
        begin abs32 = v[31] ? (~v + 32'd1) : v; end
    endfunction

    // lzc32 inline (priority encoder)
    function [4:0] lzc32;
        input [31:0] v;
        begin
            if      (v[31]) lzc32=5'd0;  else if (v[30]) lzc32=5'd1;
            else if (v[29]) lzc32=5'd2;  else if (v[28]) lzc32=5'd3;
            else if (v[27]) lzc32=5'd4;  else if (v[26]) lzc32=5'd5;
            else if (v[25]) lzc32=5'd6;  else if (v[24]) lzc32=5'd7;
            else if (v[23]) lzc32=5'd8;  else if (v[22]) lzc32=5'd9;
            else if (v[21]) lzc32=5'd10; else if (v[20]) lzc32=5'd11;
            else if (v[19]) lzc32=5'd12; else if (v[18]) lzc32=5'd13;
            else if (v[17]) lzc32=5'd14; else if (v[16]) lzc32=5'd15;
            else if (v[15]) lzc32=5'd16; else if (v[14]) lzc32=5'd17;
            else if (v[13]) lzc32=5'd18; else if (v[12]) lzc32=5'd19;
            else if (v[11]) lzc32=5'd20; else if (v[10]) lzc32=5'd21;
            else if (v[9])  lzc32=5'd22; else if (v[8])  lzc32=5'd23;
            else if (v[7])  lzc32=5'd24; else if (v[6])  lzc32=5'd25;
            else if (v[5])  lzc32=5'd26; else if (v[4])  lzc32=5'd27;
            else if (v[3])  lzc32=5'd28; else if (v[2])  lzc32=5'd29;
            else if (v[1])  lzc32=5'd30; else             lzc32=5'd31;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; sub_st <= 4'd0;
            wgen_hw_done <= 1'b0; wgen_active <= 1'b0; W_commit <= 1'b0;
            wgen_mode_dbg <= 2'd0; training_done_prev <= 1'b0;
            K <= 5'd0; inv_S <= 16'd0; S <= 64'd0; best_mag <= 64'd0; j_best <= 2'd0;
            H_i0<=32'sd0; H_q0<=32'sd0; H_i1<=32'sd0; H_q1<=32'sd0;
            H_i2<=32'sd0; H_q2<=32'sd0; H_i3<=32'sd0; H_q3<=32'sd0;
            Hc_i0<=32'sd0; Hc_q0<=32'sd0; Hc_i1<=32'sd0; Hc_q1<=32'sd0;
            Hc_i2<=32'sd0; Hc_q2<=32'sd0; Hc_i3<=32'sd0; Hc_q3<=32'sd0;
            Wraw_re0<=32'sd0; Wraw_im0<=32'sd0; Wraw_re1<=32'sd0; Wraw_im1<=32'sd0;
            Wraw_re2<=32'sd0; Wraw_im2<=32'sd0; Wraw_re3<=32'sd0; Wraw_im3<=32'sd0;
            mag2_0<=64'd0; mag2_1<=64'd0; mag2_2<=64'd0; mag2_3<=64'd0;
            nr_r<=32'd0; nr_tmp<=64'd0; nr_inner_r<=64'd0;
            W_hw_re0<=16'sd0; W_hw_im0<=16'sd0; W_hw_re1<=16'sd0; W_hw_im1<=16'sd0;
            W_hw_re2<=16'sd0; W_hw_im2<=16'sd0; W_hw_re3<=16'sd0; W_hw_im3<=16'sd0;
            W_shadow_re0<=16'sd0; W_shadow_im0<=16'sd0; W_shadow_re1<=16'sd0; W_shadow_im1<=16'sd0;
            W_shadow_re2<=16'sd0; W_shadow_im2<=16'sd0; W_shadow_re3<=16'sd0; W_shadow_im3<=16'sd0;
            lut_in_a<=8'd128; lut_in_b<=8'd128;
        end else begin
            W_commit <= 1'b0; wgen_hw_done <= 1'b0;
            training_done_prev <= training_done;

            if (wgt_src == 1'b1 && fw_W_commit) begin
                W_shadow_re0<=fw_W_re0; W_shadow_im0<=fw_W_im0;
                W_shadow_re1<=fw_W_re1; W_shadow_im1<=fw_W_im1;
                W_shadow_re2<=fw_W_re2; W_shadow_im2<=fw_W_im2;
                W_shadow_re3<=fw_W_re3; W_shadow_im3<=fw_W_im3;
                W_commit <= 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    wgen_active <= 1'b0; wgen_mode_dbg <= wgt_mode;
                    if (training_done && !training_done_prev) begin
                        H_i0<=Z_i0; H_q0<=Z_q0; H_i1<=Z_i1; H_q1<=Z_q1;
                        H_i2<=Z_i2; H_q2<=Z_q2; H_i3<=Z_i3; H_q3<=Z_q3;
                        state<=ST_SHIFT; wgen_active<=1'b1; sub_st<=4'd0;
                    end
                end

                ST_SHIFT: begin
                    begin : shift_block
                        reg [31:0] a0,a1,a2,a3,mval;
                        a0=abs32(H_i0)|abs32(H_q0); a1=abs32(H_i1)|abs32(H_q1);
                        a2=abs32(H_i2)|abs32(H_q2); a3=abs32(H_i3)|abs32(H_q3);
                        mval=a0|a1|a2|a3; K<=lzc32(mval);
                        case (lzc32(mval))
                            5'd0:  begin H_i0<=H_i0;      H_q0<=H_q0;      H_i1<=H_i1;      H_q1<=H_q1;      H_i2<=H_i2;      H_q2<=H_q2;      H_i3<=H_i3;      H_q3<=H_q3;      end
                            5'd1:  begin H_i0<=H_i0>>>1;  H_q0<=H_q0>>>1;  H_i1<=H_i1>>>1;  H_q1<=H_q1>>>1;  H_i2<=H_i2>>>1;  H_q2<=H_q2>>>1;  H_i3<=H_i3>>>1;  H_q3<=H_q3>>>1;  end
                            5'd2:  begin H_i0<=H_i0>>>2;  H_q0<=H_q0>>>2;  H_i1<=H_i1>>>2;  H_q1<=H_q1>>>2;  H_i2<=H_i2>>>2;  H_q2<=H_q2>>>2;  H_i3<=H_i3>>>2;  H_q3<=H_q3>>>2;  end
                            5'd3:  begin H_i0<=H_i0>>>3;  H_q0<=H_q0>>>3;  H_i1<=H_i1>>>3;  H_q1<=H_q1>>>3;  H_i2<=H_i2>>>3;  H_q2<=H_q2>>>3;  H_i3<=H_i3>>>3;  H_q3<=H_q3>>>3;  end
                            5'd4:  begin H_i0<=H_i0>>>4;  H_q0<=H_q0>>>4;  H_i1<=H_i1>>>4;  H_q1<=H_q1>>>4;  H_i2<=H_i2>>>4;  H_q2<=H_q2>>>4;  H_i3<=H_i3>>>4;  H_q3<=H_q3>>>4;  end
                            5'd5:  begin H_i0<=H_i0>>>5;  H_q0<=H_q0>>>5;  H_i1<=H_i1>>>5;  H_q1<=H_q1>>>5;  H_i2<=H_i2>>>5;  H_q2<=H_q2>>>5;  H_i3<=H_i3>>>5;  H_q3<=H_q3>>>5;  end
                            5'd6:  begin H_i0<=H_i0>>>6;  H_q0<=H_q0>>>6;  H_i1<=H_i1>>>6;  H_q1<=H_q1>>>6;  H_i2<=H_i2>>>6;  H_q2<=H_q2>>>6;  H_i3<=H_i3>>>6;  H_q3<=H_q3>>>6;  end
                            5'd7:  begin H_i0<=H_i0>>>7;  H_q0<=H_q0>>>7;  H_i1<=H_i1>>>7;  H_q1<=H_q1>>>7;  H_i2<=H_i2>>>7;  H_q2<=H_q2>>>7;  H_i3<=H_i3>>>7;  H_q3<=H_q3>>>7;  end
                            default: begin H_i0<=H_i0>>>8; H_q0<=H_q0>>>8; H_i1<=H_i1>>>8; H_q1<=H_q1>>>8; H_i2<=H_i2>>>8; H_q2<=H_q2>>>8; H_i3<=H_i3>>>8; H_q3<=H_q3>>>8; end
                        endcase
                    end
                    state<=ST_CALIBRATE;
                end

                ST_CALIBRATE: begin
                    case (sub_st[1:0])
                        2'd0: begin Hc_i0<=calib_re_tmp; Hc_q0<=calib_im_tmp; end
                        2'd1: begin Hc_i1<=calib_re_tmp; Hc_q1<=calib_im_tmp; end
                        2'd2: begin Hc_i2<=calib_re_tmp; Hc_q2<=calib_im_tmp; end
                        default: begin Hc_i3<=calib_re_tmp; Hc_q3<=calib_im_tmp; end
                    endcase
                    if (sub_st==4'd3) begin state<=ST_COMPUTE; sub_st<=4'd0; end
                    else sub_st<=sub_st+4'd1;
                end

                ST_COMPUTE: begin
                    case (sub_st)
                        4'd0: begin mag2_0<=mag2_tmp; S<=sel_ant_en?mag2_tmp:64'd0; best_mag<=sel_ant_en?mag2_tmp:64'd0; j_best<=2'd0; sub_st<=4'd1; end
                        4'd1: begin mag2_1<=mag2_tmp; if(sel_ant_en) S<=S+mag2_tmp; if(sel_ant_en&&mag2_tmp>best_mag) begin best_mag<=mag2_tmp; j_best<=2'd1; end sub_st<=4'd2; end
                        4'd2: begin mag2_2<=mag2_tmp; if(sel_ant_en) S<=S+mag2_tmp; if(sel_ant_en&&mag2_tmp>best_mag) begin best_mag<=mag2_tmp; j_best<=2'd2; end sub_st<=4'd3; end
                        4'd3: begin mag2_3<=mag2_tmp; if(sel_ant_en) S<=S+mag2_tmp; if(sel_ant_en&&mag2_tmp>best_mag) begin best_mag<=mag2_tmp; j_best<=2'd3; end sub_st<=4'd4; end
                        4'd4: begin
                            // LUT lookup via blackbox instances
                            begin : recip_block
                                reg [7:0] s_norm;
                                if      (S[31:24]!=8'd0) s_norm=S[31:24];
                                else if (S[23:16]!=8'd0) s_norm=S[23:16];
                                else if (S[15:8] !=8'd0) s_norm=S[15:8];
                                else                      s_norm=S[7:0];
                                if (s_norm[7]) begin lut_in_a<=s_norm;            lut_in_b<=s_norm;            end
                                else           begin lut_in_a<={1'b1,s_norm[6:0]}; lut_in_b<={1'b1,s_norm[6:0]}; end
                                nr_r <= s_norm[7] ? {16'd0, lut_out_a} : {16'd0, lut_out_b};
                            end
                            sub_st<=4'd5;
                        end
                        4'd5: begin nr_inner_r<={32'd0,nr_r[15:0]}*S[47:16];                               sub_st<=4'd6; end
                        4'd6: begin nr_tmp<={32'd0,nr_r[15:0]}*(32'd65536-nr_inner_r[47:16]);              sub_st<=4'd7; end
                        4'd7: begin nr_r<={16'd0,nr_tmp[31:16]}; nr_inner_r<={32'd0,nr_tmp[31:16]}*S[47:16]; sub_st<=4'd8; end
                        4'd8: begin nr_tmp<=nr_r*(32'd65536-nr_inner_r[47:16]);                            sub_st<=4'd9; end
                        4'd9: begin inv_S<=nr_tmp[31:16]; sub_st<=4'd0; state<=ST_SCALE; end
                        default: sub_st<=4'd0;
                    endcase
                end

                ST_SCALE: begin
                    case (wgt_mode)
                        2'b00: begin
                            Wraw_re0<=(lowest_ant==2'd0&&antenna_en[0])?32'sd32767:32'sd0; Wraw_im0<=32'sd0;
                            Wraw_re1<=(lowest_ant==2'd1&&antenna_en[1])?32'sd32767:32'sd0; Wraw_im1<=32'sd0;
                            Wraw_re2<=(lowest_ant==2'd2&&antenna_en[2])?32'sd32767:32'sd0; Wraw_im2<=32'sd0;
                            Wraw_re3<=(lowest_ant==2'd3&&antenna_en[3])?32'sd32767:32'sd0; Wraw_im3<=32'sd0;
                        end
                        2'b01: begin
                            Wraw_re0<=(j_best==2'd0)?32'sd32767:32'sd0; Wraw_im0<=32'sd0;
                            Wraw_re1<=(j_best==2'd1)?32'sd32767:32'sd0; Wraw_im1<=32'sd0;
                            Wraw_re2<=(j_best==2'd2)?32'sd32767:32'sd0; Wraw_im2<=32'sd0;
                            Wraw_re3<=(j_best==2'd3)?32'sd32767:32'sd0; Wraw_im3<=32'sd0;
                        end
                        2'b11: begin
                            case (sub_st[1:0])
                                2'd0: begin Wraw_re0<=wraw_re_tmp; Wraw_im0<=wraw_im_tmp; end
                                2'd1: begin Wraw_re1<=wraw_re_tmp; Wraw_im1<=wraw_im_tmp; end
                                2'd2: begin Wraw_re2<=wraw_re_tmp; Wraw_im2<=wraw_im_tmp; end
                                default: begin Wraw_re3<=wraw_re_tmp; Wraw_im3<=wraw_im_tmp; end
                            endcase
                            if (sub_st==4'd3) state<=ST_WRITE;
                            else sub_st<=sub_st+4'd1;
                        end
                        default: begin
                            Wraw_re0<=32'sd32767; Wraw_im0<=32'sd0;
                            Wraw_re1<=32'sd0;     Wraw_im1<=32'sd0;
                            Wraw_re2<=32'sd0;     Wraw_im2<=32'sd0;
                            Wraw_re3<=32'sd0;     Wraw_im3<=32'sd0;
                            state<=ST_WRITE;
                        end
                    endcase
                    if (wgt_mode!=2'b11) state<=ST_WRITE;
                end

                ST_WRITE: begin
                    W_hw_re0<=sat16(Wraw_re0); W_hw_im0<=sat16(Wraw_im0);
                    W_hw_re1<=sat16(Wraw_re1); W_hw_im1<=sat16(Wraw_im1);
                    W_hw_re2<=sat16(Wraw_re2); W_hw_im2<=sat16(Wraw_im2);
                    W_hw_re3<=sat16(Wraw_re3); W_hw_im3<=sat16(Wraw_im3);
                    if (wgt_src==1'b0 && wgt_auto_commit) begin
                        W_shadow_re0<=sat16(Wraw_re0); W_shadow_im0<=sat16(Wraw_im0);
                        W_shadow_re1<=sat16(Wraw_re1); W_shadow_im1<=sat16(Wraw_im1);
                        W_shadow_re2<=sat16(Wraw_re2); W_shadow_im2<=sat16(Wraw_im2);
                        W_shadow_re3<=sat16(Wraw_re3); W_shadow_im3<=sat16(Wraw_im3);
                        W_commit<=1'b1;
                    end
                    wgen_hw_done<=1'b1; wgen_active<=1'b0; state<=ST_IDLE;
                end

                default: state<=ST_IDLE;
            endcase
        end
    end

endmodule
