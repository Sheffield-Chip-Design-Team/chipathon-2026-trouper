`timescale 1ns/100ps
// tb_fir_state_wrap.v
// Verification wrapper for step 2 of the TDM refactor.
// Instantiates sd_cic_chan + sd_fir_state; keeps the FIR MAC inline but
// removes the delay line and pair mux (now provided by sd_fir_state).
// Renamed sd_decimator so tb_sqnr.v drives it unchanged.
// Expected result: bit-exact vs sd_decimator_combchain.

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

    // --- sd_cic_chan ---
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

    // --- CDC: extend 1-cycle 32 MHz strobe to span one 16 MHz edge ---
    reg fir_strobe_r;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) fir_strobe_r <= 1'b0;
        else        fir_strobe_r <= cic_valid_32m;
    end
    wire fir_strobe_ext = cic_valid_32m | fir_strobe_r;

    // --- FIR control state (16 MHz) ---
    reg [2:0]  fir_tap_idx;
    reg        fir_busy;
    reg        fir_pair_valid_r, fir_mul_valid_r;

    // load_strobe: one 16 MHz pulse at the start of each FIR computation
    wire load_strobe = fir_strobe_ext && !fir_busy;

    // --- sd_fir_state: per-channel delay line + tap-pair mux ---
    wire signed [12:0] tap_pair_i, tap_pair_q;

    sd_fir_state u_fir_state (
        .clk_16m    (clk_16m),
        .rst_n      (rst_n),
        .cic_in_i   (cic_out_i),
        .cic_in_q   (cic_out_q),
        .load_strobe(load_strobe),
        .tap_sel    (fir_tap_idx),
        .tap_pair_i (tap_pair_i),
        .tap_pair_q (tap_pair_q)
    );

    // --- FIR MAC (inline, verbatim from sd_decimator_combchain) ---
    reg signed [15:0] fir_coeff_sel;
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

    reg signed [31:0]  fir_acc_i, fir_acc_q;
    reg signed [28:0]  fir_mul_i_r, fir_mul_q_r;
    reg signed [15:0]  fir_coeff_r;
    reg signed [12:0]  fir_pair_i_r, fir_pair_q_r;

    wire signed [28:0] fir_mul_i = fir_pair_i_r * fir_coeff_r;
    wire signed [28:0] fir_mul_q = fir_pair_q_r * fir_coeff_r;

    wire signed [31:0] fir_acc_i_next = fir_acc_i + {{3{fir_mul_i_r[28]}}, fir_mul_i_r};
    wire signed [31:0] fir_acc_q_next = fir_acc_q + {{3{fir_mul_q_r[28]}}, fir_mul_q_r};

    wire signed [31:0] round_val_i = fir_acc_i_next + 32'sd8192;
    wire signed [31:0] round_val_q = fir_acc_q_next + 32'sd8192;
    wire signed [17:0] scaled_i    = round_val_i[31:14];
    wire signed [17:0] scaled_q    = round_val_q[31:14];
    wire fir_output_now = fir_busy && (fir_tap_idx == 3'd6) && fir_mul_valid_r;

    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n) begin
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
                // delay line shift is handled by sd_fir_state via load_strobe
                fir_tap_idx      <= 3'd0;
                fir_busy         <= 1'b1;
                fir_acc_i        <= 32'sd0;
                fir_acc_q        <= 32'sd0;
                fir_pair_valid_r <= 1'b0;
                fir_mul_valid_r  <= 1'b0;
            end else if (fir_busy) begin
                if (fir_tap_idx <= 3'd4) begin
                    // tap_pair_i/q come from sd_fir_state (combinational on tap_sel=fir_tap_idx)
                    fir_pair_i_r     <= tap_pair_i;
                    fir_pair_q_r     <= tap_pair_q;
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
