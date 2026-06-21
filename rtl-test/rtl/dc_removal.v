// dc_removal.v
// First-order IIR DC blocker. 4 branches × I+Q in parallel.
//
// Algorithm: leaky integrator with α = 2^−5
//   acc[n]    = acc[n−1] + (x[n] − acc[n−1]>>5)
//   dc_est[n] = acc[n] >> 5
//   y[n]      = x[n] − dc_est[n−1]           (pre-update estimate, 1-cycle lag)
//
// Accumulator: 13-bit Q8.5 per channel (acc[12:5] = integer DC estimate).
// Time constant: τ ≈ 32 samples = 64 µs at 500 kS/s (HB decimator output).
// Preserves the same physical response as the R=128 design (τ = 16 samples
// × 4 µs/sample = 64 µs); sample_shift doubles sample rate, alpha halves.
//
// The update adds the full diff to the accumulator (no deadband).
// Max steady-state acc = 127 × 32 = 4064, fits in 13-bit signed (−4096..+4095).
// SC startup hold-off must be ≥ 128 output samples (4 × τ = 4 × 32).
//
// Removed from current design: dc_alpha_shift port (always was 8, broken for
// 8-bit inputs), dc_bypass port (always 1'b0), dc_est output ports (floating).

module dc_removal (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire signed [7:0]  raw_i0, raw_i1, raw_i2, raw_i3,
    input  wire signed [7:0]  raw_q0, raw_q1, raw_q2, raw_q3,
    input  wire        raw_valid,
    output reg  signed [7:0]  out_i0, out_i1, out_i2, out_i3,
    output reg  signed [7:0]  out_q0, out_q1, out_q2, out_q3,
    output reg         out_valid
);

    // 13-bit Q8.5 accumulators — integer DC estimate is acc[12:5]
    reg signed [12:0] acc_i [0:3];
    reg signed [12:0] acc_q [0:3];

    // diff = raw − dc_est, where dc_est = acc[12:5]
    // Both raw and dc_est are 8-bit signed; difference fits in 9-bit signed.
    wire signed [8:0] diff_i [0:3];
    wire signed [8:0] diff_q [0:3];
    assign diff_i[0] = {raw_i0[7], raw_i0} - {acc_i[0][12], acc_i[0][12:5]};
    assign diff_i[1] = {raw_i1[7], raw_i1} - {acc_i[1][12], acc_i[1][12:5]};
    assign diff_i[2] = {raw_i2[7], raw_i2} - {acc_i[2][12], acc_i[2][12:5]};
    assign diff_i[3] = {raw_i3[7], raw_i3} - {acc_i[3][12], acc_i[3][12:5]};
    assign diff_q[0] = {raw_q0[7], raw_q0} - {acc_q[0][12], acc_q[0][12:5]};
    assign diff_q[1] = {raw_q1[7], raw_q1} - {acc_q[1][12], acc_q[1][12:5]};
    assign diff_q[2] = {raw_q2[7], raw_q2} - {acc_q[2][12], acc_q[2][12:5]};
    assign diff_q[3] = {raw_q3[7], raw_q3} - {acc_q[3][12], acc_q[3][12:5]};

    // err = diff sign-extended to 13-bit (full diff, no /32 wiring)
    wire signed [12:0] err_i [0:3];
    wire signed [12:0] err_q [0:3];
    assign err_i[0] = {{4{diff_i[0][8]}}, diff_i[0]};
    assign err_i[1] = {{4{diff_i[1][8]}}, diff_i[1]};
    assign err_i[2] = {{4{diff_i[2][8]}}, diff_i[2]};
    assign err_i[3] = {{4{diff_i[3][8]}}, diff_i[3]};
    assign err_q[0] = {{4{diff_q[0][8]}}, diff_q[0]};
    assign err_q[1] = {{4{diff_q[1][8]}}, diff_q[1]};
    assign err_q[2] = {{4{diff_q[2][8]}}, diff_q[2]};
    assign err_q[3] = {{4{diff_q[3][8]}}, diff_q[3]};

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            acc_i[0] <= 13'sd0; acc_i[1] <= 13'sd0;
            acc_i[2] <= 13'sd0; acc_i[3] <= 13'sd0;
            acc_q[0] <= 13'sd0; acc_q[1] <= 13'sd0;
            acc_q[2] <= 13'sd0; acc_q[3] <= 13'sd0;
            out_i0 <= 8'sd0; out_i1 <= 8'sd0; out_i2 <= 8'sd0; out_i3 <= 8'sd0;
            out_q0 <= 8'sd0; out_q1 <= 8'sd0; out_q2 <= 8'sd0; out_q3 <= 8'sd0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= raw_valid;
            if (raw_valid) begin
                acc_i[0] <= acc_i[0] + err_i[0];
                acc_i[1] <= acc_i[1] + err_i[1];
                acc_i[2] <= acc_i[2] + err_i[2];
                acc_i[3] <= acc_i[3] + err_i[3];
                acc_q[0] <= acc_q[0] + err_q[0];
                acc_q[1] <= acc_q[1] + err_q[1];
                acc_q[2] <= acc_q[2] + err_q[2];
                acc_q[3] <= acc_q[3] + err_q[3];
                // Output uses DC estimate from previous cycle (acc before update)
                out_i0 <= raw_i0 - acc_i[0][12:5];
                out_i1 <= raw_i1 - acc_i[1][12:5];
                out_i2 <= raw_i2 - acc_i[2][12:5];
                out_i3 <= raw_i3 - acc_i[3][12:5];
                out_q0 <= raw_q0 - acc_q[0][12:5];
                out_q1 <= raw_q1 - acc_q[1][12:5];
                out_q2 <= raw_q2 - acc_q[2][12:5];
                out_q3 <= raw_q3 - acc_q[3][12:5];
            end
        end
    end

endmodule
