`timescale 1ns/100ps
// tb_cic_chan_wrap.v
// Verification wrapper: sd_cic_chan + a copy of the FIR section from
// sd_decimator_combchain, wired together.  The result is functionally
// identical to sd_decimator_combchain; we rename the top to sd_decimator
// so tb_sqnr.v can drive it without changes.
//
// Purpose: confirm that sd_cic_chan.v produces bit-exact output vs the
// monolithic combchain after the interface cut.

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

    // --- CIC front-end (sd_cic_chan) ---
    wire signed [11:0] cic_out_i, cic_out_q;
    wire               cic_valid_32m;

    sd_cic_chan u_cic (
        .clk_32m    (clk_32m),
        .rst_n      (rst_n),
        .iq_in_i    (iq_in_i),
        .iq_in_q    (iq_in_q),
        .decim_ratio(decim_ratio),
        .cic_out_i  (cic_out_i),
        .cic_out_q  (cic_out_q),
        .cic_valid  (cic_valid_32m)
    );

    // --- CDC: extend 1-cycle 32 MHz pulse to span one 16 MHz edge ---
    reg fir_strobe_r;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) fir_strobe_r <= 1'b0;
        else        fir_strobe_r <= cic_valid_32m;
    end
    wire fir_strobe_ext = cic_valid_32m | fir_strobe_r;

    // cic_out_i/q are stable for 256 clk_32m cycles after cic_valid — safe
    // to read directly from 16 MHz domain without extra latching.
    wire signed [11:0] fir_in_i = cic_out_i;
    wire signed [11:0] fir_in_q = cic_out_q;

    // --- FIR filter (verbatim from sd_decimator_combchain) ---
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

    wire signed [28:0] fir_mul_i = fir_pair_i_r * fir_coeff_r;
    wire signed [28:0] fir_mul_q = fir_pair_q_r * fir_coeff_r;

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
            fir_coeff_r      <= 16'sd0;
            fir_pair_i_r     <= 13'sd0;
            fir_pair_q_r     <= 13'sd0;
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
                    fir_coeff_r      <= fir_coeff_sel;
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
