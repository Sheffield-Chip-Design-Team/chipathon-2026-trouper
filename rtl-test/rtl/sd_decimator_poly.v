// Area-reduction variant: 14-bit CIC (candidate #3) + POLYPHASE half-band delay
// lines (candidate #2) — see planning/decimator-hb-area-reduction.md.
//
// A 2:1-decimating half-band only evaluates its FIR every other input sample, and
// all odd-lag taps are zero except the centre. So the delay line splits into two
// half-rate polyphase branches:
//   phase A : the non-zero even-lag taps         (HB1 lags 0,2,4,6,8,10 ; HB2 0..14)
//   phase B : the single centre tap              (HB1 lag 5 ; HB2 lag 7)
// Each branch shifts only on its own input sample, so it holds ~N/2 registers
// instead of N. The MAC reads exactly the same sample values as the direct form,
// so packed outputs are bit-exact with the shared HB reference prototype.
//
// HB1 store: A[0:5]=lags{0,2,4,6,8,10}, B[0:2]=lags{1,3,5}; centre = B[2].
// HB2 store: A[0:7]=lags{0,2,..,14}, B[0:3]=lags{1,3,5,7}; centre = B[3].
`timescale 1ns/100ps

module sd_decimator_poly_cic_comb (
    input  wire signed [13:0] int3,
    input  wire signed [13:0] comb1_z,
    input  wire signed [13:0] comb2_z,
    input  wire signed [13:0] comb3_z,
    output wire signed [13:0] comb1,
    output wire signed [13:0] comb2,
    output wire signed [7:0]  sample8
);
    wire signed [13:0] comb3;
    wire signed [13:0] scaled;

    assign comb1 = int3 - comb1_z;
    assign comb2 = comb1 - comb2_z;
    assign comb3 = comb2 - comb3_z;
    assign scaled = (comb3 + 14'sd16) >>> 5;

    assign sample8 = (scaled > 14'sd127)  ?  8'sd127 :
                     (scaled < -14'sd128) ? -8'sd128 :
                                             scaled[7:0];
endmodule

module sd_decimator_poly_hb1_mac (
    input  wire signed [7:0] a0,
    input  wire signed [7:0] a1,
    input  wire signed [7:0] a2,
    input  wire signed [7:0] a3,
    input  wire signed [7:0] a4,
    input  wire signed [7:0] a5,
    input  wire signed [7:0] centre,
    output wire signed [7:0] result
);
    wire signed [19:0] acc;
    wire signed [19:0] scaled;

    assign acc = 20'sd19  * ($signed(a0) + $signed(a5))
               - 20'sd73  * ($signed(a1) + $signed(a4))
               + 20'sd312 * ($signed(a2) + $signed(a3))
               + 20'sd512 * $signed(centre);
    assign scaled = (acc + 20'sd512) >>> 10;

    assign result = (scaled > 20'sd127)  ?  8'sd127 :
                    (scaled < -20'sd128) ? -8'sd128 :
                                            scaled[7:0];
endmodule

module sd_decimator_poly_hb2_mac (
    input  wire signed [7:0] a0,
    input  wire signed [7:0] a1,
    input  wire signed [7:0] a2,
    input  wire signed [7:0] a3,
    input  wire signed [7:0] a4,
    input  wire signed [7:0] a5,
    input  wire signed [7:0] a6,
    input  wire signed [7:0] a7,
    input  wire signed [7:0] centre,
    output wire signed [7:0] result
);
    wire signed [19:0] acc;
    wire signed [19:0] scaled;

    assign acc = -20'sd27 * ($signed(a0) + $signed(a7))
               + 20'sd45  * ($signed(a1) + $signed(a6))
               - 20'sd96  * ($signed(a2) + $signed(a5))
               + 20'sd321 * ($signed(a3) + $signed(a4))
               + 20'sd512 * $signed(centre);
    assign scaled = (acc + 20'sd512) >>> 10;

    assign result = (scaled > 20'sd127)  ?  8'sd127 :
                    (scaled < -20'sd128) ? -8'sd128 :
                                            scaled[7:0];
endmodule

module sd_decimator_poly (
    input wire clk_32m, input wire rst_n,
    input wire [3:0] iq_in_i, input wire [3:0] iq_in_q,
    output reg [31:0] iq_out_i, output reg [31:0] iq_out_q,
    output reg [3:0] iq_valid
);
    integer ch, tap;
    genvar g;
    reg [3:0] cic_count;
    reg hb1_phase, hb2_phase;
    reg hb1_busy, hb2_busy;
    reg [2:0] hb1_stream, hb2_stream;
    localparam [3:0] CIC_LAST = 4'd15;
    localparam [2:0] STREAM_LAST = 3'd7;
    // SS-timing: the HB MAC is a ~40-level combinational cone that cannot settle
    // in one 31.25 ns cycle at the FD-cell SS corner.  The decimator is 97% idle
    // (HB2 fires once per 64 clocks, uses 8), so each stream index is held for
    // MAC_WAIT+1 cycles, making every HB MAC path a genuine 3-cycle multicycle
    // path (matched by set_multicycle_path 3 in the SDC).  Burst length grows
    // 8->24 clocks; still fits the HB1 32-clock / HB2 64-clock windows.
    localparam [1:0] MAC_WAIT = 2'd2;   // hold each MAC index MAC_WAIT+1 = 3 cycles
    reg [1:0] hb1_wait, hb2_wait;

    reg signed [13:0] int_i1[0:3], int_i2[0:3], int_i3[0:3];
    reg signed [13:0] int_q1[0:3], int_q2[0:3], int_q3[0:3];
    reg signed [13:0] comb_i1_z[0:3], comb_i2_z[0:3], comb_i3_z[0:3];
    reg signed [13:0] comb_q1_z[0:3], comb_q2_z[0:3], comb_q3_z[0:3];

    // Polyphase half-band delay lines.
    reg signed [7:0] h1a_i[0:3][0:5], h1a_q[0:3][0:5];   // HB1 phase A (even lags)
    reg signed [7:0] h1b_i[0:3][0:2], h1b_q[0:3][0:2];   // HB1 phase B (centre)
    reg signed [7:0] h2a_i[0:3][0:7], h2a_q[0:3][0:7];   // HB2 phase A
    reg signed [7:0] h2b_i[0:3][0:3], h2b_q[0:3][0:3];   // HB2 phase B
    reg signed [7:0] hb1_hold_i[0:3], hb1_hold_q[0:3];

    wire signed [13:0] ci1[0:3], ci2[0:3];
    wire signed [13:0] cq1[0:3], cq2[0:3];
    wire signed [7:0] ci8[0:3], cq8[0:3];

    // HB1 MAC operands: a0,a5 (lag0,10) a1,a4 (lag2,8) a2,a3 (lag4,6) bc (lag5).
    reg signed [7:0] h1a0,h1a1,h1a2,h1a3,h1a4,h1a5,h1bc;
    // Centre-tap (h1b[2]) snapshot, latched at HB1 burst start.  The phase-B CIC
    // insert shifts h1b every 16 clocks; the paced HB1 burst is 24 clocks, so the
    // shift would otherwise land mid-burst and corrupt h1bc for the later streams.
    // Snapshotting freezes the burst-start value for all 8 streams (matches the
    // original 8-clock burst, which always completed before the shift).
    reg signed [7:0] h1bc_snap_i[0:3], h1bc_snap_q[0:3];
    // HB2 MAC operands: a0,a7 a1,a6 a2,a5 a3,a4 bc (lag7).
    reg signed [7:0] h2a0,h2a1,h2a2,h2a3,h2a4,h2a5,h2a6,h2a7,h2bc;
    wire signed [7:0] h1_result, h2_result;
    reg [1:0] s1, s2;
    wire hb1_mac_ready = (hb1_wait == MAC_WAIT);
    wire hb2_mac_ready = (hb2_wait == MAC_WAIT);
    wire hb1_stream_is_i = !hb1_stream[2];
    wire hb2_stream_is_i = !hb2_stream[2];
    wire hb1_stream_last = (hb1_stream == STREAM_LAST);
    wire hb2_stream_last = (hb2_stream == STREAM_LAST);

    generate
        for (g = 0; g < 4; g = g + 1) begin : gen_cic_comb
            sd_decimator_poly_cic_comb u_cic_i (
                .int3(int_i3[g]),
                .comb1_z(comb_i1_z[g]),
                .comb2_z(comb_i2_z[g]),
                .comb3_z(comb_i3_z[g]),
                .comb1(ci1[g]),
                .comb2(ci2[g]),
                .sample8(ci8[g])
            );

            sd_decimator_poly_cic_comb u_cic_q (
                .int3(int_q3[g]),
                .comb1_z(comb_q1_z[g]),
                .comb2_z(comb_q2_z[g]),
                .comb3_z(comb_q3_z[g]),
                .comb1(cq1[g]),
                .comb2(cq2[g]),
                .sample8(cq8[g])
            );
        end
    endgenerate

    sd_decimator_poly_hb1_mac u_hb1_mac (
        .a0(h1a0),
        .a1(h1a1),
        .a2(h1a2),
        .a3(h1a3),
        .a4(h1a4),
        .a5(h1a5),
        .centre(h1bc),
        .result(h1_result)
    );

    sd_decimator_poly_hb2_mac u_hb2_mac (
        .a0(h2a0),
        .a1(h2a1),
        .a2(h2a2),
        .a3(h2a3),
        .a4(h2a4),
        .a5(h2a5),
        .a6(h2a6),
        .a7(h2a7),
        .centre(h2bc),
        .result(h2_result)
    );

    task insert_hb2_frame;
        input phase_a;
        integer c, t;
        reg signed [7:0] q_sample;
        begin
            for (c = 0; c < 4; c = c + 1) begin
                // The last HB1 stream is Q3. hb1_hold_q[3] is written on this
                // same edge, so feed that sample from h1_result directly.
                q_sample = (c == 3) ? h1_result : hb1_hold_q[c];

                if (phase_a) begin
                    for (t = 7; t > 0; t = t - 1) begin
                        h2a_i[c][t] <= h2a_i[c][t - 1];
                        h2a_q[c][t] <= h2a_q[c][t - 1];
                    end
                    h2a_i[c][0] <= hb1_hold_i[c];
                    h2a_q[c][0] <= q_sample;
                end else begin
                    for (t = 3; t > 0; t = t - 1) begin
                        h2b_i[c][t] <= h2b_i[c][t - 1];
                        h2b_q[c][t] <= h2b_q[c][t - 1];
                    end
                    h2b_i[c][0] <= hb1_hold_i[c];
                    h2b_q[c][0] <= q_sample;
                end
            end
        end
    endtask

    task store_hb1_result;
        begin
            if (hb1_stream_is_i)
                hb1_hold_i[hb1_stream[1:0]] <= h1_result;
            else
                hb1_hold_q[hb1_stream[1:0]] <= h1_result;
        end
    endtask

    task store_hb2_result;
        begin
            if (hb2_stream_is_i)
                iq_out_i[hb2_stream[1:0]*8+:8] <= h2_result;
            else
                iq_out_q[hb2_stream[1:0]*8+:8] <= h2_result;
        end
    endtask

    always @(*) begin
        s1 = hb1_stream[1:0];
        if (!hb1_stream[2]) begin
            h1a0=h1a_i[s1][0]; h1a1=h1a_i[s1][1]; h1a2=h1a_i[s1][2];
            h1a3=h1a_i[s1][3]; h1a4=h1a_i[s1][4]; h1a5=h1a_i[s1][5]; h1bc=h1bc_snap_i[s1];
        end else begin
            h1a0=h1a_q[s1][0]; h1a1=h1a_q[s1][1]; h1a2=h1a_q[s1][2];
            h1a3=h1a_q[s1][3]; h1a4=h1a_q[s1][4]; h1a5=h1a_q[s1][5]; h1bc=h1bc_snap_q[s1];
        end

        s2 = hb2_stream[1:0];
        if (!hb2_stream[2]) begin
            h2a0=h2a_i[s2][0]; h2a1=h2a_i[s2][1]; h2a2=h2a_i[s2][2]; h2a3=h2a_i[s2][3];
            h2a4=h2a_i[s2][4]; h2a5=h2a_i[s2][5]; h2a6=h2a_i[s2][6]; h2a7=h2a_i[s2][7];
            h2bc=h2b_i[s2][3];
        end else begin
            h2a0=h2a_q[s2][0]; h2a1=h2a_q[s2][1]; h2a2=h2a_q[s2][2]; h2a3=h2a_q[s2][3];
            h2a4=h2a_q[s2][4]; h2a5=h2a_q[s2][5]; h2a6=h2a_q[s2][6]; h2a7=h2a_q[s2][7];
            h2bc=h2b_q[s2][3];
        end
    end

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            cic_count<=0; hb1_phase<=0; hb2_phase<=0;
            hb1_busy<=0; hb2_busy<=0; hb1_stream<=0; hb2_stream<=0;
            hb1_wait<=0; hb2_wait<=0;
            iq_out_i<=0; iq_out_q<=0; iq_valid<=0;
            for (ch=0; ch<4; ch=ch+1) begin
                int_i1[ch]<=0; int_i2[ch]<=0; int_i3[ch]<=0;
                int_q1[ch]<=0; int_q2[ch]<=0; int_q3[ch]<=0;
                comb_i1_z[ch]<=0; comb_i2_z[ch]<=0; comb_i3_z[ch]<=0;
                comb_q1_z[ch]<=0; comb_q2_z[ch]<=0; comb_q3_z[ch]<=0;
                hb1_hold_i[ch]<=0; hb1_hold_q[ch]<=0;
                h1bc_snap_i[ch]<=0; h1bc_snap_q[ch]<=0;
                for (tap=0; tap<6; tap=tap+1) begin h1a_i[ch][tap]<=0; h1a_q[ch][tap]<=0; end
                for (tap=0; tap<3; tap=tap+1) begin h1b_i[ch][tap]<=0; h1b_q[ch][tap]<=0; end
                for (tap=0; tap<8; tap=tap+1) begin h2a_i[ch][tap]<=0; h2a_q[ch][tap]<=0; end
                for (tap=0; tap<4; tap=tap+1) begin h2b_i[ch][tap]<=0; h2b_q[ch][tap]<=0; end
            end
        end else begin
            iq_valid<=0;
            for (ch=0; ch<4; ch=ch+1) begin
                int_i1[ch]<=int_i1[ch]+(iq_in_i[ch]?14'sd1:-14'sd1);
                int_i2[ch]<=int_i2[ch]+int_i1[ch]; int_i3[ch]<=int_i3[ch]+int_i2[ch];
                int_q1[ch]<=int_q1[ch]+(iq_in_q[ch]?14'sd1:-14'sd1);
                int_q2[ch]<=int_q2[ch]+int_q1[ch]; int_q3[ch]<=int_q3[ch]+int_q2[ch];
            end

            if (cic_count==CIC_LAST) begin
                cic_count<=0; hb1_phase<=~hb1_phase;
                for (ch=0; ch<4; ch=ch+1) begin
                    comb_i1_z[ch]<=int_i3[ch]; comb_i2_z[ch]<=ci1[ch]; comb_i3_z[ch]<=ci2[ch];
                    comb_q1_z[ch]<=int_q3[ch]; comb_q2_z[ch]<=cq1[ch]; comb_q3_z[ch]<=cq2[ch];
                    if (hb1_phase) begin
                        // phase-A insert (this is the MAC sample): even-lag line.
                        // Snapshot the centre tap now (pre any shift) so the paced
                        // 24-clock HB1 burst is immune to the next phase-B shift.
                        h1bc_snap_i[ch]<=h1b_i[ch][2]; h1bc_snap_q[ch]<=h1b_q[ch][2];
                        for (tap=5; tap>0; tap=tap-1) begin
                            h1a_i[ch][tap]<=h1a_i[ch][tap-1]; h1a_q[ch][tap]<=h1a_q[ch][tap-1];
                        end
                        h1a_i[ch][0]<=ci8[ch]; h1a_q[ch][0]<=cq8[ch];
                    end else begin
                        // phase-B insert: centre line
                        for (tap=2; tap>0; tap=tap-1) begin
                            h1b_i[ch][tap]<=h1b_i[ch][tap-1]; h1b_q[ch][tap]<=h1b_q[ch][tap-1];
                        end
                        h1b_i[ch][0]<=ci8[ch]; h1b_q[ch][0]<=cq8[ch];
                    end
                end
                if (hb1_phase) begin hb1_busy<=1; hb1_stream<=0; hb1_wait<=0; end
            end else cic_count<=cic_count+1'b1;

            if (hb1_busy) begin
                if (!hb1_mac_ready) begin
                    hb1_wait <= hb1_wait + 1'b1;  // let HB1 MAC settle
                end else begin
                    hb1_wait <= 0;
                    store_hb1_result();

                    if (hb1_stream_last) begin
                        hb1_busy <= 0;
                        hb2_phase <= ~hb2_phase;
                        insert_hb2_frame(hb2_phase);

                        if (hb2_phase) begin
                            hb2_busy <= 1;
                            hb2_stream <= 0;
                            hb2_wait <= 0;
                        end
                    end else begin
                        hb1_stream <= hb1_stream + 1'b1;
                    end
                end
            end

            if (hb2_busy) begin
                if (!hb2_mac_ready) begin
                    hb2_wait <= hb2_wait + 1'b1;  // let HB2 MAC settle
                end else begin
                    hb2_wait <= 0;
                    store_hb2_result();

                    if (hb2_stream_last) begin
                        hb2_busy <= 0;
                        iq_valid <= 4'hf;
                    end else begin
                        hb2_stream <= hb2_stream + 1'b1;
                    end
                end
            end
        end
    end
endmodule
