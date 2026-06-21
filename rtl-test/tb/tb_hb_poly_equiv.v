// Bit-exact equivalence: sd_decimator_hb_poly (14-bit CIC) vs sd_decimator_hb_tdm
// (16-bit reference). Identical scheduling/latency, so outputs must match every
// cycle. Stimulus mixes LFSR noise with sustained all-ones / all-zeros bursts to
// drive the CIC comb output to the +/-4096 full-scale corner that separates a
// (wrong) 13-bit trim from the (correct) 14-bit trim.
`timescale 1ns/100ps
module tb_hb_poly_equiv;
    reg clk_32m, rst_n;
    reg [3:0] iq_in_i, iq_in_q;
    reg [31:0] lfsr;
    wire [31:0] ref_i, ref_q, dut_i, dut_q;
    wire [3:0] ref_valid, dut_valid;
    integer cycles, checks, phase;

    always #1 clk_32m=~clk_32m;

    sd_decimator_hb_tdm refm (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i),.iq_in_q(iq_in_q),
        .iq_out_i(ref_i),.iq_out_q(ref_q),.iq_valid(ref_valid));
    sd_decimator_hb_poly dut (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i),.iq_in_q(iq_in_q),
        .iq_out_i(dut_i),.iq_out_q(dut_q),.iq_valid(dut_valid));

    initial begin
        clk_32m=0; rst_n=0; iq_in_i=0; iq_in_q=0;
        lfsr=32'h1aceb00c; cycles=0; checks=0;
        repeat(8) @(posedge clk_32m); rst_n=1;
        repeat(20000) @(posedge clk_32m);
        if (checks<150) $fatal(1,"too few compared outputs: %0d",checks);
        $display("tb_hb_poly_equiv: PASS (%0d exact packed outputs, %0d cycles)",checks,cycles);
        $finish;
    end

    // Stimulus: alternate LFSR noise, sustained full-scale +1, and full-scale 0.
    always @(negedge clk_32m) if (rst_n) begin
        lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        phase = (cycles/200) % 3;
        case (phase)
            0: begin iq_in_i=lfsr[3:0];  iq_in_q=lfsr[11:8]; end // noise
            1: begin iq_in_i=4'hf;       iq_in_q=4'hf;       end // sustained +1 -> +4096
            default: begin iq_in_i=4'h0; iq_in_q=4'h0;       end // sustained -1 -> -4096
        endcase
    end

    always @(posedge clk_32m) if (rst_n) begin
        cycles=cycles+1;
        if (ref_valid!==dut_valid)
            $fatal(1,"valid mismatch cycle %0d: ref=%h dut=%h",cycles,ref_valid,dut_valid);
        if (ref_valid==4'hf) begin
            if (ref_i!==dut_i || ref_q!==dut_q)
                $fatal(1,"output mismatch #%0d cycle %0d: ref=%h_%h dut=%h_%h",
                       checks,cycles,ref_i,ref_q,dut_i,dut_q);
            checks=checks+1;
        end
    end
endmodule
