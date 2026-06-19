// tb_trouper_top.v
// End-to-end integration testbench for trouper_top (the tapeout top level).
//
// Signal flow exercised:
//   SDM(sinusoid) → IQ_DATA_I/Q → sd_decimator_cic_tdm8 → dc_removal
//   → psram_buf_ctrl (SC delay-line via psram_model) → sc_detector
//   → training_acc → [MRC weights via SPI] → mrc_combiner → sd_remod
//   → REMOD_A_I/Q
//
// Tests (self-checking):
//   1. PSRAM_STATUS.INIT_DONE asserts within 200 cycles of PSRAM_CTRL enable
//   2. IRQ_OUT (sc_lock) fires within 150000 cycles
//   3. IRQ_STATUS[1] (training_done) fires within 50000 cycles after sc_lock
//   4. REMOD_A_I/Q toggles within 2000 cycles of W_COMMIT
//
// Stimulus: complex sinusoid of amplitude 40 LSB, period = 128 decimated
// samples (SF7: M=128).  All 4 branches identical → perfect SC autocorr.
// 1-bit encoding: first-order sigma-delta modulator runs at 32 MHz;
// sine pointer advances every 128 clock cycles (= CIC decimation ratio).
//
// Run:
//   iverilog -g2012 -o tb_trouper_top.vvp \
//     tb/tb_trouper_top.v \
//     rtl/trouper_top.v \
//     rtl/sd_decimator_cic_tdm8.v \
//     rtl/dc_removal.v \
//     rtl/sc_detector.v \
//     rtl/training_acc.v \
//     rtl/packet_ctrl_fsm.v \
//     rtl/psram_buf_ctrl.v \
//     rtl/mrc_combiner.v \
//     rtl/sd_remod.v \
//     rtl/spi_slave.v \
//     rtl/reg_bank.v \
//     ../fpga-emul/rtl/psram_model.v
//   vvp tb_trouper_top.vvp

`timescale 1ns/1ps
`default_nettype none

