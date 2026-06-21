// X-injection experiment for the no-reset-delay-line decimator variant.
// dut = sd_decimator_hb_poly_nordl: delay-line flops are NOT reset, so in sim they
// power up as X (CIC integrators, combs, FSM, counters and iq_valid keep reset).
// ref = sd_decimator_hb_poly: identical but delay lines reset to 0.
//
// Measures three things the reset-removal decision hinges on:
//   1. iq_valid / control must be identical and never X (X confined to datapath).
//   2. How many output samples carry X before the delay lines self-flush.
//   3. Once X-free, the datapath must match the reset reference bit-exactly.
`timescale 1ns/100ps
module tb_hb_nordl_xinj;
    reg clk_32m, rst_n;
    reg [3:0] iq_in_i, iq_in_q;
    reg [31:0] lfsr;
    wire [31:0] ref_i, ref_q, dut_i, dut_q;
    wire [3:0] ref_valid, dut_valid;
    integer cycles, out_idx, x_out_count, last_x_out, first_clean;

    always #1 clk_32m=~clk_32m;

    sd_decimator_hb_poly       refm (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i),.iq_in_q(iq_in_q),
        .iq_out_i(ref_i),.iq_out_q(ref_q),.iq_valid(ref_valid));
    sd_decimator_hb_poly_nordl dut  (.clk_32m(clk_32m),.rst_n(rst_n),.iq_in_i(iq_in_i),.iq_in_q(iq_in_q),
        .iq_out_i(dut_i),.iq_out_q(dut_q),.iq_valid(dut_valid));

    initial begin
        clk_32m=0; rst_n=0; iq_in_i=0; iq_in_q=0;
        lfsr=32'h1aceb00c; cycles=0; out_idx=0; x_out_count=0; last_x_out=-1; first_clean=-1;
        repeat(8) @(posedge clk_32m); rst_n=1;
        repeat(24000) @(posedge clk_32m);
        $display("=== nordl X-injection result ===");
        $display("  total outputs            : %0d", out_idx);
        $display("  outputs containing X     : %0d", x_out_count);
        $display("  last X-bearing output idx: %0d", last_x_out);
        $display("  first all-clean output   : %0d  (== flush length in samples)", first_clean);
        if (last_x_out >= 0 && first_clean > last_x_out)
            $display("tb_hb_nordl_xinj: PASS  (control X-free, datapath flushed at sample %0d, then bit-exact)", first_clean);
        else if (x_out_count==0)
            $display("tb_hb_nordl_xinj: PASS  (no X ever observed)");
        else
            $fatal(1,"X did not cleanly flush (last_x_out=%0d first_clean=%0d)",last_x_out,first_clean);
        $finish;
    end

    always @(negedge clk_32m) if (rst_n) begin
        lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        iq_in_i=lfsr[3:0]; iq_in_q=lfsr[11:8];
    end

    always @(posedge clk_32m) if (rst_n) begin
        cycles=cycles+1;
        // (1) control safety: valid must match ref exactly and never be X.
        if (^dut_valid === 1'bx) $fatal(1,"iq_valid went X at cycle %0d",cycles);
        if (ref_valid !== dut_valid) $fatal(1,"iq_valid diverged cycle %0d: ref=%h dut=%h",cycles,ref_valid,dut_valid);

        if (dut_valid==4'hf) begin
            if ((^{dut_i,dut_q}) === 1'bx) begin
                // (2) datapath still carries X
                x_out_count = x_out_count+1;
                last_x_out  = out_idx;
            end else begin
                // (3) clean output: must equal the reset reference
                if (first_clean<0 && out_idx>last_x_out) first_clean=out_idx;
                if (out_idx>last_x_out && (dut_i!==ref_i || dut_q!==ref_q))
                    $fatal(1,"post-flush mismatch out %0d: ref=%h_%h dut=%h_%h",out_idx,ref_i,ref_q,dut_i,dut_q);
            end
            out_idx=out_idx+1;
        end
    end
endmodule
