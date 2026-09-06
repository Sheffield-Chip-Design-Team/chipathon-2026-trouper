// axi_inj_ctrl.v
// AXI4-Lite peripheral: I/Q injection FIFO + rate-matching pacer for
// fpga_dsp_wrap. Lets firmware push synthetic int8 I/Q samples (4 antennas)
// over Ethernet/UDP and have them paced out at a fixed rate to feed
// fpga_dsp_wrap's ΣΔ re-modulators, which turn them into a 1-bit stream muxed
// onto hw_iq_i/hw_iq_q in place of the real SX1257 pins. This replaces the
// old int8-level INJECT mode (which bypassed the decimator entirely): here
// the injected signal goes back through the real R=64 decimator and the rest
// of trouper_top's chain, exactly like a real antenna would produce it.
//
// Clock domain: runs entirely on dsp_clk (32 MHz) — same as fpga_dsp_wrap and
// the DSP chain. A Vivado AXI clock converter bridges the MicroBlaze AXI bus
// (100 MHz) to this peripheral, same pattern as the old axi_dsp_ctrl.
//
// Register map (byte addresses, 32-bit access):
//   0x00  CTRL       R/W  [0] INJ_EN — 1: hw_iq_i/hw_iq_q sourced from the
//                         paced ΣΔ-modulated injection stream instead of the
//                         real SX1257 pins
//   0x04  STATUS     RO   [0] FIFO_EMPTY  [1] FIFO_FULL
//                         [2] UNDERRUN (sticky, cleared on read: pacer fired
//                             while FIFO was empty — a zero sample was paced
//                             out instead)
//   0x08  INJ_LO     WO   stage {i0,q0,i1,q1} (int8 each)
//   0x0C  INJ_HI     WO   stage {i2,q2,i3,q3}; write pushes the combined
//                         64-bit entry into the FIFO
//   0x10  INJ_PERIOD R/W  [31:0] pacer period in dsp_clk cycles; default 64
//
// Replay/channel-emulation extension.  It is deliberately additive: the
// live UDP FIFO interface above is unchanged and remains the quick Ethernet
// smoke-test path.  Replay stores one base complex stream in BRAM, paces it
// locally, and derives four branches with independent complex coefficients and
// deterministic pseudo-Gaussian noise.
//   0x14  CAP_ADDR    R/W capture write address
//   0x18  CAP_DATA    WO {I,Q} signed int8; write stores at CAP_ADDR, ++addr
//   0x1c  CAP_LENGTH  R/W number of valid capture samples (1..16384)
//   0x20  REPLAY_CTRL WO [0] start, [1] abort; start requires live INJ_EN=0
//   0x24  REPLAY_STAT RO [0] active [1] done [2] bad_start [3] cap_valid
//   0x30..0x3c CHn_COEFF R/W {gain_i,gain_q}, signed Q1.15, n=0..3
//   0x40..0x4c CHn_NOISE R/W [7:0] noise scale (roughly 1/32 LSB units)
//   0x50  NOISE_SEED  R/W deterministic run seed
//                         (32 MHz / 64 = 500 kHz, matching the decimator's
//                         R=64 output rate that sd_remod expects)

