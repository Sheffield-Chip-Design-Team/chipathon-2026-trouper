// energy_meas.v
// Per-antenna energy measurement. 16 MHz budget allows single-cycle sq accumulation.

module energy_meas (
    input  wire        clk_32m,
    input  wire        rst_n,

    input  wire signed [7:0] iq_i_0, iq_i_1, iq_i_2, iq_i_3,
    input  wire signed [7:0] iq_q_0, iq_q_1, iq_q_2, iq_q_3,
    input  wire        iq_valid,

    input  wire [3:0]  sf,
    input  wire        sc_lock,

    output reg  [31:0] energy_sum_0,
    output reg  [31:0] energy_sum_1,
    output reg  [31:0] energy_sum_2,
    output reg  [31:0] energy_sum_3,

    output reg  [15:0] energy_0,
    output reg  [15:0] energy_1,
    output reg  [15:0] energy_2,
    output reg  [15:0] energy_3,

    output reg         energy_valid,
    output reg         energy_snapshot_valid
);

    reg [12:0] win_cnt;
    reg [12:0] win_max;

    always @(*) begin
        case (sf)
            4'd7:    win_max = 13'd127;
            4'd8:    win_max = 13'd255;
            4'd9:    win_max = 13'd511;
            4'd10:   win_max = 13'd1023;
            4'd11:   win_max = 13'd2047;
            4'd12:   win_max = 13'd4095;
            default: win_max = 13'd127;
        endcase
    end

    reg [31:0] acc_0, acc_1, acc_2, acc_3;

    // 8x8 squares — combinatorial, ~4 ns
    wire [15:0] i2_0 = $signed(iq_i_0) * $signed(iq_i_0);
    wire [15:0] i2_1 = $signed(iq_i_1) * $signed(iq_i_1);
    wire [15:0] i2_2 = $signed(iq_i_2) * $signed(iq_i_2);
    wire [15:0] i2_3 = $signed(iq_i_3) * $signed(iq_i_3);
    wire [15:0] q2_0 = $signed(iq_q_0) * $signed(iq_q_0);
    wire [15:0] q2_1 = $signed(iq_q_1) * $signed(iq_q_1);
    wire [15:0] q2_2 = $signed(iq_q_2) * $signed(iq_q_2);
    wire [15:0] q2_3 = $signed(iq_q_3) * $signed(iq_q_3);

    // |x|^2 = i^2 + q^2, single cycle at 62.5 ns
    wire [16:0] sq_0 = {1'b0, i2_0} + {1'b0, q2_0};
    wire [16:0] sq_1 = {1'b0, i2_1} + {1'b0, q2_1};
    wire [16:0] sq_2 = {1'b0, i2_2} + {1'b0, q2_2};
    wire [16:0] sq_3 = {1'b0, i2_3} + {1'b0, q2_3};

    wire [31:0] acc_next_0 = acc_0 + {15'd0, sq_0};
    wire [31:0] acc_next_1 = acc_1 + {15'd0, sq_1};
    wire [31:0] acc_next_2 = acc_2 + {15'd0, sq_2};
    wire [31:0] acc_next_3 = acc_3 + {15'd0, sq_3};

    wire [15:0] acc_sat_0  = (|acc_0[31:16])      ? 16'hFFFF : acc_0[15:0];
    wire [15:0] acc_sat_1  = (|acc_1[31:16])      ? 16'hFFFF : acc_1[15:0];
    wire [15:0] acc_sat_2  = (|acc_2[31:16])      ? 16'hFFFF : acc_2[15:0];
    wire [15:0] acc_sat_3  = (|acc_3[31:16])      ? 16'hFFFF : acc_3[15:0];
    wire [15:0] next_sat_0 = (|acc_next_0[31:16]) ? 16'hFFFF : acc_next_0[15:0];
    wire [15:0] next_sat_1 = (|acc_next_1[31:16]) ? 16'hFFFF : acc_next_1[15:0];
    wire [15:0] next_sat_2 = (|acc_next_2[31:16]) ? 16'hFFFF : acc_next_2[15:0];
    wire [15:0] next_sat_3 = (|acc_next_3[31:16]) ? 16'hFFFF : acc_next_3[15:0];

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            win_cnt <= 13'd0;
            acc_0 <= 32'd0; acc_1 <= 32'd0; acc_2 <= 32'd0; acc_3 <= 32'd0;
            energy_sum_0 <= 32'd0; energy_sum_1 <= 32'd0;
            energy_sum_2 <= 32'd0; energy_sum_3 <= 32'd0;
            energy_0 <= 16'd0; energy_1 <= 16'd0;
            energy_2 <= 16'd0; energy_3 <= 16'd0;
            energy_valid <= 1'b0;
            energy_snapshot_valid <= 1'b0;
        end else begin
            energy_valid <= 1'b0;
            energy_snapshot_valid <= 1'b0;

            if (sc_lock) begin
                energy_0 <= acc_sat_0;
                energy_1 <= acc_sat_1;
                energy_2 <= acc_sat_2;
                energy_3 <= acc_sat_3;
                energy_snapshot_valid <= 1'b1;
            end

            if (iq_valid) begin
                if (win_cnt == win_max) begin
                    energy_sum_0 <= acc_next_0;
                    energy_sum_1 <= acc_next_1;
                    energy_sum_2 <= acc_next_2;
                    energy_sum_3 <= acc_next_3;
                    energy_0 <= next_sat_0;
                    energy_1 <= next_sat_1;
                    energy_2 <= next_sat_2;
                    energy_3 <= next_sat_3;
                    acc_0 <= 32'd0; acc_1 <= 32'd0;
                    acc_2 <= 32'd0; acc_3 <= 32'd0;
                    win_cnt <= 13'd0;
                    energy_valid <= 1'b1;
                end else begin
                    acc_0 <= acc_next_0; acc_1 <= acc_next_1;
                    acc_2 <= acc_next_2; acc_3 <= acc_next_3;
                    win_cnt <= win_cnt + 13'd1;
                end
            end
        end
    end

endmodule
