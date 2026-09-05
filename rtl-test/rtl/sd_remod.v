// sd_remod.v
// 4th-order CIFF single-bit ΣΔ re-modulator, derived for the Trouper->SX1302
// receive path. NOT SX1257 Figure 6-3 compliant -- that figure is a 3rd-order
// modulator for the SX1257's own TRANSMIT I_IN/Q_IN interface (datasheet
// p.37); Trouper instead drives the SX1302's receive-side I/Q pins, whose
// normal SX1257 source is a 5th-order continuous-time sigma-delta ADC
// (datasheet p.24, DS_SX1257_V1.2.pdf). The SX1302 sees a synchronized 1-bit
// I/Q stream and does not encode/require a particular modulator order --
// what matters is correct average signal level, 32 MS/s timing, in-band
// SQNR, and stability, all still met (see below). 4th order (not 3rd) is
// what this loop needed once its real, physically-mandatory quantizer
// register delay is accounted for -- see the excess-loop-delay note below.
//
// Architecture: Cascade of Integrators, Feed-Forward (CIFF).
//   Four saturating int16 integrators; Q8 weighted feed-forward summer; sign quantizer.
//
// Order note: the loop filter is 4th-order, not the 3rd-order the SX1257 datasheet
// figure shows. The quantizer decision (out_i/out_q) is necessarily REGISTERED --
// out_i <= q_i, one clock after v_i is computed -- because e_i depends on the fed-
// back out_i and computing both combinationally in the same cycle would require an
// unrealizable same-cycle algebraic loop (out_i -> e_i -> v_i -> out_i). That
// register is one extra full-sample delay beyond the delay already inherent in each
// integrator stage, i.e. an "excess loop delay" of a full Ts. A 3rd-order loop filter
// synthesized for the idealized (zero-extra-delay) case cannot realize a well-margined
// NTF once this extra register is accounted for -- confirmed analytically: RTL's real
// (with-delay) closed-loop NTF denominator structurally pins the pole-sum at exactly 2,
// but any well-conditioned 3rd-order NTF at OSR=64 needs a pole-sum around 2.2 -- not
// reachable by ANY choice of a 3-tap A1/A2/A3, only approximable, and the best 3-tap
// approximation (H_inf~1.66 by linear NTF, matching the original mis-derived
// A1=205/A2=74/A3=11 coefficients' apparent intent) collapses to a real stability
// cliff around amp~0.55-0.6, short of the -3dBFS (amp=0.708) requirement below. The
// 4th tap (A4) restores the missing degree of freedom needed to place the NTF's poles
// on target given this extra register; see planning doc for the full derivation.
//
//   Coefficients: 3 poles from synthesizeNTF(order=3, OSR=64, opt=0, H_inf=1.5) via
//   python-deltasigma, plus 2 auxiliary poles (at z=0.30 and z=0.45, chosen by a grid
//   search over real-valued bit-exact SQNR at the required amp=0.708 stability point,
//   not just linear H_inf) placed to restore full pole-placement freedom under RTL's
//   real (with-delay) loop structure. Solving the resulting linear system for
//   A1..A4 gives a = [1.474, 0.414, -0.033, -0.033] -> Q8 (rounded): A1=377, A2=106,
//   A3=-8, A4=-8. Measured (bit-exact iverilog sim, job 5568/5569/later): SQNR clears
//   the >40dB spec across amp=0.3..0.708 with NO stability cliff observed up to at
//   least amp=0.75 (vs the original 3-tap coefficients, which measured ~14.8dB before
//   the separate scale-factor fix below, and ~20dB after it -- still far short of spec
//   even once correctly scaled, because the coefficients were never valid for this
//   loop's real delay in the first place).
//
// SX1257 §6.2.3: "noise shaper should be stable for input signals lower than -3 dBFS;
//   integrator outputs are saturated to avoid wraparound."