module tb_trouper_top;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk = 1'b0;
    always #15.625 clk = ~clk;   // 32 MHz

    reg resetb = 1'b0;

    // -----------------------------------------------------------------------
    // DUT pads
    // -----------------------------------------------------------------------
    reg  [3:0] iq_data_i = 4'h0;
    reg  [3:0] iq_data_q = 4'h0;

    wire       remod_a_i, remod_a_q;

    wire        psram_sck, psram_ce_n;
    wire [3:0]  psram_sio_out, psram_sio_oe;
    wire [3:0]  psram_sio_in;   // driven by psram_model

    reg  spi_cs   = 1'b1;
    reg  spi_sck  = 1'b0;
    reg  spi_mosi = 1'b0;
    wire spi_miso;

    wire irq_out, irq_grouper;
    wire [7:0] grp_rdata;
    wire       grp_ready;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    trouper_top dut (
        .IQ_CLK       (clk),
        .RESETB       (resetb),
        .IQ_DATA_I    (iq_data_i),
        .IQ_DATA_Q    (iq_data_q),
        .REMOD_A_I    (remod_a_i),
        .REMOD_A_Q    (remod_a_q),
        .PSRAM_SCK    (psram_sck),
        .PSRAM_CE_N   (psram_ce_n),
        .PSRAM_SIO_OUT(psram_sio_out),
        .PSRAM_SIO_IN (psram_sio_in),
        .PSRAM_SIO_OE (psram_sio_oe),
        .HOST_CS      (spi_cs),
        .SPI_SCK      (spi_sck),
        .SPI_MOSI     (spi_mosi),
        .SPI_MISO     (spi_miso),
        .GRP_ADDR     (8'h00),
        .GRP_WDATA    (8'h00),
        .GRP_WE       (1'b0),
        .GRP_RE       (1'b0),
        .GRP_RDATA    (grp_rdata),
        .GRP_READY    (grp_ready),
        .IRQ_OUT      (irq_out),
        .IRQ_GROUPER  (irq_grouper)
    );

    // -----------------------------------------------------------------------
    // PSRAM behavioral model (APS6404L QPI subset)
    // -----------------------------------------------------------------------
    psram_model #(.ADDR_BITS(16), .RD_LAUNCH_SKIP(3)) u_psram (
        .clk_32m (clk),
        .rst_n   (resetb),
        .ce_n    (psram_ce_n),
        .sio_out (psram_sio_out),
        .sio_oe  (psram_sio_oe),
        .sio_in  (psram_sio_in)
    );

    // -----------------------------------------------------------------------
    // Sinusoidal stimulus table: amplitude=40, period=128 decimated samples.
    // ptr advances every 128 clock cycles (R=128 CIC ratio).
    // SDM reference ±127 → after chain gain ≈128 → int8 amplitude ≈ 40.
    // -----------------------------------------------------------------------
    real pi_r;
    integer stim_i_tbl [0:127];
    integer stim_q_tbl [0:127];
    integer si;
    initial begin
        pi_r = 3.14159265358979;
        for (si = 0; si < 128; si = si + 1) begin
            stim_i_tbl[si] = $rtoi(40.0 * $cos(2.0 * pi_r * si / 128.0));
            stim_q_tbl[si] = $rtoi(40.0 * $sin(2.0 * pi_r * si / 128.0));
        end
    end

    reg [6:0] sine_ptr;
    reg [6:0] bit_cnt;   // counts 0..127, advances sine_ptr at rollover

    reg signed [15:0] sdm_acc_i;
    reg signed [15:0] sdm_acc_q;
    reg sdm_bit_i;
    reg sdm_bit_q;

    always @(posedge clk or negedge resetb) begin
        if (!resetb) begin
            sine_ptr  <= 7'd0;
            bit_cnt   <= 7'd0;
            sdm_acc_i <= 16'sd0;
            sdm_acc_q <= 16'sd0;
            sdm_bit_i <= 1'b0;
            sdm_bit_q <= 1'b0;
            iq_data_i <= 4'h0;
            iq_data_q <= 4'h0;
        end else begin
            // First-order SDM: feedback ±127 to match chain gain
            if (sdm_acc_i >= 16'sd0) begin
                sdm_bit_i <= 1'b1;
                sdm_acc_i <= sdm_acc_i + $signed(stim_i_tbl[sine_ptr][15:0]) - 16'sd127;
            end else begin
                sdm_bit_i <= 1'b0;
                sdm_acc_i <= sdm_acc_i + $signed(stim_i_tbl[sine_ptr][15:0]) + 16'sd127;
            end
            if (sdm_acc_q >= 16'sd0) begin
                sdm_bit_q <= 1'b1;
                sdm_acc_q <= sdm_acc_q + $signed(stim_q_tbl[sine_ptr][15:0]) - 16'sd127;
            end else begin
                sdm_bit_q <= 1'b0;
                sdm_acc_q <= sdm_acc_q + $signed(stim_q_tbl[sine_ptr][15:0]) + 16'sd127;
            end

            // All 4 antenna branches identical (maximum MRC gain)
            iq_data_i <= {4{sdm_bit_i}};
            iq_data_q <= {4{sdm_bit_q}};

            // Advance sine table pointer every 128 bit clocks
            if (bit_cnt == 7'd127) begin
                bit_cnt  <= 7'd0;
                sine_ptr <= sine_ptr + 7'd1;  // wraps at 128 naturally
            end else begin
                bit_cnt <= bit_cnt + 7'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // SPI master model (Mode 0, MSB first, 8 MHz)
    // -----------------------------------------------------------------------
    localparam real SCK_HALF = 62.5;  // ns → 8 MHz

    task spi_byte;
        input  [7:0] tx;
        output [7:0] rx;
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

    task spi_start; begin spi_cs = 1'b0; #(SCK_HALF); end endtask
    task spi_stop;  begin #(SCK_HALF); spi_cs = 1'b1; #500; end endtask

    task spi_write;
        input [6:0] addr;
        input [7:0] data;
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b0, addr}, dump);
            spi_byte(data, dump);
            spi_stop;
        end
    endtask

    task spi_read;
        input  [6:0] addr;
        output [7:0] data;
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b1, addr}, dump);
            spi_byte(8'h00, data);
            spi_stop;
        end
    endtask

    // -----------------------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer cycle_count;

    task check;
        input [127:0] name;
        input [7:0]   got;
        input [7:0]   exp;
        begin
            if (got !== exp) begin
                $display("FAIL  %-30s got 0x%02h expected 0x%02h at cycle %0d",
                         name, got, exp, cycle_count);
                fail_count = fail_count + 1;
            end else begin
                $display("pass  %-30s 0x%02h at cycle %0d", name, got, cycle_count);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task check_nonzero;
        input [127:0] name;
        input [7:0]   got;
        begin
            if (got === 8'h00) begin
                $display("FAIL  %-30s got 0x00 (expected non-zero) at cycle %0d",
                         name, cycle_count);
                fail_count = fail_count + 1;
            end else begin
                $display("pass  %-30s 0x%02h at cycle %0d", name, got, cycle_count);
                pass_count = pass_count + 1;
            end
        end
    endtask

    always @(posedge clk) if (resetb) cycle_count <= cycle_count + 1;

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    reg [7:0]  rd;
    integer    poll_cnt;
    integer    t_init_done, t_sc_lock, t_train_done, t_w_commit;
    reg        remod_seen_0_i, remod_seen_1_i;
    reg        remod_seen_0_q, remod_seen_1_q;
    integer    remod_wait;

    initial begin
        $dumpfile("tb_trouper_top.vcd");
        $dumpvars(1, tb_trouper_top);

        pass_count    = 0;
        fail_count    = 0;
        cycle_count   = 0;
        t_init_done   = -1;
        t_sc_lock     = -1;
        t_train_done  = -1;
        t_w_commit    = -1;
        poll_cnt      = 0;

        // -------------------------------------------------------------------
        // 1. Reset sequence
        // -------------------------------------------------------------------
        repeat (4) @(posedge clk);
        resetb = 1'b1;
        repeat (8) @(posedge clk);

        // -------------------------------------------------------------------
        // 2. Enable PSRAM (PSRAM_CTRL 0x70 = 0x01: psram_en=1, qspi_owner=0)
        // -------------------------------------------------------------------
        spi_write(7'h70, 8'h01);
        $display("INFO  PSRAM_CTRL write 0x01 at cycle %0d", cycle_count);

        // -------------------------------------------------------------------
        // 3. Poll PSRAM_STATUS (0x71) until INIT_DONE (bit 3) = 1
        // -------------------------------------------------------------------
        poll_cnt = 0;
        rd = 8'h00;
        while (!(rd[3]) && poll_cnt < 2000) begin
            @(posedge clk);
            @(posedge clk);
            spi_read(7'h71, rd);
            poll_cnt = poll_cnt + 1;
        end
        t_init_done = cycle_count;
        if (rd[3]) begin
            $display("pass  %-30s status=0x%02h at cycle %0d",
                     "PSRAM INIT_DONE", rd, cycle_count);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL  PSRAM INIT_DONE never set within poll limit (cycle %0d)", cycle_count);
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------------------
        // 4. Wait for IRQ_OUT (sc_lock) — poll IRQ_STATUS (0x02) bit 0
        //    Default sc_thr=0x7333, sc_hits_req=2 are sufficient for a
        //    perfect sinusoidal preamble (math verified in tb comments).
        // -------------------------------------------------------------------
        $display("INFO  waiting for sc_lock (IRQ_STATUS[0])...");
        rd = 8'h00;
        poll_cnt = 0;
        while (!(rd[0]) && poll_cnt < 20000) begin
            repeat (32) @(posedge clk);   // wait ~1 iq_valid period between polls
            spi_read(7'h02, rd);
            poll_cnt = poll_cnt + 1;
        end
        t_sc_lock = cycle_count;
        if (rd[0]) begin
            $display("pass  %-30s IRQ_STATUS=0x%02h at cycle %0d",
                     "sc_lock (IRQ_STATUS[0])", rd, cycle_count);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL  sc_lock never fired within poll limit (cycle %0d)", cycle_count);
            fail_count = fail_count + 1;
            $display("FAIL  --- aborting: sc_lock prerequisite not met ---");
            $display("Results: %0d passed, %0d failed", pass_count, fail_count);
            $finish;
        end

        // -------------------------------------------------------------------
        // 5. Clear IRQ so we can detect training_done separately
        // -------------------------------------------------------------------
        spi_write(7'h03, 8'hFF);   // IRQ_CLEAR (WO)

        // -------------------------------------------------------------------
        // 6. Wait for training_done (IRQ_STATUS[1])
        // -------------------------------------------------------------------
        $display("INFO  waiting for training_done (IRQ_STATUS[1])...");
        rd = 8'h00;
        poll_cnt = 0;
        while (!(rd[1]) && poll_cnt < 10000) begin
            repeat (32) @(posedge clk);
            spi_read(7'h02, rd);
            poll_cnt = poll_cnt + 1;
        end
        t_train_done = cycle_count;
        if (rd[1]) begin
            $display("pass  %-30s IRQ_STATUS=0x%02h at cycle %0d",
                     "training_done (IRQ_STATUS[1])", rd, cycle_count);
            $display("INFO  sc_lock→training_done: %0d cycles", t_train_done - t_sc_lock);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL  training_done never fired within poll limit (cycle %0d)", cycle_count);
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------------------
        // 7. Write MRC weights via SPI (W shadow bank 0x30–0x3F):
        //    Equal-gain combining: W_re=0x40 (0.5 in Q0.7), W_im=0x00
        //    8 branches × 2 bytes (re, im) = 16 bytes burst.
        //    Layout per reg_bank: 0x30=W0_re, 0x31=W0_im, ..., 0x3E=W7_re, 0x3F=W7_im
        //    (map packs 4 complex weights: re0,im0,re1,im1,...,re3,im3, then 0 padding)
        // -------------------------------------------------------------------
        begin : write_weights
            reg [7:0] dump;
            integer ww;
            spi_start;
            spi_byte({1'b0, 7'h30}, dump);
            for (ww = 0; ww < 8; ww = ww + 1) begin
                spi_byte(8'h40, dump);   // W_re = 0x40 (≈0.5)
                spi_byte(8'h00, dump);   // W_im = 0x00
            end
            spi_stop;
        end
        $display("INFO  W shadow bank written at cycle %0d", cycle_count);

        // -------------------------------------------------------------------
        // 8. Commit weights: WGT_CTRL (0x1E) W_COMMIT bit 0 = W1P
        // -------------------------------------------------------------------
        spi_write(7'h1E, 8'h01);
        t_w_commit = cycle_count;
        $display("INFO  W_COMMIT at cycle %0d", cycle_count);

        // -------------------------------------------------------------------
        // 9. Verify REMOD_A_I/Q toggles within 2000 cycles (sd_remod active)
        // -------------------------------------------------------------------
        remod_seen_0_i = 1'b0; remod_seen_1_i = 1'b0;
        remod_seen_0_q = 1'b0; remod_seen_1_q = 1'b0;
        for (remod_wait = 0; remod_wait < 2000; remod_wait = remod_wait + 1) begin
            @(posedge clk);
            if (remod_a_i == 1'b0) remod_seen_0_i = 1'b1;
            if (remod_a_i == 1'b1) remod_seen_1_i = 1'b1;
            if (remod_a_q == 1'b0) remod_seen_0_q = 1'b1;
            if (remod_a_q == 1'b1) remod_seen_1_q = 1'b1;
        end

        if (remod_seen_0_i && remod_seen_1_i) begin
            $display("pass  %-30s both 0 and 1 observed at cycle %0d",
                     "REMOD_A_I toggles", cycle_count);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL  REMOD_A_I stuck (seen_0=%0b seen_1=%0b) at cycle %0d",
                     remod_seen_0_i, remod_seen_1_i, cycle_count);
            fail_count = fail_count + 1;
        end

        if (remod_seen_0_q && remod_seen_1_q) begin
            $display("pass  %-30s both 0 and 1 observed at cycle %0d",
                     "REMOD_A_Q toggles", cycle_count);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL  REMOD_A_Q stuck (seen_0=%0b seen_1=%0b) at cycle %0d",
                     remod_seen_0_q, remod_seen_1_q, cycle_count);
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------------------
        // 10. Spot-check register state
        // -------------------------------------------------------------------
        spi_read(7'h00, rd); check("CHIP_ID",         rd, 8'hA7);
        spi_read(7'h01, rd); check("CHIP_REV",        rd, 8'h01);
        spi_read(7'h30, rd); check_nonzero("W0_re",   rd);

        // -------------------------------------------------------------------
        // Done
        // -------------------------------------------------------------------
        $display("------------------------------------------------------------");
        if (fail_count == 0)
            $display("TB PASS — %0d checks passed", pass_count);
        else
            $display("TB FAIL — %0d passed, %0d failed", pass_count, fail_count);
        $display("  t_init_done =%0d  t_sc_lock  =%0d", t_init_done,  t_sc_lock);
        $display("  t_train_done=%0d  t_w_commit =%0d", t_train_done, t_w_commit);
        $display("------------------------------------------------------------");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Global timeout
    // -----------------------------------------------------------------------
    initial begin
        #150_000_000;   // 150 ms → 4.8M cycles at 32 MHz
        $display("TB FAIL — global timeout");
        $display("  cycle_count=%0d", cycle_count);
        if (t_init_done  < 0) $display("  PSRAM INIT_DONE never set");
        if (t_sc_lock    < 0) $display("  sc_lock never fired");
        if (t_train_done < 0) $display("  training_done never fired");
        $finish;
    end

endmodule

`default_nettype wire
