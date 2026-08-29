// spi_slave_formal.sv
// Formal checker for spi_slave.v — first formal coverage of this module
// (2026-08-23), closing verification-plan rows #13 and #15
// (planning/verification-plan/spi-slave-verification-plan.md).
//
// spi_slave.v is genuinely two-clock: the serial/frame engine runs from the
// asynchronous SPI_SCK, and register writes/read side effects cross into
// clk_32m via a toggle synchronizer + bundled-data mailbox (see
// planning/spi-slave-cdc-and-10mhz-timing-plan.md). This checker is proved
// with `multiclock on` (see spi_slave.sby) so the SMT engine treats SPI_SCK
// and clk_32m as genuinely independent free-running clocks each BMC step,
// rather than assuming a single shared clock the way the single-clock
// psram_buf_ctrl_formal.sv / packet_ctrl_fsm_formal.sv checkers can.
//
// Same yosys formal-subset conventions as the other checkers in this
// directory: no SVA property/endproperty, no |->/|=>, no `bind` (silently
// dropped by this yosys version — confirmed empirically for the other two
// checkers). Properties are plain registered "previous value" compares
// followed by a procedural assert/assume inside an always block. NOT bound
// in; instantiated directly inside spi_slave.v under `ifdef FORMAL, guarded
// exactly like u_psram_formal / u_pcfsm_formal.
//
// Property groups:
//   A. Legal 7-bit address progression (command capture / +1 wrap / 0x76 hold)
//   B. CS frame reset clears only transaction-local frame state, never the
//      persistent toggle/mailbox event storage (the 2026-07 CDC redesign's
//      central architectural claim)
//   C. Partial-frame suppression: a toggle event's SPI-domain cause is
//      always a genuinely completed byte in the right role, never a partial
//      byte or the wrong direction
//   D. Row #13: conservative environment assumption stronger than legal 2 MHz SCK operation
//      cannot produce two source toggle events closer together than the
//      3-stage clk_32m synchronizer needs, PLUS the row #15 proof that under
//      that assumption every event is delivered exactly once, within a
//      bounded number of clk_32m cycles, with its mailbox contents intact.
//   E. Non-vacuity cover statements (see spi_slave.sby's separate `cover`
//      task).
//
// Proved with `mode bmc` (bounded, reset-anchored), not `mode prove`
// (BMC + k-induction) — see spi_slave.sby's [options] comment for why
// k-induction's unconstrained hypothesis window is unsound for this
// checker's cross-clock delayed-compare trackers (we_tog_sck_q vs
// spi_we_toggle etc.), confirmed by a real k=1 induction counterexample
// (SGE job 4852) that is not a reachable-from-reset scenario.
//
// Run: cd formal && (inside chipathon26 container) sby -f spi_slave.sby bmc
//      and                                          sby -f spi_slave.sby cover

