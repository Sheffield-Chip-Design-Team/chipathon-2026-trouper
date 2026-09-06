// tb_psram_model.v
// Cosimulation of psram_buf_ctrl ⇄ psram_model (BRAM-backed APS6404L model).
// Validates the SC delay-line path: after N = 2^(SF+sample_shift) iq_valid
// samples, the del_i0/del_q0 outputs must equal the branch-0 sample written
// N samples ago (see psram_buf_ctrl.v's del_n_c derivation).
//
// Build with: verilator --binary --timing  (top tb_psram_model).

`timescale 1ns/1ps
`default_nettype none
module tb_psram_model;
    localparam SF           = 7;      // smallest LoRa SF
    localparam SAMPLE_SHIFT = 1;      // 250 kHz BW, 2x oversample
    localparam N  = (1 << (SF + SAMPLE_SHIFT));  // 256 sample delay
    localparam integer PERIOD = 128;  // clk cycles per iq_valid (250 kHz @32 MHz)

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #15.625 clk = ~clk;        // 32 MHz

    // IQ stimulus — branch 0 gets a known ramp; others fixed.
    reg signed [7:0] iq_i0 = 8'sd0, iq_q0 = 8'sd0;
    reg iq_valid = 1'b0;

    // QPI pad nets between controller and model.
    wire        sck, ce_n;
    wire [3:0]  sio_out, sio_oe;
    wire [3:0]  sio_in;

    // SC delay outputs.
    wire signed [7:0] cur_i0, cur_q0, del_i0, del_q0;
    wire              del_valid;

    // ---- DUT: PSRAM buffer controller ----
    psram_buf_ctrl u_buf (
        .clk_32m (clk), .rst_n (rst_n),
        .psram_en (1'b1), .init_start (1'b1), .qspi_owner (1'b0),
        .sf (SF[3:0]), .sample_shift (SAMPLE_SHIFT[1:0]),
        .sc_ant_sel (2'd0),                     // SC path follows branch 0
        .iq_i0 (iq_i0), .iq_i1 (8'sd0), .iq_i2 (8'sd0), .iq_i3 (8'sd0),
        .iq_q0 (iq_q0), .iq_q1 (8'sd0), .iq_q2 (8'sd0), .iq_q3 (8'sd0),
        .iq_valid (iq_valid),
        .sc_lock (1'b0), .timing_ref (32'd0), .iq_sample_cnt (32'd0),
        .training_done (1'b0), .replay_delay_samples (16'd0),
        .W_commit (1'b0), .packet_end (1'b0), .packet_active (1'b0),
        .clr_err (1'b0),
        .sck (sck), .sck_en_o (), .ce_n (ce_n), .sio_out (sio_out),
        .sio_in (sio_in), .sio_oe (sio_oe),
        .cur_i0 (cur_i0), .cur_q0 (cur_q0),
        .del_i0 (del_i0), .del_q0 (del_q0), .del_valid (del_valid),
        .rpl_i0 (), .rpl_i1 (), .rpl_i2 (), .rpl_i3 (),
        .rpl_q0 (), .rpl_q1 (), .rpl_q2 (), .rpl_q3 (),
        .rpl_valid (),
        .buf_active (), .replay_active (),
        .qe_init_done (), .replay_missed (), .w_commit_late (),
        .overflow (), .sample_skip (),
        .state_dbg (),
        .del_rdy_dbg (),
        .dbg_addr (23'd0), .dbg_auto_inc (1'b0), .dbg_rd_trig (1'b0),
        .dbg_data_pop (1'b0), .dbg_busy (), .dbg_data (),
        .dbg_wdata (8'd0), .dbg_wdata_push (1'b0), .dbg_wr_trig (1'b0)
    );

    // ---- Model: BRAM-backed PSRAM ----
    psram_model #(.ADDR_BITS(16), .RD_LAUNCH_SKIP(3)) u_psram (
        .clk_32m (clk), .rst_n (rst_n),
        .ce_n (ce_n), .sio_out (sio_out), .sio_oe (sio_oe),
        .sio_in (sio_in)
    );

    // Reference model of the expected delay: ring of the last N branch-0 samples.
    reg signed [7:0] ref_i [0:4095];
    reg signed [7:0] ref_q [0:4095];
    integer wr_idx = 0;       // count of samples issued
    integer errors = 0;
    integer checks = 0;

    // Drive iq_valid pulses with a ramp on branch 0.
    integer s;
    initial begin
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        // Let QE init finish (init sequence is well under a few hundred cycles).
        repeat (600) @(posedge clk);

        for (s = 0; s < N + 64; s = s + 1) begin
            @(posedge clk);
            iq_i0 = s[7:0];
            iq_q0 = (8'sd127 - s[7:0]);
            ref_i[s % 4096] = iq_i0;
            ref_q[s % 4096] = iq_q0;
            iq_valid = 1'b1;
            @(posedge clk);
            iq_valid = 1'b0;
            wr_idx = s + 1;
            // wait out the rest of the sample period
            repeat (PERIOD - 2) @(posedge clk);
        end

        repeat (200) @(posedge clk);
        if (checks == 0) begin
            $display("FAIL: del_valid never asserted (no checks ran)");
            errors = errors + 1;
        end
        $display("=== tb_psram_model done: %0d checks, %0d errors ===",
                 checks, errors);
        if (errors == 0) $display("PSRAM MODEL PASS");
        else             $display("PSRAM MODEL FAIL");
        $finish;
    end

    // Check del outputs against the reference N-sample delay.
    always @(posedge clk) begin
        if (rst_n && del_valid) begin
            // del should equal the sample issued N writes ago. The current write
            // is sample (wr_idx-1); its N-delayed partner is (wr_idx-1-N).
            integer di;
            di = wr_idx - 1 - N;
            if (di >= 0) begin
                checks = checks + 1;
                if (del_i0 !== ref_i[di % 4096] || del_q0 !== ref_q[di % 4096]) begin
                    errors = errors + 1;
                    $display("MISMATCH @sample %0d: del=(%0d,%0d) expected=(%0d,%0d)",
                             wr_idx-1, del_i0, del_q0,
                             ref_i[di % 4096], ref_q[di % 4096]);
                end
            end
        end
    end

    // Safety timeout.
    initial begin
        #( (N + 300) * PERIOD * 32 );
        $display("FAIL: timeout");
        $finish;
    end
endmodule
`default_nettype wire
