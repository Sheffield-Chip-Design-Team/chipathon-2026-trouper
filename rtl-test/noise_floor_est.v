// noise_floor_est.v
// Per-branch noise floor estimator using EMA of idle-window energy sums.
// Serialised: processes channels 0–3 one per cycle on each noise_sample_en.
// Single set of 25-bit arithmetic (subtract + barrel-shift + add) shared across
// all 4 channels; latency = 4 cycles per update (vs 2 cycles parallel original).
// Latency is irrelevant — noise_sample_en fires at most once per idle window (≥1s).
// GF180MCU, 3.3V, 32 MHz

module noise_floor_est (
    input  wire        clk_32m,
    input  wire        rst_n,

    input  wire [31:0] energy_sum_0,
    input  wire [31:0] energy_sum_1,
    input  wire [31:0] energy_sum_2,
    input  wire [31:0] energy_sum_3,

    input  wire        noise_sample_en,

    input  wire [3:0]  sf,
    input  wire [2:0]  noise_alpha_shift,

    input  wire [15:0] sigma2_sw_0,
    input  wire [15:0] sigma2_sw_1,
    input  wire [15:0] sigma2_sw_2,
    input  wire [15:0] sigma2_sw_3,
    input  wire        sigma2_commit,
    input  wire        sigma2_src,

    input  wire        agc_gain_changed,

    output wire [15:0] sigma2_hw_0,
    output wire [15:0] sigma2_hw_1,
    output wire [15:0] sigma2_hw_2,
    output wire [15:0] sigma2_hw_3,

    output wire [15:0] sigma2_active_0,
    output wire [15:0] sigma2_active_1,
    output wire [15:0] sigma2_active_2,
    output wire [15:0] sigma2_active_3,

    output reg         sigma2_valid,
    output reg  [7:0]  n_updates
);

    // -----------------------------------------------------------------------
    // Per-channel accumulators and SW shadow registers (4-deep arrays)
    // -----------------------------------------------------------------------
    reg [22:0] sigma2_acc        [0:3];
    reg [15:0] sigma2_sw_active  [0:3];

    // -----------------------------------------------------------------------
    // Output assignments from arrays
    // -----------------------------------------------------------------------
    assign sigma2_hw_0 = sigma2_acc[0][22:7];
    assign sigma2_hw_1 = sigma2_acc[1][22:7];
    assign sigma2_hw_2 = sigma2_acc[2][22:7];
    assign sigma2_hw_3 = sigma2_acc[3][22:7];

    assign sigma2_active_0 = sigma2_src ? sigma2_sw_active[0] : sigma2_hw_0;
    assign sigma2_active_1 = sigma2_src ? sigma2_sw_active[1] : sigma2_hw_1;
    assign sigma2_active_2 = sigma2_src ? sigma2_sw_active[2] : sigma2_hw_2;
    assign sigma2_active_3 = sigma2_src ? sigma2_sw_active[3] : sigma2_hw_3;

    // -----------------------------------------------------------------------
    // eps_from_sum: per-sample energy = window sum >> SF
    // -----------------------------------------------------------------------
    function [15:0] eps_from_sum;
        input [31:0] sum;
        input [3:0]  sf_sel;
        begin
            case (sf_sel)
                4'd6:  eps_from_sum = sum[21:6];
                4'd7:  eps_from_sum = sum[22:7];
                4'd8:  eps_from_sum = sum[23:8];
                4'd9:  eps_from_sum = sum[24:9];
                4'd10: eps_from_sum = sum[25:10];
                4'd11: eps_from_sum = sum[26:11];
                4'd12: eps_from_sum = sum[27:12];
                default: eps_from_sum = sum[22:7];
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Serialisation FSM: ch cycles 0→3 on each noise_sample_en
    // -----------------------------------------------------------------------
    reg        active;
    reg [1:0]  ch;

    // Current-channel energy sum mux (combinatorial)
    wire [31:0] ch_esum = (ch == 2'd0) ? energy_sum_0 :
                          (ch == 2'd1) ? energy_sum_1 :
                          (ch == 2'd2) ? energy_sum_2 :
                                         energy_sum_3;

    // xacc for current channel: per-sample energy scaled to 23-bit accumulator
    wire [22:0] ch_xacc = {eps_from_sum(ch_esum, sf), 7'b0};

    // EMA update arithmetic (single shared 25-bit path)
    wire signed [24:0] ch_diff     = $signed({2'b00, ch_xacc}) -
                                     $signed({2'b00, sigma2_acc[ch]});
    wire signed [24:0] ch_delta    = ch_diff >>> noise_alpha_shift;
    wire signed [24:0] ch_acc_next = $signed({2'b00, sigma2_acc[ch]}) + ch_delta;

    integer i;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                sigma2_acc[i]       <= 23'd0;
                sigma2_sw_active[i] <= 16'd0;
            end
            sigma2_valid <= 1'b0;
            n_updates    <= 8'd0;
            active       <= 1'b0;
            ch           <= 2'd0;
        end else begin

            if (agc_gain_changed) begin
                for (i = 0; i < 4; i = i + 1)
                    sigma2_acc[i] <= 23'd0;
                sigma2_valid <= 1'b0;
                n_updates    <= 8'd0;
                active       <= 1'b0;
            end else if (active) begin
                // Process current channel
                if (n_updates == 8'd0) begin
                    // Cold-start: seed accumulator directly from xacc
                    sigma2_acc[ch] <= ch_xacc;
                end else begin
                    sigma2_acc[ch] <= ch_acc_next[24] ? 23'd0 : ch_acc_next[22:0];
                end

                if (ch == 2'd3) begin
                    // All 4 channels done
                    n_updates    <= (n_updates == 8'hFF) ? 8'hFF : n_updates + 8'd1;
                    sigma2_valid <= 1'b1;
                    active       <= 1'b0;
                end else begin
                    ch <= ch + 2'd1;
                end
            end else if (noise_sample_en) begin
                active <= 1'b1;
                ch     <= 2'd0;
            end

            // SW override commit
            if (sigma2_commit) begin
                sigma2_sw_active[0] <= sigma2_sw_0;
                sigma2_sw_active[1] <= sigma2_sw_1;
                sigma2_sw_active[2] <= sigma2_sw_2;
                sigma2_sw_active[3] <= sigma2_sw_3;
            end
        end
    end

endmodule
