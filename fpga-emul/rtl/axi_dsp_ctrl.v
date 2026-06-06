// axi_dsp_ctrl.v
// AXI4-Lite peripheral wrapping fpga_dsp_wrap.
//
// Clock domain:
//   This peripheral runs entirely on clk_dsp (32 MHz), which is the same
//   clock as the DSP chain.  A Vivado AXI clock converter IP in the block
//   design bridges between the MicroBlaze AXI bus (100 MHz) and this
//   peripheral (32 MHz), so no CDC is required internally.
//
// Register map (byte addresses, 32-bit access):
//   0x00  CTRL        R/W  [1:0]   mode (0=DECIM_ETH, 1=FULL_DSP, 2=INJECT)
//                          [2]     rst_dsp (active-high, hold to reset DSP)
//                          [3]     inj_rate_en (enable rate-matching timer)
//                          [5:4]   decim_ratio
//                          [9:6]   dc_alpha_shift
//                          [10]    dc_bypass
//                          [14:11] sf (LoRa SF, 6-12)
//                          [18:15] antenna_en
//                          [20:19] wgt_mode
//                          [21]    wgt_auto_commit
//                          [24:22] comb_post_gain_shift
//                          [26:25] bypass_ant (for bypass mode)
//                          [27]    wgt_src
//                          [28]    mimo_mode (0=MRC 4ant, 1=single bypass)
//   0x04  STATUS      RO   [0]     sc_lock
//                          [1]     training_done
//                          [2]     W_commit (latched since last STATUS read)
//                          [3]     packet_active
//                          [8]     eth_fifo_empty
//                          [9]     eth_fifo_half
//                          [10]    eth_fifo_full
//                          [16]    inj_fifo_empty
//                          [17]    inj_fifo_full
//                          [18]    inj_underrun (timer fired, FIFO empty; sticky, cleared on read)
//                          [19]    eth_overflow  (dropped sample, FIFO full; sticky, cleared on read)
//   0x08  ETH_LO      RO   pop ETH FIFO head → shadow; return head[63:32]
//                           Mode 0: {i0,q0,i1,q1}
//                           Mode 1/2: {y_i,y_q,flags[7:0],8'b0}
//   0x0C  ETH_HI      RO   return shadow[31:0] (no pop)
//                           Mode 0: {i2,q2,i3,q3}
//                           Mode 1/2: 32'h0
//   0x10  INJ_LO      WO   stage injection low word {i0,q0,i1,q1}
//   0x14  INJ_HI      WO   stage injection high word {i2,q2,i3,q3} + push FIFO
//   0x18  INJ_PERIOD  R/W  [31:0]  injection timer period in DSP cycles
//                                  default 256 = 32 MHz / 125 kHz
//   0x1C  TIMING_REF  RO   [31:0]  timing_ref from SC detector
//   0x20  W_RE01      RO   [31:16]=W_re1, [15:0]=W_re0
//   0x24  W_IM01      RO   [31:16]=W_im1, [15:0]=W_im0
//   0x28  W_RE23      RO   [31:16]=W_re3, [15:0]=W_re2
//   0x2C  W_IM23      RO   [31:16]=W_im3, [15:0]=W_im2
//   0x30  ENERGY01    RO   [31:16]=energy1, [15:0]=energy0
//   0x34  ENERGY23    RO   [31:16]=energy3, [15:0]=energy2
//   0x38  FW_W_RE01   R/W  [31:16]=fw_W_re1, [15:0]=fw_W_re0
//   0x3C  FW_W_IM01   R/W  ...
//   0x40  FW_W_RE23   R/W  ...
//   0x44  FW_W_IM23   R/W  ...
//   0x48  SC_CFG      R/W  [15:0]  sc_thr, [18:16] sc_hits_req
//   0x4C  NOISE_CFG   R/W  [15:0]  noise_thresh, [23:16] pkt_timeout_syms
//   0x50  CAL_RE01    R/W  [31:16]=cal_re1, [15:0]=cal_re0
//   0x54  CAL_IM01    R/W  ...
//   0x58  CAL_RE23    R/W  ...
//   0x5C  CAL_IM23    R/W  ...
//   0x60  FW_W_COMMIT WO   write any value → 1-cycle fw_W_commit pulse
//   0x64  COMBINED    RO   [7:0]=latest y_i, [15:8]=latest y_q (FULL/INJECT)

