// Four-channel fixed-rate sigma-delta decimator:
// 32 MS/s -> CIC-3 /16 -> half-band /2 -> half-band /2 -> 500 kS/s.
`timescale 1ns/100ps
module sd_decimator_hb (
    input wire clk_32m, input wire rst_n,
    input wire [3:0] iq_in_i, input wire [3:0] iq_in_q,
    output reg [31:0] iq_out_i, output reg [31:0] iq_out_q,
    output reg [3:0] iq_valid
);
    integer ch, tap;
    reg [3:0] cic_count;
    reg hb1_phase, hb2_phase;
    reg signed [15:0] int_i1[0:3], int_i2[0:3], int_i3[0:3];
    reg signed [15:0] int_q1[0:3], int_q2[0:3], int_q3[0:3];
    reg signed [15:0] comb_i1_z[0:3], comb_i2_z[0:3], comb_i3_z[0:3];
    reg signed [15:0] comb_q1_z[0:3], comb_q2_z[0:3], comb_q3_z[0:3];
    reg signed [7:0] hb1_i_z[0:3][0:9], hb1_q_z[0:3][0:9];
    reg signed [7:0] hb2_i_z[0:3][0:13], hb2_q_z[0:3][0:13];
    reg signed [15:0] ci1[0:3], ci2[0:3], ci3[0:3];
    reg signed [15:0] cq1[0:3], cq2[0:3], cq3[0:3];
    reg signed [15:0] cis[0:3], cqs[0:3];
    reg signed [7:0] ci8[0:3], cq8[0:3], h1i8[0:3], h1q8[0:3];
    reg signed [7:0] h2i8[0:3], h2q8[0:3];
    reg signed [19:0] h1ia[0:3], h1qa[0:3], h2ia[0:3], h2qa[0:3];
    reg signed [19:0] h1is[0:3], h1qs[0:3], h2is[0:3], h2qs[0:3];

    function signed [7:0] sat16(input signed [15:0] v);
        if (v > 127) sat16=127; else if (v < -128) sat16=-128; else sat16=v[7:0];
    endfunction
    function signed [7:0] sat20(input signed [19:0] v);
        if (v > 127) sat20=127; else if (v < -128) sat20=-128; else sat20=v[7:0];
    endfunction

    always @(*) begin
        for (ch=0; ch<4; ch=ch+1) begin
            ci1[ch]=int_i3[ch]-comb_i1_z[ch]; ci2[ch]=ci1[ch]-comb_i2_z[ch];
            ci3[ch]=ci2[ch]-comb_i3_z[ch]; cq1[ch]=int_q3[ch]-comb_q1_z[ch];
            cq2[ch]=cq1[ch]-comb_q2_z[ch]; cq3[ch]=cq2[ch]-comb_q3_z[ch];
            // CIC gain is 16^3. Dividing by 32 maps full scale to int8.
            cis[ch]=(ci3[ch]+16)>>>5; cqs[ch]=(cq3[ch]+16)>>>5;
            ci8[ch]=sat16(cis[ch]); cq8[ch]=sat16(cqs[ch]);
            // HB1 Q10: [19,0,-73,0,312,512,312,0,-73,0,19].
            h1ia[ch]=19*($signed(ci8[ch])+$signed(hb1_i_z[ch][9]))
                    -73*($signed(hb1_i_z[ch][1])+$signed(hb1_i_z[ch][7]))
                    +312*($signed(hb1_i_z[ch][3])+$signed(hb1_i_z[ch][5]))
                    +512*$signed(hb1_i_z[ch][4]);
            h1qa[ch]=19*($signed(cq8[ch])+$signed(hb1_q_z[ch][9]))
                    -73*($signed(hb1_q_z[ch][1])+$signed(hb1_q_z[ch][7]))
                    +312*($signed(hb1_q_z[ch][3])+$signed(hb1_q_z[ch][5]))
                    +512*$signed(hb1_q_z[ch][4]);
            h1is[ch]=(h1ia[ch]+512)>>>10; h1qs[ch]=(h1qa[ch]+512)>>>10;
            h1i8[ch]=sat20(h1is[ch]); h1q8[ch]=sat20(h1qs[ch]);
            // HB2 Q10: [-27,0,45,0,-96,0,321,512,321,0,-96,0,45,0,-27].
            h2ia[ch]=-27*($signed(h1i8[ch])+$signed(hb2_i_z[ch][13]))
                    +45*($signed(hb2_i_z[ch][1])+$signed(hb2_i_z[ch][11]))
                    -96*($signed(hb2_i_z[ch][3])+$signed(hb2_i_z[ch][9]))
                    +321*($signed(hb2_i_z[ch][5])+$signed(hb2_i_z[ch][7]))
                    +512*$signed(hb2_i_z[ch][6]);
            h2qa[ch]=-27*($signed(h1q8[ch])+$signed(hb2_q_z[ch][13]))
                    +45*($signed(hb2_q_z[ch][1])+$signed(hb2_q_z[ch][11]))
                    -96*($signed(hb2_q_z[ch][3])+$signed(hb2_q_z[ch][9]))
                    +321*($signed(hb2_q_z[ch][5])+$signed(hb2_q_z[ch][7]))
                    +512*$signed(hb2_q_z[ch][6]);
            h2is[ch]=(h2ia[ch]+512)>>>10; h2qs[ch]=(h2qa[ch]+512)>>>10;
            h2i8[ch]=sat20(h2is[ch]); h2q8[ch]=sat20(h2qs[ch]);
        end
    end

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            cic_count<=0; hb1_phase<=0; hb2_phase<=0;
            iq_out_i<=0; iq_out_q<=0; iq_valid<=0;
            for (ch=0; ch<4; ch=ch+1) begin
                int_i1[ch]<=0; int_i2[ch]<=0; int_i3[ch]<=0;
                int_q1[ch]<=0; int_q2[ch]<=0; int_q3[ch]<=0;
                comb_i1_z[ch]<=0; comb_i2_z[ch]<=0; comb_i3_z[ch]<=0;
                comb_q1_z[ch]<=0; comb_q2_z[ch]<=0; comb_q3_z[ch]<=0;
                for (tap=0; tap<10; tap=tap+1) begin
                    hb1_i_z[ch][tap]<=0; hb1_q_z[ch][tap]<=0;
                end
                for (tap=0; tap<14; tap=tap+1) begin
                    hb2_i_z[ch][tap]<=0; hb2_q_z[ch][tap]<=0;
                end
            end
        end else begin
            iq_valid<=0;
            for (ch=0; ch<4; ch=ch+1) begin
                int_i1[ch]<=int_i1[ch]+(iq_in_i[ch]?16'sd1:-16'sd1);
                int_i2[ch]<=int_i2[ch]+int_i1[ch]; int_i3[ch]<=int_i3[ch]+int_i2[ch];
                int_q1[ch]<=int_q1[ch]+(iq_in_q[ch]?16'sd1:-16'sd1);
                int_q2[ch]<=int_q2[ch]+int_q1[ch]; int_q3[ch]<=int_q3[ch]+int_q2[ch];
            end
            if (cic_count==15) begin
                cic_count<=0; hb1_phase<=~hb1_phase;
                for (ch=0; ch<4; ch=ch+1) begin
                    comb_i1_z[ch]<=int_i3[ch]; comb_i2_z[ch]<=ci1[ch]; comb_i3_z[ch]<=ci2[ch];
                    comb_q1_z[ch]<=int_q3[ch]; comb_q2_z[ch]<=cq1[ch]; comb_q3_z[ch]<=cq2[ch];
                    for (tap=9; tap>0; tap=tap-1) begin
                        hb1_i_z[ch][tap]<=hb1_i_z[ch][tap-1];
                        hb1_q_z[ch][tap]<=hb1_q_z[ch][tap-1];
                    end
                    hb1_i_z[ch][0]<=ci8[ch]; hb1_q_z[ch][0]<=cq8[ch];
                end
                if (hb1_phase) begin
                    hb2_phase<=~hb2_phase;
                    for (ch=0; ch<4; ch=ch+1) begin
                        for (tap=13; tap>0; tap=tap-1) begin
                            hb2_i_z[ch][tap]<=hb2_i_z[ch][tap-1];
                            hb2_q_z[ch][tap]<=hb2_q_z[ch][tap-1];
                        end
                        hb2_i_z[ch][0]<=h1i8[ch]; hb2_q_z[ch][0]<=h1q8[ch];
                    end
                    if (hb2_phase) begin
                        for (ch=0; ch<4; ch=ch+1) begin
                            iq_out_i[ch*8+:8]<=h2i8[ch]; iq_out_q[ch*8+:8]<=h2q8[ch];
                        end
                        iq_valid<=4'hf;
                    end
                end
            end else cic_count<=cic_count+1'b1;
        end
    end
endmodule
