// training_acc.v
// Training accumulator: cross-correlates each branch against a reference branch
// over 8 LoRa symbols after preamble detection.
// TDM: 4 shared 8x8 multipliers process antennas 0-3 sequentially (1 per cycle),
// then E_ref on cycle 5. Total compute latency: 3 cycles per iq_valid sample.
// At 16 MHz (62.5 ns) an 8x8 signed multiply (~3 ns) fits in one registered cycle.
// GF180MCU, 3.3V, 16 MHz clock domain

module signed_mul8_pipe (
    input  wire              clk,
    input  wire signed [7:0] a,
    input  wire signed [7:0] b,
    output reg  signed [15:0] p
);
    always @(posedge clk) p <= a * b;
endmodule

module training_acc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] raw_i0, raw_i1, raw_i2, raw_i3,
    input  wire signed [7:0] raw_q0, raw_q1, raw_q2, raw_q3,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire [3:0]  sf,
    input  wire [1:0]  ref_sel,
    input  wire        noise_en,       // 1 = noise-window mode: arm on idle, ref=ant0, fire noise_ready
    output reg  signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    output reg  signed [63:0] E_ref,
    output reg         training_done,
    output reg         noise_ready,    // level: high after noise window completes, until next sc_lock
    output reg  [9:0]  n_acc
);

    // M = 2^sf
    reg [31:0] M_full;
    always @(*) begin
        case (sf)
            4'd6:  M_full = 32'd64;
            4'd7:  M_full = 32'd128;
            4'd8:  M_full = 32'd256;
            4'd9:  M_full = 32'd512;
            4'd10: M_full = 32'd1024;
            4'd11: M_full = 32'd2048;
            4'd12: M_full = 32'd4096;
            default: M_full = 32'd128;
        endcase
    end

    reg [31:0] sample_count;
    reg [31:0] acc_start, acc_end;
    reg        armed;
    reg        noise_mode_r;   // 1 = currently running a noise-window accumulation
    reg        noise_done;     // sticky: noise window already fired this idle period

    // Reference branch combinatorial mux
    reg signed [7:0] ref_i, ref_q;
    always @(*) begin
        case (ref_sel)
            2'd0: begin ref_i = raw_i0; ref_q = raw_q0; end
            2'd1: begin ref_i = raw_i1; ref_q = raw_q1; end
            2'd2: begin ref_i = raw_i2; ref_q = raw_q2; end
            default: begin ref_i = raw_i3; ref_q = raw_q3; end
        endcase
    end

    // TDM state: 0=idle, 1-4=antenna 0-3, 5=E_ref
    reg [2:0] tdm_state;

    // Latched per-sample inputs (captured when iq_valid triggers TDM)
    reg signed [7:0] raw_ir [0:3];
    reg signed [7:0] raw_qr [0:3];
    reg signed [7:0] ref_ir, ref_qr;
    reg              last_samp;  // this sample was acc_end

    // Pipeline operand selection so the TDM state decode is not in the multiplier path.
    reg signed [7:0] op_i_q, op_q_q, op_ref_i_q, op_ref_q_q;
    reg [2:0]        op_state_q;
    reg              op_valid_q;
    reg              op_last_q;

    // 4 shared 8x8 multipliers, driven only by registered operands.
    wire signed [15:0] mul_a, mul_b, mul_c, mul_d;
    signed_mul8_pipe u_mul_a (.clk(clk), .a(op_i_q), .b(op_ref_i_q), .p(mul_a));
    signed_mul8_pipe u_mul_b (.clk(clk), .a(op_q_q), .b(op_ref_q_q), .p(mul_b));
    signed_mul8_pipe u_mul_c (.clk(clk), .a(op_q_q), .b(op_ref_i_q), .p(mul_c));
    signed_mul8_pipe u_mul_d (.clk(clk), .a(op_i_q), .b(op_ref_q_q), .p(mul_d));

    wire signed [15:0] tdm_zi = mul_a + mul_b;   // prod_zi for current antenna
    wire signed [15:0] tdm_zq = mul_c - mul_d;   // prod_zq for current antenna
    // In state 5: tdm_zi = ref_i^2 + ref_q^2 = E_ref contribution

    reg [1:0] mul_valid_pipe;
    reg [2:0] mul_state_0, mul_state_1;
    reg       mul_last_0, mul_last_1;

    reg signed [15:0] prod_zi_q, prod_zq_q;
    reg [2:0]         prod_state_q;
    reg               prod_valid_q;
    reg               prod_last_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count  <= 32'd0;
            armed         <= 1'b0;
            training_done <= 1'b0;
            noise_ready   <= 1'b0;
            noise_mode_r  <= 1'b0;
            noise_done    <= 1'b0;
            n_acc         <= 10'd0;
            acc_start     <= 32'd0;
            acc_end       <= 32'd0;
            tdm_state     <= 3'd0;
            last_samp     <= 1'b0;
            raw_ir[0] <= 8'sd0; raw_ir[1] <= 8'sd0; raw_ir[2] <= 8'sd0; raw_ir[3] <= 8'sd0;
            raw_qr[0] <= 8'sd0; raw_qr[1] <= 8'sd0; raw_qr[2] <= 8'sd0; raw_qr[3] <= 8'sd0;
            ref_ir <= 8'sd0; ref_qr <= 8'sd0;
            op_i_q <= 8'sd0; op_q_q <= 8'sd0; op_ref_i_q <= 8'sd0; op_ref_q_q <= 8'sd0;
            op_state_q <= 3'd0; op_valid_q <= 1'b0; op_last_q <= 1'b0;
            mul_valid_pipe <= 2'd0;
            mul_state_0 <= 3'd0; mul_state_1 <= 3'd0;
            mul_last_0 <= 1'b0; mul_last_1 <= 1'b0;
            prod_zi_q <= 16'sd0; prod_zq_q <= 16'sd0;
            prod_state_q <= 3'd0; prod_valid_q <= 1'b0; prod_last_q <= 1'b0;
            Z_i0 <= 32'sd0; Z_q0 <= 32'sd0;
            Z_i1 <= 32'sd0; Z_q1 <= 32'sd0;
            Z_i2 <= 32'sd0; Z_q2 <= 32'sd0;
            Z_i3 <= 32'sd0; Z_q3 <= 32'sd0;
            E_ref <= 64'sd0;
        end else begin
            if (iq_valid)
                sample_count <= sample_count + 32'd1;

            // Arm on sc_lock rising edge (normal training mode)
            if (sc_lock && !armed) begin
                armed         <= 1'b1;
                training_done <= 1'b0;
                noise_ready   <= 1'b0;
                noise_mode_r  <= 1'b0;
                noise_done    <= 1'b0;
                acc_start     <= timing_ref;
                acc_end       <= timing_ref + (M_full << 3) - 32'd1;
                Z_i0 <= 32'sd0; Z_q0 <= 32'sd0;
                Z_i1 <= 32'sd0; Z_q1 <= 32'sd0;
                Z_i2 <= 32'sd0; Z_q2 <= 32'sd0;
                Z_i3 <= 32'sd0; Z_q3 <= 32'sd0;
                E_ref <= 64'sd0;
                n_acc <= 10'd0;
            end

            // Arm noise-window accumulation when idle and noise_en asserted
            // ref_sel is overridden internally to ant0; uses 8 symbols of free-running samples
            if (noise_en && !sc_lock && !armed && !noise_done) begin
                armed        <= 1'b1;
                noise_mode_r <= 1'b1;
                noise_ready  <= 1'b0;
                training_done <= 1'b0;
                acc_start    <= sample_count + 32'd1;
                acc_end      <= sample_count + (M_full << 3);
                Z_i0 <= 32'sd0; Z_q0 <= 32'sd0;
                Z_i1 <= 32'sd0; Z_q1 <= 32'sd0;
                Z_i2 <= 32'sd0; Z_q2 <= 32'sd0;
                Z_i3 <= 32'sd0; Z_q3 <= 32'sd0;
                E_ref <= 64'sd0;
                n_acc <= 10'd0;
            end

            // Disarm on sc_lock de-assertion (do not disarm mid-noise-window)
            if (!sc_lock && !noise_mode_r) begin
                armed     <= 1'b0;
                tdm_state <= 3'd0;
            end

            // Trigger TDM on iq_valid within window (only when idle)
            if (armed && iq_valid && tdm_state == 3'd0 &&
                sample_count >= acc_start && sample_count <= acc_end &&
                !training_done && !noise_ready) begin
                // Latch raw samples; in noise mode force ref to ant0
                raw_ir[0] <= raw_i0; raw_qr[0] <= raw_q0;
                raw_ir[1] <= raw_i1; raw_qr[1] <= raw_q1;
                raw_ir[2] <= raw_i2; raw_qr[2] <= raw_q2;
                raw_ir[3] <= raw_i3; raw_qr[3] <= raw_q3;
                ref_ir    <= noise_mode_r ? raw_i0 : ref_i;
                ref_qr    <= noise_mode_r ? raw_q0 : ref_q;
                last_samp <= (sample_count == acc_end);
                if (n_acc < 10'd1023)
                    n_acc <= n_acc + 10'd1;
                tdm_state <= 3'd1;
            end

            // Delay state metadata to match the pipelined multiplier outputs.
            mul_valid_pipe <= {mul_valid_pipe[0], op_valid_q};
            mul_state_0 <= op_state_q;
            mul_state_1 <= mul_state_0;
            mul_last_0 <= op_last_q;
            mul_last_1 <= mul_last_0;

            // Accumulate the previously registered product.
            if (prod_valid_q) begin
                case (prod_state_q)
                    3'd1: begin
                        Z_i0 <= Z_i0 + {{16{prod_zi_q[15]}}, prod_zi_q};
                        Z_q0 <= Z_q0 + {{16{prod_zq_q[15]}}, prod_zq_q};
                    end
                    3'd2: begin
                        Z_i1 <= Z_i1 + {{16{prod_zi_q[15]}}, prod_zi_q};
                        Z_q1 <= Z_q1 + {{16{prod_zq_q[15]}}, prod_zq_q};
                    end
                    3'd3: begin
                        Z_i2 <= Z_i2 + {{16{prod_zi_q[15]}}, prod_zi_q};
                        Z_q2 <= Z_q2 + {{16{prod_zq_q[15]}}, prod_zq_q};
                    end
                    3'd4: begin
                        Z_i3 <= Z_i3 + {{16{prod_zi_q[15]}}, prod_zi_q};
                        Z_q3 <= Z_q3 + {{16{prod_zq_q[15]}}, prod_zq_q};
                    end
                    3'd5: begin
                        E_ref <= E_ref + {{48{prod_zi_q[15]}}, prod_zi_q};
                        if (prod_last_q) begin
                            if (noise_mode_r) begin
                                noise_ready  <= 1'b1;
                                noise_done   <= 1'b1;
                                armed        <= 1'b0;
                                noise_mode_r <= 1'b0;
                            end else begin
                                training_done <= 1'b1;
                            end
                        end
                    end
                    default: ;
                endcase
            end

            // Register product sums from the multiplier outputs before accumulation.
            prod_valid_q <= mul_valid_pipe[1];
            if (mul_valid_pipe[1]) begin
                prod_zi_q    <= tdm_zi;
                prod_zq_q    <= tdm_zq;
                prod_state_q <= mul_state_1;
                prod_last_q  <= mul_last_1;
            end

            // Select operands for the next product; multiplication happens in the helper pipeline.
            op_valid_q <= 1'b0;
            if ((sc_lock || noise_mode_r) && tdm_state != 3'd0) begin
                case (tdm_state)
                    3'd1: begin op_i_q <= raw_ir[0]; op_q_q <= raw_qr[0]; end
                    3'd2: begin op_i_q <= raw_ir[1]; op_q_q <= raw_qr[1]; end
                    3'd3: begin op_i_q <= raw_ir[2]; op_q_q <= raw_qr[2]; end
                    3'd4: begin op_i_q <= raw_ir[3]; op_q_q <= raw_qr[3]; end
                    default: begin op_i_q <= ref_ir; op_q_q <= ref_qr; end
                endcase
                op_ref_i_q <= ref_ir;
                op_ref_q_q <= ref_qr;
                op_state_q <= tdm_state;
                op_last_q  <= last_samp;
                op_valid_q <= 1'b1;

                if (tdm_state == 3'd5)
                    tdm_state <= 3'd0;
                else
                    tdm_state <= tdm_state + 3'd1;
            end
        end
    end

endmodule
