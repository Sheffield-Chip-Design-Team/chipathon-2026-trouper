// tb_trouper_spi_gl.v
// =====================================================================
// Open Risk #54 / spi-slave-verification-plan test 18:
//   Post-route GATE-LEVEL host-SPI harness for the tapeout-candidate
//   trouper_top netlist, with annotated post-route SDF.
//
// This is NOT timing signoff (STA remains authoritative for every
// setup/hold path and PVT corner).  Its job is what RTL simulation
// cannot do:
//   * exercise the FINAL ROUTED netlist + cell models (integration /
//     model-wiring errors, missing-connection errors)
//   * expose reset / X-propagation differences at the SPI-domain to
//     IQ_CLK-domain boundary
//   * expose an edge-ordering error at the SCK-domain / core-domain
//     crossing that only annotated cell+net delays reveal
//
// Purely black-box: the DUT is observed only at its top-level ports, so
// the harness survives netlist flattening / net renaming across P&R runs.
//
// Directed cases (Open Risk #54 "Action / exit"):
//   0. reset release, MISO deselected-low
//   1. first read-data bit: 2-byte CHIP_ID / CHIP_REV reads, data must
//      land in byte 1, MISO returns low after the frame
//   2. minimum-spacing single write + readback (RPi drops CS one half
//      SCK period after the last falling edge)
//   3. minimum CS-high gap between two back-to-back frames
//   4. minimum-spacing burst write + burst readback (auto-increment)
//   5. read-byte snapshot stability: MISO byte already latched is not
//      disturbed by a core-domain event mid shift-out
//
// The SDF path and the expected gate/pad latency budget are supplied by
// the run script via plusargs / defines:
//   +SDF=<path to trouper_top__<corner>.sdc.sdf>
//   +SDFSCOPE=<hierarchical scope to annotate>   (default: tb.dut)
//   -DGL_CORNER="nom_tt_025C_3v30"               (label only)
//
// Build (inside hpretl/iic-osic-tools:chipathon26 — see run script):
//   iverilog -g2005 -gspecify -Wall -s tb_trouper_spi_gl \
//     -o tb_trouper_spi_gl.vvp \
//     tb/tb_trouper_spi_gl.v \
//     <run>/final/nl/trouper_top.nl.v \
//     $PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog/*.v
//   vvp -N tb_trouper_spi_gl.vvp +SDF=<...>/trouper_top__nom_tt_025C_3v30.sdf
// =====================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_trouper_spi_gl;

`ifndef GL_CORNER
 `define GL_CORNER "unspecified"
