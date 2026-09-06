// tb_fpga_dsp_chain.v
// Functional end-to-end sim THROUGH fpga_dsp_wrap: the injection path -> the
// wrapper's 4x sd_remod modulators -> trouper_top's full DSP chain -> internal
// psram_model -> MRC combiner -> output sd_remod.
//
// tb_fpga_spi_reg.v is only a wiring smoke test (one register read/write).
// This bench exercises the wrapper's distinguishing logic: the injection
// sd_remod instances, the inj_en mux, the USE_EXT_PSRAM=0 BRAM back-end, and
// the whole datapath as wired through the reworked u_top instantiation.
//
// Stimulus: a continuous in-band tone (amp 80, period 256 decimated samples)
// as int8 IQ on inj_i0..3 / inj_q0..3, paced one sample per 64 clk_32m (the
// 500 kS/s decimator-output rate). All four branches get the same sample, so
// the Schmidl-Cox detector sees strongly correlated energy and locks -- the
// same principle as rtl-test/tb/tb_trouper_two_packet.v, but driven through
// the FPGA wrapper's injection port rather than trouper_top's 1-bit IQ pins.
//
// Checks (black-box over the wrapper's host-SPI port unless noted):
//   ID    CHIP_ID / CHIP_REV read back correct       -> SPI path through wrapper
//   INIT  PSRAM INIT_DONE (0x71[3])                  -> internal psram_model+ctrl
//   LOCK  sc_lock via IRQ_STATUS[0] (0x02)           -> decimator+DC+SC e2e
//   REMOD REMOD_A_I_OUT / REMOD_A_Q_OUT both toggle  -> combiner + output sd_remod
//
// Build: verilator --binary --timing  (top tb_fpga_dsp_chain).

`timescale 1ns/1ps
`default_nettype none

