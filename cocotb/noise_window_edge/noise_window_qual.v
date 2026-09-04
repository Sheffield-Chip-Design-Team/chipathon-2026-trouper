// noise_window_qual.v -- Open Risk #66 / #68 isolation wrapper.
//
// The always block below is a VERBATIM copy of the noise-window qualification
// block in src/top/trouper_top.v (Stage 5). It is pulled out here so a cocotb
// bench can drive the same-cycle / near-cycle race on the SC pipeline outputs
// relative to a noise window's training_done -- alignments that cannot be
// phase-controlled through the full trouper_top datapath.
//
// !!! KEEP IN SYNC with src/top/trouper_top.v. If that block changes, this copy
// !!! and cocotb/tests/test_noise_window_edge.py must change with it.
//
// sc_hit_dbg is sc_detector's REGISTERED 1-cycle output and can become visible a
// variable number of edges after training_done (serial metric engine ~57 cycles
// deep). The wrapper MODELS the register: the test drives `hit_ev` (1-cycle
// "evaluation completed WITH a hit"), `eval_done_ev` / `eval_start_ev` (1-cycle
// "a metric evaluation completed / launched, hit or not") and `pipe_busy` (eval
// in flight); the wrapper produces sc_hit_dbg / sc_pipe_active /
// sc_eval_done_pulse / sc_eval_start_pulse with the real 1-cycle latency.
//
// Open Risk #66 P2:
//  * sc_pipe_active only covers activity CURRENTLY in flight; an SC evaluation
//    launches only at a symbol boundary, so a packet starting late in the noise
//    window sits un-evaluated with sc_pipe_active low until the next boundary.
//  * an evaluation already in flight at training_done was fed the PREVIOUS
//    symbol -- it must not satisfy the requirement.
//  So the verdict also needs an evaluation that STARTED after the drain began
//  (eval_start_ev -> noise_eval_armed) and then completed (-> noise_eval_seen).
//  The requirement is skipped entirely when the SC detector never ran this
//  window (pipe_busy / hit_ev never asserted -> noise_sc_was_active stays 0),
//  which is the PSRAM/SC-delay-disabled case -- otherwise NOISE_READY would
//  deadlock.

module noise_window_qual (
    input  wire clk,
    input  wire rst_n,
    input  wire noise_trig_accept,
    input  wire hit_ev,          // 1-cycle: an SC evaluation completed WITH a hit
    input  wire pipe_busy,       // TDM burst / serial metric engine in flight
    input  wire eval_done_ev,    // 1-cycle: an SC metric evaluation completed (hit or not)
    input  wire eval_start_ev,   // 1-cycle: an SC metric evaluation launched (symbol boundary)
    input  wire sc_lock_in,      // SC lock level
    input  wire training_done,
    input  wire noise_abort,     // training_acc cancelled the window (real packet pre-empt)
    output wire sigma2_valid,
    // observability
    output wire noise_window_active_o,
    output wire noise_window_sc_seen_o,
    output wire noise_window_draining_o
);

    // ---- model of the registered sc_detector outputs ----
    reg sc_hit_dbg_r;
    reg sc_lock_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sc_hit_dbg_r <= 1'b0;
            sc_lock_r    <= 1'b0;
        end else begin
            sc_hit_dbg_r <= hit_ev;          // registered 1-cycle pulse
            sc_lock_r    <= sc_lock_in;
        end
    end
    wire sc_hit_dbg     = sc_hit_dbg_r;
    wire sc_lock        = sc_lock_r;
    // sc_detector.v: sc_pipe_active = tdm_busy | eval_busy | metric_valid_pulse | sc_hit_dbg
    wire sc_pipe_active = pipe_busy | hit_ev | sc_hit_dbg_r;
    // sc_detector.v: sc_eval_done_pulse = metric_valid_pulse ; sc_eval_start_pulse = metric_start_pulse
    wire sc_eval_done_pulse  = eval_done_ev | hit_ev;
    wire sc_eval_start_pulse = eval_start_ev;

    // ======================================================================
    // VERBATIM copy of src/top/trouper_top.v noise-window qualification
    // ======================================================================
    reg        noise_window_active;
    reg        noise_window_sc_seen;
    reg        noise_window_draining;
    reg  [6:0] noise_drain_cnt;
    reg        noise_sc_was_active;
    reg        noise_eval_armed;
    reg        noise_eval_seen;
    reg        sigma2_valid_r;

    localparam [6:0] NOISE_DRAIN_MIN = 7'd72;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_window_active   <= 1'b0;
            noise_window_sc_seen  <= 1'b0;
            noise_window_draining <= 1'b0;
            noise_drain_cnt       <= 7'd0;
            noise_sc_was_active   <= 1'b0;
            noise_eval_armed      <= 1'b0;
            noise_eval_seen       <= 1'b0;
            sigma2_valid_r        <= 1'b0;
        end else begin
            sigma2_valid_r    <= 1'b0;

            if (noise_trig_accept) begin
                noise_window_active   <= 1'b1;
                noise_window_sc_seen  <= 1'b0;
                noise_window_draining <= 1'b0;
                noise_drain_cnt       <= 7'd0;
                noise_sc_was_active   <= 1'b0;
                noise_eval_armed      <= 1'b0;
                noise_eval_seen       <= 1'b0;
            end else if (noise_window_active && noise_abort) begin
                noise_window_active   <= 1'b0;
                noise_window_sc_seen  <= 1'b0;
                noise_window_draining <= 1'b0;
                noise_drain_cnt       <= 7'd0;
                noise_sc_was_active   <= 1'b0;
                noise_eval_armed      <= 1'b0;
                noise_eval_seen       <= 1'b0;
            end else if (noise_window_active) begin
                if (sc_hit_dbg || sc_lock)
                    noise_window_sc_seen <= 1'b1;
                if (sc_pipe_active)
                    noise_sc_was_active <= 1'b1;

                if (!noise_window_draining) begin
                    if (training_done) begin
                        noise_window_draining <= 1'b1;
                        noise_drain_cnt       <= NOISE_DRAIN_MIN;
                        noise_eval_armed      <= 1'b0;
                        noise_eval_seen       <= 1'b0;
                    end
                end else begin
                    if (noise_drain_cnt != 7'd0)
                        noise_drain_cnt <= noise_drain_cnt - 7'd1;
                    if (sc_eval_start_pulse)
                        noise_eval_armed <= 1'b1;
                    if (sc_eval_done_pulse && noise_eval_armed)
                        noise_eval_seen <= 1'b1;
                    if (noise_drain_cnt == 7'd0 && !sc_pipe_active &&
                            (!noise_sc_was_active || noise_eval_seen)) begin
                        sigma2_valid_r        <= ~(noise_window_sc_seen || sc_lock);
                        noise_window_active   <= 1'b0;
                        noise_window_sc_seen  <= 1'b0;
                        noise_window_draining <= 1'b0;
                        noise_sc_was_active   <= 1'b0;
                        noise_eval_armed      <= 1'b0;
                        noise_eval_seen       <= 1'b0;
                    end
                end
            end
        end
    end

    assign sigma2_valid           = sigma2_valid_r;
    assign noise_window_active_o   = noise_window_active;
    assign noise_window_sc_seen_o  = noise_window_sc_seen;
    assign noise_window_draining_o = noise_window_draining;

endmodule
