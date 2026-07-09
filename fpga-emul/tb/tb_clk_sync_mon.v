// tb_clk_sync_mon.v
// Self-checking testbench for axi_clk_sync_mon. Drives dsp_clk plus three
// measured "CLK_OUT" inputs and checks the toggle-count classification:
//   ch0 = locked (same 32 MHz, fixed phase)   -> expect 0 toggles
//   ch2 = locked (same 32 MHz, other phase)    -> expect 0 toggles, other level
//   ch1 = NOT locked (different frequency)     -> expect >> 0 toggles
// Run under Vivado xsim (xvlog/xelab/xsim).
`timescale 1ns/1ps
`default_nettype none

module tb_clk_sync_mon;
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    // dsp_clk: use an integer period (32 ns, half 16) so the sim has no
    // fractional-time surprises. Only lock/unlock relative to the measured
    // clocks matters for this test, not the exact frequency.
    always #16 clk = ~clk;

    // Measured clocks. Offsets keep the sampled level away from the clk edge so
    // locked channels sample a STABLE value (0 toggles); ch1 runs at a different
    // period so it drifts and toggles.
    reg ch0 = 1'b0, ch1 = 1'b0, ch2 = 1'b1;
    initial begin #5;  forever #16 ch0 = ~ch0; end    // period 32 = locked, +5 ns
    initial begin #3;  forever #17 ch1 = ~ch1; end    // period 34 -> NOT locked
    initial begin #13; forever #16 ch2 = ~ch2; end    // period 32 = locked, +13 ns

    // AXI-Lite master signals
    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg wvalid;   wire wready;  reg [3:0] wstrb;
    wire [1:0]  bresp;   wire bvalid;  reg bready;
    reg  [7:0]  araddr;  reg arvalid;  wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;

    axi_clk_sync_mon #(.WIN_DEFAULT(25)) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .clk_meas({ch2, ch1, ch0})
    );

    // Proper AXI-Lite master: drop each valid the cycle its ready is seen, so
    // the DUT can't re-latch a phantom duplicate transaction after it accepts.
    reg aw_ack, w_ack;
    task axi_write(input [7:0] addr, input [31:0] data);
    begin
        @(posedge clk);
        awaddr <= addr; awvalid <= 1'b1; wdata <= data; wvalid <= 1'b1;
        wstrb <= 4'hF; bready <= 1'b1;
        aw_ack = 1'b0; w_ack = 1'b0;
        while (!(aw_ack && w_ack)) begin
            @(posedge clk);
            if (awready) begin awvalid <= 1'b0; aw_ack = 1'b1; end
            if (wready)  begin wvalid  <= 1'b0; w_ack  = 1'b1; end
        end
        while (!bvalid) @(posedge clk);
        @(posedge clk); bready <= 1'b0;
    end
    endtask

    task axi_read(input [7:0] addr, output [31:0] data);
    begin
        @(posedge clk);
        araddr <= addr; arvalid <= 1'b1; rready <= 1'b1;
        while (!arready) @(posedge clk);
        arvalid <= 1'b0;                 // accepted
        while (!rvalid) @(posedge clk);
        data = rdata;                    // combinational rdata valid with rvalid
        @(posedge clk); rready <= 1'b0;
    end
    endtask

    integer errors = 0;
    reg [31:0] st, t0, t1, t2;

    initial begin
        awvalid=0; wvalid=0; bready=0; arvalid=0; rready=0; wstrb=0;
        awaddr=0; wdata=0; araddr=0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // Short window for sim: 2^8 = 256 dsp_clk cycles.
        axi_write(8'h08, 32'd8);
        // One-shot: ARM (bit0), not continuous.
        axi_write(8'h00, 32'h0000_0001);

        // Poll STATUS.DONE
        st = 0;
        while (st[0] == 1'b0) begin
            axi_read(8'h04, st);
        end

        axi_read(8'h10, t0);
        axi_read(8'h14, t1);
        axi_read(8'h18, t2);

        $display("STATUS=0x%08x  levels=%b", st, st[10:8]);
        $display("TOGGLES: ch0(F3, locked)=%0d  ch1(D3, UNLOCKED)=%0d  ch2(C15, locked)=%0d",
                 t0, t1, t2);

        if (t0 !== 32'd0) begin errors=errors+1; $display("FAIL: ch0 should be locked (0 toggles), got %0d", t0); end
        if (t2 !== 32'd0) begin errors=errors+1; $display("FAIL: ch2 should be locked (0 toggles), got %0d", t2); end
        if (t1 <= 32'd4)  begin errors=errors+1; $display("FAIL: ch1 should be unlocked (>>0 toggles), got %0d", t1); end

        if (errors == 0)
            $display("\nTB PASS - clk_sync_mon classifies locked vs unlocked correctly");
        else
            $display("\nTB FAIL - %0d error(s)", errors);
        $finish;
    end

    // Watchdog
    initial begin #200000; $display("TB TIMEOUT"); $finish; end
endmodule
`default_nettype wire
