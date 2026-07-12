// packet_ctrl_fsm.v
// Packet control FSM: orchestrates buffer freeze, weight application, and payload timing
// GF180MCU, 3.3V, 32 MHz single clock domain

module packet_ctrl_fsm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] sample_count,
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
    output reg         buf_freeze,
    output reg  [2:0]  packet_phase,
    output reg         packet_active,
    output reg  [1:0]  active_mode,
    output reg  [3:0]  active_antenna_en
);

    // FSM states
    localparam ST_IDLE           = 3'd0;
    localparam ST_PREAMBLE_ACQ   = 3'd1;
    localparam ST_W_PENDING      = 3'd2;
    localparam ST_PAYLOAD_ACTIVE = 3'd3;

    reg [2:0] state;

    // Latched packet parameters
    reg [31:0] lat_timing_ref;
    reg [31:0] acq_timeout_q;
    reg [31:0] wpend_timeout_q;
    reg [31:0] pkt_end_q;
    reg [31:0] M_val;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) M_val <= 32'd256; // SF7 + shift=1 (250 kHz default)
        else        M_val <= 32'd1 << ({1'b0, sf} + {3'b0, sample_shift});
    end

    wire [3:0] tacc_window_eff = (tacc_window_syms == 4'd0) ? 4'd1 : tacc_window_syms;
    wire [31:0] tacc_window_span = {28'd0, tacc_window_eff} << (sf + sample_shift);

    // Timeout thresholds are registered at packet start to keep the FSM compare path short.
    wire [31:0] acq_timeout_next  = timing_ref + tacc_window_span + (M_val << 1);
    wire [31:0] wpend_timeout_next = timing_ref + tacc_window_span + (M_val << 2) + M_val;
    reg  [31:0] pkt_span_next;

    always @(*) begin
        pkt_span_next = {24'd0, pkt_timeout_syms} << (sf + sample_shift);
    end

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
            acq_timeout_q    <= 32'd0;
            wpend_timeout_q  <= 32'd0;
            pkt_end_q        <= 32'd0;
            W_commit_pending <= 1'b0;
            W_valid          <= 1'b0;
            W_valid_set      <= 1'b0;
            W_missed_packet  <= 1'b0;
            W_missed_q       <= 1'b0;
            buf_freeze       <= 1'b0;
            packet_phase     <= 3'd0;
            packet_active    <= 1'b0;
            active_mode      <= 2'd0;
            active_antenna_en <= 4'd1;
        end else begin
            sc_lock_prev    <= sc_lock;
            W_valid_set     <= 1'b0;
            W_missed_packet <= 1'b0;

            // Track W_commit from weight_gen (sticky pending)
            if (W_commit)
                W_commit_pending <= 1'b1;

            case (state)
                ST_IDLE: begin
                    buf_freeze      <= 1'b0;
                    packet_active   <= 1'b0;
                    packet_phase    <= 3'd0;

                    // Apply pending W when idle
                    if (W_commit_pending) begin
                        W_valid          <= 1'b1;
                        W_valid_set      <= 1'b1;
                        W_commit_pending <= 1'b0;
                    end

                    // SC lock rising edge -> start packet acquisition
                    if (sc_lock && !sc_lock_prev) begin
                        W_missed_q        <= 1'b0;
                        lat_timing_ref    <= timing_ref;
                        acq_timeout_q     <= acq_timeout_next;
                        wpend_timeout_q   <= wpend_timeout_next;
                        pkt_end_q         <= timing_ref + pkt_span_next;
                        active_mode       <= mode_shadow;
                        active_antenna_en <= antenna_en_shadow;
                        buf_freeze        <= 1'b1;
                        packet_active     <= 1'b1;
                        packet_phase      <= 3'd1;
                        state <= ST_PREAMBLE_ACQ;
                    end
                end

                ST_PREAMBLE_ACQ: begin
                    packet_phase    <= 3'd1;

                    if (training_done) begin
                        state        <= ST_W_PENDING;
                        packet_phase <= 3'd2;
                    end else if (sample_count > acq_timeout_q) begin
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
                    end else if (sample_count > wpend_timeout_q) begin
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
                    if (sample_count > pkt_end_q) begin
                        // Packet timeout -> IDLE
                        buf_freeze      <= 1'b0;
                        W_valid         <= 1'b0;
                        packet_active   <= 1'b0;
                        packet_phase    <= 3'd0;
                        state           <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
