// tb_trouper_grp_arb.v
// Register-bus arbitration testbench for trouper_top: Grouper inter-chip bus
// (GRP_*) vs. host SPI slave. trouper_top.v grants GRP priority whenever
// GRP_WE|GRP_RE is asserted (see the "Register bus arbiter" comment block
// around line 597) — this is bus-activity priority, not a config bit.
//
// Exercises:
//   1. GRP write while SPI idle lands in reg_bank (read back over SPI)
//   2. SPI write while GRP idle still works (baseline regression)
//   3. GRP write overlapping a concurrent SPI write to a different address:
//      GRP's value must land; the colliding SPI write must NOT corrupt it
//   4. GRP read pulse overlapping a concurrent SPI read: SPI must still
//      shift out data for ITS OWN requested address afterwards, and must
//      not get permanently wedged by the contention
//   5. Bus returns to normal SPI-only operation after contention clears
//
// Run (from rtl-test/):
//   iverilog -g2005 -o tb_trouper_grp_arb.vvp tb/tb_trouper_grp_arb.v \
//     ../src/top/trouper_top.v ../src/decimator/sd_decimator_poly.v \
//     ../src/frontend/dc_removal.v ../src/frontend/sc_detector.v \
//     ../src/combiner/training_acc.v ../src/control/packet_ctrl_fsm.v \
//     ../src/control/psram_buf_ctrl.v ../src/combiner/mrc_combiner.v \
//     ../src/remod/sd_remod.v ../src/control/spi_slave.v ../src/control/reg_bank.v
//   vvp tb_trouper_grp_arb.vvp

`timescale 1ns/1ps
`default_nettype none

