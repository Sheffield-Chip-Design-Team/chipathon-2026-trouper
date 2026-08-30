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
// SPI master model: Mode 0, MSB first, 10 MHz.
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

    reg resetb = 1'b1;

    // ---- DUT pads ----
    reg  [3:0] iq_i = 4'h0, iq_q = 4'h0;
    wire       remod_i, remod_q;
    wire       psram_sck, psram_ce_n;
    wire [3:0] psram_sio_out, psram_sio_oe;
    reg  [3:0] psram_sio_in = 4'h0;
    // Starts LOW so the reset sequence can create a POSEDGE on spi_slave's
    // `spi_frame_arst = HOST_CS | ~rst_n`. That reset is level-sensitive in
    // silicon (the frame FSM is held reset for the whole HOST_CS=1 window) but
    // edge-sensitive in Verilog: with HOST_CS tied high from time 0 the posedge
    // never happens, the frame FSM stays X for the entire first frame, and the
    // first read of the simulation returns 0x00 instead of the addressed byte.

    reg  spi_cs   = 1'b0;             // active low
    reg  spi_sck  = 1'b0;
    reg  spi_mosi = 1'b0;
    wire spi_miso;

    wire irq_out, irq_grouper;
    wire [7:0] grp_rdata;
    wire       grp_ready;

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
                .GRP_ADDR_0 (1'b0),
        .GRP_ADDR_1 (1'b0),
        .GRP_ADDR_2 (1'b0),
        .GRP_ADDR_3 (1'b0),
        .GRP_ADDR_4 (1'b0),
        .GRP_ADDR_5 (1'b0),
        .GRP_ADDR_6 (1'b0),
        .GRP_ADDR_7 (1'b0),
                .GRP_WDATA_0 (1'b0),
        .GRP_WDATA_1 (1'b0),
        .GRP_WDATA_2 (1'b0),
        .GRP_WDATA_3 (1'b0),
        .GRP_WDATA_4 (1'b0),
        .GRP_WDATA_5 (1'b0),
        .GRP_WDATA_6 (1'b0),
        .GRP_WDATA_7 (1'b0),
        .GRP_WE      (1'b0),
        .GRP_RE      (1'b0),
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
        .IRQ_GROUPER (irq_grouper),
        // Array acquisition sync: idle high, as the mandatory board
        // pull-up holds it. planning/array-acquisition-sync.md.
        .ARRAY_ACQ_N_IN (1'b1),
        // Debug probes: inputs tied off (the pads are output-only in function);
        // outputs left unconnected.
        .DBG0_IN        (1'b0),
        .DBG1_IN        (1'b0)
    );

    // ---- SPI master model (Mode 0, MSB first) ----
    // 2 MHz, the interface's re-scoped maximum (TRPR-SPS: host SPI is
    // specified up to 2 MHz, derated from 10 MHz). At 8 MHz a read's command
    // byte gives reg_bank's CE-gated readback register only half an SCK period
    // to settle, so the FIRST read after reset returns the reset value instead
    // of the addressed one -- an out-of-spec stimulus artefact, not a DUT bug.
    localparam real SCK_HALF = 250.0;  // ns -> 2 MHz

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

    // Raspberry Pi permits CS to deassert shortly after the final falling SCK
    // edge.  Do not add the normal extra half-cycle hold here: the completed
    // write event must survive CS resetting the SPI frame immediately.
    task spi_write_min_cs_hold(input [6:0] a, input [7:0] d);
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b0, a}, dump);
            spi_byte(d, dump);
            spi_cs = 1'b1;
            #500;
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
    integer reg_we_events = 0;
    integer reg_we_before;
    reg reg_we_prev = 1'b0;

    always @(posedge clk) begin
        reg_we_prev <= dut.u_spi.reg_we;
        if (dut.u_spi.reg_we && !reg_we_prev)
            reg_we_events <= reg_we_events + 1;
    end

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

        // Create an explicit reset assertion edge.  SPI-domain flops see no
        // SCK while idle, so starting simulation with reset already low would
        // not exercise their edge-sensitive Verilog async-reset event.
        // Hold CS low across the reset assertion so spi_frame_arst transitions
        // low->high in simulation; return CS high before the first frame.
        spi_cs = 1'b0;
        #1 resetb = 1'b0;
        repeat (4) @(posedge clk);
        resetb = 1'b1;
        #1 spi_cs = 1'b1;   // posedge on HOST_CS: fires the frame-FSM async reset
        repeat (8) @(posedge clk);

        // 0. SPI_MISO is a dedicated output and must be driven low, not Z,
        // whenever HOST_CS is deasserted (TRPR-SPS-008).
        if (spi_miso !== 1'b0) begin
            $display("FAIL  MISO deselected-low      got %b expected 0", spi_miso);
            errors = errors + 1;
        end else begin
            $display("pass  MISO deselected-low");
        end

        // 1. CHIP_ID / CHIP_REV — 2-byte read frames (TRPR-SPS-006/009)
        spi_read(7'h00, rd); check("CHIP_ID",        rd, 8'hA7);
        if (spi_miso !== 1'b0) begin
            $display("FAIL  MISO release after read got %b expected 0", spi_miso);
            errors = errors + 1;
        end else begin
            $display("pass  MISO release after read");
        end
        spi_read(7'h01, rd); check("CHIP_REV",       rd, 8'h01);

        // 2. Write + readback: SF_CFG (reset 0x07 -> 0x0A).  First use the
        // minimum-CS-hold path that exposed the old final-write CDC race.
        spi_read (7'h09, rd); check("SF_CFG reset",  rd, 8'h07);
        reg_we_before = reg_we_events;
        spi_write_min_cs_hold(7'h09, 8'h0A);
        spi_read (7'h09, rd); check("SF_CFG min-CS wr", rd, 8'h0A);
        if (reg_we_events !== reg_we_before + 1) begin
            $display("FAIL  min-CS reg_we events    got %0d expected %0d",
                     reg_we_events - reg_we_before, 1);
            errors = errors + 1;
        end else begin
            $display("pass  min-CS reg_we exactly once");
        end
        spi_write(7'h09, 8'h07);

        // 3. Reset values: MIMO_CTRL 0xF0, COMB_CFG 0x10
        spi_read(7'h08, rd); check("MIMO_CTRL reset", rd, 8'hF0);
        spi_read(7'h0F, rd); check("COMB_CFG reset",  rd, 8'h10);
        spi_read(7'h10, rd); check("rsvd 0x10 reads 0", rd, 8'h00);

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

        // 6. Training window config; 0x7F write discarded
        spi_read (7'h02, rd); check("IRQ_STATUS idle", rd, 8'h00);
        spi_read (7'h27, rd); check("TACC_WINDOW reset", rd, 8'h08);
        spi_write(7'h27, 8'h0C);
        spi_read (7'h27, rd); check("TACC_WINDOW wr", rd, 8'h0C);
        spi_write(7'h27, 8'h00);
        spi_read (7'h27, rd); check("TACC_WINDOW clamp", rd, 8'h08);
        spi_write(7'h27, 8'h08);                    // restore
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

        // 10. Reserved-bit masking: write 0xFF, read back implemented mask only
        spi_write(7'h09, 8'hFF); spi_read(7'h09, rd); check("mask SF_CFG",   rd, 8'h0F);
        spi_write(7'h09, 8'h07);                                  // restore
        spi_write(7'h08, 8'hFF); spi_read(7'h08, rd); check("mask MIMO_CTRL",rd, 8'hF1);
        spi_write(7'h08, 8'hF0);                                  // restore
        spi_write(7'h0A, 8'hFF); spi_read(7'h0A, rd); check("mask BW_CFG",   rd, 8'h07);
        spi_write(7'h0A, 8'h00);                                  // restore
        spi_write(7'h0E, 8'hFF); spi_read(7'h0E, rd); check("mask SC_HITS",  rd, 8'h03);
        spi_write(7'h0E, 8'h00);                                  // restore
        spi_write(7'h0F, 8'hFF); spi_read(7'h0F, rd); check("mask COMB_CFG", rd, 8'h37);
        spi_write(7'h0F, 8'h10);                                  // restore
        spi_write(7'h74, 8'hFF); spi_read(7'h74, rd); check("mask DBG_ADDR_HI",rd, 8'h7F);
        spi_write(7'h74, 8'h55);                                  // restore

        // 11. Read-only registers ignore writes (write 0xFF, value unchanged)
        spi_write(7'h00, 8'hFF); spi_read(7'h00, rd); check("RO CHIP_ID",    rd, 8'hA7);
        spi_write(7'h01, 8'hFF); spi_read(7'h01, rd); check("RO CHIP_REV",   rd, 8'h01);
        spi_write(7'h1C, 8'hFF); spi_read(7'h1C, rd); check("RO PKT_STATUS", rd, 8'h00);
        spi_write(7'h20, 8'hFF); spi_read(7'h20, rd); check("RO TRAIN_STAT", rd, 8'h00);
        spi_write(7'h21, 8'hFF); spi_read(7'h21, rd); check("RO N_ACC_HI",   rd, 8'h00);
        // Training-accumulator result inputs are intentionally resetless and
        // may be X before an arm event, so do not assume a reset value here;
        // their RO policy requires driven inputs in the planned standalone
        // register-bank suite.

        // 12. Write-only / W1P read semantics
        spi_write(7'h1F, 8'h01); spi_read(7'h1F, rd); check("WO NOISE_TRIG", rd, 8'h00);
        spi_write(7'h75, 8'h03);                       // RD_TRIG + AUTO_INC
        spi_read (7'h75, rd); check("DBG_CTRL RD_TRIG self-clr", rd & 8'h01, 8'h00);
        spi_write(7'h75, 8'h00);                       // restore

        // 13. 0x10-0x18 reserved (former gain shadow/active/commit block, removed):
        //     writes ignored, reads always 0
        spi_write(7'h11, 8'hFF); spi_read(7'h11, rd); check("rsvd 0x11 ignores wr", rd, 8'h00);
        spi_write(7'h18, 8'hFF); spi_read(7'h18, rd); check("rsvd 0x18 ignores wr", rd, 8'h00);

        // 14. PSRAM_CTRL masking: reserved bit2 ignores writes and reads zero;
        //     CLR_ERR (bit1) is W1P and self-clears.
        spi_write(7'h70, 8'hFF); spi_read(7'h70, rd); check("PSRAM_CTRL mask+W1P", rd, 8'h09);
        spi_write(7'h70, 8'h00);                       // restore (disable PSRAM)

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
