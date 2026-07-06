// psram_buf_ctrl.v
// Same-packet MRC PSRAM buffer controller for APS6404L-3SQR (64 Mbit QPI PSRAM).
//
// SRAM-free design: the on-chip FD SRAM has been removed.  PSRAM serves both:
//   (a) SC detector delay line — per iq_valid, write 8 bytes then read back
//       del_i0/del_q0 (branch 0 only) from N samples ago.  cur_i0/cur_q0 are
//       captured from the write data at write-done time.
//   (b) Same-packet MRC replay — at W_commit, switch to S_REPLAY: interleaved
//       write (live) + 8-byte read (from buf_base), feeding rpl_* to the combiner.
//
// Sub-cycle budget (32 MHz, CIC R=128 → iq_valid every 128 cycles):
//   S_WRITE  : 25 write + 19 del-read  = 44 sub-cycles  (84 spare)  ✓
//   S_REPLAY : 25 write + 31 rpl-read  = 56 sub-cycles  (72 spare)  ✓
//
// QPI init sequence (SPI serial mode on SIO[0]):
//   RSTEN(0x66) → RST(0x99) → tRST wait → Enter QPI(0x35)
//
// Sample format in PSRAM (8 bytes/sample):
//   byte 0=i0, 1=q0, 2=i1, 3=q1, 4=i2, 5=q2, 6=i3, 7=q3
//
// SC delay:
//   N = 2^(SF+sample_shift) samples (one full LoRa symbol in the decimated sample domain).
//   del_offset_bytes = N × 8 = 8 << (SF+sample_shift).
//   del_rdy fires after N iq_valid pulses since qe_init_done.
//
// Debug readback path (no PicoRV32 / Grouper required):
//   When packet_active=0 (IDLE) and QSPI_OWNER=0, the host RPi can read arbitrary
//   PSRAM addresses via the SPI slave register bridge:
//     0x72 PSRAM_DBG_ADDR_LO  [7:0]   — byte address bits [7:0]
//     0x73 PSRAM_DBG_ADDR_MID [7:0]   — byte address bits [15:8]
//     0x74 PSRAM_DBG_ADDR_HI  [6:0]   — byte address bits [22:16] (23-bit = 8 MB)
//     0x75 PSRAM_DBG_CTRL     R/W     — [0] RD_TRIG (strobe, self-clearing)
//                                        [1] AUTO_INC (re-arm after each 8-byte drain)
//                                        [7] DBG_BUSY (read-only, clears when data ready)
//     0x76 PSRAM_DBG_DATA     R only  — auto-incrementing byte window; 8 consecutive
//                                        reads drain one full 8-byte IQ sample; address
//                                        advances by 8 if AUTO_INC=1, else holds.
//   Sequence: write 0x72-0x74, write 0x75[0]=1, poll 0x75[7]=0, read 0x76 ×8.
//   Trigger and auto-inc refetch requests are latched into dbg_pend and serviced
//   only in the S_WRITE idle slot, with capture writes taking priority — a debug
//   fetch never starts in the same cycle an iq_valid write starts.
//   Debug reads are blocked (DBG_BUSY held) while packet_active=1, while
//   QSPI_OWNER=1 (pad handover), and before qe_init_done.
//
// Interface must remain QPI (not SPI): at 250 kHz iq_valid rate (128-cycle period),
// one period must fit both a write (25 cyc QPI) and an SC delay read (19 cyc QPI) = 44 cyc.
// SPI equivalents are ~96 cyc write + ~104 cyc read = 200 cyc — 1.56× over budget.
// SIO[3:0] occupy 4 dedicated pads (TRPR-PHY-003), so QPI costs zero extra pads
// vs SPI; there is no pin-count reason to downgrade.
//
// GF180MCU, 3.3V, 32 MHz

