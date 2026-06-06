`timescale 1ns/100ps
// tb_fir_mac_1ch_wrap.v
// Step 3 verification: sd_cic_chan + sd_fir_state + sd_fir_mac, 1 channel.
// Channels 1-3 tied off; only ch 0 is active.
// The shared MAC processes ch 0 in every round — functionally identical to
// the monolithic combchain.  Expected: bit-exact vs sd_decimator_combchain.

module sd_decimator (
    input  wire        clk_32m,
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire        iq_in_i,
    input  wire        iq_in_q,
    input  wire [1:0]  decim_ratio,
    output wire signed [7:0] iq_out_i,
    output wire signed [7:0] iq_out_q,
    output wire        iq_valid
);

    // --- CIC ---
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

    // --- CDC: extend 32 MHz pulse to guarantee one 16 MHz edge ---
    reg fir_strobe_r;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) fir_strobe_r <= 1'b0;
        else        fir_strobe_r <= cic_valid_32m;
    end
    wire ch_valid_0 = cic_valid_32m | fir_strobe_r;  // 16 MHz domain safe

    // --- FIR state (ch 0) ---
    wire [2:0]  tap_sel;
    wire [1:0]  ch_sel;
    wire [3:0]  load_strobe;
    wire signed [12:0] tap_pair_i_0, tap_pair_q_0;

    sd_fir_state u_fir_state (
        .clk_16m    (clk_16m),
        .rst_n      (rst_n),
        .cic_in_i   (cic_out_i),
        .cic_in_q   (cic_out_q),
        .load_strobe(load_strobe[0]),
        .tap_sel    (tap_sel),
        .tap_pair_i (tap_pair_i_0),
        .tap_pair_q (tap_pair_q_0)
    );

    // --- Shared FIR MAC (ch 1-3 tied off) ---
    wire [3:0]  out_valid_mac;
    wire signed [7:0] out_i_0_mac, out_q_0_mac;

    sd_fir_mac u_mac (
        .clk_16m      (clk_16m),
        .rst_n        (rst_n),
        .ch_valid     ({3'b000, ch_valid_0}),  // only ch 0 active
        .tap_pair_i_0 (tap_pair_i_0),
        .tap_pair_i_1 (13'sd0),
        .tap_pair_i_2 (13'sd0),
        .tap_pair_i_3 (13'sd0),
        .tap_pair_q_0 (tap_pair_q_0),
        .tap_pair_q_1 (13'sd0),
        .tap_pair_q_2 (13'sd0),
        .tap_pair_q_3 (13'sd0),
        .tap_sel      (tap_sel),
        .ch_sel       (ch_sel),
        .load_strobe  (load_strobe),
        .out_i_0      (out_i_0_mac), .out_i_1 (),  .out_i_2 (),  .out_i_3 (),
        .out_q_0      (out_q_0_mac), .out_q_1 (),  .out_q_2 (),  .out_q_3 (),
        .out_valid    (out_valid_mac)
    );

    assign iq_out_i = out_i_0_mac;
    assign iq_out_q = out_q_0_mac;
    assign iq_valid = out_valid_mac[0];

endmodule