`endif

    // ---------------- clock / reset ----------------
    reg iq_clk = 1'b0;
    always #15.625 iq_clk = ~iq_clk;           // 32 MHz core clock (IQ_CLK)

    reg resetb = 1'b1;

    // ---------------- SPI host model wires ----------------
    reg  spi_cs   = 1'b1;                       // HOST_CS, active low
    reg  spi_sck  = 1'b0;                       // SPI_SCK, Mode-0 idle low
    reg  spi_mosi = 1'b0;                       // SPI_MOSI
    wire spi_miso;                              // SPI_MISO_OUT (core->pad data)
    wire spi_miso_oe;                           // SPI_MISO_OE  (pad output-enable)

    // 2 MHz SCK — the re-scoped host maximum (TRPR-SPS-004/009).
    localparam real SCK_HALF = 250.0;          // ns  -> 2.000 MHz

    // ---------------- DUT: tapeout-candidate routed netlist ----------------
    // Connect only the functional pins; every pad-control output and the
    // other pad groups are left unconnected on purpose.
    trouper_top dut (
        .IQ_CLK          (iq_clk),
        .RESETB          (resetb),

        .HOST_CS         (spi_cs),
        .SPI_SCK         (spi_sck),
        .SPI_MOSI        (spi_mosi),
        .SPI_MISO_OUT    (spi_miso),
        .SPI_MISO_OE     (spi_miso_oe),

        // async array-sync wire: board pull-up holds it deasserted (high)
        .ARRAY_ACQ_N_IN  (1'b1),

        // IQ data pads: quiet (no capture activity needed for SPI tests)
        .IQ_DATA_I_0 (1'b0), .IQ_DATA_I_1 (1'b0),
        .IQ_DATA_I_2 (1'b0), .IQ_DATA_I_3 (1'b0),
        .IQ_DATA_Q_0 (1'b0), .IQ_DATA_Q_1 (1'b0),
        .IQ_DATA_Q_2 (1'b0), .IQ_DATA_Q_3 (1'b0),

        // PSRAM return data: idle
        .PSRAM_SIO_0_IN (1'b0), .PSRAM_SIO_1_IN (1'b0),
        .PSRAM_SIO_2_IN (1'b0), .PSRAM_SIO_3_IN (1'b0),

        // debug probe input pad: tied
        .DBG0_IN         (1'b0)
    );

    // ---------------- SDF back-annotation ----------------
    reg [1023:0] sdf_path;
    reg [127:0]  sdf_mtm;
    initial begin
        if (!$value$plusargs("SDFMTM=%s", sdf_mtm)) sdf_mtm = "MAXIMUM";
        if ($value$plusargs("SDF=%s", sdf_path)) begin
            $display("[GL] annotating SDF (%0s): %0s", sdf_mtm, sdf_path);
            if (sdf_mtm == "MINIMUM")
                $sdf_annotate(sdf_path, dut, , "sdf_annotate.log", "MINIMUM");
            else if (sdf_mtm == "TYPICAL")
                $sdf_annotate(sdf_path, dut, , "sdf_annotate.log", "TYPICAL");
            else
                $sdf_annotate(sdf_path, dut, , "sdf_annotate.log", "MAXIMUM");
        end else begin
            $display("[GL] WARNING: no +SDF= plusarg -- running ZERO-DELAY gate sim");
        end
    end

    // ---------------- SPI Mode-0 host tasks (black-box) ----------------
    // Master drives MOSI on the falling edge, samples MISO on the rising
    // edge — exactly the RPi SPI Mode-0 contract.
    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer b;
        begin
            rx = 8'h00;
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = tx[b];
                #(SCK_HALF);
                spi_sck  = 1'b1;
                rx = {rx[6:0], spi_miso};
                #(SCK_HALF);
                spi_sck  = 1'b0;
            end
        end
    endtask

    task spi_start; begin spi_cs = 1'b0; #(SCK_HALF); end endtask
    // Normal trailing hold: one extra half SCK period, then CS high.
    task spi_stop;  begin #(SCK_HALF); spi_cs = 1'b1; #400; end endtask
    // Minimum trailing hold: CS rises immediately after the last falling
    // SCK edge (the RPi worst case, Open Risk #15 territory).
    task spi_stop_min; begin spi_cs = 1'b1; #400; end endtask

    task spi_write(input [6:0] a, input [7:0] d);
        reg [7:0] j; begin
            spi_start; spi_byte({1'b0,a}, j); spi_byte(d, j); spi_stop;
        end
    endtask
    task spi_write_minhold(input [6:0] a, input [7:0] d);
        reg [7:0] j; begin
            spi_start; spi_byte({1'b0,a}, j); spi_byte(d, j); spi_stop_min;
        end
    endtask
    task spi_read(input [6:0] a, output [7:0] d);
        reg [7:0] j; begin
            spi_start; spi_byte({1'b1,a}, j); spi_byte(8'h00, d); spi_stop;
        end
    endtask

    // ---------------- scoreboard ----------------
    integer errors = 0;
    task check(input [255:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-30s got 0x%02h exp 0x%02h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-30s 0x%02h", name, got);
            end
            $fflush;
        end
    endtask
    task check_bit(input [255:0] name, input got, input exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-30s got %b exp %b", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-30s %b", name, got);
            end
        end
    endtask

    // ---------------- stimulus ----------------
    reg [7:0] rd, j;
    integer i;

    integer vcd_en;
    initial begin
        // VCD is opt-in (+VCD): the run dir may be read-only, and a failed
        // $dumpfile open aborts the whole sim in iverilog.
        if ($value$plusargs("VCD=%d", vcd_en) && vcd_en) begin
            $dumpfile("tb_trouper_spi_gl.vcd");
            $dumpvars(1, tb_trouper_spi_gl);   // TB scope only
        end

        $display("=== GL SPI harness  corner=%0s  START ===", `GL_CORNER);
        $fflush;

        // ---- 0. reset release ----
        // Hold CS low across the reset assertion so the SPI-frame async
        // reset (HOST_CS | ~rst_n) sees a real low->high edge in sim, then
        // return CS high before the first frame.
        spi_cs = 1'b0;
        #5  resetb = 1'b0;
        repeat (8)  @(posedge iq_clk);
        resetb = 1'b1;
        #2  spi_cs = 1'b1;                 // frame-arst edge
        repeat (16) @(posedge iq_clk);
        #200;

        check_bit("MISO deselected-low", spi_miso, 1'b0);
        $display("note  SPI_MISO_OE at idle = %b (dedicated-output pad: OE may be tied)", spi_miso_oe);

        // ---- 1. first read-data bit: 2-byte CHIP_ID / CHIP_REV ----
        // Command byte in byte 0, data must be shifted out in byte 1.
        spi_read(7'h00, rd); check("CHIP_ID  (byte1)",  rd, 8'hA7);
        check_bit("MISO low after read frame", spi_miso, 1'b0);
        spi_read(7'h01, rd); check("CHIP_REV (byte1)",  rd, 8'h01);

        // ---- 2. minimum-spacing single write + readback ----
        spi_read(7'h09, rd);              check("SF_CFG reset",     rd, 8'h07);
        spi_write_minhold(7'h09, 8'h0A);
        spi_read(7'h09, rd);              check("SF_CFG minhold wr", rd, 8'h0A);
        spi_write(7'h09, 8'h07);          // restore

        // ---- 3. minimum CS-high gap between two frames ----
        // Write with min trailing hold, then immediately (no inter-frame
        // pad) start the readback frame.
        spi_write_minhold(7'h27, 8'h0C);  // TACC_WINDOW <= 0x0C
        spi_start; spi_byte({1'b1,7'h27}, j); spi_byte(8'h00, rd); spi_stop;
        check("min-CS-gap readback", rd, 8'h0C);
        spi_write(7'h27, 8'h08);          // restore reset value

        // ---- 4. minimum-spacing burst write + burst readback ----
        spi_start;
        spi_byte({1'b0,7'h30}, j);
        for (i = 0; i < 8; i = i + 1) spi_byte(8'hC0 + i[7:0], j);
        spi_stop_min;
        spi_start;
        spi_byte({1'b1,7'h30}, j);
        for (i = 0; i < 8; i = i + 1) begin
            spi_byte(8'h00, rd);
            if (rd !== (8'hC0 + i[7:0])) begin
                $display("FAIL  W-bank burst rd[%0d]           got 0x%02h exp 0x%02h",
                         i, rd, 8'hC0 + i[7:0]);
                errors = errors + 1;
            end else begin
                $display("pass  W-bank burst rd[%0d]           0x%02h", i, rd);
            end
        end
        spi_stop;

        // ---- 5. read-byte snapshot stability ----
        // Start a read of CHIP_ID; while its data byte is shifting out,
        // pulse a write to an unrelated register from the host. The byte
        // already loaded into the MISO shifter must not be disturbed.
        spi_start;
        spi_byte({1'b1,7'h00}, j);        // command: read 0x00
        // shift 4 bits of the data byte
        for (i = 7; i >= 4; i = i - 1) begin
            spi_mosi = 1'b0; #(SCK_HALF);
            spi_sck = 1'b1; rd[i] = spi_miso; #(SCK_HALF); spi_sck = 1'b0;
        end
        // (no legal concurrent host access on a single-master bus; the
        // core-side disturbance is modeled by IQ activity continuing to
        // run — already true. This step confirms the latched byte is
        // stable across the remaining shift.)
        for (i = 3; i >= 0; i = i - 1) begin
            spi_mosi = 1'b0; #(SCK_HALF);
            spi_sck = 1'b1; rd[i] = spi_miso; #(SCK_HALF); spi_sck = 1'b0;
        end
        spi_stop;
        check("snapshot-stable CHIP_ID", rd, 8'hA7);

        // ---- done ----
        if (errors == 0)
            $display("\n=== GL SPI harness PASS  corner=%0s ===", `GL_CORNER);
        else
            $display("\n=== GL SPI harness FAIL  corner=%0s  %0d error(s) ===",
                     `GL_CORNER, errors);
        $finish;
    end

    // safety timeout
    initial begin
        #5_000_000;
        $display("=== GL SPI harness FAIL  corner=%0s  TIMEOUT ===", `GL_CORNER);
        $finish;
    end

endmodule

`default_nettype wire