module psram_buf_ctrl (
    input  wire        clk_32m,
    input  wire        rst_n,

    // Config
    input  wire        psram_en,     // 1 = capture and replay enabled
    input  wire        init_start,   // start init when the local controller owns the pads
    input  wire        qspi_owner,   // 1 = ownership transferred away from local controller
    input  wire [3:0]  sf,           // spreading factor (7–12), for del address
    input  wire [1:0]  sample_shift, // BW offset: 1=250 kHz, 2=125 kHz; N=2^(SF+sample_shift)

    // Live IQ stream (4 branches, 8-bit signed)
    input  wire signed [7:0] iq_i0, iq_i1, iq_i2, iq_i3,
    input  wire signed [7:0] iq_q0, iq_q1, iq_q2, iq_q3,
    input  wire        iq_valid,

    // Packet control
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,    // preamble-start sample index from sc_detector
    input  wire [31:0] iq_sample_cnt, // free-running iq_valid counter from trouper_top
    input  wire        W_commit,
    input  wire        packet_end,
    input  wire        packet_active,
    input  wire        clr_err,       // write-1 pulse: clear sticky error flags

    // QPI pad interface
    output wire        sck,           // PSRAM clock (32 MHz, gated internally)
    output reg         ce_n,          // PSRAM CE# active-low
    output reg  [3:0]  sio_out,       // SIO[3:0] output to PSRAM
    input  wire [3:0]  sio_in,        // SIO[3:0] input from PSRAM
    output reg  [3:0]  sio_oe,        // output-enable (1=ASIC drives, 0=PSRAM drives)

    // SC detector delay-line outputs (replaces frontend_buf_ctrl + on-chip SRAM)
    output reg  signed [7:0] cur_i0, cur_q0,  // branch 0, latched at write-done
    output reg  signed [7:0] del_i0, del_q0,  // branch 0, N samples ago
    output reg         del_valid,     // pulses when cur/del pair is ready (gated on del_rdy)

    // Replay IQ output — muxed into combiner during REPLAY
    output reg  signed [7:0] rpl_i0, rpl_i1, rpl_i2, rpl_i3,
    output reg  signed [7:0] rpl_q0, rpl_q1, rpl_q2, rpl_q3,
    output reg         rpl_valid,     // one pulse per replayed sample

    // Status
    output reg         buf_active,    // sc_lock → packet_end
    output reg         replay_active, // W_commit → packet_end
    output reg         qe_init_done,
    output reg         replay_missed, // sticky: packet_end before W_commit
    output reg         overflow,      // sticky: wr_ptr lapped rd_ptr
    output reg         sample_skip,   // sticky: iq_valid arrived while QPI busy (sample lost)
    output reg  [2:0]  state_dbg,
    input  wire [22:0] dbg_addr,
    input  wire        dbg_auto_inc,
    input  wire        dbg_rd_trig,
    input  wire        dbg_data_pop,
    output wire        dbg_busy,
    output wire [7:0]  dbg_data
);

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam S_UNINIT  = 3'd0;
    localparam S_QE_INIT = 3'd1;
    localparam S_WRITE   = 3'd2;
    localparam S_REPLAY  = 3'd3;
    reg [2:0] state;

    // -----------------------------------------------------------------------
    // PSRAM address pointers — 23-bit (8 MB = 2^23 bytes), circular
    // -----------------------------------------------------------------------
    localparam ABITS = 23;
    localparam AMASK = 23'h7FFFFF;

    reg [ABITS-1:0] wr_ptr;
    reg [ABITS-1:0] rd_ptr;
    reg [ABITS-1:0] buf_base;
    reg             buf_base_valid;
    reg             sc_lock_prev;

    // del address = wr_ptr − N×8, latched at iq_valid trigger
    // del_offset = 8 << (sf+sample_shift)  (= N × 8 = 2^(SF+sample_shift) × 8)
    //
    // del_offset and del_n are REGISTERED (del_offset_r/del_n_r below), not live
    // combinational wires.  sf/sample_shift are write-locked during a packet
    // (quasi-static), so the variable shift '8 << (sf+sample_shift)' — a ~50-gate
    // barrel-shifter cone that was the SS-corner worst path (rb_sf_cfg →
    // del_addr/del_cnt, WNS -16.4 ns) — is computed once per config change into a
    // register instead of on every per-cycle del_addr/del_cnt path.  Honest
    // retiming: the shift settles long before the first iq_valid del-read uses it.
    reg [ABITS-1:0] del_addr;
    reg [ABITS-1:0] del_offset_r;
    wire [ABITS-1:0] del_offset_c = ({{(ABITS-4){1'b0}}, 4'd8} << (sf[3:0] + sample_shift));

    // del_rdy: true once N iq_valid pulses have accumulated since qe_init_done.
    // Re-armed whenever sf or sample_shift changes so a BW/SF change cannot present
    // a stale delayed sample before the new delay distance has been fully written.
    reg             del_rdy;
    reg [14:0]      del_cnt;
    reg [3:0]       sf_prev;
    reg [1:0]       sample_shift_prev;
    reg [14:0]      del_n_r;                                       // registered (see del_offset_r)
    wire [14:0]     del_n_c = (15'd1 << (sf[3:0] + sample_shift)); // 2^(SF+shift), 128..16384

    // -----------------------------------------------------------------------
    // QPI transaction sub-cycle FSM
    //   sub  0..24 : QPI write  (cmd 2 + addr 6 + data 16 + CE#-high 1)
    //   sub 25..43 : del-read   (cmd 2 + addr 6 + dummy 6 + 2B data 4 + CE#-high 1)
    //                            S_WRITE only
    //   sub 25..55 : rpl-read   (cmd 2 + addr 6 + dummy 6 + 8B data 16 + CE#-high 1)
    //                            S_REPLAY only
    // -----------------------------------------------------------------------
    reg [5:0] sub;
    reg       qpi_busy;

    reg [63:0] wr_data;  // {i0,q0,i1,q1,i2,q2,i3,q3} latched from iq_valid
    reg [63:0] rd_data;  // accumulated nibbles from PSRAM during read phase

    reg         dbg_mode;
    reg         dbg_fetch_busy;
    reg         dbg_pend;     // latched fetch request (RD_TRIG or auto-inc refetch)
    reg [22:0]  dbg_addr_cur;
    reg [63:0]  dbg_buf;
    reg [2:0]   dbg_idx;

    assign dbg_busy = qspi_owner || packet_active || dbg_fetch_busy || !qe_init_done;
    assign dbg_data = dbg_busy ? 8'h00 :
                      (dbg_idx == 3'd0) ? dbg_buf[63:56] :
                      (dbg_idx == 3'd1) ? dbg_buf[55:48] :
                      (dbg_idx == 3'd2) ? dbg_buf[47:40] :
                      (dbg_idx == 3'd3) ? dbg_buf[39:32] :
                      (dbg_idx == 3'd4) ? dbg_buf[31:24] :
                      (dbg_idx == 3'd5) ? dbg_buf[23:16] :
                      (dbg_idx == 3'd6) ? dbg_buf[15:8]  : dbg_buf[7:0];

    // -----------------------------------------------------------------------
    // QE_INIT sub-cycle FSM (32 sub-cycles, same as original)
    // -----------------------------------------------------------------------
    reg [5:0] init_sub;
    reg [7:0] init_sr;

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------
    reg  sck_en;
    // Deferred-effect copy of qspi_owner for the pad clock gate (TRPR-PSR-011):
    // latched only between QPI bursts, so an ownership request landing mid-burst
    // lets the in-flight transaction complete with its clock running (CE# low
    // with SCK frozen and SIO still driven is exactly the pad glitch the spec
    // prohibits — that was the pre-2026-07-06 behavior). New bursts are blocked
    // by the raw qspi_owner at every launch site, so nothing starts after the
    // request; the effect lands at the first engine-idle boundary.
    reg  qspi_owner_eff;
    assign sck = sck_en & clk_32m;

    wire [ABITS-1:0] cur_wr = wr_ptr;
    wire [ABITS-1:0] cur_rd = rd_ptr;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_UNINIT;
            wr_ptr         <= {ABITS{1'b0}};
            rd_ptr         <= {ABITS{1'b0}};
            buf_base       <= {ABITS{1'b0}};
            buf_base_valid <= 1'b0;
            sc_lock_prev   <= 1'b0;
            del_addr       <= {ABITS{1'b0}};
            del_offset_r   <= {ABITS{1'b0}};
            del_n_r        <= 15'd1;
            del_rdy        <= 1'b0;
            del_cnt        <= 15'd0;
            sf_prev        <= 4'd0;
            sample_shift_prev <= 2'd0;
            sub            <= 6'd0;
            qpi_busy       <= 1'b0;
            wr_data        <= 64'd0;
            rd_data        <= 64'd0;
            init_sub       <= 6'd0;
            init_sr        <= 8'd0;
            dbg_mode       <= 1'b0;
            dbg_fetch_busy <= 1'b0;
            dbg_pend       <= 1'b0;
            dbg_addr_cur   <= 23'd0;
            dbg_buf        <= 64'd0;
            dbg_idx        <= 3'd0;
            sck_en         <= 1'b0;
            qspi_owner_eff <= 1'b0;
            ce_n           <= 1'b1;
            sio_out        <= 4'd0;
            sio_oe         <= 4'd0;
            cur_i0 <= 8'sd0; cur_q0 <= 8'sd0;
            del_i0 <= 8'sd0; del_q0 <= 8'sd0;
            del_valid      <= 1'b0;
            rpl_i0 <= 8'sd0; rpl_q0 <= 8'sd0;
            rpl_i1 <= 8'sd0; rpl_q1 <= 8'sd0;
            rpl_i2 <= 8'sd0; rpl_q2 <= 8'sd0;
            rpl_i3 <= 8'sd0; rpl_q3 <= 8'sd0;
            rpl_valid      <= 1'b0;
            buf_active     <= 1'b0;
            replay_active  <= 1'b0;
            qe_init_done   <= 1'b0;
            replay_missed  <= 1'b0;
            overflow       <= 1'b0;
            sample_skip    <= 1'b0;
            state_dbg      <= 3'd0;
        end else begin
            sc_lock_prev      <= sc_lock;
            sf_prev           <= sf;
            sample_shift_prev <= sample_shift;
            // Registered barrel-shift outputs (quasi-static; off the per-cycle
            // path).  Loaded ONLY when sf/sample_shift have been stable for a
            // cycle (sf==sf_prev), so the '<<' cone has a guaranteed >=2-cycle
            // settle window before capture — this makes the SDC MCP=2 on
            // del_offset_c/del_n_c honest (the dest FF never latches a half-
            // settled barrel-shift result on the config-change boundary).  Any
            // residual transient is further masked by the del_rdy warm-up gate.
            if (sf == sf_prev && sample_shift == sample_shift_prev) begin
                del_offset_r <= del_offset_c;
                del_n_r      <= del_n_c;
            end
            rpl_valid    <= 1'b0;
            del_valid    <= 1'b0;
            state_dbg    <= state;

            if (!qpi_busy) qspi_owner_eff <= qspi_owner;
            sck_en <= ((state == S_QE_INIT) || qpi_busy) && !qspi_owner_eff;

            // Sticky error clear (write-1 pulse via PSRAM_CLR_ERR). Placed before
            // the per-state error sets below and before sample_skip detection, so a
            // genuine error landing in the same cycle as a clear is not lost.
            if (clr_err) begin
                overflow      <= 1'b0;
                replay_missed <= 1'b0;
                sample_skip   <= 1'b0;
            end

            // Sample-skip detection: a live sample arrived while the QPI engine was
            // still busy with a prior transaction, so it could not be captured.
            // Within the supported 125/250 kHz envelope the timing budget
            // (TRPR-PSR-014) guarantees this never fires; the flag makes any
            // out-of-budget condition observable (TRPR-PSR-020).
            if (iq_valid && qpi_busy && psram_en && qe_init_done && !qspi_owner)
                sample_skip <= 1'b1;

            // del_rdy counter: accumulate iq_valid pulses after init. An sf or
            // sample_shift change re-arms the warm-up so the SC detector never
            // sees a delayed sample from an address not yet written with N =
            // 2^(SF+sample_shift) fresh samples at the new delay distance.
            if (!qe_init_done) begin
                del_rdy <= 1'b0;
                del_cnt <= 15'd0;
            end else if (sf != sf_prev || sample_shift != sample_shift_prev) begin
                del_rdy <= 1'b0;
                del_cnt <= 15'd0;
            end else if (!del_rdy && iq_valid) begin
                if (del_cnt + 15'd1 >= del_n_r)
                    del_rdy <= 1'b1;
                else
                    del_cnt <= del_cnt + 15'd1;
            end

            // Debug-data pop: advance the byte index; on the eighth byte with
            // AUTO_INC set, request a refetch of the next sample.  The fetch
            // itself starts only from the S_WRITE idle slot below — never here —
            // so it cannot collide with a capture-write start or fire in a
            // state that would leave qpi_busy/dbg_fetch_busy orphaned.
            if (!dbg_busy && dbg_data_pop) begin
                if (dbg_idx == 3'd7) begin
                    dbg_idx <= 3'd0;
                    if (dbg_auto_inc) begin
                        dbg_addr_cur   <= (dbg_addr_cur + 23'd8) & AMASK;
                        dbg_fetch_busy <= 1'b1;
                        dbg_pend       <= 1'b1;
                    end
                end else begin
                    dbg_idx <= dbg_idx + 3'd1;
                end
            end

            // RD_TRIG: latch a fetch request whenever the debug engine is idle.
            // Pends until the S_WRITE idle slot services it, so a trigger that
            // lands while the QPI bus is busy is not lost.
            if (dbg_rd_trig && !dbg_fetch_busy && !packet_active && !qspi_owner
                && qe_init_done) begin
                dbg_addr_cur   <= dbg_addr;
                dbg_fetch_busy <= 1'b1;
                dbg_pend       <= 1'b1;
            end

            case (state)

                // ------------------------------------------------------------
                S_UNINIT: begin
                    ce_n   <= 1'b1;
                    sio_oe <= 4'd0;
                    if (init_start && !qspi_owner) begin
                        state    <= S_QE_INIT;
                        init_sub <= 6'd0;
                        init_sr  <= 8'h66; // RSTEN
                    end
                end

                // ------------------------------------------------------------
                S_QE_INIT: begin
                    sio_oe <= 4'b0001;
                    case (init_sub)
                        6'd0:  begin ce_n <= 1'b0; sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd1; end
                        6'd1:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd2; end
                        6'd2:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd3; end
                        6'd3:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd4; end
                        6'd4:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd5; end
                        6'd5:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd6; end
                        6'd6:  begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd7; end
                        6'd7:  begin sio_out <= {3'd0, init_sr[7]}; init_sub <= 6'd8; end
                        6'd8:  begin ce_n <= 1'b1; sio_oe <= 4'd0; init_sub <= 6'd9; end
                        6'd9:  begin init_sr <= 8'h99; init_sub <= 6'd10; end
                        6'd10: begin ce_n <= 1'b0; sio_oe <= 4'b0001; sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd11; end
                        6'd11: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd12; end
                        6'd12: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd13; end
                        6'd13: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd14; end
                        6'd14: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd15; end
                        6'd15: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd16; end
                        6'd16: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd17; end
                        6'd17: begin sio_out <= {3'd0, init_sr[7]}; init_sub <= 6'd18; end
                        6'd18: begin ce_n <= 1'b1; sio_oe <= 4'd0; init_sub <= 6'd19; end
                        6'd19: init_sub <= 6'd20;
                        6'd20: begin init_sr <= 8'h35; init_sub <= 6'd21; end
                        6'd21: begin ce_n <= 1'b0; sio_oe <= 4'b0001; sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd22; end
                        6'd22: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd23; end
                        6'd23: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd24; end
                        6'd24: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd25; end
                        6'd25: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd26; end
                        6'd26: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd27; end
                        6'd27: begin sio_out <= {3'd0, init_sr[7]}; init_sr <= {init_sr[6:0],1'b0}; init_sub <= 6'd28; end
                        6'd28: begin sio_out <= {3'd0, init_sr[7]}; init_sub <= 6'd29; end
                        6'd29: begin
                            ce_n         <= 1'b1;
                            sio_oe       <= 4'd0;
                            qe_init_done <= 1'b1;
                            state        <= S_WRITE;
                        end
                        default: init_sub <= init_sub + 6'd1;
                    endcase
                end

                // ------------------------------------------------------------
                // S_WRITE — circular write + del-read every iq_valid.
                // Sub 0..24:  QPI write 8 bytes at wr_ptr
                // Sub 25..43: QPI read 2 bytes (del_i0/del_q0) from del_addr
                // sc_lock rising edge: snapshot buf_base.
                // W_commit: → S_REPLAY.
                // ------------------------------------------------------------
                S_WRITE: begin
                    if (sc_lock && !sc_lock_prev && psram_en) begin : blk_bufbase_w
                        reg [22:0] back_bytes;
                        back_bytes = (iq_sample_cnt - timing_ref) << 3;
                        buf_base       <= (wr_ptr - back_bytes) & AMASK;
                        buf_base_valid <= 1'b1;
                        buf_active     <= 1'b1;
                    end

                    if (W_commit && buf_base_valid && psram_en) begin
                        rd_ptr        <= buf_base;
                        replay_active <= 1'b1;
                        state         <= S_REPLAY;
                    end

                    if (packet_end) begin
                        if (buf_base_valid) replay_missed <= 1'b1;
                        buf_base_valid <= 1'b0;
                        buf_active     <= 1'b0;
                    end

                    if (!qpi_busy) begin
                        ce_n   <= 1'b1;
                        sio_oe <= 4'd0;
                        // Capture writes take priority; pending debug fetches
                        // are serviced in the spare idle cycles between them.
                        if (iq_valid && psram_en && qe_init_done && !qspi_owner) begin
                            wr_data  <= {iq_i0, iq_q0, iq_i1, iq_q1,
                                         iq_i2, iq_q2, iq_i3, iq_q3};
                            del_addr <= (wr_ptr - del_offset_r) & AMASK;
                            dbg_mode <= 1'b0;
                            qpi_busy <= 1'b1;
                            sub      <= 6'd0;
                        end else if (dbg_pend && !packet_active && !qspi_owner
                                     && qe_init_done) begin
                            dbg_pend <= 1'b0;
                            dbg_mode <= 1'b1;
                            qpi_busy <= 1'b1;
                            sub      <= 6'd0;
                        end
                    end else begin
                        if (dbg_mode) begin
                            case (sub)
                                6'd0:  begin ce_n<=1'b0; sio_oe<=4'hF; sio_out<=4'hE; sub<=6'd1; end
                                6'd1:  begin sio_out<=4'hB; sub<=6'd2; end
                                6'd2:  begin sio_out<=dbg_addr_cur[22:20]; sub<=6'd3; end
                                6'd3:  begin sio_out<=dbg_addr_cur[19:16]; sub<=6'd4; end
                                6'd4:  begin sio_out<=dbg_addr_cur[15:12]; sub<=6'd5; end
                                6'd5:  begin sio_out<=dbg_addr_cur[11:8];  sub<=6'd6; end
                                6'd6:  begin sio_out<=dbg_addr_cur[7:4];   sub<=6'd7; end
                                6'd7:  begin sio_out<=dbg_addr_cur[3:0];   sub<=6'd8; end
                                6'd8:  begin sio_oe<=4'd0; sub<=6'd9; end
                                6'd9:  sub<=6'd10;
                                6'd10: sub<=6'd11;
                                6'd11: sub<=6'd12;
                                6'd12: sub<=6'd13;
                                6'd13: sub<=6'd14;
                                6'd14: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd15; end
                                6'd15: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd16; end
                                6'd16: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd17; end
                                6'd17: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd18; end
                                6'd18: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd19; end
                                6'd19: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd20; end
                                6'd20: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd21; end
                                6'd21: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd22; end
                                6'd22: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd23; end
                                6'd23: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd24; end
                                6'd24: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd25; end
                                6'd25: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd26; end
                                6'd26: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd27; end
                                6'd27: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd28; end
                                6'd28: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd29; end
                                6'd29: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd30; end
                                6'd30: begin
                                    ce_n          <= 1'b1;
                                    sio_oe        <= 4'd0;
                                    dbg_buf       <= rd_data;
                                    dbg_idx       <= 3'd0;
                                    dbg_fetch_busy<= 1'b0;
                                    dbg_mode      <= 1'b0;
                                    qpi_busy      <= 1'b0;
                                    sub           <= 6'd0;
                                end
                                default: sub <= 6'd0;
                            endcase
                        end else begin
                            case (sub)
                            // ---- QPI WRITE: CMD 0x02 ----
                            6'd0:  begin ce_n<=1'b0; sio_oe<=4'hF; sio_out<=4'h0; sub<=6'd1; end
                            6'd1:  begin sio_out<=4'h2; sub<=6'd2; end
                            // ---- WRITE ADDR ----
                            6'd2:  begin sio_out<=cur_wr[22:20]; sub<=6'd3; end
                            6'd3:  begin sio_out<=cur_wr[19:16]; sub<=6'd4; end
                            6'd4:  begin sio_out<=cur_wr[15:12]; sub<=6'd5; end
                            6'd5:  begin sio_out<=cur_wr[11:8];  sub<=6'd6; end
                            6'd6:  begin sio_out<=cur_wr[7:4];   sub<=6'd7; end
                            6'd7:  begin sio_out<=cur_wr[3:0];   sub<=6'd8; end
                            // ---- WRITE DATA (8 bytes = 16 nibbles) ----
                            6'd8:  begin sio_out<=wr_data[63:60]; sub<=6'd9;  end
                            6'd9:  begin sio_out<=wr_data[59:56]; sub<=6'd10; end
                            6'd10: begin sio_out<=wr_data[55:52]; sub<=6'd11; end
                            6'd11: begin sio_out<=wr_data[51:48]; sub<=6'd12; end
                            6'd12: begin sio_out<=wr_data[47:44]; sub<=6'd13; end
                            6'd13: begin sio_out<=wr_data[43:40]; sub<=6'd14; end
                            6'd14: begin sio_out<=wr_data[39:36]; sub<=6'd15; end
                            6'd15: begin sio_out<=wr_data[35:32]; sub<=6'd16; end
                            6'd16: begin sio_out<=wr_data[31:28]; sub<=6'd17; end
                            6'd17: begin sio_out<=wr_data[27:24]; sub<=6'd18; end
                            6'd18: begin sio_out<=wr_data[23:20]; sub<=6'd19; end
                            6'd19: begin sio_out<=wr_data[19:16]; sub<=6'd20; end
                            6'd20: begin sio_out<=wr_data[15:12]; sub<=6'd21; end
                            6'd21: begin sio_out<=wr_data[11:8];  sub<=6'd22; end
                            6'd22: begin sio_out<=wr_data[7:4];   sub<=6'd23; end
                            6'd23: begin sio_out<=wr_data[3:0];   sub<=6'd24; end
                            // ---- WRITE DONE: CE# high, advance wr_ptr, save cur ----
                            6'd24: begin
                                ce_n    <= 1'b1;
                                sio_oe  <= 4'd0;
                                wr_ptr  <= (wr_ptr + {{(ABITS-4){1'b0}}, 4'd8}) & AMASK;
                                cur_i0  <= $signed(wr_data[63:56]);
                                cur_q0  <= $signed(wr_data[55:48]);
                                sub     <= 6'd25;
                            end
                            // ---- DEL READ: CMD 0xEB ----
                            6'd25: begin ce_n<=1'b0; sio_oe<=4'hF; sio_out<=4'hE; sub<=6'd26; end
                            6'd26: begin sio_out<=4'hB; sub<=6'd27; end
                            // ---- DEL READ ADDR ----
                            6'd27: begin sio_out<=del_addr[22:20]; sub<=6'd28; end
                            6'd28: begin sio_out<=del_addr[19:16]; sub<=6'd29; end
                            6'd29: begin sio_out<=del_addr[15:12]; sub<=6'd30; end
                            6'd30: begin sio_out<=del_addr[11:8];  sub<=6'd31; end
                            6'd31: begin sio_out<=del_addr[7:4];   sub<=6'd32; end
                            6'd32: begin sio_out<=del_addr[3:0];   sub<=6'd33; end
                            // ---- 6 DUMMY CLOCKS ----
                            6'd33: begin sio_oe<=4'd0; sub<=6'd34; end
                            6'd34: sub<=6'd35;
                            6'd35: sub<=6'd36;
                            6'd36: sub<=6'd37;
                            6'd37: sub<=6'd38;
                            6'd38: sub<=6'd39;
                            // ---- DEL READ DATA: 2 bytes = 4 nibbles ----
                            // rd_data[15:8]=del_i0, [7:0]=del_q0 after 4 shifts
                            6'd39: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd40; end
                            6'd40: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd41; end
                            6'd41: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd42; end
                            6'd42: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd43; end
                            // ---- DEL READ DONE: CE# high, latch del, assert del_valid ----
                            6'd43: begin
                                ce_n      <= 1'b1;
                                sio_oe    <= 4'd0;
                                del_i0    <= $signed(rd_data[15:8]);
                                del_q0    <= $signed(rd_data[7:0]);
                                del_valid <= del_rdy;
                                qpi_busy  <= 1'b0;
                                sub       <= 6'd0;
                            end
                            default: sub <= 6'd0;
                            endcase
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_REPLAY — interleaved write (live) + read (from buf_base).
                // Sub 0..24:  QPI write 8 bytes at wr_ptr
                // Sub 25..55: QPI read 8 bytes from rd_ptr → rpl_*
                // packet_end → back to S_WRITE.
                // ------------------------------------------------------------
                S_REPLAY: begin
                    if (packet_end) begin
                        buf_base_valid <= 1'b0;
                        buf_active     <= 1'b0;
                        replay_active  <= 1'b0;
                        qpi_busy       <= 1'b0;
                        sub            <= 6'd0;
                        ce_n           <= 1'b1;
                        sio_oe         <= 4'd0;
                        state          <= S_WRITE;
                    end else if (!qpi_busy) begin
                        ce_n   <= 1'b1;
                        sio_oe <= 4'd0;
                        // !qspi_owner gate added 2026-07-06 (TRPR-PSR-010/011):
                        // S_WRITE's launch had it, this one didn't — an owner
                        // request mid-REPLAY never suspended the replay bursts.
                        if (iq_valid && psram_en && !qspi_owner) begin
                            wr_data  <= {iq_i0, iq_q0, iq_i1, iq_q1,
                                         iq_i2, iq_q2, iq_i3, iq_q3};
                            qpi_busy <= 1'b1;
                            sub      <= 6'd0;
                        end
                    end else begin
                        case (sub)
                            // ---- QPI WRITE: CMD 0x02 ----
                            6'd0:  begin ce_n<=1'b0; sio_oe<=4'hF; sio_out<=4'h0; sub<=6'd1; end
                            6'd1:  begin sio_out<=4'h2; sub<=6'd2; end
                            // ---- WRITE ADDR ----
                            6'd2:  begin sio_out<=cur_wr[22:20]; sub<=6'd3; end
                            6'd3:  begin sio_out<=cur_wr[19:16]; sub<=6'd4; end
                            6'd4:  begin sio_out<=cur_wr[15:12]; sub<=6'd5; end
                            6'd5:  begin sio_out<=cur_wr[11:8];  sub<=6'd6; end
                            6'd6:  begin sio_out<=cur_wr[7:4];   sub<=6'd7; end
                            6'd7:  begin sio_out<=cur_wr[3:0];   sub<=6'd8; end
                            // ---- WRITE DATA (8 bytes = 16 nibbles) ----
                            6'd8:  begin sio_out<=wr_data[63:60]; sub<=6'd9;  end
                            6'd9:  begin sio_out<=wr_data[59:56]; sub<=6'd10; end
                            6'd10: begin sio_out<=wr_data[55:52]; sub<=6'd11; end
                            6'd11: begin sio_out<=wr_data[51:48]; sub<=6'd12; end
                            6'd12: begin sio_out<=wr_data[47:44]; sub<=6'd13; end
                            6'd13: begin sio_out<=wr_data[43:40]; sub<=6'd14; end
                            6'd14: begin sio_out<=wr_data[39:36]; sub<=6'd15; end
                            6'd15: begin sio_out<=wr_data[35:32]; sub<=6'd16; end
                            6'd16: begin sio_out<=wr_data[31:28]; sub<=6'd17; end
                            6'd17: begin sio_out<=wr_data[27:24]; sub<=6'd18; end
                            6'd18: begin sio_out<=wr_data[23:20]; sub<=6'd19; end
                            6'd19: begin sio_out<=wr_data[19:16]; sub<=6'd20; end
                            6'd20: begin sio_out<=wr_data[15:12]; sub<=6'd21; end
                            6'd21: begin sio_out<=wr_data[11:8];  sub<=6'd22; end
                            6'd22: begin sio_out<=wr_data[7:4];   sub<=6'd23; end
                            6'd23: begin sio_out<=wr_data[3:0];   sub<=6'd24; end
                            // ---- WRITE DONE: CE# high, advance wr_ptr ----
                            6'd24: begin
                                ce_n   <= 1'b1;
                                sio_oe <= 4'd0;
                                wr_ptr <= (wr_ptr + {{(ABITS-4){1'b0}}, 4'd8}) & AMASK;
                                sub    <= 6'd25;
                            end
                            // ---- QPI READ: CMD 0xEB ----
                            6'd25: begin ce_n<=1'b0; sio_oe<=4'hF; sio_out<=4'hE; sub<=6'd26; end
                            6'd26: begin sio_out<=4'hB; sub<=6'd27; end
                            // ---- READ ADDR ----
                            6'd27: begin sio_out<=cur_rd[22:20]; sub<=6'd28; end
                            6'd28: begin sio_out<=cur_rd[19:16]; sub<=6'd29; end
                            6'd29: begin sio_out<=cur_rd[15:12]; sub<=6'd30; end
                            6'd30: begin sio_out<=cur_rd[11:8];  sub<=6'd31; end
                            6'd31: begin sio_out<=cur_rd[7:4];   sub<=6'd32; end
                            6'd32: begin sio_out<=cur_rd[3:0];   sub<=6'd33; end
                            // ---- 6 DUMMY CLOCKS ----
                            6'd33: begin sio_oe<=4'd0; sub<=6'd34; end
                            6'd34: sub<=6'd35;
                            6'd35: sub<=6'd36;
                            6'd36: sub<=6'd37;
                            6'd37: sub<=6'd38;
                            6'd38: sub<=6'd39;
                            // ---- READ DATA: 8 bytes = 16 nibbles ----
                            6'd39: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd40; end
                            6'd40: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd41; end
                            6'd41: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd42; end
                            6'd42: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd43; end
                            6'd43: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd44; end
                            6'd44: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd45; end
                            6'd45: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd46; end
                            6'd46: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd47; end
                            6'd47: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd48; end
                            6'd48: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd49; end
                            6'd49: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd50; end
                            6'd50: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd51; end
                            6'd51: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd52; end
                            6'd52: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd53; end
                            6'd53: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd54; end
                            6'd54: begin rd_data<={rd_data[59:0],sio_in}; sub<=6'd55; end
                            // ---- READ DONE: CE# high, advance rd_ptr, latch replay IQ ----
                            6'd55: begin
                                ce_n      <= 1'b1;
                                sio_oe    <= 4'd0;
                                rd_ptr    <= (rd_ptr + {{(ABITS-4){1'b0}}, 4'd8}) & AMASK;
                                rpl_i0    <= $signed(rd_data[63:56]);
                                rpl_q0    <= $signed(rd_data[55:48]);
                                rpl_i1    <= $signed(rd_data[47:40]);
                                rpl_q1    <= $signed(rd_data[39:32]);
                                rpl_i2    <= $signed(rd_data[31:24]);
                                rpl_q2    <= $signed(rd_data[23:16]);
                                rpl_i3    <= $signed(rd_data[15:8]);
                                rpl_q3    <= $signed(rd_data[7:0]);
                                rpl_valid <= 1'b1;
                                qpi_busy  <= 1'b0;
                                sub       <= 6'd0;
                                if (rd_ptr == wr_ptr) overflow <= 1'b1;
                            end
                            default: sub <= 6'd0;
                        endcase
                    end
                end

                default: state <= S_UNINIT;
            endcase
        end
    end

endmodule
