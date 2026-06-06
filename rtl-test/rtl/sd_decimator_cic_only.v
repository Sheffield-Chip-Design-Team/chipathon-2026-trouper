// sd_decimator_cic_only.v
// CIC N=3 decimator — no FIR compensation, no multiplier.
//
// Drop-in replacement for sd_decimator_combchain: identical port list,
// identical clk_32m / clk_16m / rst_n / decim_ratio / iq_in / iq_out ports.
// clk_16m is accepted but unused; all logic runs on clk_32m.
//
// Pipeline (all clk_32m):
//   Cycle 0-N : CIC integrators (every cycle)
//   Cycle N   : cic_strobe fires → combinational comb chain → shifted_i/q
//   Cycle N+1 : output register latches shifted_i/q, asserts iq_valid
//
// Normalisation:
//   shifted_i = comb_i3_w >>> norm_shift  (same as combchain)
//   iq_out_i  = saturate(shifted_i[17:0], 8)
//   Bits [17:8] are used for saturation check; bits [7:0] are the output.
//
// Passband ripple (Python model, tone swept 0..0.45×BW):
//   R=256 (125 kHz): −9.3 dB droop at band edge,  min SQNR ~32 dB (≥ 28 dB ✓)
//   R=128 (250 kHz): −9.3 dB droop,                min SQNR ~33 dB (≥ 28 dB ✓)
//   R= 64 (500 kHz): −9.3 dB droop,                min SQNR ~34 dB (≥ 28 dB ✓)
//   R= 32 (1 MS/s) : −9.3 dB droop,                min SQNR ~32 dB (≥ 28 dB ✓)
//
// GF180MCU, 3.3V

