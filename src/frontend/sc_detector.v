// sc_detector.v
// Schmidl-Cox preamble detector — NR=1 (antenna 0 only)
// Post-lock combining uses all 4 antennas via training_acc independently.
// GF180MCU, 3.3V, 32 MHz single clock domain
//
// Area-reduction changes vs original:
//   Single-channel (NR=1): ch1 inputs/accumulators/eval steps removed.
//     TDM steps: 16 → 8 (ch0 correlation + ch0 energy only).
//     Eval steps: 7 → 4 (ci0², cq0², E0cur×E0del, threshold).
//     training_acc does its own independent 4-channel preamble accumulation,
//     so sc_detector ch1 outputs were not load-bearing for MIMO combining.
//   Accumulator width: 24 → 32 bit (Open Risk #61, 2026-09).  The earlier
//     24-bit width assumed the deleted 128-sample correlator; a full symbol is
//     now Sum(cur_i0^2+cur_q0^2) over M ≤ 16384 samples, abs max
//     16384·(127^2+127^2) ≈ 2^29, and at SF12 a nominal-AGC preamble overran
//     24 bits (metric computed on wrapped / sign-flipped data → lock failure).
//   Snapshot: eval_* ← acc_* >>> (sf + sample_shift + 2), ARITHMETIC (sign-
//     preserving), saturated to signed 13-bit.  The old fixed [22:10] slice
//     dropped the sign bit and did not scale with M.  The M-dependent shift
//     keeps the 13-bit eval_* operand at ~constant magnitude for every SF
//     (acc_E0cur ~ M·A^2·2 → >>(sf+ss+2) ~ A^2/2, M-independent).  K=2 keeps
//     SF7/BW250 at the historical >>10.
//   Eval multiplier: 13 bit, bit-serial (serial_mul13): only 4 products/symbol
//     inside a ≥4,096-clock budget, so a wide combinational multiply was pure
//     area waste.  The serial product is the exact integer a*b.
//   sc_thr firmware value: a SINGLE value for every SF/BW (unchanged from the
//     pre-#61 SF7/BW250 default).  The threshold comparison is a k^2 / k^2
//     ratio (see eval_hit: both eval_mag_acc[27:1] and thr·eval_e_acc[25:13]
//     scale by the same snapshot factor squared), so it is invariant under the
//     M-dependent shift.
//   Per-sample multipliers: 16 simultaneous combinational 8×8 wires → 1 shared
//     8×8 multiplier, 8-step TDM FSM.
//   eval_mag_acc/eval_e_acc: 48 → 28 bit. Max |C|² = 2×4095² < 2^25; 28 bits
//     gives 3 bits headroom. sym_E_ref eliminated (was unused). sc_stat now
//     reads sym_mag_sc[27:12] (same top-16-bits-of-useful-range semantics).
//   timing_ref offset: replaced 32×32 hardware multiply with shift+concat.
//     (sc_hits_req+1)*M where M = 2^SF — pure wiring, no multiplier.

