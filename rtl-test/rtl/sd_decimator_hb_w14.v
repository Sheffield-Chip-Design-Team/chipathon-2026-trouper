// Area-reduction variant of sd_decimator_hb_tdm: CIC integrator/comb words
// trimmed 16 -> 14 bits (candidate #3 in planning/decimator-hb-area-reduction.md).
// 14 bits is the provably-exact minimum: a sustained full-scale (+1) 1-bit input
// drives the CIC-3 R=16 comb output to +16^3 = +4096 = 2^12, which needs 14-bit
// signed (13-bit signed would wrap at +4095 and diverge from the 16-bit golden).
// Everything else is byte-for-byte identical to sd_decimator_hb_tdm so the packed
// outputs are bit-exact.
`timescale 1ns/100ps
module sd_decimator_hb_w14 (
    input wire clk_32m, input wire rst_n,
    input wire [3:0] iq_in_i, input wire [3:0] iq_in_q,
    output reg [31:0] iq_out_i, output reg [31:0] iq_out_q,
    output reg [3:0] iq_valid
);
    integer ch, tap;
    reg [3:0] cic_count;
    reg hb1_phase, hb2_phase;
    reg hb1_busy, hb2_busy;
    reg [2:0] hb1_stream, hb2_stream;

    reg signed [13:0] int_i1[0:3], int_i2[0:3], int_i3[0:3];
    reg signed [13:0] int_q1[0:3], int_q2[0:3], int_q3[0:3];
    reg signed [13:0] comb_i1_z[0:3], comb_i2_z[0:3], comb_i3_z[0:3];
    reg signed [13:0] comb_q1_z[0:3], comb_q2_z[0:3], comb_q3_z[0:3];
    reg signed [7:0] hb1_i_z[0:3][0:10], hb1_q_z[0:3][0:10];
    reg signed [7:0] hb2_i_z[0:3][0:14], hb2_q_z[0:3][0:14];
    reg signed [7:0] hb1_hold_i[0:3], hb1_hold_q[0:3];

    reg signed [13:0] ci1[0:3], ci2[0:3], ci3[0:3];
    reg signed [13:0] cq1[0:3], cq2[0:3], cq3[0:3];
    reg signed [13:0] cis[0:3], cqs[0:3];
    reg signed [7:0] ci8[0:3], cq8[0:3];

    reg signed [7:0] h1x0, h1x2, h1x4, h1x5, h1x6, h1x8, h1x10;
    reg signed [7:0] h2x0, h2x2, h2x4, h2x6, h2x7, h2x8, h2x10, h2x12, h2x14;
    reg signed [19:0] h1_acc, h2_acc, h1_scaled, h2_scaled;
    reg signed [7:0] h1_result, h2_result;

    function signed [7:0] sat14(input signed [13:0] v);
        if (v > 127) sat14=127; else if (v < -128) sat14=-128; else sat14=v[7:0];
    endfunction
    function signed [7:0] sat20(input signed [19:0] v);
        if (v > 127) sat20=127; else if (v < -128) sat20=-128; else sat20=v[7:0];
    endfunction

    always @(*) begin
        for (ch=0; ch<4; ch=ch+1) begin
            ci1[ch]=int_i3[ch]-comb_i1_z[ch]; ci2[ch]=ci1[ch]-comb_i2_z[ch];
            ci3[ch]=ci2[ch]-comb_i3_z[ch]; cq1[ch]=int_q3[ch]-comb_q1_z[ch];
            cq2[ch]=cq1[ch]-comb_q2_z[ch]; cq3[ch]=cq2[ch]-comb_q3_z[ch];
            cis[ch]=(ci3[ch]+16)>>>5; cqs[ch]=(cq3[ch]+16)>>>5;
            ci8[ch]=sat14(cis[ch]); cq8[ch]=sat14(cqs[ch]);
        end

        if (!hb1_stream[2]) begin
            h1x0=hb1_i_z[hb1_stream[1:0]][0]; h1x2=hb1_i_z[hb1_stream[1:0]][2];
            h1x4=hb1_i_z[hb1_stream[1:0]][4]; h1x5=hb1_i_z[hb1_stream[1:0]][5];
            h1x6=hb1_i_z[hb1_stream[1:0]][6]; h1x8=hb1_i_z[hb1_stream[1:0]][8];
            h1x10=hb1_i_z[hb1_stream[1:0]][10];
        end else begin
            h1x0=hb1_q_z[hb1_stream[1:0]][0]; h1x2=hb1_q_z[hb1_stream[1:0]][2];
            h1x4=hb1_q_z[hb1_stream[1:0]][4]; h1x5=hb1_q_z[hb1_stream[1:0]][5];
            h1x6=hb1_q_z[hb1_stream[1:0]][6]; h1x8=hb1_q_z[hb1_stream[1:0]][8];
            h1x10=hb1_q_z[hb1_stream[1:0]][10];
        end
        h1_acc=19*($signed(h1x0)+$signed(h1x10))
              -73*($signed(h1x2)+$signed(h1x8))
              +312*($signed(h1x4)+$signed(h1x6))+512*$signed(h1x5);
        h1_scaled=(h1_acc+512)>>>10;
        h1_result=sat20(h1_scaled);

        if (!hb2_stream[2]) begin
            h2x0=hb2_i_z[hb2_stream[1:0]][0]; h2x2=hb2_i_z[hb2_stream[1:0]][2];
            h2x4=hb2_i_z[hb2_stream[1:0]][4]; h2x6=hb2_i_z[hb2_stream[1:0]][6];
            h2x7=hb2_i_z[hb2_stream[1:0]][7]; h2x8=hb2_i_z[hb2_stream[1:0]][8];
            h2x10=hb2_i_z[hb2_stream[1:0]][10]; h2x12=hb2_i_z[hb2_stream[1:0]][12];
            h2x14=hb2_i_z[hb2_stream[1:0]][14];
        end else begin
            h2x0=hb2_q_z[hb2_stream[1:0]][0]; h2x2=hb2_q_z[hb2_stream[1:0]][2];
            h2x4=hb2_q_z[hb2_stream[1:0]][4]; h2x6=hb2_q_z[hb2_stream[1:0]][6];
            h2x7=hb2_q_z[hb2_stream[1:0]][7]; h2x8=hb2_q_z[hb2_stream[1:0]][8];
            h2x10=hb2_q_z[hb2_stream[1:0]][10]; h2x12=hb2_q_z[hb2_stream[1:0]][12];
            h2x14=hb2_q_z[hb2_stream[1:0]][14];
        end
        h2_acc=-27*($signed(h2x0)+$signed(h2x14))
              +45*($signed(h2x2)+$signed(h2x12))
              -96*($signed(h2x4)+$signed(h2x10))
              +321*($signed(h2x6)+$signed(h2x8))+512*$signed(h2x7);
        h2_scaled=(h2_acc+512)>>>10;
        h2_result=sat20(h2_scaled);
    end

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            cic_count<=0; hb1_phase<=0; hb2_phase<=0;
            hb1_busy<=0; hb2_busy<=0; hb1_stream<=0; hb2_stream<=0;
            iq_out_i<=0; iq_out_q<=0; iq_valid<=0;
            for (ch=0; ch<4; ch=ch+1) begin
                int_i1[ch]<=0; int_i2[ch]<=0; int_i3[ch]<=0;
                int_q1[ch]<=0; int_q2[ch]<=0; int_q3[ch]<=0;
                comb_i1_z[ch]<=0; comb_i2_z[ch]<=0; comb_i3_z[ch]<=0;
                comb_q1_z[ch]<=0; comb_q2_z[ch]<=0; comb_q3_z[ch]<=0;
                hb1_hold_i[ch]<=0; hb1_hold_q[ch]<=0;
                for (tap=0; tap<11; tap=tap+1) begin hb1_i_z[ch][tap]<=0; hb1_q_z[ch][tap]<=0; end
                for (tap=0; tap<15; tap=tap+1) begin hb2_i_z[ch][tap]<=0; hb2_q_z[ch][tap]<=0; end
            end
        end else begin
            iq_valid<=0;
            for (ch=0; ch<4; ch=ch+1) begin
                int_i1[ch]<=int_i1[ch]+(iq_in_i[ch]?14'sd1:-14'sd1);
                int_i2[ch]<=int_i2[ch]+int_i1[ch]; int_i3[ch]<=int_i3[ch]+int_i2[ch];
                int_q1[ch]<=int_q1[ch]+(iq_in_q[ch]?14'sd1:-14'sd1);
                int_q2[ch]<=int_q2[ch]+int_q1[ch]; int_q3[ch]<=int_q3[ch]+int_q2[ch];
            end

            if (cic_count==15) begin
                cic_count<=0; hb1_phase<=~hb1_phase;
                for (ch=0; ch<4; ch=ch+1) begin
                    comb_i1_z[ch]<=int_i3[ch]; comb_i2_z[ch]<=ci1[ch]; comb_i3_z[ch]<=ci2[ch];
                    comb_q1_z[ch]<=int_q3[ch]; comb_q2_z[ch]<=cq1[ch]; comb_q3_z[ch]<=cq2[ch];
                    for (tap=10; tap>0; tap=tap-1) begin
                        hb1_i_z[ch][tap]<=hb1_i_z[ch][tap-1]; hb1_q_z[ch][tap]<=hb1_q_z[ch][tap-1];
                    end
                    hb1_i_z[ch][0]<=ci8[ch]; hb1_q_z[ch][0]<=cq8[ch];
                end
                if (hb1_phase) begin hb1_busy<=1; hb1_stream<=0; end
            end else cic_count<=cic_count+1'b1;

            if (hb1_busy) begin
                if (!hb1_stream[2]) hb1_hold_i[hb1_stream[1:0]]<=h1_result;
                else hb1_hold_q[hb1_stream[1:0]]<=h1_result;
                if (hb1_stream==7) begin
                    hb1_busy<=0; hb2_phase<=~hb2_phase;
                    for (ch=0; ch<4; ch=ch+1) begin
                        for (tap=14; tap>0; tap=tap-1) begin
                            hb2_i_z[ch][tap]<=hb2_i_z[ch][tap-1]; hb2_q_z[ch][tap]<=hb2_q_z[ch][tap-1];
                        end
                        hb2_i_z[ch][0]<=hb1_hold_i[ch];
                        if (ch==3) hb2_q_z[ch][0]<=h1_result; else hb2_q_z[ch][0]<=hb1_hold_q[ch];
                    end
                    if (hb2_phase) begin hb2_busy<=1; hb2_stream<=0; end
                end else hb1_stream<=hb1_stream+1'b1;
            end

            if (hb2_busy) begin
                if (!hb2_stream[2]) iq_out_i[hb2_stream[1:0]*8+:8]<=h2_result;
                else iq_out_q[hb2_stream[1:0]*8+:8]<=h2_result;
                if (hb2_stream==7) begin hb2_busy<=0; iq_valid<=4'hf; end
                else hb2_stream<=hb2_stream+1'b1;
            end
        end
    end
endmodule