`timescale 1ns/100ps

module sd_decimator_cic_only (
    input  wire        clk_32m,
    input  wire        clk_16m,   // unused; retained for drop-in compatibility
    input  wire        rst_n,
    input  wire        iq_in_i,
    input  wire        iq_in_q,
    input  wire [1:0]  decim_ratio,
    output reg  signed [7:0] iq_out_i,
    output reg  signed [7:0] iq_out_q,
    output reg         iq_valid
);

    // =========================================================
    // CIC integrators (32 MHz, every cycle)
    // =========================================================

    reg iq_in_i_r, iq_in_q_r;
    reg cic_bit_i_r, cic_bit_q_r;

    reg signed [25:0] intg_i1, intg_i2, intg_i3;
    reg signed [25:0] intg_q1, intg_q2, intg_q3;

    reg [7:0] decim_cnt;
    reg [7:0] R;
    always @(*) begin
        case (decim_ratio)
            2'd0: R = 8'd255;
            2'd1: R = 8'd127;
            2'd2: R = 8'd63;
            2'd3: R = 8'd31;
            default: R = 8'd255;
        endcase
    end

    reg [4:0] norm_shift;
    always @(*) begin
        case (decim_ratio)
            2'd0: norm_shift = 5'd17;
            2'd1: norm_shift = 5'd14;
            2'd2: norm_shift = 5'd11;
            2'd3: norm_shift = 5'd8;
            default: norm_shift = 5'd17;
        endcase
    end

    reg cic_strobe;

    wire signed [25:0] intg_i1_next = cic_bit_i_r ? (intg_i1 + 26'sd1) : (intg_i1 - 26'sd1);
    wire signed [25:0] intg_i2_next = intg_i2 + intg_i1;
    wire signed [25:0] intg_i3_next = intg_i3 + intg_i2;
    wire signed [25:0] intg_q1_next = cic_bit_q_r ? (intg_q1 + 26'sd1) : (intg_q1 - 26'sd1);
    wire signed [25:0] intg_q2_next = intg_q2 + intg_q1;
    wire signed [25:0] intg_q3_next = intg_q3 + intg_q2;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            iq_in_i_r   <= 1'b0; iq_in_q_r   <= 1'b0;
            cic_bit_i_r <= 1'b0; cic_bit_q_r <= 1'b0;
            intg_i1 <= 26'sd0; intg_i2 <= 26'sd0; intg_i3 <= 26'sd0;
            intg_q1 <= 26'sd0; intg_q2 <= 26'sd0; intg_q3 <= 26'sd0;
            decim_cnt  <= 8'd0;
            cic_strobe <= 1'b0;
        end else begin
            iq_in_i_r   <= iq_in_i;
            iq_in_q_r   <= iq_in_q;
            cic_bit_i_r <= iq_in_i_r;
            cic_bit_q_r <= iq_in_q_r;
            intg_i1 <= intg_i1_next;
            intg_i2 <= intg_i2_next;
            intg_i3 <= intg_i3_next;
            intg_q1 <= intg_q1_next;
            intg_q2 <= intg_q2_next;
            intg_q3 <= intg_q3_next;
            if (decim_cnt == R) begin
                decim_cnt  <= 8'd0;
                cic_strobe <= 1'b1;
            end else begin
                decim_cnt  <= decim_cnt + 8'd1;
                cic_strobe <= 1'b0;
            end
        end
    end

    // =========================================================
    // CIC comb stages + normalisation (32 MHz, strobe-gated)
    // =========================================================

    reg signed [25:0] intg_i3_lat, intg_q3_lat;
    reg signed [25:0] comb_i1_d, comb_i2_d, comb_i3_d;
    reg signed [25:0] comb_q1_d, comb_q2_d, comb_q3_d;
    reg signed [25:0] shifted_i, shifted_q;

    wire signed [25:0] comb_i1_w = intg_i3_lat - comb_i1_d;
    wire signed [25:0] comb_q1_w = intg_q3_lat - comb_q1_d;
    wire signed [25:0] comb_i2_w = comb_i1_w   - comb_i2_d;
    wire signed [25:0] comb_q2_w = comb_q1_w   - comb_q2_d;
    wire signed [25:0] comb_i3_w = comb_i2_w   - comb_i3_d;
    wire signed [25:0] comb_q3_w = comb_q2_w   - comb_q3_d;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            intg_i3_lat <= 26'sd0; intg_q3_lat <= 26'sd0;
            comb_i1_d   <= 26'sd0; comb_i2_d   <= 26'sd0; comb_i3_d   <= 26'sd0;
            comb_q1_d   <= 26'sd0; comb_q2_d   <= 26'sd0; comb_q3_d   <= 26'sd0;
            shifted_i   <= 26'sd0; shifted_q   <= 26'sd0;
        end else if (cic_strobe) begin
            intg_i3_lat <= intg_i3;
            intg_q3_lat <= intg_q3;

            comb_i1_d <= intg_i3_lat;
            comb_q1_d <= intg_q3_lat;
            comb_i2_d <= comb_i1_w;
            comb_q2_d <= comb_q1_w;
            comb_i3_d <= comb_i2_w;
            comb_q3_d <= comb_q2_w;

            case (norm_shift)
                5'd17: begin shifted_i <= comb_i3_w >>> 17; shifted_q <= comb_q3_w >>> 17; end
                5'd14: begin shifted_i <= comb_i3_w >>> 14; shifted_q <= comb_q3_w >>> 14; end
                5'd11: begin shifted_i <= comb_i3_w >>> 11; shifted_q <= comb_q3_w >>> 11; end
                5'd8:  begin shifted_i <= comb_i3_w >>> 8;  shifted_q <= comb_q3_w >>> 8;  end
                default: begin shifted_i <= comb_i3_w >>> 17; shifted_q <= comb_q3_w >>> 17; end
            endcase
        end
    end

    // =========================================================
    // Output register (32 MHz, fires 1 cycle after cic_strobe)
    //
    // shifted_i/q are 26-bit signed; after norm_shift the useful range is
    // ±128 LSB at full scale (bits [8:0] have the signal, [25:9] are sign ext).
    // Use bits [17:0] for saturation check (same width as combchain's scaled_i).
    //
    // CDC note: the testbench (and any downstream consumer) captures iq_valid
    // on posedge clk_16m.  clk_16m is derived as clk_32m/2, so its posedge
    // fires every 2 clk_32m cycles.  A 1-cycle iq_valid pulse has a 50%
    // chance of being missed.  Extend to 2 clk_32m cycles (same trick as the
    // combchain fir_strobe_ext) so the clk_16m edge always catches it.
    // =========================================================

    reg strobe_out, strobe_out_r;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            strobe_out   <= 1'b0;
            strobe_out_r <= 1'b0;
        end else begin
            strobe_out   <= cic_strobe;
            strobe_out_r <= strobe_out;
        end
    end

    wire signed [17:0] out_val_i = shifted_i[17:0];
    wire signed [17:0] out_val_q = shifted_q[17:0];

    // iq_valid is high for 2 clk_32m cycles; iq_out latched on the first.
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            iq_out_i <= 8'sd0;
            iq_out_q <= 8'sd0;
            iq_valid <= 1'b0;
        end else begin
            iq_valid <= strobe_out | strobe_out_r;
            if (strobe_out) begin
                if      (out_val_i > 18'sd127)  iq_out_i <= 8'sd127;
                else if (out_val_i < -18'sd128) iq_out_i <= -8'sd128;
                else                            iq_out_i <= out_val_i[7:0];
                if      (out_val_q > 18'sd127)  iq_out_q <= 8'sd127;
                else if (out_val_q < -18'sd128) iq_out_q <= -8'sd128;
                else                            iq_out_q <= out_val_q[7:0];
            end
        end
    end

endmodule
