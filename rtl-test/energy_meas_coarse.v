// energy_meas_coarse.v
// Experimental energy measurement path:
// - preserves 16-bit AGC/status snapshots
// - emits a 10-bit normalized coarse noise metric for software NW-MRC support
//
// Coarse metric:
//   eps_full      = (sum |x|^2 over one symbol) >> sf
//   noise_metric  = sat_u10(eps_full >> 5)
//
// This keeps the current shared 8x8 TDM squarer structure but drops the need
// for a wide raw-energy interface on the noise-estimation path.

module energy_meas_coarse (
    input  wire        clk_32m,
    input  wire        rst_n,

    input  wire signed [7:0] iq_i_0, iq_i_1, iq_i_2, iq_i_3,
    input  wire signed [7:0] iq_q_0, iq_q_1, iq_q_2, iq_q_3,
    input  wire        iq_valid,

    input  wire [3:0]  sf,
    input  wire        sc_lock,

    output reg  [15:0] energy_0, energy_1, energy_2, energy_3,
    output reg  [9:0]  noise_metric_0, noise_metric_1, noise_metric_2, noise_metric_3,
    output reg         energy_valid,
    output reg         energy_snapshot_valid,
    output reg         noise_metric_valid
);

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

    function [9:0] coarse_metric_from_acc;
        input [27:0] acc;
        input [3:0]  sf_sel;
        reg   [15:0] eps_shifted;
        begin
            case (sf_sel)
                4'd7:    eps_shifted = acc[27:12];
                4'd8:    eps_shifted = acc[27:13];
                4'd9:    eps_shifted = acc[27:14];
                4'd10:   eps_shifted = acc[27:15];
                4'd11:   eps_shifted = acc[27:16];
                4'd12:   eps_shifted = acc[27:17];
                default: eps_shifted = acc[27:12];
            endcase

            if (|eps_shifted[15:10]) begin
                coarse_metric_from_acc = 10'h3FF;
            end else begin
                coarse_metric_from_acc = eps_shifted[9:0];
            end
        end
    endfunction

    reg [12:0] win_cnt;
    reg [27:0] acc_0, acc_1, acc_2, acc_3;
    reg        win_end;

    reg signed [7:0] lat_i0, lat_q0, lat_i1, lat_q1;
    reg signed [7:0] lat_i2, lat_q2, lat_i3, lat_q3;

    reg signed [7:0] sq_in;
    reg [15:0]       sq_out_r;
    always @(posedge clk_32m) sq_out_r <= sq_in * sq_in;

    reg [15:0] i_sq_r;
    reg [3:0]  tdm_step;
    reg [27:0] new_acc;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            win_cnt               <= 13'd0;
            win_end               <= 1'b0;
            acc_0 <= 28'd0; acc_1 <= 28'd0; acc_2 <= 28'd0; acc_3 <= 28'd0;
            energy_0 <= 16'd0; energy_1 <= 16'd0; energy_2 <= 16'd0; energy_3 <= 16'd0;
            noise_metric_0 <= 10'd0; noise_metric_1 <= 10'd0;
            noise_metric_2 <= 10'd0; noise_metric_3 <= 10'd0;
            energy_valid          <= 1'b0;
            energy_snapshot_valid <= 1'b0;
            noise_metric_valid    <= 1'b0;
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
            noise_metric_valid    <= 1'b0;

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

                4'd1: begin
                    sq_in    <= lat_q0;
                    tdm_step <= 4'd2;
                end

                4'd2: begin
                    i_sq_r   <= sq_out_r;
                    sq_in    <= lat_i1;
                    tdm_step <= 4'd3;
                end

                4'd3: begin
                    new_acc = acc_0 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_0 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_0 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                        noise_metric_0 <= coarse_metric_from_acc(new_acc, sf);
                    end
                    sq_in    <= lat_q1;
                    tdm_step <= 4'd4;
                end

                4'd4: begin
                    i_sq_r   <= sq_out_r;
                    sq_in    <= lat_i2;
                    tdm_step <= 4'd5;
                end

                4'd5: begin
                    new_acc = acc_1 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_1 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_1 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                        noise_metric_1 <= coarse_metric_from_acc(new_acc, sf);
                    end
                    sq_in    <= lat_q2;
                    tdm_step <= 4'd6;
                end

                4'd6: begin
                    i_sq_r   <= sq_out_r;
                    sq_in    <= lat_i3;
                    tdm_step <= 4'd7;
                end

                4'd7: begin
                    new_acc = acc_2 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_2 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_2 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                        noise_metric_2 <= coarse_metric_from_acc(new_acc, sf);
                    end
                    sq_in    <= lat_q3;
                    tdm_step <= 4'd8;
                end

                4'd8: begin
                    i_sq_r   <= sq_out_r;
                    tdm_step <= 4'd9;
                end

                4'd9: begin
                    new_acc = acc_3 + {12'd0, i_sq_r} + {12'd0, sq_out_r};
                    acc_3 <= win_end ? 28'd0 : new_acc;
                    if (win_end) begin
                        energy_3 <= (|new_acc[27:16]) ? 16'hFFFF : new_acc[15:0];
                        noise_metric_3 <= coarse_metric_from_acc(new_acc, sf);
                        energy_valid       <= 1'b1;
                        noise_metric_valid <= 1'b1;
                    end
                    tdm_step <= 4'd0;
                end

                default: tdm_step <= 4'd0;
            endcase
        end
    end

endmodule