`default_nettype none

module axi_inj_ctrl #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 8,
    parameter CAPTURE_ADDR_W = 14
) (
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

    // Outputs to fpga_dsp_wrap (dsp_clk domain == s_axi_aclk)
    output wire        inj_en,
    output wire        inj_valid,
    output wire signed [7:0] inj_i0, inj_q0,
    output wire signed [7:0] inj_i1, inj_q1,
    output wire signed [7:0] inj_i2, inj_q2,
    output wire signed [7:0] inj_i3, inj_q3
);

    wire clk   = s_axi_aclk;
    wire rst_n = s_axi_aresetn;

    // =========================================================================
    // AXI write channel
    // =========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr_lat;
    reg [C_S_AXI_DATA_WIDTH-1:0] w_data_lat;
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
            if (s_axi_arvalid && !s_axi_rvalid && !do_read) begin
                rd_addr       <= s_axi_araddr;
                do_read       <= 1'b1;
                s_axi_arready <= 1'b1;
            end
            /* Let the register-file process consume do_read before RVALID is
             * asserted.  This guarantees that RDATA is stable for the master,
             * rather than returning the preceding register's value. */
            if (do_read) begin
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
                do_read       <= 1'b0;
            end
            else if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Registers
    // =========================================================================
    reg        ctrl_inj_en;               // 0x00[0], live FIFO mode only
    reg [31:0] inj_period_reg;            // 0x10, default 64
    reg [31:0] inj_lo_stage;              // 0x08 staging

    reg        underrun_sticky;

    localparam [7:0] ADDR_CTRL       = 8'h00;
    localparam [7:0] ADDR_STATUS     = 8'h04;
    localparam [7:0] ADDR_INJ_LO     = 8'h08;
    localparam [7:0] ADDR_INJ_HI     = 8'h0C;
    localparam [7:0] ADDR_INJ_PERIOD = 8'h10;
    localparam [7:0] ADDR_CAP_ADDR   = 8'h14;
    localparam [7:0] ADDR_CAP_DATA   = 8'h18;
    localparam [7:0] ADDR_CAP_LENGTH = 8'h1c;
    localparam [7:0] ADDR_REPLAY_CTL = 8'h20;
    localparam [7:0] ADDR_REPLAY_STA = 8'h24;
    localparam [7:0] ADDR_COEFF0     = 8'h30;
    localparam [7:0] ADDR_NOISE0     = 8'h40;
    localparam [7:0] ADDR_NOISE_SEED = 8'h50;

    localparam CAPTURE_DEPTH = 1 << CAPTURE_ADDR_W;
`ifdef SYNTHESIS
    wire [15:0] capture_data_r;
