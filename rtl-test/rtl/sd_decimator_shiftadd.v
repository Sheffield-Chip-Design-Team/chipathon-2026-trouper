// sd_decimator_shiftadd.v
// Variant of sd_decimator_combchain that replaces the 13×16 general multiplier
// with explicit shift-add trees for each of the 5 FIR coefficients.
//
// Key change: fir_coeff_r (registered coefficient) and the variable multiply
//   wire signed [28:0] fir_mul_i = fir_pair_i_r * fir_coeff_r;
// are replaced by:
//   a registered tap-index pipeline stage (fir_tap_staged) feeding a case
//   statement where each arm is a constant multiply expressed as shifts+adds.
//
// Coefficient CSD decompositions (verified):
//   h[0] =  470 = 2^9  - 2^5  - 2^3 - 2^1
//   h[1] = -1111 = 1   - 2^3  - 2^4 - 2^6 - 2^10
//   h[2] =  2623 = 2^11 + 2^9  + 2^6 - 1
//   h[3] = -7089 = -1  + 2^4  + 2^6 + 2^10 - 2^13
//   h[4] = 26862 = 2^15 - 2^12 - 2^11 + 2^8 - 2^4 - 2^1
//
// All other logic is identical to sd_decimator_combchain.

`timescale 1ns/100ps

module sd_decimator_shiftadd (
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

    reg signed [25:0] intg_i1, intg_i2, intg_i3;
    reg signed [25:0] intg_q1, intg_q2, intg_q3;

    reg signed [25:0] comb_i1_d, comb_i2_d, comb_i3_d;
    reg signed [25:0] comb_q1_d, comb_q2_d, comb_q3_d;

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
            iq_in_i_r <= 1'b0; iq_in_q_r <= 1'b0;
            cic_bit_i_r <= 1'b0; cic_bit_q_r <= 1'b0;
            intg_i1 <= 26'sd0; intg_i2 <= 26'sd0; intg_i3 <= 26'sd0;
            intg_q1 <= 26'sd0; intg_q2 <= 26'sd0; intg_q3 <= 26'sd0;
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
    // 32 MHz domain: CIC comb stages + normalisation (combchain)
    // =========================================================

    reg signed [25:0] intg_i3_lat, intg_q3_lat;
    reg signed [25:0] shifted_i, shifted_q;

    wire signed [25:0] comb_i1_w = intg_i3_lat - comb_i1_d;
    wire signed [25:0] comb_q1_w = intg_q3_lat - comb_q1_d;
    wire signed [25:0] comb_i2_w = comb_i1_w  - comb_i2_d;
    wire signed [25:0] comb_q2_w = comb_q1_w  - comb_q2_d;
    wire signed [25:0] comb_i3_w = comb_i2_w  - comb_i3_d;
    wire signed [25:0] comb_q3_w = comb_q2_w  - comb_q3_d;

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

    reg strobe_pipe;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) strobe_pipe <= 1'b0;
        else        strobe_pipe <= cic_strobe;
    end

    // =========================================================
    // CDC: 32 MHz -> 16 MHz
    // =========================================================

    reg fir_strobe_r;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) fir_strobe_r <= 1'b0;
        else        fir_strobe_r <= strobe_pipe;
    end
    wire fir_strobe_ext = strobe_pipe | fir_strobe_r;

    wire signed [11:0] fir_in_i = shifted_i[11:0];
    wire signed [11:0] fir_in_q = shifted_q[11:0];

    // =========================================================
    // 16 MHz domain: FIR filter — shift-add constant multiply
    //
    // Pipeline stages (same depth as combchain baseline):
    //   Stage 1: register tap pair + tap index  (fir_pair_*_r, fir_tap_staged)
    //   Stage 2: compute constant multiply combinationally from stage-1 regs,
    //            register product               (fir_mul_*_r)
    //   Stage 3: accumulate registered product  (fir_acc_*)
    //
    // fir_coeff_r and the variable multiply are gone.
    // =========================================================

    reg [2:0]          fir_tap_idx;
    reg [2:0]          fir_tap_staged;    // tap index pipelined with pair data

    reg signed [11:0] fir_dl_i [0:8];
    reg signed [11:0] fir_dl_q [0:8];
    reg                fir_busy;
    reg signed [31:0]  fir_acc_i, fir_acc_q;
    reg signed [28:0]  fir_mul_i_r, fir_mul_q_r;
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

    // Constant-coefficient multiply: shift-add trees, one arm per tap.
    // fir_tap_staged holds the tap index registered at the same cycle as
    // fir_pair_*_r, so each arm is data × a compile-time constant.
    // Shifts are wiring only; each coefficient costs (terms-1) adder stages.
    //
    //  tap 0: h =  470 = 2^9 - 2^5 - 2^3 - 2^1          (3 adds)
    //  tap 1: h = -1111 = 1 - 2^3 - 2^4 - 2^6 - 2^10     (4 adds)
    //  tap 2: h =  2623 = 2^11 + 2^9 + 2^6 - 1            (3 adds)
    //  tap 3: h = -7089 = -1 + 2^4 + 2^6 + 2^10 - 2^13   (4 adds)
    //  tap 4: h = 26862 = 2^15-2^12-2^11+2^8-2^4-2^1      (5 adds)

    wire signed [28:0] fir_mul_i;
    wire signed [28:0] fir_mul_q;

    // Sign-extend pair to 29 bits for safe wide shifts
    wire signed [28:0] pi = {{16{fir_pair_i_r[12]}}, fir_pair_i_r};
    wire signed [28:0] pq = {{16{fir_pair_q_r[12]}}, fir_pair_q_r};

    always @(*) begin end  // keep always for linting; wires drive the mux
    assign fir_mul_i =
        (fir_tap_staged == 3'd0) ? ((pi<<<9) - (pi<<<5) - (pi<<<3) - (pi<<<1))    :
        (fir_tap_staged == 3'd1) ? (pi - (pi<<<3) - (pi<<<4) - (pi<<<6) - (pi<<<10)) :
        (fir_tap_staged == 3'd2) ? ((pi<<<11) + (pi<<<9) + (pi<<<6) - pi)          :
        (fir_tap_staged == 3'd3) ? (-pi + (pi<<<4) + (pi<<<6) + (pi<<<10) - (pi<<<13)) :
        (fir_tap_staged == 3'd4) ? ((pi<<<15) - (pi<<<12) - (pi<<<11) + (pi<<<8) - (pi<<<4) - (pi<<<1)) :
                                   29'sd0;

    assign fir_mul_q =
        (fir_tap_staged == 3'd0) ? ((pq<<<9) - (pq<<<5) - (pq<<<3) - (pq<<<1))    :
        (fir_tap_staged == 3'd1) ? (pq - (pq<<<3) - (pq<<<4) - (pq<<<6) - (pq<<<10)) :
        (fir_tap_staged == 3'd2) ? ((pq<<<11) + (pq<<<9) + (pq<<<6) - pq)          :
        (fir_tap_staged == 3'd3) ? (-pq + (pq<<<4) + (pq<<<6) + (pq<<<10) - (pq<<<13)) :
        (fir_tap_staged == 3'd4) ? ((pq<<<15) - (pq<<<12) - (pq<<<11) + (pq<<<8) - (pq<<<4) - (pq<<<1)) :
                                   29'sd0;

    wire signed [31:0] fir_acc_i_next = fir_acc_i + {{3{fir_mul_i_r[28]}}, fir_mul_i_r};
    wire signed [31:0] fir_acc_q_next = fir_acc_q + {{3{fir_mul_q_r[28]}}, fir_mul_q_r};

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
            fir_mul_i_r      <= 29'sd0;
            fir_mul_q_r      <= 29'sd0;
            fir_pair_i_r     <= 13'sd0;
            fir_pair_q_r     <= 13'sd0;
            fir_tap_staged   <= 3'd0;
            fir_pair_valid_r <= 1'b0;
            fir_mul_valid_r  <= 1'b0;
            fir_tap_idx      <= 3'd0;
            fir_busy         <= 1'b0;
            fir_acc_i        <= 32'sd0;
            fir_acc_q        <= 32'sd0;
        end else begin
            if (fir_strobe_ext && !fir_busy) begin
                for (j = 8; j > 0; j = j - 1) begin
                    fir_dl_i[j] <= fir_dl_i[j-1];
                    fir_dl_q[j] <= fir_dl_q[j-1];
                end
                fir_dl_i[0]      <= fir_in_i;
                fir_dl_q[0]      <= fir_in_q;
                fir_tap_idx      <= 3'd0;
                fir_busy         <= 1'b1;
                fir_acc_i        <= 32'sd0;
                fir_acc_q        <= 32'sd0;
                fir_pair_valid_r <= 1'b0;
                fir_mul_valid_r  <= 1'b0;
            end else if (fir_busy) begin
                if (fir_tap_idx <= 3'd4) begin
                    fir_pair_i_r     <= fir_pair_i;
                    fir_pair_q_r     <= fir_pair_q;
                    fir_tap_staged   <= fir_tap_idx;   // pipeline tap with pair data
                    fir_pair_valid_r <= 1'b1;
                    fir_tap_idx      <= fir_tap_idx + 3'd1;
                end else begin
                    fir_pair_valid_r <= 1'b0;
                    if (fir_output_now) begin
                        fir_busy    <= 1'b0;
                        fir_tap_idx <= 3'd0;
                    end else begin
                        fir_tap_idx <= fir_tap_idx + 3'd1;
                    end
                end

                fir_mul_i_r     <= fir_mul_i;
                fir_mul_q_r     <= fir_mul_q;
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
