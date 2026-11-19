// sd_remod_multiplierless.v
//
// 3rd-order CIFF sigma-delta re-modulator core, instantiated by sd_remod.v.
// CIFF3 REDESIGN 2026-10-03 -- see planning/sd-remod-ciff3-redesign-2026-10-03.md
// and the bit-true model sim/models/sd_remod.py (config CIFF3).
//
// Why it changed: the 2026-09-05 core was a nominal 4th-order CIFF with Q8
// taps (377, 106, -8, -8). The negative A3/A4 put a real closed-loop pole at
// ~+1.2 for every quantizer gain (positive feedback at DC), so s3/s4 ran to
// the sat16 rail within ~30 clocks of reset and the loop behaved as a
// 2nd-order shaper held in place by saturation. The "4th tap" itself was
// added to work around a pole-sum constraint that only exists if the 1-bit
// quantizer gain is assumed fixed at 1; it is not.
//
// Loop (one update per clk_32m, registered quantizer):
//   e   = x - (out ? +508 : -508)              x: 10-bit, 4x int8 scale
//   v   = 256*e + 334*s1 + 89*s2 + 10*s3       (old s values)
//   s1' = sat13(s1 + e)
//   s2' = sat14(s2 + s1)
//   s3' = sat16(s3 + s2)
//   out' = (v >= 0)
// Taps are pole-placed for this exact topology (registered quantizer +
// delaying integrators + direct 256*e term): synthesizeNTF(3, OSR=64,
// opt=0, H_inf=1.4) poles plus one pole at z=0, implied quantizer gain 0.67.
// Linearised loop is stable for quantizer gains ~0.3x..3x nominal; s3 peaks
// at ~91% of its 16-bit range at 0.8 FS (-1.9 dBFS) and no integrator
// saturates below that, so the loop really is 3rd order across the
// TRPR-RMD-004 range (< -3 dBFS). Above it the saturating integrators give a
// clean recovery (overload-then-0.5 FS test: longest identical-bit run 5).
//
// Feed-forward constant multiplies are explicit shift/add networks (the
// 2026-09-05 investigation traced a general `*` here to the worst full-chip
// SS path):
//   334*s1 = (5*s1)<<6 + s1<<4 - s1<<1
//    89*s2 = s2<<6 + (3*s2)<<3 + s2
//    10*s3 = (5*s3)<<1
// |v| <= 256*1020 + 334*4096 + 89*8192 + 10*32768 = 2,685,952 < 2^22, so v
// and every partial sum fit in signed 23 bits.