/* verilator lint_off DECLFILENAME */
// Bit-serial signed 13×13 → 26-bit multiplier (shift-add, LSB-first).
// Replaces the wide combinational signed_mul24_pipe: the eval engine performs
// only 4 products per symbol inside a budget of ≥4,096 clocks, so a ~14-cycle
// serial multiply is far cheaper in area (no 13×13 combinational array, ~−20K)
// and removes a wide combinational cone from the 32 MHz IQ_CLK domain (the
// critical path becomes a single 26-bit add, not a 13×13 multiply → SS-friendly).
// The product is the EXACT two's-complement integer a*b, so every downstream
// accumulation is bit-identical to the pipelined multiplier it replaces.
module serial_mul13 (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               start,   // 1-cycle pulse: latch a,b and begin
    input  wire signed [12:0] a,
    input  wire signed [12:0] b,
    output reg                done,    // 1-cycle pulse when p is final
    output reg  signed [25:0] p
);
    reg               running;
    reg  [3:0]        cnt;      // bit index 0..12
    reg  signed [25:0] a_sh;    // a sign-extended, shifted left one place per bit
    reg  [12:0]       b_sh;     // remaining multiplier bits, LSB first

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0; cnt <= 4'd0;
            a_sh <= 26'sd0; b_sh <= 13'd0;
            p <= 26'sd0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                running <= 1'b1;
                cnt     <= 4'd0;
                p       <= 26'sd0;
                a_sh    <= {{13{a[12]}}, a};  // sign-extend 13 → 26
                b_sh    <= b;
            end else if (running) begin
                if (b_sh[0]) begin
                    if (cnt == 4'd12) p <= p - a_sh;  // MSB has negative weight
                    else              p <= p + a_sh;
                end
                a_sh <= a_sh <<< 1;
                b_sh <= b_sh >> 1;
                if (cnt == 4'd12) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                end else begin
                    cnt <= cnt + 4'd1;
                end
            end
        end
    end
endmodule
/* verilator lint_on DECLFILENAME */

module sc_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] cur_i0,
    input  wire signed [7:0] cur_q0,
    input  wire signed [7:0] del_i0,
    input  wire signed [7:0] del_q0,
    input  wire        delayed_valid,
    input  wire [3:0]  sf,
    input  wire [1:0]  sample_shift,
    input  wire [15:0] sc_thr,
    input  wire [1:0]  sc_hits_req,
    input  wire        sc_clr,     // re-arm: clear lock + detection state (packet done)
    input  wire        sc_lock_force, // manual override (reg_bank SC_FORCE_LOCK 0x19, W1P)
    input  wire        sc_lock_sync,  // idle-only peer acquisition request
    output reg         sc_lock,
    output reg         sc_lock_natural_pulse,
    output reg  [31:0] timing_ref,
    output reg  signed [31:0] c_i0, c_q0,
    output wire        sc_tdm_busy_dbg,  // debug-probe observability only (DBG_CTRL group 011)
    // "An evaluation is in flight that could still emit a hit." Open Risk #66:
    // sc_hit_dbg is a registered 1-cycle pulse that can become visible a
    // variable number of edges after a noise window's training_done, so the
    // trouper_top contamination gate holds its verdict until this is low.
    output wire        sc_pipe_active,
    // 1-cycle pulse: a per-symbol metric evaluation just completed (hit or not).
    // Open Risk #66 (P2): the trouper_top noise-window gate uses this to prove
    // the symbol that was accumulating at training_done has actually been
    // judged before it renders a verdict -- sc_pipe_active going low only means
    // nothing is *currently* in flight, not that the pending symbol was scored.
    output wire        sc_eval_done_pulse,
    // 1-cycle pulse: a per-symbol metric evaluation just LAUNCHED (at the symbol
    // boundary). Open Risk #66 (P2): the trouper_top noise-window gate uses this
    // to require a verdict-qualifying evaluation that STARTED after training_done
    // -- one already in flight at training_done was fed the symbol *before* the
    // noise-window tail and must not count.
    output wire        sc_eval_start_pulse,
    output reg  [15:0] sc_stat,
    output reg         sc_hit_dbg,
    // Held mirror of sc_hit_dbg for register readback (SC_DBG_FLAGS[0]):
    // sc_hit_dbg is a 1-cycle pulse (internal consumer: the noise-window
    // contamination latch in trouper_top) — read combinationally over SPI it
    // is firmware-invisible. This holds the most recent symbol evaluation's
    // hit decision until the next evaluation; cleared on reset and sc_clr.
    output reg         sc_hit_hold,
    output reg  [1:0]  sc_hit_count_dbg,
    output reg  [31:0] sc_first_hit_dbg,
    output reg  [31:0] sc_lock_sample_dbg
);

    // =========================================================
    // Input registers
    // =========================================================
    reg signed [7:0] cur_i0_r, cur_q0_r;
    reg signed [7:0] del_i0_r, del_q0_r;
    reg              iq_valid_r, delayed_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_i0_r <= 8'sd0; cur_q0_r <= 8'sd0;
            del_i0_r <= 8'sd0; del_q0_r <= 8'sd0;
            iq_valid_r <= 1'b0; delayed_valid_r <= 1'b0;
        end else begin
            cur_i0_r <= cur_i0; cur_q0_r <= cur_q0;
            del_i0_r <= del_i0; del_q0_r <= del_q0;
            iq_valid_r      <= iq_valid;
            delayed_valid_r <= delayed_valid;
        end
    end

    reg [31:0] sample_count;
    reg [14:0] sym_cnt;  // up to 16383 (SF12+shift=2)
    reg [14:0] M_val;    // M = 2^(SF+sample_shift): 128..16384
    always @(*) begin
        case (sf)
            4'd6:    M_val = 15'd64   << sample_shift;
            4'd7:    M_val = 15'd128  << sample_shift;
            4'd8:    M_val = 15'd256  << sample_shift;
            4'd9:    M_val = 15'd512  << sample_shift;
            4'd10:   M_val = 15'd1024 << sample_shift;
            4'd11:   M_val = 15'd2048 << sample_shift;
            4'd12:   M_val = 15'd4096 << sample_shift;
            default: M_val = 15'd128  << sample_shift;
        endcase
    end

    // =========================================================
    // Per-symbol accumulators (NR=1).  Open Risk #61: widened 24 -> 32 bit.
    // One symbol of energy is Sum(cur_i0^2 + cur_q0^2) over M <= 16384 samples;
    // absolute max (both components clipped to +-127 for a whole symbol) is
    // 16384 * (127^2 + 127^2) = 528,515,072 (~2^29), so signed 32-bit has ~4x
    // headroom and never wraps in one symbol. The old 24-bit width assumed the
    // deleted 128-sample correlator; at SF12 a nominal-AGC preamble overran it.
    // =========================================================
    reg signed [31:0] acc_ci0, acc_cq0;
    reg signed [31:0] acc_E0cur, acc_E0del;

    // Symbol-boundary snapshot shift (Open Risk #61). The 13-bit eval_* operands
    // must hold the top ~12 significant bits of one symbol's accumulator for
    // ANY M, so the shift tracks M: M = 2^(sf+sample_shift), and shifting by
    // (sf+sample_shift+2) makes the snapshot magnitude M-independent
    //   acc_E0cur ~ M*A^2*2  ->  >> (sf+ss+2)  ~  A^2/2  (constant in M).
    // K=2 keeps SF7/BW250 at the historical >>10, so sc_thr is unchanged; the
    // metric is a k^2/k^2 ratio (see eval_hit) so sc_thr stays a single value
    // for every SF/BW. A near-full-scale (overdriven) symbol can still push the
    // shifted value past 13 bits -- sat13() clamps it there rather than wrap
    // (bounded, degraded, same policy as training_acc Open Risk #63).
    wire [4:0] snap_sh = {1'b0, sf} + {3'b0, sample_shift} + 5'd2;

    function signed [12:0] sat13;
        input signed [31:0] v;
        begin
            if      (v >  32'sd4095)  sat13 = 13'sd4095;
            else if (v < -32'sd4096)  sat13 = -13'sd4096;
            else                      sat13 = v[12:0];
        end
    endfunction

    // =========================================================
    // TDM per-sample 8×8 multiplier
    //
    // 8 steps per sample (down from 16 — ch1 removed):
    //
    //   Step  Inputs A×B              Accumulate at odd step
    //   ----  ----------------------  ------------------------------------------
    //   0,1   cur_i0×del_i0, cq0×dq0  acc_ci0 += P0 + P1  (re corr ch0)
    //   2,3   cur_q0×del_i0, ci0×dq0  acc_cq0 += P2 - P3  (im corr ch0)
    //   4,5   cur_i0², cur_q0²         acc_E0cur += P4 + P5
    //   6,7   del_i0², del_q0²         acc_E0del += P6 + P7; end TDM
    //
    // Pipeline: tdm_a_r/tdm_b_r registered → tdm_mul (comb) → tdm_mul_r (registered).
    // At odd step N: tdm_mul_r = P_{N-1}, tdm_mul = P_N (comb).
    // =========================================================
    reg signed [7:0] tlat_ci0, tlat_qi0, tlat_di0, tlat_dq0;

    reg        tdm_busy;
    assign sc_tdm_busy_dbg = tdm_busy;
    reg [3:0]  tdm_step;
    reg signed [7:0]  tdm_a_r, tdm_b_r;
    wire signed [15:0] tdm_mul = tdm_a_r * tdm_b_r;
    reg  signed [15:0] tdm_mul_r;
    // acc_E0del with this sample's del-energy folded in (Open Risk #61):
    // acc_E0del is written at TDM step 7, the same edge the symbol-boundary
    // snapshot reads it, so the snapshot uses this forward-combined value.
    wire signed [31:0] acc_E0del_next = acc_E0del
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
    // SS-timing pacing: the 8x8 tdm multiply is ~76 ns at the FD SS corner and
    // cannot settle in one 31.25 ns cycle.  The TDM burst is ~8 steps once per
    // 500 kS/s sample (64 clocks), so we hold each step TDM_WAIT+1 = 3 cycles
    // (burst grows 8->24 clocks, still << 64) — every tdm multiply then has a
    // genuine 3-cycle (MCP=3) budget.  Operands (tlat_* + the step pre-select)
    // are stable across the hold, so the arithmetic is unchanged.
    localparam [1:0] TDM_WAIT = 2'd2;

    // Peer-sync epoch compensation, in 500 kS/s output samples.  See the
    // sc_lock_sync block below for the derivation; measured, and regression-
    // locked by cocotb/array_sync.
    localparam [31:0] SYNC_EPOCH_LAG_SAMPLES = 32'd2;
    reg [1:0]  tdm_wait;
    reg        iq_inc_pending;   // defer a sample_count++ that lands mid-burst

    reg signed [31:0] sym_ci0, sym_cq0;   // Open Risk #61: 24 -> 32 bit (raw correlation sum)
    reg signed [27:0] sym_mag_sc;   // max |C|² = 2×4095² < 2^25; 28-bit sufficient

    reg [1:0]  hit_count;
    reg [31:0] first_hit_sample, eval_sample_mark;
    reg        metric_valid_pulse;
    reg        metric_start_pulse;   // Open Risk #66 P2: 1-cycle at eval launch (symbol boundary)

    // =========================================================
    // Serialised metric engine — 4 multiplications (steps 0..3), one shared
    // bit-serial serial_mul13.  Sequential launch/wait handshake: issue a
    // product, wait ~14 cycles for `mul_done`, accumulate, launch the next.
    // =========================================================
    reg        eval_busy;
    // Open Risk #66: high while a per-sample TDM burst, the serial metric
    // engine, its completion pulse, or the resulting 1-cycle sc_hit_dbg is in
    // flight -- i.e. while an in-progress evaluation could still register a hit.
    // The trouper_top noise-window gate holds its verdict until this is low.
    assign sc_pipe_active = tdm_busy | eval_busy | metric_valid_pulse | sc_hit_dbg;
    assign sc_eval_done_pulse = metric_valid_pulse;
    assign sc_eval_start_pulse = metric_start_pulse;
    reg [3:0]  eval_step;
    reg        mul_start;
    reg signed [27:0] eval_mag_acc, eval_e_acc;  // 28-bit: 3-bit headroom over max 2^25

    reg signed [12:0] eval_ci0, eval_cq0;
    reg signed [12:0] eval_E0cur, eval_E0del;

    // Combinational operand select (serial_mul13 latches on `mul_start`).
    reg signed [12:0] eval_mul_a_sel, eval_mul_b_sel;
    always @(*) begin
        case (eval_step)
            4'd0: begin eval_mul_a_sel = eval_ci0;   eval_mul_b_sel = eval_ci0;   end
            4'd1: begin eval_mul_a_sel = eval_cq0;   eval_mul_b_sel = eval_cq0;   end
            4'd2: begin eval_mul_a_sel = eval_E0cur; eval_mul_b_sel = eval_E0del;  end
            default: begin
                // sc_thr[11:0] caps the threshold at 12 bits (0..4095) so bit 12
                // of the 13-bit signed operand is always 0 (always positive).
                // Firmware must write sc_thr ÷ 64 of the legacy value (see header).
                eval_mul_a_sel = {1'b0, sc_thr[11:0]};
                eval_mul_b_sel = $signed(eval_e_acc[25:13]);
            end
        endcase
    end

    wire        mul_done;
    wire signed [25:0] eval_prod;
    serial_mul13 u_eval_mul (
        .clk(clk), .rst_n(rst_n), .start(mul_start),
        .a(eval_mul_a_sel), .b(eval_mul_b_sel),
        .done(mul_done), .p(eval_prod));

    reg        eval_hit;

    // =========================================================
    // Main sequential block
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count    <= 32'd0;
            sym_cnt         <= 15'd0;
            acc_ci0  <= 32'sd0; acc_cq0  <= 32'sd0;
            acc_E0cur<= 32'sd0; acc_E0del<= 32'sd0;
            tlat_ci0 <= 8'sd0; tlat_qi0 <= 8'sd0;
            tlat_di0 <= 8'sd0; tlat_dq0 <= 8'sd0;
            tdm_busy    <= 1'b0;
            tdm_step    <= 4'd0;
            tdm_wait    <= 2'd0;
            iq_inc_pending <= 1'b0;
            tdm_a_r     <= 8'sd0; tdm_b_r <= 8'sd0;
            tdm_mul_r   <= 16'sd0;
            sym_ci0  <= 32'sd0; sym_cq0  <= 32'sd0;
            sym_mag_sc <= 28'sd0;
            hit_count        <= 2'd0;
            first_hit_sample <= 32'd0;
            eval_sample_mark <= 32'd0;
            metric_valid_pulse <= 1'b0;
            metric_start_pulse <= 1'b0;
            eval_busy       <= 1'b0;
            eval_step       <= 4'd0;
            mul_start       <= 1'b0;
            eval_mag_acc <= 28'sd0; eval_e_acc <= 28'sd0;
            eval_hit     <= 1'b0;
            eval_ci0  <= 13'sd0; eval_cq0  <= 13'sd0;
            eval_E0cur<= 13'sd0; eval_E0del<= 13'sd0;
            sc_lock            <= 1'b0;
            sc_lock_natural_pulse <= 1'b0;
            timing_ref         <= 32'd0;
            c_i0 <= 32'sd0; c_q0 <= 32'sd0;
            sc_stat            <= 16'd0;
            sc_hit_dbg         <= 1'b0;
            sc_hit_hold        <= 1'b0;
            sc_hit_count_dbg   <= 2'd0;
            sc_first_hit_dbg   <= 32'd0;
            sc_lock_sample_dbg <= 32'd0;
        end else begin
            metric_valid_pulse <= 1'b0;
            metric_start_pulse <= 1'b0;
            sc_hit_dbg         <= 1'b0;
            sc_lock_natural_pulse <= 1'b0;
            mul_start          <= 1'b0;  // default; pulsed to launch a product

            // -----------------------------------------------------------------
            // Sample arrives: latch inputs, start TDM
            // -----------------------------------------------------------------
            if (delayed_valid_r && !tdm_busy) begin
                tlat_ci0 <= cur_i0_r; tlat_qi0 <= cur_q0_r;
                tlat_di0 <= del_i0_r; tlat_dq0 <= del_q0_r;
                tdm_a_r  <= cur_i0_r;
                tdm_b_r  <= del_i0_r;
                tdm_step <= 4'd0;
                tdm_wait <= 2'd0;
                tdm_busy <= 1'b1;
            end

            // -----------------------------------------------------------------
            // sample_count: exactly ONE increment per iq sample (iq_valid_r),
            // independent of when (or whether) its delayed counterpart gets
            // processed. Fixed 2026-07-06: this used to be guarded with
            // !delayed_valid_r and ALSO incremented at TDM step 7 — correct
            // when the delay line returned data in the same cycle as iq_valid
            // (old on-chip-SRAM frontend_buf_ctrl), but psram_buf_ctrl asserts
            // del_valid ~44 clocks AFTER iq_valid, so both paths fired and
            // every sample was counted TWICE. That put eval_sample_mark /
            // timing_ref / SC_FIRST_HIT / SC_LOCK_SNAP in inflated units
            // relative to iq_samp_cnt (packet FSM) and training_acc's counter,
            // with the error growing over the session (~2 symbols by the first
            // lock, ~T samples by a lock at true sample T).
            // The iq_inc_pending deferral is kept: an increment must not land
            // while a TDM burst is in flight, so the symbol-boundary
            // eval_sample_mark latch always reads the pre-increment value of
            // any sample that arrives mid-burst.
            // -----------------------------------------------------------------
            if (iq_valid_r && !tdm_busy) begin
                sample_count <= sample_count + 32'd1;
            end else if (iq_valid_r && tdm_busy) begin
                iq_inc_pending <= 1'b1;
            end else if (iq_inc_pending && !tdm_busy) begin
                sample_count   <= sample_count + 32'd1;
                iq_inc_pending <= 1'b0;
            end

            // -----------------------------------------------------------------
            // TDM engine: one 8×8 multiply per cycle, 8 cycles per sample
            // -----------------------------------------------------------------
            if (tdm_busy) begin
              if (tdm_wait != TDM_WAIT) tdm_wait <= tdm_wait + 2'd1;  // hold: let tdm_mul settle
              else begin
                tdm_wait  <= 2'd0;
                tdm_mul_r <= tdm_mul;
                tdm_step  <= tdm_step + 4'd1;

                // Pre-select inputs for next step
                case (tdm_step)
                    4'd0:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_dq0; end
                    4'd1:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_di0; end
                    4'd2:  begin tdm_a_r <= tlat_ci0; tdm_b_r <= tlat_dq0; end
                    4'd3:  begin tdm_a_r <= tlat_ci0; tdm_b_r <= tlat_ci0; end
                    4'd4:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_qi0; end
                    4'd5:  begin tdm_a_r <= tlat_di0; tdm_b_r <= tlat_di0; end
                    4'd6:  begin tdm_a_r <= tlat_dq0; tdm_b_r <= tlat_dq0; end
                    default: begin end  // step 7: last step
                endcase

                // Accumulate at odd steps (32-bit accumulators, Open Risk #61 —
                // sign-extend the 16-bit product to 32).
                case (tdm_step)
                    4'd1:  acc_ci0   <= acc_ci0
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                    4'd3:  acc_cq0   <= acc_cq0
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                - {{16{tdm_mul[15]}},   tdm_mul};
                    4'd5:  acc_E0cur <= acc_E0cur
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                    4'd7: begin
                        // acc_E0del's increment lands on THIS edge; the boundary
                        // snapshot below must see the completed value, so
                        // forward-combine it (Open Risk #61 last-sample fix —
                        // acc_ci0/cq0/E0cur are updated at steps 1/3/5 and are
                        // already complete here).
                        acc_E0del <= acc_E0del_next;
                        // ----- End of TDM for this sample -----
                        // (sample_count is NOT incremented here — this sample
                        // was already counted at its iq_valid_r; see the
                        // single-increment block above, fixed 2026-07-06.)
                        tdm_busy     <= 1'b0;

                        if (sym_cnt == M_val - 15'd1) begin
                            sym_cnt <= 15'd0;
                            sym_ci0 <= acc_ci0; sym_cq0 <= acc_cq0;

                            // Snapshot for eval: M-dependent arithmetic right
                            // shift -> sign-preserving 13-bit operand, magnitude
                            // ~constant in M, saturated at overdrive (Open Risk
                            // #61). acc_E0del uses the forward-combined value.
                            eval_ci0   <= sat13(acc_ci0        >>> snap_sh);
                            eval_cq0   <= sat13(acc_cq0        >>> snap_sh);
                            eval_E0cur <= sat13(acc_E0cur      >>> snap_sh);
                            eval_E0del <= sat13(acc_E0del_next >>> snap_sh);

                            eval_mag_acc    <= 28'sd0;
                            eval_e_acc      <= 28'sd0;
                            eval_step       <= 4'd0;
                            eval_busy       <= 1'b1;
                            metric_start_pulse <= 1'b1;  // Open Risk #66 P2: eval launched
                            mul_start       <= 1'b1;  // launch product 0 (ci0²)
                            // sample_count already includes the current sample
                            // (counted at its iq_valid_r), so the mark is the
                            // plain count — previously `+ 1` because the old
                            // step-7 increment for this sample had not landed
                            // yet in the same NBA cycle. 1-based index either way.
                            eval_sample_mark <= sample_count;

                            acc_ci0   <= 32'sd0; acc_cq0   <= 32'sd0;
                            acc_E0cur <= 32'sd0; acc_E0del <= 32'sd0;
                        end else begin
                            sym_cnt <= sym_cnt + 15'd1;
                        end
                    end
                    default: begin end
                endcase
              end
            end

            // -----------------------------------------------------------------
            // Metric evaluation engine (4 steps: ci0², cq0², E0cur×E0del, thr)
            // -----------------------------------------------------------------
            if (eval_busy && mul_done) begin
                // A product just completed (serial_mul13 == exact integer a*b);
                // accumulate it, then launch the next step (or finish at step 3).
                case (eval_step)
                    4'd0: eval_mag_acc <= eval_mag_acc + {{2{eval_prod[25]}}, eval_prod};
                    4'd1: eval_mag_acc <= eval_mag_acc + {{2{eval_prod[25]}}, eval_prod};
                    4'd2: begin
                        eval_e_acc <= eval_e_acc + {{2{eval_prod[25]}}, eval_prod};
                        sym_mag_sc <= eval_mag_acc;
                    end
                    default: begin
                        // e_slice==0 means energy² < 8192 ADU — threshold
                        // comparison degenerates to 0; suppress hit to avoid
                        // false alarms on noise. Threshold is implicitly
                        // SF-adaptive: A_min ∝ 1/√M, matching LoRa sensitivity.
                        eval_hit           <= (eval_e_acc > 28'sd0) &&
                                              (eval_e_acc[25:13] > 13'sd0) &&
                                              ({1'b0, eval_mag_acc[27:1]} >=
                                               {{2{eval_prod[25]}}, eval_prod});
                        eval_busy          <= 1'b0;
                        metric_valid_pulse <= 1'b1;
                    end
                endcase

                // Step 2's product updates eval_e_acc this cycle; the step-3
                // operand (thr × e_slice) reads it combinationally next cycle,
                // when mul_start relaunches, so the ordering is preserved.
                if (eval_step != 4'd3) begin
                    eval_step <= eval_step + 4'd1;
                    mul_start <= 1'b1;
                end
            end

            // -----------------------------------------------------------------
            // Lock detection
            // -----------------------------------------------------------------
            if (metric_valid_pulse && !sc_lock) begin
                sc_hit_dbg  <= eval_hit;
                sc_hit_hold <= eval_hit;   // held (no default clear) for SPI readback
                if (eval_hit) begin
                    if (hit_count == 2'd0)
                        first_hit_sample <= eval_sample_mark;
                    if (hit_count == sc_hits_req) begin
                        sc_lock            <= 1'b1;
                        sc_lock_natural_pulse <= 1'b1;
                        sc_lock_sample_dbg <= eval_sample_mark;
                        // (sc_hits_req+1)*M: M=2^(sf+sample_shift), shift by sf+sample_shift.
                        // n_hits_p1 ∈ 1..4 (3 bits); offset ≤ 4×16384=65536 (17 bits).
                        begin : blk_timing
                            reg [2:0]  n_hits_p1;
                            reg [16:0] sc_off;
                            n_hits_p1 = {1'b0, sc_hits_req} + 2'd1;
                            sc_off = {14'd0, n_hits_p1} << (sf + sample_shift);
                            timing_ref <= eval_sample_mark - {15'd0, sc_off} + 32'd1;
                        end
                        c_i0 <= sym_ci0;   // Open Risk #61: sym_ci0/cq0 now 32-bit
                        c_q0 <= sym_cq0;
                        sc_first_hit_dbg <= first_hit_sample;
                        hit_count <= 2'd0;
                    end else begin
                        hit_count <= hit_count + 2'd1;
                    end
                end else begin
                    hit_count <= 2'd0;
                end
                sc_hit_count_dbg <= hit_count;
            end

            // Peer array acquisition request. This is intentionally distinct
            // from SC_FORCE_LOCK: it has passed the idle-only guard in
            // array_acq_sync and uses the same hit-run back-calculation as a
            // natural SC lock. Linked arrays must share SF/BW, IQ_CLK, and
            // reset deassertion. A simultaneous local qualified hit wins.
            //
            // The peer path is inherently LATE relative to the chip that
            // detected: that chip back-calculates from eval_sample_mark (the
            // correlation window mark, latched when the hit was evaluated),
            // while this path can only read the live sample_count when the
            // wire edge arrives -- after the peer's evaluation pipeline, its
            // lock-to-OE delay, and this chip's two-flop synchroniser.
            //
            // SYNC_EPOCH_LAG_SAMPLES removes that lag so both chips land on
            // the SAME timing_ref. The constant is legitimate because the
            // decimator is fixed R=64: one output sample is always 64 IQ_CLK
            // cycles, so a latency that is constant in clocks is constant in
            // samples for every SF and BW. Measured +2 samples at SF7/BW250,
            // SF7/BW125 and SF8/BW250 before compensation (cocotb/array_sync,
            // test_epoch_offset_is_stable_across_sf_bw, SGE job 5264); that
            // test now asserts the compensated delta is exactly 0 and will
            // fail if a future change to the evaluation pipeline moves it.
            if (sc_lock_sync && !sc_lock &&
                !(metric_valid_pulse && eval_hit && (hit_count == sc_hits_req))) begin
                sc_lock            <= 1'b1;
                sc_lock_sample_dbg <= sample_count;
                begin : blk_sync_timing
                    reg [2:0]  n_hits_p1;
                    reg [16:0] sc_off;
                    n_hits_p1 = {1'b0, sc_hits_req} + 2'd1;
                    sc_off = {14'd0, n_hits_p1} << (sf + sample_shift);
                    timing_ref <= sample_count - {15'd0, sc_off} + 32'd1
                                  - SYNC_EPOCH_LAG_SAMPLES;
                end
            end

            // -----------------------------------------------------------------
            // Manual force-lock: bring-up / catastrophic-detector-failure
            // escape hatch (reg_bank SC_FORCE_LOCK 0x19, W1P; blocked upstream
            // while PACKET_ACTIVE, so this only fires from IDLE). Unlike a
            // real hit there is no verified preamble edge to anchor on, so
            // timing_ref is best-effort: it latches the raw free-running
            // sample_count rather than a symbol-boundary-corrected value.
            // Downstream MRC training on a forced lock is not expected to
            // produce a meaningful channel estimate -- this exists to prove
            // the FSM/PSRAM/combiner chain is alive when the correlator
            // itself is suspected broken, not to recover a real packet.
            // -----------------------------------------------------------------
            if (sc_lock_force && !sc_lock) begin
                sc_lock            <= 1'b1;
                timing_ref         <= sample_count;
                sc_lock_sample_dbg <= sample_count;
            end

            sc_stat <= {sym_mag_sc[27:13], 1'b0}; // top 15 useful bits, zero-padded LSB

            // -----------------------------------------------------------------
            // Packet-done re-arm (TRPR-SCD-014): clear lock + detection state so
            // the next packet can be acquired. Overrides the logic above via
            // last-assignment-wins. sample_count is deliberately NOT reset — it
            // must stay free-running to keep the timing_ref domain aligned with
            // the top-level iq sample counter across packets.
            // -----------------------------------------------------------------
            if (sc_clr) begin
                sc_lock            <= 1'b0;
                hit_count          <= 2'd0;
                first_hit_sample   <= 32'd0;
                acc_ci0   <= 32'sd0; acc_cq0   <= 32'sd0;
                acc_E0cur <= 32'sd0; acc_E0del <= 32'sd0;
                sym_cnt            <= 15'd0;
                tdm_busy           <= 1'b0;
                tdm_wait           <= 2'd0;
                iq_inc_pending     <= 1'b0;
                eval_busy          <= 1'b0;
                mul_start          <= 1'b0;
                metric_valid_pulse <= 1'b0;
                metric_start_pulse <= 1'b0;
                sc_hit_dbg         <= 1'b0;
                sc_hit_hold        <= 1'b0;
            end
        end
    end

endmodule
