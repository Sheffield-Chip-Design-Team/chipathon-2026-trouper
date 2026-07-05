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

module dc_removal_chan (
    input  wire              clk_32m,
    input  wire              rst_n,
    input  wire signed [7:0] sample_in,
    input  wire              sample_valid,
    output reg  signed [7:0] sample_out
);

    // 13-bit Q8.5 accumulator; integer DC estimate is dc_est_acc[12:5]
    reg signed [12:0] dc_est_acc;

    wire signed [7:0] dc_est = dc_est_acc[12:5];
    wire signed [8:0] diff = {sample_in[7], sample_in} - {dc_est[7], dc_est};
    wire signed [12:0] dc_est_step = {{4{diff[8]}}, diff};

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            dc_est_acc <= 13'sd0;
            sample_out <= 8'sd0;
        end else if (sample_valid) begin
            dc_est_acc <= dc_est_acc + dc_est_step;
            // Output uses DC estimate from previous cycle (acc before update).
            sample_out <= sample_in - dc_est;
        end
    end

endmodule

module dc_removal (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire signed [7:0]  sample_i0, sample_i1, sample_i2, sample_i3,
    input  wire signed [7:0]  sample_q0, sample_q1, sample_q2, sample_q3,
    input  wire        sample_valid,
    output wire signed [7:0]  sample_out_i0, sample_out_i1, sample_out_i2, sample_out_i3,
    output wire signed [7:0]  sample_out_q0, sample_out_q1, sample_out_q2, sample_out_q3,
    output reg         sample_out_valid
);

    wire signed [7:0] sample_i [0:3];
    wire signed [7:0] sample_q [0:3];
    wire signed [7:0] sample_out_i [0:3];
    wire signed [7:0] sample_out_q [0:3];

    assign sample_i[0] = sample_i0;
    assign sample_i[1] = sample_i1;
    assign sample_i[2] = sample_i2;
    assign sample_i[3] = sample_i3;
    assign sample_q[0] = sample_q0;
    assign sample_q[1] = sample_q1;
    assign sample_q[2] = sample_q2;
    assign sample_q[3] = sample_q3;

    assign sample_out_i0 = sample_out_i[0];
    assign sample_out_i1 = sample_out_i[1];
    assign sample_out_i2 = sample_out_i[2];
    assign sample_out_i3 = sample_out_i[3];
    assign sample_out_q0 = sample_out_q[0];
    assign sample_out_q1 = sample_out_q[1];
    assign sample_out_q2 = sample_out_q[2];
    assign sample_out_q3 = sample_out_q[3];

    genvar ch;
    generate
        for (ch = 0; ch < 4; ch = ch + 1) begin : g_i
            dc_removal_chan u_chan (
                .clk_32m      (clk_32m),
                .rst_n        (rst_n),
                .sample_in    (sample_i[ch]),
                .sample_valid (sample_valid),
                .sample_out   (sample_out_i[ch])
            );
        end

        for (ch = 0; ch < 4; ch = ch + 1) begin : g_q
            dc_removal_chan u_chan (
                .clk_32m      (clk_32m),
                .rst_n        (rst_n),
                .sample_in    (sample_q[ch]),
                .sample_valid (sample_valid),
                .sample_out   (sample_out_q[ch])
            );
        end
    endgenerate

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            sample_out_valid <= 1'b0;
        end else begin
            sample_out_valid <= sample_valid;
        end
    end

endmodule
