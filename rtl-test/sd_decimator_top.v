// sd_decimator_top.v
// TDM decimator: 4× sd_cic_chan + 4× sd_fir_state + 1× sd_fir_mac.
// Drop-in replacement for the 4× sd_decimator_combchain generate-for loop
// in mimo_rx_top.v.
//
// Output alignment: the shared MAC processes channels 0→1→2→3 sequentially.
// iq_valid fires once all 4 channels have completed (ch 3 done, ~28 clk_16m
// cycles after the strobe), at which point all 4 iq_out_* ports are stable.
// This keeps the iq_valid semantics identical to the monolithic design.
//
// GF180MCU 3.3V

`timescale 1ns/100ps

module sd_decimator_top (
    input  wire        clk_32m,
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire [3:0]  iq_in_i,
    input  wire [3:0]  iq_in_q,
    input  wire [1:0]  decim_ratio,
    output wire signed [7:0] iq_out_i_0,
    output wire signed [7:0] iq_out_i_1,
    output wire signed [7:0] iq_out_i_2,
    output wire signed [7:0] iq_out_i_3,
    output wire signed [7:0] iq_out_q_0,
    output wire signed [7:0] iq_out_q_1,
    output wire signed [7:0] iq_out_q_2,
    output wire signed [7:0] iq_out_q_3,
    output reg         iq_valid         // common strobe: all 4 channels ready
);

    // -----------------------------------------------------------------------
    // 4× CIC channels (32 MHz)
    // -----------------------------------------------------------------------
    wire signed [11:0] cic_out_i_0, cic_out_i_1, cic_out_i_2, cic_out_i_3;
    wire signed [11:0] cic_out_q_0, cic_out_q_1, cic_out_q_2, cic_out_q_3;
    wire cic_valid_32m_0, cic_valid_32m_1, cic_valid_32m_2, cic_valid_32m_3;

    sd_cic_chan u_cic_0 (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i[0]),.iq_in_q(iq_in_q[0]),.decim_ratio(decim_ratio),.cic_out_i(cic_out_i_0),.cic_out_q(cic_out_q_0),.cic_valid(cic_valid_32m_0));
    sd_cic_chan u_cic_1 (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i[1]),.iq_in_q(iq_in_q[1]),.decim_ratio(decim_ratio),.cic_out_i(cic_out_i_1),.cic_out_q(cic_out_q_1),.cic_valid(cic_valid_32m_1));
    sd_cic_chan u_cic_2 (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i[2]),.iq_in_q(iq_in_q[2]),.decim_ratio(decim_ratio),.cic_out_i(cic_out_i_2),.cic_out_q(cic_out_q_2),.cic_valid(cic_valid_32m_2));
    sd_cic_chan u_cic_3 (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i[3]),.iq_in_q(iq_in_q[3]),.decim_ratio(decim_ratio),.cic_out_i(cic_out_i_3),.cic_out_q(cic_out_q_3),.cic_valid(cic_valid_32m_3));

    // -----------------------------------------------------------------------
    // CDC: extend each 1-cycle 32 MHz CIC pulse to guarantee ≥1 16 MHz edge
    // -----------------------------------------------------------------------
    reg strobe_r_0, strobe_r_1, strobe_r_2, strobe_r_3;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            strobe_r_0 <= 1'b0; strobe_r_1 <= 1'b0;
            strobe_r_2 <= 1'b0; strobe_r_3 <= 1'b0;
        end else begin
            strobe_r_0 <= cic_valid_32m_0; strobe_r_1 <= cic_valid_32m_1;
            strobe_r_2 <= cic_valid_32m_2; strobe_r_3 <= cic_valid_32m_3;
        end
    end
    wire ch_valid_0 = cic_valid_32m_0 | strobe_r_0;
    wire ch_valid_1 = cic_valid_32m_1 | strobe_r_1;
    wire ch_valid_2 = cic_valid_32m_2 | strobe_r_2;
    wire ch_valid_3 = cic_valid_32m_3 | strobe_r_3;

    // -----------------------------------------------------------------------
    // Shared MAC control wires
    // -----------------------------------------------------------------------
    wire [2:0]  tap_sel;
    wire [1:0]  ch_sel;
    wire [3:0]  load_strobe;
    wire [3:0]  out_valid_mac;

    // -----------------------------------------------------------------------
    // 4× FIR state (16 MHz, per-channel delay lines)
    // -----------------------------------------------------------------------
    wire signed [12:0] tap_pair_i_0, tap_pair_i_1, tap_pair_i_2, tap_pair_i_3;
    wire signed [12:0] tap_pair_q_0, tap_pair_q_1, tap_pair_q_2, tap_pair_q_3;

    sd_fir_state u_fir_s0 (.clk_16m(clk_16m),.rst_n(rst_n),.cic_in_i(cic_out_i_0),.cic_in_q(cic_out_q_0),.load_strobe(load_strobe[0]),.tap_sel(tap_sel),.tap_pair_i(tap_pair_i_0),.tap_pair_q(tap_pair_q_0));
    sd_fir_state u_fir_s1 (.clk_16m(clk_16m),.rst_n(rst_n),.cic_in_i(cic_out_i_1),.cic_in_q(cic_out_q_1),.load_strobe(load_strobe[1]),.tap_sel(tap_sel),.tap_pair_i(tap_pair_i_1),.tap_pair_q(tap_pair_q_1));
    sd_fir_state u_fir_s2 (.clk_16m(clk_16m),.rst_n(rst_n),.cic_in_i(cic_out_i_2),.cic_in_q(cic_out_q_2),.load_strobe(load_strobe[2]),.tap_sel(tap_sel),.tap_pair_i(tap_pair_i_2),.tap_pair_q(tap_pair_q_2));
    sd_fir_state u_fir_s3 (.clk_16m(clk_16m),.rst_n(rst_n),.cic_in_i(cic_out_i_3),.cic_in_q(cic_out_q_3),.load_strobe(load_strobe[3]),.tap_sel(tap_sel),.tap_pair_i(tap_pair_i_3),.tap_pair_q(tap_pair_q_3));

    // -----------------------------------------------------------------------
    // 1× shared FIR MAC
    // -----------------------------------------------------------------------
    wire signed [7:0] mac_out_i_0, mac_out_i_1, mac_out_i_2, mac_out_i_3;
    wire signed [7:0] mac_out_q_0, mac_out_q_1, mac_out_q_2, mac_out_q_3;

    sd_fir_mac u_mac (
        .clk_16m      (clk_16m),
        .rst_n        (rst_n),
        .ch_valid     ({ch_valid_3, ch_valid_2, ch_valid_1, ch_valid_0}),
        .tap_pair_i_0 (tap_pair_i_0), .tap_pair_i_1 (tap_pair_i_1),
        .tap_pair_i_2 (tap_pair_i_2), .tap_pair_i_3 (tap_pair_i_3),
        .tap_pair_q_0 (tap_pair_q_0), .tap_pair_q_1 (tap_pair_q_1),
        .tap_pair_q_2 (tap_pair_q_2), .tap_pair_q_3 (tap_pair_q_3),
        .tap_sel      (tap_sel),
        .ch_sel       (ch_sel),
        .load_strobe  (load_strobe),
        .out_i_0      (mac_out_i_0), .out_i_1 (mac_out_i_1),
        .out_i_2      (mac_out_i_2), .out_i_3 (mac_out_i_3),
        .out_q_0      (mac_out_q_0), .out_q_1 (mac_out_q_1),
        .out_q_2      (mac_out_q_2), .out_q_3 (mac_out_q_3),
        .out_valid    (out_valid_mac)
    );

    assign iq_out_i_0 = mac_out_i_0; assign iq_out_i_1 = mac_out_i_1;
    assign iq_out_i_2 = mac_out_i_2; assign iq_out_i_3 = mac_out_i_3;
    assign iq_out_q_0 = mac_out_q_0; assign iq_out_q_1 = mac_out_q_1;
    assign iq_out_q_2 = mac_out_q_2; assign iq_out_q_3 = mac_out_q_3;

    // -----------------------------------------------------------------------
    // Output alignment: fire iq_valid once all 4 channels have completed.
    // Channels complete in order 0→1→2→3 within ~28 clk_16m cycles.
    // The MAC output registers hold their values until overwritten, so all
    // 4 iq_out_* ports are stable when iq_valid fires.
    // -----------------------------------------------------------------------
    reg [3:0] ch_done;

    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n) begin
            ch_done  <= 4'd0;
            iq_valid <= 1'b0;
        end else begin
            iq_valid <= 1'b0;
            if (|out_valid_mac) begin
                if ((ch_done | out_valid_mac) == 4'b1111) begin
                    iq_valid <= 1'b1;
                    ch_done  <= 4'd0;
                end else begin
                    ch_done <= ch_done | out_valid_mac;
                end
            end
        end
    end

endmodule
