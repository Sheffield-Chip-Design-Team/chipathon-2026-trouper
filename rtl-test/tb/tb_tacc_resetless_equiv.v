// tb_tacc_resetless_equiv.v
// B2 verification: prove that making training_acc's Zpair_*/Zdiag_* resetless
// cannot change any output, by construction-independent-of-initial-state.
//
// Method (randomized-init differential / X-optimism-proof):
//   Two identical instances of the NEW (resetless-Z) training_acc, driven with
//   bit-identical stimulus. Before reset, DUT's Z flops are force-loaded with a
//   GARBAGE pattern (0xA5A5A5A5) and REF's with 0. If the async reset we removed
//   were load-bearing, the garbage would leak into a consumed output and the two
//   instances would diverge. We assert every output is identical on every clock
//   from the first arm onward, across TWO arm windows (multi-packet re-zero).
//
//   Garbage (not X) is the point: it propagates deterministically where a 4-state
//   X could get "lucky" through an X-optimistic operator, so this is strictly
//   stronger than relying on iverilog's default X-init.
`timescale 1ns/1ps

module tb_tacc_resetless_equiv;
    reg clk = 1'b0, rst_n = 1'b0, iq_valid = 1'b0, sc_lock = 1'b0, noise_trig = 1'b0;
    reg signed [7:0] ri0, ri1, ri2, ri3, rq0, rq1, rq2, rq3;
    reg [31:0] timing_ref = 32'd0;
    reg [3:0]  sf  = 4'd6;
    reg [1:0]  ss  = 2'd0;
    reg [3:0]  win = 4'd1;               // window = 1<<6 = 64 samples

    // DUT / REF output nets
    wire signed [31:0] d_i0,d_q0,d_i1,d_q1,d_i2,d_q2,d_i3,d_q3,d_i4,d_q4,d_i5,d_q5;
    wire        [31:0] d_d0,d_d1,d_d2,d_d3; wire d_done, d_armed; wire [17:0] d_nacc;
    wire signed [31:0] r_i0,r_q0,r_i1,r_q1,r_i2,r_q2,r_i3,r_q3,r_i4,r_q4,r_i5,r_q5;
    wire        [31:0] r_d0,r_d1,r_d2,r_d3; wire r_done, r_armed; wire [17:0] r_nacc;

    training_acc dut (
        .clk(clk), .rst_n(rst_n), .iq_valid(iq_valid),
        .raw_i0(ri0),.raw_i1(ri1),.raw_i2(ri2),.raw_i3(ri3),
        .raw_q0(rq0),.raw_q1(rq1),.raw_q2(rq2),.raw_q3(rq3),
        .sc_lock(sc_lock), .timing_ref(timing_ref), .sf(sf),
        .sample_shift(ss), .tacc_window_syms(win), .noise_trig(noise_trig),
        .Zpair_i0(d_i0),.Zpair_q0(d_q0),.Zpair_i1(d_i1),.Zpair_q1(d_q1),
        .Zpair_i2(d_i2),.Zpair_q2(d_q2),.Zpair_i3(d_i3),.Zpair_q3(d_q3),
        .Zpair_i4(d_i4),.Zpair_q4(d_q4),.Zpair_i5(d_i5),.Zpair_q5(d_q5),
        .Zdiag_0(d_d0),.Zdiag_1(d_d1),.Zdiag_2(d_d2),.Zdiag_3(d_d3),
        .training_done(d_done),.n_acc(d_nacc),.training_armed(d_armed));

    training_acc ref_ (
        .clk(clk), .rst_n(rst_n), .iq_valid(iq_valid),
        .raw_i0(ri0),.raw_i1(ri1),.raw_i2(ri2),.raw_i3(ri3),
        .raw_q0(rq0),.raw_q1(rq1),.raw_q2(rq2),.raw_q3(rq3),
        .sc_lock(sc_lock), .timing_ref(timing_ref), .sf(sf),
        .sample_shift(ss), .tacc_window_syms(win), .noise_trig(noise_trig),
        .Zpair_i0(r_i0),.Zpair_q0(r_q0),.Zpair_i1(r_i1),.Zpair_q1(r_q1),
        .Zpair_i2(r_i2),.Zpair_q2(r_q2),.Zpair_i3(r_i3),.Zpair_q3(r_q3),
        .Zpair_i4(r_i4),.Zpair_q4(r_q4),.Zpair_i5(r_i5),.Zpair_q5(r_q5),
        .Zdiag_0(r_d0),.Zdiag_1(r_d1),.Zdiag_2(r_d2),.Zdiag_3(r_d3),
        .training_done(r_done),.n_acc(r_nacc),.training_armed(r_armed));

    always #5 clk = ~clk;

    integer errors = 0;
    reg     armed_seen = 1'b0;

    // ---- Inject garbage into DUT's resetless Z flops; zeros into REF's ----
    localparam [31:0] G = 32'hA5A5A5A5;
    initial begin
        dut.Zpair_i0=G; dut.Zpair_q0=G; dut.Zpair_i1=G; dut.Zpair_q1=G;
        dut.Zpair_i2=G; dut.Zpair_q2=G; dut.Zpair_i3=G; dut.Zpair_q3=G;
        dut.Zpair_i4=G; dut.Zpair_q4=G; dut.Zpair_i5=G; dut.Zpair_q5=G;
        dut.Zdiag_0=G;  dut.Zdiag_1=G;  dut.Zdiag_2=G;  dut.Zdiag_3=G;
        ref_.Zpair_i0=0; ref_.Zpair_q0=0; ref_.Zpair_i1=0; ref_.Zpair_q1=0;
        ref_.Zpair_i2=0; ref_.Zpair_q2=0; ref_.Zpair_i3=0; ref_.Zpair_q3=0;
        ref_.Zpair_i4=0; ref_.Zpair_q4=0; ref_.Zpair_i5=0; ref_.Zpair_q5=0;
        ref_.Zdiag_0=0;  ref_.Zdiag_1=0;  ref_.Zdiag_2=0;  ref_.Zdiag_3=0;
    end

    // ---- Equality checker: active from the first arm onward ----
    wire [16*32+18:0] d_bus = {d_i0,d_q0,d_i1,d_q1,d_i2,d_q2,d_i3,d_q3,
                               d_i4,d_q4,d_i5,d_q5,d_d0,d_d1,d_d2,d_d3,d_done,d_nacc};
    wire [16*32+18:0] r_bus = {r_i0,r_q0,r_i1,r_q1,r_i2,r_q2,r_i3,r_q3,
                               r_i4,r_q4,r_i5,r_q5,r_d0,r_d1,r_d2,r_d3,r_done,r_nacc};
    always @(posedge clk) begin
        if (rst_n && (armed_seen || d_armed || r_armed)) begin
            armed_seen <= 1'b1;
            if (d_bus !== r_bus) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("  MISMATCH @%0t: garbage-init Z leaked to an output (dut!=ref)", $time);
            end
        end
    end

    // ---- Drive one sample (identical random IQ to both instances) ----
    task drive_sample; begin
        @(negedge clk);
        ri0=$random; ri1=$random; ri2=$random; ri3=$random;
        rq0=$random; rq1=$random; rq2=$random; rq3=$random;
        iq_valid = 1'b1;
        @(negedge clk); iq_valid = 1'b0;
        repeat (80) @(negedge clk);       // let paced 16-step TDM drain
    end endtask

    integer k;
    task run_window(input [31:0] start_ref); begin
        timing_ref = start_ref;
        @(negedge clk); sc_lock = 1'b1;   // arm on rising edge
        repeat (4) @(negedge clk);
        for (k = 0; k < 64; k = k + 1) drive_sample;  // full 64-sample window
        // wait for training_done on both
        repeat (200) @(negedge clk);
        if (!d_done || !r_done) begin
            errors = errors + 1;
            $display("  ERROR: training_done not reached (dut=%b ref=%b)", d_done, r_done);
        end
        sc_lock = 1'b0;                    // disarm
        repeat (20) @(negedge clk);
    end endtask

    initial begin
        rst_n = 1'b0;
        repeat (6) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        run_window(32'd0);    // packet 1: sample_count 0..63
        run_window(32'd64);   // packet 2: re-arm re-zero (multi-packet)

        if (errors == 0)
            $display("PASS: garbage-initialised resetless Z is output-equivalent to zero-init across 2 arms");
        else
            $display("FAIL: %0d mismatches -- removed reset WAS load-bearing", errors);
        $finish;
    end
endmodule
