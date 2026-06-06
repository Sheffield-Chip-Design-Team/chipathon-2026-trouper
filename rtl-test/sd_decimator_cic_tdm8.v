// sd_decimator_cic_tdm8.v
// 4-channel (NR=4) CIC decimator: boxcar-4 pre-stage + 4-slot TDM CIC(N=3, R=64).
//
// Architecture:
//   Pre-stage:  boxcar-4 per stream. Global 2-bit counter box_cnt drives windowing.
//               All 4 channels latch box_sum simultaneously at box_cnt==3.
//   TDM CIC:    box_cnt also selects the TDM slot. One adder set (I+Q) shared via
//               4-slot rotation. Each channel's integrators update once per 4 cycles.
//   Comb:       Per-channel, triggered by cic_strobe (every 256 input cycles).
//   Total OSR:  4 × 64 = 256.  Output: 125 kHz at 32 MHz input.
//   Acc width:  22-bit signed (vs 26-bit in sd_decimator_cic_only × 4).
//   norm_shift: 13  (gain = 4 × 64^3 = 2^20; >>13 → ±128 range)
//
// Fixed decim_ratio = R=256 (125 kHz). For synthesis comparison only.
// Interface: 4 antenna 1-bit inputs → 4 × 8-bit signed IQ outputs (packed).
// GF180MCU 3.3V

