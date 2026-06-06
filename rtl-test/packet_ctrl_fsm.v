// packet_ctrl_fsm.v
// Packet control FSM: orchestrates buffer freeze, weight application, and payload timing
// GF180MCU, 3.3V, 32 MHz single clock domain

module packet_ctrl_fsm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire [31:0] sample_count,
    input  wire [3:0]  sf,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire        training_done,
    input  wire        W_commit,
    input  wire [1:0]  mode_shadow,
    input  wire [3:0]  antenna_en_shadow,
    input  wire        psram_en,
    input  wire        psram_replay_active,
    input  wire [7:0]  pkt_timeout_syms,
    input  wire [15:0] noise_thresh,
    input  wire [15:0] energy0, energy1, energy2, energy3,
    output reg         safe_switch,
    output reg         W_valid_set,
    output reg         W_missed_packet,
    output reg         combiner_source,
    output reg         psram_packet_arm,
    output reg         psram_replay_start,
    output reg         psram_abort,
    output reg  [23:0] payload_rd_base,
    output reg         buf_freeze,
    output reg  [2:0]  packet_phase,
    output reg         packet_active,
    output reg  [1:0]  active_mode,
    output reg  [3:0]  active_antenna_en,
    output reg         noise_sample_en
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
        if (!rst_n) begin
            M_val <= 32'd128;
        end else begin
            case (sf)
                4'd6:  M_val <= 32'd64;
                4'd7:  M_val <= 32'd128;
                4'd8:  M_val <= 32'd256;
                4'd9:  M_val <= 32'd512;
                4'd10: M_val <= 32'd1024;
                4'd11: M_val <= 32'd2048;
                4'd12: M_val <= 32'd4096;
                default: M_val <= 32'd128;
            endcase
        end
    end

    // Timeout thresholds are registered at packet start to keep the FSM compare path short.
    wire [31:0] acq_timeout_next  = timing_ref + (M_val << 3) + (M_val << 1);
    wire [31:0] wpend_timeout_next = timing_ref + (M_val << 3) + (M_val << 2) + M_val;
    reg  [31:0] pkt_span_next;

    always @(*) begin
        case (sf)
            4'd6:  pkt_span_next = {18'd0, pkt_timeout_syms, 6'd0};
            4'd7:  pkt_span_next = {17'd0, pkt_timeout_syms, 7'd0};
            4'd8:  pkt_span_next = {16'd0, pkt_timeout_syms, 8'd0};
            4'd9:  pkt_span_next = {15'd0, pkt_timeout_syms, 9'd0};
            4'd10: pkt_span_next = {14'd0, pkt_timeout_syms, 10'd0};
            4'd11: pkt_span_next = {13'd0, pkt_timeout_syms, 11'd0};
            4'd12: pkt_span_next = {12'd0, pkt_timeout_syms, 12'd0};
            default: pkt_span_next = {17'd0, pkt_timeout_syms, 7'd0};
        endcase
    end

    // W commit pending (can arrive in any state, deferred to IDLE or applied in PAYLOAD)
    reg W_commit_pending;
    reg W_valid;           // W has been applied for current packet

    // Noise gate: all energies below noise_thresh
    wire all_quiet = (energy0 < noise_thresh) && (energy1 < noise_thresh)
                   && (energy2 < noise_thresh) && (energy3 < noise_thresh);

    // Symbol-rate strobe for noise sampling (one per M samples)
    reg [12:0] sym_sample_cnt;
    reg        sym_strobe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sym_sample_cnt <= 13'd0;
            sym_strobe     <= 1'b0;
        end else if (iq_valid) begin
            if (sym_sample_cnt == M_val[12:0] - 13'd1) begin
                sym_sample_cnt <= 13'd0;
                sym_strobe     <= 1'b1;
            end else begin
                sym_sample_cnt <= sym_sample_cnt + 13'd1;
                sym_strobe     <= 1'b0;
            end
        end else begin
            sym_strobe <= 1'b0;
        end
    end

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
            safe_switch      <= 1'b1;
            W_valid_set      <= 1'b0;
            W_missed_packet  <= 1'b0;
            combiner_source  <= 1'b0;
            psram_packet_arm <= 1'b0;
            psram_replay_start <= 1'b0;
            psram_abort      <= 1'b0;
            payload_rd_base  <= 24'd0;
            buf_freeze       <= 1'b0;
            packet_phase     <= 3'd0;
            packet_active    <= 1'b0;
            active_mode      <= 2'd0;
            active_antenna_en <= 4'd1;
            noise_sample_en  <= 1'b0;
        end else begin
            sc_lock_prev    <= sc_lock;
            W_valid_set     <= 1'b0;
            W_missed_packet <= 1'b0;
            noise_sample_en <= 1'b0;
            psram_abort     <= 1'b0;
            psram_replay_start <= 1'b0;

            // Track W_commit from weight_gen (sticky pending)
            if (W_commit)
                W_commit_pending <= 1'b1;

            case (state)
                ST_IDLE: begin
                    safe_switch     <= 1'b1;
                    combiner_source <= 1'b0;
                    buf_freeze      <= 1'b0;
                    packet_active   <= 1'b0;
                    packet_phase    <= 3'd0;

                    // Apply pending W when idle
                    if (W_commit_pending) begin
                        W_valid          <= 1'b1;
                        W_valid_set      <= 1'b1;
                        W_commit_pending <= 1'b0;
                    end

                    // Noise sampling when channel is quiet
                    if (sym_strobe && all_quiet && !sc_lock)
                        noise_sample_en <= 1'b1;

                    // SC lock rising edge -> start packet acquisition
                    if (sc_lock && !sc_lock_prev) begin
                        lat_timing_ref    <= timing_ref;
                        acq_timeout_q     <= acq_timeout_next;
                        wpend_timeout_q   <= wpend_timeout_next;
                        pkt_end_q         <= timing_ref + pkt_span_next;
                        active_mode       <= mode_shadow;
                        active_antenna_en <= antenna_en_shadow;
                        buf_freeze        <= 1'b1;
                        safe_switch       <= 1'b0;
                        packet_active     <= 1'b1;
                        packet_phase      <= 3'd1;
                        if (psram_en) psram_packet_arm <= 1'b1;
                        state <= ST_PREAMBLE_ACQ;
                    end
                end

                ST_PREAMBLE_ACQ: begin
                    combiner_source <= 1'b0; // bypass during acquisition
                    packet_phase    <= 3'd1;
                    psram_packet_arm <= 1'b0;

                    if (training_done) begin
                        state        <= ST_W_PENDING;
                        packet_phase <= 3'd2;
                    end else if (sample_count > acq_timeout_q) begin
                        // Timeout: proceed without weight update
                        W_missed_packet <= 1'b1;
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
                        combiner_source  <= 1'b1;
                        state            <= ST_PAYLOAD_ACTIVE;
                        packet_phase     <= 3'd3;
                    end else if (sample_count > wpend_timeout_q) begin
                        // Timeout: use whatever W_valid we have
                        if (W_valid) combiner_source <= 1'b1;
                        state        <= ST_PAYLOAD_ACTIVE;
                        packet_phase <= 3'd3;
                    end
                end

                ST_PAYLOAD_ACTIVE: begin
                    packet_phase    <= 3'd3;
                    combiner_source <= W_valid ? 1'b1 : 1'b0;

                    // Apply any pending W immediately during payload
                    if (W_commit_pending) begin
                        W_valid          <= 1'b1;
                        W_valid_set      <= 1'b1;
                        W_commit_pending <= 1'b0;
                        combiner_source  <= 1'b1;
                    end

                    // New sc_lock -> start next packet
                    if (sc_lock && !sc_lock_prev) begin
                        psram_abort <= psram_replay_active;
                        lat_timing_ref    <= timing_ref;
                        acq_timeout_q     <= acq_timeout_next;
                        wpend_timeout_q   <= wpend_timeout_next;
                        pkt_end_q         <= timing_ref + pkt_span_next;
                        active_mode       <= mode_shadow;
                        active_antenna_en <= antenna_en_shadow;
                        buf_freeze        <= 1'b1;
                        W_valid           <= 1'b0;
                        combiner_source   <= 1'b0;
                        packet_phase      <= 3'd1;
                        if (psram_en) psram_packet_arm <= 1'b1;
                        state <= ST_PREAMBLE_ACQ;
                    end else if (sample_count > pkt_end_q) begin
                        // Packet timeout -> IDLE
                        buf_freeze      <= 1'b0;
                        safe_switch     <= 1'b1;
                        combiner_source <= 1'b0;
                        W_valid         <= 1'b0;
                        packet_active   <= 1'b0;
                        packet_phase    <= 3'd0;
                        psram_abort     <= psram_replay_active;
                        state           <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