`default_nettype none

module sd_remod_multiplierless (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire signed [9:0] in_i,
    input  wire signed [9:0] in_q,
    input  wire        in_valid,
    input  wire        en,
    output reg         out_i,
    output reg         out_q
);

    function signed [12:0] sat13;
        input signed [13:0] v;
        begin
            if      (v > 14'sd4095)  sat13 = 13'sd4095;
            else if (v < -14'sd4096) sat13 = -13'sd4096;
            else                     sat13 = v[12:0];
        end
    endfunction

    function signed [13:0] sat14;
        input signed [14:0] v;
        begin
            if      (v > 15'sd8191)  sat14 = 14'sd8191;
            else if (v < -15'sd8192) sat14 = -14'sd8192;
            else                     sat14 = v[13:0];
        end
    endfunction

    function signed [15:0] sat16;
        input signed [16:0] v;
        begin
            if      (v > 17'sd32767)  sat16 = 16'sd32767;
            else if (v < -17'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    reg signed [12:0] s1_i, s1_q;
    reg signed [13:0] s2_i, s2_q;
    reg signed [15:0] s3_i, s3_q;
    reg signed [9:0]  in_i_lat, in_q_lat;

    wire signed [11:0] x_i = {{2{in_i_lat[9]}}, in_i_lat};
    wire signed [11:0] x_q = {{2{in_q_lat[9]}}, in_q_lat};
    wire signed [11:0] y_i_fb = out_i ? 12'sd508 : -12'sd508;
    wire signed [11:0] y_q_fb = out_q ? 12'sd508 : -12'sd508;

    // |e| <= 512 + 508 = 1020: fits signed 12 bits.
    wire signed [11:0] e_i = x_i - y_i_fb;
    wire signed [11:0] e_q = x_q - y_q_fb;

    wire signed [13:0] s1_i_next = $signed({s1_i[12], s1_i}) + {{2{e_i[11]}}, e_i};
    wire signed [13:0] s1_q_next = $signed({s1_q[12], s1_q}) + {{2{e_q[11]}}, e_q};
    wire signed [14:0] s2_i_next = $signed({s2_i[13], s2_i}) + {{2{s1_i[12]}}, s1_i};
    wire signed [14:0] s2_q_next = $signed({s2_q[13], s2_q}) + {{2{s1_q[12]}}, s1_q};
    wire signed [16:0] s3_i_next = $signed({s3_i[15], s3_i}) + {{3{s2_i[13]}}, s2_i};
    wire signed [16:0] s3_q_next = $signed({s3_q[15], s3_q}) + {{3{s2_q[13]}}, s2_q};

    // 23-bit sign-extended operands for the feed-forward network.
    wire signed [22:0] e_i_w  = {{11{e_i[11]}}, e_i};
    wire signed [22:0] e_q_w  = {{11{e_q[11]}}, e_q};
    wire signed [22:0] s1_i_w = {{10{s1_i[12]}}, s1_i};
    wire signed [22:0] s1_q_w = {{10{s1_q[12]}}, s1_q};
    wire signed [22:0] s2_i_w = {{9{s2_i[13]}}, s2_i};
    wire signed [22:0] s2_q_w = {{9{s2_q[13]}}, s2_q};
    wire signed [22:0] s3_i_w = {{7{s3_i[15]}}, s3_i};
    wire signed [22:0] s3_q_w = {{7{s3_q[15]}}, s3_q};

    // Small odd multiples first (one adder level, in parallel), then combine.
    wire signed [22:0] s1_i_x5 = s1_i_w + (s1_i_w <<< 2);
    wire signed [22:0] s2_i_x3 = s2_i_w + (s2_i_w <<< 1);
    wire signed [22:0] s3_i_x5 = s3_i_w + (s3_i_w <<< 2);
    wire signed [22:0] w1_i  = (s1_i_x5 <<< 6) + (s1_i_w <<< 4) - (s1_i_w <<< 1); // 334*s1
    wire signed [22:0] w2_i  = (s2_i_w <<< 6) + (s2_i_x3 <<< 3) + s2_i_w;         //  89*s2
    wire signed [22:0] w3_i  = s3_i_x5 <<< 1;                                     //  10*s3

    wire signed [22:0] s1_q_x5 = s1_q_w + (s1_q_w <<< 2);
    wire signed [22:0] s2_q_x3 = s2_q_w + (s2_q_w <<< 1);
    wire signed [22:0] s3_q_x5 = s3_q_w + (s3_q_w <<< 2);
    wire signed [22:0] w1_q  = (s1_q_x5 <<< 6) + (s1_q_w <<< 4) - (s1_q_w <<< 1);
    wire signed [22:0] w2_q  = (s2_q_w <<< 6) + (s2_q_x3 <<< 3) + s2_q_w;
    wire signed [22:0] w3_q  = s3_q_x5 <<< 1;

    wire signed [22:0] sum_lo_i = (e_i_w <<< 8) + w1_i;
    wire signed [22:0] sum_hi_i = w2_i + w3_i;
    wire signed [22:0] sum_lo_q = (e_q_w <<< 8) + w1_q;
    wire signed [22:0] sum_hi_q = w2_q + w3_q;
    wire signed [22:0] v_i = sum_lo_i + sum_hi_i;
    wire signed [22:0] v_q = sum_lo_q + sum_hi_q;

    wire q_i = !v_i[22];
    wire q_q = !v_q[22];

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            s1_i <= 13'sd0; s2_i <= 14'sd0; s3_i <= 16'sd0;
            s1_q <= 13'sd0; s2_q <= 14'sd0; s3_q <= 16'sd0;
            in_i_lat <= 10'sd0; in_q_lat <= 10'sd0;
            out_i <= 1'b0; out_q <= 1'b0;
        end else begin
            if (in_valid) begin
                in_i_lat <= in_i;
                in_q_lat <= in_q;
            end
            if (!en) begin
                s1_i <= 13'sd0; s2_i <= 14'sd0; s3_i <= 16'sd0;
                s1_q <= 13'sd0; s2_q <= 14'sd0; s3_q <= 16'sd0;
                out_i <= 1'b0;
                out_q <= 1'b0;
            end else begin
                s1_i <= sat13(s1_i_next);
                s1_q <= sat13(s1_q_next);
                s2_i <= sat14(s2_i_next);
                s2_q <= sat14(s2_q_next);
                s3_i <= sat16(s3_i_next);
                s3_q <= sat16(s3_q_next);
                out_i <= q_i;
                out_q <= q_q;
            end
        end
    end

endmodule
`default_nettype wire