`timescale 1ns/100ps

module sd_decimator_cic_tdm8 (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire [3:0]  iq_in_i,      // iq_in_i[k] = antenna k I bitstream
    input  wire [3:0]  iq_in_q,
    output reg  [31:0] iq_out_i,     // [8*k+7 -: 8] = antenna k 8-bit signed I
    output reg  [31:0] iq_out_q,
    output reg         iq_valid      // 1-cycle strobe: all 4 channels ready
);

    // =========================================================
    // Global counters
    // box_cnt [1:0]: 4-phase counter — drives boxcar window and TDM slot
    // cic_cnt [5:0]: counts 0..63 complete box rotations per CIC output period
    // cic_strobe: fires 1 cycle after cic_cnt wraps (all channels completed last update)
    // =========================================================
    reg [1:0] box_cnt;
    reg [5:0] cic_cnt;
    reg       cic_strobe;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            box_cnt    <= 2'd0;
            cic_cnt    <= 6'd0;
            cic_strobe <= 1'b0;
        end else begin
            cic_strobe <= 1'b0;
            if (box_cnt == 2'd3) begin
                box_cnt <= 2'd0;
                if (cic_cnt == 6'd63) begin
                    cic_cnt    <= 6'd0;
                    cic_strobe <= 1'b1;
                end else begin
                    cic_cnt <= cic_cnt + 6'd1;
                end
            end else begin
                box_cnt <= box_cnt + 2'd1;
            end
        end
    end

    // =========================================================
    // Stage 1: Boxcar-4 pre-decimator (per channel, all 8 streams)
    // NRZ encoding: input 1 → +1, input 0 → −1
    // box_acc: running sum over 4-cycle window, range [-4,+4], 4-bit signed
    // box_sum: latched at box_cnt==3, held stable for next 4 cycles while TDM reads it
    // =========================================================
    reg signed [3:0] box_acc_i_0, box_acc_i_1, box_acc_i_2, box_acc_i_3;
    reg signed [3:0] box_acc_q_0, box_acc_q_1, box_acc_q_2, box_acc_q_3;
    reg signed [3:0] box_sum_i_0, box_sum_i_1, box_sum_i_2, box_sum_i_3;
    reg signed [3:0] box_sum_q_0, box_sum_q_1, box_sum_q_2, box_sum_q_3;

    // Sign-extended to 22 bits for adder input
    wire signed [21:0] bsi0 = {{18{box_sum_i_0[3]}}, box_sum_i_0};
    wire signed [21:0] bsi1 = {{18{box_sum_i_1[3]}}, box_sum_i_1};
    wire signed [21:0] bsi2 = {{18{box_sum_i_2[3]}}, box_sum_i_2};
    wire signed [21:0] bsi3 = {{18{box_sum_i_3[3]}}, box_sum_i_3};
    wire signed [21:0] bsq0 = {{18{box_sum_q_0[3]}}, box_sum_q_0};
    wire signed [21:0] bsq1 = {{18{box_sum_q_1[3]}}, box_sum_q_1};
    wire signed [21:0] bsq2 = {{18{box_sum_q_2[3]}}, box_sum_q_2};
    wire signed [21:0] bsq3 = {{18{box_sum_q_3[3]}}, box_sum_q_3};

    task automatic boxcar_step;
        input       in_bit;
        inout signed [3:0] acc;
        inout signed [3:0] sum;
        input       is_last;
        begin
            if (is_last) begin
                sum = acc + (in_bit ? 4'sd1 : -4'sd1);
                acc = (in_bit ? 4'sd1 : -4'sd1);
            end else begin
                acc = acc + (in_bit ? 4'sd1 : -4'sd1);
            end
        end
    endtask

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            box_acc_i_0 <= 4'sd0; box_acc_i_1 <= 4'sd0;
            box_acc_i_2 <= 4'sd0; box_acc_i_3 <= 4'sd0;
            box_acc_q_0 <= 4'sd0; box_acc_q_1 <= 4'sd0;
            box_acc_q_2 <= 4'sd0; box_acc_q_3 <= 4'sd0;
            box_sum_i_0 <= 4'sd0; box_sum_i_1 <= 4'sd0;
            box_sum_i_2 <= 4'sd0; box_sum_i_3 <= 4'sd0;
            box_sum_q_0 <= 4'sd0; box_sum_q_1 <= 4'sd0;
            box_sum_q_2 <= 4'sd0; box_sum_q_3 <= 4'sd0;
        end else if (box_cnt == 2'd3) begin
            // End of window: latch sums, seed next window with current bit
            box_sum_i_0 <= box_acc_i_0 + (iq_in_i[0] ? 4'sd1 : -4'sd1);
            box_sum_i_1 <= box_acc_i_1 + (iq_in_i[1] ? 4'sd1 : -4'sd1);
            box_sum_i_2 <= box_acc_i_2 + (iq_in_i[2] ? 4'sd1 : -4'sd1);
            box_sum_i_3 <= box_acc_i_3 + (iq_in_i[3] ? 4'sd1 : -4'sd1);
            box_sum_q_0 <= box_acc_q_0 + (iq_in_q[0] ? 4'sd1 : -4'sd1);
            box_sum_q_1 <= box_acc_q_1 + (iq_in_q[1] ? 4'sd1 : -4'sd1);
            box_sum_q_2 <= box_acc_q_2 + (iq_in_q[2] ? 4'sd1 : -4'sd1);
            box_sum_q_3 <= box_acc_q_3 + (iq_in_q[3] ? 4'sd1 : -4'sd1);
            box_acc_i_0 <= (iq_in_i[0] ? 4'sd1 : -4'sd1);
            box_acc_i_1 <= (iq_in_i[1] ? 4'sd1 : -4'sd1);
            box_acc_i_2 <= (iq_in_i[2] ? 4'sd1 : -4'sd1);
            box_acc_i_3 <= (iq_in_i[3] ? 4'sd1 : -4'sd1);
            box_acc_q_0 <= (iq_in_q[0] ? 4'sd1 : -4'sd1);
            box_acc_q_1 <= (iq_in_q[1] ? 4'sd1 : -4'sd1);
            box_acc_q_2 <= (iq_in_q[2] ? 4'sd1 : -4'sd1);
            box_acc_q_3 <= (iq_in_q[3] ? 4'sd1 : -4'sd1);
        end else begin
            box_acc_i_0 <= box_acc_i_0 + (iq_in_i[0] ? 4'sd1 : -4'sd1);
            box_acc_i_1 <= box_acc_i_1 + (iq_in_i[1] ? 4'sd1 : -4'sd1);
            box_acc_i_2 <= box_acc_i_2 + (iq_in_i[2] ? 4'sd1 : -4'sd1);
            box_acc_i_3 <= box_acc_i_3 + (iq_in_i[3] ? 4'sd1 : -4'sd1);
            box_acc_q_0 <= box_acc_q_0 + (iq_in_q[0] ? 4'sd1 : -4'sd1);
            box_acc_q_1 <= box_acc_q_1 + (iq_in_q[1] ? 4'sd1 : -4'sd1);
            box_acc_q_2 <= box_acc_q_2 + (iq_in_q[2] ? 4'sd1 : -4'sd1);
            box_acc_q_3 <= box_acc_q_3 + (iq_in_q[3] ? 4'sd1 : -4'sd1);
        end
    end

    // =========================================================
    // Stage 2: TDM CIC integrators (N=3, R=64)
    // 4 channels, one updated per clock cycle. State: 22-bit signed × 3 stages × I+Q.
    // Each channel sees 64 updates per CIC output period (8 MHz effective input rate).
    // =========================================================
    reg signed [21:0] i1i_0, i2i_0, i3i_0,  i1q_0, i2q_0, i3q_0;
    reg signed [21:0] i1i_1, i2i_1, i3i_1,  i1q_1, i2q_1, i3q_1;
    reg signed [21:0] i1i_2, i2i_2, i3i_2,  i1q_2, i2q_2, i3q_2;
    reg signed [21:0] i1i_3, i2i_3, i3i_3,  i1q_3, i2q_3, i3q_3;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            i1i_0<=22'sd0; i2i_0<=22'sd0; i3i_0<=22'sd0;
            i1q_0<=22'sd0; i2q_0<=22'sd0; i3q_0<=22'sd0;
            i1i_1<=22'sd0; i2i_1<=22'sd0; i3i_1<=22'sd0;
            i1q_1<=22'sd0; i2q_1<=22'sd0; i3q_1<=22'sd0;
            i1i_2<=22'sd0; i2i_2<=22'sd0; i3i_2<=22'sd0;
            i1q_2<=22'sd0; i2q_2<=22'sd0; i3q_2<=22'sd0;
            i1i_3<=22'sd0; i2i_3<=22'sd0; i3i_3<=22'sd0;
            i1q_3<=22'sd0; i2q_3<=22'sd0; i3q_3<=22'sd0;
        end else begin
            case (box_cnt)
                2'd0: begin
                    i1i_0 <= i1i_0 + bsi0; i2i_0 <= i2i_0 + i1i_0; i3i_0 <= i3i_0 + i2i_0;
                    i1q_0 <= i1q_0 + bsq0; i2q_0 <= i2q_0 + i1q_0; i3q_0 <= i3q_0 + i2q_0;
                end
                2'd1: begin
                    i1i_1 <= i1i_1 + bsi1; i2i_1 <= i2i_1 + i1i_1; i3i_1 <= i3i_1 + i2i_1;
                    i1q_1 <= i1q_1 + bsq1; i2q_1 <= i2q_1 + i1q_1; i3q_1 <= i3q_1 + i2q_1;
                end
                2'd2: begin
                    i1i_2 <= i1i_2 + bsi2; i2i_2 <= i2i_2 + i1i_2; i3i_2 <= i3i_2 + i2i_2;
                    i1q_2 <= i1q_2 + bsq2; i2q_2 <= i2q_2 + i1q_2; i3q_2 <= i3q_2 + i2q_2;
                end
                2'd3: begin
                    i1i_3 <= i1i_3 + bsi3; i2i_3 <= i2i_3 + i1i_3; i3i_3 <= i3i_3 + i2i_3;
                    i1q_3 <= i1q_3 + bsq3; i2q_3 <= i2q_3 + i1q_3; i3q_3 <= i3q_3 + i2q_3;
                end
            endcase
        end
    end

    // =========================================================
    // Stage 3: Comb (N=3) + normalisation, per channel, triggered by cic_strobe.
    // norm_shift = 13: total gain = 4 × 64^3 = 2^20; >>13 → ±128 range.
    // =========================================================
    reg signed [21:0] lat_i_0, lat_q_0, lat_i_1, lat_q_1;
    reg signed [21:0] lat_i_2, lat_q_2, lat_i_3, lat_q_3;

    reg signed [21:0] c1di_0,c2di_0,c3di_0, c1dq_0,c2dq_0,c3dq_0;
    reg signed [21:0] c1di_1,c2di_1,c3di_1, c1dq_1,c2dq_1,c3dq_1;
    reg signed [21:0] c1di_2,c2di_2,c3di_2, c1dq_2,c2dq_2,c3dq_2;
    reg signed [21:0] c1di_3,c2di_3,c3di_3, c1dq_3,c2dq_3,c3dq_3;

    reg signed [21:0] shi_0,shq_0, shi_1,shq_1, shi_2,shq_2, shi_3,shq_3;

    wire signed [21:0] c1wi_0 = lat_i_0 - c1di_0; wire signed [21:0] c1wq_0 = lat_q_0 - c1dq_0;
    wire signed [21:0] c2wi_0 = c1wi_0  - c2di_0; wire signed [21:0] c2wq_0 = c1wq_0  - c2dq_0;
    wire signed [21:0] c3wi_0 = c2wi_0  - c3di_0; wire signed [21:0] c3wq_0 = c2wq_0  - c3dq_0;

    wire signed [21:0] c1wi_1 = lat_i_1 - c1di_1; wire signed [21:0] c1wq_1 = lat_q_1 - c1dq_1;
    wire signed [21:0] c2wi_1 = c1wi_1  - c2di_1; wire signed [21:0] c2wq_1 = c1wq_1  - c2dq_1;
    wire signed [21:0] c3wi_1 = c2wi_1  - c3di_1; wire signed [21:0] c3wq_1 = c2wq_1  - c3dq_1;

    wire signed [21:0] c1wi_2 = lat_i_2 - c1di_2; wire signed [21:0] c1wq_2 = lat_q_2 - c1dq_2;
    wire signed [21:0] c2wi_2 = c1wi_2  - c2di_2; wire signed [21:0] c2wq_2 = c1wq_2  - c2dq_2;
    wire signed [21:0] c3wi_2 = c2wi_2  - c3di_2; wire signed [21:0] c3wq_2 = c2wq_2  - c3dq_2;

    wire signed [21:0] c1wi_3 = lat_i_3 - c1di_3; wire signed [21:0] c1wq_3 = lat_q_3 - c1dq_3;
    wire signed [21:0] c2wi_3 = c1wi_3  - c2di_3; wire signed [21:0] c2wq_3 = c1wq_3  - c2dq_3;
    wire signed [21:0] c3wi_3 = c2wi_3  - c3di_3; wire signed [21:0] c3wq_3 = c2wq_3  - c3dq_3;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            lat_i_0<=22'sd0; lat_q_0<=22'sd0; c1di_0<=22'sd0; c2di_0<=22'sd0; c3di_0<=22'sd0;
            c1dq_0<=22'sd0; c2dq_0<=22'sd0; c3dq_0<=22'sd0; shi_0<=22'sd0; shq_0<=22'sd0;
            lat_i_1<=22'sd0; lat_q_1<=22'sd0; c1di_1<=22'sd0; c2di_1<=22'sd0; c3di_1<=22'sd0;
            c1dq_1<=22'sd0; c2dq_1<=22'sd0; c3dq_1<=22'sd0; shi_1<=22'sd0; shq_1<=22'sd0;
            lat_i_2<=22'sd0; lat_q_2<=22'sd0; c1di_2<=22'sd0; c2di_2<=22'sd0; c3di_2<=22'sd0;
            c1dq_2<=22'sd0; c2dq_2<=22'sd0; c3dq_2<=22'sd0; shi_2<=22'sd0; shq_2<=22'sd0;
            lat_i_3<=22'sd0; lat_q_3<=22'sd0; c1di_3<=22'sd0; c2di_3<=22'sd0; c3di_3<=22'sd0;
            c1dq_3<=22'sd0; c2dq_3<=22'sd0; c3dq_3<=22'sd0; shi_3<=22'sd0; shq_3<=22'sd0;
        end else if (cic_strobe) begin
            // Channel 0
            lat_i_0<=i3i_0; lat_q_0<=i3q_0;
            c1di_0<=lat_i_0; c1dq_0<=lat_q_0;
            c2di_0<=c1wi_0;  c2dq_0<=c1wq_0;
            c3di_0<=c2wi_0;  c3dq_0<=c2wq_0;
            shi_0 <= c3wi_0 >>> 13; shq_0 <= c3wq_0 >>> 13;
            // Channel 1
            lat_i_1<=i3i_1; lat_q_1<=i3q_1;
            c1di_1<=lat_i_1; c1dq_1<=lat_q_1;
            c2di_1<=c1wi_1;  c2dq_1<=c1wq_1;
            c3di_1<=c2wi_1;  c3dq_1<=c2wq_1;
            shi_1 <= c3wi_1 >>> 13; shq_1 <= c3wq_1 >>> 13;
            // Channel 2
            lat_i_2<=i3i_2; lat_q_2<=i3q_2;
            c1di_2<=lat_i_2; c1dq_2<=lat_q_2;
            c2di_2<=c1wi_2;  c2dq_2<=c1wq_2;
            c3di_2<=c2wi_2;  c3dq_2<=c2wq_2;
            shi_2 <= c3wi_2 >>> 13; shq_2 <= c3wq_2 >>> 13;
            // Channel 3
            lat_i_3<=i3i_3; lat_q_3<=i3q_3;
            c1di_3<=lat_i_3; c1dq_3<=lat_q_3;
            c2di_3<=c1wi_3;  c2dq_3<=c1wq_3;
            c3di_3<=c2wi_3;  c3dq_3<=c2wq_3;
            shi_3 <= c3wi_3 >>> 13; shq_3 <= c3wq_3 >>> 13;
        end
    end

    // =========================================================
    // Output registers + saturation (1 cycle after cic_strobe)
    // =========================================================
    reg strobe_r, strobe_rr;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin strobe_r <= 1'b0; strobe_rr <= 1'b0; end
        else        begin strobe_r <= cic_strobe; strobe_rr <= strobe_r; end
    end

    wire signed [8:0] oi0 = shi_0[8:0]; wire signed [8:0] oq0 = shq_0[8:0];
    wire signed [8:0] oi1 = shi_1[8:0]; wire signed [8:0] oq1 = shq_1[8:0];
    wire signed [8:0] oi2 = shi_2[8:0]; wire signed [8:0] oq2 = shq_2[8:0];
    wire signed [8:0] oi3 = shi_3[8:0]; wire signed [8:0] oq3 = shq_3[8:0];

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            iq_out_i <= 32'd0; iq_out_q <= 32'd0; iq_valid <= 1'b0;
        end else begin
            iq_valid <= strobe_r | strobe_rr;
            if (strobe_r) begin
                iq_out_i[ 7: 0] <= (oi0>9'sd127) ? 8'sd127 : (oi0<-9'sd128) ? -8'sd128 : oi0[7:0];
                iq_out_q[ 7: 0] <= (oq0>9'sd127) ? 8'sd127 : (oq0<-9'sd128) ? -8'sd128 : oq0[7:0];
                iq_out_i[15: 8] <= (oi1>9'sd127) ? 8'sd127 : (oi1<-9'sd128) ? -8'sd128 : oi1[7:0];
                iq_out_q[15: 8] <= (oq1>9'sd127) ? 8'sd127 : (oq1<-9'sd128) ? -8'sd128 : oq1[7:0];
                iq_out_i[23:16] <= (oi2>9'sd127) ? 8'sd127 : (oi2<-9'sd128) ? -8'sd128 : oi2[7:0];
                iq_out_q[23:16] <= (oq2>9'sd127) ? 8'sd127 : (oq2<-9'sd128) ? -8'sd128 : oq2[7:0];
                iq_out_i[31:24] <= (oi3>9'sd127) ? 8'sd127 : (oi3<-9'sd128) ? -8'sd128 : oi3[7:0];
                iq_out_q[31:24] <= (oq3>9'sd127) ? 8'sd127 : (oq3<-9'sd128) ? -8'sd128 : oq3[7:0];
            end
        end
    end

endmodule
