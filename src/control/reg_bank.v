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
    // RX gain active values (applied to SX1257)
    input  wire [7:0]  rx_gain_active_0, rx_gain_active_1,
                       rx_gain_active_2, rx_gain_active_3,
    // Packet / weight control readback
    input  wire [1:0]  active_mode_rb,
    input  wire [3:0]  active_antenna_en_rb,
    input  wire        packet_active,
    input  wire [2:0]  packet_phase,
    input  wire        training_done_rb,
    input  wire        w_pending_rb,
    input  wire        w_valid_rb,
    input  wire        w_missed_rb,
    // IRQ status (sticky bits set by hardware events)
    input  wire [7:0]  irq_set,     // one-cycle pulse per IRQ source to set sticky bits
    // SC detection statistic [15:0]
    input  wire [15:0] sc_stat,
    // Training accumulator readback
    input  wire        training_armed,
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
    // SC thresholds
    output reg [15:0]  sc_thr,
    output reg [1:0]   sc_hits_req,
    // Packet timeout
    output reg [7:0]   pkt_timeout_syms,
    // Gain control
    output reg [7:0]   rx_gain_shadow_0, rx_gain_shadow_1,
                       rx_gain_shadow_2, rx_gain_shadow_3,
    output reg         rx_gain_commit,  // W1P
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
    output reg         psram_dbg_rd_trig, // W1P
    // Training accumulator
    output reg         noise_trig,     // 0x1F[0]: W1P — firmware-triggered noise measurement
    output reg [3:0]   tacc_window_syms, // 0x27[3:0]: accumulation endpoint in symbols from timing_ref
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mimo_mode        <= 2'h0;
            antenna_en       <= 4'hF;
            sf_cfg           <= 4'h7;
            bw_sel           <= 1'b0;
            sc_thr           <= 16'h01CC;   // 0x7333 ÷ 64; sc_thr[11:0] used (12-bit positive)
            sc_hits_req      <= 2'h2;
            pkt_timeout_syms <= 8'h50;
            rx_gain_shadow_0 <= 8'h3E;
            rx_gain_shadow_1 <= 8'h3E;
            rx_gain_shadow_2 <= 8'h3E;
            rx_gain_shadow_3 <= 8'h3E;
            rx_gain_commit   <= 1'b0;
            w_commit_pulse   <= 1'b0;
            comb_post_gain_shift <= 3'd0;
            remod_backoff_shift <= 2'd1;
            psram_ctrl       <= 4'h0;
            psram_dbg_addr   <= 23'h0;
            psram_dbg_auto_inc <= 1'b0;
            psram_dbg_rd_trig <= 1'b0;
            noise_trig       <= 1'b0;
            tacc_window_syms <= 4'd8;
            for (i = 0; i < 16; i = i + 1) w_shadow_r[i] <= 8'h00;
        end else if (clk_en) begin
            // Auto-clear write-1-pulse outputs (held one CE period = 2 clocks,
            // safely caught by 32 MHz consumers; we is 2 cycles wide so each
            // write/W1P fires exactly once per CE edge)
            rx_gain_commit  <= 1'b0;
            w_commit_pulse  <= 1'b0;
            psram_ctrl[1]   <= 1'b0;
            psram_dbg_rd_trig <= 1'b0;
            noise_trig      <= 1'b0;

            if (we) begin
                case (addr)
                    // --- RX / modem configuration ---
                    8'h08: begin
                               mimo_mode[0] <= wdata[0];
                               antenna_en   <= wdata[7:4];
                           end
                    8'h09: if (!packet_active) sf_cfg <= wdata[3:0]; // blocked during active packet
                    8'h0A: if (!packet_active) bw_sel <= wdata[0]; // blocked during active packet
                    8'h0B: pkt_timeout_syms <= wdata;
                    8'h0C: sc_thr[15:8]     <= wdata;
                    8'h0D: sc_thr[7:0]      <= wdata;
                    8'h0E: sc_hits_req      <= wdata[1:0];
                    8'h0F: begin
                               comb_post_gain_shift <= wdata[2:0];
                               remod_backoff_shift  <= wdata[5:4];
                           end
                    // --- Gain ---
                    8'h10: rx_gain_shadow_0 <= wdata;
                    8'h11: rx_gain_shadow_1 <= wdata;
                    8'h12: rx_gain_shadow_2 <= wdata;
                    8'h13: rx_gain_shadow_3 <= wdata;
                    8'h18: rx_gain_commit   <= wdata[0];
                    // --- Packet / weight / training control ---
                    8'h1E: w_commit_pulse   <= wdata[0];
                    8'h1F: noise_trig       <= wdata[0];
                    8'h27: tacc_window_syms <= (wdata[3:0] < 4'd8) ? 4'd8 : wdata[3:0];
                    // --- W shadow bank 0x30–0x3F ---
                    8'h30: w_shadow_r[0]  <= wdata;
                    8'h31: w_shadow_r[1]  <= wdata;
                    8'h32: w_shadow_r[2]  <= wdata;
                    8'h33: w_shadow_r[3]  <= wdata;
                    8'h34: w_shadow_r[4]  <= wdata;
                    8'h35: w_shadow_r[5]  <= wdata;
                    8'h36: w_shadow_r[6]  <= wdata;
                    8'h37: w_shadow_r[7]  <= wdata;
                    8'h38: w_shadow_r[8]  <= wdata;
                    8'h39: w_shadow_r[9]  <= wdata;
                    8'h3A: w_shadow_r[10] <= wdata;
                    8'h3B: w_shadow_r[11] <= wdata;
                    8'h3C: w_shadow_r[12] <= wdata;
                    8'h3D: w_shadow_r[13] <= wdata;
                    8'h3E: w_shadow_r[14] <= wdata;
                    8'h3F: w_shadow_r[15] <= wdata;
                    // --- PSRAM / debug window ---
                    8'h70: begin
                               if (!packet_active) psram_ctrl[0] <= wdata[0]; // PSRAM_EN: blocked during active packet
                               psram_ctrl[1] <= wdata[1];
                               psram_ctrl[2] <= wdata[2];
                               psram_ctrl[3] <= wdata[3];
                           end
                    8'h72: psram_dbg_addr[7:0]   <= wdata;
                    8'h73: psram_dbg_addr[15:8]  <= wdata;
                    8'h74: psram_dbg_addr[22:16] <= wdata[6:0];
                    8'h75: begin
                               psram_dbg_rd_trig  <= wdata[0];
                               psram_dbg_auto_inc <= wdata[1];
                           end
                    default: ;
                endcase
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
            8'h0B: rdata_next = pkt_timeout_syms;
            8'h0C: rdata_next = sc_thr[15:8];
            8'h0D: rdata_next = sc_thr[7:0];
            8'h0E: rdata_next = {6'h0, sc_hits_req};
            8'h0F: rdata_next = {2'h0, remod_backoff_shift, 1'b0, comb_post_gain_shift};
            // --- Gain ---
            8'h10: rdata_next = rx_gain_shadow_0;
            8'h11: rdata_next = rx_gain_shadow_1;
            8'h12: rdata_next = rx_gain_shadow_2;
            8'h13: rdata_next = rx_gain_shadow_3;
            8'h14: rdata_next = rx_gain_active_0;
            8'h15: rdata_next = rx_gain_active_1;
            8'h16: rdata_next = rx_gain_active_2;
            8'h17: rdata_next = rx_gain_active_3;
            // W1P commit bit reads back 0 (same as WGT_CTRL[0]): the pulse
            // lasts one CE period and the shadow→active latch completes within
            // one clock — there is no observable "pending" state over SPI.
            8'h18: rdata_next = 8'h00;
            // --- Packet / weight / training control ---
            8'h1C: rdata_next = {w_missed_rb, w_valid_rb, w_pending_rb,
                            training_done_rb, packet_phase, packet_active};
            8'h1D: rdata_next = {active_antenna_en_rb, 2'h0, active_mode_rb};
            8'h1E: rdata_next = {4'h0, w_missed_rb, w_pending_rb, w_valid_rb, 1'b0};
            8'h1F: rdata_next = 8'h00;                              // TACC_NOISE_TRIG (WO)
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
            8'h70: rdata_next = {4'h0, psram_ctrl};
            8'h71: rdata_next = psram_status_rb;
            8'h72: rdata_next = psram_dbg_addr[7:0];
            8'h73: rdata_next = psram_dbg_addr[15:8];
            8'h74: rdata_next = {1'b0, psram_dbg_addr[22:16]};
            8'h75: rdata_next = {psram_dbg_busy, 5'h0, psram_dbg_auto_inc, 1'b0};
            8'h76: rdata_next = psram_dbg_busy ? 8'h00 : psram_dbg_data;
            // 0x77–0x7E reserved; 0x7F permanently reserved (protocol escape)
            default: rdata_next = 8'h00;
        endcase
    end

endmodule
