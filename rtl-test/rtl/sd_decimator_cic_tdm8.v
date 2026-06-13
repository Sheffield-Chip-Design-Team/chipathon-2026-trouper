// sd_decimator_cic_tdm8.v
// Structural area experiment: 4-channel boxcar-4 front end + shared 4-slot CIC(N=3, R=32).
//
// Purpose:
//   - estimate area of a staged decimator that enables TDM in the slower stage
//   - preserve the same top-level compare interface as sd_decim_4ch_cic_only
//
// Notes:
//   - This is a synthesis-oriented test RTL, not the deployed decimator.
//   - Stage A runs per-branch at 32 MHz and reduces each branch by 4.
//   - Stage B is a shared 4-slot CIC across branches, effectively seeing 8 MHz/branch.
//   - Total decimation is 4 * 32 = 128, matching the deployed 250 kS/s operating point.
//   - Outputs are released with a common iq_valid when all 4 branches in a decimated frame are ready.
//   - Frame pickup is folded into the slot-0 processing cycle, so the shared
//     stage services a 4-branch frame in exactly 4 clocks (matches Stage A rate).
//   - Chain gain is boxcar-4 * 32^3 = 2^17; >>>10 maps full scale to int8.
//
// GF180MCU, 3.3V

`timescale 1ns/100ps

module sd_decimator_cic_tdm8 (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire [3:0]  iq_in_i,
    input  wire [3:0]  iq_in_q,
    output reg  [31:0] iq_out_i,
    output reg  [31:0] iq_out_q,
    output reg  [3:0]  iq_valid
);

    integer k;

    // ---------------------------------------------------------------------
    // Stage A: per-branch boxcar-4 pre-decimator
    // ---------------------------------------------------------------------
    reg [1:0] box_cnt;
    reg signed [3:0] box_acc_i [0:3];
    reg signed [3:0] box_acc_q [0:3];

    reg frame_valid [0:1];
    reg       wr_bank;
    reg       rd_bank;
    reg       busy;
    reg [1:0] slot;

    reg signed [3:0] frame_i_0 [0:3];
    reg signed [3:0] frame_q_0 [0:3];
    reg signed [3:0] frame_i_1 [0:3];
    reg signed [3:0] frame_q_1 [0:3];

    // ---------------------------------------------------------------------
    // Stage B: shared CIC state, one branch serviced per clock
    // ---------------------------------------------------------------------
    reg [4:0] decim_cnt [0:3];

    reg signed [25:0] intg_i1 [0:3];
    reg signed [25:0] intg_i2 [0:3];
    reg signed [25:0] intg_i3 [0:3];
    reg signed [25:0] intg_q1 [0:3];
    reg signed [25:0] intg_q2 [0:3];
    reg signed [25:0] intg_q3 [0:3];

    reg signed [25:0] comb_i1_d [0:3];
    reg signed [25:0] comb_i2_d [0:3];
    reg signed [25:0] comb_i3_d [0:3];
    reg signed [25:0] comb_q1_d [0:3];
    reg signed [25:0] comb_q2_d [0:3];
    reg signed [25:0] comb_q3_d [0:3];

    reg        pending_valid [0:3];
    reg signed [7:0] out_hold_i [0:3];
    reg signed [7:0] out_hold_q [0:3];

    reg signed [3:0]  samp_i_4b, samp_q_4b;
    reg signed [25:0] samp_i_ext, samp_q_ext;
    reg signed [25:0] comb_i1_w, comb_i2_w, comb_i3_w;
    reg signed [25:0] comb_q1_w, comb_q2_w, comb_q3_w;
    reg signed [25:0] shifted_i, shifted_q;
    reg [3:0] next_pending_bits;

    // Active slot this cycle: slot 0 is processed in the pickup cycle itself
    // so a frame is serviced in 4 clocks, matching Stage A's frame rate.
    reg       proc_en;
    reg [1:0] proc_slot;
    reg       proc_bank;

    function signed [7:0] sat8;
        input signed [25:0] v;
        begin
            if (v > 26'sd127)
                sat8 = 8'sd127;
            else if (v < -26'sd128)
                sat8 = -8'sd128;
            else
                sat8 = v[7:0];
        end
    endfunction

    always @(*) begin
        if (busy) begin
            proc_en   = 1'b1;
            proc_slot = slot;
            proc_bank = rd_bank;
        end else if (frame_valid[0]) begin
            proc_en   = 1'b1;
            proc_slot = 2'd0;
            proc_bank = 1'b0;
        end else if (frame_valid[1]) begin
            proc_en   = 1'b1;
            proc_slot = 2'd0;
            proc_bank = 1'b1;
        end else begin
            proc_en   = 1'b0;
            proc_slot = 2'd0;
            proc_bank = 1'b0;
        end

        if (!proc_bank) begin
            samp_i_4b = frame_i_0[proc_slot];
            samp_q_4b = frame_q_0[proc_slot];
        end else begin
            samp_i_4b = frame_i_1[proc_slot];
            samp_q_4b = frame_q_1[proc_slot];
        end

        samp_i_ext = {{22{samp_i_4b[3]}}, samp_i_4b};
        samp_q_ext = {{22{samp_q_4b[3]}}, samp_q_4b};

        comb_i1_w = intg_i3[proc_slot] - comb_i1_d[proc_slot];
        comb_i2_w = comb_i1_w           - comb_i2_d[proc_slot];
        comb_i3_w = comb_i2_w           - comb_i3_d[proc_slot];
        comb_q1_w = intg_q3[proc_slot] - comb_q1_d[proc_slot];
        comb_q2_w = comb_q1_w           - comb_q2_d[proc_slot];
        comb_q3_w = comb_q2_w           - comb_q3_d[proc_slot];

        // gain = 4 * 32^3 = 2^17; map full scale to int8 (+/-128)
        shifted_i = comb_i3_w >>> 10;
        shifted_q = comb_q3_w >>> 10;

        next_pending_bits = {
            pending_valid[3],
            pending_valid[2],
            pending_valid[1],
            pending_valid[0]
        } | (4'b0001 << proc_slot);
    end

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            box_cnt <= 2'd0;
            wr_bank <= 1'b0;
            rd_bank <= 1'b0;
            busy    <= 1'b0;
            slot    <= 2'd0;
            iq_out_i <= 32'd0;
            iq_out_q <= 32'd0;
            iq_valid <= 4'd0;
            frame_valid[0] <= 1'b0;
            frame_valid[1] <= 1'b0;
            for (k = 0; k < 4; k = k + 1) begin
                box_acc_i[k] <= 4'sd0;
                box_acc_q[k] <= 4'sd0;
                frame_i_0[k] <= 4'sd0;
                frame_q_0[k] <= 4'sd0;
                frame_i_1[k] <= 4'sd0;
                frame_q_1[k] <= 4'sd0;
                decim_cnt[k] <= 5'd0;
                intg_i1[k] <= 26'sd0;
                intg_i2[k] <= 26'sd0;
                intg_i3[k] <= 26'sd0;
                intg_q1[k] <= 26'sd0;
                intg_q2[k] <= 26'sd0;
                intg_q3[k] <= 26'sd0;
                comb_i1_d[k] <= 26'sd0;
                comb_i2_d[k] <= 26'sd0;
                comb_i3_d[k] <= 26'sd0;
                comb_q1_d[k] <= 26'sd0;
                comb_q2_d[k] <= 26'sd0;
                comb_q3_d[k] <= 26'sd0;
                pending_valid[k] <= 1'b0;
                out_hold_i[k] <= 8'sd0;
                out_hold_q[k] <= 8'sd0;
            end
        end else begin
            iq_valid <= 4'd0;

            // Stage A capture runs continuously.
            if (box_cnt == 2'd3) begin
                box_cnt <= 2'd0;
                if (!wr_bank) begin
                    for (k = 0; k < 4; k = k + 1) begin
                        frame_i_0[k] <= box_acc_i[k] + (iq_in_i[k] ? 4'sd1 : -4'sd1);
                        frame_q_0[k] <= box_acc_q[k] + (iq_in_q[k] ? 4'sd1 : -4'sd1);
                        box_acc_i[k] <= 4'sd0;
                        box_acc_q[k] <= 4'sd0;
                    end
                    frame_valid[0] <= 1'b1;
                end else begin
                    for (k = 0; k < 4; k = k + 1) begin
                        frame_i_1[k] <= box_acc_i[k] + (iq_in_i[k] ? 4'sd1 : -4'sd1);
                        frame_q_1[k] <= box_acc_q[k] + (iq_in_q[k] ? 4'sd1 : -4'sd1);
                        box_acc_i[k] <= 4'sd0;
                        box_acc_q[k] <= 4'sd0;
                    end
                    frame_valid[1] <= 1'b1;
                end
                wr_bank <= ~wr_bank;
            end else begin
                box_cnt <= box_cnt + 2'd1;
                for (k = 0; k < 4; k = k + 1) begin
                    box_acc_i[k] <= box_acc_i[k] + (iq_in_i[k] ? 4'sd1 : -4'sd1);
                    box_acc_q[k] <= box_acc_q[k] + (iq_in_q[k] ? 4'sd1 : -4'sd1);
                end
            end

            // Frame pickup: slot 0 is processed this same cycle (via proc_slot),
            // so the sweep continues with slot 1 next cycle. Total service time
            // is 4 clocks per frame, matching Stage A's production rate.
            if (!busy) begin
                if (frame_valid[0]) begin
                    busy <= 1'b1;
                    rd_bank <= 1'b0;
                    slot <= 2'd1;
                    frame_valid[0] <= 1'b0;
                end else if (frame_valid[1]) begin
                    busy <= 1'b1;
                    rd_bank <= 1'b1;
                    slot <= 2'd1;
                    frame_valid[1] <= 1'b0;
                end
            end else begin
                if (slot == 2'd3) begin
                    busy <= 1'b0;
                end else begin
                    slot <= slot + 2'd1;
                end
            end

            // Shared CIC update for the active branch slot.
            if (proc_en) begin
                intg_i1[proc_slot] <= intg_i1[proc_slot] + samp_i_ext;
                intg_i2[proc_slot] <= intg_i2[proc_slot] + intg_i1[proc_slot];
                intg_i3[proc_slot] <= intg_i3[proc_slot] + intg_i2[proc_slot];
                intg_q1[proc_slot] <= intg_q1[proc_slot] + samp_q_ext;
                intg_q2[proc_slot] <= intg_q2[proc_slot] + intg_q1[proc_slot];
                intg_q3[proc_slot] <= intg_q3[proc_slot] + intg_q2[proc_slot];

                if (decim_cnt[proc_slot] == 5'd31) begin
                    decim_cnt[proc_slot] <= 5'd0;
                    comb_i1_d[proc_slot] <= intg_i3[proc_slot];
                    comb_i2_d[proc_slot] <= comb_i1_w;
                    comb_i3_d[proc_slot] <= comb_i2_w;
                    comb_q1_d[proc_slot] <= intg_q3[proc_slot];
                    comb_q2_d[proc_slot] <= comb_q1_w;
                    comb_q3_d[proc_slot] <= comb_q2_w;
                    out_hold_i[proc_slot] <= sat8(shifted_i);
                    out_hold_q[proc_slot] <= sat8(shifted_q);

                    if (next_pending_bits == 4'b1111) begin
                        iq_out_i <= {
                            out_hold_i[3],
                            out_hold_i[2],
                            out_hold_i[1],
                            (proc_slot == 2'd0) ? sat8(shifted_i) : out_hold_i[0]
                        };
                        iq_out_q <= {
                            out_hold_q[3],
                            out_hold_q[2],
                            out_hold_q[1],
                            (proc_slot == 2'd0) ? sat8(shifted_q) : out_hold_q[0]
                        };
                        case (proc_slot)
                            2'd1: begin iq_out_i[15:8]  <= sat8(shifted_i); iq_out_q[15:8]  <= sat8(shifted_q); end
                            2'd2: begin iq_out_i[23:16] <= sat8(shifted_i); iq_out_q[23:16] <= sat8(shifted_q); end
                            2'd3: begin iq_out_i[31:24] <= sat8(shifted_i); iq_out_q[31:24] <= sat8(shifted_q); end
                            default: begin end
                        endcase
                        iq_valid <= 4'b1111;
                        for (k = 0; k < 4; k = k + 1)
                            pending_valid[k] <= 1'b0;
                    end else begin
                        pending_valid[proc_slot] <= 1'b1;
                    end
                end else begin
                    decim_cnt[proc_slot] <= decim_cnt[proc_slot] + 5'd1;
                end
            end
        end
    end
endmodule
