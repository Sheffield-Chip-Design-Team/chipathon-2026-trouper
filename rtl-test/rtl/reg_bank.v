// reg_bank.v
// ASIC configuration and status register bank.
// Address space: 0x00–0xFF, 8-bit registers. Big-endian multi-byte fields.
// Accessed via AHB-Lite slave port (byte addr/data).
// GF180MCU, 3.3V, 32 MHz single clock domain

module reg_bank (
    input  wire        clk,
    input  wire        rst_n,

    // AHB-Lite slave byte interface (from ahb_lite_bus)
    input  wire [7:0]  addr,
    input  wire [7:0]  wdata,
    input  wire        we,
    input  wire        re,
    output reg  [7:0]  rdata,
    output wire        ready,       // reads insert one wait state

    // -----------------------------------------------------------------------
    // Hardware status inputs (RO registers)
    // -----------------------------------------------------------------------
    // GPIO sampled inputs
    input  wire [2:0]  gpio_in,
    // CPU SRAM status
    input  wire [5:0]  cpu_sram_status,  // [5:0] = BANK0_PASS..BORROW_ACTIVE
    // Frontend buffer status
    input  wire [1:0]  buf_mode,
    input  wire        buf_valid,
    input  wire        sram0_bist_pass,
    input  wire        sram1_bist_pass,
    input  wire        buf_freeze,
    input  wire [6:0]  buf_wr_ptr,
    // RX gain active values (applied to SX1257)
    input  wire [7:0]  rx_gain_active_0, rx_gain_active_1,
                       rx_gain_active_2, rx_gain_active_3,
    input  wire        rx_gain_pending,
    input  wire        rx_gain_owner,
    input  wire        rx_gain_error,
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
    // Energy snapshots [15:0] per branch
    input  wire [15:0] energy_0, energy_1, energy_2, energy_3,
    // SC correlation magnitude [15:0] per branch
    input  wire [15:0] corr_mag_0, corr_mag_1, corr_mag_2, corr_mag_3,
    // SC detection statistic [15:0]
    input  wire [15:0] sc_stat,
    // Training accumulator readback
    input  wire        training_armed,
    input  wire [9:0]  n_acc,
    input  wire [5:0]  z_shift,
    // C_pool diagnostic [15:0] I and Q
    input  wire [15:0] c_pool_i, c_pool_q,
    // CFO diagnostic [15:0]
    input  wire [15:0] cfo_diag,
    // Z_kl pair readback — individual cross-correlations (int32, big-endian bytes)
    // Pairs: 0=Z_01 1=Z_02 2=Z_03 3=Z_12 4=Z_13 5=Z_23
    input  wire [31:0] zpair_i0, zpair_q0,   // Z_01  @ 0x70-0x77
    input  wire [31:0] zpair_i1, zpair_q1,   // Z_02  @ 0x78-0x7F
    input  wire [31:0] zpair_i2, zpair_q2,   // Z_03  @ 0x80-0x87
    input  wire [31:0] zpair_i3, zpair_q3,   // Z_12  @ 0x88-0x8F
    input  wire [31:0] zpair_i4, zpair_q4,   // Z_13  @ 0xD4-0xDB
    // Z_kk diagonal autocorrelation (Σ|raw_k|², real int32) @ 0xE8-0xEF top 16-bit
    input  wire [31:0] zdiag_0, zdiag_1, zdiag_2, zdiag_3,
    // SC debug
    input  wire        sc_hit_dbg,
    input  wire [1:0]  sc_hit_count_dbg,
    input  wire        sc_lock_dbg,
    input  wire [31:0] sc_first_hit_dbg,
    input  wire [31:0] sc_lock_snap_dbg,
    // SRAM dump
    input  wire        sram_dump_done,
    input  wire [7:0]  sram_dump_data,
    // NFE status
    input  wire        sigma2_valid,
    // SIGMA2 hardware EMA estimates [15:0] per branch
    input  wire [15:0] sigma2_hw_0, sigma2_hw_1, sigma2_hw_2, sigma2_hw_3,
    // PSRAM status
    input  wire [7:0]  psram_status_rb,
    input  wire [15:0] psram_pkt_bytes,
    input  wire [7:0]  psram_rd_offset,
    // Firmware diagnostic registers (written by PicoRV32 via AHB)
    // (cond_num and snr_0 are R/W from firmware side — stored internally)

    // -----------------------------------------------------------------------
    // Hardware control outputs (RW registers)
    // -----------------------------------------------------------------------
    output reg         cpu_reset,
    output reg         jtag_en,
    output reg [2:0]   gpio_dir,
    output reg [2:0]   gpio_out,
    output reg [1:0]   cpu_sram_ctrl,
    output reg [2:0]   tx_ctrl,
    output reg [7:0]   low_bat_thr,
    // RX front-end
    output reg [1:0]   mimo_mode,       // MIMO_CTRL[0] (mode) + [1] reserved
    output reg [3:0]   antenna_en,      // MIMO_CTRL[7:4]
    output reg [3:0]   sf_cfg,          // SF_CFG[3:0]
    output reg [1:0]   decim_ratio,
    output reg         bist_run,        // W1P: self-clears after one cycle
    // SC thresholds
    output reg [15:0]  sc_thr,
    output reg [1:0]   sc_hits_req,
    output reg         energy_gate_en,
    output reg [15:0]  energy_thr,
    // Packet timeout
    output reg [7:0]   pkt_timeout_syms,
    // Gain control
    output reg [7:0]   rx_gain_shadow_0, rx_gain_shadow_1,
                       rx_gain_shadow_2, rx_gain_shadow_3,
    output reg [7:0]   tx_gain_0, tx_gain_1,
    output reg         rx_gain_commit,  // W1P
    // Weight generation
    output reg         wgt_src,
    output reg         wgt_auto_commit,
    output reg [1:0]   wgt_mode,
    output reg         w_commit_pulse,  // W1P: one-cycle pulse when bit [4] written 1
    output reg [2:0]   comb_post_gain_shift,
    output reg [1:0]   remod_backoff_shift,
    // W shadow bank: 16 bytes 0x90–0x9F packed big-endian (byte[0] at [127:120])
    output wire [127:0] w_shadow,
    // Calibration coefficients: 16 bytes 0xA0–0xAF packed big-endian
    output wire [127:0] cal_coeff,
    // PSRAM control
    output reg [2:0]   psram_ctrl,
    // SPI master passthrough
    output reg [1:0]   sx_target,
    output reg [6:0]   sx_addr,
    output reg [7:0]   sx_data_wr,
    output reg         sx_rnw,
    output reg         sx_start,       // W1P
    // SRAM dump control
    output reg         sram_dump_start, // W1P
    output reg [9:0]   sram_dump_addr,  // {macro_sel, addr[8:0]}
    // NFE control
    output reg         sigma2_src,
    output reg [2:0]   noise_alpha_shift,
    output reg [15:0]  noise_thresh,
    // SIGMA2 software overrides
    output reg         sigma2_commit,  // W1P
    // sigma2 SW overrides: 8 bytes 0xF1–0xF8 packed big-endian (byte[0] at [63:56])
    output wire [63:0]  sigma2_sw,
    // Null steering
    output reg         noise_en,       // 0x6A[0]: enable noise-window accumulation mode
    output reg [1:0]   ref_sel,        // 0x6B[1:0]: training reference branch (0-3)
    output reg         noise_trig      // 0x6C[0]: W1P — firmware-triggers noise measurement in training_acc
);

    reg read_valid;
    assign ready = !re || read_valid;

    // -----------------------------------------------------------------------
    // Internal storage for the three array-typed outputs
    // (Verilog-2001 / Yosys do not support unpacked array ports; exposed below
    //  as flat packed buses, big-endian: byte[0] at MSB)
    // -----------------------------------------------------------------------
    reg [7:0] w_shadow_r  [0:15];
    reg [7:0] cal_coeff_r [0:15];
    reg [7:0] sigma2_sw_r [0:7];

    assign w_shadow[127:120] = w_shadow_r[0];  assign w_shadow[119:112] = w_shadow_r[1];
    assign w_shadow[111:104] = w_shadow_r[2];  assign w_shadow[103:96]  = w_shadow_r[3];
    assign w_shadow[95:88]   = w_shadow_r[4];  assign w_shadow[87:80]   = w_shadow_r[5];
    assign w_shadow[79:72]   = w_shadow_r[6];  assign w_shadow[71:64]   = w_shadow_r[7];
    assign w_shadow[63:56]   = w_shadow_r[8];  assign w_shadow[55:48]   = w_shadow_r[9];
    assign w_shadow[47:40]   = w_shadow_r[10]; assign w_shadow[39:32]   = w_shadow_r[11];
    assign w_shadow[31:24]   = w_shadow_r[12]; assign w_shadow[23:16]   = w_shadow_r[13];
    assign w_shadow[15:8]    = w_shadow_r[14]; assign w_shadow[7:0]     = w_shadow_r[15];

    assign cal_coeff[127:120] = cal_coeff_r[0];  assign cal_coeff[119:112] = cal_coeff_r[1];
    assign cal_coeff[111:104] = cal_coeff_r[2];  assign cal_coeff[103:96]  = cal_coeff_r[3];
    assign cal_coeff[95:88]   = cal_coeff_r[4];  assign cal_coeff[87:80]   = cal_coeff_r[5];
    assign cal_coeff[79:72]   = cal_coeff_r[6];  assign cal_coeff[71:64]   = cal_coeff_r[7];
    assign cal_coeff[63:56]   = cal_coeff_r[8];  assign cal_coeff[55:48]   = cal_coeff_r[9];
    assign cal_coeff[47:40]   = cal_coeff_r[10]; assign cal_coeff[39:32]   = cal_coeff_r[11];
    assign cal_coeff[31:24]   = cal_coeff_r[12]; assign cal_coeff[23:16]   = cal_coeff_r[13];
    assign cal_coeff[15:8]    = cal_coeff_r[14]; assign cal_coeff[7:0]     = cal_coeff_r[15];

    assign sigma2_sw[63:56] = sigma2_sw_r[0]; assign sigma2_sw[55:48] = sigma2_sw_r[1];
    assign sigma2_sw[47:40] = sigma2_sw_r[2]; assign sigma2_sw[39:32] = sigma2_sw_r[3];
    assign sigma2_sw[31:24] = sigma2_sw_r[4]; assign sigma2_sw[23:16] = sigma2_sw_r[5];
    assign sigma2_sw[15:8]  = sigma2_sw_r[6]; assign sigma2_sw[7:0]   = sigma2_sw_r[7];

    // -----------------------------------------------------------------------
    // IRQ status register (sticky, cleared by write to 0x33)
    // -----------------------------------------------------------------------
    reg [7:0] irq_status;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irq_status <= 8'h00;
        else begin
            // Set bits from hardware
            irq_status <= (irq_status | irq_set);
            // Clear bits when host writes 1 to 0x33 (IRQ_CLEAR)
            if (we && addr == 8'h33)
                irq_status <= (irq_status | irq_set) & ~wdata;
        end
    end

    // -----------------------------------------------------------------------
    // Firmware diagnostic registers (RW, written by PicoRV32 via AHB)
    // -----------------------------------------------------------------------
    reg [15:0] cond_num_reg;
    reg [15:0] snr_0_reg;
    reg [15:0] null_quality_reg;

    // -----------------------------------------------------------------------
    // Write logic
    // -----------------------------------------------------------------------
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_reset        <= 1'b1;
            jtag_en          <= 1'b0;
            gpio_dir         <= 3'h0;
            gpio_out         <= 3'h0;
            cpu_sram_ctrl    <= 2'h0;
            tx_ctrl          <= 3'h0;
            low_bat_thr      <= 8'h02;
            mimo_mode        <= 2'h0;
            antenna_en       <= 4'hF;
            sf_cfg           <= 4'h7;
            decim_ratio      <= 2'h0;
            bist_run         <= 1'b0;
            sc_thr           <= 16'h7333;
            sc_hits_req      <= 2'h2;
            energy_gate_en   <= 1'b0;
            energy_thr       <= 16'h0000;
            pkt_timeout_syms <= 8'h50;
            rx_gain_shadow_0 <= 8'h3E;
            rx_gain_shadow_1 <= 8'h3E;
            rx_gain_shadow_2 <= 8'h3E;
            rx_gain_shadow_3 <= 8'h3E;
            tx_gain_0        <= 8'h08;
            tx_gain_1        <= 8'h08;
            rx_gain_commit   <= 1'b0;
            wgt_src          <= 1'b0;
            wgt_auto_commit  <= 1'b1;
            wgt_mode         <= 2'b11;
            w_commit_pulse   <= 1'b0;
            comb_post_gain_shift <= 3'd0;
            remod_backoff_shift <= 2'd1;
            psram_ctrl       <= 3'h0;
            sx_target        <= 2'h0;
            sx_addr          <= 7'h0;
            sx_data_wr       <= 8'h0;
            sx_rnw           <= 1'b0;
            sx_start         <= 1'b0;
            sram_dump_start  <= 1'b0;
            sram_dump_addr   <= 10'h0;
            sigma2_src       <= 1'b0;
            noise_alpha_shift <= 3'h2;
            noise_thresh     <= 16'h0;
            sigma2_commit    <= 1'b0;
            cond_num_reg     <= 16'h0;
            snr_0_reg        <= 16'h0;
            null_quality_reg <= 16'h0;
            noise_en         <= 1'b0;
            ref_sel          <= 2'd0;
            noise_trig       <= 1'b0;
            for (i = 0; i < 16; i = i + 1) w_shadow_r[i] <= 8'h00;
            // CAL default: I=0x7FFF (unity), Q=0x0000 per branch (4 bytes each)
            cal_coeff_r[0]  <= 8'h7F; cal_coeff_r[1]  <= 8'hFF; // CAL_0_I
            cal_coeff_r[2]  <= 8'h00; cal_coeff_r[3]  <= 8'h00; // CAL_0_Q
            cal_coeff_r[4]  <= 8'h7F; cal_coeff_r[5]  <= 8'hFF;
            cal_coeff_r[6]  <= 8'h00; cal_coeff_r[7]  <= 8'h00;
            cal_coeff_r[8]  <= 8'h7F; cal_coeff_r[9]  <= 8'hFF;
            cal_coeff_r[10] <= 8'h00; cal_coeff_r[11] <= 8'h00;
            cal_coeff_r[12] <= 8'h7F; cal_coeff_r[13] <= 8'hFF;
            cal_coeff_r[14] <= 8'h00; cal_coeff_r[15] <= 8'h00;
            for (i = 0; i < 8; i = i + 1) sigma2_sw_r[i] <= 8'h00;
        end else begin
            // Auto-clear write-1-pulse outputs
            bist_run        <= 1'b0;
            rx_gain_commit  <= 1'b0;
            w_commit_pulse  <= 1'b0;
            sx_start        <= 1'b0;
            sram_dump_start <= 1'b0;
            sigma2_commit   <= 1'b0;
            noise_trig      <= 1'b0;

            if (we) begin
                case (addr)
                    8'h02: cpu_reset        <= wdata[0];
                    8'h03: jtag_en          <= wdata[0];
                    8'h04: gpio_dir         <= wdata[2:0];
                    8'h05: gpio_out         <= wdata[2:0];
                    8'h07: cpu_sram_ctrl    <= wdata[1:0];
                    8'h09: tx_ctrl          <= wdata[2:0];
                    8'h0A: low_bat_thr      <= wdata;
                    8'h10: begin
                               mimo_mode   <= wdata[1:0];
                               antenna_en  <= wdata[7:4];
                           end
                    8'h11: sf_cfg           <= wdata[3:0];
                    8'h12: decim_ratio      <= wdata[1:0];
                    8'h13: bist_run         <= wdata[1];
                    8'h16: pkt_timeout_syms <= wdata;
                    8'h17: energy_thr[15:8] <= wdata;
                    8'h18: energy_thr[7:0]  <= wdata;
                    8'h19: sc_thr[15:8]     <= wdata;
                    8'h1A: sc_thr[7:0]      <= wdata;
                    8'h1B: sc_hits_req      <= wdata[1:0];
                    8'h1C: energy_gate_en   <= wdata[0];
                    8'h20: rx_gain_shadow_0 <= wdata;
                    8'h21: rx_gain_shadow_1 <= wdata;
                    8'h22: rx_gain_shadow_2 <= wdata;
                    8'h23: rx_gain_shadow_3 <= wdata;
                    8'h24: tx_gain_0        <= wdata;
                    8'h25: tx_gain_1        <= wdata;
                    8'h2A: rx_gain_commit   <= wdata[0];
                    8'h35: begin
                               wgt_src        <= wdata[0];
                               wgt_auto_commit <= wdata[1];
                               wgt_mode       <= wdata[3:2];
                               w_commit_pulse <= wdata[4];
                           end
                    8'h36: comb_post_gain_shift <= wdata[2:0];
                    8'h37: remod_backoff_shift <= wdata[1:0];
                    // W shadow bank 0x90–0x9F
                    8'h90: w_shadow_r[0]  <= wdata;
                    8'h91: w_shadow_r[1]  <= wdata;
                    8'h92: w_shadow_r[2]  <= wdata;
                    8'h93: w_shadow_r[3]  <= wdata;
                    8'h94: w_shadow_r[4]  <= wdata;
                    8'h95: w_shadow_r[5]  <= wdata;
                    8'h96: w_shadow_r[6]  <= wdata;
                    8'h97: w_shadow_r[7]  <= wdata;
                    8'h98: w_shadow_r[8]  <= wdata;
                    8'h99: w_shadow_r[9]  <= wdata;
                    8'h9A: w_shadow_r[10] <= wdata;
                    8'h9B: w_shadow_r[11] <= wdata;
                    8'h9C: w_shadow_r[12] <= wdata;
                    8'h9D: w_shadow_r[13] <= wdata;
                    8'h9E: w_shadow_r[14] <= wdata;
                    8'h9F: w_shadow_r[15] <= wdata;
                    // Calibration 0xA0–0xAF
                    8'hA0: cal_coeff_r[0]  <= wdata;
                    8'hA1: cal_coeff_r[1]  <= wdata;
                    8'hA2: cal_coeff_r[2]  <= wdata;
                    8'hA3: cal_coeff_r[3]  <= wdata;
                    8'hA4: cal_coeff_r[4]  <= wdata;
                    8'hA5: cal_coeff_r[5]  <= wdata;
                    8'hA6: cal_coeff_r[6]  <= wdata;
                    8'hA7: cal_coeff_r[7]  <= wdata;
                    8'hA8: cal_coeff_r[8]  <= wdata;
                    8'hA9: cal_coeff_r[9]  <= wdata;
                    8'hAA: cal_coeff_r[10] <= wdata;
                    8'hAB: cal_coeff_r[11] <= wdata;
                    8'hAC: cal_coeff_r[12] <= wdata;
                    8'hAD: cal_coeff_r[13] <= wdata;
                    8'hAE: cal_coeff_r[14] <= wdata;
                    8'hAF: cal_coeff_r[15] <= wdata;
                    // PSRAM / SPI passthrough
                    8'hB0: psram_ctrl <= wdata[2:0];
                    8'hB5: sx_target  <= wdata[1:0];
                    8'hB6: sx_addr    <= wdata[6:0];
                    8'hB7: sx_data_wr <= wdata;
                    8'hB8: begin sx_rnw <= wdata[0]; sx_start <= wdata[1]; end
                    // SRAM dump
                    8'hCA: sram_dump_start <= wdata[0];
                    8'hCB: sram_dump_addr[9:8] <= wdata[1:0];
                    8'hCC: sram_dump_addr[7:0]  <= wdata;
                    // NFE
                    8'hD0: begin sigma2_src <= wdata[0]; noise_alpha_shift <= wdata[3:1]; end
                    8'hD2: noise_thresh[15:8] <= wdata;
                    8'hD3: noise_thresh[7:0]  <= wdata;
                    // SIGMA2 SW override
                    8'hF0: sigma2_commit   <= wdata[0];
                    8'hF1: sigma2_sw_r[0]    <= wdata;
                    8'hF2: sigma2_sw_r[1]    <= wdata;
                    8'hF3: sigma2_sw_r[2]    <= wdata;
                    8'hF4: sigma2_sw_r[3]    <= wdata;
                    8'hF5: sigma2_sw_r[4]    <= wdata;
                    8'hF6: sigma2_sw_r[5]    <= wdata;
                    8'hF7: sigma2_sw_r[6]    <= wdata;
                    8'hF8: sigma2_sw_r[7]    <= wdata;
                    // Firmware diagnostics
                    8'h52: cond_num_reg[15:8] <= wdata;
                    8'h53: cond_num_reg[7:0]  <= wdata;
                    8'h54: snr_0_reg[15:8]       <= wdata;
                    8'h55: snr_0_reg[7:0]        <= wdata;
                    8'h56: null_quality_reg[15:8] <= wdata;
                    8'h57: null_quality_reg[7:0]  <= wdata;
                    8'h6A: noise_en               <= wdata[0];
                    8'h6B: ref_sel                <= wdata[1:0];
                    8'h6C: noise_trig             <= wdata[0];  // W1P: firmware noise-mode trigger
                    default: ;
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Read logic: combinatorial decode captured into rdata with one wait state.
    // -----------------------------------------------------------------------
    reg [7:0] rdata_next;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rdata <= 8'h00;
            read_valid <= 1'b0;
        end else if (re && !read_valid) begin
            rdata <= rdata_next;
            read_valid <= 1'b1;
        end else begin
            read_valid <= 1'b0;
        end
    end

    always @(*) begin
        rdata_next = 8'h00;
        case (addr)
            // --- Global / CPU / Debug ---
            8'h00: rdata_next = 8'hA7;                              // CHIP_ID
            8'h01: rdata_next = 8'h01;                              // CHIP_REV
            8'h02: rdata_next = {7'h0, cpu_reset};
            8'h03: rdata_next = {7'h0, jtag_en};
            8'h04: rdata_next = {5'h0, gpio_dir};
            8'h05: rdata_next = {5'h0, gpio_out};
            8'h06: rdata_next = {5'h0, gpio_in};
            8'h07: rdata_next = {6'h0, cpu_sram_ctrl};
            8'h08: rdata_next = {2'h0, cpu_sram_status};
            8'h09: rdata_next = {5'h0, tx_ctrl};
            8'h0A: rdata_next = low_bat_thr;
            // --- RX front-end ---
            8'h10: rdata_next = {antenna_en, 2'h0, mimo_mode};
            8'h11: rdata_next = {4'h0, sf_cfg};
            8'h12: rdata_next = {6'h0, decim_ratio};
            8'h13: rdata_next = 8'h00;                              // FRONTEND_CFG (WO bits)
            8'h14: rdata_next = {2'h0, buf_freeze, sram1_bist_pass,
                            sram0_bist_pass, buf_valid, buf_mode};
            8'h15: rdata_next = {buf_freeze, buf_wr_ptr};
            8'h16: rdata_next = pkt_timeout_syms;
            8'h17: rdata_next = energy_thr[15:8];
            8'h18: rdata_next = energy_thr[7:0];
            8'h19: rdata_next = sc_thr[15:8];
            8'h1A: rdata_next = sc_thr[7:0];
            8'h1B: rdata_next = {6'h0, sc_hits_req};
            8'h1C: rdata_next = {7'h0, energy_gate_en};
            // --- Gain / AGC ---
            8'h20: rdata_next = rx_gain_shadow_0;
            8'h21: rdata_next = rx_gain_shadow_1;
            8'h22: rdata_next = rx_gain_shadow_2;
            8'h23: rdata_next = rx_gain_shadow_3;
            8'h24: rdata_next = tx_gain_0;
            8'h25: rdata_next = tx_gain_1;
            8'h26: rdata_next = rx_gain_active_0;
            8'h27: rdata_next = rx_gain_active_1;
            8'h28: rdata_next = rx_gain_active_2;
            8'h29: rdata_next = rx_gain_active_3;
            8'h2A: rdata_next = {4'h0, rx_gain_error, rx_gain_owner,
                            rx_gain_pending, 1'b0};
            // --- Packet / weight ---
            8'h30: rdata_next = {6'h0, active_mode_rb};
            8'h31: rdata_next = {4'h0, active_antenna_en_rb};
            8'h32: rdata_next = irq_status;
            8'h33: rdata_next = 8'h00;                              // IRQ_CLEAR (WO)
            8'h34: rdata_next = {w_missed_rb, w_valid_rb, w_pending_rb,
                            training_done_rb, packet_phase, packet_active};
            8'h35: rdata_next = {w_missed_rb, w_pending_rb, w_valid_rb,
                            1'b0, wgt_mode, wgt_auto_commit, wgt_src};
            8'h36: rdata_next = {5'h0, comb_post_gain_shift};
            8'h37: rdata_next = {6'h0, remod_backoff_shift};
            // --- Energy / SC live telemetry ---
            8'h40: rdata_next = energy_0[15:8];
            8'h41: rdata_next = energy_0[7:0];
            8'h42: rdata_next = energy_1[15:8];
            8'h43: rdata_next = energy_1[7:0];
            8'h44: rdata_next = energy_2[15:8];
            8'h45: rdata_next = energy_2[7:0];
            8'h46: rdata_next = energy_3[15:8];
            8'h47: rdata_next = energy_3[7:0];
            8'h48: rdata_next = corr_mag_0[15:8];
            8'h49: rdata_next = corr_mag_0[7:0];
            8'h4A: rdata_next = corr_mag_1[15:8];
            8'h4B: rdata_next = corr_mag_1[7:0];
            8'h4C: rdata_next = corr_mag_2[15:8];
            8'h4D: rdata_next = corr_mag_2[7:0];
            8'h4E: rdata_next = corr_mag_3[15:8];
            8'h4F: rdata_next = corr_mag_3[7:0];
            8'h50: rdata_next = sc_stat[15:8];
            8'h51: rdata_next = sc_stat[7:0];
            8'h52: rdata_next = cond_num_reg[15:8];
            8'h53: rdata_next = cond_num_reg[7:0];
            8'h54: rdata_next = snr_0_reg[15:8];
            8'h55: rdata_next = snr_0_reg[7:0];
            8'h56: rdata_next = null_quality_reg[15:8];
            8'h57: rdata_next = null_quality_reg[7:0];
            8'h6A: rdata_next = {7'h0, noise_en};
            8'h6B: rdata_next = {6'h0, ref_sel};
            // --- Training / estimation ---
            8'h60: rdata_next = {6'h0, training_armed, training_done_rb};
            8'h61: rdata_next = {6'h0, n_acc[9:8]};
            8'h62: rdata_next = n_acc[7:0];
            8'h63: rdata_next = {2'h0, z_shift};
            8'h64: rdata_next = c_pool_i[15:8];
            8'h65: rdata_next = c_pool_i[7:0];
            8'h66: rdata_next = c_pool_q[15:8];
            8'h67: rdata_next = c_pool_q[7:0];
            8'h68: rdata_next = cfo_diag[15:8];
            8'h69: rdata_next = cfo_diag[7:0];
            // Z_kl pair readback (big-endian int32) — all C(4,2)=6 cross-correlations.
            // Use with z_shift (0x63) for firmware scaling. Firmware path: read pairs,
            // build 4×4 Hermitian Z, take principal eigenvector for MRC weights.
            // Z_01 @ 0x70: pair (0,1)
            8'h70: rdata_next = zpair_i0[31:24];
            8'h71: rdata_next = zpair_i0[23:16];
            8'h72: rdata_next = zpair_i0[15:8];
            8'h73: rdata_next = zpair_i0[7:0];
            8'h74: rdata_next = zpair_q0[31:24];
            8'h75: rdata_next = zpair_q0[23:16];
            8'h76: rdata_next = zpair_q0[15:8];
            8'h77: rdata_next = zpair_q0[7:0];
            // Z_02 @ 0x78: pair (0,2)
            8'h78: rdata_next = zpair_i1[31:24];
            8'h79: rdata_next = zpair_i1[23:16];
            8'h7A: rdata_next = zpair_i1[15:8];
            8'h7B: rdata_next = zpair_i1[7:0];
            8'h7C: rdata_next = zpair_q1[31:24];
            8'h7D: rdata_next = zpair_q1[23:16];
            8'h7E: rdata_next = zpair_q1[15:8];
            8'h7F: rdata_next = zpair_q1[7:0];
            // Z_03 @ 0x80: pair (0,3)
            8'h80: rdata_next = zpair_i2[31:24];
            8'h81: rdata_next = zpair_i2[23:16];
            8'h82: rdata_next = zpair_i2[15:8];
            8'h83: rdata_next = zpair_i2[7:0];
            8'h84: rdata_next = zpair_q2[31:24];
            8'h85: rdata_next = zpair_q2[23:16];
            8'h86: rdata_next = zpair_q2[15:8];
            8'h87: rdata_next = zpair_q2[7:0];
            // Z_12 @ 0x88: pair (1,2)
            8'h88: rdata_next = zpair_i3[31:24];
            8'h89: rdata_next = zpair_i3[23:16];
            8'h8A: rdata_next = zpair_i3[15:8];
            8'h8B: rdata_next = zpair_i3[7:0];
            8'h8C: rdata_next = zpair_q3[31:24];
            8'h8D: rdata_next = zpair_q3[23:16];
            8'h8E: rdata_next = zpair_q3[15:8];
            8'h8F: rdata_next = zpair_q3[7:0];
            // --- W shadow bank (RW) ---
            8'h90: rdata_next = w_shadow_r[0];
            8'h91: rdata_next = w_shadow_r[1];
            8'h92: rdata_next = w_shadow_r[2];
            8'h93: rdata_next = w_shadow_r[3];
            8'h94: rdata_next = w_shadow_r[4];
            8'h95: rdata_next = w_shadow_r[5];
            8'h96: rdata_next = w_shadow_r[6];
            8'h97: rdata_next = w_shadow_r[7];
            8'h98: rdata_next = w_shadow_r[8];
            8'h99: rdata_next = w_shadow_r[9];
            8'h9A: rdata_next = w_shadow_r[10];
            8'h9B: rdata_next = w_shadow_r[11];
            8'h9C: rdata_next = w_shadow_r[12];
            8'h9D: rdata_next = w_shadow_r[13];
            8'h9E: rdata_next = w_shadow_r[14];
            8'h9F: rdata_next = w_shadow_r[15];
            // --- Calibration (RW) ---
            8'hA0: rdata_next = cal_coeff_r[0];
            8'hA1: rdata_next = cal_coeff_r[1];
            8'hA2: rdata_next = cal_coeff_r[2];
            8'hA3: rdata_next = cal_coeff_r[3];
            8'hA4: rdata_next = cal_coeff_r[4];
            8'hA5: rdata_next = cal_coeff_r[5];
            8'hA6: rdata_next = cal_coeff_r[6];
            8'hA7: rdata_next = cal_coeff_r[7];
            8'hA8: rdata_next = cal_coeff_r[8];
            8'hA9: rdata_next = cal_coeff_r[9];
            8'hAA: rdata_next = cal_coeff_r[10];
            8'hAB: rdata_next = cal_coeff_r[11];
            8'hAC: rdata_next = cal_coeff_r[12];
            8'hAD: rdata_next = cal_coeff_r[13];
            8'hAE: rdata_next = cal_coeff_r[14];
            8'hAF: rdata_next = cal_coeff_r[15];
            // --- PSRAM / SPI passthrough ---
            8'hB0: rdata_next = {5'h0, psram_ctrl};
            8'hB1: rdata_next = psram_status_rb;
            8'hB2: rdata_next = psram_pkt_bytes[15:8];
            8'hB3: rdata_next = psram_pkt_bytes[7:0];
            8'hB4: rdata_next = psram_rd_offset;
            8'hB5: rdata_next = {6'h0, sx_target};
            8'hB6: rdata_next = {1'h0, sx_addr};
            8'hB7: rdata_next = sx_data_wr;
            8'hB8: rdata_next = {5'h0, 1'b0 /*BUSY from SPI master*/, sx_start, sx_rnw};
            // --- SC debug ---
            8'hC0: rdata_next = {4'h0, sc_lock_dbg, sc_hit_count_dbg, sc_hit_dbg};
            8'hC2: rdata_next = sc_first_hit_dbg[31:24];
            8'hC3: rdata_next = sc_first_hit_dbg[23:16];
            8'hC4: rdata_next = sc_first_hit_dbg[15:8];
            8'hC5: rdata_next = sc_first_hit_dbg[7:0];
            8'hC6: rdata_next = sc_lock_snap_dbg[31:24];
            8'hC7: rdata_next = sc_lock_snap_dbg[23:16];
            8'hC8: rdata_next = sc_lock_snap_dbg[15:8];
            8'hC9: rdata_next = sc_lock_snap_dbg[7:0];
            8'hCA: rdata_next = {6'h0, sram_dump_done, 1'b0};
            8'hCB: rdata_next = {6'h0, sram_dump_addr[9:8]};
            8'hCC: rdata_next = sram_dump_addr[7:0];
            8'hCD: rdata_next = sram_dump_data;
            // --- NFE ---
            8'hD0: rdata_next = {4'h0, noise_alpha_shift, sigma2_src};
            8'hD1: rdata_next = {7'h0, sigma2_valid};
            8'hD2: rdata_next = noise_thresh[15:8];
            8'hD3: rdata_next = noise_thresh[7:0];
            // Z_13 @ 0xD4: pair (1,3)
            8'hD4: rdata_next = zpair_i4[31:24];
            8'hD5: rdata_next = zpair_i4[23:16];
            8'hD6: rdata_next = zpair_i4[15:8];
            8'hD7: rdata_next = zpair_i4[7:0];
            8'hD8: rdata_next = zpair_q4[31:24];
            8'hD9: rdata_next = zpair_q4[23:16];
            8'hDA: rdata_next = zpair_q4[15:8];
            8'hDB: rdata_next = zpair_q4[7:0];
            // --- Z_23 @ 0xE0: pair (2,3) — repurposes former sigma2_hw addresses ---
            // sigma2_hw_0..3 ports are wired to Zpair5 halves in mimo_rx_top.
            8'hE0: rdata_next = sigma2_hw_0[15:8];   // zpair_i5[31:16] MSB
            8'hE1: rdata_next = sigma2_hw_0[7:0];    // zpair_i5[31:16] LSB
            8'hE2: rdata_next = sigma2_hw_1[15:8];   // zpair_i5[15:0]  MSB
            8'hE3: rdata_next = sigma2_hw_1[7:0];    // zpair_i5[15:0]  LSB
            8'hE4: rdata_next = sigma2_hw_2[15:8];   // zpair_q5[31:16] MSB
            8'hE5: rdata_next = sigma2_hw_2[7:0];    // zpair_q5[31:16] LSB
            8'hE6: rdata_next = sigma2_hw_3[15:8];   // zpair_q5[15:0]  MSB
            8'hE7: rdata_next = sigma2_hw_3[7:0];    // zpair_q5[15:0]  LSB
            // --- Z_kk diagonal autocorrelation @ 0xE8: top 16 bits per branch ---
            // Zdiag_k = Σ|raw_k[n]|² over the training window.  In noise mode
            // (no signal) Zdiag_k ≈ σ²_k · n_acc. Upper 16 bits give sufficient
            // resolution for firmware noise EMA (full 32-bit in training_acc register).
            8'hE8: rdata_next = zdiag_0[31:24];
            8'hE9: rdata_next = zdiag_0[23:16];
            8'hEA: rdata_next = zdiag_1[31:24];
            8'hEB: rdata_next = zdiag_1[23:16];
            8'hEC: rdata_next = zdiag_2[31:24];
            8'hED: rdata_next = zdiag_2[23:16];
            8'hEE: rdata_next = zdiag_3[31:24];
            8'hEF: rdata_next = zdiag_3[23:16];
            // --- SIGMA2 SW override ---
            8'hF1: rdata_next = sigma2_sw_r[0];
            8'hF2: rdata_next = sigma2_sw_r[1];
            8'hF3: rdata_next = sigma2_sw_r[2];
            8'hF4: rdata_next = sigma2_sw_r[3];
            8'hF5: rdata_next = sigma2_sw_r[4];
            8'hF6: rdata_next = sigma2_sw_r[5];
            8'hF7: rdata_next = sigma2_sw_r[6];
            8'hF8: rdata_next = sigma2_sw_r[7];
            default: rdata_next = 8'h00;
        endcase
    end

endmodule
