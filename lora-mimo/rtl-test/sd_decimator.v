// sd_decimator.v
// CIC N=3 decimator + 9-tap FIR compensation for one SX1257 antenna (I+Q)
//
// Two clock domains:
//   clk_32m : CIC integrators, comb stages, strobe generation
//   clk_16m : FIR filter + output registers  (clk_16m = clk_32m / 2)
//
// CDC (32M -> 16M):
//   strobe_pipe[2] is extended to 2 clk_32m cycles (fir_strobe_ext) so that
//   it spans at least one clk_16m rising edge regardless of phase alignment.
//   shifted_i/q data remains stable for 256 clk_32m cycles — safe to read
//   directly from the 16M domain without extra latching.
//
// FIR pipeline: single-cycle 13x16 multiply at 16 MHz (62.5 ns budget).
//   6 busy tap cycles (tap 0..5). Invisible at 125 kS/s.
//
// GF180MCU, 3.3V

module sd_decimator (
    input  wire        clk_32m,
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire        iq_in_i,
    input  wire        iq_in_q,
    input  wire [1:0]  decim_ratio,
    output reg  signed [7:0] iq_out_i,
    output reg  signed [7:0] iq_out_q,
    output reg         iq_valid
);

    // =========================================================
    // 32 MHz domain: CIC integrators
    // =========================================================

    reg iq_in_i_r, iq_in_q_r;
    reg cic_bit_i_r, cic_bit_q_r;

    reg signed [24:0] intg_i1, intg_i2, intg_i3;
    reg signed [24:0] intg_q1, intg_q2, intg_q3;

    reg signed [24:0] comb_i1_d, comb_i2_d, comb_i3_d;
    reg signed [24:0] comb_q1_d, comb_q2_d, comb_q3_d;
    reg signed [24:0] comb_i1_out, comb_i2_out, comb_i3_out;
    reg signed [24:0] comb_q1_out, comb_q2_out, comb_q3_out;

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

    wire signed [24:0] intg_i1_next = cic_bit_i_r ? (intg_i1 + 25'sd1) : (intg_i1 - 25'sd2);
    wire signed [24:0] intg_i2_next = intg_i2 + intg_i1;
    wire signed [24:0] intg_i3_next = intg_i3 + intg_i2;
    wire signed [24:0] intg_q1_next = cic_bit_q_r ? (intg_q1 + 25'sd1) : (intg_q1 - 25'sd2);
    wire signed [24:0] intg_q2_next = intg_q2 + intg_q1;
    wire signed [24:0] intg_q3_next = intg_q3 + intg_q2;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            iq_in_i_r <= 1'b0; iq_in_q_r <= 1'b0;
            cic_bit_i_r <= 1'b0; cic_bit_q_r <= 1'b0;
            intg_i1 <= 25'sd0; intg_i2 <= 25'sd0; intg_i3 <= 25'sd0;
            intg_q1 <= 25'sd0; intg_q2 <= 25'sd0; intg_q3 <= 25'sd0;
            decim_cnt  <= 8'd0;
            cic_strobe <= 1'b0;
        end else begin
            iq_in_i_r <= iq_in_i;
            iq_in_q_r <= iq_in_q;
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
    // 32 MHz domain: CIC comb stages + normalisation
    // =========================================================

    reg signed [24:0] intg_i3_lat, intg_q3_lat;
    reg signed [24:0] shifted_i, shifted_q;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            intg_i3_lat <= 25'sd0; intg_q3_lat <= 25'sd0;
            comb_i1_d   <= 25'sd0; comb_i2_d   <= 25'sd0; comb_i3_d   <= 25'sd0;
            comb_q1_d   <= 25'sd0; comb_q2_d   <= 25'sd0; comb_q3_d   <= 25'sd0;
            comb_i1_out <= 25'sd0; comb_i2_out <= 25'sd0; comb_i3_out <= 25'sd0;
            comb_q1_out <= 25'sd0; comb_q2_out <= 25'sd0; comb_q3_out <= 25'sd0;
            shifted_i   <= 25'sd0; shifted_q   <= 25'sd0;
        end else if (cic_strobe) begin
            intg_i3_lat <= intg_i3;
            intg_q3_lat <= intg_q3;

            comb_i1_out <= intg_i3_lat - comb_i1_d; comb_i1_d <= intg_i3_lat;
            comb_q1_out <= intg_q3_lat - comb_q1_d; comb_q1_d <= intg_q3_lat;
            comb_i2_out <= comb_i1_out - comb_i2_d; comb_i2_d <= comb_i1_out;
            comb_q2_out <= comb_q1_out - comb_q2_d; comb_q2_d <= comb_q1_out;
            comb_i3_out <= comb_i2_out - comb_i3_d; comb_i3_d <= comb_i2_out;
            comb_q3_out <= comb_q2_out - comb_q3_d; comb_q3_d <= comb_q2_out;

            case (norm_shift)
                5'd17: begin shifted_i <= comb_i3_out >>> 17; shifted_q <= comb_q3_out >>> 17; end
                5'd14: begin shifted_i <= comb_i3_out >>> 14; shifted_q <= comb_q3_out >>> 14; end
                5'd11: begin shifted_i <= comb_i3_out >>> 11; shifted_q <= comb_q3_out >>> 11; end
                5'd8:  begin shifted_i <= comb_i3_out >>> 8;  shifted_q <= comb_q3_out >>> 8;  end
                default: begin shifted_i <= comb_i3_out >>> 17; shifted_q <= comb_q3_out >>> 17; end
            endcase
        end
    end

    // Strobe pipeline: 3 cycles to align with comb output latency
    reg [2:0] strobe_pipe;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) strobe_pipe <= 3'b0;
        else        strobe_pipe <= {strobe_pipe[1:0], cic_strobe};
    end

    // =========================================================
    // CDC: 32 MHz -> 16 MHz
    // Extend strobe_pipe[2] to 2 clk_32m cycles. This guarantees that
    // fir_strobe_ext is high on exactly one clk_16m rising edge, regardless
    // of whether the 16M edge aligns with clk_32m cycle N or N+1.
    // =========================================================

    reg fir_strobe_r;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) fir_strobe_r <= 1'b0;
        else        fir_strobe_r <= strobe_pipe[2];
    end
    wire fir_strobe_ext = strobe_pipe[2] | fir_strobe_r;

    // Data crossing: shifted_i/q are stable for 256 clk_32m cycles after the
    // strobe — the 16M FIR reads them directly with no extra register.
    wire signed [11:0] fir_in_i = shifted_i[11:0];
    wire signed [11:0] fir_in_q = shifted_q[11:0];

    // =========================================================
    // 16 MHz domain: FIR filter
    // 9-tap symmetric Type-I, Q1.14 coefficients.
    // h[k]=h[8-k]; 5 unique coefficients; fir_tap_idx 0..5 (6 busy cycles).
    // Single-cycle 13x16 multiply: fits comfortably in 62.5 ns at SS corner.
    // =========================================================

    reg signed [15:0] fir_coeff_sel;
    reg [2:0]          fir_tap_idx;
    always @(*) begin
        case (fir_tap_idx)
            3'd0: fir_coeff_sel = 16'sd470;
            3'd1: fir_coeff_sel = -16'sd1111;
            3'd2: fir_coeff_sel = 16'sd2623;
            3'd3: fir_coeff_sel = -16'sd7089;
            3'd4: fir_coeff_sel = 16'sd26862;
            default: fir_coeff_sel = 16'sd0;
        endcase
    end

    reg signed [11:0] fir_dl_i [0:8];
    reg signed [11:0] fir_dl_q [0:8];
    reg                fir_busy;
    reg signed [31:0]  fir_acc_i, fir_acc_q;
    reg signed [28:0]  fir_mul_i_r, fir_mul_q_r;
    reg signed [15:0]  fir_coeff_r;
    reg signed [12:0]  fir_pair_i_r, fir_pair_q_r;
    reg                fir_pair_valid_r, fir_mul_valid_r;

    reg signed [12:0] fir_pair_i, fir_pair_q;
    always @(*) begin
        case (fir_tap_idx)
            3'd0: begin
                fir_pair_i = {fir_dl_i[0][11], fir_dl_i[0]} + {fir_dl_i[8][11], fir_dl_i[8]};
                fir_pair_q = {fir_dl_q[0][11], fir_dl_q[0]} + {fir_dl_q[8][11], fir_dl_q[8]};
            end
            3'd1: begin
                fir_pair_i = {fir_dl_i[1][11], fir_dl_i[1]} + {fir_dl_i[7][11], fir_dl_i[7]};
                fir_pair_q = {fir_dl_q[1][11], fir_dl_q[1]} + {fir_dl_q[7][11], fir_dl_q[7]};
            end
            3'd2: begin
                fir_pair_i = {fir_dl_i[2][11], fir_dl_i[2]} + {fir_dl_i[6][11], fir_dl_i[6]};
                fir_pair_q = {fir_dl_q[2][11], fir_dl_q[2]} + {fir_dl_q[6][11], fir_dl_q[6]};
            end
            3'd3: begin
                fir_pair_i = {fir_dl_i[3][11], fir_dl_i[3]} + {fir_dl_i[5][11], fir_dl_i[5]};
                fir_pair_q = {fir_dl_q[3][11], fir_dl_q[3]} + {fir_dl_q[5][11], fir_dl_q[5]};
            end
            3'd4: begin
                fir_pair_i = {fir_dl_i[4][11], fir_dl_i[4]};
                fir_pair_q = {fir_dl_q[4][11], fir_dl_q[4]};
            end
            default: begin fir_pair_i = 13'sd0; fir_pair_q = 13'sd0; end
        endcase
    end

    // Single-cycle 13x16 multiply (fits in 62.5 ns on clk_16m at SS corner)
    wire signed [28:0] fir_mul_i = fir_pair_i_r * fir_coeff_r;
    wire signed [28:0] fir_mul_q = fir_pair_q_r * fir_coeff_r;

    // Accumulate from registered product
    wire signed [31:0] fir_acc_i_next = fir_acc_i + {{3{fir_mul_i_r[28]}}, fir_mul_i_r};
    wire signed [31:0] fir_acc_q_next = fir_acc_q + {{3{fir_mul_q_r[28]}}, fir_mul_q_r};

    // Q1.14 round-to-nearest
    wire signed [31:0] round_val_i = fir_acc_i_next + 32'sd8192;
    wire signed [31:0] round_val_q = fir_acc_q_next + 32'sd8192;
    wire signed [17:0] scaled_i    = round_val_i[31:14];
    wire signed [17:0] scaled_q    = round_val_q[31:14];
    wire fir_output_now = fir_busy && (fir_tap_idx == 3'd6) && fir_mul_valid_r;

    always @(posedge clk_16m or negedge rst_n) begin : fir_block
        integer j;
        if (!rst_n) begin
            for (j = 0; j <= 8; j = j + 1) begin
                fir_dl_i[j] <= 12'sd0;
                fir_dl_q[j] <= 12'sd0;
            end
            fir_mul_i_r <= 29'sd0;
            fir_mul_q_r <= 29'sd0;
            fir_coeff_r <= 16'sd0;
            fir_pair_i_r <= 13'sd0;
            fir_pair_q_r <= 13'sd0;
            fir_pair_valid_r <= 1'b0;
            fir_mul_valid_r <= 1'b0;
            fir_tap_idx <= 3'd0;
            fir_busy    <= 1'b0;
            fir_acc_i   <= 32'sd0;
            fir_acc_q   <= 32'sd0;
        end else begin
            if (fir_strobe_ext && !fir_busy) begin
                for (j = 8; j > 0; j = j - 1) begin
                    fir_dl_i[j] <= fir_dl_i[j-1];
                    fir_dl_q[j] <= fir_dl_q[j-1];
                end
                fir_dl_i[0] <= fir_in_i;
                fir_dl_q[0] <= fir_in_q;
                fir_tap_idx <= 3'd0;
                fir_busy    <= 1'b1;
                fir_acc_i   <= 32'sd0;
                fir_acc_q   <= 32'sd0;
                fir_pair_valid_r <= 1'b0;
                fir_mul_valid_r <= 1'b0;
            end else if (fir_busy) begin
                if (fir_tap_idx <= 3'd4) begin
                    fir_pair_i_r <= fir_pair_i;
                    fir_pair_q_r <= fir_pair_q;
                    fir_coeff_r  <= fir_coeff_sel;
                    fir_pair_valid_r <= 1'b1;
                    fir_tap_idx <= fir_tap_idx + 3'd1;
                end else begin
                    fir_pair_valid_r <= 1'b0;
                    if (fir_output_now) begin
                        fir_busy    <= 1'b0;
                        fir_tap_idx <= 3'd0;
                    end else begin
                        fir_tap_idx <= fir_tap_idx + 3'd1;
                    end
                end

                fir_mul_i_r <= fir_mul_i;
                fir_mul_q_r <= fir_mul_q;
                fir_mul_valid_r <= fir_pair_valid_r;

                if (fir_mul_valid_r) begin
                    fir_acc_i <= fir_acc_i_next;
                    fir_acc_q <= fir_acc_q_next;
                end
            end
        end
    end

    // Output register on clk_16m
    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n) begin
            iq_out_i <= 8'sd0;
            iq_out_q <= 8'sd0;
            iq_valid <= 1'b0;
        end else begin
            iq_valid <= fir_output_now;
            if (fir_output_now) begin
                if (scaled_i > 18'sd127)       iq_out_i <= 8'sd127;
                else if (scaled_i < -18'sd128) iq_out_i <= -8'sd128;
                else                            iq_out_i <= scaled_i[7:0];
                if (scaled_q > 18'sd127)       iq_out_q <= 8'sd127;
                else if (scaled_q < -18'sd128) iq_out_q <= -8'sd128;
                else                            iq_out_q <= scaled_q[7:0];
            end
        end
    end

endmodule