`else
    reg [15:0] capture_mem [0:CAPTURE_DEPTH-1];
    reg [15:0] capture_data_r;
`endif
    reg [CAPTURE_ADDR_W-1:0] capture_addr;
    reg [CAPTURE_ADDR_W:0] capture_length;
    reg replay_active, replay_done, replay_bad_start;
    reg replay_start_req, replay_abort_req;
    reg [CAPTURE_ADDR_W:0] replay_index;
    reg signed [15:0] coeff_i [0:3];
    reg signed [15:0] coeff_q [0:3];
    reg [7:0] noise_scale [0:3];
    reg [15:0] noise_seed;
    reg [15:0] lfsr [0:3];

    function signed [7:0] approx_gauss;
        input [15:0] s;
        reg [5:0] sum;
        begin
            sum = s[3:0] + s[7:4] + s[11:8] + s[15:12];
            approx_gauss = $signed({1'b0, sum}) - 8'sd30;
        end
    endfunction
    function [15:0] lfsr_next;
        input [15:0] s;
        begin lfsr_next = {s[14:0], s[15]^s[13]^s[12]^s[10]}; end
    endfunction
    function signed [7:0] sat8;
        input signed [31:0] x;
        begin
            if (x > 127)       sat8 = 8'sd127;
            else if (x < -128) sat8 = -8'sd128;
            else               sat8 = x[7:0];
        end
    endfunction

    // =========================================================================
    // Injection FIFO
    // =========================================================================
    wire [63:0] inj_fifo_wdata = {inj_lo_stage, wr_data};
    reg         inj_fifo_wr_en;
    wire        inj_fifo_full;
    wire [63:0] inj_fifo_rdata;
    wire        inj_fifo_empty;
    reg         inj_pop;

    sync_fifo #(.DATA_W(64), .ADDR_W(8)) u_inj_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (inj_fifo_wr_en),
        .wr_data (inj_fifo_wdata),
        .full    (inj_fifo_full),
        .rd_en   (inj_pop),
        .rd_data (inj_fifo_rdata),
        .empty   (inj_fifo_empty),
        .half    ()
    );

    always @(*) begin
        inj_fifo_wr_en = 1'b0;
        if (do_write && wr_addr == ADDR_INJ_HI) inj_fifo_wr_en = 1'b1;
    end

    // =========================================================================
    // Register writes
    // =========================================================================
    integer ci;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_inj_en    <= 1'b0;
            inj_period_reg <= 32'd64;
            inj_lo_stage   <= 32'd0;
            capture_addr <= 0;
            capture_length <= 0;
            replay_start_req <= 1'b0;
            replay_abort_req <= 1'b0;
            noise_seed <= 16'h1;
            for (ci = 0; ci < 4; ci = ci + 1) begin
                coeff_i[ci] <= 16'sh7fff;
                coeff_q[ci] <= 16'sh0000;
                noise_scale[ci] <= 0;
            end
        end else begin
            replay_start_req <= 1'b0;
            replay_abort_req <= 1'b0;
            if (do_write) case (wr_addr)
                ADDR_CTRL:       ctrl_inj_en    <= wr_data[0];
                ADDR_INJ_LO:     inj_lo_stage   <= wr_data;
                ADDR_INJ_PERIOD: inj_period_reg <= wr_data;
                ADDR_CAP_ADDR:   capture_addr <= wr_data[CAPTURE_ADDR_W-1:0];
                ADDR_CAP_DATA: begin
                    capture_addr <= capture_addr + 1'b1;
                end
                ADDR_CAP_LENGTH: capture_length <= (wr_data > CAPTURE_DEPTH) ? CAPTURE_DEPTH : wr_data[CAPTURE_ADDR_W:0];
                ADDR_REPLAY_CTL: begin
                    replay_start_req <= wr_data[0];
                    replay_abort_req <= wr_data[1];
                end
                ADDR_NOISE_SEED: noise_seed <= wr_data[15:0];
                ADDR_COEFF0: begin coeff_i[0] <= wr_data[31:16]; coeff_q[0] <= wr_data[15:0]; end
                ADDR_COEFF0+4: begin coeff_i[1] <= wr_data[31:16]; coeff_q[1] <= wr_data[15:0]; end
                ADDR_COEFF0+8: begin coeff_i[2] <= wr_data[31:16]; coeff_q[2] <= wr_data[15:0]; end
                ADDR_COEFF0+12: begin coeff_i[3] <= wr_data[31:16]; coeff_q[3] <= wr_data[15:0]; end
                ADDR_NOISE0: noise_scale[0] <= wr_data[7:0];
                ADDR_NOISE0+4: noise_scale[1] <= wr_data[7:0];
                ADDR_NOISE0+8: noise_scale[2] <= wr_data[7:0];
                ADDR_NOISE0+12: noise_scale[3] <= wr_data[7:0];
                default: ;
            endcase
        end
    end

    // Explicit XPM RAM gives a genuine Artix BRAM implementation.  Vivado's
    // inference engine otherwise maps this common-clock, 16k x 16 dual-port
    // pattern into distributed RAM.  Keep a behavioural array for Verilator.
`ifdef SYNTHESIS
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(CAPTURE_ADDR_W), .ADDR_WIDTH_B(CAPTURE_ADDR_W),
        .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(16),
        .CLOCKING_MODE("common_clock"), .ECC_MODE("no_ecc"),
        .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(CAPTURE_DEPTH * 16), .MESSAGE_CONTROL(0),
        .READ_DATA_WIDTH_B(16), .READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"), .RST_MODE_A("SYNC"), .RST_MODE_B("SYNC"),
        .USE_EMBEDDED_CONSTRAINT(0), .USE_MEM_INIT(0),
        .WAKEUP_TIME("disable_sleep"), .WRITE_DATA_WIDTH_A(16),
        .WRITE_MODE_B("read_first")
    ) u_capture_bram (
        .clka(clk), .ena(do_write && wr_addr == ADDR_CAP_DATA),
        .wea(1'b1), .addra(capture_addr), .dina(wr_data[15:0]),
        .injectdbiterra(1'b0), .injectsbiterra(1'b0),
        .clkb(clk), .enb(replay_active),
        .addrb(replay_index[CAPTURE_ADDR_W-1:0]), .doutb(capture_data_r),
        .regceb(1'b1), .rstb(1'b0), .sleep(1'b0),
        .dbiterrb(), .sbiterrb()
    );
`else
    always @(posedge clk) begin
        if (do_write && wr_addr == ADDR_CAP_DATA)
            capture_mem[capture_addr] <= wr_data[15:0];
        if (replay_active)
            capture_data_r <= capture_mem[replay_index[CAPTURE_ADDR_W-1:0]];
    end
`endif

    // =========================================================================
    // Rate-matching pacer: pops the FIFO every inj_period_reg dsp_clk cycles
    // =========================================================================
    reg [31:0] pace_timer;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pace_timer <= 32'd0;
            inj_pop    <= 1'b0;
        end else begin
            inj_pop <= 1'b0;
            if (ctrl_inj_en || replay_active) begin
                if (pace_timer >= inj_period_reg - 1) begin
                    pace_timer <= 32'd0;
                    inj_pop    <= 1'b1;
                end else begin
                    pace_timer <= pace_timer + 32'd1;
                end
            end else begin
                pace_timer <= 32'd0;
            end
        end
    end

    reg        inj_valid_r;
    reg signed [7:0] i0_r, q0_r, i1_r, q1_r, i2_r, q2_r, i3_r, q3_r;
    wire signed [7:0] replay_i = capture_data_r[15:8];
    wire signed [7:0] replay_q = capture_data_r[7:0];
    reg signed [31:0] mix_i, mix_q, noise_i, noise_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inj_valid_r <= 1'b0;
            {i0_r,q0_r,i1_r,q1_r,i2_r,q2_r,i3_r,q3_r} <= 64'h0;
            replay_active <= 1'b0;
            replay_done <= 1'b0;
            replay_bad_start <= 1'b0;
            replay_index <= 0;
            for (ci = 0; ci < 4; ci = ci + 1) lfsr[ci] <= 16'h1 + ci;
        end else begin
            inj_valid_r <= 1'b0;
            if (replay_abort_req) replay_active <= 1'b0;
            if (replay_start_req) begin
                replay_done <= 1'b0;
                replay_bad_start <= ctrl_inj_en || (capture_length == 0);
                if (!ctrl_inj_en && capture_length != 0) begin
                    replay_active <= 1'b1;
                    replay_index <= 0;
                    for (ci = 0; ci < 4; ci = ci + 1)
                        lfsr[ci] <= noise_seed ^ (16'h1d0f * (ci + 1));
                end
            end else if (inj_pop) begin
                inj_valid_r <= 1'b1;
                if (replay_active) begin
                    mix_i = replay_i * coeff_i[0] - replay_q * coeff_q[0]; mix_q = replay_i * coeff_q[0] + replay_q * coeff_i[0];
                    noise_i = approx_gauss(lfsr[0]) * $signed({1'b0,noise_scale[0]}); noise_q = approx_gauss({lfsr[0][7:0],lfsr[0][15:8]}) * $signed({1'b0,noise_scale[0]});
                    i0_r <= sat8((mix_i >>> 15) + (noise_i >>> 5)); q0_r <= sat8((mix_q >>> 15) + (noise_q >>> 5));
                    mix_i = replay_i * coeff_i[1] - replay_q * coeff_q[1]; mix_q = replay_i * coeff_q[1] + replay_q * coeff_i[1];
                    noise_i = approx_gauss(lfsr[1]) * $signed({1'b0,noise_scale[1]}); noise_q = approx_gauss({lfsr[1][7:0],lfsr[1][15:8]}) * $signed({1'b0,noise_scale[1]});
                    i1_r <= sat8((mix_i >>> 15) + (noise_i >>> 5)); q1_r <= sat8((mix_q >>> 15) + (noise_q >>> 5));
                    mix_i = replay_i * coeff_i[2] - replay_q * coeff_q[2]; mix_q = replay_i * coeff_q[2] + replay_q * coeff_i[2];
                    noise_i = approx_gauss(lfsr[2]) * $signed({1'b0,noise_scale[2]}); noise_q = approx_gauss({lfsr[2][7:0],lfsr[2][15:8]}) * $signed({1'b0,noise_scale[2]});
                    i2_r <= sat8((mix_i >>> 15) + (noise_i >>> 5)); q2_r <= sat8((mix_q >>> 15) + (noise_q >>> 5));
                    mix_i = replay_i * coeff_i[3] - replay_q * coeff_q[3]; mix_q = replay_i * coeff_q[3] + replay_q * coeff_i[3];
                    noise_i = approx_gauss(lfsr[3]) * $signed({1'b0,noise_scale[3]}); noise_q = approx_gauss({lfsr[3][7:0],lfsr[3][15:8]}) * $signed({1'b0,noise_scale[3]});
                    i3_r <= sat8((mix_i >>> 15) + (noise_i >>> 5)); q3_r <= sat8((mix_q >>> 15) + (noise_q >>> 5));
                    for (ci = 0; ci < 4; ci = ci + 1) lfsr[ci] <= lfsr_next(lfsr[ci]);
                    if (replay_index + 1'b1 >= capture_length) begin
                        replay_active <= 1'b0;
                        replay_done <= 1'b1;
                    end else replay_index <= replay_index + 1'b1;
                end else if (!inj_fifo_empty) begin
                    i0_r <= $signed(inj_fifo_rdata[63:56]);
                    q0_r <= $signed(inj_fifo_rdata[55:48]);
                    i1_r <= $signed(inj_fifo_rdata[47:40]);
                    q1_r <= $signed(inj_fifo_rdata[39:32]);
                    i2_r <= $signed(inj_fifo_rdata[31:24]);
                    q2_r <= $signed(inj_fifo_rdata[23:16]);
                    i3_r <= $signed(inj_fifo_rdata[15:8]);
                    q3_r <= $signed(inj_fifo_rdata[7:0]);
                end else begin
                    {i0_r,q0_r,i1_r,q1_r,i2_r,q2_r,i3_r,q3_r} <= 64'h0;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          underrun_sticky <= 1'b0;
        else if (inj_pop && inj_fifo_empty)   underrun_sticky <= 1'b1;
        else if (do_read && rd_addr == ADDR_STATUS) underrun_sticky <= 1'b0;
    end

    assign inj_en    = ctrl_inj_en | replay_active;
    assign inj_valid = inj_valid_r;
    assign inj_i0 = i0_r; assign inj_q0 = q0_r;
    assign inj_i1 = i1_r; assign inj_q1 = q1_r;
    assign inj_i2 = i2_r; assign inj_q2 = q2_r;
    assign inj_i3 = i3_r; assign inj_q3 = q3_r;

    // =========================================================================
    // Register reads
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_rdata <= 32'd0;
        end else if (do_read) begin
            case (rd_addr)
                ADDR_CTRL:       s_axi_rdata <= {31'd0, ctrl_inj_en};
                ADDR_STATUS:     s_axi_rdata <= {29'd0, underrun_sticky,
                                                  inj_fifo_full, inj_fifo_empty};
                ADDR_INJ_PERIOD: s_axi_rdata <= inj_period_reg;
                ADDR_CAP_ADDR:   s_axi_rdata <= capture_addr;
                ADDR_CAP_LENGTH: s_axi_rdata <= capture_length;
                ADDR_REPLAY_STA: s_axi_rdata <= {28'd0, (capture_length != 0), replay_bad_start, replay_done, replay_active};
                ADDR_NOISE_SEED: s_axi_rdata <= noise_seed;
                ADDR_COEFF0: s_axi_rdata <= {coeff_i[0],coeff_q[0]};
                ADDR_COEFF0+4: s_axi_rdata <= {coeff_i[1],coeff_q[1]};
                ADDR_COEFF0+8: s_axi_rdata <= {coeff_i[2],coeff_q[2]};
                ADDR_COEFF0+12: s_axi_rdata <= {coeff_i[3],coeff_q[3]};
                ADDR_NOISE0: s_axi_rdata <= noise_scale[0];
                ADDR_NOISE0+4: s_axi_rdata <= noise_scale[1];
                ADDR_NOISE0+8: s_axi_rdata <= noise_scale[2];
                ADDR_NOISE0+12: s_axi_rdata <= noise_scale[3];
                default:         s_axi_rdata <= 32'd0;
            endcase
        end
    end

endmodule
`default_nettype wire
