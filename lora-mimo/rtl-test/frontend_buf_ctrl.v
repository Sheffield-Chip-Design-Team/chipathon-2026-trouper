// frontend_buf_ctrl.v
// Frontend buffer controller for 2x single-port 512x8 SRAMs
// SRAM0: channels 0+1 (4 bytes: i0,q0,i1,q1), SRAM1: channels 2+3
// GF180MCU, 3.3V, 32 MHz single clock domain

module frontend_buf_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] in_i0, in_i1, in_i2, in_i3,
    input  wire signed [7:0] in_q0, in_q1, in_q2, in_q3,
    input  wire [3:0]  sf,
    input  wire        sc_lock,
    input  wire        buf_freeze,
    output reg  [8:0]  sram0_A,
    output reg  [7:0]  sram0_D,
    input  wire [7:0]  sram0_Q,
    output reg         sram0_CEN,
    output reg         sram0_GWEN,
    output reg  [8:0]  sram1_A,
    output reg  [7:0]  sram1_D,
    input  wire [7:0]  sram1_Q,
    output reg         sram1_CEN,
    output reg         sram1_GWEN,
    output reg  signed [7:0] cur_i0, cur_i1, cur_i2, cur_i3,
    output reg  signed [7:0] cur_q0, cur_q1, cur_q2, cur_q3,
    output reg  signed [7:0] del_i0, del_i1, del_i2, del_i3,
    output reg  signed [7:0] del_q0, del_q1, del_q2, del_q3,
    output reg         delayed_valid,
    output reg  [1:0]  buf_mode,
    output reg         buf_valid,
    output reg  [6:0]  wr_ptr
);

    // M = 2^sf, clamped to 128 max (7-bit wr_ptr wraps at M)
    // sf range 6-12; sf=7 -> M=128 max we store; higher sf also uses M=128 window
    // Effective M for buffer purposes: min(2^sf, 128)
    reg [6:0] M_mask; // bitmask for modulo: wr_ptr & M_mask
    always @(*) begin
        case (sf)
            4'd6: M_mask = 7'h3F;  // M=64,  mask=63
            4'd7: M_mask = 7'h7F;  // M=128, mask=127
            default: M_mask = 7'h7F; // clamp to 128
        endcase
    end

    reg [7:0] M_val;
    always @(*) begin
        case (sf)
            4'd6: M_val = 8'd64;
            4'd7: M_val = 8'd128;
            default: M_val = 8'd128;
        endcase
    end

    // Sample count tracks how many samples have been written (capped at M)
    reg [7:0] sample_count;

    // Sub-cycle FSM: runs 16 sub-cycles per iq_valid
    reg [4:0]  sub_cycle;
    reg        fsm_active;

    // Latched inputs for current sample
    reg signed [7:0] lat_i0, lat_i1, lat_i2, lat_i3;
    reg signed [7:0] lat_q0, lat_q1, lat_q2, lat_q3;

    // Delayed read captures from SRAM (2-cycle read latency)
    // byte_index: 0=i0,1=q0 on SRAM0; 2=i1,3=q1 on SRAM0
    //             0=i2,1=q2 on SRAM1; 2=i3,3=q3 on SRAM1

    // Read base address: 4*(wr_ptr mod M) for delayed sample
    wire [6:0] rd_base_ptr = (wr_ptr + 7'd1) & M_mask; // oldest slot = (wr_ptr+1) mod M
    wire [8:0] rd_base_addr = {2'b00, rd_base_ptr, 2'b00}; // *4

    // Write base address
    wire [8:0] wr_base_addr = {2'b00, wr_ptr & M_mask, 2'b00}; // *4

    // SRAM read capture registers
    reg [7:0] rd0_b0, rd0_b1, rd0_b2, rd0_b3;
    reg [7:0] rd1_b0, rd1_b1, rd1_b2, rd1_b3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram0_A <= 9'd0; sram0_D <= 8'd0; sram0_CEN <= 1'b1; sram0_GWEN <= 1'b1;
            sram1_A <= 9'd0; sram1_D <= 8'd0; sram1_CEN <= 1'b1; sram1_GWEN <= 1'b1;
            sub_cycle    <= 5'd0;
            fsm_active   <= 1'b0;
            wr_ptr       <= 7'd0;
            sample_count <= 8'd0;
            buf_valid    <= 1'b0;
            delayed_valid <= 1'b0;
            buf_mode     <= 2'd0;
            lat_i0 <= 8'sd0; lat_i1 <= 8'sd0; lat_i2 <= 8'sd0; lat_i3 <= 8'sd0;
            lat_q0 <= 8'sd0; lat_q1 <= 8'sd0; lat_q2 <= 8'sd0; lat_q3 <= 8'sd0;
            cur_i0 <= 8'sd0; cur_i1 <= 8'sd0; cur_i2 <= 8'sd0; cur_i3 <= 8'sd0;
            cur_q0 <= 8'sd0; cur_q1 <= 8'sd0; cur_q2 <= 8'sd0; cur_q3 <= 8'sd0;
            del_i0 <= 8'sd0; del_i1 <= 8'sd0; del_i2 <= 8'sd0; del_i3 <= 8'sd0;
            del_q0 <= 8'sd0; del_q1 <= 8'sd0; del_q2 <= 8'sd0; del_q3 <= 8'sd0;
            rd0_b0 <= 8'd0; rd0_b1 <= 8'd0; rd0_b2 <= 8'd0; rd0_b3 <= 8'd0;
            rd1_b0 <= 8'd0; rd1_b1 <= 8'd0; rd1_b2 <= 8'd0; rd1_b3 <= 8'd0;
        end else begin
            // Default: deassert chip enables
            sram0_CEN <= 1'b1;
            sram1_CEN <= 1'b1;
            sram0_GWEN <= 1'b1;
            sram1_GWEN <= 1'b1;

            // Latch inputs on iq_valid and start sub-cycle FSM
            if (iq_valid && !fsm_active) begin
                lat_i0 <= in_i0; lat_q0 <= in_q0;
                lat_i1 <= in_i1; lat_q1 <= in_q1;
                lat_i2 <= in_i2; lat_q2 <= in_q2;
                lat_i3 <= in_i3; lat_q3 <= in_q3;
                cur_i0 <= in_i0; cur_q0 <= in_q0;
                cur_i1 <= in_i1; cur_q1 <= in_q1;
                cur_i2 <= in_i2; cur_q2 <= in_q2;
                cur_i3 <= in_i3; cur_q3 <= in_q3;
                fsm_active <= 1'b1;
                sub_cycle  <= 5'd0;
            end

            if (fsm_active) begin
                case (sub_cycle)
                    // -- Read phase (cycles 0-7): 4 bytes from each SRAM
                    // SRAM0 byte 0 (i0 of delayed sample): assert for 2 cycles
                    5'd0: begin
                        sram0_A   <= rd_base_addr + 9'd0;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1; // read
                        sram1_A   <= rd_base_addr + 9'd0;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        sub_cycle <= 5'd1;
                    end
                    5'd1: begin
                        sram0_A   <= rd_base_addr + 9'd0;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1;
                        sram1_A   <= rd_base_addr + 9'd0;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        rd0_b0 <= sram0_Q;
                        rd1_b0 <= sram1_Q;
                        sub_cycle <= 5'd2;
                    end
                    5'd2: begin
                        sram0_A   <= rd_base_addr + 9'd1;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1;
                        sram1_A   <= rd_base_addr + 9'd1;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        sub_cycle <= 5'd3;
                    end
                    5'd3: begin
                        sram0_A   <= rd_base_addr + 9'd1;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1;
                        sram1_A   <= rd_base_addr + 9'd1;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        rd0_b1 <= sram0_Q;
                        rd1_b1 <= sram1_Q;
                        sub_cycle <= 5'd4;
                    end
                    5'd4: begin
                        sram0_A   <= rd_base_addr + 9'd2;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1;
                        sram1_A   <= rd_base_addr + 9'd2;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        sub_cycle <= 5'd5;
                    end
                    5'd5: begin
                        sram0_A   <= rd_base_addr + 9'd2;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1;
                        sram1_A   <= rd_base_addr + 9'd2;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        rd0_b2 <= sram0_Q;
                        rd1_b2 <= sram1_Q;
                        sub_cycle <= 5'd6;
                    end
                    5'd6: begin
                        sram0_A   <= rd_base_addr + 9'd3;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1;
                        sram1_A   <= rd_base_addr + 9'd3;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        sub_cycle <= 5'd7;
                    end
                    5'd7: begin
                        sram0_A   <= rd_base_addr + 9'd3;
                        sram0_CEN <= 1'b0;
                        sram0_GWEN <= 1'b1;
                        sram1_A   <= rd_base_addr + 9'd3;
                        sram1_CEN <= 1'b0;
                        sram1_GWEN <= 1'b1;
                        rd0_b3 <= sram0_Q;
                        rd1_b3 <= sram1_Q;
                        sub_cycle <= 5'd8;
                    end
                    5'd8: begin
                        // Latch delayed sample outputs
                        if (buf_valid) begin
                            del_i0 <= $signed(rd0_b0);
                            del_q0 <= $signed(rd0_b1);
                            del_i1 <= $signed(rd0_b2);
                            del_q1 <= $signed(rd0_b3);
                            del_i2 <= $signed(rd1_b0);
                            del_q2 <= $signed(rd1_b1);
                            del_i3 <= $signed(rd1_b2);
                            del_q3 <= $signed(rd1_b3);
                            delayed_valid <= 1'b1;
                        end else begin
                            delayed_valid <= 1'b0;
                        end
                        sub_cycle <= 5'd9;
                    end
                    // -- Write phase (cycles 9-16): write 4 bytes per SRAM
                    5'd9: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd0;
                            sram0_D    <= lat_i0;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd0;
                            sram1_D    <= lat_i2;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                        end
                        sub_cycle <= 5'd10;
                    end
                    5'd10: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd0;
                            sram0_D    <= lat_i0;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd0;
                            sram1_D    <= lat_i2;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                        end
                        sub_cycle <= 5'd11;
                    end
                    5'd11: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd1;
                            sram0_D    <= lat_q0;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd1;
                            sram1_D    <= lat_q2;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                        end
                        sub_cycle <= 5'd12;
                    end
                    5'd12: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd1;
                            sram0_D    <= lat_q0;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd1;
                            sram1_D    <= lat_q2;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                        end
                        sub_cycle <= 5'd13;
                    end
                    5'd13: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd2;
                            sram0_D    <= lat_i1;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd2;
                            sram1_D    <= lat_i3;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                        end
                        sub_cycle <= 5'd14;
                    end
                    5'd14: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd2;
                            sram0_D    <= lat_i1;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd2;
                            sram1_D    <= lat_i3;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                        end
                        sub_cycle <= 5'd15;
                    end
                    5'd15: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd3;
                            sram0_D    <= lat_q1;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd3;
                            sram1_D    <= lat_q3;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                        end
                        sub_cycle <= 5'd16;
                    end
                    5'd16: begin
                        if (!buf_freeze) begin
                            sram0_A    <= wr_base_addr + 9'd3;
                            sram0_D    <= lat_q1;
                            sram0_CEN  <= 1'b0;
                            sram0_GWEN <= 1'b0;
                            sram1_A    <= wr_base_addr + 9'd3;
                            sram1_D    <= lat_q3;
                            sram1_CEN  <= 1'b0;
                            sram1_GWEN <= 1'b0;
                            // Advance write pointer and sample count
                            wr_ptr <= (wr_ptr + 7'd1) & M_mask;
                            if (sample_count < M_val)
                                sample_count <= sample_count + 8'd1;
                        end
                        fsm_active <= 1'b0;
                        sub_cycle  <= 5'd0;
                    end
                    default: begin
                        fsm_active <= 1'b0;
                        sub_cycle  <= 5'd0;
                    end
                endcase
            end

            // buf_valid: asserted when sample_count >= M
            buf_valid <= (sample_count >= {1'b0, M_val});

            // buf_mode
            if (!sc_lock)
                buf_mode <= buf_valid ? 2'd1 : 2'd0; // acquiring / idle
            else if (buf_freeze)
                buf_mode <= 2'd2; // locked
            else
                buf_mode <= 2'd3; // post-lock
        end
    end

endmodule
