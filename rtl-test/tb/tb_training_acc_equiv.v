// tb_training_acc_equiv.v
// Bit-exact equivalence: original training_acc_ref (32-step, single mult + p_latch)
// vs the dual-multiplier + paced training_acc.  Both get identical stimulus and
// must produce identical final Z accumulators / n_acc.  The paced DUT completes
// later (3x longer bursts); we drive past both training_done and compare.
`timescale 1ns/1ps
module tb_training_acc_equiv;
    reg clk = 0, rst_n = 0;
    always #15.625 clk = ~clk;   // 32 MHz

    reg        iq_valid = 0;
    reg signed [7:0] ri0,ri1,ri2,ri3, rq0,rq1,rq2,rq3;
    reg        sc_lock = 0;
    reg [31:0] timing_ref = 32'd0;
    reg [3:0]  sf = 4'd2;            // window = 1<<(2+0+3) = 32 samples
    reg [1:0]  sample_shift = 2'd0;

    // outputs
    wire signed [31:0] rZpi0,rZpq0,rZpi1,rZpq1,rZpi2,rZpq2,rZpi3,rZpq3,rZpi4,rZpq4,rZpi5,rZpq5;
    wire [31:0] rZd0,rZd1,rZd2,rZd3; wire rdone; wire [17:0] rnacc;
    wire signed [31:0] nZpi0,nZpq0,nZpi1,nZpq1,nZpi2,nZpq2,nZpi3,nZpq3,nZpi4,nZpq4,nZpi5,nZpq5;
    wire [31:0] nZd0,nZd1,nZd2,nZd3; wire ndone; wire [17:0] nnacc;

    training_acc_ref u_ref (
        .clk(clk),.rst_n(rst_n),.iq_valid(iq_valid),
        .raw_i0(ri0),.raw_i1(ri1),.raw_i2(ri2),.raw_i3(ri3),
        .raw_q0(rq0),.raw_q1(rq1),.raw_q2(rq2),.raw_q3(rq3),
        .sc_lock(sc_lock),.timing_ref(timing_ref),.sf(sf),.sample_shift(sample_shift),.noise_trig(1'b0),
        .Zpair_i0(rZpi0),.Zpair_q0(rZpq0),.Zpair_i1(rZpi1),.Zpair_q1(rZpq1),
        .Zpair_i2(rZpi2),.Zpair_q2(rZpq2),.Zpair_i3(rZpi3),.Zpair_q3(rZpq3),
        .Zpair_i4(rZpi4),.Zpair_q4(rZpq4),.Zpair_i5(rZpi5),.Zpair_q5(rZpq5),
        .Zdiag_0(rZd0),.Zdiag_1(rZd1),.Zdiag_2(rZd2),.Zdiag_3(rZd3),
        .training_done(rdone),.n_acc(rnacc),.training_armed());

    training_acc u_dut (
        .clk(clk),.rst_n(rst_n),.iq_valid(iq_valid),
        .raw_i0(ri0),.raw_i1(ri1),.raw_i2(ri2),.raw_i3(ri3),
        .raw_q0(rq0),.raw_q1(rq1),.raw_q2(rq2),.raw_q3(rq3),
        .sc_lock(sc_lock),.timing_ref(timing_ref),.sf(sf),.sample_shift(sample_shift),.noise_trig(1'b0),
        .Zpair_i0(nZpi0),.Zpair_q0(nZpq0),.Zpair_i1(nZpi1),.Zpair_q1(nZpq1),
        .Zpair_i2(nZpi2),.Zpair_q2(nZpq2),.Zpair_i3(nZpi3),.Zpair_q3(nZpq3),
        .Zpair_i4(nZpi4),.Zpair_q4(nZpq4),.Zpair_i5(nZpi5),.Zpair_q5(nZpq5),
        .Zdiag_0(nZd0),.Zdiag_1(nZd1),.Zdiag_2(nZd2),.Zdiag_3(nZd3),
        .training_done(ndone),.n_acc(nnacc),.training_armed());

    reg [31:0] lfsr = 32'h1357BD13;
    function [7:0] nxt; input dummy; begin
        lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]}; nxt = lfsr[7:0];
    end endfunction

    integer s, bad;
    initial begin
        repeat (6) @(posedge clk);
        rst_n = 1;
        sc_lock = 1;                       // arm immediately: window = samples [0,31]
        @(posedge clk);
        // 40 samples, one iq_valid pulse every 64 clocks
        for (s = 0; s < 40; s = s+1) begin
            ri0=nxt(0); rq0=nxt(0); ri1=nxt(0); rq1=nxt(0);
            ri2=nxt(0); rq2=nxt(0); ri3=nxt(0); rq3=nxt(0);
            iq_valid = 1; @(posedge clk); iq_valid = 0;
            repeat (63) @(posedge clk);
        end
        // both should be done by now
        bad = 0;
        if (rnacc !== nnacc) begin $display("MISMATCH n_acc ref=%0d dut=%0d", rnacc, nnacc); bad=bad+1; end
        if (rdone !== ndone) begin $display("MISMATCH done ref=%b dut=%b", rdone, ndone); bad=bad+1; end
        `define CK(r,n,nm) if (r!==n) begin $display("MISMATCH %s ref=%h dut=%h", nm, r, n); bad=bad+1; end
        `CK(rZpi0,nZpi0,"Zpi0") `CK(rZpq0,nZpq0,"Zpq0") `CK(rZpi1,nZpi1,"Zpi1") `CK(rZpq1,nZpq1,"Zpq1")
        `CK(rZpi2,nZpi2,"Zpi2") `CK(rZpq2,nZpq2,"Zpq2") `CK(rZpi3,nZpi3,"Zpi3") `CK(rZpq3,nZpq3,"Zpq3")
        `CK(rZpi4,nZpi4,"Zpi4") `CK(rZpq4,nZpq4,"Zpq4") `CK(rZpi5,nZpi5,"Zpi5") `CK(rZpq5,nZpq5,"Zpq5")
        `CK(rZd0,nZd0,"Zd0") `CK(rZd1,nZd1,"Zd1") `CK(rZd2,nZd2,"Zd2") `CK(rZd3,nZd3,"Zd3")
        $display("n_acc=%0d done ref=%b dut=%b", rnacc, rdone, ndone);
        if (rdone && bad==0) $display("TACC_EQUIV: PASS (all Z accumulators bit-identical)");
        else $display("TACC_EQUIV: FAIL (%0d mismatches, ref_done=%b)", bad, rdone);
        $finish;
    end
endmodule
