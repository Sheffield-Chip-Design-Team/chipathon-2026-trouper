// sd_decimator_sa3.v
// CIC N=3 decimator + 5-tap shift-and-add FIR compensation.
//
// FIR: h = [-1, -2, 10, -2, -1] / 4  (no multiplier — shifts and adds only)
//   y[n] = (-x[n] - 2·x[n-1] + 10·x[n-2] - 2·x[n-3] - x[n-4]) / 4
//   10·x = (x<<3) + (x<<1);  divide-by-4 = arithmetic >> 2
//
// Frequency response (Type-I symmetric): H(ω) = (10 - 4·cos(ω) - 2·cos(2ω)) / 4
//   DC:          H = 1.0
//   0.9×Nyquist: H = 3.05  → compensates CIC's 0.34 attenuation to ~1.04
//
// All logic on clk_32m.  clk_16m accepted but unused (drop-in port compat).
//
// GF180MCU, 3.3V

`timescale 1ns/100ps

module sd_decimator_sa3 (
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

            // Round-to-nearest: add half-LSB before arithmetic right shift
            case (norm_shift)
                5'd17: begin shifted_i <= (comb_i3_w + 26'sd65536) >>> 17; shifted_q <= (comb_q3_w + 26'sd65536) >>> 17; end
                5'd14: begin shifted_i <= (comb_i3_w + 26'sd8192)  >>> 14; shifted_q <= (comb_q3_w + 26'sd8192)  >>> 14; end
                5'd11: begin shifted_i <= (comb_i3_w + 26'sd1024)  >>> 11; shifted_q <= (comb_q3_w + 26'sd1024)  >>> 11; end
                5'd8:  begin shifted_i <= (comb_i3_w + 26'sd128)   >>> 8;  shifted_q <= (comb_q3_w + 26'sd128)   >>> 8;  end
                default: begin shifted_i <= (comb_i3_w + 26'sd65536) >>> 17; shifted_q <= (comb_q3_w + 26'sd65536) >>> 17; end
            endcase
        end
    end

    // =========================================================
    // Strobe pipeline (shifted_i/q valid 1 cycle after cic_strobe)
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

    // =========================================================
    // 3-tap shift-add FIR: h = [-1, 4, -1] / 2
    //
    // x[n]   = cic_out (newest, valid at strobe_out)
    // x[n-1] = dl[0], x[n-2] = dl[1]
    //
    // y[n] = round((4·x[n-1] - x[n] - x[n-2]) / 2)
    //      = (((x[n-1] << 2) - x[n] - x[n-2]) + 1) >> 1   (round-to-nearest)
    //
    // All combinational; result registered on strobe_out.
    // =========================================================

    wire signed [11:0] cic_out_i = shifted_i[11:0];
    wire signed [11:0] cic_out_q = shifted_q[11:0];

    reg signed [11:0] fir_dl_i0, fir_dl_i1;
    reg signed [11:0] fir_dl_q0, fir_dl_q1;

    // acc = (4·dl0 - cic_out - dl1); all old values at strobe_out edge
    wire signed [14:0] fir_acc_i = ({{3{fir_dl_i0[11]}}, fir_dl_i0} <<< 2)
                                 - {{3{cic_out_i[11]}},   cic_out_i}
                                 - {{3{fir_dl_i1[11]}},   fir_dl_i1};
    wire signed [14:0] fir_acc_q = ({{3{fir_dl_q0[11]}}, fir_dl_q0} <<< 2)
                                 - {{3{cic_out_q[11]}},   cic_out_q}
                                 - {{3{fir_dl_q1[11]}},   fir_dl_q1};

    // Round-to-nearest divide-by-2: (acc + 1) >> 1
    wire signed [13:0] fir_out_i = (fir_acc_i + 15'sd1) >>> 1;
    wire signed [13:0] fir_out_q = (fir_acc_q + 15'sd1) >>> 1;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            fir_dl_i0 <= 12'sd0; fir_dl_i1 <= 12'sd0;
            fir_dl_q0 <= 12'sd0; fir_dl_q1 <= 12'sd0;
            iq_out_i  <= 8'sd0;
            iq_out_q  <= 8'sd0;
            iq_valid  <= 1'b0;
        end else begin
            iq_valid <= strobe_out | strobe_out_r;
            if (strobe_out) begin
                // Shift delay line (FIR uses old values computed above)
                fir_dl_i1 <= fir_dl_i0;
                fir_dl_i0 <= cic_out_i;
                fir_dl_q1 <= fir_dl_q0;
                fir_dl_q0 <= cic_out_q;

                // Saturate and register FIR output
                if      (fir_out_i > 14'sd127)  iq_out_i <= 8'sd127;
                else if (fir_out_i < -14'sd128) iq_out_i <= -8'sd128;
                else                             iq_out_i <= fir_out_i[7:0];

                if      (fir_out_q > 14'sd127)  iq_out_q <= 8'sd127;
                else if (fir_out_q < -14'sd128) iq_out_q <= -8'sd128;
                else                             iq_out_q <= fir_out_q[7:0];
            end
        end
    end

endmodule
