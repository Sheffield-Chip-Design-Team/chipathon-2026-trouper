// tb_decimator_poly_equiv.v
// Bit-exact equivalence check: original sd_decimator_poly_ref vs the paced+
// pipelined sd_decimator_poly.  Both DUTs get the SAME 1-bit IQ stimulus, so
// their output SAMPLE SEQUENCES must be identical (the pipelined DUT is only
// delayed in time).  We index each DUT's outputs by an independent sample
// counter and compare ref[k] vs new[k] for every k.  Any mismatch = the
// pipelining changed the arithmetic.  PASS requires >= MIN_SAMPLES compared.
`timescale 1ns/1ps
module tb_decimator_poly_equiv;
    reg clk = 0, rst_n = 0;
    reg [3:0] iqi = 0, iqq = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    // Reference (original)
    wire [31:0] r_i, r_q; wire [3:0] r_v;
    sd_decimator_poly_ref u_ref (
        .clk_32m(clk), .rst_n(rst_n), .iq_in_i(iqi), .iq_in_q(iqq),
        .iq_out_i(r_i), .iq_out_q(r_q), .iq_valid(r_v));

    // DUT (paced + pipelined)
    wire [31:0] n_i, n_q; wire [3:0] n_v;
    sd_decimator_poly u_dut (
        .clk_32m(clk), .rst_n(rst_n), .iq_in_i(iqi), .iq_in_q(iqq),
        .iq_out_i(n_i), .iq_out_q(n_q), .iq_valid(n_v));

    localparam integer N = 8192;          // sample-buffer depth
    reg [31:0] ri_buf[0:N-1], rq_buf[0:N-1];
    reg [31:0] ni_buf[0:N-1], nq_buf[0:N-1];
    integer rk = 0, nk = 0;               // independent sample counters

    // Capture each DUT's outputs on its own iq_valid.
    always @(posedge clk) if (rst_n && r_v==4'hf) begin
        if (rk<N) begin ri_buf[rk]=r_i; rq_buf[rk]=r_q; end rk=rk+1;
    end
    always @(posedge clk) if (rst_n && n_v==4'hf) begin
        if (nk<N) begin ni_buf[nk]=n_i; nq_buf[nk]=n_q; end nk=nk+1;
    end

    // Pseudo-random 1-bit IQ (LFSR), one fresh nibble per clock.
    reg [31:0] lfsr = 32'hACE12345;
    always @(posedge clk) begin
        lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
        iqi  <= lfsr[3:0];
        iqq  <= lfsr[7:4];
    end

    integer k, cmp, bad;
    localparam integer MIN_SAMPLES = 1000;
    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1;
        repeat (300000) @(posedge clk);   // ~4600 output samples
        // Compare overlapping sample indices.
        cmp = (rk<nk)?rk:nk; if (cmp>N) cmp=N;
        bad = 0;
        for (k=0; k<cmp; k=k+1) begin
            if (ri_buf[k]!==ni_buf[k] || rq_buf[k]!==nq_buf[k]) begin
                if (bad<10) $display("MISMATCH[%0d] ref=(%h,%h) dut=(%h,%h)",
                    k, ri_buf[k], rq_buf[k], ni_buf[k], nq_buf[k]);
                bad = bad+1;
            end
        end
        $display("ref_samples=%0d dut_samples=%0d compared=%0d mismatches=%0d",
                 rk, nk, cmp, bad);
        if (cmp < MIN_SAMPLES)
            $display("EQUIV: FAIL (too few samples: %0d < %0d)", cmp, MIN_SAMPLES);
        else if (bad==0)
            $display("EQUIV: PASS (%0d samples bit-identical)", cmp);
        else
            $display("EQUIV: FAIL (%0d/%0d samples differ)", bad, cmp);
        $finish;
    end
endmodule
