// mrc_combiner.v
// MRC combiner — serialised I/Q multiply (Option A).
//
// Each complex MAC is split into two sub-cycles sharing two 8×8 multipliers:
//   Sub-cycle 1 (w_re): mul_i = w_re × x_i,  mul_q = w_re × x_q  → save a_r, c_r
//   Sub-cycle 2 (w_im): mul_i = w_im × x_q,  mul_q = w_im × x_i
//     prod_i = a_r − mul_i = w_re×x_i − w_im×x_q
//     prod_q = c_r + mul_q = w_re×x_q + w_im×x_i
//
// Weight width: 8-bit signed (was 16-bit). 48 dB dynamic range — sufficient
// for 4-antenna MRC. Firmware writes weight to high byte of 16-bit shadow reg;
// trouper_top passes rb_w_shadow[hi_byte] to W_re/im ports.
// Multiplier: 8×8→16-bit (was 16×8→24-bit). prod_i_r/prod_q_r: 17-bit (not
// 16) -- the add path (prod_q = c_r + mul_q) reaches exactly +32768 at the
// legal int8 rail extreme (w_re=w_im=x_i=x_q=-128), one past a 16-bit signed
// max. Accumulator: 19-bit (was 26-bit) -- the 4-branch sum of that same
// extreme is 131072, one past an 18-bit signed max.
// Output shift: acc >>> (8 − pgs) — single combined shift replacing the old
// two-step (acc >>> 8) << pgs. Eliminates amplified truncation: worst-case
// loss < 0.05 dB across all pgs tiers. pgs ∈ [0,7] → net shift ∈ [1,8].
// post_gain_shift (0–7) is set per-packet by firmware from Zdiag to recover
// output amplitude for weak signals without touching the weight encoding.
// State count: 11. Budget: 64-clock iq_valid window (R=64); paced burst = 31 clocks.
// GF180MCU, 3.3V, 32 MHz IQ_CLK domain (the clk_16m port name is historical —
// trouper_top wires it to the single 32 MHz clk; there is no 16 MHz clock net).

