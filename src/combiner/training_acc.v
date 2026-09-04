// training_acc.v
// All-pairs cross-correlator + diagonal autocorrelator, fully serialised through
// one shared 8×8 pipelined multiplier.
//
// Outputs:
//   Zpair_kl (6 complex int32 pairs)         → firmware eigenvector path
//   Zdiag_k  = Σ|raw_k[n]|²  (int32, real)   → firmware noise estimation
//
// Noise mode: firmware writes TACC_NOISE_TRIG (reg_bank 0x1F[0]) to arm the
// accumulator without waiting for sc_lock. In noise mode Zpair_kl ≈ 0 (uncorrelated
// noise) and Zdiag_k ≈ σ²_k · n_acc (pure noise power). Use with noise_mode_r
// gating so normal sc_lock disarm is suppressed.
//
// TDM: 6 cross-pairs × 4 sub-steps + 4 diagonal pairs × 2 sub-steps = 32 active
// steps per sample.  Budget: iq_valid every ≥128 cycles (CIC R=128) — 95 idle.
//
// Pair table:
//   Cross-pairs (a < b): 0=(0,1) 1=(0,2) 2=(0,3) 3=(1,2) 4=(1,3) 5=(2,3)
//   Diagonal pairs:      6=Z_00  7=Z_11  8=Z_22  9=Z_33
//
// Sub-steps for cross-pairs (a,b):
//   sub=0: I_a×I_b → p_latch
//   sub=1: Q_a×Q_b → Zpair_i[pair] += p_latch+mul
//   sub=2: Q_a×I_b → p_latch
//   sub=3: I_a×Q_b → Zpair_q[pair] += p_latch−mul  (pair_a sign convention)
//
// Sub-steps for diagonal pairs (k = pair − 6):
//   sub=0: I_k×I_k → p_latch
//   sub=1: Q_k×Q_k → Zdiag[k] += p_latch + mul
//          at pair=9 (k=3), last_samp: commit Zdiag_3 final value, assert training_done
//
// Area optimisation: working accumulators merged with output snapshot registers.
// The _a registers have been removed; accumulation happens directly into the output
// registers (Zpair_i/q0..5, Zdiag_0..3). These are zeroed at arm time and are live
// (updating every sample) during the training window. Firmware must wait for
// training_done before reading — enforced by the training_done IRQ in reg_bank.
//
// Accumulators: 32-bit signed.
// GF180MCU, 3.3V, 32 MHz IQ_CLK domain (single clock net; activity is gated
// by iq_valid, one 16-step paced burst per 64-clock sample period).

