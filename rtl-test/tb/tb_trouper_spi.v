// tb_trouper_spi.v
// Host-SPI register-access testbench for trouper_top (the tapeout top level).
//
// Exercises the 7-bit register map and the spi_slave frame logic per
// TRPR-SPS-002/006/009/010/011:
//   1. 2-byte read of CHIP_ID / CHIP_REV (read data must arrive in byte 1)
//   2. single write + readback (SF_CFG)
//   3. 16-byte burst write of the W shadow bank + 16-byte burst readback
//   4. burst auto-increment wrap (0x7E -> 0x7F -> 0x00 = CHIP_ID)
//   5. reserved/removed addresses read 0x00; write to 0x7F discarded
//   6. PSRAM_DBG_CTRL.DBG_BUSY reads 1 while qe_init_done=0
//   7. W1P self-clear: WGT_CTRL.W_COMMIT readback shows bit 0 low
//   8. COMB_CFG reset value 0x10 (REMOD_BACKOFF_SHIFT=1)
//
// SPI master model: Mode 0, MSB first, 8 MHz (under the 10 MHz max).
//
// Run:
//   iverilog -g2005 -o tb_trouper_spi.vvp tb/tb_trouper_spi.v rtl/trouper_top.v \
//     rtl/sd_decimator_cic_only.v rtl/dc_removal.v rtl/sc_detector.v \
//     rtl/training_acc.v rtl/packet_ctrl_fsm.v rtl/psram_buf_ctrl.v \
//     rtl/mrc_combiner.v rtl/sd_remod.v rtl/spi_slave.v rtl/reg_bank.v
//   vvp tb_trouper_spi.vvp

`timescale 1ns/1ps
`default_nettype none

module tb_trouper_spi;

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

    wire irq_out, irq_grouper;
    wire [7:0] grp_rdata;
    wire       grp_ready;

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
        .GRP_ADDR    (8'h00),
        .GRP_WDATA   (8'h00),
        .GRP_WE      (1'b0),
        .GRP_RE      (1'b0),
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

    // ---- Scoreboard ----
    integer errors = 0;

    task check(input [127:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-24s got 0x%02h expected 0x%02h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-24s 0x%02h", name, got);
            end
        end
    endtask

    // ---- Test sequence ----
    reg [7:0] rd, dump;
    integer i;

    initial begin
        $dumpfile("tb_trouper_spi.vcd");
        $dumpvars(1, tb_trouper_spi);

        repeat (4) @(posedge clk);
        resetb = 1'b1;
        repeat (8) @(posedge clk);

        // 1. CHIP_ID / CHIP_REV — 2-byte read frames (TRPR-SPS-006/009)
        spi_read(7'h00, rd); check("CHIP_ID",        rd, 8'hA7);
        spi_read(7'h01, rd); check("CHIP_REV",       rd, 8'h01);

        // 2. Write + readback: SF_CFG (reset 0x07 -> 0x0A)
        spi_read (7'h09, rd); check("SF_CFG reset",  rd, 8'h07);
        spi_write(7'h09, 8'h0A);
        spi_read (7'h09, rd); check("SF_CFG wr/rd",  rd, 8'h0A);
        spi_write(7'h09, 8'h07);

        // 3. Reset values: MIMO_CTRL 0xF0, COMB_CFG 0x10, gain shadow 0x3E
        spi_read(7'h08, rd); check("MIMO_CTRL reset", rd, 8'hF0);
        spi_read(7'h0F, rd); check("COMB_CFG reset",  rd, 8'h10);
        spi_read(7'h10, rd); check("RX_GAIN_SH0",     rd, 8'h3E);
        spi_read(7'h14, rd); check("RX_GAIN_ACT0",    rd, 8'h3E);

        // 4. Burst write W shadow bank 0x30-0x3F, then burst readback
        spi_start;
        spi_byte({1'b0, 7'h30}, dump);
        for (i = 0; i < 16; i = i + 1) spi_byte(8'hA0 + i[7:0], dump);
        spi_stop;

        spi_start;
        spi_byte({1'b1, 7'h30}, dump);
        for (i = 0; i < 16; i = i + 1) begin
            spi_byte(8'h00, rd);
            if (rd !== (8'hA0 + i[7:0])) begin
                $display("FAIL  W bank burst rd[%0d]   got 0x%02h expected 0x%02h",
                         i, rd, 8'hA0 + i[7:0]);
                errors = errors + 1;
            end
        end
        spi_stop;
        $display("pass  W bank 16-byte burst write/readback");

        // 5. Burst auto-increment wrap: 0x7E -> 0x7F -> 0x00 (CHIP_ID)
        spi_start;
        spi_byte({1'b1, 7'h7E}, dump);
        spi_byte(8'h00, rd); check("rsvd 0x7E",      rd, 8'h00);
        spi_byte(8'h00, rd); check("rsvd 0x7F",      rd, 8'h00);
        spi_byte(8'h00, rd); check("wrap -> CHIP_ID", rd, 8'hA7);
        spi_stop;

        // 6. Removed/reserved addresses read as 0x00; 0x7F write discarded
        spi_read (7'h02, rd); check("IRQ_STATUS idle", rd, 8'h00);
        spi_read (7'h27, rd); check("rsvd 0x27",       rd, 8'h00);
        spi_write(7'h7F, 8'hFF);                    // must be ignored
        spi_read (7'h7F, rd); check("0x7F after wr",   rd, 8'h00);

        // 7. PSRAM debug: DBG_BUSY=1 while qe_init_done=0 (PSRAM disabled)
        spi_read(7'h75, rd); check("DBG_BUSY pre-init", rd & 8'h80, 8'h80);
        spi_read(7'h76, rd); check("DBG_DATA pre-init", rd, 8'h00);

        // 8. W1P self-clear: W_COMMIT write, readback bit 0 must be low
        spi_write(7'h1E, 8'h01);
        spi_read (7'h1E, rd); check("WGT_CTRL W1P clr", rd & 8'h01, 8'h00);

        // 9. PSRAM_DBG_ADDR write/readback across all three bytes
        spi_write(7'h72, 8'h34);
        spi_write(7'h73, 8'h12);
        spi_write(7'h74, 8'h55);
        spi_read (7'h72, rd); check("DBG_ADDR_LO",  rd, 8'h34);
        spi_read (7'h73, rd); check("DBG_ADDR_MID", rd, 8'h12);
        spi_read (7'h74, rd); check("DBG_ADDR_HI",  rd, 8'h55);

        if (errors == 0) $display("\nTB PASS — all SPI register checks passed");
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
