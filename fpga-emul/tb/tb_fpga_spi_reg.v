// tb_fpga_spi_reg.v
// Smoke test (run under Verilator) for fpga_dsp_wrap (which now instantiates trouper_top.v
// directly). Confirms the wrapper's wiring is sound: host-SPI register access
// reaches trouper_top's reg_bank through the wrapper's host_cs/spi_sck/
// spi_mosi/spi_miso ports, and the PSRAM model cosim still elaborates and
// runs cleanly.
//
// This does not re-test spi_slave/reg_bank/GRP-arbiter correctness in depth —
// that's covered directly against trouper_top.v in
// rtl-test/tb/tb_trouper_spi.v and rtl-test/tb/tb_trouper_grp_arb.v. This test
// only proves the FPGA wrapper's pass-through wiring is correct.

`timescale 1ns/1ps
`default_nettype none

module tb_fpga_spi_reg;

    reg clk = 1'b0;
    always #15.625 clk = ~clk;        // 32 MHz

    reg rst_n = 1'b0;

    reg  [3:0] hw_iq_i = 4'h0, hw_iq_q = 4'h0;
    wire       remod_i, remod_q;

    reg  host_cs   = 1'b1;            // active low
    reg  spi_sck   = 1'b0;
    reg  spi_mosi  = 1'b0;
    wire spi_miso;
    wire irq;

    fpga_dsp_wrap dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .hw_iq_i   (hw_iq_i),
        .hw_iq_q   (hw_iq_q),
        .inj_en    (1'b0),
        .inj_valid (1'b0),
        .inj_i0 (8'sd0), .inj_q0 (8'sd0),
        .inj_i1 (8'sd0), .inj_q1 (8'sd0),
        .inj_i2 (8'sd0), .inj_q2 (8'sd0),
        .inj_i3 (8'sd0), .inj_q3 (8'sd0),
        .remod_i   (remod_i),
        .remod_q   (remod_q),
        .spi_sel      (1'b0),          // internal master path (this test)
        .host_cs   (host_cs),
        .spi_sck   (spi_sck),
        .spi_mosi  (spi_mosi),
        .spi_miso  (spi_miso),
        .ext_host_cs  (1'b0),
        .ext_spi_sck  (1'b0),
        .ext_spi_mosi (1'b0),
        .ext_spi_miso (),
        .irq       (irq),
        .ext_irq      ()
    );

    // ---- SPI master model (Mode 0, MSB first) ----
    localparam real SCK_HALF = 62.5;  // 8 MHz

    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = tx[b];
                #(SCK_HALF);
                spi_sck = 1'b1;
                rx = {rx[6:0], spi_miso};
                #(SCK_HALF);
                spi_sck = 1'b0;
            end
        end
    endtask

    task spi_start;  begin host_cs = 1'b0; #(SCK_HALF); end endtask
    task spi_stop;   begin #(SCK_HALF); host_cs = 1'b1; #500; end endtask

    task spi_write(input [6:0] a, input [7:0] d);
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b0, a}, dump);
            spi_byte(d, dump);
            spi_stop;
        end
    endtask

    task spi_read(input [6:0] a, output [7:0] d);
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b1, a}, dump);
            spi_byte(8'h00, d);
            spi_stop;
        end
    endtask

    integer errors = 0;
    task check(input [255:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-24s got 0x%02h expected 0x%02h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-24s 0x%02h", name, got);
            end
        end
    endtask

    reg [7:0] rd;

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);

        // CHIP_ID / CHIP_REV reads through the wrapper -> trouper_top -> reg_bank
        spi_read(7'h00, rd); check("CHIP_ID",  rd, 8'hA7);
        spi_read(7'h01, rd); check("CHIP_REV", rd, 8'h01);

        // Write + readback through the wrapper
        spi_write(7'h09, 8'h0A);
        spi_read (7'h09, rd); check("SF_CFG wr/rd", rd, 8'h0A);
        spi_write(7'h09, 8'h07);   // restore

        if (errors == 0) $display("\nTB PASS — fpga_dsp_wrap SPI pass-through OK");
        else             $display("\nTB FAIL — %0d error(s)", errors);
        $finish;
    end

    initial begin
        #500_000;
        $display("TB FAIL — timeout");
        $finish;
    end

endmodule
`default_nettype wire
