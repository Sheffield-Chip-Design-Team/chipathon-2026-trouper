// sd_remod.v
// 3rd-order feed-forward sigma-delta re-modulator
// Converts int8 baseband I+Q at sample rate to 1-bit 32 MS/s bitstreams
// GF180MCU, 3.3V, 32 MHz single clock domain

module sd_remod (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire signed [7:0] in_i,
    input  wire signed [7:0] in_q,
    input  wire        in_valid,
    input  wire        en,
    output reg         out_i,
    output reg         out_q
);

    // 12-bit signed saturating adder
    function signed [11:0] sat12;
        input signed [12:0] v;
        begin
            if      (v > 13'sd2047)  sat12 = 12'sd2047;
            else if (v < -13'sd2048) sat12 = -12'sd2048;
            else                      sat12 = v[11:0];
        end
    endfunction

    // Integrator state (12-bit signed saturating)
    reg signed [11:0] acc1_i, acc2_i, acc3_i;
    reg signed [11:0] acc1_q, acc2_q, acc3_q;

    // Latched input (hold between in_valid strobes)
    reg signed [7:0] in_i_lat, in_q_lat;

    // Previous integrator values for feed-forward
    reg signed [11:0] acc1_i_prev, acc2_i_prev;
    reg signed [11:0] acc1_q_prev, acc2_q_prev;

    // Registered feedback error. Nonblocking updates used the previous output
    // value for feedback; these flops preserve that timing while avoiding
    // high fanout from the output pins back into the accumulator adders.
    reg signed [7:0] err_i_r, err_q_r;

    // Quantizer input: feed-forward sum
    // v = acc1 + acc2 + acc3 + (in << 3)  (scale int8 to 12-bit range: *8)
    wire signed [13:0] v_i = {{2{acc1_i[11]}}, acc1_i}
                            + {{2{acc2_i[11]}}, acc2_i}
                            + {{2{acc3_i[11]}}, acc3_i}
                            + {{3{in_i_lat[7]}}, in_i_lat, 3'b000};

    wire signed [13:0] v_q = {{2{acc1_q[11]}}, acc1_q}
                            + {{2{acc2_q[11]}}, acc2_q}
                            + {{2{acc3_q[11]}}, acc3_q}
                            + {{3{in_q_lat[7]}}, in_q_lat, 3'b000};

    // Comparator: MSB of sum (sign bit) determines output bit
    wire q_i = !v_i[13]; // positive sum -> output 1
    wire q_q = !v_q[13];

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            acc1_i <= 12'sd0; acc2_i <= 12'sd0; acc3_i <= 12'sd0;
            acc1_q <= 12'sd0; acc2_q <= 12'sd0; acc3_q <= 12'sd0;
            acc1_i_prev <= 12'sd0; acc2_i_prev <= 12'sd0;
            acc1_q_prev <= 12'sd0; acc2_q_prev <= 12'sd0;
            in_i_lat <= 8'sd0; in_q_lat <= 8'sd0;
            err_i_r <= -8'sd127; err_q_r <= -8'sd127;
            out_i <= 1'b0; out_q <= 1'b0;
        end else begin
            // Latch input sample on in_valid strobe
            if (in_valid) begin
                in_i_lat <= in_i;
                in_q_lat <= in_q;
            end

            // Save previous integrator outputs for acc2/acc3 update
            acc1_i_prev <= acc1_i;
            acc1_q_prev <= acc1_q;
            acc2_i_prev <= acc2_i;
            acc2_q_prev <= acc2_q;

            // Update integrators
            // acc1 = sat(acc1 + in_latched - err)
            acc1_i <= sat12($signed({acc1_i[11], acc1_i}) + {{4{in_i_lat[7]}}, in_i_lat} - {{4{err_i_r[7]}}, err_i_r});
            acc1_q <= sat12($signed({acc1_q[11], acc1_q}) + {{4{in_q_lat[7]}}, in_q_lat} - {{4{err_q_r[7]}}, err_q_r});

            // acc2 = sat(acc2 + acc1_prev)
            acc2_i <= sat12($signed({acc2_i[11], acc2_i}) + $signed({acc1_i_prev[11], acc1_i_prev}));
            acc2_q <= sat12($signed({acc2_q[11], acc2_q}) + $signed({acc1_q_prev[11], acc1_q_prev}));

            // acc3 = sat(acc3 + acc2_prev)
            acc3_i <= sat12($signed({acc3_i[11], acc3_i}) + $signed({acc2_i_prev[11], acc2_i_prev}));
            acc3_q <= sat12($signed({acc3_q[11], acc3_q}) + $signed({acc2_q_prev[11], acc2_q_prev}));

            // Output: comparator result or forced low if !en
            out_i <= en ? q_i : 1'b0;
            out_q <= en ? q_q : 1'b0;
            err_i_r <= en ? (q_i ? 8'sd127 : -8'sd127) : -8'sd127;
            err_q_r <= en ? (q_q ? 8'sd127 : -8'sd127) : -8'sd127;
        end
    end

endmodule
