`timescale 1ns/100ps
module tb_decimator_hb_equiv;
    reg clk_32m, rst_n;
    reg [3:0] iq_in_i, iq_in_q;
    reg [31:0] lfsr;
    wire [31:0] par_i, par_q, tdm_i, tdm_q;
    wire [3:0] par_valid, tdm_valid;
    reg [63:0] expected [0:255];
    integer wr_ptr, rd_ptr, cycles;

    always #1 clk_32m=~clk_32m;
    sd_decimator_hb par (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i),.iq_in_q(iq_in_q),
        .iq_out_i(par_i),.iq_out_q(par_q),.iq_valid(par_valid));
    sd_decimator_hb_tdm tdm (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i),.iq_in_q(iq_in_q),
        .iq_out_i(tdm_i),.iq_out_q(tdm_q),.iq_valid(tdm_valid));

    initial begin
        clk_32m=0; rst_n=0; iq_in_i=0; iq_in_q=0;
        lfsr=32'h1aceb00c; wr_ptr=0; rd_ptr=0; cycles=0;
        repeat(8) @(posedge clk_32m); rst_n=1;
        repeat(12288) @(posedge clk_32m);
        if(rd_ptr<150) $fatal(1,"too few compared outputs: %0d",rd_ptr);
        if(rd_ptr!=wr_ptr) $fatal(1,"unconsumed reference outputs: rd=%0d wr=%0d",rd_ptr,wr_ptr);
        $display("tb_decimator_hb_equiv: PASS (%0d exact packed outputs)",rd_ptr);
        $finish;
    end

    always @(negedge clk_32m) if(rst_n) begin
        lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        iq_in_i=lfsr[3:0]; iq_in_q=lfsr[11:8];
    end

    always @(posedge clk_32m) if(rst_n) begin
        cycles=cycles+1;
        if(par_valid==4'hf) begin expected[wr_ptr]={par_i,par_q}; wr_ptr=wr_ptr+1; end
        if(tdm_valid==4'hf) begin
            if(rd_ptr>=wr_ptr) $fatal(1,"TDM output preceded reference at cycle %0d",cycles);
            if({tdm_i,tdm_q}!==expected[rd_ptr])
                $fatal(1,"mismatch sample %0d: par=%h tdm=%h",rd_ptr,expected[rd_ptr],{tdm_i,tdm_q});
            rd_ptr=rd_ptr+1;
        end
    end
endmodule
