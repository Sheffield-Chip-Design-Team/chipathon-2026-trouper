`timescale 1ns/100ps
module tb_decimator_hb_tdm;
    reg clk_32m, rst_n;
    reg [3:0] iq_in_i, iq_in_q;
    wire [31:0] iq_out_i, iq_out_q; wire [3:0] iq_valid;
    integer cycle, outputs, last_cycle, i0, q0;
    always #1 clk_32m=~clk_32m;
    sd_decimator_hb_tdm dut (.*);
    initial begin
        clk_32m=0; rst_n=0; iq_in_i=4'hf; iq_in_q=0;
        cycle=0; outputs=0; last_cycle=-1; i0=0; q0=0;
        repeat(8) @(posedge clk_32m); rst_n=1;
        repeat(4096) @(posedge clk_32m);
        if(outputs<40) $fatal(1,"too few outputs: %0d",outputs);
        if(i0<110 || q0>-110) $fatal(1,"bad settled DC: I=%0d Q=%0d",i0,q0);
        $display("tb_decimator_hb_tdm: PASS (%0d outputs, I=%0d Q=%0d)",outputs,i0,q0);
        $finish;
    end
    always @(posedge clk_32m) if(rst_n) begin
        cycle=cycle+1;
        if(iq_valid!=0 && iq_valid!=4'hf) $fatal(1,"non-atomic valid");
        if(iq_valid==4'hf) begin
            if(last_cycle>=0 && cycle-last_cycle!=64) $fatal(1,"bad cadence");
            last_cycle=cycle; outputs=outputs+1;
            i0=$signed(iq_out_i[7:0]); q0=$signed(iq_out_q[7:0]);
            if(iq_out_i[7:0]!==iq_out_i[15:8] || iq_out_i[7:0]!==iq_out_i[23:16] ||
               iq_out_i[7:0]!==iq_out_i[31:24] || iq_out_q[7:0]!==iq_out_q[15:8] ||
               iq_out_q[7:0]!==iq_out_q[23:16] || iq_out_q[7:0]!==iq_out_q[31:24])
                $fatal(1,"channels differ");
            if($isunknown({iq_out_i,iq_out_q})) $fatal(1,"unknown output");
        end
    end
endmodule