`timescale 1ns/100ps

module mrc_combiner (
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire signed [7:0]  x_i0, x_q0, x_i1, x_q1,
    input  wire signed [7:0]  x_i2, x_q2, x_i3, x_q3,
    input  wire        x_valid,
    input  wire signed [7:0]  W_re0, W_im0, W_re1, W_im1,
    input  wire signed [7:0]  W_re2, W_im2, W_re3, W_im3,
    input  wire        W_valid,
    input  wire        mode,
    input  wire [1:0]  bypass_ant,
    input  wire [2:0]  post_gain_shift,
    output reg  signed [7:0] y_i, y_q,
    output reg         y_valid,
    // Burst-aligned "this y_* pair is an MRC result" flag (= W_valid && !mode,
    // sampled at the state-0 burst start, held for the burst). trouper_top uses
    // it to apply REMOD_BACKOFF_SHIFT to MRC output only, not to bypass
    // passthrough (Open Risk #65 / TRPR-PCF-011 / TRPR-RMD-008).
    output wire        use_mrc
);

    reg [3:0] state;

    // 3-cycle pacing (honest MCP=3): each computing state holds MAC_WAIT+1 = 3
    // clocks so the 8x8 multiply (+ subtract) soaks the full multicycle budget.
    // State 0 is NOT paced — it must catch the 1-clock x_valid immediately.
    // Burst: state0 (1) + states 1..10 x3 = 31 clocks, fits the 64-clock window.
    localparam [1:0] MAC_WAIT = 2'd2;
    reg [1:0] mac_wait;

    // Latched inputs.  B4 (area roadmap §7/§8): the per-burst weight latches
    // were deleted — the W_re*/W_im* ports come from the reg_bank W-shadow,
    // which is hardware-stable whenever W_valid is high: reg_bank drops
    // 0x30-0x3F writes while W_valid (sticky WGT_CTRL[5] flags the attempt),
    // and the combiner consumes weights only under W_valid (sampled at burst
    // start into use_mrc_r).  The xr_* input latches REMAIN: they guard
    // against the live/replay source mux flipping mid-burst, which no
    // upstream protocol prevents.
    reg signed [7:0]  xr_i [0:3];
    reg signed [7:0]  xr_q [0:3];
    reg signed [7:0]  bypass_i_r, bypass_q_r;
    reg               use_mrc_r;
    assign use_mrc = use_mrc_r;   // Open Risk #65: burst-aligned MRC/bypass flag

    // 2 shared multiplier input registers
    reg signed [7:0]  w_r;
    reg signed [7:0]  xi_r;   // → mul_i = w_r × xi_r
    reg signed [7:0]  xq_r;   // → mul_q = w_r × xq_r

    // Sub-cycle 1 intermediate saves (w_re × x_i, w_re × x_q)
    reg signed [15:0] a_r, c_r;

    // Registered multiply output. 17-bit, not 16: the add path (prod_q_r <=
    // c_r + mul_q_next) can reach exactly +32768 when both 8x8 products hit
    // their shared extreme (w_re=w_im=x_i=x_q=-128), one past a 16-bit
    // signed max -- confirmed reachable, not just a nominal bound.
    reg signed [16:0] prod_i_r, prod_q_r;

    // Accumulator (19-bit: 17-bit product sign-extended + 2 guard bits for 4
    // additions). The 4-branch sum of the +32768 extreme above is 131072,
    // one past an 18-bit signed max -- 19 bits is the safe positive endpoint.
    reg signed [18:0] acc_i, acc_q;
    reg signed [18:0] acc_i_final_r, acc_q_final_r;

    // Two shared multipliers — combinatorial (8×8 → 16-bit)
    wire signed [15:0] mul_i_next = w_r * xi_r;
    wire signed [15:0] mul_q_next = w_r * xq_r;

    // Saturation path — single combined shift acc >>> (8 − pgs)
    wire [3:0] net_rshift  = 4'd8 - {1'b0, post_gain_shift};
    wire signed [18:0] shifted_i_f = acc_i_final_r >>> net_rshift;
    wire signed [18:0] shifted_q_f = acc_q_final_r >>> net_rshift;
    wire signed [8:0] sat_i = (shifted_i_f >  19'sd127) ?  9'sd127 :
                               (shifted_i_f < -19'sd128) ? -9'sd128 :
                               shifted_i_f[8:0];
    wire signed [8:0] sat_q = (shifted_q_f >  19'sd127) ?  9'sd127 :
                               (shifted_q_f < -19'sd128) ? -9'sd128 :
                               shifted_q_f[8:0];

    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n) begin
            state <= 4'd0;
            mac_wait <= 2'd0;
            w_r <= 8'sd0; xi_r <= 8'sd0; xq_r <= 8'sd0;
            a_r <= 16'sd0; c_r <= 16'sd0;
            prod_i_r <= 17'sd0; prod_q_r <= 17'sd0;
            acc_i <= 19'sd0; acc_q <= 19'sd0;
            acc_i_final_r <= 19'sd0; acc_q_final_r <= 19'sd0;
            xr_i[0]<=8'sd0; xr_i[1]<=8'sd0; xr_i[2]<=8'sd0; xr_i[3]<=8'sd0;
            xr_q[0]<=8'sd0; xr_q[1]<=8'sd0; xr_q[2]<=8'sd0; xr_q[3]<=8'sd0;
            bypass_i_r<=8'sd0; bypass_q_r<=8'sd0; use_mrc_r<=1'b0;
            y_i<=8'sd0; y_q<=8'sd0; y_valid<=1'b0;
        end else begin
            y_valid <= 1'b0;

            // Pace states 1..10: hold each MAC_WAIT+1 clocks. State 0 runs every
            // clock so x_valid is never missed.
            if (state != 4'd0 && mac_wait != MAC_WAIT) begin
                mac_wait <= mac_wait + 2'd1;
            end else begin
            mac_wait <= 2'd0;
            case (state)

            // ── IDLE: latch inputs, prime ant0 sub1 ─────────────────────────
            4'd0: if (x_valid) begin
                xr_i[0]<=x_i0; xr_q[0]<=x_q0;
                xr_i[1]<=x_i1; xr_q[1]<=x_q1;
                xr_i[2]<=x_i2; xr_q[2]<=x_q2;
                xr_i[3]<=x_i3; xr_q[3]<=x_q3;
                case (bypass_ant)
                    2'd0: begin bypass_i_r<=x_i0; bypass_q_r<=x_q0; end
                    2'd1: begin bypass_i_r<=x_i1; bypass_q_r<=x_q1; end
                    2'd2: begin bypass_i_r<=x_i2; bypass_q_r<=x_q2; end
                    default: begin bypass_i_r<=x_i3; bypass_q_r<=x_q3; end
                endcase
                use_mrc_r <= W_valid && !mode;
                acc_i <= 19'sd0; acc_q <= 19'sd0;
                w_r <= W_re0; xi_r <= x_i0; xq_r <= x_q0;
                state <= 4'd1;
            end

            // ── ANT0 SUB1: register w_re0 products → a_r, c_r ───────────────
            4'd1: begin
                a_r <= mul_i_next;
                c_r <= mul_q_next;
                w_r <= W_im0; xi_r <= xr_q[0]; xq_r <= xr_i[0];
                state <= 4'd2;
            end

            // ── ANT0 SUB2: form prod0; prime ant1 sub1 ──────────────────────
            4'd2: begin
                prod_i_r <= a_r - mul_i_next;
                prod_q_r <= c_r + mul_q_next;
                w_r <= W_re1; xi_r <= xr_i[1]; xq_r <= xr_q[1];
                state <= 4'd3;
            end

            // ── ANT1 SUB1: acc+=prod0; register w_re1 products ──────────────
            4'd3: begin
                acc_i <= acc_i + {{2{prod_i_r[16]}}, prod_i_r};
                acc_q <= acc_q + {{2{prod_q_r[16]}}, prod_q_r};
                a_r <= mul_i_next;
                c_r <= mul_q_next;
                w_r <= W_im1; xi_r <= xr_q[1]; xq_r <= xr_i[1];
                state <= 4'd4;
            end

            // ── ANT1 SUB2: form prod1; prime ant2 sub1 ──────────────────────
            4'd4: begin
                prod_i_r <= a_r - mul_i_next;
                prod_q_r <= c_r + mul_q_next;
                w_r <= W_re2; xi_r <= xr_i[2]; xq_r <= xr_q[2];
                state <= 4'd5;
            end

            // ── ANT2 SUB1: acc+=prod1; register w_re2 products ──────────────
            4'd5: begin
                acc_i <= acc_i + {{2{prod_i_r[16]}}, prod_i_r};
                acc_q <= acc_q + {{2{prod_q_r[16]}}, prod_q_r};
                a_r <= mul_i_next;
                c_r <= mul_q_next;
                w_r <= W_im2; xi_r <= xr_q[2]; xq_r <= xr_i[2];
                state <= 4'd6;
            end

            // ── ANT2 SUB2: form prod2; prime ant3 sub1 ──────────────────────
            4'd6: begin
                prod_i_r <= a_r - mul_i_next;
                prod_q_r <= c_r + mul_q_next;
                w_r <= W_re3; xi_r <= xr_i[3]; xq_r <= xr_q[3];
                state <= 4'd7;
            end

            // ── ANT3 SUB1: acc+=prod2; register w_re3 products ──────────────
            4'd7: begin
                acc_i <= acc_i + {{2{prod_i_r[16]}}, prod_i_r};
                acc_q <= acc_q + {{2{prod_q_r[16]}}, prod_q_r};
                a_r <= mul_i_next;
                c_r <= mul_q_next;
                w_r <= W_im3; xi_r <= xr_q[3]; xq_r <= xr_i[3];
                state <= 4'd8;
            end

            // ── ANT3 SUB2: form prod3 ────────────────────────────────────────
            4'd8: begin
                prod_i_r <= a_r - mul_i_next;
                prod_q_r <= c_r + mul_q_next;
                state <= 4'd9;
            end

            // ── Final accumulate ─────────────────────────────────────────────
            4'd9: begin
                acc_i_final_r <= acc_i + {{2{prod_i_r[16]}}, prod_i_r};
                acc_q_final_r <= acc_q + {{2{prod_q_r[16]}}, prod_q_r};
                state <= 4'd10;
            end

            // ── Output ───────────────────────────────────────────────────────
            4'd10: begin
                state   <= 4'd0;
                y_valid <= 1'b1;
                if (use_mrc_r) begin
                    y_i <= sat_i[7:0];
                    y_q <= sat_q[7:0];
                end else begin
                    y_i <= bypass_i_r;
                    y_q <= bypass_q_r;
                end
            end

            default: state <= 4'd0;
            endcase
            end
        end
    end

endmodule
