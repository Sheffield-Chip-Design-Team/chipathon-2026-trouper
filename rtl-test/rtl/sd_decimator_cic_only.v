// sd_decimator_cic_only.v
// CIC N=3 decimator — no FIR compensation, no multiplier.
//
// Drop-in replacement for sd_decimator_combchain: identical port list,
// identical clk_32m / clk_16m / rst_n / decim_ratio / iq_in / iq_out ports.
// clk_16m is accepted but unused; all logic runs on clk_32m.
//
// Pipeline (all clk_32m):
//   Cycle 0-N : CIC integrators (every cycle)
//   Cycle N   : cic_strobe fires, captures the next decimated snapshot
//   Cycle N+1 : comb stage 1
//   Cycle N+2 : comb stage 2
//   Cycle N+3 : comb stage 3
//   Cycle N+4 : normalise / shift
//   Cycle N+5 : output register latches, asserts iq_valid
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
    // CIC comb stages + normalisation
    //
    // The comb tail only has work to do on decimated samples. Splitting it
    // over several clk_32m cycles removes the long strobe-gated path that
    // dominated SS timing while staying well inside the minimum 32-cycle
    // spacing between cic_strobe pulses.
    // =========================================================

    reg signed [25:0] intg_i3_lat, intg_q3_lat;
    reg signed [25:0] comb_i1_d, comb_i2_d, comb_i3_d;
    reg signed [25:0] comb_q1_d, comb_q2_d, comb_q3_d;
    reg signed [25:0] comb_i1_pipe, comb_i2_pipe, comb_i3_pipe;
    reg signed [25:0] comb_q1_pipe, comb_q2_pipe, comb_q3_pipe;
    reg signed [25:0] shifted_i, shifted_q;
    reg               comb1_valid, comb2_valid, comb3_valid, shift_valid;

    wire signed [25:0] comb_i1_w = intg_i3_lat - comb_i1_d;
    wire signed [25:0] comb_q1_w = intg_q3_lat - comb_q1_d;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            intg_i3_lat <= 26'sd0; intg_q3_lat <= 26'sd0;
            comb_i1_d   <= 26'sd0; comb_i2_d   <= 26'sd0; comb_i3_d   <= 26'sd0;
            comb_q1_d   <= 26'sd0; comb_q2_d   <= 26'sd0; comb_q3_d   <= 26'sd0;
            comb_i1_pipe <= 26'sd0; comb_i2_pipe <= 26'sd0; comb_i3_pipe <= 26'sd0;
            comb_q1_pipe <= 26'sd0; comb_q2_pipe <= 26'sd0; comb_q3_pipe <= 26'sd0;
            shifted_i   <= 26'sd0; shifted_q   <= 26'sd0;
            comb1_valid <= 1'b0;
            comb2_valid <= 1'b0;
            comb3_valid <= 1'b0;
            shift_valid <= 1'b0;
        end else begin
            comb1_valid <= cic_strobe;
            comb2_valid <= comb1_valid;
            comb3_valid <= comb2_valid;
            shift_valid <= comb3_valid;

            if (cic_strobe) begin
                comb_i1_pipe <= comb_i1_w;
                comb_q1_pipe <= comb_q1_w;
                comb_i1_d    <= intg_i3_lat;
                comb_q1_d    <= intg_q3_lat;
                intg_i3_lat  <= intg_i3;
                intg_q3_lat  <= intg_q3;
            end

            if (comb1_valid) begin
                comb_i2_pipe <= comb_i1_pipe - comb_i2_d;
                comb_q2_pipe <= comb_q1_pipe - comb_q2_d;
                comb_i2_d    <= comb_i1_pipe;
                comb_q2_d    <= comb_q1_pipe;
            end

            if (comb2_valid) begin
                comb_i3_pipe <= comb_i2_pipe - comb_i3_d;
                comb_q3_pipe <= comb_q2_pipe - comb_q3_d;
                comb_i3_d    <= comb_i2_pipe;
                comb_q3_d    <= comb_q2_pipe;
            end

            if (comb3_valid) begin
                case (norm_shift)
                    5'd17: begin shifted_i <= comb_i3_pipe >>> 17; shifted_q <= comb_q3_pipe >>> 17; end
                    5'd14: begin shifted_i <= comb_i3_pipe >>> 14; shifted_q <= comb_q3_pipe >>> 14; end
                    5'd11: begin shifted_i <= comb_i3_pipe >>> 11; shifted_q <= comb_q3_pipe >>> 11; end
                    5'd8:  begin shifted_i <= comb_i3_pipe >>> 8;  shifted_q <= comb_q3_pipe >>> 8;  end
                    default: begin shifted_i <= comb_i3_pipe >>> 17; shifted_q <= comb_q3_pipe >>> 17; end
                endcase
            end
        end
    end

    // =========================================================
    // Output register
    //
    // shifted_i/q are 26-bit signed; after norm_shift the useful range is
    // ±128 LSB at full scale (bits [8:0] have the signal, [25:9] are sign ext).
    // Use bits [17:0] for saturation check (same width as combchain's scaled_i).
    //
    // CDC note: the testbench (and any downstream consumer) captures iq_valid
    // on posedge clk_16m.  clk_16m is derived as clk_32m/2, so its posedge
    // fires every 2 clk_32m cycles.  A 1-cycle iq_valid pulse has a 50%
    // chance of being missed.  Extend to 2 clk_32m cycles so the clk_16m
    // edge always catches it.
    // =========================================================

    reg out_fire, out_fire_r;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            out_fire   <= 1'b0;
            out_fire_r <= 1'b0;
        end else begin
            out_fire   <= shift_valid;
            out_fire_r <= out_fire;
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
            iq_valid <= out_fire | out_fire_r;
            if (out_fire) begin
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
