// crit_path_test.v — isolated timing test for weight_gen critical paths
// Exercises every multiply in the post-fix NR loop and mag2 computation.
// Each DUT_* module maps to one clock cycle in the FSM.
// GF180MCU 3.3V 32 MHz target.

// sub_st 5 / 7: 16x32 inner product  r[15:0] * S[47:16]
module dut_nr_inner (
    input  wire        clk,
    input  wire [15:0] r,
    input  wire [31:0] s_slice,   // S[47:16]
    output reg  [63:0] nr_inner_r
);
    reg [7:0] r0_q, r1_q;
    reg [7:0] s0_q, s1_q, s2_q, s3_q;
    reg [15:0] pp00_q, pp01_q, pp02_q, pp03_q;
    reg [15:0] pp10_q, pp11_q, pp12_q, pp13_q;
    reg [7:0] pp00_ll_q, pp00_lh_q, pp00_hl_q, pp00_hh_q;
    reg [7:0] pp01_ll_q, pp01_lh_q, pp01_hl_q, pp01_hh_q;
    reg [7:0] pp02_ll_q, pp02_lh_q, pp02_hl_q, pp02_hh_q;
    reg [7:0] pp03_ll_q, pp03_lh_q, pp03_hl_q, pp03_hh_q;
    reg [7:0] pp10_ll_q, pp10_lh_q, pp10_hl_q, pp10_hh_q;
    reg [7:0] pp11_ll_q, pp11_lh_q, pp11_hl_q, pp11_hh_q;
    reg [7:0] pp12_ll_q, pp12_lh_q, pp12_hl_q, pp12_hh_q;
    reg [7:0] pp13_ll_q, pp13_lh_q, pp13_hl_q, pp13_hh_q;
    reg [47:0] sum0_q, sum1_q, sum2_q, sum3a_q, sum3b_q, sum3_q;
    reg [47:0] sum01_q, sum23_q, total_q;

    always @(posedge clk) begin
        r0_q <= r[7:0];
        r1_q <= r[15:8];
        s0_q <= s_slice[7:0];
        s1_q <= s_slice[15:8];
        s2_q <= s_slice[23:16];
        s3_q <= s_slice[31:24];

        pp00_ll_q <= r0_q[3:0] * s0_q[3:0];
        pp00_lh_q <= r0_q[3:0] * s0_q[7:4];
        pp00_hl_q <= r0_q[7:4] * s0_q[3:0];
        pp00_hh_q <= r0_q[7:4] * s0_q[7:4];
        pp00_q <= {8'd0, pp00_ll_q} + {4'd0, pp00_lh_q, 4'd0} + {4'd0, pp00_hl_q, 4'd0} + {pp00_hh_q, 8'd0};
        pp01_ll_q <= r0_q[3:0] * s1_q[3:0];
        pp01_lh_q <= r0_q[3:0] * s1_q[7:4];
        pp01_hl_q <= r0_q[7:4] * s1_q[3:0];
        pp01_hh_q <= r0_q[7:4] * s1_q[7:4];
        pp01_q <= {8'd0, pp01_ll_q} + {4'd0, pp01_lh_q, 4'd0} + {4'd0, pp01_hl_q, 4'd0} + {pp01_hh_q, 8'd0};
        pp02_ll_q <= r0_q[3:0] * s2_q[3:0];
        pp02_lh_q <= r0_q[3:0] * s2_q[7:4];
        pp02_hl_q <= r0_q[7:4] * s2_q[3:0];
        pp02_hh_q <= r0_q[7:4] * s2_q[7:4];
        pp02_q <= {8'd0, pp02_ll_q} + {4'd0, pp02_lh_q, 4'd0} + {4'd0, pp02_hl_q, 4'd0} + {pp02_hh_q, 8'd0};
        pp03_ll_q <= r0_q[3:0] * s3_q[3:0];
        pp03_lh_q <= r0_q[3:0] * s3_q[7:4];
        pp03_hl_q <= r0_q[7:4] * s3_q[3:0];
        pp03_hh_q <= r0_q[7:4] * s3_q[7:4];
        pp03_q <= {8'd0, pp03_ll_q} + {4'd0, pp03_lh_q, 4'd0} + {4'd0, pp03_hl_q, 4'd0} + {pp03_hh_q, 8'd0};
        pp10_ll_q <= r1_q[3:0] * s0_q[3:0];
        pp10_lh_q <= r1_q[3:0] * s0_q[7:4];
        pp10_hl_q <= r1_q[7:4] * s0_q[3:0];
        pp10_hh_q <= r1_q[7:4] * s0_q[7:4];
        pp10_q <= {8'd0, pp10_ll_q} + {4'd0, pp10_lh_q, 4'd0} + {4'd0, pp10_hl_q, 4'd0} + {pp10_hh_q, 8'd0};
        pp11_ll_q <= r1_q[3:0] * s1_q[3:0];
        pp11_lh_q <= r1_q[3:0] * s1_q[7:4];
        pp11_hl_q <= r1_q[7:4] * s1_q[3:0];
        pp11_hh_q <= r1_q[7:4] * s1_q[7:4];
        pp11_q <= {8'd0, pp11_ll_q} + {4'd0, pp11_lh_q, 4'd0} + {4'd0, pp11_hl_q, 4'd0} + {pp11_hh_q, 8'd0};
        pp12_ll_q <= r1_q[3:0] * s2_q[3:0];
        pp12_lh_q <= r1_q[3:0] * s2_q[7:4];
        pp12_hl_q <= r1_q[7:4] * s2_q[3:0];
        pp12_hh_q <= r1_q[7:4] * s2_q[7:4];
        pp12_q <= {8'd0, pp12_ll_q} + {4'd0, pp12_lh_q, 4'd0} + {4'd0, pp12_hl_q, 4'd0} + {pp12_hh_q, 8'd0};
        pp13_ll_q <= r1_q[3:0] * s3_q[3:0];
        pp13_lh_q <= r1_q[3:0] * s3_q[7:4];
        pp13_hl_q <= r1_q[7:4] * s3_q[3:0];
        pp13_hh_q <= r1_q[7:4] * s3_q[7:4];
        pp13_q <= {8'd0, pp13_ll_q} + {4'd0, pp13_lh_q, 4'd0} + {4'd0, pp13_hl_q, 4'd0} + {pp13_hh_q, 8'd0};

        sum0_q  <= {32'd0, pp00_q} + {24'd0, pp01_q, 8'd0};
        sum1_q  <= {16'd0, pp02_q, 16'd0} + {8'd0, pp03_q, 24'd0};
        sum2_q  <= {24'd0, pp10_q, 8'd0} + {16'd0, pp11_q, 16'd0};
        sum3a_q <= {8'd0, pp12_q, 24'd0};
        sum3b_q <= {pp13_q, 32'd0};
        sum3_q  <= sum3a_q + sum3b_q;
        sum01_q <= sum0_q + sum1_q;
        sum23_q <= sum2_q + sum3_q;
        total_q <= sum01_q + sum23_q;
        nr_inner_r <= {16'd0, total_q};
    end
endmodule
// sub_st 6/9: subtraction only — register the correction term (no multiply)
module dut_nr_corr (
    input  wire        clk,
    input  wire [63:0] nr_inner_r,
    output reg  [31:0] nr_corr_r
);
    always @(posedge clk)
        nr_corr_r <= 32'd65536 - nr_inner_r[47:16];
endmodule

// sub_st 7/10: outer multiply r[15:0] * corr (pre-registered, no sub in path)
module dut_nr_outer (
    input  wire        clk,
    input  wire [15:0] r,
    input  wire [31:0] nr_corr_r,
    output reg  [63:0] nr_tmp
);
    reg [7:0] a0_q, a1_q;
    reg [7:0] b0_q, b1_q, b2_q, b3_q;
    reg [15:0] pp00_q, pp01_q, pp02_q, pp03_q;
    reg [15:0] pp10_q, pp11_q, pp12_q, pp13_q;
    reg [7:0] pp00_ll_q, pp00_lh_q, pp00_hl_q, pp00_hh_q;
    reg [7:0] pp01_ll_q, pp01_lh_q, pp01_hl_q, pp01_hh_q;
    reg [7:0] pp02_ll_q, pp02_lh_q, pp02_hl_q, pp02_hh_q;
    reg [7:0] pp03_ll_q, pp03_lh_q, pp03_hl_q, pp03_hh_q;
    reg [7:0] pp10_ll_q, pp10_lh_q, pp10_hl_q, pp10_hh_q;
    reg [7:0] pp11_ll_q, pp11_lh_q, pp11_hl_q, pp11_hh_q;
    reg [7:0] pp12_ll_q, pp12_lh_q, pp12_hl_q, pp12_hh_q;
    reg [7:0] pp13_ll_q, pp13_lh_q, pp13_hl_q, pp13_hh_q;
    reg [47:0] sum0_q, sum1_q, sum2_q, sum3a_q, sum3_q;
    reg [47:0] sum01_q, sum23_q, total_q;

    always @(posedge clk) begin
        a0_q <= r[7:0];
        a1_q <= r[15:8];
        b0_q <= nr_corr_r[7:0];
        b1_q <= nr_corr_r[15:8];
        b2_q <= nr_corr_r[23:16];
        b3_q <= nr_corr_r[31:24];

        pp00_ll_q <= a0_q[3:0] * b0_q[3:0];
        pp00_lh_q <= a0_q[3:0] * b0_q[7:4];
        pp00_hl_q <= a0_q[7:4] * b0_q[3:0];
        pp00_hh_q <= a0_q[7:4] * b0_q[7:4];
        pp00_q <= {8'd0, pp00_ll_q} + {4'd0, pp00_lh_q, 4'd0} + {4'd0, pp00_hl_q, 4'd0} + {pp00_hh_q, 8'd0};
        pp01_ll_q <= a0_q[3:0] * b1_q[3:0];
        pp01_lh_q <= a0_q[3:0] * b1_q[7:4];
        pp01_hl_q <= a0_q[7:4] * b1_q[3:0];
        pp01_hh_q <= a0_q[7:4] * b1_q[7:4];
        pp01_q <= {8'd0, pp01_ll_q} + {4'd0, pp01_lh_q, 4'd0} + {4'd0, pp01_hl_q, 4'd0} + {pp01_hh_q, 8'd0};
        pp02_ll_q <= a0_q[3:0] * b2_q[3:0];
        pp02_lh_q <= a0_q[3:0] * b2_q[7:4];
        pp02_hl_q <= a0_q[7:4] * b2_q[3:0];
        pp02_hh_q <= a0_q[7:4] * b2_q[7:4];
        pp02_q <= {8'd0, pp02_ll_q} + {4'd0, pp02_lh_q, 4'd0} + {4'd0, pp02_hl_q, 4'd0} + {pp02_hh_q, 8'd0};
        pp03_ll_q <= a0_q[3:0] * b3_q[3:0];
        pp03_lh_q <= a0_q[3:0] * b3_q[7:4];
        pp03_hl_q <= a0_q[7:4] * b3_q[3:0];
        pp03_hh_q <= a0_q[7:4] * b3_q[7:4];
        pp03_q <= {8'd0, pp03_ll_q} + {4'd0, pp03_lh_q, 4'd0} + {4'd0, pp03_hl_q, 4'd0} + {pp03_hh_q, 8'd0};
        pp10_ll_q <= a1_q[3:0] * b0_q[3:0];
        pp10_lh_q <= a1_q[3:0] * b0_q[7:4];
        pp10_hl_q <= a1_q[7:4] * b0_q[3:0];
        pp10_hh_q <= a1_q[7:4] * b0_q[7:4];
        pp10_q <= {8'd0, pp10_ll_q} + {4'd0, pp10_lh_q, 4'd0} + {4'd0, pp10_hl_q, 4'd0} + {pp10_hh_q, 8'd0};
        pp11_ll_q <= a1_q[3:0] * b1_q[3:0];
        pp11_lh_q <= a1_q[3:0] * b1_q[7:4];
        pp11_hl_q <= a1_q[7:4] * b1_q[3:0];
        pp11_hh_q <= a1_q[7:4] * b1_q[7:4];
        pp11_q <= {8'd0, pp11_ll_q} + {4'd0, pp11_lh_q, 4'd0} + {4'd0, pp11_hl_q, 4'd0} + {pp11_hh_q, 8'd0};
        pp12_ll_q <= a1_q[3:0] * b2_q[3:0];
        pp12_lh_q <= a1_q[3:0] * b2_q[7:4];
        pp12_hl_q <= a1_q[7:4] * b2_q[3:0];
        pp12_hh_q <= a1_q[7:4] * b2_q[7:4];
        pp12_q <= {8'd0, pp12_ll_q} + {4'd0, pp12_lh_q, 4'd0} + {4'd0, pp12_hl_q, 4'd0} + {pp12_hh_q, 8'd0};
        pp13_ll_q <= a1_q[3:0] * b3_q[3:0];
        pp13_lh_q <= a1_q[3:0] * b3_q[7:4];
        pp13_hl_q <= a1_q[7:4] * b3_q[3:0];
        pp13_hh_q <= a1_q[7:4] * b3_q[7:4];
        pp13_q <= {8'd0, pp13_ll_q} + {4'd0, pp13_lh_q, 4'd0} + {4'd0, pp13_hl_q, 4'd0} + {pp13_hh_q, 8'd0};

        sum0_q  <= {32'd0, pp00_q};
        sum1_q  <= {24'd0, pp01_q, 8'd0} + {24'd0, pp10_q, 8'd0};
        sum2_q  <= {16'd0, pp02_q, 16'd0} + {16'd0, pp11_q, 16'd0};
        sum3a_q <= {8'd0, pp03_q, 24'd0} + {8'd0, pp12_q, 24'd0};
        sum3_q  <= sum3a_q + {pp13_q, 32'd0};
        sum01_q <= sum0_q + sum1_q;
        sum23_q <= sum2_q + sum3_q;
        total_q <= sum01_q + sum23_q;
        nr_tmp  <= {16'd0, total_q};
    end
endmodule

// ST_COMPUTE sub_st 0-3: mag2 path  (was 32x32, now 16x16 after fix)
module dut_mag2 (
    input  wire        clk,
    input  wire signed [15:0] hc_i, hc_q,
    output reg  [63:0] mag2_out
);
    reg [15:0] i_abs_q, q_abs_q;
    reg [15:0] i_lo2_q, i_hi2_q, i_hilo_q;
    reg [15:0] q_lo2_q, q_hi2_q, q_hilo_q;
    reg [31:0] i2_q, q2_q;
    reg [32:0] sum_q;

    wire [15:0] i_abs = hc_i[15] ? (~hc_i + 16'd1) : hc_i;
    wire [15:0] q_abs = hc_q[15] ? (~hc_q + 16'd1) : hc_q;

    always @(posedge clk) begin
        i_abs_q <= i_abs;
        q_abs_q <= q_abs;

        i_lo2_q  <= i_abs_q[7:0]  * i_abs_q[7:0];
        i_hi2_q  <= i_abs_q[15:8] * i_abs_q[15:8];
        i_hilo_q <= i_abs_q[15:8] * i_abs_q[7:0];
        q_lo2_q  <= q_abs_q[7:0]  * q_abs_q[7:0];
        q_hi2_q  <= q_abs_q[15:8] * q_abs_q[15:8];
        q_hilo_q <= q_abs_q[15:8] * q_abs_q[7:0];

        i2_q <= {i_hi2_q, 16'd0} + {7'd0, i_hilo_q, 9'd0} + {16'd0, i_lo2_q};
        q2_q <= {q_hi2_q, 16'd0} + {7'd0, q_hilo_q, 9'd0} + {16'd0, q_lo2_q};

        sum_q <= {1'b0, i2_q} + {1'b0, q2_q};
        mag2_out <= {31'd0, sum_q};
    end
endmodule

// ST_CALIBRATE: 16x16 complex multiply  (reference — should close easily)

module signed_mul16_pipe (
    input  wire               clk,
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    output reg  signed [31:0] p
);
    wire [15:0] a_abs_w = a[15] ? (~a + 16'd1) : a;
    wire [15:0] b_abs_w = b[15] ? (~b + 16'd1) : b;
    wire        sign_w  = a[15] ^ b[15];

    reg [15:0] a_abs_q, b_abs_q;
    reg        sign_q0, sign_q1, sign_q2, sign_q3;
    reg [7:0] pp00_q, pp01_q, pp02_q, pp03_q;
    reg [7:0] pp10_q, pp11_q, pp12_q, pp13_q;
    reg [7:0] pp20_q, pp21_q, pp22_q, pp23_q;
    reg [7:0] pp30_q, pp31_q, pp32_q, pp33_q;
    reg [31:0] row0_q, row1_q, row2_q, row3_q;
    reg [31:0] sum01_q, sum23_q, mag_q;

    always @(posedge clk) begin
        a_abs_q <= a_abs_w;
        b_abs_q <= b_abs_w;
        sign_q0 <= sign_w;

        pp00_q <= a_abs_q[3:0]   * b_abs_q[3:0];
        pp01_q <= a_abs_q[3:0]   * b_abs_q[7:4];
        pp02_q <= a_abs_q[3:0]   * b_abs_q[11:8];
        pp03_q <= a_abs_q[3:0]   * b_abs_q[15:12];
        pp10_q <= a_abs_q[7:4]   * b_abs_q[3:0];
        pp11_q <= a_abs_q[7:4]   * b_abs_q[7:4];
        pp12_q <= a_abs_q[7:4]   * b_abs_q[11:8];
        pp13_q <= a_abs_q[7:4]   * b_abs_q[15:12];
        pp20_q <= a_abs_q[11:8]  * b_abs_q[3:0];
        pp21_q <= a_abs_q[11:8]  * b_abs_q[7:4];
        pp22_q <= a_abs_q[11:8]  * b_abs_q[11:8];
        pp23_q <= a_abs_q[11:8]  * b_abs_q[15:12];
        pp30_q <= a_abs_q[15:12] * b_abs_q[3:0];
        pp31_q <= a_abs_q[15:12] * b_abs_q[7:4];
        pp32_q <= a_abs_q[15:12] * b_abs_q[11:8];
        pp33_q <= a_abs_q[15:12] * b_abs_q[15:12];
        sign_q1 <= sign_q0;

        row0_q <= {24'd0, pp00_q} + {20'd0, pp01_q, 4'd0} + {16'd0, pp02_q, 8'd0} + {12'd0, pp03_q, 12'd0};
        row1_q <= {20'd0, pp10_q, 4'd0} + {16'd0, pp11_q, 8'd0} + {12'd0, pp12_q, 12'd0} + {8'd0, pp13_q, 16'd0};
        row2_q <= {16'd0, pp20_q, 8'd0} + {12'd0, pp21_q, 12'd0} + {8'd0, pp22_q, 16'd0} + {4'd0, pp23_q, 20'd0};
        row3_q <= {12'd0, pp30_q, 12'd0} + {8'd0, pp31_q, 16'd0} + {4'd0, pp32_q, 20'd0} + {pp33_q, 24'd0};
        sign_q2 <= sign_q1;

        sum01_q <= row0_q + row1_q;
        sum23_q <= row2_q + row3_q;
        sign_q3 <= sign_q2;

        mag_q <= sum01_q + sum23_q;
        p <= sign_q3 ? -(mag_q) : (mag_q);
    end
endmodule

module dut_calib (
    input  wire        clk,
    input  wire signed [15:0] h_i, h_q, cal_re, cal_im,
    output reg  signed [31:0] hc_i_out, hc_q_out
);
    wire signed [31:0] ii_w, qq_w, qi_w, iq_w;
    reg  signed [32:0] re_sum_q, im_diff_q;

    signed_mul16_pipe u_ii (.clk(clk), .a(h_i), .b(cal_re), .p(ii_w));
    signed_mul16_pipe u_qq (.clk(clk), .a(h_q), .b(cal_im), .p(qq_w));
    signed_mul16_pipe u_qi (.clk(clk), .a(h_q), .b(cal_re), .p(qi_w));
    signed_mul16_pipe u_iq (.clk(clk), .a(h_i), .b(cal_im), .p(iq_w));

    always @(posedge clk) begin
        re_sum_q  <= {ii_w[31], ii_w} + {qq_w[31], qq_w};
        im_diff_q <= {qi_w[31], qi_w} - {iq_w[31], iq_w};
        hc_i_out  <= re_sum_q >>> 15;
        hc_q_out  <= im_diff_q >>> 15;
    end
endmodule
