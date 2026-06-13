// tb_sd_decimator_cic_tdm8.v
// Functional check of sd_decimator_cic_tdm8 against sd_decimator_cic_only (R=128).
//
// Same 1st-order SD bitstream drives all 4 TDM branches and the reference.
// Phase 1: DC at 0.5 FS   -> reference should settle near +64; rate = 32M/128
// Phase 2: 30 kHz sine, 0.7 FS -> amplitude/shape comparison
//
// Checks:
//   - tdm iq_valid interval (expect 128 clk)
//   - reference iq_valid interval (expect 128 clk)
//   - output amplitude vs reference
//   - all 4 TDM output bytes identical (same input on all branches)
//   - Stage A frame overwrites (frame_valid already set when bank rewritten)

`timescale 1ns/100ps

module tb_sd_decimator_cic_tdm8;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #15.625 clk = ~clk;   // 32 MHz

    // ---------------- SD modulator (1st order, error feedback) -------------
    real x_in, sd_acc;
    reg  sd_bit;
    integer cyc;

    localparam real PI = 3.141592653589793;
    localparam integer PHASE1_CYC = 400000;   // DC phase
    localparam integer PHASE2_CYC = 400000;   // sine phase

    always @(posedge clk) begin
        if (!rst_n) begin
            sd_acc <= 0.0;
            sd_bit <= 1'b0;
            cyc    <= 0;
        end else begin
            cyc <= cyc + 1;
            if (cyc < PHASE1_CYC)
                x_in = 0.5;
            else
                x_in = 0.7 * $sin(2.0*PI*30.0e3 * (cyc / 32.0e6));
            if (sd_acc >= 0.0) begin
                sd_bit <= 1'b1;
                sd_acc <= sd_acc + x_in - 1.0;
            end else begin
                sd_bit <= 1'b0;
                sd_acc <= sd_acc + x_in + 1.0;
            end
        end
    end

    // ---------------- DUT: TDM8 -------------------------------------------
    wire [31:0] tdm_out_i, tdm_out_q;
    wire [3:0]  tdm_valid;

    sd_decimator_cic_tdm8 dut (
        .clk_32m (clk),
        .rst_n   (rst_n),
        .iq_in_i ({4{sd_bit}}),
        .iq_in_q ({4{sd_bit}}),
        .iq_out_i(tdm_out_i),
        .iq_out_q(tdm_out_q),
        .iq_valid(tdm_valid)
    );

    // ---------------- Reference: cic_only @ R=128 --------------------------
    wire signed [7:0] ref_out_i, ref_out_q;
    wire ref_valid;

    sd_decimator_cic_only u_ref (
        .clk_32m    (clk),
        .clk_16m    (clk),
        .rst_n      (rst_n),
        .iq_in_i    (sd_bit),
        .iq_in_q    (sd_bit),
        .decim_ratio(2'b01),       // R=128, norm_shift=14
        .iq_out_i   (ref_out_i),
        .iq_out_q   (ref_out_q),
        .iq_valid   (ref_valid)
    );

    // ---------------- Monitors ---------------------------------------------
    integer tdm_count = 0,  ref_count = 0;
    integer tdm_last = -1,  ref_last = -1;
    integer tdm_int_min = 1<<30, tdm_int_max = 0;
    integer ref_int_min = 1<<30, ref_int_max = 0;
    integer tdm_absmax_p1 = 0, tdm_absmax_p2 = 0;
    integer ref_absmax_p1 = 0, ref_absmax_p2 = 0;
    integer byte_mismatch = 0;
    integer overwrites = 0;
    integer itv;
    integer b0, b1, b2, b3, av, rv;
    reg ref_valid_d = 1'b0;

    function integer iabs; input integer v; iabs = (v < 0) ? -v : v; endfunction
    function integer sx8; input [7:0] b; sx8 = b[7] ? (b - 256) : b; endfunction

    always @(posedge clk) if (rst_n) begin
        // TDM output
        if (tdm_valid != 4'd0) begin
            if (tdm_last >= 0) begin
                itv = cyc - tdm_last;
                if (itv < tdm_int_min) tdm_int_min = itv;
                if (itv > tdm_int_max) tdm_int_max = itv;
            end
            tdm_last = cyc;
            tdm_count = tdm_count + 1;
            b0 = sx8(tdm_out_i[7:0]);
            b1 = sx8(tdm_out_i[15:8]);
            b2 = sx8(tdm_out_i[23:16]);
            b3 = sx8(tdm_out_i[31:24]);
            if (b0 !== b1 || b0 !== b2 || b0 !== b3)
                byte_mismatch = byte_mismatch + 1;
            av = iabs(b0);
            if (cyc < PHASE1_CYC) begin
                if (av > tdm_absmax_p1) tdm_absmax_p1 = av;
            end else begin
                if (av > tdm_absmax_p2) tdm_absmax_p2 = av;
            end
            if (tdm_count % 200 == 0 || tdm_count < 8)
                $display("TDM  n=%0d cyc=%0d i_b0=%0d (b3..b0 = %0d %0d %0d %0d)",
                         tdm_count, cyc, b0, b3, b2, b1, b0);
        end
        // reference output (valid is 2 cycles wide -> edge detect)
        ref_valid_d <= ref_valid;
        if (ref_valid && !ref_valid_d) begin
            if (ref_last >= 0) begin
                itv = cyc - ref_last;
                if (itv < ref_int_min) ref_int_min = itv;
                if (itv > ref_int_max) ref_int_max = itv;
            end
            ref_last = cyc;
            ref_count = ref_count + 1;
            rv = iabs(ref_out_i);
            if (cyc < PHASE1_CYC) begin
                if (rv > ref_absmax_p1) ref_absmax_p1 = rv;
            end else begin
                if (rv > ref_absmax_p2) ref_absmax_p2 = rv;
            end
            if (ref_count % 200 == 0 || ref_count < 8)
                $display("REF  n=%0d cyc=%0d i=%0d", ref_count, cyc, ref_out_i);
        end
        // Stage A overwrite detect: bank rewritten while its frame_valid still set
        if (dut.box_cnt == 2'd3 && dut.frame_valid[dut.wr_bank])
            overwrites = overwrites + 1;
    end

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        wait (cyc >= PHASE1_CYC + PHASE2_CYC);
        $display("");
        $display("==== SUMMARY ====");
        $display("cycles simulated        : %0d", cyc);
        $display("TDM  valids             : %0d (interval min/max = %0d/%0d)",
                 tdm_count, tdm_int_min, tdm_int_max);
        $display("REF  valids             : %0d (interval min/max = %0d/%0d)",
                 ref_count, ref_int_min, ref_int_max);
        $display("expected valids @ R=128 : %0d", (PHASE1_CYC+PHASE2_CYC)/128);
        $display("TDM  |i| max  DC / sine : %0d / %0d", tdm_absmax_p1, tdm_absmax_p2);
        $display("REF  |i| max  DC / sine : %0d / %0d", ref_absmax_p1, ref_absmax_p2);
        $display("TDM byte mismatches     : %0d", byte_mismatch);
        $display("Stage A frame overwrites: %0d", overwrites);
        $finish;
    end

endmodule
