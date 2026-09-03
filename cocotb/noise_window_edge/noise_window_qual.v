// noise_window_qual.v -- Open Risk #66 isolation wrapper.
//
// This is a VERBATIM copy of the noise-window qualification always block in
// src/top/trouper_top.v (Stage 5, ~line 693-724, "noise-window qualification").
// It is pulled out here only so a cocotb bench can drive the exact
// same-cycle race on {sc_hit_dbg, sc_lock, training_done} that is impossible to
// phase-align through the full trouper_top datapath.
//
// !!! KEEP IN SYNC with src/top/trouper_top.v. If that block changes, this copy
// !!! and cocotb/tests/test_noise_window_edge.py must change with it.
//
// The finding: a contaminating sc_hit_dbg that lands on the SAME edge as
// training_done (with sc_lock low) sets noise_window_sc_seen and qualifies
// sigma2_valid_r in one sequential block; the non-blocking validity expression
// reads the OLD noise_window_sc_seen (0) and asserts NOISE_READY for a
// contaminated window.

module noise_window_qual (
    input  wire clk,
    input  wire rst_n,
    input  wire noise_trig_accept,
    input  wire sc_hit_dbg,
    input  wire sc_lock,
    input  wire training_done,
    output wire sigma2_valid,
    // observability
    output wire noise_window_active_o,
    output wire noise_window_sc_seen_o
);

    reg noise_window_active;
    reg noise_window_sc_seen;
    reg sigma2_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_window_active  <= 1'b0;
            noise_window_sc_seen <= 1'b0;
            sigma2_valid_r       <= 1'b0;
        end else begin
            sigma2_valid_r <= 1'b0;

            if (noise_trig_accept) begin
                noise_window_active  <= 1'b1;
                noise_window_sc_seen <= 1'b0;
            end else if (noise_window_active && (sc_hit_dbg || sc_lock)) begin
                noise_window_sc_seen <= 1'b1;
            end

            if (noise_window_active && training_done) begin
                // Open Risk #66 FIX (mirrors src/top/trouper_top.v): include the
                // current-cycle SC activity so a hit landing on the completion
                // edge is not missed by the stale-read of noise_window_sc_seen.
                sigma2_valid_r       <= ~(noise_window_sc_seen || sc_hit_dbg || sc_lock);
                noise_window_active  <= 1'b0;
                noise_window_sc_seen <= 1'b0;
            end
        end
    end

    assign sigma2_valid          = sigma2_valid_r;
    assign noise_window_active_o  = noise_window_active;
    assign noise_window_sc_seen_o = noise_window_sc_seen;

endmodule