`default_nettype none

module axi_dsp_ctrl #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 8
) (
    // AXI4-Lite slave (runs at clk_dsp after clock converter)
    input  wire                             s_axi_aclk,
    input  wire                             s_axi_aresetn,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  wire [2:0]                       s_axi_awprot,
    input  wire                             s_axi_awvalid,
    output reg                              s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]    s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]  s_axi_wstrb,
    input  wire                             s_axi_wvalid,
    output reg                              s_axi_wready,
    output reg  [1:0]                       s_axi_bresp,
    output reg                              s_axi_bvalid,
    input  wire                             s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
    input  wire [2:0]                       s_axi_arprot,
    input  wire                             s_axi_arvalid,
    output reg                              s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]    s_axi_rdata,
    output reg  [1:0]                       s_axi_rresp,
    output reg                              s_axi_rvalid,
    input  wire                             s_axi_rready,

    // DSP clock (same as s_axi_aclk after clock converter in block design)
    input  wire        dsp_clk,      // 32 MHz from MMCM
    // Note: rst_n for DSP chain driven by CTRL[2] internally; AXI reset
    // used for AXI logic; DSP reset is OR of (~aresetn | CTRL[2])

    // Hardware I/Q inputs (SX1257 pins, synchronous to dsp_clk)
    input  wire [3:0]  hw_iq_i,
    input  wire [3:0]  hw_iq_q,

    // Status outputs for external logic / IRQ
    output wire        sc_lock_out,
    output wire        training_done_out,
    output wire        W_commit_out,

    // REMOD output pins (for PMOD / oscilloscope connection)
    output wire        remod_i,
    output wire        remod_q
);

    // =========================================================================
    // AXI write channel
    // =========================================================================
    wire clk    = s_axi_aclk;
    wire rst_n  = s_axi_aresetn;

    // Latch write address + data together (AW and W may arrive in different cycles)
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr_lat;
    reg [C_S_AXI_DATA_WIDTH-1:0] w_data_lat;
    reg [C_S_AXI_DATA_WIDTH/8-1:0] w_strb_lat;
    reg aw_pend, w_pend;
    reg do_write;
    reg [C_S_AXI_ADDR_WIDTH-1:0] wr_addr;
    reg [C_S_AXI_DATA_WIDTH-1:0] wr_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0;
            s_axi_bvalid  <= 1'b0; s_axi_bresp  <= 2'b0;
            aw_pend <= 1'b0; w_pend <= 1'b0;
            do_write <= 1'b0;
        end else begin
            do_write <= 1'b0;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;

            if (s_axi_awvalid && !aw_pend) begin
                aw_addr_lat  <= s_axi_awaddr;
                aw_pend      <= 1'b1;
                s_axi_awready <= 1'b1;
            end
            if (s_axi_wvalid && !w_pend) begin
                w_data_lat  <= s_axi_wdata;
                w_strb_lat  <= s_axi_wstrb;
                w_pend      <= 1'b1;
                s_axi_wready <= 1'b1;
            end

            if (aw_pend && w_pend) begin
                wr_addr  <= aw_addr_lat;
                wr_data  <= w_data_lat;
                do_write <= 1'b1;
                aw_pend  <= 1'b0;
                w_pend   <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // =========================================================================
    // AXI read channel
    // =========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] rd_addr;
    reg do_read;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b0;
            do_read       <= 1'b0;
        end else begin
            s_axi_arready <= 1'b0;
            do_read       <= 1'b0;
            if (s_axi_arvalid && !s_axi_rvalid) begin
                rd_addr       <= s_axi_araddr;
                do_read       <= 1'b1;
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Configuration registers (written by AXI, read by DSP wrap)
    // =========================================================================
    // Default values chosen for safe single-antenna bypass operation at power-on.
    reg [28:0]  ctrl_reg;          // offset 0x00
    reg [31:0]  inj_period_reg;    // offset 0x18, default=256
    reg signed [15:0] fw_W_re0_r, fw_W_im0_r;
    reg signed [15:0] fw_W_re1_r, fw_W_im1_r;
    reg signed [15:0] fw_W_re2_r, fw_W_im2_r;
    reg signed [15:0] fw_W_re3_r, fw_W_im3_r;
    reg [18:0]  sc_cfg_reg;        // [15:0]=sc_thr, [18:16]=sc_hits_req
    reg [23:0]  noise_cfg_reg;     // [15:0]=noise_thresh, [23:16]=pkt_timeout
    reg signed [15:0] cal_re0_r, cal_im0_r;
    reg signed [15:0] cal_re1_r, cal_im1_r;
    reg signed [15:0] cal_re2_r, cal_im2_r;
    reg signed [15:0] cal_re3_r, cal_im3_r;

    // Decoded config fields
    wire [1:0]  mode_cfg           = ctrl_reg[1:0];
    wire        rst_dsp_cfg        = ctrl_reg[2];
    wire        inj_rate_en        = ctrl_reg[3];
    wire [1:0]  decim_ratio_cfg    = ctrl_reg[5:4];
    wire [3:0]  dc_alpha_shift_cfg = ctrl_reg[9:6];
    wire        dc_bypass_cfg      = ctrl_reg[10];
    wire [3:0]  sf_cfg             = ctrl_reg[14:11];
    wire [3:0]  antenna_en_cfg     = ctrl_reg[18:15];
    wire [1:0]  wgt_mode_cfg       = ctrl_reg[20:19];
    wire        wgt_auto_commit_cfg= ctrl_reg[21];
    wire [2:0]  comb_post_gain_cfg = ctrl_reg[24:22];
    wire [1:0]  bypass_ant_cfg     = ctrl_reg[26:25];   // unused by wrap, kept for future
    wire        wgt_src_cfg        = ctrl_reg[27];
    wire        mimo_mode_cfg      = ctrl_reg[28];

    // DSP reset: AXI reset OR software rst_dsp bit
    wire dsp_rst_n = rst_n & ~rst_dsp_cfg;

    // fw_W_commit: one-cycle pulse when FW_W_COMMIT register is written
    reg fw_W_commit_pulse;

    // Status sticky bits — all driven from the single sticky-bits always block below.
    // Cleared on STATUS register read.
    reg eth_overflow_sticky;
    reg inj_underrun_sticky;
    reg W_commit_latched;

    // =========================================================================
    // Injection FIFO and rate-matching timer
    // =========================================================================
    // Staging register for two-word write protocol
    reg [31:0] inj_lo_stage;

    wire [63:0] inj_fifo_wdata;
    reg         inj_fifo_wr_en;
    wire        inj_fifo_full;
    wire [63:0] inj_fifo_rdata;
    wire        inj_fifo_empty;
    wire        inj_fifo_half;

    assign inj_fifo_wdata = {inj_lo_stage, wr_data};   // pushed when INJ_HI written

    sync_fifo #(.DATA_W(64), .ADDR_W(8)) u_inj_fifo (
        .clk     (clk),
        .rst_n   (dsp_rst_n),
        .wr_en   (inj_fifo_wr_en),
        .wr_data (inj_fifo_wdata),
        .full    (inj_fifo_full),
        .rd_en   (inj_pop),
        .rd_data (inj_fifo_rdata),
        .empty   (inj_fifo_empty),
        .half    (inj_fifo_half)
    );

    // Rate-matching timer: generates inj_pop at cfg rate when enabled
    reg [31:0] inj_timer;
    reg        inj_pop;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inj_timer <= 32'd0;
            inj_pop   <= 1'b0;
        end else begin
            inj_pop <= 1'b0;
            if (inj_rate_en && (mode_cfg == 2'b10)) begin
                if (inj_timer >= inj_period_reg - 1) begin
                    inj_timer <= 32'd0;
                    inj_pop   <= 1'b1;
                end else begin
                    inj_timer <= inj_timer + 32'd1;
                end
            end else begin
                inj_timer <= 32'd0;
            end
        end
    end

    // Injection outputs to fpga_dsp_wrap.
    // inj_fifo uses distributed RAM (FWFT): inj_fifo_rdata is combinational head.
    // Capture it on the same cycle inj_pop fires; assert valid the following cycle.
    reg        inj_valid_r;
    reg signed [7:0] inj_i0_r, inj_q0_r;
    reg signed [7:0] inj_i1_r, inj_q1_r;
    reg signed [7:0] inj_i2_r, inj_q2_r;
    reg signed [7:0] inj_i3_r, inj_q3_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inj_valid_r <= 1'b0;
            {inj_i0_r,inj_q0_r,inj_i1_r,inj_q1_r,inj_i2_r,inj_q2_r,inj_i3_r,inj_q3_r}
                <= 64'h0;
        end else begin
            inj_valid_r <= 1'b0;
            if (inj_pop) begin
                inj_valid_r <= 1'b1;
                if (!inj_fifo_empty) begin
                    // Distributed RAM: rdata is combinational; capture head now.
                    // fifo data: [63:56]=i0,[55:48]=q0,...,[7:0]=q3
                    inj_i0_r <= $signed(inj_fifo_rdata[63:56]);
                    inj_q0_r <= $signed(inj_fifo_rdata[55:48]);
                    inj_i1_r <= $signed(inj_fifo_rdata[47:40]);
                    inj_q1_r <= $signed(inj_fifo_rdata[39:32]);
                    inj_i2_r <= $signed(inj_fifo_rdata[31:24]);
                    inj_q2_r <= $signed(inj_fifo_rdata[23:16]);
                    inj_i3_r <= $signed(inj_fifo_rdata[15:8]);
                    inj_q3_r <= $signed(inj_fifo_rdata[7:0]);
                end else begin
                    // Underrun: insert zero sample to maintain DSP timing.
                    // inj_underrun_sticky set in sticky-bits always block below.
                    {inj_i0_r,inj_q0_r,inj_i1_r,inj_q1_r,
                     inj_i2_r,inj_q2_r,inj_i3_r,inj_q3_r} <= 64'h0;
                end
            end
        end
    end

    // =========================================================================
    // ETH output FIFO (DSP chain → MicroBlaze → UDP)
    // =========================================================================
    wire [63:0] eth_fifo_wdata;
    wire        eth_fifo_wr_en;
    wire        eth_fifo_full;
    wire [63:0] eth_fifo_rdata;
    reg         eth_fifo_rd_en;
    wire        eth_fifo_empty;
    wire        eth_fifo_half;

    sync_fifo #(.DATA_W(64), .ADDR_W(8)) u_eth_fifo (
        .clk     (clk),
        .rst_n   (dsp_rst_n),
        .wr_en   (eth_fifo_wr_en),
        .wr_data (eth_fifo_wdata),
        .full    (eth_fifo_full),
        .rd_en   (eth_fifo_rd_en),
        .rd_data (eth_fifo_rdata),
        .empty   (eth_fifo_empty),
        .half    (eth_fifo_half)
    );

    // ETH FIFO shadow register.
    // Populated when ETH_LO is read: captures the full 64-bit FIFO head
    // (combinational — distributed RAM, no latency).  ETH_HI returns shadow[31:0].
    reg [63:0] eth_shadow;

    // =========================================================================
    // DSP chain status signals
    // =========================================================================
    wire        sc_lock_w, training_done_w, W_commit_w, packet_active_w;
    wire signed [15:0] W_re0_w, W_im0_w, W_re1_w, W_im1_w;
    wire signed [15:0] W_re2_w, W_im2_w, W_re3_w, W_im3_w;
    wire [15:0] energy0_w, energy1_w, energy2_w, energy3_w;
    wire [31:0] timing_ref_w;
    wire        inj_ready_w;

    assign sc_lock_out      = sc_lock_w;
    assign training_done_out = training_done_w;
    assign W_commit_out     = W_commit_w;

    // Latest combined output (for COMBINED register)
    reg signed [7:0] latest_y_i, latest_y_q;

    // Capture combined sample from FIFO data in FULL_DSP/INJECT modes
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latest_y_i <= 8'h0;
            latest_y_q <= 8'h0;
        end else if (eth_fifo_wr_en && (mode_cfg != 2'b00)) begin
            latest_y_i <= $signed(eth_fifo_wdata[63:56]);
            latest_y_q <= $signed(eth_fifo_wdata[55:48]);
        end
    end

    // =========================================================================
    // Sticky-bits / latch register — single always block, single driver per reg
    // =========================================================================
    // Register map:
    //   eth_overflow_sticky : set when eth_fifo_wr_en && eth_fifo_full
    //   inj_underrun_sticky : set when inj_pop && inj_fifo_empty
    //   W_commit_latched    : set on any W_commit_w pulse
    // All three cleared on STATUS register read (status_read pulse).
    //
    // status_read defined here as a combinational signal; used by read block too.
    // rd_reg declared below, but it's a wire so forward reference is fine in Verilog.

    // Register address decode helpers — forward-declared wires used in multiple blocks.
    // wr_addr / rd_addr are 8-bit [7:0]; word-index = [7:2] = 6 bits [5:0].
    // Max register offset is 0x64 → word-index 0x19 = 25, fits in [5:0].
    localparam [5:0] CTRL_OFF       = 6'h00;
    localparam [5:0] STATUS_OFF     = 6'h01;
    localparam [5:0] ETH_LO_OFF     = 6'h02;
    localparam [5:0] ETH_HI_OFF     = 6'h03;
    localparam [5:0] INJ_LO_OFF     = 6'h04;
    localparam [5:0] INJ_HI_OFF     = 6'h05;
    localparam [5:0] INJ_PERIOD_OFF = 6'h06;
    localparam [5:0] TIMING_OFF     = 6'h07;
    localparam [5:0] W_RE01_OFF     = 6'h08;
    localparam [5:0] W_IM01_OFF     = 6'h09;
    localparam [5:0] W_RE23_OFF     = 6'h0A;
    localparam [5:0] W_IM23_OFF     = 6'h0B;
    localparam [5:0] ENERGY01_OFF   = 6'h0C;
    localparam [5:0] ENERGY23_OFF   = 6'h0D;
    localparam [5:0] FW_W_RE01_OFF  = 6'h0E;
    localparam [5:0] FW_W_IM01_OFF  = 6'h0F;
    localparam [5:0] FW_W_RE23_OFF  = 6'h10;
    localparam [5:0] FW_W_IM23_OFF  = 6'h11;
    localparam [5:0] SC_CFG_OFF     = 6'h12;
    localparam [5:0] NOISE_CFG_OFF  = 6'h13;
    localparam [5:0] CAL_RE01_OFF   = 6'h14;
    localparam [5:0] CAL_IM01_OFF   = 6'h15;
    localparam [5:0] CAL_RE23_OFF   = 6'h16;
    localparam [5:0] CAL_IM23_OFF   = 6'h17;
    localparam [5:0] FW_W_COMMIT_OFF= 6'h18;
    localparam [5:0] COMBINED_OFF   = 6'h19;

    wire [5:0] wr_reg = wr_addr[7:2];
    wire [5:0] rd_reg = rd_addr[7:2];

    // status_read: high for one cycle when the AXI read channel services STATUS.
    wire status_read = do_read && (rd_reg == STATUS_OFF);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eth_overflow_sticky <= 1'b0;
            inj_underrun_sticky <= 1'b0;
            W_commit_latched    <= 1'b0;
        end else begin
            // Set conditions
            if (eth_fifo_wr_en && eth_fifo_full)
                eth_overflow_sticky <= 1'b1;
            if (inj_pop && inj_fifo_empty)
                inj_underrun_sticky <= 1'b1;
            if (W_commit_w)
                W_commit_latched <= 1'b1;
            // Clear all on STATUS read (override sets if both happen same cycle;
            // a simultaneous set+clear is an extremely unlikely race at 32 MHz
            // and the cleared value is acceptable — firmware will re-read).
            if (status_read) begin
                eth_overflow_sticky <= 1'b0;
                inj_underrun_sticky <= 1'b0;
                W_commit_latched    <= 1'b0;
            end
        end
    end

    // =========================================================================
    // fpga_dsp_wrap instantiation
    // =========================================================================
    fpga_dsp_wrap u_dsp (
        .clk         (clk),
        .rst_n       (dsp_rst_n),
        .mode        (mode_cfg),
        .decim_ratio (decim_ratio_cfg),
        .dc_alpha_shift (dc_alpha_shift_cfg),
        .dc_bypass   (dc_bypass_cfg),
        .sf          (sf_cfg),
        .antenna_en  (antenna_en_cfg),
        .sc_thr      (sc_cfg_reg[15:0]),
        .sc_hits_req (sc_cfg_reg[18:16]),
        .wgt_mode    (wgt_mode_cfg),
        .wgt_src     (wgt_src_cfg),
        .wgt_auto_commit (wgt_auto_commit_cfg),
        .mimo_mode   ({1'b0, mimo_mode_cfg}),
        .pkt_timeout_syms (noise_cfg_reg[23:16]),
        .noise_thresh     (noise_cfg_reg[15:0]),
        .comb_post_gain_shift (comb_post_gain_cfg),
        .cal_re0 (cal_re0_r), .cal_im0 (cal_im0_r),
        .cal_re1 (cal_re1_r), .cal_im1 (cal_im1_r),
        .cal_re2 (cal_re2_r), .cal_im2 (cal_im2_r),
        .cal_re3 (cal_re3_r), .cal_im3 (cal_im3_r),
        .fw_W_re0 (fw_W_re0_r), .fw_W_im0 (fw_W_im0_r),
        .fw_W_re1 (fw_W_re1_r), .fw_W_im1 (fw_W_im1_r),
        .fw_W_re2 (fw_W_re2_r), .fw_W_im2 (fw_W_im2_r),
        .fw_W_re3 (fw_W_re3_r), .fw_W_im3 (fw_W_im3_r),
        .fw_W_commit (fw_W_commit_pulse),
        .hw_iq_i     (hw_iq_i),
        .hw_iq_q     (hw_iq_q),
        .inj_i0 (inj_i0_r), .inj_q0 (inj_q0_r),
        .inj_i1 (inj_i1_r), .inj_q1 (inj_q1_r),
        .inj_i2 (inj_i2_r), .inj_q2 (inj_q2_r),
        .inj_i3 (inj_i3_r), .inj_q3 (inj_q3_r),
        .inj_valid   (inj_valid_r),
        .inj_ready   (inj_ready_w),
        .eth_data    (eth_fifo_wdata),
        .eth_push    (eth_fifo_wr_en),
        .eth_full    (eth_fifo_full),
        .sc_lock     (sc_lock_w),
        .timing_ref  (timing_ref_w),
        .training_done (training_done_w),
        .W_commit    (W_commit_w),
        .packet_active (packet_active_w),
        .W_re0 (W_re0_w), .W_im0 (W_im0_w),
        .W_re1 (W_re1_w), .W_im1 (W_im1_w),
        .W_re2 (W_re2_w), .W_im2 (W_im2_w),
        .W_re3 (W_re3_w), .W_im3 (W_im3_w),
        .energy0 (energy0_w), .energy1 (energy1_w),
        .energy2 (energy2_w), .energy3 (energy3_w),
        .remod_i     (remod_i),
        .remod_q     (remod_q)
    );

    // =========================================================================
    // Register write logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_reg        <= 29'b0;
            inj_period_reg  <= 32'd256;
            fw_W_re0_r <= 16'h7FFF; fw_W_im0_r <= 16'h0;  // identity weights
            fw_W_re1_r <= 16'h7FFF; fw_W_im1_r <= 16'h0;
            fw_W_re2_r <= 16'h7FFF; fw_W_im2_r <= 16'h0;
            fw_W_re3_r <= 16'h7FFF; fw_W_im3_r <= 16'h0;
            sc_cfg_reg  <= {3'd3, 16'd4000};   // 3 hits, threshold=4000
            noise_cfg_reg <= {8'd20, 16'd100}; // timeout=20 syms, thresh=100
            cal_re0_r <= 16'h7FFF; cal_im0_r <= 16'h0;   // unity cal
            cal_re1_r <= 16'h7FFF; cal_im1_r <= 16'h0;
            cal_re2_r <= 16'h7FFF; cal_im2_r <= 16'h0;
            cal_re3_r <= 16'h7FFF; cal_im3_r <= 16'h0;
            inj_lo_stage    <= 32'h0;
            inj_fifo_wr_en  <= 1'b0;
            fw_W_commit_pulse <= 1'b0;
        end else begin
            inj_fifo_wr_en    <= 1'b0;
            fw_W_commit_pulse <= 1'b0;

            if (do_write) begin
                case (wr_reg)
                    CTRL_OFF:       ctrl_reg        <= wr_data[28:0];
                    INJ_LO_OFF:     inj_lo_stage    <= wr_data;
                    INJ_HI_OFF: begin
                        // Push: {inj_lo_stage[31:0], wr_data[31:0]} → FIFO
                        // Byte order in 64-bit word:
                        //   [63:56]=i0 [55:48]=q0 [47:40]=i1 [39:32]=q1
                        //   [31:24]=i2 [23:16]=q2 [15:8]=i3  [7:0]=q3
                        // INJ_LO carries {i0,q0,i1,q1}, INJ_HI carries {i2,q2,i3,q3}
                        if (!inj_fifo_full)
                            inj_fifo_wr_en <= 1'b1;
                        // inj_fifo_wdata = {inj_lo_stage, wr_data} (see assign above)
                    end
                    INJ_PERIOD_OFF: inj_period_reg  <= wr_data;
                    FW_W_RE01_OFF: begin
                        fw_W_re0_r <= $signed(wr_data[15:0]);
                        fw_W_re1_r <= $signed(wr_data[31:16]);
                    end
                    FW_W_IM01_OFF: begin
                        fw_W_im0_r <= $signed(wr_data[15:0]);
                        fw_W_im1_r <= $signed(wr_data[31:16]);
                    end
                    FW_W_RE23_OFF: begin
                        fw_W_re2_r <= $signed(wr_data[15:0]);
                        fw_W_re3_r <= $signed(wr_data[31:16]);
                    end
                    FW_W_IM23_OFF: begin
                        fw_W_im2_r <= $signed(wr_data[15:0]);
                        fw_W_im3_r <= $signed(wr_data[31:16]);
                    end
                    SC_CFG_OFF:    sc_cfg_reg      <= wr_data[18:0];
                    NOISE_CFG_OFF: noise_cfg_reg   <= wr_data[23:0];
                    CAL_RE01_OFF: begin
                        cal_re0_r <= $signed(wr_data[15:0]);
                        cal_re1_r <= $signed(wr_data[31:16]);
                    end
                    CAL_IM01_OFF: begin
                        cal_im0_r <= $signed(wr_data[15:0]);
                        cal_im1_r <= $signed(wr_data[31:16]);
                    end
                    CAL_RE23_OFF: begin
                        cal_re2_r <= $signed(wr_data[15:0]);
                        cal_re3_r <= $signed(wr_data[31:16]);
                    end
                    CAL_IM23_OFF: begin
                        cal_im2_r <= $signed(wr_data[15:0]);
                        cal_im3_r <= $signed(wr_data[31:16]);
                    end
                    FW_W_COMMIT_OFF: fw_W_commit_pulse <= 1'b1;
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // Register read logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_rdata    <= 32'h0;
            eth_fifo_rd_en <= 1'b0;
            eth_shadow     <= 64'h0;
        end else begin
            eth_fifo_rd_en <= 1'b0;

            if (do_read) begin
                case (rd_reg)
                    CTRL_OFF: s_axi_rdata <= {3'b0, ctrl_reg};

                    STATUS_OFF: begin
                        // Sticky bits read here; cleared by sticky-bits always block
                        // which sees status_read = do_read && (rd_reg == STATUS_OFF).
                        s_axi_rdata <= {
                            12'b0,
                            eth_overflow_sticky,    // [19]
                            inj_underrun_sticky,    // [18]
                            inj_fifo_full,          // [17]
                            inj_fifo_empty,         // [16]
                            6'b0,
                            eth_fifo_full,          // [10]
                            eth_fifo_half,          // [9]
                            eth_fifo_empty,         // [8]
                            4'b0,
                            packet_active_w,        // [3]
                            W_commit_latched,       // [2]
                            training_done_w,        // [1]
                            sc_lock_w               // [0]
                        };
                    end

                    ETH_LO_OFF: begin
                        // Distributed RAM FWFT: eth_fifo_rdata is the combinational
                        // head.  Assert rd_en to advance the pointer.  Capture the
                        // full 64-bit word into eth_shadow for subsequent ETH_HI read.
                        // Return the upper 32 bits ([63:32]) directly — no latency.
                        if (!eth_fifo_empty) begin
                            eth_fifo_rd_en <= 1'b1;
                            eth_shadow     <= eth_fifo_rdata;
                            s_axi_rdata    <= eth_fifo_rdata[63:32];
                        end else begin
                            // FIFO empty: return last captured shadow high word.
                            s_axi_rdata <= eth_shadow[63:32];
                        end
                    end

                    ETH_HI_OFF:
                        // Return shadow low word — captured when ETH_LO was read.
                        s_axi_rdata <= eth_shadow[31:0];

                    INJ_PERIOD_OFF: s_axi_rdata <= inj_period_reg;
                    TIMING_OFF:     s_axi_rdata <= timing_ref_w;

                    W_RE01_OFF:  s_axi_rdata <= {W_re1_w, W_re0_w};
                    W_IM01_OFF:  s_axi_rdata <= {W_im1_w, W_im0_w};
                    W_RE23_OFF:  s_axi_rdata <= {W_re3_w, W_re2_w};
                    W_IM23_OFF:  s_axi_rdata <= {W_im3_w, W_im2_w};
                    ENERGY01_OFF:s_axi_rdata <= {energy1_w, energy0_w};
                    ENERGY23_OFF:s_axi_rdata <= {energy3_w, energy2_w};

                    FW_W_RE01_OFF: s_axi_rdata <= {fw_W_re1_r, fw_W_re0_r};
                    FW_W_IM01_OFF: s_axi_rdata <= {fw_W_im1_r, fw_W_im0_r};
                    FW_W_RE23_OFF: s_axi_rdata <= {fw_W_re3_r, fw_W_re2_r};
                    FW_W_IM23_OFF: s_axi_rdata <= {fw_W_im3_r, fw_W_im2_r};
                    SC_CFG_OFF:    s_axi_rdata <= {13'b0, sc_cfg_reg};
                    NOISE_CFG_OFF: s_axi_rdata <= {8'b0, noise_cfg_reg};
                    CAL_RE01_OFF:  s_axi_rdata <= {cal_re1_r, cal_re0_r};
                    CAL_IM01_OFF:  s_axi_rdata <= {cal_im1_r, cal_im0_r};
                    CAL_RE23_OFF:  s_axi_rdata <= {cal_re3_r, cal_re2_r};
                    CAL_IM23_OFF:  s_axi_rdata <= {cal_im3_r, cal_im2_r};
                    COMBINED_OFF:  s_axi_rdata <= {16'b0,
                                                   latest_y_q, latest_y_i};
                    default:       s_axi_rdata <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
