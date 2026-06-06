// frontend_buf_ctrl.v
// Frontend buffer controller — block-based SC delay buffer.
// GF180MCU, 3.3V, 32 MHz single clock domain
//
// Block-based design (replaces sliding circular buffer):
//   L = min(M, 256) samples stored per block in SRAM0 (channel 0 only).
//   blk_cnt counts 0..M-1 across the full symbol period.
//   store_en = (blk_cnt < L): SRAM writes and delayed_valid gated here.
//   Ignore phase (blk_cnt >= L): SRAM idle, delayed_valid=0.
//   block_ready: set after first complete symbol period (blk_cnt wraps once).
//
// SRAM layout (channel 0 only, 2 bytes/sample):
//   i0[k] at address 2k, q0[k] at address 2k+1, k=0..L-1.
//   Max L=256 → max address=511 → fits in 512×8 SRAM0.
//
// SC coverage per SF:
//   SF7: L=128=M  (full symbol, 0 dB loss)
//   SF8: L=256=M  (full symbol, 0 dB loss)
//   SF9: L=256=M/2 (−3 dB)  SF10: M/4 (−6 dB) ... SF12: M/16 (−12 dB)
//   All SFs: one 512×8 SRAM macro.
//
// Channels 1-3 delayed outputs: zeroed (unused by sc_detector; training_acc
// reads dc_removal outputs directly).

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

    // -----------------------------------------------------------------------
    // Full symbol size M = 2^sf (12-bit, max 4096 at SF12)
    // -----------------------------------------------------------------------
    reg [11:0] M_full;
    always @(*) begin
        case (sf)
            4'd6:  M_full = 12'd64;
            4'd7:  M_full = 12'd128;
            4'd8:  M_full = 12'd256;
            4'd9:  M_full = 12'd512;
            4'd10: M_full = 12'd1024;
            4'd11: M_full = 12'd2048;
            4'd12: M_full = 12'd4096;
            default: M_full = 12'd128;
        endcase
    end

    // L = min(M, 256): block size stored in SRAM
    wire [8:0] L_val = (M_full > 12'd256) ? 9'd256 : {1'b0, M_full[7:0]};

    // -----------------------------------------------------------------------
    // Block counter: counts 0..M_full-1 across the full symbol period
    // store_en: first L samples of each block
    // -----------------------------------------------------------------------
    reg [11:0] blk_cnt;
    wire store_en = (blk_cnt < {3'd0, L_val});

    // block_ready: set after first symbol period completes
    reg block_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blk_cnt     <= 12'd0;
            block_ready <= 1'b0;
        end else if (iq_valid) begin
            if (blk_cnt == M_full - 12'd1) begin
                blk_cnt     <= 12'd0;
                block_ready <= 1'b1;
            end else begin
                blk_cnt <= blk_cnt + 12'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sub-cycle FSM: 8 cycles per sample (store phase only)
    // Cycle 0-1: read i0 from SRAM (addr = 2*blk_cnt)
    // Cycle 2-3: read q0 from SRAM (addr = 2*blk_cnt+1)
    // Cycle 4:   latch del_i0/del_q0, assert delayed_valid
    // Cycle 5-6: write i0 to SRAM
    // Cycle 7-8: write q0 to SRAM, done
    // -----------------------------------------------------------------------
    reg [3:0]  sub_cycle;
    reg        fsm_active;

    reg signed [7:0] lat_i0, lat_q0;
    reg [7:0]        rd_i0, rd_q0;

    // SRAM base address for current block position (2 bytes per sample)
    wire [8:0] sram_addr_i = {blk_cnt[7:0], 1'b0};       // 2*blk_cnt
    wire [8:0] sram_addr_q = {blk_cnt[7:0], 1'b0} + 9'd1; // 2*blk_cnt+1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram0_A   <= 9'd0; sram0_D   <= 8'd0;
            sram0_CEN <= 1'b1; sram0_GWEN <= 1'b1;
            sram1_A   <= 9'd0; sram1_D   <= 8'd0;
            sram1_CEN <= 1'b1; sram1_GWEN <= 1'b1;
            sub_cycle   <= 4'd0;
            fsm_active  <= 1'b0;
            lat_i0 <= 8'sd0; lat_q0 <= 8'sd0;
            rd_i0  <= 8'd0;  rd_q0  <= 8'd0;
            cur_i0 <= 8'sd0; cur_i1 <= 8'sd0;
            cur_i2 <= 8'sd0; cur_i3 <= 8'sd0;
            cur_q0 <= 8'sd0; cur_q1 <= 8'sd0;
            cur_q2 <= 8'sd0; cur_q3 <= 8'sd0;
            del_i0 <= 8'sd0; del_i1 <= 8'sd0;
            del_i2 <= 8'sd0; del_i3 <= 8'sd0;
            del_q0 <= 8'sd0; del_q1 <= 8'sd0;
            del_q2 <= 8'sd0; del_q3 <= 8'sd0;
            delayed_valid <= 1'b0;
            buf_valid     <= 1'b0;
            buf_mode      <= 2'd0;
            wr_ptr        <= 7'd0;
        end else begin
            sram0_CEN  <= 1'b1;
            sram0_GWEN <= 1'b1;
            sram1_CEN  <= 1'b1;  // SRAM1 unused — always disabled
            sram1_GWEN <= 1'b1;
            delayed_valid <= 1'b0;

            // Pass-through current samples on iq_valid; trigger FSM if store phase
            if (iq_valid && !fsm_active) begin
                cur_i0 <= in_i0; cur_q0 <= in_q0;
                cur_i1 <= in_i1; cur_q1 <= in_q1;
                cur_i2 <= in_i2; cur_q2 <= in_q2;
                cur_i3 <= in_i3; cur_q3 <= in_q3;
                lat_i0 <= in_i0; lat_q0 <= in_q0;
                if (store_en && !buf_freeze) begin
                    fsm_active <= 1'b1;
                    sub_cycle  <= 4'd0;
                end
            end

            if (fsm_active) begin
                case (sub_cycle)
                    // Read i0 (2 cycles for SRAM read latency)
                    4'd0: begin
                        sram0_A   <= sram_addr_i;
                        sram0_CEN <= 1'b0;
                        sub_cycle <= 4'd1;
                    end
                    4'd1: begin
                        sram0_A   <= sram_addr_i;
                        sram0_CEN <= 1'b0;
                        rd_i0     <= sram0_Q;
                        sub_cycle <= 4'd2;
                    end
                    // Read q0
                    4'd2: begin
                        sram0_A   <= sram_addr_q;
                        sram0_CEN <= 1'b0;
                        sub_cycle <= 4'd3;
                    end
                    4'd3: begin
                        sram0_A   <= sram_addr_q;
                        sram0_CEN <= 1'b0;
                        rd_q0     <= sram0_Q;
                        sub_cycle <= 4'd4;
                    end
                    // Latch delayed outputs
                    4'd4: begin
                        if (block_ready) begin
                            del_i0        <= $signed(rd_i0);
                            del_q0        <= $signed(rd_q0);
                            delayed_valid <= 1'b1;
                        end
                        // Channels 1-3 delayed: unused, left at reset value (0)
                        sub_cycle <= 4'd5;
                    end
                    // Write i0 (2 cycles)
                    4'd5: begin
                        sram0_A    <= sram_addr_i;
                        sram0_D    <= lat_i0;
                        sram0_CEN  <= 1'b0;
                        sram0_GWEN <= 1'b0;
                        sub_cycle  <= 4'd6;
                    end
                    4'd6: begin
                        sram0_A    <= sram_addr_i;
                        sram0_D    <= lat_i0;
                        sram0_CEN  <= 1'b0;
                        sram0_GWEN <= 1'b0;
                        sub_cycle  <= 4'd7;
                    end
                    // Write q0 (2 cycles)
                    4'd7: begin
                        sram0_A    <= sram_addr_q;
                        sram0_D    <= lat_q0;
                        sram0_CEN  <= 1'b0;
                        sram0_GWEN <= 1'b0;
                        sub_cycle  <= 4'd8;
                    end
                    4'd8: begin
                        sram0_A    <= sram_addr_q;
                        sram0_D    <= lat_q0;
                        sram0_CEN  <= 1'b0;
                        sram0_GWEN <= 1'b0;
                        wr_ptr     <= blk_cnt[6:0];
                        fsm_active <= 1'b0;
                        sub_cycle  <= 4'd0;
                    end
                    default: begin
                        fsm_active <= 1'b0;
                        sub_cycle  <= 4'd0;
                    end
                endcase
            end

            buf_valid <= block_ready;

            if (!sc_lock)
                buf_mode <= block_ready ? 2'd1 : 2'd0;
            else if (buf_freeze)
                buf_mode <= 2'd2;
            else
                buf_mode <= 2'd3;
        end
    end

endmodule
