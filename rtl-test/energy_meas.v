// energy_meas.v
// Per-antenna energy measurement — single shared 8×8 squarer, 9-step TDM.
//
// Pipeline per iq_valid:
//   step 0 (iq_valid): latch inputs; sq_in←i0; latch win_end
//   step 1:  sq_out_r←i0²;  sq_in←q0
//   step 2:  sq_out_r←q0²;  i_sq_r←i0²;  sq_in←i1
//   step 3:  sq_out_r←i1²;  acc_0 += i0²+q0²;  sq_in←q1
//   step 4:  sq_out_r←q1²;  i_sq_r←i1²;  sq_in←i2
//   step 5:  sq_out_r←i2²;  acc_1 += i1²+q1²;  sq_in←q2
//   step 6:  sq_out_r←q2²;  i_sq_r←i2²;  sq_in←i3
//   step 7:  sq_out_r←i3²;  acc_2 += i2²+q2²;  sq_in←q3
//   step 8:  sq_out_r←q3²;  i_sq_r←i3²
//   step 9:  acc_3 += i3²+q3²;  pulse energy_valid if win_end
//
// Budget: R=256 → 256 cycles between iq_valid; 9 cycles used.
// GF180MCU, 3.3V, 32 MHz
//
// Accumulator width reduction:
//   acc_0..3, new_acc: 32 → 28-bit. Max value at SF12 = 4096×2×127² = 132M < 2^27.
//   28-bit unsigned holds up to 268M — 1 guard bit of headroom.
//   energy_sum_0..3 output ports stay 32-bit (zero-extended); no interface change.
//   Saturation check updated: |new_acc[27:16] instead of |new_acc[31:16].