module training_acc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] raw_i0, raw_i1, raw_i2, raw_i3,
    input  wire signed [7:0] raw_q0, raw_q1, raw_q2, raw_q3,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire [3:0]  sf,
    input  wire [1:0]  sample_shift,
    input  wire [3:0]  tacc_window_syms,
    input  wire        noise_trig,           // W1P from reg_bank: start noise-mode measurement
    // Individual Z_kl pairs (for firmware eigenvector path)
    output reg  signed [31:0] Zpair_i0, Zpair_q0,   // Z_01
    output reg  signed [31:0] Zpair_i1, Zpair_q1,   // Z_02
    output reg  signed [31:0] Zpair_i2, Zpair_q2,   // Z_03
    output reg  signed [31:0] Zpair_i3, Zpair_q3,   // Z_12
    output reg  signed [31:0] Zpair_i4, Zpair_q4,   // Z_13
    output reg  signed [31:0] Zpair_i5, Zpair_q5,   // Z_23
    // Z_kk autocorrelation (real, for noise estimation)
    output reg  [31:0] Zdiag_0, Zdiag_1, Zdiag_2, Zdiag_3,
    output reg         training_done,      // asserts for EITHER mode's completion
    output reg         training_done_pkt,  // asserts ONLY for a packet-mode window
                                           // (the packet FSM / w_pending path must
                                           //  never see a noise-window completion)
    output reg         noise_abort,        // 1-cycle: an armed noise window was
                                           // cancelled because sc_lock acquired a
                                           // real packet mid-measurement
    output reg  [17:0] n_acc,  // up to 131072 samples (SF12+shift=2 = 2^(12+2+3))
    output wire        training_armed
);

    reg [31:0] sample_count;
    reg [31:0] acc_start, acc_end;
    reg        armed;

    assign training_armed = armed;
    reg        noise_mode_r;    // 1 = firmware-triggered noise measurement in progress
    reg        noise_trig_r;    // previous-cycle noise_trig for edge detect
    reg        sc_lock_r;       // previous-cycle sc_lock for edge detect

    // Open Risk #68 (pipeline-flush): per-window epoch for the accumulate
    // pipeline. The noise-abort only clears `armed`/`noise_mode_r`; a final
    // noise sample already latched into the TDM/accumulate pipeline can still
    // reach the completion block afterwards and wrongly assert training_done /
    // training_done_pkt. A global valid *level* does not work -- a real packet
    // re-arms on the next cycle (sc_lock still high) and would re-validate the
    // stale work before it drains (~57 cycles). Instead every pipeline item
    // carries the epoch it was launched under (tdm_epoch -> acc_epoch); the
    // completion / accumulate only fire when acc_epoch matches the CURRENT
    // win_epoch. win_epoch bumps on every arm AND on the abort, so a stale
    // item's epoch can never coincide with the live one (2 bits: at most one
    // window's worth of items in flight, drained long before a 3rd bump).
    reg  [1:0]  win_epoch;      // current window epoch
    reg  [1:0]  tdm_epoch;      // epoch of the sample currently in the TDM burst
    reg  [1:0]  acc_epoch;      // epoch of the item currently in the accumulate stage

    wire noise_trig_rise = noise_trig && !noise_trig_r;
    wire sc_lock_rise    = sc_lock   && !sc_lock_r;
    // Clamp window to >= 8 symbols (same rule reg_bank applies to 0x27 writes).
    // In live mode acc_start = timing_ref, which lies up to (sc_hits_req+1) <= 4
    // symbols in the past at arm time; a window <= that latency puts acc_end
    // before the lock instant, so no sample ever accumulates and training_done
    // never fires (packet lost to PKT_TIMEOUT). The clamp keeps direct-drive
    // integrations (unit TBs, FPGA wrapper, formal) out of that dead zone.
    wire [3:0] tacc_window_eff = (tacc_window_syms < 4'd8) ? 4'd8 : tacc_window_syms;

    // TDM counters: pair (0–9) and sub-step.
    // DUAL-MULTIPLIER: two products per step halves the walk to 16 steps
    //   cross-pairs (0–5): 2 sub-steps  (sub0→Zpair_i, sub1→Zpair_q)
    //   diagonal   (6–9): 1 sub-step    (sub0→Zdiag)
    // 6×2 + 4×1 = 16 steps.  At 3-cycle pacing that is 48 (+drain) < 64-clock
    // window, so the ~73 ns MAC gets an honest MCP=3 budget (the original 32-step
    // walk could not fit any pace once the HB migration shrank R=128→R=64).
    reg [3:0] tdm_pair;
    reg [1:0] tdm_sub;
    reg       tdm_active;

    // SS-timing pacing (active-cycle freeze model, same as decimator/sc_detector).
    localparam [1:0] TDM_WAIT = 2'd2;     // run the pipeline 1 cycle in 3
    reg [1:0] tdm_wait;

    // 1-cycle delayed tags (synchronised with the registered products)
    reg [3:0] acc_pair;
    reg [1:0] acc_sub;
    reg       acc_active;

    wire pipe_active  = tdm_active || acc_active;
    wire active_cycle = pipe_active && (tdm_wait == TDM_WAIT);

    // Diagonal branch index k: valid when (tdm|acc)_pair ∈ {6,7,8,9}
    // pair 6→k=0, 7→k=1, 8→k=2, 9→k=3  (pair[1:0] XOR 2'b10)
    wire [1:0] diag_k     = tdm_pair[1:0] ^ 2'b10;
    wire [1:0] acc_diag_k = acc_pair[1:0] ^ 2'b10;

    // Pair lookup: pair index → (branch_a, branch_b), a < b (cross-pairs only)
    reg [1:0] tdm_pa, tdm_pb;
    always @(*) begin
        case (tdm_pair)
            4'd0: begin tdm_pa = 2'd0; tdm_pb = 2'd1; end
            4'd1: begin tdm_pa = 2'd0; tdm_pb = 2'd2; end
            4'd2: begin tdm_pa = 2'd0; tdm_pb = 2'd3; end
            4'd3: begin tdm_pa = 2'd1; tdm_pb = 2'd2; end
            4'd4: begin tdm_pa = 2'd1; tdm_pb = 2'd3; end
            default: begin tdm_pa = 2'd2; tdm_pb = 2'd3; end  // pair 5
        endcase
    end


    // Latched branch samples (captured at iq_valid trigger)
    reg signed [7:0] raw_i0_r, raw_i1_r, raw_i2_r, raw_i3_r;
    reg signed [7:0] raw_q0_r, raw_q1_r, raw_q2_r, raw_q3_r;
    reg              last_samp;

    // Combinational operand selection → single-cycle registered product.
    // Using wires (not registers) for op_a/op_b eliminates the extra pipeline
    // stage that caused mul_out to lag acc_pair by one TDM step, which produced
    // cross-pair contamination in the diagonal (Zdiag) accumulation.
    reg signed [15:0] mul_out;
    reg signed [7:0]  tdm_i_a_r, tdm_q_a_r, tdm_i_b_r, tdm_q_b_r, diag_i_r, diag_q_r;
    always @(*) begin
        case (tdm_pa)
            2'd0: begin tdm_i_a_r = raw_i0_r; tdm_q_a_r = raw_q0_r; end
            2'd1: begin tdm_i_a_r = raw_i1_r; tdm_q_a_r = raw_q1_r; end
            2'd2: begin tdm_i_a_r = raw_i2_r; tdm_q_a_r = raw_q2_r; end
            default: begin tdm_i_a_r = raw_i3_r; tdm_q_a_r = raw_q3_r; end
        endcase
        case (tdm_pb)
            2'd0: begin tdm_i_b_r = raw_i0_r; tdm_q_b_r = raw_q0_r; end
            2'd1: begin tdm_i_b_r = raw_i1_r; tdm_q_b_r = raw_q1_r; end
            2'd2: begin tdm_i_b_r = raw_i2_r; tdm_q_b_r = raw_q2_r; end
            default: begin tdm_i_b_r = raw_i3_r; tdm_q_b_r = raw_q3_r; end
        endcase
        case (diag_k)
            2'd0: begin diag_i_r = raw_i0_r; diag_q_r = raw_q0_r; end
            2'd1: begin diag_i_r = raw_i1_r; diag_q_r = raw_q1_r; end
            2'd2: begin diag_i_r = raw_i2_r; diag_q_r = raw_q2_r; end
            default: begin diag_i_r = raw_i3_r; diag_q_r = raw_q3_r; end
        endcase
    end
    // Dual-multiplier operand selection.
    //   cross sub0: mulA = I_a·I_b,  mulB = Q_a·Q_b   → Zpair_i += A + B
    //   cross sub1: mulA = Q_a·I_b,  mulB = I_a·Q_b   → Zpair_q += A − B
    //   diagonal  : mulA = I_k·I_k,  mulB = Q_k·Q_k   → Zdiag  += A + B (real)
    wire signed [7:0] opA_a = (tdm_pair >= 4'd6) ? diag_i_r
                            : (tdm_sub[0] ? tdm_q_a_r : tdm_i_a_r);
    wire signed [7:0] opA_b = (tdm_pair >= 4'd6) ? diag_i_r : tdm_i_b_r;
    wire signed [7:0] opB_a = (tdm_pair >= 4'd6) ? diag_q_r
                            : (tdm_sub[0] ? tdm_i_a_r : tdm_q_a_r);
    wire signed [7:0] opB_b = (tdm_pair >= 4'd6) ? diag_q_r : tdm_q_b_r;
    reg signed [15:0] mulB_out;   // mul_out (declared above) is mulA_out
    always @(posedge clk) begin
        if (active_cycle) begin
            mul_out  <= opA_a * opA_b;   // mulA
            mulB_out <= opB_a * opB_b;   // mulB
        end
    end

    // Addends: cross-pairs sign-extend; diagonal (squares, ≥0) zero-extend.
    wire signed [31:0] mulA_ext = {{16{mul_out[15]}},  mul_out};
    wire signed [31:0] mulB_ext = {{16{mulB_out[15]}}, mulB_out};
    wire signed [31:0] zi_add   = mulA_ext + mulB_ext;   // Zpair_i addend
    wire signed [31:0] zq_add   = mulA_ext - mulB_ext;   // Zpair_q addend
    wire        [31:0] zd_add   = {16'h0, mul_out[15:0]} + {16'h0, mulB_out[15:0]}; // Zdiag

    // Read mux for current cross-pair output register (read-modify-write)
    reg signed [31:0] zpair_ia_r, zpair_qa_r;
    always @(*) begin
        case (acc_pair)
            4'd0: begin zpair_ia_r = Zpair_i0; zpair_qa_r = Zpair_q0; end
            4'd1: begin zpair_ia_r = Zpair_i1; zpair_qa_r = Zpair_q1; end
            4'd2: begin zpair_ia_r = Zpair_i2; zpair_qa_r = Zpair_q2; end
            4'd3: begin zpair_ia_r = Zpair_i3; zpair_qa_r = Zpair_q3; end
            4'd4: begin zpair_ia_r = Zpair_i4; zpair_qa_r = Zpair_q4; end
            default: begin zpair_ia_r = Zpair_i5; zpair_qa_r = Zpair_q5; end
        endcase
    end

    // Saturating accumulate (Open Risk #63). The Z accumulators are 32-bit and
    // the per-sample terms are small (|zi_add|,|zq_add| < 2^16, zd_add < 2^17),
    // but a legal TACC_WINDOW_SYMS=15 window at high SF and near-full-scale
    // input can drive the running sum past the signed-int32 / unsigned-int32
    // range. Wrapping there sign-inverts Z and corrupts the firmware weight
    // computation; clamping degrades gracefully instead (bounded, monotonic Z).
    function signed [31:0] sadd32;
        input signed [31:0] a;
        input signed [31:0] b;
        reg   signed [32:0] s;
        begin
            s = {a[31], a} + {b[31], b};      // 33-bit exact
            case (s[32:31])
                2'b01:   sadd32 = 32'sh7FFFFFFF;   // positive overflow -> clamp
                2'b10:   sadd32 = 32'sh80000000;   // negative overflow -> clamp
                default: sadd32 = s[31:0];         // 2'b00 / 2'b11 -> in range
            endcase
        end
    endfunction

    function [31:0] uadd32;
        input [31:0] a;
        input [31:0] b;
        reg   [32:0] s;
        begin
            s = {1'b0, a} + {1'b0, b};
            uadd32 = s[32] ? 32'hFFFFFFFF : s[31:0];   // carry-out -> clamp
        end
    endfunction

    // Forward-combine final Zdiag_3 value at the last accumulation step
    wire [31:0] zdiag3_final = uadd32(Zdiag_3, zd_add);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count  <= 32'd0;
            armed         <= 1'b0;
            noise_mode_r  <= 1'b0;
            noise_trig_r  <= 1'b0;
            sc_lock_r     <= 1'b0;
            training_done <= 1'b0;
            training_done_pkt <= 1'b0;
            noise_abort   <= 1'b0;
            win_epoch     <= 2'd0;
            tdm_epoch     <= 2'd0;
            acc_epoch     <= 2'd0;
            n_acc         <= 18'd0;
            acc_start     <= 32'd0;
            acc_end       <= 32'd0;
            tdm_pair      <= 4'd0;
            tdm_sub       <= 2'd0;
            tdm_active    <= 1'b0;
            tdm_wait      <= 2'd0;
            acc_pair      <= 4'd0;
            acc_sub       <= 2'd0;
            acc_active    <= 1'b0;
            last_samp     <= 1'b0;
            raw_i0_r <= 8'sd0; raw_i1_r <= 8'sd0;
            raw_i2_r <= 8'sd0; raw_i3_r <= 8'sd0;
            raw_q0_r <= 8'sd0; raw_q1_r <= 8'sd0;
            raw_q2_r <= 8'sd0; raw_q3_r <= 8'sd0;
            // B2: Zpair_*/Zdiag_* are intentionally NOT reset here. They are
            // zeroed at arm time below (every training window) and never read
            // before that zeroing, so the reset was dead area — proven by
            // tb_tacc_resetless_equiv.v (garbage-init equivalence, 2 arm windows).
        end else begin
            if (iq_valid)
                sample_count <= sample_count + 32'd1;

            // Edge-detect registers
            noise_trig_r <= noise_trig;
            sc_lock_r    <= sc_lock;
            noise_abort  <= 1'b0;   // 1-cycle pulse

            // Disarm when sc_lock deasserts (suppressed in noise mode)
            if (!sc_lock && !noise_mode_r) begin
                armed      <= 1'b0;
                tdm_active <= 1'b0;
                tdm_pair   <= 4'd0;
                tdm_sub    <= 2'd0;
            end

            // A real packet acquired (sc_lock rising) while a firmware noise
            // measurement is in flight: cancel the noise window. `armed` clears
            // here, so the (sc_lock && !armed) arm clause below re-arms a proper
            // PACKET-mode window on the next edge with acc_start = timing_ref.
            // The cancelled noise window asserts neither training_done nor
            // training_done_pkt, so the packet FSM never sees a noise completion
            // aliased as packet-training completion.
            if (armed && noise_mode_r && sc_lock_rise) begin
                armed         <= 1'b0;
                noise_mode_r  <= 1'b0;
                noise_abort   <= 1'b1;
                win_epoch     <= win_epoch + 2'd1;   // retire the aborted window's epoch
            end
            // Arm on sc_lock rising edge (normal) or noise_trig rising edge (noise mode).
            // Zero output registers here — they serve as both working accumulators and
            // final outputs during the training window.
            else if ((sc_lock && !armed) || (noise_trig_rise && !armed)) begin
                armed         <= 1'b1;
                noise_mode_r  <= ~sc_lock;
                win_epoch     <= win_epoch + 2'd1;   // fresh window epoch
                training_done <= 1'b0;
                training_done_pkt <= 1'b0;
                acc_start     <= sc_lock ? timing_ref : sample_count;
                acc_end       <= sc_lock ? timing_ref + ({28'd0, tacc_window_eff} << (sf + sample_shift)) - 32'd1
                                         : sample_count + ({28'd0, tacc_window_eff} << (sf + sample_shift)) - 32'd1;
                Zpair_i0 <= 32'sd0; Zpair_q0 <= 32'sd0;
                Zpair_i1 <= 32'sd0; Zpair_q1 <= 32'sd0;
                Zpair_i2 <= 32'sd0; Zpair_q2 <= 32'sd0;
                Zpair_i3 <= 32'sd0; Zpair_q3 <= 32'sd0;
                Zpair_i4 <= 32'sd0; Zpair_q4 <= 32'sd0;
                Zpair_i5 <= 32'sd0; Zpair_q5 <= 32'sd0;
                Zdiag_0 <= 32'd0; Zdiag_1 <= 32'd0;
                Zdiag_2 <= 32'd0; Zdiag_3 <= 32'd0;
                n_acc <= 18'd0;
            end

            // Pacing counter: advance the pipeline once per TDM_WAIT+1 clocks
            // while it has work; reset when idle (and on (re)trigger).
            if (pipe_active && tdm_wait != TDM_WAIT)
                tdm_wait <= tdm_wait + 2'd1;
            else
                tdm_wait <= 2'd0;

            // Trigger TDM on iq_valid within window when idle.
            if (armed && (sc_lock || noise_mode_r) && iq_valid && !tdm_active &&
                    sample_count >= acc_start && sample_count <= acc_end &&
                    !training_done) begin
                raw_i0_r <= raw_i0; raw_q0_r <= raw_q0;
                raw_i1_r <= raw_i1; raw_q1_r <= raw_q1;
                raw_i2_r <= raw_i2; raw_q2_r <= raw_q2;
                raw_i3_r <= raw_i3; raw_q3_r <= raw_q3;
                last_samp  <= (sample_count == acc_end);
                n_acc <= n_acc + 18'd1;
                tdm_pair   <= 4'd0;
                tdm_sub    <= 2'd0;
                tdm_active <= 1'b1;
                tdm_epoch  <= win_epoch;   // Open Risk #68: tag this item's window
            end else if (active_cycle && tdm_active) begin
                if (tdm_pair >= 4'd6) begin
                    // Diagonal pairs: 1 sub-step (dual-mult does I²+Q² at once)
                    if (tdm_pair == 4'd9)
                        tdm_active <= 1'b0;
                    else
                        tdm_pair <= tdm_pair + 4'd1;
                end else begin
                    // Cross-pairs: 2 sub-steps (sub0→Zpair_i, sub1→Zpair_q)
                    if (tdm_sub == 2'd1) begin
                        tdm_sub <= 2'd0;
                        tdm_pair <= tdm_pair + 4'd1;
                    end else
                        tdm_sub <= tdm_sub + 2'd1;
                end
            end

            // Delayed tags — advance only on active cycle (stay synced with products)
            if (active_cycle) begin
                acc_pair   <= tdm_pair;
                acc_sub    <= tdm_sub;
                acc_active <= tdm_active;
                acc_epoch  <= tdm_epoch;   // Open Risk #68: carry the window tag
            end

            // Accumulate directly into output registers when products are ready
            // (dual-mult: both products available each step → no p_latch interleave).
            // Open Risk #68 (pipeline-flush): only accumulate / complete for an
            // item whose window epoch still matches. A noise sample left in the
            // pipe by an aborted window carries the retired epoch and is
            // silently dropped, even after a packet re-arm has bumped the epoch
            // again — no false training_done/_pkt, no stale Z writes.
            if (acc_active && active_cycle && (acc_epoch == win_epoch)) begin
                if (acc_pair <= 4'd5) begin
                    // --- Cross-pair accumulation ---
                    if (acc_sub == 2'd0) begin
                        // sub=0: Z_i = I_a×I_b + Q_a×Q_b  (saturating, Open Risk #63)
                        case (acc_pair)
                            4'd0: Zpair_i0 <= sadd32(zpair_ia_r, zi_add);
                            4'd1: Zpair_i1 <= sadd32(zpair_ia_r, zi_add);
                            4'd2: Zpair_i2 <= sadd32(zpair_ia_r, zi_add);
                            4'd3: Zpair_i3 <= sadd32(zpair_ia_r, zi_add);
                            4'd4: Zpair_i4 <= sadd32(zpair_ia_r, zi_add);
                            default: Zpair_i5 <= sadd32(zpair_ia_r, zi_add);
                        endcase
                    end else begin
                        // sub=1: Z_q = Q_a×I_b − I_a×Q_b  (saturating, Open Risk #63)
                        case (acc_pair)
                            4'd0: Zpair_q0 <= sadd32(zpair_qa_r, zq_add);
                            4'd1: Zpair_q1 <= sadd32(zpair_qa_r, zq_add);
                            4'd2: Zpair_q2 <= sadd32(zpair_qa_r, zq_add);
                            4'd3: Zpair_q3 <= sadd32(zpair_qa_r, zq_add);
                            4'd4: Zpair_q4 <= sadd32(zpair_qa_r, zq_add);
                            default: Zpair_q5 <= sadd32(zpair_qa_r, zq_add);
                        endcase
                    end
                end else begin
                    // --- Diagonal pair accumulation (1 step): Zdiag[k] += I_k² + Q_k² ---
                    if (acc_pair == 4'd9 && last_samp) begin
                        // Last diagonal, last sample: write final value and signal done
                        Zdiag_3 <= zdiag3_final;
                        training_done <= 1'b1;
                        // Packet-mode completion only: this is the pulse the
                        // packet FSM / w_pending consume. A noise-window
                        // completion asserts training_done (for the reg_bank
                        // status bit / IRQ, per TRPR-TAC-007) but NOT this.
                        if (!noise_mode_r)
                            training_done_pkt <= 1'b1;
                        if (noise_mode_r) begin
                            noise_mode_r <= 1'b0;
                            armed        <= 1'b0;
                        end
                    end else begin
                        case (acc_diag_k)   // saturating, Open Risk #63
                            2'd0: Zdiag_0 <= uadd32(Zdiag_0, zd_add);
                            2'd1: Zdiag_1 <= uadd32(Zdiag_1, zd_add);
                            2'd2: Zdiag_2 <= uadd32(Zdiag_2, zd_add);
                            default: Zdiag_3 <= uadd32(Zdiag_3, zd_add);
                        endcase
                    end
                end
            end
        end
    end

endmodule
