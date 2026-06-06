// sd_cic_chan.v
// Per-channel CIC N=3 decimator front-end for one SX1257 antenna (I+Q).
// All logic runs in the 32 MHz domain.
//
// Outputs:
//   cic_out_i / cic_out_q  — 12-bit normalised CIC result (= shifted[11:0])
//   cic_valid              — 1-cycle 32 MHz pulse: new sample ready
//
// This module is step 1 of the TDM refactor.  It contains exactly the
// 32 MHz section of sd_decimator_combchain, cut at shifted_i/q + strobe_pipe.
// The FIR, CDC extension, and output registers move to sd_fir_shared.
//
// GF180MCU 3.3V

`timescale 1ns/100ps

module sd_cic_chan (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire        iq_in_i,
    input  wire        iq_in_q,
    input  wire [1:0]  decim_ratio,
    output wire signed [11:0] cic_out_i,
    output wire signed [11:0] cic_out_q,
    output wire        cic_valid          // 1-cycle pulse at clk_32m
);

    // =========================================================
    // Integrators
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
    // CIC comb stages + normalisation (combinational chain)
    // =========================================================

    reg signed [25:0] comb_i1_d, comb_i2_d, comb_i3_d;
    reg signed [25:0] comb_q1_d, comb_q2_d, comb_q3_d;

    reg signed [25:0] intg_i3_lat, intg_q3_lat;
    reg signed [25:0] shifted_i, shifted_q;

    wire signed [25:0] comb_i1_w = intg_i3_lat - comb_i1_d;
    wire signed [25:0] comb_q1_w = intg_q3_lat - comb_q1_d;
    wire signed [25:0] comb_i2_w = comb_i1_w   - comb_i2_d;
    wire signed [25:0] comb_q2_w = comb_q1_w   - comb_q2_d;
    wire signed [25:0] comb_i3_w = comb_i2_w   - comb_i3_d;
    wire signed [25:0] comb_q3_w = comb_q2_w   - comb_q3_d;

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
                5'd8:  begin shifted_i <= comb_i3_w >>>  8; shifted_q <= comb_q3_w >>>  8; end
                default: begin shifted_i <= comb_i3_w >>> 17; shifted_q <= comb_q3_w >>> 17; end
            endcase
        end
    end

    // strobe_pipe: 1-cycle delay to align with shifted_i/q settling
    reg strobe_pipe;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) strobe_pipe <= 1'b0;
        else        strobe_pipe <= cic_strobe;
    end

    assign cic_out_i = shifted_i[11:0];
    assign cic_out_q = shifted_q[11:0];
    assign cic_valid = strobe_pipe;

endmodule
