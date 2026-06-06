`timescale 1ns/1ps
module tb_remod_decim_const;
    reg clk_32m;
    reg clk_16m;
    reg rst_n;
    always #15.625 clk_32m = ~clk_32m;
    always @(posedge clk_32m) clk_16m <= ~clk_16m;

    reg signed [7:0] in_i, in_q;
    reg in_valid;
    wire bit_i, bit_q;
    wire signed [7:0] out_i, out_q;
    wire out_valid;
    integer cycle;
    integer nout;
    integer ones_32m;

    sd_remod u_remod (
        .clk_32m(clk_32m), .rst_n(rst_n),
        .in_i(in_i), .in_q(in_q), .in_valid(in_valid), .en(1'b1),
        .out_i(bit_i), .out_q(bit_q)
    );

    sd_decimator u_decim (
        .clk_32m(clk_32m), .clk_16m(clk_16m), .rst_n(rst_n),
        .iq_in_i(bit_i), .iq_in_q(bit_q), .decim_ratio(2'd0),
        .iq_out_i(out_i), .iq_out_q(out_q), .iq_valid(out_valid)
    );

    always @(posedge clk_32m) begin
        if (rst_n) begin
            cycle <= cycle + 1;
            if (bit_i) ones_32m <= ones_32m + 1;
        end
    end

    initial begin
        clk_32m = 0; clk_16m = 0; rst_n = 0;
        in_i = 0; in_q = 0; in_valid = 0;
        cycle = 0; nout = 0; ones_32m = 0;
        repeat (8) @(posedge clk_32m);
        rst_n = 1'b1;
        repeat (8) @(posedge clk_32m);

        drive_const(-8'sd128, 600);
        reset_gap();
        drive_const(-8'sd90, 600);
        reset_gap();
        drive_const(8'sd0, 600);
        reset_gap();
        drive_const(8'sd90, 600);
        reset_gap();
        drive_const(8'sd100, 600);
        reset_gap();
        drive_const(8'sd110, 600);
        reset_gap();
        drive_const(8'sd120, 600);
        reset_gap();
        drive_const(8'sd127, 600);
        $finish;
    end

    task drive_const(input signed [7:0] v, input integer outputs);
        integer start_nout;
        begin
            $display("CONST_START v=%0d cycle=%0d", v, cycle);
            in_i = v; in_q = v; in_valid = 1'b1;
            @(posedge clk_32m);
            in_valid = 1'b0;
            start_nout = nout;
            while ((nout - start_nout) < outputs) begin
                @(posedge clk_32m);
            end
            $display("CONST_DONE v=%0d cycle=%0d nout=%0d ones_32m=%0d", v, cycle, nout - start_nout, ones_32m);
        end
    endtask

    task reset_gap;
        begin
            rst_n = 1'b0;
            repeat (8) @(posedge clk_32m);
            rst_n = 1'b1;
            in_i = 0; in_q = 0; in_valid = 0;
            cycle = 0; nout = 0; ones_32m = 0;
            repeat (8) @(posedge clk_32m);
        end
    endtask

    always @(posedge clk_16m) begin
        if (rst_n && out_valid) begin
            nout = nout + 1;
            if ((nout < 20) || (nout % 100 == 0)) begin
                $display("OUT n=%0d cycle=%0d in=%0d out_i=%0d out_q=%0d bit_i=%0b", nout, cycle, in_i, $signed(out_i), $signed(out_q), bit_i);
            end
        end
    end
endmodule
