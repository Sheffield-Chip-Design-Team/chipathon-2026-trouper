// dc_removal.v
// First-order IIR DC blocker. 4 branches × I+Q in parallel.
//
// Algorithm: leaky integrator with α = 2^−4
//   acc[n]    = acc[n−1] + (x[n] − acc[n−1]>>4)
//   dc_est[n] = acc[n] >> 4
//   y[n]      = x[n] − dc_est[n−1]           (pre-update estimate, 1-cycle lag)
//
// Accumulator: 12-bit Q8.4 per channel (acc[11:4] = integer DC estimate).
// Time constant: τ ≈ 16 samples = 64 µs at 250 kS/s (CIC R=128).
//
// The update adds the full diff (not diff>>4) to the accumulator.
// This eliminates the ±15 LSB positive-DC deadband that floor(diff/16) caused:
//   Old: err = diff>>4 → 0 for 0 < diff < 16 → stalls on small +ve DC
//   New: err = diff    → always non-zero for diff ≠ 0 → symmetric convergence
// Time constant is unchanged; only the transient response improves.
// Max steady-state acc = 127 × 16 = 2032, fits in 12-bit signed (±2047).
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

    // 12-bit Q8.4 accumulators — integer DC estimate is acc[11:4]
    reg signed [11:0] acc_i [0:3];
    reg signed [11:0] acc_q [0:3];

    // err = (raw − dc_est) >> 4, where dc_est = acc[11:4]
    // Both raw and dc_est are 8-bit signed; difference fits in 9 bits,
    // >> 4 → 5-bit signed, sign-extended to 12-bit for the accumulator update.
    wire signed [8:0] diff_i [0:3];
    wire signed [8:0] diff_q [0:3];
    assign diff_i[0] = {raw_i0[7], raw_i0} - {acc_i[0][11], acc_i[0][11:4]};
    assign diff_i[1] = {raw_i1[7], raw_i1} - {acc_i[1][11], acc_i[1][11:4]};
    assign diff_i[2] = {raw_i2[7], raw_i2} - {acc_i[2][11], acc_i[2][11:4]};
    assign diff_i[3] = {raw_i3[7], raw_i3} - {acc_i[3][11], acc_i[3][11:4]};
    assign diff_q[0] = {raw_q0[7], raw_q0} - {acc_q[0][11], acc_q[0][11:4]};
    assign diff_q[1] = {raw_q1[7], raw_q1} - {acc_q[1][11], acc_q[1][11:4]};
    assign diff_q[2] = {raw_q2[7], raw_q2} - {acc_q[2][11], acc_q[2][11:4]};
    assign diff_q[3] = {raw_q3[7], raw_q3} - {acc_q[3][11], acc_q[3][11:4]};

    // err = diff sign-extended to 12-bit (full diff, no /16 wiring)
    wire signed [11:0] err_i [0:3];
    wire signed [11:0] err_q [0:3];
    assign err_i[0] = {{3{diff_i[0][8]}}, diff_i[0]};
    assign err_i[1] = {{3{diff_i[1][8]}}, diff_i[1]};
    assign err_i[2] = {{3{diff_i[2][8]}}, diff_i[2]};
    assign err_i[3] = {{3{diff_i[3][8]}}, diff_i[3]};
    assign err_q[0] = {{3{diff_q[0][8]}}, diff_q[0]};
    assign err_q[1] = {{3{diff_q[1][8]}}, diff_q[1]};
    assign err_q[2] = {{3{diff_q[2][8]}}, diff_q[2]};
    assign err_q[3] = {{3{diff_q[3][8]}}, diff_q[3]};

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            acc_i[0] <= 12'sd0; acc_i[1] <= 12'sd0;
            acc_i[2] <= 12'sd0; acc_i[3] <= 12'sd0;
            acc_q[0] <= 12'sd0; acc_q[1] <= 12'sd0;
            acc_q[2] <= 12'sd0; acc_q[3] <= 12'sd0;
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
                out_i0 <= raw_i0 - acc_i[0][11:4];
                out_i1 <= raw_i1 - acc_i[1][11:4];
                out_i2 <= raw_i2 - acc_i[2][11:4];
                out_i3 <= raw_i3 - acc_i[3][11:4];
                out_q0 <= raw_q0 - acc_q[0][11:4];
                out_q1 <= raw_q1 - acc_q[1][11:4];
                out_q2 <= raw_q2 - acc_q[2][11:4];
                out_q3 <= raw_q3 - acc_q[3][11:4];
            end
        end
    end

endmodule
