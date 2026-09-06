`timescale 1ns/1ps
`default_nettype none

module tb_axi_inj_replay;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg [7:0] awaddr = 0, araddr = 0;
    reg [2:0] awprot = 0, arprot = 0;
    reg awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg [31:0] wdata = 0;
    reg [3:0] wstrb = 4'hf;
    wire awready, wready, bvalid, arready, rvalid;
    wire [1:0] bresp, rresp;
    wire [31:0] rdata;
    wire inj_en, inj_valid;
    wire signed [7:0] i0,q0,i1,q1,i2,q2,i3,q3;
    integer seen = 0, errors = 0;

    axi_inj_ctrl #(.CAPTURE_ADDR_W(4)) dut (
      .s_axi_aclk(clk), .s_axi_aresetn(rst_n), .s_axi_awaddr(awaddr), .s_axi_awprot(awprot),
      .s_axi_awvalid(awvalid), .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
      .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
      .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid),
      .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
      .s_axi_rready(rready), .inj_en(inj_en), .inj_valid(inj_valid), .inj_i0(i0), .inj_q0(q0),
      .inj_i1(i1), .inj_q1(q1), .inj_i2(i2), .inj_q2(q2), .inj_i3(i3), .inj_q3(q3));

    task wr(input [7:0] a, input [31:0] d);
      begin
        @(negedge clk); awaddr=a; wdata=d; awvalid=1; wvalid=1;
        while (!(awready && wready)) @(posedge clk);
        @(negedge clk); awvalid=0; wvalid=0;
        while (!bvalid) @(posedge clk);
      end
    endtask

    always @(posedge clk) if (inj_valid) begin
        seen = seen + 1;
        if (i0 !== 8'sd39 || q0 !== -8'sd12 || i1 !== 8'sd39 || q1 !== -8'sd12) begin
            $display("replay sample %0d got {%0d,%0d,%0d,%0d}", seen, i0,q0,i1,q1);
            errors = errors + 1;
        end
    end

    initial begin
      repeat (3) @(posedge clk); rst_n=1;
      // Upload three identical {I,Q} samples, unity default coefficients/noise.
      wr(8'h14, 0); wr(8'h18, {16'd0,8'sd40,-8'sd12});
      wr(8'h18, {16'd0,8'sd40,-8'sd12});
      wr(8'h18, {16'd0,8'sd40,-8'sd12});
      wr(8'h1c, 3); wr(8'h20, 1);
      repeat (210) @(posedge clk);
      if (seen != 3 || errors != 0 || dut.replay_active !== 0 || dut.replay_done !== 1) begin
        $display("TB FAIL seen=%0d errors=%0d active=%b done=%b", seen, errors, dut.replay_active, dut.replay_done);
      end else $display("TB PASS replay: 3 paced samples, unity transform, done");
      $finish;
    end
endmodule
`default_nettype wire
