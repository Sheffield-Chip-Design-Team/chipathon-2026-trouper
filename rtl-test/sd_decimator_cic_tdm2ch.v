// sd_decimator_cic_tdm2ch.v
// 2-channel (NR=2) CIC decimator: boxcar-2 pre-stage + 2-slot TDM CIC(N=3, R=128).
//
// Architecture:
//   Pre-stage:  boxcar-2 per I+Q pair. 1-bit counter box_cnt drives windowing.
//               Each antenna's I and Q accumulate 2 consecutive bits → ±2, 2-bit signed.
//   TDM CIC:    box_cnt also selects TDM slot (0=ant0, 1=ant1).
//               One adder pair (I+Q in parallel) shared via 2-slot rotation.
//               Each channel updates once per 2 cycles at 32 MHz = 16 MHz effective input.
//   Comb:       Per-channel, triggered by cic_strobe (every 256 input cycles).
//   Total OSR:  2 × 128 = 256. Output: 125 kHz at 32 MHz input.
//   Acc width:  23-bit signed.
//   norm_shift: 15  (gain = 2 × 128^3 = 4,194,304 ≈ 2^22; >>15 → ±128 range)
//
// Fixed decim_ratio = R=256 (125 kHz). For synthesis comparison only.
// Interface: 2 antenna 1-bit inputs → 2 × 8-bit signed IQ outputs (packed).
// GF180MCU 3.3V

