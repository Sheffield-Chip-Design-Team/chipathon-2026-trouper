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

    // Start HIGH and pulse LOW below: trouper_top's SPI-domain flops use
    // `always @(posedge SPI_SCK or negedge rst_n)`, so their reset branch runs
    // only on a real 1->0 edge. Declaring resetb = 1'b0 at time 0 is a level,
    // not an edge, so those flops (spi_we_toggle / spi_re_toggle and the
    // latched address/data) stay X for the whole run, every SPI event toggle
    // reads X, and reg_bank silently never sees a write.
    reg resetb = 1'b1;

    // -----------------------------------------------------------------------
    // DUT pads
    // -----------------------------------------------------------------------
    reg  [3:0] iq_data_i = 4'h0;
    reg  [3:0] iq_data_q = 4'h0;

    wire       remod_a_i, remod_a_q;

    wire        psram_sck, psram_ce_n;
    wire [3:0]  psram_sio_out, psram_sio_oe;
    wire [3:0]  psram_sio_in;   // driven by psram_model
    // Starts LOW so the reset sequence can create a POSEDGE on spi_slave's
    // `spi_frame_arst = HOST_CS | ~rst_n`. That reset is level-sensitive in
    // silicon (the frame FSM is held reset for the whole HOST_CS=1 window) but
    // edge-sensitive in Verilog: with HOST_CS tied high from time 0 the posedge
    // never happens, the frame FSM stays X for the entire first frame, and the
    // first read of the simulation returns 0x00 instead of the addressed byte.

    reg  spi_cs   = 1'b0;
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
                .IQ_DATA_I_0 (iq_data_i[0]),
        .IQ_DATA_I_1 (iq_data_i[1]),
        .IQ_DATA_I_2 (iq_data_i[2]),
        .IQ_DATA_I_3 (iq_data_i[3]),
                .IQ_DATA_Q_0 (iq_data_q[0]),
        .IQ_DATA_Q_1 (iq_data_q[1]),
        .IQ_DATA_Q_2 (iq_data_q[2]),
        .IQ_DATA_Q_3 (iq_data_q[3]),
        .REMOD_A_I_OUT    (remod_a_i),
        .REMOD_A_Q_OUT    (remod_a_q),
        .PSRAM_SCK_OUT    (psram_sck),
        .PSRAM_CE_N_OUT   (psram_ce_n),
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
        .HOST_CS      (spi_cs),
        .SPI_SCK      (spi_sck),
        .SPI_MOSI     (spi_mosi),
        .SPI_MISO_OUT     (spi_miso),
        .IRQ_OUT_OUT      (irq_out),
        // Array acquisition sync: idle high, as the mandatory board
        // pull-up holds it. planning/array-acquisition-sync.md.
        .ARRAY_ACQ_N_IN (1'b1),
        // Debug probes: inputs tied off (the pads are output-only in function);
        // outputs left unconnected.
        .DBG0_IN        (1'b0)
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
            stim_i_tbl[si] = $rtoi(80.0 * $cos(2.0 * pi_r * si / 128.0));
            stim_q_tbl[si] = $rtoi(80.0 * $sin(2.0 * pi_r * si / 128.0));
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
            // First-order SDM: feedback ±127 to match chain gain.
            // Amplitude 80 in stim table → CIC output ≈ 80 → after dc_removal ≈ 52.
            // 52 is safely within int8 and above the sc_detector e_slice guard (≥27).
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
    // 2 MHz, the interface's re-scoped maximum (TRPR-SPS: host SPI is
    // specified up to 2 MHz, derated from 10 MHz). At 8 MHz a read's command
    // byte gives reg_bank's CE-gated readback register only half an SCK period
    // to settle, so the FIRST read after reset returns the reset value instead
    // of the addressed one -- an out-of-spec stimulus artefact, not a DUT bug.
    localparam real SCK_HALF = 250.0;  // ns -> 2 MHz

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
        resetb = 1'b0;                 // 1->0 edge: see the declaration comment
        repeat (4) @(posedge clk);
        resetb = 1'b1;
        spi_cs  = 1'b1;   // posedge on HOST_CS: fires the frame-FSM async reset
        repeat (8) @(posedge clk);

        // -------------------------------------------------------------------
        // 1b. SPI smoke test: read CHIP_ID before touching PSRAM
        // -------------------------------------------------------------------
        spi_read(7'h00, rd);
        $display("DBG   CHIP_ID=0x%02h (expect 0xA7) at cycle %0d", rd, cycle_count);
        spi_read(7'h09, rd);
        $display("DBG   SF_CFG=0x%02h (expect 0x07) at cycle %0d", rd, cycle_count);

        // -------------------------------------------------------------------
        // 2. Enable PSRAM (PSRAM_CTRL 0x70 = 0x01: psram_en=1, qspi_owner=0)
        // -------------------------------------------------------------------
        spi_write(7'h70, 8'h01);
        $display("INFO  PSRAM_CTRL write 0x01 at cycle %0d", cycle_count);

        // Verify write took effect
        repeat (4) @(posedge clk);
        spi_read(7'h70, rd);
        $display("DBG   PSRAM_CTRL readback=0x%02h (expect 0x01) psram_ctrl_int=0x%01h at cycle %0d",
                 rd, dut.u_rb.psram_ctrl, cycle_count);

        // Give PSRAM init plenty of time (init takes ~30 cycles from when init_start asserts)
        repeat (200) @(posedge clk);
        $display("DBG   psram state=%0d qe_init_done=%0b init_start=%0b psram_en=%0b at cycle %0d",
                 dut.u_psram.state, dut.u_psram.qe_init_done,
                 dut.rb_psram_ctrl[0] & ~dut.rb_psram_ctrl[3],
                 dut.rb_psram_ctrl[0], cycle_count);

        // -------------------------------------------------------------------
        // 3. Poll PSRAM_STATUS (0x71) until INIT_DONE (bit 3) = 1
        // -------------------------------------------------------------------
        poll_cnt = 0;
        rd = 8'h00;
        while (!(rd[3]) && poll_cnt < 500) begin
            repeat (8) @(posedge clk);
            spi_read(7'h71, rd);
            if (poll_cnt < 5)
                $display("DBG   PSRAM_STATUS poll[%0d]=0x%02h state=%0d qe=%0b cycle=%0d",
                         poll_cnt, rd, dut.u_psram.state, dut.u_psram.qe_init_done, cycle_count);
            poll_cnt = poll_cnt + 1;
        end
        t_init_done = cycle_count;
        if (rd[3]) begin
            $display("pass  %-30s status=0x%02h at cycle %0d",
                     "PSRAM INIT_DONE", rd, cycle_count);
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL  PSRAM INIT_DONE never set within poll limit (cycle %0d)", cycle_count);
            $display("DBG   qe_init_done=%0b state=%0d psram_ctrl=0x%01h",
                     dut.u_psram.qe_init_done, dut.u_psram.state, dut.rb_psram_ctrl);
            fail_count = fail_count + 1;
        end

        // -------------------------------------------------------------------
        // 4. Wait for IRQ_OUT (sc_lock) — poll IRQ_STATUS (0x02) bit 0
        //    Default sc_thr=0x01CC, sc_hits_req=2 are sufficient for a
        //    perfect sinusoidal preamble (math verified in tb comments).
        // -------------------------------------------------------------------
        // sc_thr: detector consumes the unsigned low 12 bits only.
        // Use 0x0100 = sc_thr[11:0]=256 to give this directed test extra margin.
        spi_write(7'h0C, 8'h01);   // sc_thr[15:8] = 0x01
        spi_write(7'h0D, 8'h00);   // sc_thr[7:0]  = 0x00  → sc_thr = 0x0100 = 256
        spi_write(7'h0E, 8'h01);   // sc_hits_req  = 1 (need 2 consecutive hits)
        $display("INFO  sc_thr=0x0100, sc_hits_req=1 set at cycle %0d", cycle_count);

        // RX_HOLD (0x1A[0]) is SET out of reset -- the receiver comes up
        // disabled so that "config writable" and "detector able to lock" are
        // mutually exclusive (Open Risks #43, planning/mcp-config-settle-gate-
        // design.md 4a).  It must be released here, AFTER the gated config
        // writes above (SF_CFG/BW_CFG/PKT_TIMEOUT_SYMS/SC_HITS_REQ/
        // TACC_WINDOW_SYMS): once released hardware refuses those writes and
        // silently keeps the previous values.  Without this the detector never
        // sees a sample and every case aborts on "sc_lock never fired".
        spi_write(7'h1A, 8'h00);   // release RX_HOLD

        $display("INFO  waiting for sc_lock (IRQ_STATUS[0])...");
        rd = 8'h00;
        poll_cnt = 0;
        while (!(rd[0]) && poll_cnt < 5000) begin
            repeat (128) @(posedge clk);   // ~1 iq_valid period
            spi_read(7'h02, rd);
            // Print diagnostics for first 10 polls and every 100 after that
            if (poll_cnt < 10 || (poll_cnt % 100) == 0) begin
                $display("DBG   sc poll[%0d] del_rdy=%0b tdm_busy=%0b sym_cnt=%0d acc_ci0=%0d eval_busy=%0b sym_mag=%0d sc_stat=%0d cycle=%0d",
                         poll_cnt,
                         dut.u_psram.del_rdy,
                         dut.u_sc.tdm_busy,
                         dut.u_sc.sym_cnt,
                         dut.u_sc.acc_ci0,
                         dut.u_sc.eval_busy,
                         dut.u_sc.sym_mag_sc,
                         dut.u_sc.sc_stat,
                         cycle_count);
            end
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
        //    Equal-gain combining: W_re=0x40 (≈0.5 in Q0.7), W_im=0x00.
        //    The 128-bit shadow word is big-endian over 16 bytes (0x30=MSB).
        //    mrc_combiner reads W_rek from even byte-pair slots:
        //      0x30=W_re0, 0x31=unused, 0x32=W_im0, 0x33=unused,
        //      0x34=W_re1, 0x35=unused, 0x36=W_im1, 0x37=unused,
        //      0x38=W_re2, 0x39=unused, 0x3A=W_im2, 0x3B=unused,
        //      0x3C=W_re3, 0x3D=unused, 0x3E=W_im3, 0x3F=unused.
        //    Burst: {0x40,0,0,0} × 4 sets W_rek=0x40, W_imk=0x00.
        // -------------------------------------------------------------------
        begin : write_weights
            reg [7:0] dump;
            integer ww;
            spi_start;
            spi_byte({1'b0, 7'h30}, dump);
            for (ww = 0; ww < 4; ww = ww + 1) begin
                spi_byte(8'h40, dump);   // W_re_k = 0x40 (≈0.5)
                spi_byte(8'h00, dump);   // unused slot
                spi_byte(8'h00, dump);   // W_im_k = 0x00
                spi_byte(8'h00, dump);   // unused slot
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
