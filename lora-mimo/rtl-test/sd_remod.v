// sd_remod.v
// 3rd-order single-bit feed-forward sigma-delta re-modulator
// Based on SX1257 datasheet Figure 6-3: three delayed integrators,
// symmetric 1-bit feedback, and a feed-forward summer into the sign quantizer.

module sd_remod (
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

    reg signed [15:0] s1_i, s2_i, s3_i;
    reg signed [15:0] s1_q, s2_q, s3_q;
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

    // Feed-forward summer into the sign quantizer. Keep unity weights first;
    // coefficient tuning can follow once the loopback behaves correctly.
    wire signed [18:0] v_i = {{6{e_i[12]}}, e_i}
                           + {{3{s1_i[15]}}, s1_i}
                           + {{3{s2_i[15]}}, s2_i}
                           + {{3{s3_i[15]}}, s3_i};
    wire signed [18:0] v_q = {{6{e_q[12]}}, e_q}
                           + {{3{s1_q[15]}}, s1_q}
                           + {{3{s2_q[15]}}, s2_q}
                           + {{3{s3_q[15]}}, s3_q};

    wire q_i = !v_i[18];
    wire q_q = !v_q[18];

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            s1_i <= 16'sd0; s2_i <= 16'sd0; s3_i <= 16'sd0;
            s1_q <= 16'sd0; s2_q <= 16'sd0; s3_q <= 16'sd0;
            in_i_lat <= 8'sd0; in_q_lat <= 8'sd0;
            out_i <= 1'b0; out_q <= 1'b0;
        end else begin
            if (in_valid) begin
                in_i_lat <= in_i;
                in_q_lat <= in_q;
            end

            s1_i <= sat16(s1_i_next);
            s1_q <= sat16(s1_q_next);
            s2_i <= sat16(s2_i_next);
            s2_q <= sat16(s2_q_next);
            s3_i <= sat16(s3_i_next);
            s3_q <= sat16(s3_q_next);

            out_i <= en ? q_i : 1'b0;
            out_q <= en ? q_q : 1'b0;
        end
    end

endmodule