`timescale 1ns/100ps

module sd_decimator_cic_tdm2ch (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire [1:0]  iq_in_i,      // iq_in_i[k] = antenna k I bitstream
    input  wire [1:0]  iq_in_q,
    output reg  [15:0] iq_out_i,     // [8*k+7 -: 8] = antenna k 8-bit signed I
    output reg  [15:0] iq_out_q,
    output reg         iq_valid
);

    // =========================================================
    // Global counters
    // box_cnt [0]: 2-phase counter — drives boxcar window and TDM slot
    // cic_cnt [6:0]: counts 0..127 box rotations per CIC output period
    // =========================================================
    reg       box_cnt;
    reg [6:0] cic_cnt;
    reg       cic_strobe;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            box_cnt    <= 1'b0;
            cic_cnt    <= 7'd0;
            cic_strobe <= 1'b0;
        end else begin
            cic_strobe <= 1'b0;
            if (box_cnt == 1'b1) begin
                box_cnt <= 1'b0;
                if (cic_cnt == 7'd127) begin
                    cic_cnt    <= 7'd0;
                    cic_strobe <= 1'b1;
                end else begin
                    cic_cnt <= cic_cnt + 7'd1;
                end
            end else begin
                box_cnt <= 1'b1;
            end
        end
    end

    // =========================================================
    // Stage 1: Boxcar-2 pre-decimator (per antenna, I and Q in parallel)
    // NRZ: input 1 → +1, input 0 → −1.
    // box_acc: running sum over 2-cycle window, range [-2,+2], 2-bit signed.
    // box_sum: latched at box_cnt==1, held for 2 cycles while TDM reads it.
    // =========================================================
    reg signed [1:0] box_acc_i_0, box_acc_q_0;
    reg signed [1:0] box_acc_i_1, box_acc_q_1;
    reg signed [1:0] box_sum_i_0, box_sum_q_0;
    reg signed [1:0] box_sum_i_1, box_sum_q_1;

    // Sign-extended to 23 bits for adder input
    wire signed [22:0] bsi0 = {{21{box_sum_i_0[1]}}, box_sum_i_0};
    wire signed [22:0] bsq0 = {{21{box_sum_q_0[1]}}, box_sum_q_0};
    wire signed [22:0] bsi1 = {{21{box_sum_i_1[1]}}, box_sum_i_1};
    wire signed [22:0] bsq1 = {{21{box_sum_q_1[1]}}, box_sum_q_1};

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            box_acc_i_0 <= 2'sd0; box_acc_q_0 <= 2'sd0;
            box_acc_i_1 <= 2'sd0; box_acc_q_1 <= 2'sd0;
            box_sum_i_0 <= 2'sd0; box_sum_q_0 <= 2'sd0;
            box_sum_i_1 <= 2'sd0; box_sum_q_1 <= 2'sd0;
        end else if (box_cnt == 1'b1) begin
            // End of window: latch sums, seed next window
            box_sum_i_0 <= box_acc_i_0 + (iq_in_i[0] ? 2'sd1 : -2'sd1);
            box_sum_q_0 <= box_acc_q_0 + (iq_in_q[0] ? 2'sd1 : -2'sd1);
            box_sum_i_1 <= box_acc_i_1 + (iq_in_i[1] ? 2'sd1 : -2'sd1);
            box_sum_q_1 <= box_acc_q_1 + (iq_in_q[1] ? 2'sd1 : -2'sd1);
            box_acc_i_0 <= (iq_in_i[0] ? 2'sd1 : -2'sd1);
            box_acc_q_0 <= (iq_in_q[0] ? 2'sd1 : -2'sd1);
            box_acc_i_1 <= (iq_in_i[1] ? 2'sd1 : -2'sd1);
            box_acc_q_1 <= (iq_in_q[1] ? 2'sd1 : -2'sd1);
        end else begin
            box_acc_i_0 <= box_acc_i_0 + (iq_in_i[0] ? 2'sd1 : -2'sd1);
            box_acc_q_0 <= box_acc_q_0 + (iq_in_q[0] ? 2'sd1 : -2'sd1);
            box_acc_i_1 <= box_acc_i_1 + (iq_in_i[1] ? 2'sd1 : -2'sd1);
            box_acc_q_1 <= box_acc_q_1 + (iq_in_q[1] ? 2'sd1 : -2'sd1);
        end
    end

    // =========================================================
    // Stage 2: TDM CIC integrators (N=3, R=128)
    // 2 channels, one per clock cycle. Each updates at 16 MHz effective rate.
    // Acc width: 23-bit signed. Max = 2 × 128^3 = 4,194,304 ≈ 2^22.
    // =========================================================
    reg signed [22:0] i1i_0, i2i_0, i3i_0,  i1q_0, i2q_0, i3q_0;
    reg signed [22:0] i1i_1, i2i_1, i3i_1,  i1q_1, i2q_1, i3q_1;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            i1i_0<=23'sd0; i2i_0<=23'sd0; i3i_0<=23'sd0;
            i1q_0<=23'sd0; i2q_0<=23'sd0; i3q_0<=23'sd0;
            i1i_1<=23'sd0; i2i_1<=23'sd0; i3i_1<=23'sd0;
            i1q_1<=23'sd0; i2q_1<=23'sd0; i3q_1<=23'sd0;
        end else begin
            if (box_cnt == 1'b0) begin
                i1i_0 <= i1i_0 + bsi0; i2i_0 <= i2i_0 + i1i_0; i3i_0 <= i3i_0 + i2i_0;
                i1q_0 <= i1q_0 + bsq0; i2q_0 <= i2q_0 + i1q_0; i3q_0 <= i3q_0 + i2q_0;
            end else begin
                i1i_1 <= i1i_1 + bsi1; i2i_1 <= i2i_1 + i1i_1; i3i_1 <= i3i_1 + i2i_1;
                i1q_1 <= i1q_1 + bsq1; i2q_1 <= i2q_1 + i1q_1; i3q_1 <= i3q_1 + i2q_1;
            end
        end
    end

    // =========================================================
    // Stage 3: Comb (N=3) + normalisation, per channel.
    // norm_shift = 15: 4,194,304 >> 15 = 128. Saturation check on bits [8:0].
    // =========================================================
    reg signed [22:0] lat_i_0, lat_q_0, lat_i_1, lat_q_1;
    reg signed [22:0] c1di_0,c2di_0,c3di_0, c1dq_0,c2dq_0,c3dq_0;
    reg signed [22:0] c1di_1,c2di_1,c3di_1, c1dq_1,c2dq_1,c3dq_1;
    reg signed [22:0] shi_0,shq_0, shi_1,shq_1;

    wire signed [22:0] c1wi_0 = lat_i_0 - c1di_0; wire signed [22:0] c1wq_0 = lat_q_0 - c1dq_0;
    wire signed [22:0] c2wi_0 = c1wi_0  - c2di_0; wire signed [22:0] c2wq_0 = c1wq_0  - c2dq_0;
    wire signed [22:0] c3wi_0 = c2wi_0  - c3di_0; wire signed [22:0] c3wq_0 = c2wq_0  - c3dq_0;

    wire signed [22:0] c1wi_1 = lat_i_1 - c1di_1; wire signed [22:0] c1wq_1 = lat_q_1 - c1dq_1;
    wire signed [22:0] c2wi_1 = c1wi_1  - c2di_1; wire signed [22:0] c2wq_1 = c1wq_1  - c2dq_1;
    wire signed [22:0] c3wi_1 = c2wi_1  - c3di_1; wire signed [22:0] c3wq_1 = c2wq_1  - c3dq_1;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            lat_i_0<=23'sd0; lat_q_0<=23'sd0; c1di_0<=23'sd0; c2di_0<=23'sd0; c3di_0<=23'sd0;
            c1dq_0<=23'sd0; c2dq_0<=23'sd0; c3dq_0<=23'sd0; shi_0<=23'sd0; shq_0<=23'sd0;
            lat_i_1<=23'sd0; lat_q_1<=23'sd0; c1di_1<=23'sd0; c2di_1<=23'sd0; c3di_1<=23'sd0;
            c1dq_1<=23'sd0; c2dq_1<=23'sd0; c3dq_1<=23'sd0; shi_1<=23'sd0; shq_1<=23'sd0;
        end else if (cic_strobe) begin
            lat_i_0<=i3i_0; lat_q_0<=i3q_0;
            c1di_0<=lat_i_0; c1dq_0<=lat_q_0;
            c2di_0<=c1wi_0;  c2dq_0<=c1wq_0;
            c3di_0<=c2wi_0;  c3dq_0<=c2wq_0;
            shi_0 <= c3wi_0 >>> 15; shq_0 <= c3wq_0 >>> 15;

            lat_i_1<=i3i_1; lat_q_1<=i3q_1;
            c1di_1<=lat_i_1; c1dq_1<=lat_q_1;
            c2di_1<=c1wi_1;  c2dq_1<=c1wq_1;
            c3di_1<=c2wi_1;  c3dq_1<=c2wq_1;
            shi_1 <= c3wi_1 >>> 15; shq_1 <= c3wq_1 >>> 15;
        end
    end

    // =========================================================
    // Output registers + saturation
    // =========================================================
    reg strobe_r, strobe_rr;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin strobe_r <= 1'b0; strobe_rr <= 1'b0; end
        else        begin strobe_r <= cic_strobe; strobe_rr <= strobe_r; end
    end

    wire signed [8:0] oi0 = shi_0[8:0]; wire signed [8:0] oq0 = shq_0[8:0];
    wire signed [8:0] oi1 = shi_1[8:0]; wire signed [8:0] oq1 = shq_1[8:0];

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            iq_out_i <= 16'd0; iq_out_q <= 16'd0; iq_valid <= 1'b0;
        end else begin
            iq_valid <= strobe_r | strobe_rr;
            if (strobe_r) begin
                iq_out_i[ 7:0] <= (oi0>9'sd127) ? 8'sd127 : (oi0<-9'sd128) ? -8'sd128 : oi0[7:0];
                iq_out_q[ 7:0] <= (oq0>9'sd127) ? 8'sd127 : (oq0<-9'sd128) ? -8'sd128 : oq0[7:0];
                iq_out_i[15:8] <= (oi1>9'sd127) ? 8'sd127 : (oi1<-9'sd128) ? -8'sd128 : oi1[7:0];
                iq_out_q[15:8] <= (oq1>9'sd127) ? 8'sd127 : (oq1<-9'sd128) ? -8'sd128 : oq1[7:0];
            end
        end
    end

endmodule
