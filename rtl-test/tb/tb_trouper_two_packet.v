// tb_trouper_two_packet.v
// Directed two-packet integration testbench for trouper_top.
//
// Purpose: verify the sc_lock re-arm and IRQ edge-set fixes (Open Risks #2, #3;
// TRPR-SCD-014, TRPR-IRQ-002/006). The original RTL latched sc_lock until RESETB
// (one-shot receiver) and fed sc_lock/training_done into IRQ_STATUS as held
// levels (un-clearable). This TB drives a continuous preamble-like sinusoid so
// the packet FSM cycles naturally, and checks:
//
//   PK1-1  first sc_lock fires (IRQ_STATUS[0]) — baseline acquisition
//   IRQ-1  IRQ_STATUS[0] is clearable while sc_lock is STILL asserted (level):
//          the discriminating check for the edge-set fix. With the old
//          level-driven irq_set, the bit would immediately re-assert.
//   ARM-1  sc_lock de-asserts when the packet FSM returns to IDLE (re-arm) —
//          on the buggy RTL sc_lock would stay high forever here.
//   PK2-1  a SECOND sc_lock fires (IRQ_STATUS[0]) — proves the receiver is no
//          longer one-shot (the core re-acquisition check).
//   PK2-2  training_done (IRQ_STATUS[1]) fires again on packet 2 — proves
//          training_acc re-armed on !sc_lock.
//   IRQ-2  IRQ_STATUS[0] is clearable again after the second lock.
//
// Stimulus / config are identical to tb_trouper_top.v (SF7, 250 kHz default,
// M=256 decimated samples = one sinusoid period). PKT_TIMEOUT_SYMS is shortened
// so two full packets complete well inside the global timeout.
//
// Run (see Makefile target sim_trouper_two_packet):
//   iverilog -g2012 -o tb_trouper_two_packet.vvp \
//     tb/tb_trouper_two_packet.v $(TROUPER_TOP_SRCS)
//   vvp tb_trouper_two_packet.vvp

`timescale 1ns/1ps
`default_nettype none

