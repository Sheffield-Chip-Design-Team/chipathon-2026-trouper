// tb_trouper_grp_arb.v
// Register-bus arbitration testbench for trouper_top: Grouper inter-chip bus
// (GRP_*) vs. host SPI slave. trouper_top.v grants GRP priority whenever
// GRP_WE|GRP_RE is asserted (see the "Register bus arbiter" comment block
// around line 597) — this is bus-activity priority, not a config bit.
//
// Exercises:
//   1. GRP write while SPI idle lands in reg_bank (read back over SPI)
//   2. SPI write while GRP idle still works (baseline regression)
//   3. A GRP write that covers the complete synchronized SPI write event:
//      GRP wins first and the pending SPI write is committed after GRP releases
//   4. GRP read overlapping the SPI MISO-load window: the colliding SPI read
//      byte is rejected/undefined by contract, and a retry after GRP_RE drops
//      must return the SPI-requested address
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
                .IQ_DATA_I_0 (iq_i[0]),
        .IQ_DATA_I_1 (iq_i[1]),
        .IQ_DATA_I_2 (iq_i[2]),
        .IQ_DATA_I_3 (iq_i[3]),
                .IQ_DATA_Q_0 (iq_q[0]),
        .IQ_DATA_Q_1 (iq_q[1]),
        .IQ_DATA_Q_2 (iq_q[2]),
        .IQ_DATA_Q_3 (iq_q[3]),
        .REMOD_A_I_OUT   (remod_i),
        .REMOD_A_Q_OUT   (remod_q),
        .PSRAM_SCK_OUT   (psram_sck),
        .PSRAM_CE_N_OUT  (psram_ce_n),
                .PSRAM_SIO_0_OUT (psram_sio_out[0]),
        .PSRAM_SIO_1_OUT (psram_sio_out[1]),
        .PSRAM_SIO_2_OUT (psram_sio_out[2]),
        .PSRAM_SIO_3_OUT (psram_sio_out[3]),
                .PSRAM_SIO_0_IN (psram_sio_in[0]),
        .PSRAM_SIO_1_IN (psram_sio_in[1]),
        .PSRAM_SIO_2_IN (psram_sio_in[2]),
        .PSRAM_SIO_3_IN (psram_sio_in[3]),
                .PSRAM_SIO_0_OE (psram_sio_oe[0]),
        .PSRAM_SIO_1_OE (psram_sio_oe[1]),
        .PSRAM_SIO_2_OE (psram_sio_oe[2]),
        .PSRAM_SIO_3_OE (psram_sio_oe[3]),
        .HOST_CS     (spi_cs),
        .SPI_SCK     (spi_sck),
        .SPI_MOSI    (spi_mosi),
        .SPI_MISO_OUT    (spi_miso),
                .GRP_ADDR_0 (grp_addr[0]),
        .GRP_ADDR_1 (grp_addr[1]),
        .GRP_ADDR_2 (grp_addr[2]),
        .GRP_ADDR_3 (grp_addr[3]),
        .GRP_ADDR_4 (grp_addr[4]),
        .GRP_ADDR_5 (grp_addr[5]),
        .GRP_ADDR_6 (grp_addr[6]),
        .GRP_ADDR_7 (grp_addr[7]),
                .GRP_WDATA_0 (grp_wdata[0]),
        .GRP_WDATA_1 (grp_wdata[1]),
        .GRP_WDATA_2 (grp_wdata[2]),
        .GRP_WDATA_3 (grp_wdata[3]),
        .GRP_WDATA_4 (grp_wdata[4]),
        .GRP_WDATA_5 (grp_wdata[5]),
        .GRP_WDATA_6 (grp_wdata[6]),
        .GRP_WDATA_7 (grp_wdata[7]),
        .GRP_WE      (grp_we),
        .GRP_RE      (grp_re),
                .GRP_RDATA_0 (grp_rdata[0]),
        .GRP_RDATA_1 (grp_rdata[1]),
        .GRP_RDATA_2 (grp_rdata[2]),
        .GRP_RDATA_3 (grp_rdata[3]),
        .GRP_RDATA_4 (grp_rdata[4]),
        .GRP_RDATA_5 (grp_rdata[5]),
        .GRP_RDATA_6 (grp_rdata[6]),
        .GRP_RDATA_7 (grp_rdata[7]),
        .GRP_READY   (grp_ready),
        // Grouper dev AHB-Lite endpoint: tied idle.  HTRANS must be driven
        // (HTRANS[1] is the adapter's request term); floating it would drive
        // ahb_we/ahb_re -- and hence grp_active -- to X.
        .HADDR         (8'd0),
        .HBURST        (3'd0),
        .HMASTLOCK     (1'b0),
        .HPROT         (4'd0),
        .HSIZE         (3'd0),
        .HTRANS        (2'd0),
        .HWDATA        (8'd0),
        .HWRITE        (1'b0),
        .HRDATA        (),
        .HREADY        (),
        .HRESP         (),
        .IRQ_OUT_OUT     (irq_out),
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

        // ---- 3. Contention: hold GRP_WE over the complete two-cycle
        //         synchronized SPI write strobe. Grouper takes the active
        //         register-bank slots; the one-entry arbiter pending slot must
        //         preserve and subsequently commit the SPI write.       ----
        fork
            begin
                spi_write(ADDR_SF, 8'h0E);
            end
            begin
                wait (dut.spi_reg_we === 1'b1);
                grp_addr = ADDR_MIMO; grp_wdata = 8'hF1; grp_we = 1'b1;
                repeat (8) @(posedge clk);
                grp_we = 1'b0;
            end
        join

        spi_read(ADDR_MIMO, rd); check("3a. GRP write survives SPI collision", rd, 8'hF1);
        spi_read(ADDR_SF,   rd); check("3b. pending SPI write preserved", rd, 8'h0E);
        grp_write(ADDR_MIMO, 8'hF0);   // restore

        // ---- 4. Read-side contention: this SPI wire protocol has no WAIT
        //         response. A GRP_RE overlapping the single shared read port
        //         therefore rejects that SPI byte by contract. Do not consume
        //         the colliding result; retry after GRP_RE deasserts.     ----
        spi_write(ADDR_SF, 8'h0B);      // distinct known value to detect corruption
        fork
            begin
                spi_read(ADDR_SF, rd);
            end
            begin
                // Cover the command's eighth rising edge and the following
                // falling edge where the SPI MISO shifter snapshots read data.
                #900;
                grp_read_pulse(ADDR_MIMO, 8);
            end
        join
        spi_read(ADDR_SF, rd);
        check("4a. rejected SPI read succeeds on retry", rd, 8'h0B);

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
