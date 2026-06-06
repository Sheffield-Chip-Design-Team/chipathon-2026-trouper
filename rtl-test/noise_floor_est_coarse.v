// noise_floor_est_coarse.v
// Experimental coarse noise floor estimator.
//
// Input metric:
//   noise_metric_j = sat_u10(((sum |x|^2 over one symbol) >> sf) >> 5)
//
// The block preserves the same control model as noise_floor_est.v but drops the
// wide raw-energy input and runtime sf normalization. Since the input is only
// 10 bits, the EMA accumulator shrinks from 23 bits to 17 bits.

module noise_floor_est_coarse (
    input  wire        clk_32m,
    input  wire        rst_n,

    input  wire [9:0]  noise_metric_0,
    input  wire [9:0]  noise_metric_1,
    input  wire [9:0]  noise_metric_2,
    input  wire [9:0]  noise_metric_3,

    input  wire        noise_sample_en,
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

    reg [16:0] sigma2_acc       [0:3];
    reg [15:0] sigma2_sw_active [0:3];

    assign sigma2_hw_0 = {6'd0, sigma2_acc[0][16:7]};
    assign sigma2_hw_1 = {6'd0, sigma2_acc[1][16:7]};
    assign sigma2_hw_2 = {6'd0, sigma2_acc[2][16:7]};
    assign sigma2_hw_3 = {6'd0, sigma2_acc[3][16:7]};

    assign sigma2_active_0 = sigma2_src ? sigma2_sw_active[0] : sigma2_hw_0;
    assign sigma2_active_1 = sigma2_src ? sigma2_sw_active[1] : sigma2_hw_1;
    assign sigma2_active_2 = sigma2_src ? sigma2_sw_active[2] : sigma2_hw_2;
    assign sigma2_active_3 = sigma2_src ? sigma2_sw_active[3] : sigma2_hw_3;

    reg       active;
    reg [1:0] ch;

    wire [9:0] ch_metric = (ch == 2'd0) ? noise_metric_0 :
                           (ch == 2'd1) ? noise_metric_1 :
                           (ch == 2'd2) ? noise_metric_2 :
                                          noise_metric_3;

    wire [16:0] ch_xacc = {ch_metric, 7'b0};

    wire signed [18:0] ch_diff     = $signed({2'b00, ch_xacc}) -
                                     $signed({2'b00, sigma2_acc[ch]});
    wire signed [18:0] ch_delta    = ch_diff >>> noise_alpha_shift;
    wire signed [18:0] ch_acc_next = $signed({2'b00, sigma2_acc[ch]}) + ch_delta;

    integer i;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                sigma2_acc[i]       <= 17'd0;
                sigma2_sw_active[i] <= 16'd0;
            end
            sigma2_valid <= 1'b0;
            n_updates    <= 8'd0;
            active       <= 1'b0;
            ch           <= 2'd0;
        end else begin
            if (agc_gain_changed) begin
                for (i = 0; i < 4; i = i + 1)
                    sigma2_acc[i] <= 17'd0;
                sigma2_valid <= 1'b0;
                n_updates    <= 8'd0;
                active       <= 1'b0;
            end else if (active) begin
                if (n_updates == 8'd0) begin
                    sigma2_acc[ch] <= ch_xacc;
                end else begin
                    sigma2_acc[ch] <= ch_acc_next[18] ? 17'd0 : ch_acc_next[16:0];
                end

                if (ch == 2'd3) begin
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

            if (sigma2_commit) begin
                sigma2_sw_active[0] <= sigma2_sw_0;
                sigma2_sw_active[1] <= sigma2_sw_1;
                sigma2_sw_active[2] <= sigma2_sw_2;
                sigma2_sw_active[3] <= sigma2_sw_3;
            end
        end
    end

endmodule