module tb_trouper_grp_arb;

    // ---- Clocks / reset ----
    reg clk = 1'b0;
    always #15.625 clk = ~clk;        // 32 MHz

    reg resetb = 1'b0;

    // ---- DUT pads ----
    reg  [3:0] iq_i = 4'h0, iq_q = 4'h0;
    wire       remod_i, remod_q;
    wire       psram_sck, psram_ce_n;
    wire [3:0] psram_sio_out, psram_sio_oe;
    reg  [3:0] psram_sio_in = 4'h0;

    reg  spi_cs   = 1'b1;             // active low
    reg  spi_sck  = 1'b0;
    reg  spi_mosi = 1'b0;
    wire spi_miso;

    reg  [7:0] grp_addr  = 8'h00;
    reg  [7:0] grp_wdata = 8'h00;
    reg        grp_we    = 1'b0;
    reg        grp_re    = 1'b0;
    wire [7:0] grp_rdata;
    wire       grp_ready;

    wire irq_out, irq_grouper;

    trouper_top dut (
        .IQ_CLK      (clk),
        .RESETB      (resetb),
        .IQ_DATA_I   (iq_i),
        .IQ_DATA_Q   (iq_q),
        .REMOD_A_I   (remod_i),
        .REMOD_A_Q   (remod_q),
        .PSRAM_SCK   (psram_sck),
        .PSRAM_CE_N  (psram_ce_n),
        .PSRAM_SIO_OUT(psram_sio_out),
        .PSRAM_SIO_IN(psram_sio_in),
        .PSRAM_SIO_OE(psram_sio_oe),
        .HOST_CS     (spi_cs),
        .SPI_SCK     (spi_sck),
        .SPI_MOSI    (spi_mosi),
        .SPI_MISO    (spi_miso),
        .GRP_ADDR    (grp_addr),
        .GRP_WDATA   (grp_wdata),
        .GRP_WE      (grp_we),
        .GRP_RE      (grp_re),
        .GRP_RDATA   (grp_rdata),
        .GRP_READY   (grp_ready),
        .IRQ_OUT     (irq_out),
        .IRQ_GROUPER (irq_grouper)
    );

    // ---- SPI master model (Mode 0, MSB first) ----
    localparam real SCK_HALF = 62.5;  // 8 MHz

    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = tx[b];
                #(SCK_HALF);
                spi_sck = 1'b1;       // slave shifts in; master samples MISO
                rx = {rx[6:0], spi_miso};
                #(SCK_HALF);
                spi_sck = 1'b0;       // slave shifts out next MISO bit
            end
        end
    endtask

    task spi_start;  begin spi_cs = 1'b0; #(SCK_HALF); end endtask
    task spi_stop;   begin #(SCK_HALF); spi_cs = 1'b1; #500; end endtask

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

    // ---- GRP bus driver: single-cycle strobe held across a ce_16m edge ----
    // reg_bank's write port is CE-gated (16 MHz effective); hold WE/ADDR/WDATA
    // for 4 clk_32m cycles (2 full ce_16m periods) to guarantee capture.
    task grp_write(input [7:0] a, input [7:0] d);
        begin
            @(posedge clk);
            grp_addr = a; grp_wdata = d; grp_we = 1'b1;
            repeat (4) @(posedge clk);
            grp_we = 1'b0;
            @(posedge clk);
        end
    endtask

    task grp_read_pulse(input [7:0] a, input integer hold_cycles);
        begin
            @(posedge clk);
            grp_addr = a; grp_re = 1'b1;
            repeat (hold_cycles) @(posedge clk);
            grp_re = 1'b0;
        end
    endtask

    // ---- Scoreboard ----
    integer errors = 0;

    task check(input [351:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-40s got 0x%02h expected 0x%02h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-40s 0x%02h", name, got);
            end
        end
    endtask

    // ---- Test sequence ----
    reg [7:0] rd;
    // SF_CFG (0x09) and MIMO_CTRL (0x08) are convenient RW scratch registers.
    localparam [6:0] ADDR_SF   = 7'h09;  // reset 0x07
    localparam [6:0] ADDR_MIMO = 7'h08;  // reset 0xF0 (only bits[7:4]/[0] wired)

    initial begin
        $dumpfile("tb_trouper_grp_arb.vcd");
        $dumpvars(1, tb_trouper_grp_arb);

        repeat (4) @(posedge clk);
        resetb = 1'b1;
        repeat (8) @(posedge clk);

        // ---- 1. GRP-only write lands, read back over SPI ----
        grp_write(ADDR_SF, 8'h0A);
        spi_read(ADDR_SF, rd); check("1. GRP write -> SPI readback", rd, 8'h0A);
        grp_write(ADDR_SF, 8'h07);   // restore

        // ---- 2. SPI-only write still works with GRP idle (baseline) ----
        spi_write(ADDR_SF, 8'h0C);
        spi_read(ADDR_SF, rd); check("2. SPI write baseline", rd, 8'h0C);
        spi_write(ADDR_SF, 8'h07);   // restore

        // ---- 3. Contention: SPI write to ADDR_SF racing a GRP write to
        //         ADDR_MIMO. GRP must win for its own address; the SPI write
        //         collision must not corrupt GRP's value.               ----
        fork
            begin
                spi_write(ADDR_SF, 8'h0E);
            end
            begin
                // Delay so the GRP write's CE-latching window overlaps the
                // SPI byte-shift (SPI frame is ~16 SCK periods = 2000 ns).
                #700;
                grp_write(ADDR_MIMO, 8'hF1);
            end
        join

        spi_read(ADDR_MIMO, rd); check("3a. GRP write survives SPI collision", rd, 8'hF1);
        grp_write(ADDR_MIMO, 8'hF0);   // restore

        // ---- 4. Read-side contention: GRP read pulse overlapping an SPI
        //         read frame. After contention, SPI must still return ITS
        //         own requested register correctly (no permanent wedge).  ----
        spi_write(ADDR_SF, 8'h0B);      // distinct known value to detect corruption
        fork
            begin
                spi_read(ADDR_SF, rd);
            end
            begin
                #700;
                grp_read_pulse(ADDR_MIMO, 2);
            end
        join
        check("4a. SPI read survives GRP read collision", rd, 8'h0B);

        // ---- 5. Bus returns to normal SPI-only operation post-contention ----
        spi_write(ADDR_SF, 8'h07);      // restore
        spi_read(ADDR_SF, rd); check("5. post-contention SPI still works", rd, 8'h07);
        spi_read(ADDR_MIMO, rd); check("5. MIMO_CTRL restored", rd, 8'hF0);

        if (errors == 0) $display("\nTB PASS — all GRP/SPI arbitration checks passed");
        else             $display("\nTB FAIL — %0d error(s)", errors);
        $finish;
    end

    // Global timeout
    initial begin
        #2_000_000;
        $display("TB FAIL — timeout");
        $finish;
    end

endmodule

`default_nettype wire
