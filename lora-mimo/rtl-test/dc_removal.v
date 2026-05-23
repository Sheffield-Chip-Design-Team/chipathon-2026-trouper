// dc_removal.v
// First-order IIR DC removal. 16 MHz budget allows single-cycle update.

module dc_removal (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire signed [7:0]  raw_i0, raw_i1, raw_i2, raw_i3,
    input  wire signed [7:0]  raw_q0, raw_q1, raw_q2, raw_q3,
    input  wire        raw_valid,
    input  wire [3:0]  dc_alpha_shift,
    input  wire        dc_bypass,
    output reg  signed [7:0]  out_i0, out_i1, out_i2, out_i3,
    output reg  signed [7:0]  out_q0, out_q1, out_q2, out_q3,
    output reg         out_valid,
    output wire signed [15:0] dc_est_i0, dc_est_i1, dc_est_i2, dc_est_i3,
    output wire signed [15:0] dc_est_q0, dc_est_q1, dc_est_q2, dc_est_q3
);

    reg signed [15:0] acc_i0, acc_i1, acc_i2, acc_i3;
    reg signed [15:0] acc_q0, acc_q1, acc_q2, acc_q3;

    assign dc_est_i0 = acc_i0;
    assign dc_est_i1 = acc_i1;
    assign dc_est_i2 = acc_i2;
    assign dc_est_i3 = acc_i3;
    assign dc_est_q0 = acc_q0;
    assign dc_est_q1 = acc_q1;
    assign dc_est_q2 = acc_q2;
    assign dc_est_q3 = acc_q3;

    // err = (raw - acc[15:8]) >>> alpha_shift  (single-cycle at 62.5 ns)
    wire signed [15:0] err_i0_w = $signed({{8{raw_i0[7]}}, raw_i0} - {{8{acc_i0[15]}}, acc_i0[15:8]}) >>> dc_alpha_shift;
    wire signed [15:0] err_i1_w = $signed({{8{raw_i1[7]}}, raw_i1} - {{8{acc_i1[15]}}, acc_i1[15:8]}) >>> dc_alpha_shift;
    wire signed [15:0] err_i2_w = $signed({{8{raw_i2[7]}}, raw_i2} - {{8{acc_i2[15]}}, acc_i2[15:8]}) >>> dc_alpha_shift;
    wire signed [15:0] err_i3_w = $signed({{8{raw_i3[7]}}, raw_i3} - {{8{acc_i3[15]}}, acc_i3[15:8]}) >>> dc_alpha_shift;
    wire signed [15:0] err_q0_w = $signed({{8{raw_q0[7]}}, raw_q0} - {{8{acc_q0[15]}}, acc_q0[15:8]}) >>> dc_alpha_shift;
    wire signed [15:0] err_q1_w = $signed({{8{raw_q1[7]}}, raw_q1} - {{8{acc_q1[15]}}, acc_q1[15:8]}) >>> dc_alpha_shift;
    wire signed [15:0] err_q2_w = $signed({{8{raw_q2[7]}}, raw_q2} - {{8{acc_q2[15]}}, acc_q2[15:8]}) >>> dc_alpha_shift;
    wire signed [15:0] err_q3_w = $signed({{8{raw_q3[7]}}, raw_q3} - {{8{acc_q3[15]}}, acc_q3[15:8]}) >>> dc_alpha_shift;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            acc_i0 <= 16'sd0; acc_i1 <= 16'sd0; acc_i2 <= 16'sd0; acc_i3 <= 16'sd0;
            acc_q0 <= 16'sd0; acc_q1 <= 16'sd0; acc_q2 <= 16'sd0; acc_q3 <= 16'sd0;
            out_i0 <= 8'sd0; out_i1 <= 8'sd0; out_i2 <= 8'sd0; out_i3 <= 8'sd0;
            out_q0 <= 8'sd0; out_q1 <= 8'sd0; out_q2 <= 8'sd0; out_q3 <= 8'sd0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= raw_valid;
            if (raw_valid) begin
                acc_i0 <= acc_i0 + err_i0_w; acc_i1 <= acc_i1 + err_i1_w;
                acc_i2 <= acc_i2 + err_i2_w; acc_i3 <= acc_i3 + err_i3_w;
                acc_q0 <= acc_q0 + err_q0_w; acc_q1 <= acc_q1 + err_q1_w;
                acc_q2 <= acc_q2 + err_q2_w; acc_q3 <= acc_q3 + err_q3_w;

                if (dc_bypass) begin
                    out_i0 <= raw_i0; out_i1 <= raw_i1; out_i2 <= raw_i2; out_i3 <= raw_i3;
                    out_q0 <= raw_q0; out_q1 <= raw_q1; out_q2 <= raw_q2; out_q3 <= raw_q3;
                end else begin
                    out_i0 <= raw_i0 - acc_i0[15:8]; out_i1 <= raw_i1 - acc_i1[15:8];
                    out_i2 <= raw_i2 - acc_i2[15:8]; out_i3 <= raw_i3 - acc_i3[15:8];
                    out_q0 <= raw_q0 - acc_q0[15:8]; out_q1 <= raw_q1 - acc_q1[15:8];
                    out_q2 <= raw_q2 - acc_q2[15:8]; out_q3 <= raw_q3 - acc_q3[15:8];
                end
            end
        end
    end
endmodule
