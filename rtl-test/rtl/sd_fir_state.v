// sd_fir_state.v
// Per-channel FIR delay line for the TDM decimator refactor.
// Holds the 9-tap delay line and exposes symmetric tap sums as a
// combinational output, selected by tap_sel from the shared MAC.
//
// Interface:
//   load_strobe  — one clk_16m pulse per CIC output (= fir_strobe_ext &&
//                  !fir_busy in the monolithic design).  Shifts the delay
//                  line and loads cic_in at position 0.
//   tap_sel      — driven by the shared MAC scheduler (0..4).
//   tap_pair_i/q — combinational symmetric sum for the selected tap pair.
//                  The MAC registers these into its own pipeline stage 1
//                  (fir_pair_i_r), exactly as the monolithic design did.
//
// Tap symmetry (9-tap Type-I FIR, h[k]=h[8-k]):
//   tap 0: dl[0] + dl[8]
//   tap 1: dl[1] + dl[7]
//   tap 2: dl[2] + dl[6]
//   tap 3: dl[3] + dl[5]
//   tap 4: dl[4]          (centre tap, no pair)
//
// GF180MCU 3.3V

`timescale 1ns/100ps

module sd_fir_state (
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire signed [11:0] cic_in_i,
    input  wire signed [11:0] cic_in_q,
    input  wire        load_strobe,
    input  wire [2:0]  tap_sel,
    output wire signed [12:0] tap_pair_i,
    output wire signed [12:0] tap_pair_q
);

    reg signed [11:0] dl_i [0:8];
    reg signed [11:0] dl_q [0:8];

    always @(posedge clk_16m or negedge rst_n) begin : dl_shift
        integer j;
        if (!rst_n) begin
            for (j = 0; j <= 8; j = j + 1) begin
                dl_i[j] <= 12'sd0;
                dl_q[j] <= 12'sd0;
            end
        end else if (load_strobe) begin
            for (j = 8; j > 0; j = j - 1) begin
                dl_i[j] <= dl_i[j-1];
                dl_q[j] <= dl_q[j-1];
            end
            dl_i[0] <= cic_in_i;
            dl_q[0] <= cic_in_q;
        end
    end

    // Combinational symmetric-pair mux — matches the original fir_pair_i/q
    // always @(*) block in sd_decimator_combchain verbatim.
    reg signed [12:0] pair_i_r, pair_q_r;
    always @(*) begin
        case (tap_sel)
            3'd0: begin
                pair_i_r = {dl_i[0][11], dl_i[0]} + {dl_i[8][11], dl_i[8]};
                pair_q_r = {dl_q[0][11], dl_q[0]} + {dl_q[8][11], dl_q[8]};
            end
            3'd1: begin
                pair_i_r = {dl_i[1][11], dl_i[1]} + {dl_i[7][11], dl_i[7]};
                pair_q_r = {dl_q[1][11], dl_q[1]} + {dl_q[7][11], dl_q[7]};
            end
            3'd2: begin
                pair_i_r = {dl_i[2][11], dl_i[2]} + {dl_i[6][11], dl_i[6]};
                pair_q_r = {dl_q[2][11], dl_q[2]} + {dl_q[6][11], dl_q[6]};
            end
            3'd3: begin
                pair_i_r = {dl_i[3][11], dl_i[3]} + {dl_i[5][11], dl_i[5]};
                pair_q_r = {dl_q[3][11], dl_q[3]} + {dl_q[5][11], dl_q[5]};
            end
            3'd4: begin
                pair_i_r = {dl_i[4][11], dl_i[4]};
                pair_q_r = {dl_q[4][11], dl_q[4]};
            end
            default: begin pair_i_r = 13'sd0; pair_q_r = 13'sd0; end
        endcase
    end

    assign tap_pair_i = pair_i_r;
    assign tap_pair_q = pair_q_r;

endmodule