module tb_trouper_two_packet;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk = 1'b0;
    always #15.625 clk = ~clk;   // 32 MHz

    // Start deasserted, then pulse low: the SPI-domain frame flops reset on a
    // genuine negedge of rst_n (models a real power-on-reset edge), so the fix
    // for Open Risks #26 is exercised without a warm-up SPI transaction.
    reg resetb = 1'b1;

    // -----------------------------------------------------------------------
    // DUT pads
    // -----------------------------------------------------------------------
    reg  [3:0] iq_data_i = 4'h0;
    reg  [3:0] iq_data_q = 4'h0;

    wire       remod_a_i, remod_a_q;

    wire        psram_sck, psram_ce_n;
    wire [3:0]  psram_sio_out, psram_sio_oe;
    wire [3:0]  psram_sio_in;

    reg  spi_cs   = 1'b0;   // held low across the reset pulse (see reset seq)
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
    // Sinusoidal stimulus: amplitude=80, period=128 decimated samples.
    // Continuous tone -> looks like an endless preamble, so the packet FSM
    // re-acquires on its own after each packet returns to IDLE.
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
    reg [6:0] bit_cnt;

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

            iq_data_i <= {4{sdm_bit_i}};
            iq_data_q <= {4{sdm_bit_q}};

            if (bit_cnt == 7'd127) begin
                bit_cnt  <= 7'd0;
                sine_ptr <= sine_ptr + 7'd1;
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

    task pass_msg;
        input [255:0] name;
        begin
            $display("pass  %-40s at cycle %0d", name, cycle_count);
            pass_count = pass_count + 1;
        end
    endtask

    task fail_msg;
        input [255:0] name;
        begin
            $display("FAIL  %-40s at cycle %0d", name, cycle_count);
            fail_count = fail_count + 1;
        end
    endtask

    task check_true;
        input [255:0] name;
        input         cond;
        begin
            if (cond) pass_msg(name);
            else      fail_msg(name);
        end
    endtask

    always @(posedge clk) if (resetb) cycle_count <= cycle_count + 1;

    // -----------------------------------------------------------------------
    // Reusable poll helpers (drive real time while polling internal/SPI state)
    // -----------------------------------------------------------------------
    reg [7:0] rd;
    integer   poll_cnt;

    // Poll IRQ_STATUS (0x02) over SPI until `bit_idx` is 1 or the limit is hit.
    task wait_irq_bit;
        input integer bit_idx;
        input integer limit;
        output        ok;
        begin
            rd = 8'h00;
            poll_cnt = 0;
            ok = 1'b0;
            while (!ok && poll_cnt < limit) begin
                repeat (128) @(posedge clk);
                spi_read(7'h02, rd);
                if (rd[bit_idx]) ok = 1'b1;
                poll_cnt = poll_cnt + 1;
            end
        end
    endtask

    // Wait until the detector's internal sc_lock returns to 0 (re-arm).
    task wait_sc_unlock;
        input integer limit;
        output        ok;
        begin
            poll_cnt = 0;
            ok = 1'b0;
            while (!ok && poll_cnt < limit) begin
                repeat (64) @(posedge clk);
                if (dut.u_sc.sc_lock === 1'b0) ok = 1'b1;
                poll_cnt = poll_cnt + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    integer t_lock1, t_unlock, t_lock2;
    reg     ok;

    initial begin
        $dumpfile("tb_trouper_two_packet.vcd");
        $dumpvars(1, tb_trouper_two_packet);

        pass_count  = 0;
        fail_count  = 0;
        cycle_count = 0;
        t_lock1     = -1;
        t_unlock    = -1;
        t_lock2     = -1;

        // 1. Reset. Hold CS low across the reset pulse so the SPI frame
        // async-reset term (HOST_CS | ~rst_n) actually toggles 0→1 in sim when
        // rst_n asserts — with CS already high the term is masked and iverilog
        // never applies the reset (silicon uses a level-sensitive reset pin, so
        // this is only a behavioral-sim modelling detail). Then idle CS high.
        repeat (2) @(posedge clk);
        resetb = 1'b0;
        repeat (4) @(posedge clk);
        resetb = 1'b1;
        spi_cs = 1'b1;               // idle high; first real transaction pulls it low
        repeat (8) @(posedge clk);

        // 2. Enable PSRAM and wait for INIT_DONE.
        //    NOTE: no SPI warm-up read here on purpose — the PSRAM-enable write
        //    is the FIRST transaction after reset. This directly exercises the
        //    spi_slave power-on-reset fix (Open Risks #26): before the fix the
        //    frame flops were uninitialised until the first CS rising edge, so
        //    this write was dropped and PSRAM never initialised.
        spi_write(7'h70, 8'h01);
        repeat (200) @(posedge clk);
        poll_cnt = 0;
        rd = 8'h00;
        while (!(rd[3]) && poll_cnt < 500) begin
            repeat (8) @(posedge clk);
            spi_read(7'h71, rd);
            poll_cnt = poll_cnt + 1;
        end
        check_true("PSRAM INIT_DONE", rd[3]);

        // 3. Detector threshold + short packet timeout so two packets fit.
        //    sc_thr = 0x0100 (256), sc_hits_req = 1 (2 consecutive hits).
        //    PKT_TIMEOUT_SYMS = 16 : long enough to pass W_PENDING timeout
        //    (~13 symbols) and spend a payload phase, short enough for 2 packets.
        spi_write(7'h0C, 8'h01);   // sc_thr[15:8]
        spi_write(7'h0D, 8'h00);   // sc_thr[7:0]  -> 0x0100
        spi_write(7'h0E, 8'h01);   // sc_hits_req = 1
        spi_write(7'h0B, 8'h10);   // PKT_TIMEOUT_SYMS = 16
        $display("INFO  sc_thr=0x0100 hits_req=1 pkt_timeout=16 at cycle %0d", cycle_count);

        // RX_HOLD (0x1A[0]) is SET out of reset -- the receiver comes up
        // disabled so that "config writable" and "detector able to lock" are
        // mutually exclusive (Open Risks #43, planning/mcp-config-settle-gate-
        // design.md 4a).  It must be released here, AFTER the gated config
        // writes above (SF_CFG/BW_CFG/PKT_TIMEOUT_SYMS/SC_HITS_REQ/
        // TACC_WINDOW_SYMS): once released hardware refuses those writes and
        // silently keeps the previous values.  Without this the detector never
        // sees a sample and every case aborts on "sc_lock never fired".
        spi_write(7'h1A, 8'h00);   // release RX_HOLD

        // -------------------------------------------------------------------
        // PACKET 1: acquire
        // -------------------------------------------------------------------
        $display("INFO  waiting for FIRST sc_lock (IRQ_STATUS[0])...");
        wait_irq_bit(0, 5000, ok);
        t_lock1 = cycle_count;
        check_true("PK1-1 first sc_lock (IRQ[0])", ok);
        if (!ok) begin
            $display("FAIL  --- aborting: first lock never occurred ---");
            $display("Results: %0d passed, %0d failed", pass_count, fail_count);
            $finish;
        end

        // -------------------------------------------------------------------
        // IRQ edge-set discriminating check: sc_lock is still asserted (level),
        // yet an IRQ_CLEAR write must clear IRQ_STATUS[0] and it must STAY clear.
        // On the old level-driven irq_set this bit would re-assert immediately.
        // -------------------------------------------------------------------
        check_true("IRQ-1a sc_lock still high pre-clear", dut.u_sc.sc_lock === 1'b1);
        spi_write(7'h03, 8'hFF);            // IRQ_CLEAR
        repeat (256) @(posedge clk);        // dwell while sc_lock level persists
        check_true("IRQ-1b sc_lock still high post-clear", dut.u_sc.sc_lock === 1'b1);
        spi_read(7'h02, rd);
        check_true("IRQ-1c IRQ[0] stays clear (edge-set)", rd[0] === 1'b0);

        // -------------------------------------------------------------------
        // ARM-1: sc_lock must de-assert when the packet FSM returns to IDLE.
        // On the buggy one-shot RTL this never happens.
        // -------------------------------------------------------------------
        $display("INFO  waiting for sc_lock re-arm (internal de-assert)...");
        wait_sc_unlock(20000, ok);
        t_unlock = cycle_count;
        check_true("ARM-1 sc_lock de-asserts at IDLE", ok);

        // Clear IRQ again so PACKET 2's lock is unambiguously a fresh edge.
        spi_write(7'h03, 8'hFF);
        repeat (64) @(posedge clk);
        spi_read(7'h02, rd);
        check_true("ARM-1b IRQ[0] clear after re-arm", rd[0] === 1'b0);

        // -------------------------------------------------------------------
        // PACKET 2: the receiver must acquire again (not one-shot).
        // -------------------------------------------------------------------
        $display("INFO  waiting for SECOND sc_lock (IRQ_STATUS[0])...");
        wait_irq_bit(0, 5000, ok);
        t_lock2 = cycle_count;
        check_true("PK2-1 second sc_lock (IRQ[0])", ok);

        // -------------------------------------------------------------------
        // PK2-2: training_acc re-armed on !sc_lock -> training_done fires again.
        // -------------------------------------------------------------------
        spi_write(7'h03, 8'hFF);            // clear so we see a fresh training_done
        $display("INFO  waiting for SECOND training_done (IRQ_STATUS[1])...");
        wait_irq_bit(1, 10000, ok);
        check_true("PK2-2 second training_done (IRQ[1])", ok);

        // -------------------------------------------------------------------
        // IRQ-2: bits remain clearable on the second packet too.
        // -------------------------------------------------------------------
        spi_write(7'h03, 8'hFF);
        repeat (256) @(posedge clk);
        spi_read(7'h02, rd);
        check_true("IRQ-2 IRQ[1] clearable on pkt2", rd[1] === 1'b0);

        // -------------------------------------------------------------------
        // Done
        // -------------------------------------------------------------------
        $display("------------------------------------------------------------");
        if (fail_count == 0)
            $display("TB PASS - %0d checks passed", pass_count);
        else
            $display("TB FAIL - %0d passed, %0d failed", pass_count, fail_count);
        $display("  t_lock1=%0d  t_unlock=%0d  t_lock2=%0d", t_lock1, t_unlock, t_lock2);
        $display("------------------------------------------------------------");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Global timeout
    // -----------------------------------------------------------------------
    initial begin
        #300_000_000;   // 300 ms -> ~9.6M cycles at 32 MHz
        $display("TB FAIL - global timeout");
        $display("  cycle_count=%0d t_lock1=%0d t_unlock=%0d t_lock2=%0d",
                 cycle_count, t_lock1, t_unlock, t_lock2);
        if (t_lock1  < 0) $display("  first sc_lock never fired");
        if (t_unlock < 0) $display("  sc_lock never de-asserted (one-shot?)");
        if (t_lock2  < 0) $display("  second sc_lock never fired (one-shot?)");
        $finish;
    end

endmodule

`default_nettype wire
