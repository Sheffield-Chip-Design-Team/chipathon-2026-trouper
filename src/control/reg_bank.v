// reg_bank.v
// Trouper configuration and status register bank.
// Address space: 0x00–0x7F (7-bit, hard constraint from the host SPI frame —
// bit [7] of the SPI command byte is R/W#).  8-bit registers, big-endian
// multi-byte fields.  See planning/Register Map.md (authoritative).
// 0x7F is permanently reserved (future SPI protocol-escape command byte).
// GF180MCU, 3.3V, 32 MHz single clock domain

module reg_bank (
    input  wire        clk,
    input  wire        clk_en,    // 16 MHz clock-enable: bank updates every other
                                  // 32 MHz cycle → write decode is a 2-cycle path
                                  // (honest MCP=2).  Bus inputs are CE-aligned and
                                  // we is 2 cycles wide → exactly one write/CE edge.
    input  wire        rst_n,

    // Register-bus slave byte interface (Grouper bus / SPI slave via arbiter)
    input  wire [7:0]  addr,    // WRITE address (CE-latched with we/wdata)
    input  wire [7:0]  raddr,   // READ address (combinational — peek has no CE latency)
    input  wire [7:0]  wdata,
    input  wire        we,
    input  wire        re,
    output reg  [7:0]  rdata,
    output wire [7:0]  peek_rdata,   // combinational read tap for SPI slave
    output wire        ready,        // reads insert one wait state

    // -----------------------------------------------------------------------
    // Hardware status inputs (RO registers)
    // -----------------------------------------------------------------------
    // Packet / weight control readback
    input  wire [1:0]  active_mode_rb,
    input  wire [3:0]  active_antenna_en_rb,
    input  wire        packet_active,
    input  wire [2:0]  packet_phase,
    input  wire        training_done_rb,
    input  wire        w_pending_rb,
    input  wire        w_valid_rb,
    input  wire        w_missed_rb,
    input  wire        w_commit_late_rb,  // WGT_CTRL[4]: commit landed after replay start
    // IRQ status (sticky bits set by hardware events)
    input  wire [7:0]  irq_set,     // one-cycle pulse per IRQ source to set sticky bits
    // SC detection statistic [15:0]
    input  wire [15:0] sc_stat,
    // Training accumulator readback
    input  wire        training_armed,
    input  wire        noise_trig_rejected, // pulse: 0x1F trigger arrived while a window was armed
    input  wire [17:0] n_acc,
    // Z_kl pair readback — top 24 bits [31:8] of the int32 accumulators,
    // big-endian, 3 bytes per component (I then Q), 6 bytes per pair.
    // Pairs: 0=Z_01 1=Z_02 2=Z_03 3=Z_12 4=Z_13 5=Z_23 @ 0x40–0x63
    input  wire [31:0] zpair_i0, zpair_q0,   // Z_01  @ 0x40-0x45
    input  wire [31:0] zpair_i1, zpair_q1,   // Z_02  @ 0x46-0x4B
    input  wire [31:0] zpair_i2, zpair_q2,   // Z_03  @ 0x4C-0x51
    input  wire [31:0] zpair_i3, zpair_q3,   // Z_12  @ 0x52-0x57
    input  wire [31:0] zpair_i4, zpair_q4,   // Z_13  @ 0x58-0x5D
    input  wire [31:0] zpair_i5, zpair_q5,   // Z_23  @ 0x5E-0x63
    // Z_kk diagonal autocorrelation (Σ|raw_k|², real int32) @ 0x64-0x6F top 24-bit
    input  wire [31:0] zdiag_0, zdiag_1, zdiag_2, zdiag_3,
    // SC debug
    input  wire        sc_hit_dbg,
    input  wire [1:0]  sc_hit_count_dbg,
    input  wire        sc_lock_dbg,
    input  wire [31:0] sc_first_hit_dbg,
    input  wire [31:0] sc_lock_snap_dbg,
    // PSRAM status
    input  wire [7:0]  psram_status_rb,
    input  wire        psram_dbg_busy,
    input  wire [7:0]  psram_dbg_data,

    // -----------------------------------------------------------------------
    // Hardware control outputs (RW registers)
    // -----------------------------------------------------------------------
    // RX front-end
    output reg [1:0]   mimo_mode,       // MIMO_CTRL[1:0]
    output reg [3:0]   antenna_en,      // MIMO_CTRL[7:4]
    output reg [3:0]   sf_cfg,          // SF_CFG[3:0], direct-coded 7–12
    output reg         bw_sel,        // BW_CFG[0]: 0=250 kHz (sample_shift=1), 1=125 kHz (sample_shift=2)
    output reg [1:0]   sc_ant_sel,    // SC_ANT_SEL[1:0]: SC correlator source antenna (0-3)
    // ARRAY_SYNC_CTRL[0] (0x18): arm the multi-ASIC acquisition-sync link.
    // Resets to 0 -- the shared ARRAY_ACQ_N pin does nothing until firmware
    // opts in, so a single-chip board cannot be started by noise on an unused
    // pad. See planning/array-acquisition-sync.md.
    output reg         array_sync_en,
    // SC thresholds
    output reg [15:0]  sc_thr,
    output reg [1:0]   sc_hits_req,
    // Packet timeout
    output reg [7:0]   pkt_timeout_syms,
    // Weight path
    output reg         w_commit_pulse,  // W1P: WGT_CTRL[0]
    output reg [2:0]   comb_post_gain_shift,
    output reg [1:0]   remod_backoff_shift,
    // W shadow bank: 16 bytes 0x30–0x3F packed big-endian (byte[0] at [127:120])
    output wire [127:0] w_shadow,
    // PSRAM control
    output reg [3:0]   psram_ctrl,
    output reg [22:0]  psram_dbg_addr,
    output reg         psram_dbg_auto_inc,
    output reg         psram_dbg_rd_trig, // W1P: 0x75[0] — debug fetch
    output reg         psram_dbg_wr_trig, // W1P: 0x75[2] — debug write commit
                                          // (payload byte port 0x79 is fed to
                                          //  psram_buf_ctrl directly from the
                                          //  SPI slave, like the 0x76 read pop)
    // Manual SC lock override (bring-up / catastrophic-detector-failure escape hatch)
    // Digital debug probe (planning/two-pin-digital-debug-plan.md), split
    // selector: dbg_ctrl0 drives the dedicated DBG0 pad, dbg_ctrl1 the shared
    // IRQ_OUT/DBG1 pad (which carries the sticky interrupt unless dbg_ctrl1
    // EN=1).  Both feed the probe mux in trouper_top.  dbg_pad_value is the
    // post-mux, post-enable value read back at DBG_STATUS as a connectivity
    // check.  irq_status_dbg exports the sticky IRQ vector so the mux can
    // probe an individual source -- observability only, no functional use.
    output reg  [7:0]  dbg_ctrl0,       // 0x04: [7] EN, [6:4] GROUP, [3:2] ANT, [1:0] SEL
    output reg  [7:0]  dbg_ctrl1,       // 0x06: same layout, shared IRQ/DBG1 pad
    input  wire [1:0]  dbg_pad_value,   // 0x05: [0] DBG0 pad, [1] IRQ_OUT/DBG1 pad
    output wire [7:0]  irq_status_dbg,
    // BRINGUP_SRC deterministic first-silicon sample source (Open Risks #59).
    // Feeds a mux at the re-modulator input in trouper_top; lets mrc_combiner /
    // sd_remod be exercised without a working frontend/SC/PSRAM chain.
    // Relocated from 0x06/0x07 to 0x10/0x11 on the main rebase (0x06 is now
    // DBG_CTRL1, 0x07 stays reserved).
    output reg  [7:0]         bringup_ctrl,   // 0x10: [0] EN, [2:1] MODE
    output reg  signed [7:0]  bringup_ampl,   // 0x11: signed sample amplitude
    output reg         sc_force_lock,  // 0x19[0]: W1P — blocked while packet_active
    // 0x1A[0]: level.  1 = SC detector held disabled (ORed into sc_clr at the
    // top level) AND the quasi-static config registers are writable.  0 = the
    // detector can lock and those writes are rejected.  The two are mutually
    // exclusive by construction, which is what makes the scoped-MCP settling
    // exceptions sound — see planning/mcp-config-settle-gate-design.md.
    output reg         rx_hold,
    // Training accumulator
    output reg         noise_trig,     // 0x1F[0]: W1P — firmware-triggered noise measurement
    output reg [3:0]   tacc_window_syms, // 0x27[3:0]: accumulation endpoint in symbols from timing_ref
    // Same-packet replay margin: samples to wait after training_done before the
    // PSRAM delay-line replay starts (bounds host response only; SF-independent)
    output reg [15:0]  replay_delay_samples, // 0x77 LO / 0x78 HI
    // Aggregated sticky interrupt output (mirrors IRQ_STATUS OR)
    output wire        irq_out
);

    reg read_valid;
    assign ready = !re || read_valid;

    // -----------------------------------------------------------------------
    // Internal storage for the W shadow bank
    // (Verilog-2001 / Yosys do not support unpacked array ports; exposed below
    //  as a flat packed bus, big-endian: byte[0] at MSB)
    // -----------------------------------------------------------------------
    reg [7:0] w_shadow_r  [0:15];
    // Sticky: a 0x30-0x3F write was dropped by the W_valid write-lock
    // (WGT_CTRL[5] readback, W1C via WGT_CTRL write with bit[5] set)
    reg w_wr_rejected;
    // RX_HOLD (0x1A[0]) and its rejected-write flag (0x1A[1]).  See
    // planning/mcp-config-settle-gate-design.md: holding the detector disabled
    // is what makes "config writable" and "detector able to lock" mutually
    // exclusive, which is what the scoped-MCP settling exceptions actually
    // need (Open Risks #43).
    reg cfg_wr_rejected;
    // Sticky rejection for a noise trigger issued while training_acc is
    // already busy.  Without this, top-level qualification could treat the
    // normal training_done as completion of a noise window that never armed.
    reg noise_trig_rejected_sticky;

    assign w_shadow[127:120] = w_shadow_r[0];  assign w_shadow[119:112] = w_shadow_r[1];
    assign w_shadow[111:104] = w_shadow_r[2];  assign w_shadow[103:96]  = w_shadow_r[3];
    assign w_shadow[95:88]   = w_shadow_r[4];  assign w_shadow[87:80]   = w_shadow_r[5];
    assign w_shadow[79:72]   = w_shadow_r[6];  assign w_shadow[71:64]   = w_shadow_r[7];
    assign w_shadow[63:56]   = w_shadow_r[8];  assign w_shadow[55:48]   = w_shadow_r[9];
    assign w_shadow[47:40]   = w_shadow_r[10]; assign w_shadow[39:32]   = w_shadow_r[11];
    assign w_shadow[31:24]   = w_shadow_r[12]; assign w_shadow[23:16]   = w_shadow_r[13];
    assign w_shadow[15:8]    = w_shadow_r[14]; assign w_shadow[7:0]     = w_shadow_r[15];

    reg [7:0] rdata_next;
    assign peek_rdata = rdata_next;

    // -----------------------------------------------------------------------
    // IRQ status register (sticky, cleared by write to 0x03)
    // -----------------------------------------------------------------------
    reg [7:0] irq_status;
    assign irq_out = |irq_status;
    assign irq_status_dbg = irq_status;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irq_status <= 8'h00;
        else if (clk_en) begin
            // Set bits from hardware (irq_set pulses are 2-cycle-stretched so
            // this every-other-cycle sample never misses them)
            irq_status <= (irq_status | irq_set);
            // Clear bits when host writes 1 to 0x03 (IRQ_CLEAR)
            if (we && addr == 8'h03)
                irq_status <= (irq_status | irq_set) & ~wdata;
        end
    end

    // -----------------------------------------------------------------------
    // Write logic
    // -----------------------------------------------------------------------
    integer i;

    // The six quasi-static config registers whose MCP exceptions depend on
    // the rx_hold interlock.  SC_THR (0x0C/0x0D) is deliberately absent: it
    // appears in no MCP group and times honestly single-cycle.
    wire cfg_locked_addr = (addr == 8'h09) || (addr == 8'h0A) || (addr == 8'h18) ||
                           (addr == 8'h0B) || (addr == 8'h0E) ||
                           (addr == 8'h1B) || (addr == 8'h27) ||
                           // BRINGUP_CTRL/BRINGUP_AMPL (0x10/0x11): the test
                           // source may only be armed or retuned while the
                           // receiver is held.  It drives the re-modulator
                           // input mux, so a mid-burst change would flip the
                           // source under sd_remod's input.  Rejection lands in
                           // CFG_WR_REJECTED.
                           (addr == 8'h10) || (addr == 8'h11);

    // BOTH conditions are required, and rx_hold does NOT imply !packet_active:
    // firmware may assert RX_HOLD mid-packet, which holds sc_clr and clears the
    // detector but leaves packet_ctrl_fsm's packet_active high until its own
    // timeout.  Dropping the packet_active term would re-open the mid-packet
    // config-change hole closed by Open Risks #31/#32 (sc_detector/training_acc
    // consume sf/sample_shift live during a packet).  Caught by
    // test_packet_active_gate_smoke.
    wire cfg_wr_ok = rx_hold && !packet_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mimo_mode        <= 2'h0;
            antenna_en       <= 4'hF;
            sf_cfg           <= 4'h7;
            bw_sel           <= 1'b0;
            sc_ant_sel       <= 2'd0;
            array_sync_en    <= 1'b0;
            sc_thr           <= 16'h01CC;   // 0x7333 ÷ 64; sc_thr[11:0] used (12-bit positive)
            sc_hits_req      <= 2'h2;
            pkt_timeout_syms <= 8'h50;
            w_commit_pulse   <= 1'b0;
            comb_post_gain_shift <= 3'd0;
            remod_backoff_shift <= 2'd1;
            psram_ctrl       <= 4'h0;
            psram_dbg_addr   <= 23'h0;
            psram_dbg_auto_inc <= 1'b0;
            psram_dbg_rd_trig <= 1'b0;
            psram_dbg_wr_trig <= 1'b0;
            sc_force_lock    <= 1'b0;
            dbg_ctrl0        <= 8'h00;
            dbg_ctrl1        <= 8'h00;
            // Reset selects the normal path: EN=0 means the re-modulator sees
            // the combiner output, exactly as if the source did not exist.
            bringup_ctrl     <= 8'h00;
            bringup_ampl     <= 8'h00;
            noise_trig       <= 1'b0;
            tacc_window_syms <= 4'd8;
            replay_delay_samples <= 16'd1500; // ≈3 ms: measured Grouper rv32emc
                                              // 8-it compute (~1140) + readout/IRQ
            for (i = 0; i < 16; i = i + 1) w_shadow_r[i] <= 8'h00;
            w_wr_rejected    <= 1'b0;
            // Held out of reset: the receiver comes up disabled and firmware
            // must configure, then release.  Chosen so a driver that ignores
            // the sequence fails loudly (never locks) instead of silently
            // losing config writes.
            rx_hold          <= 1'b1;
            cfg_wr_rejected  <= 1'b0;
            noise_trig_rejected_sticky <= 1'b0;
        end else if (clk_en) begin
            // Auto-clear write-1-pulse outputs (held one CE period = 2 clocks,
            // safely caught by 32 MHz consumers; we is 2 cycles wide so each
            // write/W1P fires exactly once per CE edge)
            w_commit_pulse  <= 1'b0;
            psram_ctrl[1]   <= 1'b0;
            psram_dbg_rd_trig <= 1'b0;
            psram_dbg_wr_trig <= 1'b0;
            sc_force_lock   <= 1'b0;
            noise_trig      <= 1'b0;

            // W-shadow write-lock flag: the combiner reads w_shadow live (no
            // per-burst latch), so 0x30-0x3F writes are dropped while W_valid
            // is high; latch the rejection so firmware can see it.
            if (we && (addr[7:4] == 4'h3) && w_valid_rb)
                w_wr_rejected <= 1'b1;
            else if (we && addr == 8'h1E && wdata[5])
                w_wr_rejected <= 1'b0;

            // Quasi-static config write-lock (Open Risks #43).  These five
            // registers feed the scoped-MCP cones captured at the sc_lock /
            // ST_ACQ_SETUP edges; the exceptions are only sound if the source
            // cannot change near that capture.  Accepting the write ONLY while
            // rx_hold (detector cannot lock) guarantees that structurally.
            // Rejection is latched so firmware can detect an out-of-sequence
            // driver -- a dropped write is otherwise invisible (cf. Open Risks
            // #16 and the W_MISSED_PACKET readback bug).
            if ((we && !cfg_wr_ok && cfg_locked_addr) ||
                (we && (addr == 8'h04) && packet_active) ||
                (we && (addr == 8'h06) && packet_active) ||
                (we && (addr == 8'h19) && packet_active))
                cfg_wr_rejected <= 1'b1;
            else if (we && addr == 8'h1A && wdata[1])
                cfg_wr_rejected <= 1'b0;

            if (noise_trig_rejected)
                noise_trig_rejected_sticky <= 1'b1;
            else if (we && addr == 8'h1F && wdata[1])
                noise_trig_rejected_sticky <= 1'b0;

            if (we) begin
                case (addr)
                    // --- RX / modem configuration ---
                    8'h08: begin
                               mimo_mode[0] <= wdata[0];
                               antenna_en   <= wdata[7:4];
                           end
                    // 0x09/0x0A/0x0B/0x0E/0x1B/0x27 are gated on cfg_wr_ok =
                    // rx_hold && !packet_active.  0x09/0x0A previously carried
                    // the packet_active half only; 0x0B/0x0E/0x27 had no gate
                    // at all.  See cfg_wr_ok above and Open Risks #43.
                    8'h09: if (cfg_wr_ok) sf_cfg <= wdata[3:0];
                    // ARRAY_SYNC_CTRL. Gated with the other quasi-static
                    // config: arming or disarming the array link mid-packet
                    // would change whether a peer event can restart this
                    // receiver while it is already running one.
                    8'h18: if (cfg_wr_ok) array_sync_en <= wdata[0];
                    8'h0A: if (cfg_wr_ok) bw_sel <= wdata[0];
                    8'h0B: if (cfg_wr_ok) pkt_timeout_syms <= wdata;
                    8'h0C: sc_thr[15:8]     <= wdata;
                    8'h0D: sc_thr[7:0]      <= wdata;
                    8'h0E: if (cfg_wr_ok) sc_hits_req <= wdata[1:0];
                    8'h0F: begin
                               comb_post_gain_shift <= wdata[2:0];
                               remod_backoff_shift  <= wdata[5:4];
                           end
                    // DBG_CTRL.  Gated on !packet_active ONLY -- deliberately a
                    // weaker gate than cfg_wr_ok.  The requirement is that the
                    // probe selection is fixed for the whole of any one packet,
                    // not that the receiver be held: re-pointing a probe between
                    // packets without disabling the detector is the normal
                    // bring-up loop.  A rejected write still raises the shared
                    // CFG_WR_REJECTED sticky so a dropped write is visible.
                    8'h04: if (!packet_active) dbg_ctrl0 <= wdata;
                    // DBG_CTRL1 -- shared IRQ_OUT/DBG1 pad selector.  Same weak
                    // !packet_active gate as DBG_CTRL0: fixed selection per
                    // packet, no receiver hold.  When EN=0 the pad reverts to
                    // the sticky interrupt at the top level.
                    8'h06: if (!packet_active) dbg_ctrl1 <= wdata;
                    // BRINGUP_SRC control (Open Risks #59).  Same cfg_wr_ok gate
                    // (rx_hold && !packet_active) as the quasi-static config: the
                    // source feeds the re-modulator input mux, so it may only be
                    // armed, re-moded or retuned while the receiver is held.
                    8'h10: if (cfg_wr_ok) bringup_ctrl <= {5'h0, wdata[2:0]};
                    8'h11: if (cfg_wr_ok) bringup_ampl <= wdata;
                    // SC_FORCE_LOCK.  Same weak !packet_active gate as DBG_CTRL,
                    // and likewise reported: a write rejected mid-packet raises
                    // CFG_WR_REJECTED.  Without that it was silently dropped --
                    // the firmware-invisible-drop class of Open Risks #16 and
                    // the W_MISSED_PACKET readback bug.
                    8'h19: if (!packet_active) sc_force_lock <= wdata[0];
                    // RX_HOLD is intentionally NOT self-gated: firmware must
                    // always be able to re-assert the hold to reconfigure.
                    // Bit [1] is the W1C for cfg_wr_rejected, handled above.
                    8'h1A: rx_hold <= wdata[0];
                    // SC_ANT_SEL lives with the SC group, not in BW_CFG: it is
                    // correlator branch routing, not a bandwidth/decimation
                    // setting.  Same cfg_wr_ok gate it carried as BW_CFG[2:1] —
                    // psram_buf_ctrl's delay-line addressing must not change
                    // mid-packet.
                    8'h1B: if (cfg_wr_ok) sc_ant_sel <= wdata[1:0];
                    // --- Packet / weight / training control ---
                    8'h1E: w_commit_pulse   <= wdata[0];
                    8'h1F: noise_trig       <= wdata[0]; // bit[1] W1C handled above
                    8'h27: if (cfg_wr_ok)
                               tacc_window_syms <= (wdata[3:0] < 4'd8) ? 4'd8 : wdata[3:0];
                    // --- W shadow bank 0x30–0x3F: indexed write below (outside
                    //     the case) so the W_valid lock is one shared enable term ---
                    // --- PSRAM / debug window ---
                    8'h70: begin
                               if (!packet_active) psram_ctrl[0] <= wdata[0]; // PSRAM_EN: blocked during active packet
                               psram_ctrl[1] <= wdata[1];
                               // Bit [2] is reserved: ignore writes and retain
                               // its reset value of zero.
                               psram_ctrl[3] <= wdata[3];
                           end
                    8'h72: psram_dbg_addr[7:0]   <= wdata;
                    8'h73: psram_dbg_addr[15:8]  <= wdata;
                    8'h74: psram_dbg_addr[22:16] <= wdata[6:0];
                    8'h75: begin
                               psram_dbg_rd_trig  <= wdata[0];
                               psram_dbg_auto_inc <= wdata[1];
                               psram_dbg_wr_trig  <= wdata[2];
                           end
                    8'h77: if (!packet_active) replay_delay_samples[7:0]  <= wdata; // blocked during active packet
                    8'h78: if (!packet_active) replay_delay_samples[15:8] <= wdata; // blocked during active packet
                    default: ;
                endcase
                if (addr[7:4] == 4'h3 && !w_valid_rb)
                    w_shadow_r[addr[3:0]] <= wdata;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Read logic: combinatorial decode captured into rdata with one wait state.
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata <= 8'h00;
            read_valid <= 1'b0;
        end else if (clk_en) begin
            if (re && !read_valid) begin
                rdata <= rdata_next;
                read_valid <= 1'b1;
            end else begin
                read_valid <= 1'b0;
            end
        end
    end

    always @(*) begin
        rdata_next = 8'h00;
        case (raddr)
            // --- Global / IRQ / pad-mux debug ---
            8'h00: rdata_next = 8'hA7;                              // CHIP_ID
            8'h01: rdata_next = 8'h01;                              // CHIP_REV
            8'h02: rdata_next = irq_status;
            8'h03: rdata_next = 8'h00;                              // IRQ_CLEAR (WO)
            // --- RX / modem configuration ---
            8'h08: rdata_next = {antenna_en, 2'h0, mimo_mode};
            8'h09: rdata_next = {4'h0, sf_cfg};
            8'h0A: rdata_next = {7'h0, bw_sel};
            8'h04: rdata_next = dbg_ctrl0;                          // DBG_CTRL0
            8'h05: rdata_next = {6'h0, dbg_pad_value};              // DBG_STATUS (RO)
            8'h06: rdata_next = dbg_ctrl1;                          // DBG_CTRL1
            8'h10: rdata_next = bringup_ctrl;                       // BRINGUP_CTRL
            8'h11: rdata_next = bringup_ampl;                       // BRINGUP_AMPL
            8'h18: rdata_next = {7'h0, array_sync_en};              // ARRAY_SYNC_CTRL
            8'h0B: rdata_next = pkt_timeout_syms;
            8'h0C: rdata_next = sc_thr[15:8];
            8'h0D: rdata_next = sc_thr[7:0];
            8'h0E: rdata_next = {6'h0, sc_hits_req};
            8'h0F: rdata_next = {2'h0, remod_backoff_shift, 1'b0, comb_post_gain_shift};
            8'h19: rdata_next = 8'h00;                              // SC_FORCE_LOCK (WO)
            8'h1A: rdata_next = {6'h0, cfg_wr_rejected, rx_hold};   // RX_HOLD / CFG_WR_REJECTED
            8'h1B: rdata_next = {6'h0, sc_ant_sel};                 // SC_ANT_SEL
            // --- Packet / weight / training control ---
            8'h1C: rdata_next = {w_missed_rb, w_valid_rb, w_pending_rb,
                            training_done_rb, packet_phase, packet_active};
            8'h1D: rdata_next = {active_antenna_en_rb, 2'h0, active_mode_rb};
            8'h1E: rdata_next = {2'h0, w_wr_rejected, w_commit_late_rb, w_missed_rb, w_pending_rb, w_valid_rb, 1'b0};
            8'h1F: rdata_next = {6'h0, noise_trig_rejected_sticky, 1'b0};
            8'h20: rdata_next = {6'h0, training_armed, training_done_rb};
            8'h21: rdata_next = {6'h0, n_acc[17:16]};  // N_ACC[17:16] (big-endian byte 0)
            8'h22: rdata_next = n_acc[15:8];             // N_ACC[15:8]  (big-endian byte 1)
            8'h23: rdata_next = n_acc[7:0];              // N_ACC[7:0]   (big-endian byte 2)
            // --- SC status / bring-up debug ---
            8'h24: rdata_next = sc_stat[15:8];
            8'h25: rdata_next = sc_stat[7:0];
            8'h26: rdata_next = {4'h0, sc_lock_dbg, sc_hit_count_dbg, sc_hit_dbg};
            8'h27: rdata_next = {4'h0, tacc_window_syms};
            8'h28: rdata_next = sc_first_hit_dbg[31:24];
            8'h29: rdata_next = sc_first_hit_dbg[23:16];
            8'h2A: rdata_next = sc_first_hit_dbg[15:8];
            8'h2B: rdata_next = sc_first_hit_dbg[7:0];
            8'h2C: rdata_next = sc_lock_snap_dbg[31:24];
            8'h2D: rdata_next = sc_lock_snap_dbg[23:16];
            8'h2E: rdata_next = sc_lock_snap_dbg[15:8];
            8'h2F: rdata_next = sc_lock_snap_dbg[7:0];
            // --- W shadow bank (RW) ---
            8'h30: rdata_next = w_shadow_r[0];
            8'h31: rdata_next = w_shadow_r[1];
            8'h32: rdata_next = w_shadow_r[2];
            8'h33: rdata_next = w_shadow_r[3];
            8'h34: rdata_next = w_shadow_r[4];
            8'h35: rdata_next = w_shadow_r[5];
            8'h36: rdata_next = w_shadow_r[6];
            8'h37: rdata_next = w_shadow_r[7];
            8'h38: rdata_next = w_shadow_r[8];
            8'h39: rdata_next = w_shadow_r[9];
            8'h3A: rdata_next = w_shadow_r[10];
            8'h3B: rdata_next = w_shadow_r[11];
            8'h3C: rdata_next = w_shadow_r[12];
            8'h3D: rdata_next = w_shadow_r[13];
            8'h3E: rdata_next = w_shadow_r[14];
            8'h3F: rdata_next = w_shadow_r[15];
            // --- Z_kl pair readback: top 24 bits [31:8], big-endian ---
            // Z_01 @ 0x40
            8'h40: rdata_next = zpair_i0[31:24];
            8'h41: rdata_next = zpair_i0[23:16];
            8'h42: rdata_next = zpair_i0[15:8];
            8'h43: rdata_next = zpair_q0[31:24];
            8'h44: rdata_next = zpair_q0[23:16];
            8'h45: rdata_next = zpair_q0[15:8];
            // Z_02 @ 0x46
            8'h46: rdata_next = zpair_i1[31:24];
            8'h47: rdata_next = zpair_i1[23:16];
            8'h48: rdata_next = zpair_i1[15:8];
            8'h49: rdata_next = zpair_q1[31:24];
            8'h4A: rdata_next = zpair_q1[23:16];
            8'h4B: rdata_next = zpair_q1[15:8];
            // Z_03 @ 0x4C
            8'h4C: rdata_next = zpair_i2[31:24];
            8'h4D: rdata_next = zpair_i2[23:16];
            8'h4E: rdata_next = zpair_i2[15:8];
            8'h4F: rdata_next = zpair_q2[31:24];
            8'h50: rdata_next = zpair_q2[23:16];
            8'h51: rdata_next = zpair_q2[15:8];
            // Z_12 @ 0x52
            8'h52: rdata_next = zpair_i3[31:24];
            8'h53: rdata_next = zpair_i3[23:16];
            8'h54: rdata_next = zpair_i3[15:8];
            8'h55: rdata_next = zpair_q3[31:24];
            8'h56: rdata_next = zpair_q3[23:16];
            8'h57: rdata_next = zpair_q3[15:8];
            // Z_13 @ 0x58
            8'h58: rdata_next = zpair_i4[31:24];
            8'h59: rdata_next = zpair_i4[23:16];
            8'h5A: rdata_next = zpair_i4[15:8];
            8'h5B: rdata_next = zpair_q4[31:24];
            8'h5C: rdata_next = zpair_q4[23:16];
            8'h5D: rdata_next = zpair_q4[15:8];
            // Z_23 @ 0x5E
            8'h5E: rdata_next = zpair_i5[31:24];
            8'h5F: rdata_next = zpair_i5[23:16];
            8'h60: rdata_next = zpair_i5[15:8];
            8'h61: rdata_next = zpair_q5[31:24];
            8'h62: rdata_next = zpair_q5[23:16];
            8'h63: rdata_next = zpair_q5[15:8];
            // --- Z_kk diagonal autocorrelation: top 24 bits per branch ---
            // In noise mode (no signal) Zdiag_k ≈ σ²_k · n_acc — firmware noise EMA.
            // Same [31:8] scale as the Zpair off-diagonals above (no separate
            // scale-alignment shift needed when combining diag + off-diag).
            8'h64: rdata_next = zdiag_0[31:24];
            8'h65: rdata_next = zdiag_0[23:16];
            8'h66: rdata_next = zdiag_0[15:8];
            8'h67: rdata_next = zdiag_1[31:24];
            8'h68: rdata_next = zdiag_1[23:16];
            8'h69: rdata_next = zdiag_1[15:8];
            8'h6A: rdata_next = zdiag_2[31:24];
            8'h6B: rdata_next = zdiag_2[23:16];
            8'h6C: rdata_next = zdiag_2[15:8];
            8'h6D: rdata_next = zdiag_3[31:24];
            8'h6E: rdata_next = zdiag_3[23:16];
            8'h6F: rdata_next = zdiag_3[15:8];
            // --- PSRAM control / status / debug readback ---
            8'h70: rdata_next = {4'h0, psram_ctrl[3], 1'b0, psram_ctrl[1:0]};
            8'h71: rdata_next = psram_status_rb;
            8'h72: rdata_next = psram_dbg_addr[7:0];
            8'h73: rdata_next = psram_dbg_addr[15:8];
            8'h74: rdata_next = {1'b0, psram_dbg_addr[22:16]};
            8'h75: rdata_next = {psram_dbg_busy, 5'h0, psram_dbg_auto_inc, 1'b0};
            8'h76: rdata_next = psram_dbg_busy ? 8'h00 : psram_dbg_data;
            8'h77: rdata_next = replay_delay_samples[7:0];
            8'h78: rdata_next = replay_delay_samples[15:8];
            // 0x79–0x7E reserved; 0x7F permanently reserved (protocol escape)
            default: rdata_next = 8'h00;
        endcase
    end

endmodule
