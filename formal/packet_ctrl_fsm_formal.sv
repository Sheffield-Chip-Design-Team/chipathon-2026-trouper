// packet_ctrl_fsm_formal.sv
// Formal checker for packet_ctrl_fsm.v — first formal coverage of this
// module (2026-07-19). Targets the properties that recent RTL surgery relied
// on but only simulation had checked:
//   * the B6 down-counter rewrite's 20-bit modular elapsed subtract is exact
//     in every reachable ST_ACQ_SETUP cycle (the comment's central claim);
//   * ST_ACQ_SETUP is entered only from the ST_IDLE sc_lock edge and lasts
//     exactly one cycle (the Open Risk #39 structure);
//   * packet_active_ps is a bit-identical mirror of packet_active (the
//     2026-07-19 fanout split);
//   * packet_active / packet_phase are pure functions of state;
//   * W_missed_q stickiness and the exact timeout causes of the
//     W_missed_packet pulse;
//   * counters change only via the SETUP load or a single armed decrement.
//
// Same yosys-0.64 formal-subset conventions as psram_buf_ctrl_formal.sv:
// procedural asserts only (no SVA properties), no `bind` (silently dropped —
// instantiated directly inside packet_ctrl_fsm.v under `ifdef FORMAL),
// initial assume(!rst_n) reset modeling.
//
// State encoding (hardcoded — localparams not visible across the boundary):
//   ST_IDLE=0  ST_PREAMBLE_ACQ=1  ST_W_PENDING=2  ST_PAYLOAD_ACTIVE=3
//   ST_ACQ_SETUP=4
//
// Run: cd formal && (inside chipathon26 container) sby -f packet_ctrl_fsm.sby

