// packet_ctrl_fsm.v
// Packet control FSM: orchestrates packet phase, weight application, and payload timing
// (the buf_freeze output was deleted 2026-07-26: bit-identical to packet_active and
//  consumed by nothing since the frontend_buf_ctrl -> PSRAM migration)
// GF180MCU, 3.3V, 32 MHz single clock domain

module packet_ctrl_fsm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] sample_count,
    input  wire        iq_tick,       // 1-clock pulse per captured sample (dcr_valid)
    input  wire [3:0]  sf,
    input  wire [1:0]  sample_shift,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire        training_done,
    input  wire        W_commit,
    input  wire [1:0]  mode_shadow,
    input  wire [3:0]  antenna_en_shadow,
    input  wire [7:0]  pkt_timeout_syms,
    input  wire [3:0]  tacc_window_syms,
    output reg         W_valid_set,
    output reg         W_missed_packet,
    // Sticky per-packet mirror of W_missed_packet for register readback
    // (PACKET_STATUS[7] / WGT_CTRL[3]): W_missed_packet is a 1-cycle pulse
    // consumed by the IRQ path and is firmware-invisible if wired to
    // reg_bank directly. Held through IDLE, cleared at the next packet start.
    output reg         W_missed_q,
    output reg  [2:0]  packet_phase,
    output reg         packet_active,
    // Physical fanout split (2026-07-19): bit-identical duplicate of
    // packet_active dedicated to u_psram's wide enable cone, so the repair
    // lottery on one net cannot starve the other's buffer tree.  Mirrored at
    // every packet_active assignment; (* keep *) stops opt_merge folding it.
    (* keep *) output reg packet_active_ps,
    output reg  [1:0]  active_mode,
    output reg  [3:0]  active_antenna_en
);

    // FSM states
    localparam ST_IDLE           = 3'd0;
    localparam ST_PREAMBLE_ACQ   = 3'd1;
    localparam ST_W_PENDING      = 3'd2;
    localparam ST_PAYLOAD_ACTIVE = 3'd3;
    // One dedicated cycle between sc_lock and ST_PREAMBLE_ACQ that loads
    // the acq/wpend/pkt down-counters from the already-registered
    // lat_timing_ref instead of combinationally from the live timing_ref
    // input -- see Open Risk #39 (dishonest single-cycle timing_ref -> adder
    // -> timeout-register arc).
    localparam ST_ACQ_SETUP      = 3'd4;

    reg [2:0] state;

    // Latched packet parameters.
    // B6 (area roadmap §7/§8): the three 32-bit absolute deadlines
    // (acq_timeout_q/wpend_timeout_q/pkt_end_q) + their continuous 32-bit
    // `sample_count >` comparators are replaced by narrow DOWN-COUNTERS
    // decremented once per captured sample (iq_tick) and consumed as
    // zero-checks.  Loads still happen exactly once, in ST_ACQ_SETUP, from
    // registered/quasi-static operands (Open Risk #39 structure preserved);
    // the only live operand is sample_count itself (elapsed-since-timing_ref
    // correction), whose arc stays honestly single-cycle -- the same depth
    // class as the 32-bit comparators this change deletes.  Down-counters
    // are also wrap-immune (the old `>` compares were not: 32-bit
    // iq_samp_cnt wraps after ~2.4 h at 500 kS/s).
    // Span bounds: acq = tacc_span + 2M <= 15*16384 + 2*16384 = 278,528 (19b)
    //              wpend = tacc_span + 5M            <= 327,680 (19b)
    //              pkt   = 255 * 16384             <= 4,177,920 (22b)
    reg [31:0] lat_timing_ref;
    reg [19:0] acq_cnt;
    reg [19:0] wpend_cnt;
    reg [22:0] pkt_cnt;
    reg [14:0] M_val;   // 2^(SF+shift) <= 16384 -> 15 bits (was 32)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) M_val <= 15'd256; // SF7 + shift=1 (250 kHz default)
        else        M_val <= 15'd1 << ({1'b0, sf} + {3'b0, sample_shift});
    end

    wire [3:0] tacc_window_eff = (tacc_window_syms == 4'd0) ? 4'd1 : tacc_window_syms;
    wire [18:0] tacc_window_span = {15'd0, tacc_window_eff} << (sf + sample_shift);

    // Spans in samples relative to lat_timing_ref (quasi-static operands only)
    wire [18:0] acq_span   = tacc_window_span + {3'd0, M_val, 1'b0};                    // + 2M
    wire [18:0] wpend_span = tacc_window_span + {2'd0, M_val, 2'b0} + {4'd0, M_val};    // + 5M
    wire [21:0] pkt_span   = {14'd0, pkt_timeout_syms} << (sf + sample_shift);

    // Down-counter loads (used in ST_ACQ_SETUP only): remaining ticks until
    // the old absolute fire instant sample_count == lat_timing_ref + span + 1.
    //   load = span + 1 - (sample_count - lat_timing_ref) - iq_tick,  floor 0
    // The iq_tick term accounts for a tick landing on the load edge itself
    // (the counter decrement is not active during ST_ACQ_SETUP).  A clamped
    // load of 0 fires on the first evaluation in the consuming state --
    // identical to the old already-expired `>` compare.
    // Elapsed is computed MODULO 2^20 from the low counter bits: the true
    // value is structurally bounded by (sc_hits_req+1)*M + pipeline lag
    // <= ~2^17 (timing_ref is at most ~5 symbols in the past at lock), so a
    // 20-bit subtract is exact in every reachable state and avoids putting a
    // 32-bit carry chain on the live iq_samp_cnt -> counter-load arc (that
    // full-width subtract WAS the post-PnR SS worst path, -20.5 ns, run
    // 2026-07-18_21-45-53).
    wire [19:0] elapsed_c   = sample_count[19:0] - lat_timing_ref[19:0];
    wire [24:0] acq_rem_w   = {6'd0, acq_span}   + 25'd1 - {5'd0, elapsed_c} - {24'd0, iq_tick};
    wire [24:0] wpend_rem_w = {6'd0, wpend_span} + 25'd1 - {5'd0, elapsed_c} - {24'd0, iq_tick};
    wire [24:0] pkt_rem_w   = {3'd0, pkt_span}   + 25'd1 - {5'd0, elapsed_c} - {24'd0, iq_tick};
    wire [19:0] acq_load    = acq_rem_w[24]   ? 20'd0 : acq_rem_w[19:0];
    wire [19:0] wpend_load  = wpend_rem_w[24] ? 20'd0 : wpend_rem_w[19:0];
    wire [22:0] pkt_load    = pkt_rem_w[24]   ? 23'd0 : pkt_rem_w[22:0];

    // W commit pending (can arrive in any state, deferred to IDLE or applied in PAYLOAD)
    reg W_commit_pending;
    reg W_valid;           // W has been applied for current packet

    // Noise-estimation quiet gating removed.
    reg sc_lock_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            sc_lock_prev     <= 1'b0;
            lat_timing_ref   <= 32'd0;
            acq_cnt          <= 20'd0;
            wpend_cnt        <= 20'd0;
            pkt_cnt          <= 23'd0;
            W_commit_pending <= 1'b0;
            W_valid          <= 1'b0;
            W_valid_set      <= 1'b0;
            W_missed_packet  <= 1'b0;
            W_missed_q       <= 1'b0;
            packet_phase     <= 3'd0;
            packet_active    <= 1'b0;
            packet_active_ps <= 1'b0;
            active_mode      <= 2'd0;
            active_antenna_en <= 4'd1;
        end else begin
            sc_lock_prev    <= sc_lock;
            W_valid_set     <= 1'b0;
            W_missed_packet <= 1'b0;

            // Track W_commit from weight_gen (sticky pending)
            if (W_commit)
                W_commit_pending <= 1'b1;

            // B6 down-counter tick: one decrement per captured sample while
            // the deadlines are armed.  All three run concurrently from
            // ST_ACQ_SETUP onward (they encode ABSOLUTE deadlines from
            // lat_timing_ref, exactly like the old registers).  The case
            // below never writes these registers in the same states, so
            // there is no assignment race; the ST_ACQ_SETUP load (a state
            // where this block is inactive) has sole write access there.
            if (state == ST_PREAMBLE_ACQ || state == ST_W_PENDING ||
                state == ST_PAYLOAD_ACTIVE) begin
                if (iq_tick) begin
                    if (acq_cnt   != 20'd0) acq_cnt   <= acq_cnt   - 20'd1;
                    if (wpend_cnt != 20'd0) wpend_cnt <= wpend_cnt - 20'd1;
                    if (pkt_cnt   != 23'd0) pkt_cnt   <= pkt_cnt   - 23'd1;
                end
            end

            case (state)
                ST_IDLE: begin
                    packet_active   <= 1'b0;
                    packet_active_ps <= 1'b0;
                    packet_phase    <= 3'd0;

                    // Apply pending W when idle
                    if (W_commit_pending) begin
                        W_valid          <= 1'b1;
                        W_valid_set      <= 1'b1;
                        W_commit_pending <= 1'b0;
                    end

                    // SC lock rising edge -> start packet acquisition.
                    // Only lat_timing_ref is latched here (a plain register
                    // copy of the live timing_ref input); the timeout
                    // down-counters are loaded one cycle later in
                    // ST_ACQ_SETUP from lat_timing_ref, not combinationally
                    // from timing_ref itself (Open Risk #39).
                    if (sc_lock && !sc_lock_prev) begin
                        W_missed_q        <= 1'b0;
                        lat_timing_ref    <= timing_ref;
                        active_mode       <= mode_shadow;
                        active_antenna_en <= antenna_en_shadow;
                        packet_active     <= 1'b1;
                        packet_active_ps  <= 1'b1;
                        packet_phase      <= 3'd1;
                        state <= ST_ACQ_SETUP;
                    end
                end

                ST_ACQ_SETUP: begin
                    // lat_timing_ref was latched last cycle and will not
                    // change again until the next sc_lock edge (many
                    // thousands of cycles away) -- so this arc genuinely
                    // tolerates a multicycle SDC exception, unlike the old
                    // same-edge compute from live timing_ref.
                    packet_phase    <= 3'd1;
                    acq_cnt         <= acq_load;
                    wpend_cnt       <= wpend_load;
                    pkt_cnt         <= pkt_load;
                    state           <= ST_PREAMBLE_ACQ;
                end

                ST_PREAMBLE_ACQ: begin
                    packet_phase    <= 3'd1;

                    if (training_done) begin
                        state        <= ST_W_PENDING;
                        packet_phase <= 3'd2;
                    end else if (acq_cnt == 20'd0) begin
                        // Timeout: proceed without weight update
                        W_missed_packet <= 1'b1;
                        W_missed_q      <= 1'b1;
                        state           <= ST_PAYLOAD_ACTIVE;
                        packet_phase    <= 3'd3;
                    end
                end

                ST_W_PENDING: begin
                    packet_phase <= 3'd2;

                    if (W_commit_pending) begin
                        W_valid          <= 1'b1;
                        W_valid_set      <= 1'b1;
                        W_commit_pending <= 1'b0;
                        state            <= ST_PAYLOAD_ACTIVE;
                        packet_phase     <= 3'd3;
                    end else if (wpend_cnt == 20'd0) begin
                        // Timeout: use whatever W_valid we have
                        if (!W_valid) begin
                            W_missed_packet <= 1'b1;
                            W_missed_q      <= 1'b1;
                        end
                        state        <= ST_PAYLOAD_ACTIVE;
                        packet_phase <= 3'd3;
                    end
                end

                ST_PAYLOAD_ACTIVE: begin
                    packet_phase    <= 3'd3;

                    // Apply any pending W immediately during payload
                    if (W_commit_pending) begin
                        W_valid          <= 1'b1;
                        W_valid_set      <= 1'b1;
                        W_commit_pending <= 1'b0;
                    end

                    // No mid-payload re-lock handling: deliberate, not an
                    // oversight. sc_lock is level-held by sc_detector until
                    // sc_clr (= packet_done_pulse, the falling edge of
                    // packet_active), so a second sc_lock rising edge cannot
                    // occur while this state is active -- every new packet
                    // acquisition necessarily passes through ST_IDLE. A
                    // former re-lock branch here (with a psram_abort output
                    // to bail psram_buf_ctrl out of a stale replay) was
                    // verified unreachable and removed 2026-07-12 (Open
                    // Risks #25). If sc_detector ever gains a mid-packet
                    // re-arm path (e.g. a cascade sc_lock_in without the
                    // !sc_lock gate), re-lock handling and a replay abort
                    // must be reintroduced here AND in psram_buf_ctrl.
                    if (pkt_cnt == 23'd0) begin
                        // Packet timeout -> IDLE
                        W_valid         <= 1'b0;
                        packet_active   <= 1'b0;
                        packet_active_ps <= 1'b0;
                        packet_phase    <= 3'd0;
                        state           <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    // Formal-only checker instantiation (see formal/packet_ctrl_fsm_formal.sv).
    // Dead code in every real build: read_verilog defines FORMAL only when
    // passed `-formal` (yosys's sby-driven proof flow); LibreLane synthesis
    // and cocotb (Icarus/Verilator) never pass that flag and get SYNTHESIS
    // instead. Deliberately NOT a `bind` — this yosys version silently drops
    // `bind` statements (confirmed 2026-07-05 on psram_buf_ctrl), which makes
    // bind-based proofs vacuous. Do not delete: without this instance `sby`
    // still reports PASS but checks zero assertions.
    packet_ctrl_fsm_formal u_pcfsm_formal (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_count     (sample_count),
        .iq_tick          (iq_tick),
        .sf               (sf),
        .sample_shift     (sample_shift),
        .sc_lock          (sc_lock),
        .timing_ref       (timing_ref),
        .training_done    (training_done),
        .W_commit         (W_commit),
        .W_valid_set      (W_valid_set),
        .W_missed_packet  (W_missed_packet),
        .W_missed_q       (W_missed_q),
        .packet_phase     (packet_phase),
        .packet_active    (packet_active),
        .packet_active_ps (packet_active_ps),
        .state            (state),
        .sc_lock_prev     (sc_lock_prev),
        .lat_timing_ref   (lat_timing_ref),
        .acq_cnt          (acq_cnt),
        .wpend_cnt        (wpend_cnt),
        .pkt_cnt          (pkt_cnt),
        .W_commit_pending (W_commit_pending),
        .W_valid          (W_valid)
    );
`endif

endmodule