`default_nettype none
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

    // Q8 feedforward coefficients (a_k * 256). Widened to 10-bit signed (A1=377
    // exceeds the old 9-bit A1's 255 max) -- see header for derivation.
    localparam signed [9:0] A1 = 10'sd377;   //  1.473
    localparam signed [9:0] A2 = 10'sd106;   //  0.414
    localparam signed [9:0] A3 = -10'sd8;    // -0.031
    localparam signed [9:0] A4 = -10'sd8;    // -0.031

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

    // Cascade of delaying integrators: each stage sums the PREVIOUS cycle's
    // registered value of the stage before it (never a same-cycle/just-updated
    // value) -- the only physically realizable clocked-hardware topology (see
    // header). s4 extends the same pattern from s3.
    wire signed [16:0] s1_i_next = $signed({s1_i[15], s1_i}) + {{4{e_i[12]}}, e_i};
    wire signed [16:0] s1_q_next = $signed({s1_q[15], s1_q}) + {{4{e_q[12]}}, e_q};
    wire signed [16:0] s2_i_next = $signed({s2_i[15], s2_i}) + $signed({s1_i[15], s1_i});
    wire signed [16:0] s2_q_next = $signed({s2_q[15], s2_q}) + $signed({s1_q[15], s1_q});
    wire signed [16:0] s3_i_next = $signed({s3_i[15], s3_i}) + $signed({s2_i[15], s2_i});
    wire signed [16:0] s3_q_next = $signed({s3_q[15], s3_q}) + $signed({s2_q[15], s2_q});
    wire signed [16:0] s4_i_next = $signed({s4_i[15], s4_i}) + $signed({s3_i[15], s3_i});
    wire signed [16:0] s4_q_next = $signed({s4_q[15], s4_q}) + $signed({s3_q[15], s3_q});

    // CIFF Q8 weighted feed-forward summer. Declared width (25 bits, [24:0]) is
    // narrower than the Verilog-computed product width (17-bit operand * 10-bit
    // coefficient = 27 bits) -- silently truncates the top 2 bits, same as the
    // pre-existing w1/w2/w3 pattern. Safe here only because the actual data range
    // never needs the full nominal width: max |s_k|=32768 (post-sat16) * max
    // |A_k|=377 = 12,353,536, which needs 25 bits (24 magnitude + 1 sign) --
    // fits [24:0] exactly. Re-check this bound if A1..A4 are ever re-derived
    // with a larger magnitude.
    wire signed [24:0] w1_i = $signed({s1_i[15], s1_i}) * A1;
    wire signed [24:0] w2_i = $signed({s2_i[15], s2_i}) * A2;
    wire signed [24:0] w3_i = $signed({s3_i[15], s3_i}) * A3;
    wire signed [24:0] w4_i = $signed({s4_i[15], s4_i}) * A4;
    wire signed [24:0] w1_q = $signed({s1_q[15], s1_q}) * A1;
    wire signed [24:0] w2_q = $signed({s2_q[15], s2_q}) * A2;
    wire signed [24:0] w3_q = $signed({s3_q[15], s3_q}) * A3;
    wire signed [24:0] w4_q = $signed({s4_q[15], s4_q}) * A4;

    // Scale e by 256 (Q8) to match weighted integrators, then sum. e_i/e_q are
    // 13-bit; {{6{e_i[12]}}, e_i, 8'b0} sign-extends by 6 bits and shifts left
    // by 8 (x256, Q8) for a 27-bit result matching v_i's width and the w*_i
    // terms' scale ({{2{w1_i[24]}}, w1_i} is also 27 bits). Worst-case sum
    // magnitude (all four w terms plus the e term at their bounds) is well
    // under the 27-bit signed range -- see the width comment on w1_i above for
    // the per-term bound.
    wire signed [26:0] v_i = {{6{e_i[12]}}, e_i, 8'b0}
                           + {{2{w1_i[24]}}, w1_i}
                           + {{2{w2_i[24]}}, w2_i}
                           + {{2{w3_i[24]}}, w3_i}
                           + {{2{w4_i[24]}}, w4_i};
    wire signed [26:0] v_q = {{6{e_q[12]}}, e_q, 8'b0}
                           + {{2{w1_q[24]}}, w1_q}
                           + {{2{w2_q[24]}}, w2_q}
                           + {{2{w3_q[24]}}, w3_q}
                           + {{2{w4_q[24]}}, w4_q};

    wire q_i = !v_i[26];
    wire q_q = !v_q[26];

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
                // Hold the loop at its reset state while disabled. If the
                // integrators kept running, the gated-low output would feed
                // back as a constant -127, railing all four stages within
                // ~256 cycles and forcing a recovery transient on re-enable.
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