module energy_meas (
    input  wire        clk_32m,
    input  wire        rst_n,

    input  wire signed [7:0] iq_i_0, iq_i_1, iq_i_2, iq_i_3,
    input  wire signed [7:0] iq_q_0, iq_q_1, iq_q_2, iq_q_3,
    input  wire        iq_valid,

    input  wire [3:0]  sf,
    input  wire        sc_lock,

    output reg  [31:0] energy_sum_0, energy_sum_1, energy_sum_2, energy_sum_3,
    output reg  [15:0] energy_0, energy_1, energy_2, energy_3,
    output reg         energy_valid,
    output reg         energy_snapshot_valid
);

    // -----------------------------------------------------------------------
    // Window length (2^SF samples)
    // -----------------------------------------------------------------------
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

    reg [12:0] win_cnt;
    reg [27:0] acc_0, acc_1, acc_2, acc_3;  // 28-bit: max 132M < 2^27, 1 guard bit
    reg        win_end;

    // -----------------------------------------------------------------------
    // Latched inputs
    // -----------------------------------------------------------------------
    reg signed [7:0] lat_i0, lat_q0, lat_i1, lat_q1;
    reg signed [7:0] lat_i2, lat_q2, lat_i3, lat_q3;

    // -----------------------------------------------------------------------
    // Shared squarer — 1 registered 8×8 multiply
    // sq_out_r holds sq_in² from the PREVIOUS clock cycle.
    // -----------------------------------------------------------------------
    reg signed [7:0] sq_in;
    reg [15:0]       sq_out_r;
    always @(posedge clk_32m) sq_out_r <= sq_in * sq_in;

    reg [15:0] i_sq_r;   // holds i_N² while waiting one more step for q_N²

    // -----------------------------------------------------------------------
    // TDM FSM
    // -----------------------------------------------------------------------
    reg [3:0] tdm_step;

    // Blocking temp used inside case steps for new accumulator value (28-bit)
    reg [27:0] new_acc;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            win_cnt               <= 13'd0;
            win_end               <= 1'b0;
            acc_0 <= 28'd0; acc_1 <= 28'd0; acc_2 <= 28'd0; acc_3 <= 28'd0;
            energy_sum_0 <= 32'd0; energy_sum_1 <= 32'd0;
            energy_sum_2 <= 32'd0; energy_sum_3 <= 32'd0;
            energy_0 <= 16'd0; energy_1 <= 16'd0;
            energy_2 <= 16'd0; energy_3 <= 16'd0;
            energy_valid          <= 1'b0;
            energy_snapshot_valid <= 1'b0;
            tdm_step <= 4'd0;
            sq_in    <= 8'sd0;
            i_sq_r   <= 16'd0;
            lat_i0 <= 8'sd0; lat_q0 <= 8'sd0;
            lat_i1 <= 8'sd0; lat_q1 <= 8'sd0;
            lat_i2 <= 8'sd0; lat_q2 <= 8'sd0;
            lat_i3 <= 8'sd0; lat_q3 <= 8'sd0;
        end else begin
            energy_valid          <= 1'b0;
            energy_snapshot_valid <= 1'b0;

            // sc_lock snapshot: sample current acc values
            if (sc_lock) begin
                energy_0 <= (|acc_0[27:16]) ? 16'hFFFF : acc_0[15:0];
                energy_1 <= (|acc_1[27:16]) ? 16'hFFFF : acc_1[15:0];
                energy_2 <= (|acc_2[27:16]) ? 16'hFFFF : acc_2[15:0];
                energy_3 <= (|acc_3[27:16]) ? 16'hFFFF : acc_3[15:0];
                energy_snapshot_valid <= 1'b1;
            end

            case (tdm_step)
                4'd0: begin
                    if (iq_valid) begin
                        lat_i0 <= iq_i_0; lat_q0 <= iq_q_0;
                        lat_i1 <= iq_i_1; lat_q1 <= iq_q_1;
                        lat_i2 <= iq_i_2; lat_q2 <= iq_q_2;
                        lat_i3 <= iq_i_3; lat_q3 <= iq_q_3;
                        sq_in   <= iq_i_0;
                        win_end <= (win_cnt == win_max);
                        win_cnt <= (win_cnt == win_max) ? 13'd0 : win_cnt + 13'd1;
                        tdm_step <= 4'd1;
                    end
                end

                // Step 1: sq_out_r will become i0² after this posedge
                4'd1: begin
                    sq_in    <= lat_q0;
                    tdm_step <= 4'd2;
                end

                // Step 2: sq_out_r = i0²; will become q0² after this posedge
                4'd2: begin
                    i_sq_r   <= sq_out_r;  // save i0²
                    sq_in    <= lat_i1;
                    tdm_step <= 4'd3;
                end

                // Step 3: sq_out_r = q0²; update acc_0
                4'd3: begin
                    new_acc = acc_0 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_0 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_sum_0 <= {4'd0, new_acc};
                        energy_0 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                    end
                    sq_in    <= lat_q1;
                    tdm_step <= 4'd4;
                end

                // Step 4: sq_out_r = i1²
                4'd4: begin
                    i_sq_r   <= sq_out_r;  // save i1²
                    sq_in    <= lat_i2;
                    tdm_step <= 4'd5;
                end

                // Step 5: sq_out_r = q1²; update acc_1
                4'd5: begin
                    new_acc = acc_1 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_1 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_sum_1 <= {4'd0, new_acc};
                        energy_1 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                    end
                    sq_in    <= lat_q2;
                    tdm_step <= 4'd6;
                end

                // Step 6: sq_out_r = i2²
                4'd6: begin
                    i_sq_r   <= sq_out_r;  // save i2²
                    sq_in    <= lat_i3;
                    tdm_step <= 4'd7;
                end

                // Step 7: sq_out_r = q2²; update acc_2
                4'd7: begin
                    new_acc = acc_2 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_2 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_sum_2 <= {4'd0, new_acc};
                        energy_2 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                    end
                    sq_in    <= lat_q3;
                    tdm_step <= 4'd8;
                end

                // Step 8: sq_out_r = i3²
                4'd8: begin
                    i_sq_r   <= sq_out_r;  // save i3²
                    tdm_step <= 4'd9;
                end

                // Step 9: sq_out_r = q3²; update acc_3; pulse energy_valid if win_end
                4'd9: begin
                    new_acc = acc_3 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_3 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_sum_3 <= {4'd0, new_acc};
                        energy_3 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                        energy_valid <= 1'b1;
                    end
                    tdm_step <= 4'd0;
                end

                default: tdm_step <= 4'd0;
            endcase
        end
    end

endmodule