module tb_fpga_dsp_chain;
    // ---- 32 MHz clock ----
    reg clk = 1'b0;
    always #15.625 clk = ~clk;

    reg rst_n = 1'b0;

    integer cycle_count = 0;
    always @(posedge clk) cycle_count <= cycle_count + 1;

    // ---- injection stimulus ----
    reg              inj_en    = 1'b0;
    reg              inj_valid = 1'b0;
    reg signed [7:0] inj_i = 8'sd0, inj_q = 8'sd0;

    // ---- host SPI (internal-master path: spi_sel = 0) ----
    // CS held LOW across the reset pulse so the spi_slave frame async-reset
    // term (HOST_CS | ~rst_n) actually toggles in sim (see
    // tb_trouper_two_packet.v / project_tb_reset_edge_gotchas).
    reg  host_cs  = 1'b0;
    reg  spi_sck  = 1'b0;
    reg  spi_mosi = 1'b0;
    wire spi_miso;
    wire irq;

    wire remod_i, remod_q;

    fpga_dsp_wrap #(.USE_EXT_PSRAM(0)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .hw_iq_i    (4'h0),
        .hw_iq_q    (4'h0),
        .inj_en     (inj_en),
        .inj_valid  (inj_valid),
        .inj_i0 (inj_i), .inj_q0 (inj_q),
        .inj_i1 (inj_i), .inj_q1 (inj_q),
        .inj_i2 (inj_i), .inj_q2 (inj_q),
        .inj_i3 (inj_i), .inj_q3 (inj_q),
        .remod_i    (remod_i),
        .remod_q    (remod_q),
        .psram_sck  (),
        .psram_ce_n (),
        .psram_sio  (),
        .spi_sel      (1'b0),
        .host_cs   (host_cs),
        .spi_sck   (spi_sck),
        .spi_mosi  (spi_mosi),
        .spi_miso  (spi_miso),
        .ext_host_cs  (1'b0),
        .ext_spi_sck  (1'b0),
        .ext_spi_mosi (1'b0),
        .ext_spi_miso (),
        .irq       (irq),
        .ext_irq   ()
    );

    // -----------------------------------------------------------------------
    // Tone table + injection pacer: one int8 IQ sample per 64 clk_32m.
    // -----------------------------------------------------------------------
    real pi_r;
    integer tone_i [0:255];
    integer tone_q [0:255];
    integer k;
    initial begin
        pi_r = 3.14159265358979;
        for (k = 0; k < 256; k = k + 1) begin
            tone_i[k] = $rtoi(80.0 * $cos(2.0*pi_r*k/256.0));
            tone_q[k] = $rtoi(80.0 * $sin(2.0*pi_r*k/256.0));
        end
    end

    reg [7:0] tone_ptr = 8'd0;
    reg [6:0] pace      = 7'd0;   // 0..63
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pace      <= 7'd0;
            tone_ptr  <= 8'd0;
            inj_valid <= 1'b0;
            inj_i     <= 8'sd0;
            inj_q     <= 8'sd0;
        end else if (pace == 7'd63) begin
            pace      <= 7'd0;
            inj_valid <= inj_en;                 // 1-clk strobe while enabled
            inj_i     <= tone_i[tone_ptr][7:0];
            inj_q     <= tone_q[tone_ptr][7:0];
            tone_ptr  <= tone_ptr + 8'd1;
        end else begin
            pace      <= pace + 7'd1;
            inj_valid <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // SPI master model (Mode 0, MSB first, 2 MHz -- the host-SPI spec max;
    // 8 MHz starves reg_bank's CE-gated readback on the first post-reset read).
    // Command byte = {rw, addr[6:0]}: rw=0 write, rw=1 read.
    // -----------------------------------------------------------------------
    localparam real SCK_HALF = 250.0;   // ns -> 2 MHz

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

    task spi_start; begin host_cs = 1'b0; #(SCK_HALF); end endtask
    task spi_stop;  begin #(SCK_HALF); host_cs = 1'b1; #500; end endtask

    task spi_write(input [6:0] addr, input [7:0] data);
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b0, addr}, dump);
            spi_byte(data, dump);
            spi_stop;
        end
    endtask

    task spi_read(input [6:0] addr, output [7:0] data);
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b1, addr}, dump);
            spi_byte(8'h00, data);
            spi_stop;
        end
    endtask

    // ---- check helpers ----
    integer pass_count = 0;
    integer fail_count = 0;
    task check_true(input [255:0] name, input cond);
        begin
            if (cond) begin
                pass_count = pass_count + 1;
                $display("pass  %0s", name);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL  %0s   (cycle %0d)", name, cycle_count);
            end
        end
    endtask
    task check_eq(input [255:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got === exp) begin
                pass_count = pass_count + 1;
                $display("pass  %0s = 0x%02h", name, got);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL  %0s got 0x%02h expected 0x%02h", name, got, exp);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    reg  [7:0] rd;
    integer poll, lock_cycle;
    reg        locked;
    reg        seen0_i, seen1_i, seen0_q, seen1_q;
    integer    w;

    initial begin
        $dumpfile("tb_fpga_dsp_chain.vcd");
        $dumpvars(0, tb_fpga_dsp_chain);

        // 1. Reset (CS low across the pulse, then idle high).
        repeat (2) @(posedge clk);
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        host_cs = 1'b1;
        repeat (8) @(posedge clk);

        // Start injection now so the decimator + DC-removal pipeline is
        // settling while the config writes go in (SC stays gated by RX_HOLD).
        inj_en = 1'b1;

        // 2. Warm-up read (discard: first post-reset read returns the reset
        //    value), then verify the ID registers over the wrapper's SPI.
        spi_read(7'h00, rd);
        spi_read(7'h00, rd);  check_eq("ID   CHIP_ID",  rd, 8'hA7);
        spi_read(7'h01, rd);  check_eq("ID   CHIP_REV", rd, 8'h01);

        // 3. Enable PSRAM, wait for INIT_DONE (0x71[3]).
        spi_write(7'h70, 8'h01);
        poll = 0; rd = 8'h00;
        while (!rd[3] && poll < 800) begin
            repeat (8) @(posedge clk);
            spi_read(7'h71, rd);
            poll = poll + 1;
        end
        check_true("INIT PSRAM INIT_DONE", rd[3]);

        // 4. Detector config (mirror tb_trouper_two_packet): sc_thr = 0x0100,
        //    sc_hits_req = 1, short packet timeout. SF/BW keep reset defaults
        //    (SF7 / BW 250 kHz). These are RX_HOLD-gated, so they go in first.
        spi_write(7'h0C, 8'h01);   // sc_thr[15:8]
        spi_write(7'h0D, 8'h00);   // sc_thr[7:0]
        spi_write(7'h0E, 8'h01);   // sc_hits_req
        spi_write(7'h0B, 8'h10);   // PKT_TIMEOUT_SYMS = 16
        spi_write(7'h1A, 8'h00);   // release RX_HOLD

        // 5. Poll IRQ_STATUS[0] (sc_lock) over SPI.
        $display("INFO  waiting for sc_lock (IRQ_STATUS[0]) ...");
        poll = 0; locked = 1'b0; lock_cycle = -1;
        while (!locked && poll < 6000) begin
            repeat (64) @(posedge clk);
            spi_read(7'h02, rd);
            if (rd[0]) begin locked = 1'b1; lock_cycle = cycle_count; end
            poll = poll + 1;
        end
        check_true("LOCK sc_lock asserted (IRQ[0])", locked);
        if (locked)
            $display("INFO  sc_lock at cycle %0d  (internal sc_lock=%0b)",
                     lock_cycle, dut.u_top.u_sc.sc_lock);

        // 6. With the chain locked, the MRC output ΣΔ stream must be alive
        //    (both rails toggle) -- proves combiner + output sd_remod run.
        seen0_i = 1'b0; seen1_i = 1'b0; seen0_q = 1'b0; seen1_q = 1'b0;
        for (w = 0; w < 40000; w = w + 1) begin
            @(posedge clk);
            if (remod_i === 1'b0) seen0_i = 1'b1;
            if (remod_i === 1'b1) seen1_i = 1'b1;
            if (remod_q === 1'b0) seen0_q = 1'b1;
            if (remod_q === 1'b1) seen1_q = 1'b1;
        end
        check_true("REMOD REMOD_A_I_OUT toggles", seen0_i && seen1_i);
        check_true("REMOD REMOD_A_Q_OUT toggles", seen0_q && seen1_q);

        // 7. Diagnostics (not pass/fail): training_acc branch-0 diagonal energy
        //    high byte (Zdiag base 0x64) -- non-zero => the combiner front end
        //    is accumulating real signal power.
        spi_read(7'h64, rd);
        $display("INFO  ZDIAG0[0x64] = 0x%02h", rd);

        $display("------------------------------------------------------------");
        if (fail_count == 0)
            $display("TB PASS - %0d checks passed", pass_count);
        else
            $display("TB FAIL - %0d passed, %0d failed", pass_count, fail_count);
        $display("  lock_cycle=%0d", lock_cycle);
        $display("------------------------------------------------------------");
        $finish;
    end

    // ---- global timeout ----
    initial begin
        #90_000_000;   // ~2.9M clk at 32 MHz
        $display("TB FAIL - global timeout (cycle_count=%0d)", cycle_count);
        $finish;
    end
endmodule
`default_nettype wire
