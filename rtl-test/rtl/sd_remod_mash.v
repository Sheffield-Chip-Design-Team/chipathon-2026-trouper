// sd_remod_mash.v — 3rd-order MASH 1-1-1 ΣΔ re-modulator
//
// Architecture: Cascade of three independent 1st-order error-feedback loops.
//   Stage k+1 input = quantization error of stage k.
//   Unconditionally stable for any bounded input (each stage is 1st-order).
//   No coefficient multiplications — accumulators and error registers only.
//
// 3rd-order output: Y = q1 + Δq2 + Δ²q3  (MASH noise cancellation).
//   Δq2[n]  = q2[n] - q2[n-1]
//   Δ²q3[n] = q3[n] - 2·q3[n-1] + q3[n-2]
//   sign(Y) gives the 1-bit output with 3rd-order noise shaping.
//
// Bit widths:
//   Error states s_k ∈ [-127,127] → 8-bit signed (provably bounded).
//   u_k ∈ [-254, 254]             → 9-bit signed.
//   q_k ∈ {-127, +127}           → 8-bit signed.
//   Δq2  ∈ [-254, 254]           → 9-bit signed.
//   Δ²q3 ∈ [-508, 508]           → 10-bit signed.
//   Y    ∈ [-889, 889]            → 11-bit signed.
//
// Interface identical to sd_remod.v for drop-in synthesis comparison.

`default_nettype none
module sd_remod_mash (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire        in_valid,
    input  wire        en,
    output reg         out_i,
    output reg         out_q
);

    localparam signed [7:0] FB_POS = 8'sd127;
    localparam signed [7:0] FB_NEG = -8'sd127;

    reg signed [7:0] in_i_lat, in_q_lat;

    // Error state registers (bounded ±127, no saturation needed)
    reg signed [7:0] s1_i, s2_i, s3_i;
    reg signed [7:0] s1_q, s2_q, s3_q;

    // Registered quantizer outputs for MASH differencing
    reg signed [7:0] q2_i_r,  q2_q_r;    // q2[n-1]
    reg signed [7:0] q3_i_r1, q3_q_r1;   // q3[n-1]
    reg signed [7:0] q3_i_r2, q3_q_r2;   // q3[n-2]

    // -----------------------------------------------------------------------
    // Stage 1 — input: latched in_i/in_q
    // -----------------------------------------------------------------------
    wire signed [8:0] u1_i = $signed({in_i_lat[7], in_i_lat}) + $signed({s1_i[7], s1_i});
    wire signed [8:0] u1_q = $signed({in_q_lat[7], in_q_lat}) + $signed({s1_q[7], s1_q});
    wire signed [7:0] q1_i = u1_i[8] ? FB_NEG : FB_POS;
    wire signed [7:0] q1_q = u1_q[8] ? FB_NEG : FB_POS;
    wire signed [7:0] ns1_i = u1_i[7:0] - q1_i;
    wire signed [7:0] ns1_q = u1_q[7:0] - q1_q;

    // -----------------------------------------------------------------------
    // Stage 2 — input: stage 1 error s1
    // -----------------------------------------------------------------------
    wire signed [8:0] u2_i = $signed({s1_i[7], s1_i}) + $signed({s2_i[7], s2_i});
    wire signed [8:0] u2_q = $signed({s1_q[7], s1_q}) + $signed({s2_q[7], s2_q});
    wire signed [7:0] q2_i = u2_i[8] ? FB_NEG : FB_POS;
    wire signed [7:0] q2_q = u2_q[8] ? FB_NEG : FB_POS;
    wire signed [7:0] ns2_i = u2_i[7:0] - q2_i;
    wire signed [7:0] ns2_q = u2_q[7:0] - q2_q;

    // -----------------------------------------------------------------------
    // Stage 3 — input: stage 2 error s2
    // -----------------------------------------------------------------------
    wire signed [8:0] u3_i = $signed({s2_i[7], s2_i}) + $signed({s3_i[7], s3_i});
    wire signed [8:0] u3_q = $signed({s2_q[7], s2_q}) + $signed({s3_q[7], s3_q});
    wire signed [7:0] q3_i = u3_i[8] ? FB_NEG : FB_POS;
    wire signed [7:0] q3_q = u3_q[8] ? FB_NEG : FB_POS;
    wire signed [7:0] ns3_i = u3_i[7:0] - q3_i;
    wire signed [7:0] ns3_q = u3_q[7:0] - q3_q;

    // -----------------------------------------------------------------------
    // MASH combination: Y = q1 + Δq2 + Δ²q3
    // -----------------------------------------------------------------------
    // Δq2[n] = q2[n] - q2[n-1]   (9-bit)
    wire signed [8:0] dq2_i = $signed({q2_i[7], q2_i}) - $signed({q2_i_r[7], q2_i_r});
    wire signed [8:0] dq2_q = $signed({q2_q[7], q2_q}) - $signed({q2_q_r[7], q2_q_r});

    // Δ²q3[n] = q3[n] - 2·q3[n-1] + q3[n-2]   (10-bit)
    wire signed [9:0] d2q3_i = {{2{q3_i[7]}},    q3_i}
                              - {q3_i_r1[7], q3_i_r1, 1'b0}
                              + {{2{q3_i_r2[7]}}, q3_i_r2};
    wire signed [9:0] d2q3_q = {{2{q3_q[7]}},    q3_q}
                              - {q3_q_r1[7], q3_q_r1, 1'b0}
                              + {{2{q3_q_r2[7]}}, q3_q_r2};

    // Y = q1 + Δq2 + Δ²q3   (11-bit)
    wire signed [10:0] y_i = {{3{q1_i[7]}},   q1_i}
                           + {{2{dq2_i[8]}},   dq2_i}
                           + {d2q3_i[9],       d2q3_i};
    wire signed [10:0] y_q = {{3{q1_q[7]}},   q1_q}
                           + {{2{dq2_q[8]}},   dq2_q}
                           + {d2q3_q[9],       d2q3_q};

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            in_i_lat <= 8'sd0; in_q_lat <= 8'sd0;
            s1_i <= 8'sd0; s2_i <= 8'sd0; s3_i <= 8'sd0;
            s1_q <= 8'sd0; s2_q <= 8'sd0; s3_q <= 8'sd0;
            q2_i_r  <= 8'sd0; q2_q_r  <= 8'sd0;
            q3_i_r1 <= 8'sd0; q3_i_r2 <= 8'sd0;
            q3_q_r1 <= 8'sd0; q3_q_r2 <= 8'sd0;
            out_i <= 1'b0; out_q <= 1'b0;
        end else begin
            if (in_valid) begin
                in_i_lat <= in_i;
                in_q_lat <= in_q;
            end
            s1_i <= ns1_i; s2_i <= ns2_i; s3_i <= ns3_i;
            s1_q <= ns1_q; s2_q <= ns2_q; s3_q <= ns3_q;
            q2_i_r  <= q2_i;
            q2_q_r  <= q2_q;
            q3_i_r1 <= q3_i;   q3_i_r2 <= q3_i_r1;
            q3_q_r1 <= q3_q;   q3_q_r2 <= q3_q_r1;
            out_i <= en ? !y_i[10] : 1'b0;
            out_q <= en ? !y_q[10] : 1'b0;
        end
    end

endmodule
`default_nettype wire
