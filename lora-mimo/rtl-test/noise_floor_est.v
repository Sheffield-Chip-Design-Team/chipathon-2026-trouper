// noise_floor_est.v
// Per-branch noise floor estimator using EMA of idle-window energy sums.
// EMA update (on each noise_sample_en): acc += (x_acc - acc) >>> alpha_shift
// Accumulator is 23-bit; sigma2_hw = acc[22:7] (top 16 bits, UQ2.14 scale).
// Cold-start: first update seeds acc directly from per-sample energy.
// SW override path follows the same shadow/commit/source-select pattern as weight_gen.
// GF180MCU, 3.3V, 32 MHz single clock domain

module noise_floor_est (
    input  wire        clk_32m,
    input  wire        rst_n,

    // 32-bit raw energy sums from energy_meas (Σ|x|² over one symbol window)
    input  wire [31:0] energy_sum_0,
    input  wire [31:0] energy_sum_1,
    input  wire [31:0] energy_sum_2,
    input  wire [31:0] energy_sum_3,

    // Strobe from packet_ctrl_fsm: asserted only when IDLE, !sc_lock, all energy < NOISE_THRESH
    input  wire        noise_sample_en,

    input  wire [3:0]  sf,                 // SF 7..12 — right-shift to get per-sample energy
    input  wire [2:0]  noise_alpha_shift,  // EMA decay exponent (default 4 → τ ≈ 16 windows)

    // SW override path
    input  wire [15:0] sigma2_sw_0,
    input  wire [15:0] sigma2_sw_1,
    input  wire [15:0] sigma2_sw_2,
    input  wire [15:0] sigma2_sw_3,
    input  wire        sigma2_commit,  // one-cycle strobe: latch SW shadow into active regs
    input  wire        sigma2_src,     // 0 = HW EMA (default), 1 = SW override

    // AGC invalidation: any gain change makes existing EMA incomparable
    input  wire        agc_gain_changed,

    // HW EMA outputs (register readback: 0xE0–0xE7)
    output wire [15:0] sigma2_hw_0,
    output wire [15:0] sigma2_hw_1,
    output wire [15:0] sigma2_hw_2,
    output wire [15:0] sigma2_hw_3,

    // Active estimate consumed by weight_gen (combinatorial mux of HW/SW)
    output wire [15:0] sigma2_active_0,
    output wire [15:0] sigma2_active_1,
    output wire [15:0] sigma2_active_2,
    output wire [15:0] sigma2_active_3,

    output reg         sigma2_valid,  // at least one EMA window accumulated since reset
    output reg  [7:0]  n_updates      // saturating count of EMA updates (diagnostic)
);

    // -----------------------------------------------------------------------
    // 23-bit EMA accumulators (sigma2_hw = acc[22:7])
    // The extra 7 sub-bits below the 16-bit output preserve IIR precision up to
    // NOISE_ALPHA_SHIFT_MAX = 7.
    // -----------------------------------------------------------------------
    reg [22:0] sigma2_acc_0, sigma2_acc_1, sigma2_acc_2, sigma2_acc_3;

    // Latched SW shadow registers (loaded on sigma2_commit)
    reg [15:0] sigma2_sw_active_0, sigma2_sw_active_1, sigma2_sw_active_2, sigma2_sw_active_3;

    // -----------------------------------------------------------------------
    // Staged EMA update path
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

    reg [22:0] xacc_q_0, xacc_q_1, xacc_q_2, xacc_q_3;
    reg [22:0] acc_base_q_0, acc_base_q_1, acc_base_q_2, acc_base_q_3;
    reg signed [24:0] delta_q_0, delta_q_1, delta_q_2, delta_q_3;
    reg [2:0]  alpha_q;
    reg        sample_pending;
    reg        ema_pending;

    wire [22:0] xacc_next_0 = {eps_from_sum(energy_sum_0, sf), 7'b0};
    wire [22:0] xacc_next_1 = {eps_from_sum(energy_sum_1, sf), 7'b0};
    wire [22:0] xacc_next_2 = {eps_from_sum(energy_sum_2, sf), 7'b0};
    wire [22:0] xacc_next_3 = {eps_from_sum(energy_sum_3, sf), 7'b0};

    // Signed difference: sampled x_acc - sigma2_acc (25-bit signed to avoid overflow)
        wire signed [24:0] diff_0 = $signed({2'b00, xacc_q_0}) - $signed({2'b00, sigma2_acc_0});
        wire signed [24:0] diff_1 = $signed({2'b00, xacc_q_1}) - $signed({2'b00, sigma2_acc_1});
        wire signed [24:0] diff_2 = $signed({2'b00, xacc_q_2}) - $signed({2'b00, sigma2_acc_2});
        wire signed [24:0] diff_3 = $signed({2'b00, xacc_q_3}) - $signed({2'b00, sigma2_acc_3});

    wire signed [24:0] delta_0 = diff_0 >>> alpha_q;
    wire signed [24:0] delta_1 = diff_1 >>> alpha_q;
    wire signed [24:0] delta_2 = diff_2 >>> alpha_q;
    wire signed [24:0] delta_3 = diff_3 >>> alpha_q;

        wire signed [24:0] acc_next_0 = $signed({2'b00, acc_base_q_0}) + delta_q_0;
        wire signed [24:0] acc_next_1 = $signed({2'b00, acc_base_q_1}) + delta_q_1;
        wire signed [24:0] acc_next_2 = $signed({2'b00, acc_base_q_2}) + delta_q_2;
        wire signed [24:0] acc_next_3 = $signed({2'b00, acc_base_q_3}) + delta_q_3;

    // -----------------------------------------------------------------------
    // Output assignments
    // -----------------------------------------------------------------------

    // HW sigma2: top 16 bits of 23-bit accumulator
    assign sigma2_hw_0 = sigma2_acc_0[22:7];
    assign sigma2_hw_1 = sigma2_acc_1[22:7];
    assign sigma2_hw_2 = sigma2_acc_2[22:7];
    assign sigma2_hw_3 = sigma2_acc_3[22:7];

    // Active sigma2: combinatorial mux — no register; immediate on src-select change
    assign sigma2_active_0 = sigma2_src ? sigma2_sw_active_0 : sigma2_hw_0;
    assign sigma2_active_1 = sigma2_src ? sigma2_sw_active_1 : sigma2_hw_1;
    assign sigma2_active_2 = sigma2_src ? sigma2_sw_active_2 : sigma2_hw_2;
    assign sigma2_active_3 = sigma2_src ? sigma2_sw_active_3 : sigma2_hw_3;

    // -----------------------------------------------------------------------
    // Sequential state
    // -----------------------------------------------------------------------
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            sigma2_acc_0       <= 23'd0;
            sigma2_acc_1       <= 23'd0;
            sigma2_acc_2       <= 23'd0;
            sigma2_acc_3       <= 23'd0;
            sigma2_sw_active_0 <= 16'd0;
            sigma2_sw_active_1 <= 16'd0;
            sigma2_sw_active_2 <= 16'd0;
            sigma2_sw_active_3 <= 16'd0;
            sigma2_valid       <= 1'b0;
            n_updates          <= 8'd0;
            xacc_q_0          <= 23'd0;
            xacc_q_1          <= 23'd0;
            xacc_q_2          <= 23'd0;
            xacc_q_3          <= 23'd0;
            acc_base_q_0      <= 23'd0;
            acc_base_q_1      <= 23'd0;
            acc_base_q_2      <= 23'd0;
            acc_base_q_3      <= 23'd0;
            delta_q_0         <= 25'sd0;
            delta_q_1         <= 25'sd0;
            delta_q_2         <= 25'sd0;
            delta_q_3         <= 25'sd0;
            alpha_q           <= 3'd0;
            sample_pending    <= 1'b0;
            ema_pending       <= 1'b0;
        end else begin
            // AGC gain change: invalidate all HW estimates; re-converge after next
            // NOISE_ALPHA_SHIFT window periods
            if (agc_gain_changed) begin
                sigma2_acc_0  <= 23'd0;
                sigma2_acc_1  <= 23'd0;
                sigma2_acc_2  <= 23'd0;
                sigma2_acc_3  <= 23'd0;
                sigma2_valid  <= 1'b0;
                n_updates     <= 8'd0;
                sample_pending <= 1'b0;
                ema_pending    <= 1'b0;
            end else begin
                if (noise_sample_en) begin
                    xacc_q_0 <= xacc_next_0;
                    xacc_q_1 <= xacc_next_1;
                    xacc_q_2 <= xacc_next_2;
                    xacc_q_3 <= xacc_next_3;
                    alpha_q  <= noise_alpha_shift;
                    sample_pending <= 1'b1;
                end else begin
                    sample_pending <= 1'b0;
                end

                if (sample_pending) begin
                    if (n_updates == 8'd0) begin
                        sigma2_acc_0 <= xacc_q_0;
                        sigma2_acc_1 <= xacc_q_1;
                        sigma2_acc_2 <= xacc_q_2;
                        sigma2_acc_3 <= xacc_q_3;
                        sigma2_valid <= 1'b1;
                        n_updates <= (n_updates == 8'hFF) ? 8'hFF : n_updates + 8'd1;
                    end else begin
                        acc_base_q_0 <= sigma2_acc_0;
                        acc_base_q_1 <= sigma2_acc_1;
                        acc_base_q_2 <= sigma2_acc_2;
                        acc_base_q_3 <= sigma2_acc_3;
                        delta_q_0 <= delta_0;
                        delta_q_1 <= delta_1;
                        delta_q_2 <= delta_2;
                        delta_q_3 <= delta_3;
                        ema_pending <= 1'b1;
                    end
                end

                if (ema_pending) begin
                    sigma2_acc_0 <= acc_next_0[24] ? 23'd0 : acc_next_0[22:0];
                    sigma2_acc_1 <= acc_next_1[24] ? 23'd0 : acc_next_1[22:0];
                    sigma2_acc_2 <= acc_next_2[24] ? 23'd0 : acc_next_2[22:0];
                    sigma2_acc_3 <= acc_next_3[24] ? 23'd0 : acc_next_3[22:0];
                    n_updates <= (n_updates == 8'hFF) ? 8'hFF : n_updates + 8'd1;
                    ema_pending <= 1'b0;
                end
            end

            // SW override commit: latch firmware shadow values into active registers
            if (sigma2_commit) begin
                sigma2_sw_active_0 <= sigma2_sw_0;
                sigma2_sw_active_1 <= sigma2_sw_1;
                sigma2_sw_active_2 <= sigma2_sw_2;
                sigma2_sw_active_3 <= sigma2_sw_3;
            end
        end
    end

endmodule
