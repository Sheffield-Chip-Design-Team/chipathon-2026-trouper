// sd_remod_multiplierless.v
//
// Bit-exact arithmetic implementation candidate for src/remod/sd_remod.v.
// The loop topology, state widths, saturation, coefficients, latency, enable
// behaviour, and I/O interface are unchanged.  Only the Q8 feed-forward cone
// is rewritten as shifts and balanced additions:
//
//   377*s1 = (3*s1)<<7 - 7*s1
//   106*s2 = (3*s2)<<5 + (5*s2)<<1
//    -8*s3 - 8*s4 = -8*(s3+s4)
//
// The complete feed-forward value fits in signed 25 bits:
//   (377+106+8+8)*32768 + 254*256 = 16,416,256 < 2^24.
// This lets the final sum and sign test stay at 25 bits instead of the
// deployed RTL's conservative 27 bits.  This file is an rtl-test experiment;
// it is deliberately not used by the working src/ tree.

`default_nettype none

module sd_remod_multiplierless (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire        in_valid,
    input  wire        en,
    output reg         out_i,
    output reg         out_q
);

    function signed [15:0] sat16;
        input signed [16:0] v;
        begin
            if      (v > 17'sd32767)  sat16 = 16'sd32767;
            else if (v < -17'sd32768) sat16 = -16'sd32768;
            else                      sat16 = v[15:0];
        end
    endfunction

    reg signed [15:0] s1_i, s2_i, s3_i, s4_i;
    reg signed [15:0] s1_q, s2_q, s3_q, s4_q;
    reg signed [7:0]  in_i_lat, in_q_lat;

    wire signed [11:0] x_i = {{4{in_i_lat[7]}}, in_i_lat};
    wire signed [11:0] x_q = {{4{in_q_lat[7]}}, in_q_lat};
    wire signed [11:0] y_i_fb = out_i ? 12'sd127 : -12'sd127;
    wire signed [11:0] y_q_fb = out_q ? 12'sd127 : -12'sd127;

    wire signed [12:0] e_i = $signed({x_i[11], x_i}) - $signed({y_i_fb[11], y_i_fb});
    wire signed [12:0] e_q = $signed({x_q[11], x_q}) - $signed({y_q_fb[11], y_q_fb});

    wire signed [16:0] s1_i_next = $signed({s1_i[15], s1_i}) + {{4{e_i[12]}}, e_i};
    wire signed [16:0] s1_q_next = $signed({s1_q[15], s1_q}) + {{4{e_q[12]}}, e_q};
    wire signed [16:0] s2_i_next = $signed({s2_i[15], s2_i}) + $signed({s1_i[15], s1_i});
    wire signed [16:0] s2_q_next = $signed({s2_q[15], s2_q}) + $signed({s1_q[15], s1_q});
    wire signed [16:0] s3_i_next = $signed({s3_i[15], s3_i}) + $signed({s2_i[15], s2_i});
    wire signed [16:0] s3_q_next = $signed({s3_q[15], s3_q}) + $signed({s2_q[15], s2_q});
    wire signed [16:0] s4_i_next = $signed({s4_i[15], s4_i}) + $signed({s3_i[15], s3_i});
    wire signed [16:0] s4_q_next = $signed({s4_q[15], s4_q}) + $signed({s3_q[15], s3_q});

    // Explicit 25-bit sign extension keeps every shift and intermediate sum
    // signed and wide enough.  The grouping is intentional: it exposes two
    // independent partial-sum cones followed by one final carry propagation.
    wire signed [24:0] s1_i_w = {{9{s1_i[15]}}, s1_i};
    wire signed [24:0] s2_i_w = {{9{s2_i[15]}}, s2_i};
    wire signed [24:0] s1_q_w = {{9{s1_q[15]}}, s1_q};
    wire signed [24:0] s2_q_w = {{9{s2_q[15]}}, s2_q};

    wire signed [16:0] s34_i = $signed({s3_i[15], s3_i})
                                  + $signed({s4_i[15], s4_i});
    wire signed [16:0] s34_q = $signed({s3_q[15], s3_q})
                                  + $signed({s4_q[15], s4_q});
    wire signed [24:0] s34_i_w = {{8{s34_i[16]}}, s34_i};
    wire signed [24:0] s34_q_w = {{8{s34_q[16]}}, s34_q};

    // Booth-style factorizations keep each coefficient network to two adder
    // levels: form the small odd multiples in parallel, then combine them.
    wire signed [24:0] s1_i_x3 = s1_i_w + (s1_i_w <<< 1);
    wire signed [24:0] s1_i_x7 = (s1_i_w <<< 3) - s1_i_w;
    wire signed [24:0] s2_i_x3 = s2_i_w + (s2_i_w <<< 1);
    wire signed [24:0] s2_i_x5 = s2_i_w + (s2_i_w <<< 2);
    wire signed [24:0] w1_i = (s1_i_x3 <<< 7) - s1_i_x7;
    wire signed [24:0] w2_i = (s2_i_x3 <<< 5) + (s2_i_x5 <<< 1);
    wire signed [24:0] w34_i = -(s34_i_w <<< 3);

    wire signed [24:0] s1_q_x3 = s1_q_w + (s1_q_w <<< 1);
    wire signed [24:0] s1_q_x7 = (s1_q_w <<< 3) - s1_q_w;
    wire signed [24:0] s2_q_x3 = s2_q_w + (s2_q_w <<< 1);
    wire signed [24:0] s2_q_x5 = s2_q_w + (s2_q_w <<< 2);
    wire signed [24:0] w1_q = (s1_q_x3 <<< 7) - s1_q_x7;
    wire signed [24:0] w2_q = (s2_q_x3 <<< 5) + (s2_q_x5 <<< 1);
    wire signed [24:0] w34_q = -(s34_q_w <<< 3);

    wire signed [24:0] e_i_q8 = {{4{e_i[12]}}, e_i, 8'b0};
    wire signed [24:0] e_q_q8 = {{4{e_q[12]}}, e_q, 8'b0};

    wire signed [24:0] sum_lo_i = e_i_q8 + w1_i;
    wire signed [24:0] sum_hi_i = w2_i + w34_i;
    wire signed [24:0] sum_lo_q = e_q_q8 + w1_q;
    wire signed [24:0] sum_hi_q = w2_q + w34_q;
    wire signed [24:0] v_i = sum_lo_i + sum_hi_i;
    wire signed [24:0] v_q = sum_lo_q + sum_hi_q;

    wire q_i = !v_i[24];
    wire q_q = !v_q[24];

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            s1_i <= 16'sd0; s2_i <= 16'sd0; s3_i <= 16'sd0; s4_i <= 16'sd0;
            s1_q <= 16'sd0; s2_q <= 16'sd0; s3_q <= 16'sd0; s4_q <= 16'sd0;
            in_i_lat <= 8'sd0; in_q_lat <= 8'sd0;
            out_i <= 1'b0; out_q <= 1'b0;
        end else begin
            if (in_valid) begin
                in_i_lat <= in_i;
                in_q_lat <= in_q;
            end
            if (!en) begin
                s1_i <= 16'sd0; s2_i <= 16'sd0; s3_i <= 16'sd0; s4_i <= 16'sd0;
                s1_q <= 16'sd0; s2_q <= 16'sd0; s3_q <= 16'sd0; s4_q <= 16'sd0;
                out_i <= 1'b0;
                out_q <= 1'b0;
            end else begin
                s1_i <= sat16(s1_i_next);
                s1_q <= sat16(s1_q_next);
                s2_i <= sat16(s2_i_next);
                s2_q <= sat16(s2_q_next);
                s3_i <= sat16(s3_i_next);
                s3_q <= sat16(s3_q_next);
                s4_i <= sat16(s4_i_next);
                s4_q <= sat16(s4_q_next);
                out_i <= q_i;
                out_q <= q_q;
            end
        end
    end

endmodule
`default_nettype wire