`default_nettype none

module packet_ctrl_fsm_formal (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] sample_count,
    input  wire        iq_tick,
    input  wire [3:0]  sf,
    input  wire [1:0]  sample_shift,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire        training_done,
    input  wire        W_commit,

    input  wire        W_valid_set,
    input  wire        W_missed_packet,
    input  wire        W_missed_q,
    input  wire [2:0]  packet_phase,
    input  wire        packet_active,
    input  wire        packet_active_ps,

    // internals
    input  wire [2:0]  state,
    input  wire        sc_lock_prev,
    input  wire [31:0] lat_timing_ref,
    input  wire [19:0] acq_cnt,
    input  wire [19:0] wpend_cnt,
    input  wire [22:0] pkt_cnt,
    input  wire        W_commit_pending,
    input  wire        W_valid
);

    localparam ST_IDLE           = 3'd0;
    localparam ST_PREAMBLE_ACQ   = 3'd1;
    localparam ST_W_PENDING      = 3'd2;
    localparam ST_PAYLOAD_ACTIVE = 3'd3;
    localparam ST_ACQ_SETUP      = 3'd4;

    // -----------------------------------------------------------------------
    // Reset modeling — see psram_buf_ctrl_formal.sv for the rationale.
    // -----------------------------------------------------------------------
    initial assume (!rst_n);

    // -----------------------------------------------------------------------
    // Environment: sample_count is trouper_top's free-running iq_samp_cnt —
    // it advances by exactly 1 on each iq_tick and is otherwise frozen. The
    // relation is only enforced once reset has genuinely been seen high for
    // two consecutive cycles (the _q sample below is undefined across the
    // reset boundary).
    // -----------------------------------------------------------------------
    reg [31:0] sample_count_q;
    reg        iq_tick_q;
    reg        rstn_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count_q <= 32'd0;
            iq_tick_q      <= 1'b0;
            rstn_q         <= 1'b0;
        end else begin
            sample_count_q <= sample_count;
            iq_tick_q      <= iq_tick;
            rstn_q         <= 1'b1;
        end
    end

    always @(posedge clk)
        if (rst_n && rstn_q)
            m_sample_count_increment:
                assume (sample_count == sample_count_q + {31'd0, iq_tick_q});

    // sf/sample_shift spec ranges (same rationale as the psram harness).
    always @(posedge clk)
        if (rst_n) begin
            m_sf_valid_range: assume (sf >= 4'd7 && sf <= 4'd12);
            m_sample_shift_valid_range: assume (sample_shift == 2'd1 || sample_shift == 2'd2);
        end

    // -----------------------------------------------------------------------
    // Environment: SC-detection latency bound at the lock edge. Same
    // cross-module fact the psram harness assumes (group H there):
    // sc_detector.v bounds timing_ref's lag behind the live sample counter to
    // sc_off <= 4*16384 = 65536 samples; 2^17 doubles it as pipeline margin.
    // This is exactly the "structurally bounded by ~2^17" premise the B6
    // 20-bit modular subtract comment relies on — assumed here, and the
    // 20-bit exactness it implies is ASSERTED below (a_elapsed_fits_20bit).
    // -----------------------------------------------------------------------
    always @(posedge clk)
        if (rst_n && state == ST_IDLE && sc_lock && !sc_lock_prev)
            m_lock_delta_bounded: assume ((sample_count - timing_ref) <= 32'd131072);

    // -----------------------------------------------------------------------
    // Shared previous-value trackers
    // -----------------------------------------------------------------------
    reg [2:0]  state_q;
    reg        lock_edge_q;     // ST_IDLE sc_lock rising edge (packet start)
    reg        training_done_q;
    reg        W_commit_pending_q;
    reg        W_valid_q;
    reg        W_missed_q_q;
    reg        W_missed_packet_q;
    reg [19:0] acq_cnt_q, wpend_cnt_q;
    reg [22:0] pkt_cnt_q;
    reg [31:0] lat_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q            <= ST_IDLE;
            lock_edge_q        <= 1'b0;
            training_done_q    <= 1'b0;
            W_commit_pending_q <= 1'b0;
            W_valid_q          <= 1'b0;
            W_missed_q_q       <= 1'b0;
            W_missed_packet_q  <= 1'b0;
            acq_cnt_q          <= 20'd0;
            wpend_cnt_q        <= 20'd0;
            pkt_cnt_q          <= 23'd0;
            lat_q              <= 32'd0;
        end else begin
            state_q            <= state;
            lock_edge_q        <= (state == ST_IDLE && sc_lock && !sc_lock_prev);
            training_done_q    <= training_done;
            W_commit_pending_q <= W_commit_pending;
            W_valid_q          <= W_valid;
            W_missed_q_q       <= W_missed_q;
            W_missed_packet_q  <= W_missed_packet;
            acq_cnt_q          <= acq_cnt;
            wpend_cnt_q        <= wpend_cnt;
            pkt_cnt_q          <= pkt_cnt;
            lat_q              <= lat_timing_ref;
        end
    end

    // -----------------------------------------------------------------------
    // A. State machine shape
    // -----------------------------------------------------------------------
    // Only the five defined encodings are ever reachable (3-bit reg, 5 used).
    always @(posedge clk)
        if (rst_n)
            a_state_valid: assert (state <= ST_ACQ_SETUP);

    // Only the documented edges exist. ST_ACQ_SETUP lasts exactly one cycle
    // (its arc to ST_PREAMBLE_ACQ is unconditional) — that single-cycle
    // residency is what the Open Risk #39 SDC story leans on.
    always @(posedge clk)
        if (rst_n) begin
            case (state_q)
                ST_IDLE:           a_legal_from_idle:    assert (state == ST_IDLE || state == ST_ACQ_SETUP);
                ST_ACQ_SETUP:      a_legal_from_setup:   assert (state == ST_PREAMBLE_ACQ);
                ST_PREAMBLE_ACQ:   a_legal_from_acq:     assert (state == ST_PREAMBLE_ACQ || state == ST_W_PENDING || state == ST_PAYLOAD_ACTIVE);
                ST_W_PENDING:      a_legal_from_wpend:   assert (state == ST_W_PENDING || state == ST_PAYLOAD_ACTIVE);
                ST_PAYLOAD_ACTIVE: a_legal_from_payload: assert (state == ST_PAYLOAD_ACTIVE || state == ST_IDLE);
                default:           a_legal_from_default: assert (state == ST_IDLE);
            endcase
        end

    // ST_ACQ_SETUP is entered ONLY from the ST_IDLE lock edge — so
    // lat_timing_ref was latched from timing_ref exactly one cycle before
    // any counter load consumes it (#39 structure).
    always @(posedge clk)
        if (rst_n && state == ST_ACQ_SETUP)
            a_setup_entry_cause: assert (state_q == ST_IDLE && lock_edge_q);

    // lat_timing_ref frame: written only on the lock edge.
    always @(posedge clk)
        if (rst_n && lat_timing_ref != lat_q)
            a_lat_frame: assert (lock_edge_q);

    // -----------------------------------------------------------------------
    // B. Output/state lockstep
    // -----------------------------------------------------------------------
    // The 2026-07-19 fanout split: packet_active_ps must remain bit-identical
    // to packet_active forever (mirrored at every assignment site).
    always @(posedge clk)
        if (rst_n)
            a_ps_mirror: assert (packet_active_ps == packet_active);

    // packet_active is exactly "not idle".
    always @(posedge clk)
        if (rst_n)
            a_active_iff_not_idle: assert (packet_active == (state != ST_IDLE));

    // packet_phase is a pure function of state (readback contract for
    // PACKET_STATUS): IDLE→0, SETUP/ACQ→1, W_PENDING→2, PAYLOAD→3.
    always @(posedge clk)
        if (rst_n) begin
            case (state)
                ST_IDLE:           a_phase_idle:    assert (packet_phase == 3'd0);
                ST_ACQ_SETUP:      a_phase_setup:   assert (packet_phase == 3'd1);
                ST_PREAMBLE_ACQ:   a_phase_acq:     assert (packet_phase == 3'd1);
                ST_W_PENDING:      a_phase_wpend:   assert (packet_phase == 3'd2);
                ST_PAYLOAD_ACTIVE: a_phase_payload: assert (packet_phase == 3'd3);
                default:           a_phase_default: assert (1'b0); // unreachable via a_state_valid
            endcase
        end

    // -----------------------------------------------------------------------
    // C. B6 20-bit modular elapsed subtract is exact (the load-arc claim).
    // At ST_ACQ_SETUP, elapsed = sample_count - lat_timing_ref. From
    // a_setup_entry_cause the previous cycle was the lock edge, where
    // m_lock_delta_bounded pinned (sample_count - timing_ref) <= 2^17 and the
    // RTL latched lat_timing_ref <= timing_ref; sample_count has advanced by
    // at most 1 since (m_sample_count_increment). Hence the true 32-bit
    // elapsed is <= 2^17 + 1 and its top 12 bits are zero — the RTL's
    // elapsed_c = sample_count[19:0] - lat_timing_ref[19:0] is exact.
    // -----------------------------------------------------------------------
    always @(posedge clk)
        if (rst_n && state == ST_ACQ_SETUP)
            a_elapsed_fits_20bit: assert ((sample_count - lat_timing_ref) <= 32'd131073);

    // -----------------------------------------------------------------------
    // D. Down-counter frame: each counter changes only via the ST_ACQ_SETUP
    // load, or a single decrement (never past 0) on an iq_tick in one of the
    // three armed states.
    // -----------------------------------------------------------------------
    wire armed_q = (state_q == ST_PREAMBLE_ACQ || state_q == ST_W_PENDING ||
                    state_q == ST_PAYLOAD_ACTIVE);

    always @(posedge clk)
        if (rst_n && acq_cnt != acq_cnt_q)
            a_acq_cnt_frame: assert (state_q == ST_ACQ_SETUP ||
                (armed_q && iq_tick_q && acq_cnt_q != 20'd0 && acq_cnt == acq_cnt_q - 20'd1));

    always @(posedge clk)
        if (rst_n && wpend_cnt != wpend_cnt_q)
            a_wpend_cnt_frame: assert (state_q == ST_ACQ_SETUP ||
                (armed_q && iq_tick_q && wpend_cnt_q != 20'd0 && wpend_cnt == wpend_cnt_q - 20'd1));

    always @(posedge clk)
        if (rst_n && pkt_cnt != pkt_cnt_q)
            a_pkt_cnt_frame: assert (state_q == ST_ACQ_SETUP ||
                (armed_q && iq_tick_q && pkt_cnt_q != 23'd0 && pkt_cnt == pkt_cnt_q - 23'd1));

    // -----------------------------------------------------------------------
    // E. Weight protocol
    // -----------------------------------------------------------------------
    // W_valid_set pulses only as the consumption of a pending commit, and
    // only in the states that apply one.
    always @(posedge clk)
        if (rst_n && W_valid_set)
            a_wvalid_set_cause: assert (W_commit_pending_q &&
                (state_q == ST_IDLE || state_q == ST_W_PENDING || state_q == ST_PAYLOAD_ACTIVE));

    // W_missed_packet is a one-shot pulse with exactly two causes: the
    // acquisition timeout (training never finished) and the W-pending
    // timeout with no weight ever applied. The W_PENDING cause must include
    // !W_commit_pending_q — a commit arriving on the timeout cycle wins.
    always @(posedge clk)
        if (rst_n && W_missed_packet) begin
            a_wmissed_oneshot: assert (!W_missed_packet_q);
            a_wmissed_cause: assert (
                (state_q == ST_PREAMBLE_ACQ && acq_cnt_q == 20'd0 && !training_done_q) ||
                (state_q == ST_W_PENDING && wpend_cnt_q == 20'd0 &&
                 !W_commit_pending_q && !W_valid_q));
        end

    // W_missed_q (the firmware-visible sticky mirror) clears only at the
    // next packet start.
    always @(posedge clk)
        if (rst_n && W_missed_q_q && !lock_edge_q)
            a_wmissed_q_sticky: assert (W_missed_q);

endmodule