`default_nettype none

module spi_slave_formal (
    input  wire        clk_32m,
    input  wire        rst_n,

    input  wire        HOST_CS,
    input  wire        SPI_SCK,
    input  wire        SPI_MOSI,
    input  wire        SPI_MISO,

    input  wire [7:0]  reg_wr_addr,
    input  wire [7:0]  reg_wdata,
    input  wire        reg_we,
    input  wire [7:0]  reg_rd_addr,
    input  wire [7:0]  reg_re_addr,
    input  wire        reg_re,
    input  wire [7:0]  reg_rdata,

    // internals
    input  wire [7:0]  spi_shreg,
    input  wire [2:0]  spi_bit_cnt,
    input  wire        have_cmd,
    input  wire        fp_rw,
    input  wire [6:0]  cur_addr,

    input  wire        spi_we_toggle,
    input  wire        spi_re_toggle,
    input  wire [6:0]  spi_wr_addr_lat,
    input  wire [7:0]  spi_wdata_lat,
    input  wire [6:0]  spi_re_addr_lat,

    input  wire        spi_we_sync0,
    input  wire        spi_we_sync1,
    input  wire        spi_we_sync2,
    input  wire        spi_re_sync0,
    input  wire        spi_re_sync1,
    input  wire        spi_re_sync2,
    input  wire        reg_we_p
);

    localparam [6:0] NO_INC_ADDR = 7'h76;

    // -----------------------------------------------------------------------
    // Reset modeling — see psram_buf_ctrl_formal.sv for the rationale: force
    // step 0 to genuinely see rst_n low so every register starts at its real
    // reset value rather than an arbitrary BMC-chosen one.
    // -----------------------------------------------------------------------
    initial assume (!rst_n);

    // Recompute the DUT's frame-reset term locally (a plain expression of
    // already-visible primary inputs, not an internal net worth a port).
    wire spi_frame_arst = HOST_CS | ~rst_n;

    // -----------------------------------------------------------------------
    // Frame-domain trackers (mirror spi_shreg/spi_bit_cnt/have_cmd/fp_rw/
    // cur_addr's own reset domain exactly: posedge SPI_SCK or posedge
    // spi_frame_arst). These hold the pre-this-edge value of each signal,
    // which is what the DUT's own combinational byte_now/persistent-event
    // block reads on the same edge (nonblocking-assignment simultaneity).
    // -----------------------------------------------------------------------
    reg [7:0] spi_shreg_q;
    reg [2:0] spi_bit_cnt_q;
    reg       have_cmd_q;
    reg       fp_rw_q;
    reg [6:0] cur_addr_q;
    // SPI_MOSI is a primary input (not registered), sampled combinationally
    // by the DUT's byte_now at the SAME edge that produced spi_shreg_q's
    // captured value; this checker's assertions run one edge later than that
    // capture, so SPI_MOSI must be tracked with the same one-edge delay or
    // byte_now_chk would pair a stale spi_shreg with a too-new MOSI bit.
    reg       spi_mosi_q;

    always @(posedge SPI_SCK or posedge spi_frame_arst) begin
        if (spi_frame_arst) begin
            spi_shreg_q   <= 8'd0;
            spi_bit_cnt_q <= 3'd0;
            have_cmd_q    <= 1'b0;
            fp_rw_q       <= 1'b0;
            cur_addr_q    <= 7'd0;
            spi_mosi_q    <= 1'b0;
        end else begin
            spi_shreg_q   <= spi_shreg;
            spi_bit_cnt_q <= spi_bit_cnt;
            have_cmd_q    <= have_cmd;
            fp_rw_q       <= fp_rw;
            cur_addr_q    <= cur_addr;
            spi_mosi_q    <= SPI_MOSI;
        end
    end

    wire [7:0] byte_now_chk = {spi_shreg_q[6:0], spi_mosi_q};

    // -----------------------------------------------------------------------
    // Persistent-event trackers (mirror spi_we_toggle/spi_re_toggle/
    // spi_wr_addr_lat/spi_wdata_lat/spi_re_addr_lat's own reset domain
    // exactly: posedge SPI_SCK or negedge rst_n only — HOST_CS must NOT
    // reset these, that is the entire point of group B below).
    // -----------------------------------------------------------------------
    reg       we_tog_sck_q, re_tog_sck_q;
    reg [6:0] we_addr_sck_q, re_addr_sck_q;
    reg [7:0] wdata_sck_q;
    // HOST_CS is a primary input read combinationally by the DUT's
    // persistent-event block at the SAME edge that gates its update; like
    // SPI_MOSI above, this checker's own assertions run one edge later, so
    // HOST_CS must be tracked with the same one-edge delay to correctly
    // reconstruct the condition that gated the transition into the current
    // step.
    reg       host_cs_sck_q;
    // have_cmd/fp_rw/spi_bit_cnt as seen by the PERSISTENT-EVENT block,
    // tracked with the SAME reset domain as that block (negedge rst_n only).
    // Deliberately a separate copy from group A's frame-domain trackers
    // below: on an edge where HOST_CS rises on the very same SPI_SCK edge
    // that completes a byte (spi_frame_arst asserting simultaneously with
    // the triggering posedge), the real DUT's persistent-event block still
    // correctly fires off the true pre-edge have_cmd/fp_rw/spi_bit_cnt
    // (nonblocking-assignment simultaneity — this is the documented
    // "load-then-advance" read-side-effect behavior, not a bug), while a
    // tracker sharing spi_frame_arst's reset would incorrectly see 0 on that
    // same edge. Confirmed by a real BMC counterexample during development
    // (SGE job 4849): HOST_CS rising exactly on the SCK edge that starts a
    // read data byte's first bit legitimately still produces the
    // spi_re_toggle flip.
    reg       have_cmd_evt_q, fp_rw_evt_q;
    reg [2:0] spi_bit_cnt_evt_q;

    always @(posedge SPI_SCK or negedge rst_n) begin
        if (!rst_n) begin
            we_tog_sck_q      <= 1'b0;
            re_tog_sck_q      <= 1'b0;
            we_addr_sck_q     <= 7'd0;
            wdata_sck_q       <= 8'd0;
            re_addr_sck_q     <= 7'd0;
            host_cs_sck_q     <= 1'b1;
            have_cmd_evt_q    <= 1'b0;
            fp_rw_evt_q       <= 1'b0;
            spi_bit_cnt_evt_q <= 3'd0;
        end else begin
            we_tog_sck_q      <= spi_we_toggle;
            re_tog_sck_q      <= spi_re_toggle;
            we_addr_sck_q     <= spi_wr_addr_lat;
            wdata_sck_q       <= spi_wdata_lat;
            re_addr_sck_q     <= spi_re_addr_lat;
            host_cs_sck_q     <= HOST_CS;
            have_cmd_evt_q    <= have_cmd;
            fp_rw_evt_q       <= fp_rw;
            spi_bit_cnt_evt_q <= spi_bit_cnt;
        end
    end

    // -----------------------------------------------------------------------
    // A. Legal 7-bit address progression (row #15's "legal address
    // progression" clause). Frame reset itself (cur_addr -> 0) is covered by
    // group B's a_frame_*_clear asserts below.
    // -----------------------------------------------------------------------
    always @(posedge SPI_SCK or posedge spi_frame_arst) begin
        if (!spi_frame_arst) begin
            if (spi_bit_cnt_q == 3'd7) begin
                if (!have_cmd_q)
                    a_addr_cmd_capture: assert (cur_addr == byte_now_chk[6:0]);
                else if (cur_addr_q == NO_INC_ADDR)
                    a_addr_hold_0x76: assert (cur_addr == cur_addr_q);
                else
                    // 7-bit reg wraps mod 128 for free at 0x7F -> 0x00.
                    a_addr_incr_wrap: assert (cur_addr == cur_addr_q + 7'd1);
            end else begin
                a_addr_stable_mid_byte: assert (cur_addr == cur_addr_q);
            end
        end
    end

    // -----------------------------------------------------------------------
    // B. CS frame reset clears only transaction-local state (row #15's "CS
    // frame reset" clause). Frame state clears exactly on spi_frame_arst;
    // the persistent toggle/mailbox regs are untouched by any HOST_CS-only
    // deassertion (rst_n stays 1 across it) — the central claim of the
    // 2026-07 CDC redesign (planning/spi-slave-cdc-and-10mhz-timing-plan.md
    // "Separate frame reset from event storage").
    // -----------------------------------------------------------------------
    always @(posedge SPI_SCK or posedge spi_frame_arst)
        if (spi_frame_arst) begin
            a_frame_shreg_clear:   assert (spi_shreg   == 8'd0);
            a_frame_bitcnt_clear:  assert (spi_bit_cnt == 3'd0);
            a_frame_havecmd_clear: assert (have_cmd    == 1'b0);
            a_frame_fprw_clear:    assert (fp_rw        == 1'b0);
            a_frame_addr_clear:    assert (cur_addr    == 7'd0);
        end

    // Persistent event storage is sensitive only to posedge SPI_SCK / negedge
    // rst_n, so a HOST_CS-only deassertion cannot change it on this edge (and
    // by induction, cannot change it across any window with rst_n held high).
    always @(posedge SPI_SCK or negedge rst_n)
        if (rst_n && host_cs_sck_q) begin
            a_mailbox_persists_we: assert (spi_we_toggle   == we_tog_sck_q &&
                                            spi_wr_addr_lat == we_addr_sck_q &&
                                            spi_wdata_lat   == wdata_sck_q);
            a_mailbox_persists_re: assert (spi_re_toggle   == re_tog_sck_q &&
                                            spi_re_addr_lat == re_addr_sck_q);
        end

    // -----------------------------------------------------------------------
    // C. Partial-frame suppression (row #15's "partial-frame suppression"
    // clause): a toggle can only flip for the exact byte-completion role the
    // spec defines — never for an aborted/partial byte, and never for the
    // wrong direction.
    // -----------------------------------------------------------------------
    always @(posedge SPI_SCK or negedge rst_n)
        if (rst_n) begin
            if (spi_we_toggle != we_tog_sck_q)
                a_we_toggle_cause: assert (!host_cs_sck_q && spi_bit_cnt_evt_q == 3'd7 &&
                                            have_cmd_evt_q && !fp_rw_evt_q);
            if (spi_re_toggle != re_tog_sck_q)
                a_re_toggle_cause: assert (!host_cs_sck_q && spi_bit_cnt_evt_q == 3'd0 &&
                                            have_cmd_evt_q && fp_rw_evt_q);
        end

    // -----------------------------------------------------------------------
    // D. Row #13 (legal byte-spacing bound) + row #15 (event conservation,
    // exactly-once delivery, mailbox stability) in the clk_32m domain.
    // -----------------------------------------------------------------------
    reg we_tog_c_q, re_tog_c_q;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) begin
            we_tog_c_q <= 1'b0;
            re_tog_c_q <= 1'b0;
        end else begin
            we_tog_c_q <= spi_we_toggle;
            re_tog_c_q <= spi_re_toggle;
        end

    // Saturating clk_32m-cycle counters since the last observed toggle
    // change, sampled in the clk_32m domain.
    reg [7:0] we_gap_cnt, re_gap_cnt;
    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) begin
            we_gap_cnt <= 8'd0;
            re_gap_cnt <= 8'd0;
        end else begin
            we_gap_cnt <= (spi_we_toggle != we_tog_c_q) ? 8'd0 :
                          (we_gap_cnt == 8'hFF ? we_gap_cnt : we_gap_cnt + 8'd1);
            re_gap_cnt <= (spi_re_toggle != re_tog_c_q) ? 8'd0 :
                          (re_gap_cnt == 8'hFF ? re_gap_cnt : re_gap_cnt + 8'd1);
        end

    // Environment assumption for row #13: TRPR-SPS-004 caps SPI_SCK at
    // 2 MHz (the bound retained here is conservative), and a source toggle event fires at most once per completed
    // byte (8 SCK periods); against clk_32m at 32 MHz that is >= 25.6 core
    // cycles per event (spi_slave.v's own header comment: "at least one byte
    // (800 ns) apart ... >25 clk_32m cycles"). Assumed here as the concrete,
    // spec-derived lower bound the RTL comment claims; asserted below is the
    // actual proof obligation this bound exists to satisfy — that the
    // 3-stage synchronizer never has two events in flight at once.
    always @(posedge clk_32m)
        if (rst_n && (spi_we_toggle != we_tog_c_q))
            m_we_min_byte_spacing: assume (we_gap_cnt >= 8'd25);
    always @(posedge clk_32m)
        if (rst_n && (spi_re_toggle != re_tog_c_q))
            m_re_min_byte_spacing: assume (re_gap_cnt >= 8'd25);

    // "Credit" abstraction: one bit is enough because the min-gap assumption
    // (>=25 cycles) vastly exceeds the synchronizer's structural latency
    // (<=3 stages) proved bounded below — so at most one event is ever
    // outstanding. Set on a new toggle flip, cleared on the corresponding
    // edge-detect pulse.
    wire we_edge = spi_we_sync1 ^ spi_we_sync2;
    wire re_edge = spi_re_sync1 ^ spi_re_sync2;

    reg we_credit, re_credit;
    reg [3:0] we_credit_age, re_credit_age;
    reg [6:0] we_addr_snap, re_addr_snap;
    reg [7:0] we_wdata_snap;

    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) begin
            we_credit     <= 1'b0;
            we_credit_age <= 4'd0;
            we_addr_snap  <= 7'd0;
            we_wdata_snap <= 8'd0;
        end else if (spi_we_toggle != we_tog_c_q) begin
            we_credit     <= 1'b1;
            we_credit_age <= 4'd0;
            we_addr_snap  <= spi_wr_addr_lat;
            we_wdata_snap <= spi_wdata_lat;
        end else if (we_edge) begin
            we_credit     <= 1'b0;
        end else if (we_credit && we_credit_age != 4'hF) begin
            we_credit_age <= we_credit_age + 4'd1;
        end

    always @(posedge clk_32m or negedge rst_n)
        if (!rst_n) begin
            re_credit     <= 1'b0;
            re_credit_age <= 4'd0;
            re_addr_snap  <= 7'd0;
        end else if (spi_re_toggle != re_tog_c_q) begin
            re_credit     <= 1'b1;
            re_credit_age <= 4'd0;
            re_addr_snap  <= spi_re_addr_lat;
        end else if (re_edge) begin
            re_credit     <= 1'b0;
        end else if (re_credit && re_credit_age != 4'hF) begin
            re_credit_age <= re_credit_age + 4'd1;
        end

    // No duplication: a new source event cannot arrive while a previous one
    // is still outstanding (proved as a consequence of the min-gap
    // assumption plus the bounded-delivery proof directly below, not assumed
    // directly — this is the "sufficiently separated to be distinguished"
    // claim row #13 asks for).
    always @(posedge clk_32m)
        if (rst_n)
            a_we_no_new_flip_while_pending: assert (!(we_credit && (spi_we_toggle != we_tog_c_q)));
    always @(posedge clk_32m)
        if (rst_n)
            a_re_no_new_flip_while_pending: assert (!(re_credit && (spi_re_toggle != re_tog_c_q)));

    // No loss: every outstanding credit clears (i.e. we_edge/re_edge fires)
    // within a small, fixed number of clk_32m cycles — well inside the >=25
    // cycle margin the min-gap assumption provides. 6 is a generous bound
    // over the pipeline's true ~3-cycle latency.
    always @(posedge clk_32m)
        if (rst_n)
            a_we_credit_bounded: assert (we_credit_age <= 4'd6);
    always @(posedge clk_32m)
        if (rst_n)
            a_re_credit_bounded: assert (re_credit_age <= 4'd6);

    // No spurious pulses: an edge/reg_we pulse never fires without an
    // outstanding credit.
    always @(posedge clk_32m)
        if (rst_n && we_edge)
            a_we_edge_has_credit: assert (we_credit);
    always @(posedge clk_32m)
        if (rst_n && re_edge)
            a_re_edge_has_credit: assert (re_credit);

    // Mailbox stability end-to-end: whenever the DUT's own output reg_we is
    // asserted, its bundled address/data equal exactly what was latched at
    // the source toggle event that this delivery corresponds to.
    always @(posedge clk_32m)
        if (rst_n && reg_we) begin
            a_mailbox_addr_correct:  assert (reg_wr_addr == {1'b0, we_addr_snap});
            a_mailbox_wdata_correct: assert (reg_wdata   == we_wdata_snap);
        end
    always @(posedge clk_32m)
        if (rst_n && reg_re)
            a_re_mailbox_addr_correct: assert (reg_re_addr == {1'b0, re_addr_snap});

    // -----------------------------------------------------------------------
    // E. Non-vacuity: reachability cover points (checked by the `cover` task
    // in spi_slave.sby, not the `prove` task).
    // -----------------------------------------------------------------------
    always @(posedge clk_32m) begin
        if (rst_n) begin
            c_write_delivered: cover (reg_we);
            c_read_delivered:  cover (reg_re);
            c_both_credits_concurrent: cover (we_credit && re_credit);
        end
    end
    always @(posedge SPI_SCK) begin
        if (!spi_frame_arst) begin
            c_addr_wrap: cover (cur_addr_q == 7'h7F && cur_addr == 7'h00);
            c_addr_hold_0x76_cov: cover (cur_addr_q == NO_INC_ADDR && cur_addr == NO_INC_ADDR &&
                                          spi_bit_cnt_q == 3'd7 && have_cmd_q);
            c_cs_deassert_after_write: cover (spi_we_toggle != we_tog_sck_q);
        end
    end

endmodule
