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
//                         (32 MHz / 64 = 500 kHz, matching the decimator's
//                         R=64 output rate that sd_remod expects)

`default_nettype none

module axi_inj_ctrl #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 8
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
    // Registers
    // =========================================================================
    reg        ctrl_inj_en;               // 0x00[0]
    reg [31:0] inj_period_reg;            // 0x10, default 64
    reg [31:0] inj_lo_stage;              // 0x08 staging

    reg        underrun_sticky;

    localparam [7:0] ADDR_CTRL       = 8'h00;
    localparam [7:0] ADDR_STATUS     = 8'h04;
    localparam [7:0] ADDR_INJ_LO     = 8'h08;
    localparam [7:0] ADDR_INJ_HI     = 8'h0C;
    localparam [7:0] ADDR_INJ_PERIOD = 8'h10;

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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_inj_en    <= 1'b0;
            inj_period_reg <= 32'd64;
            inj_lo_stage   <= 32'd0;
        end else if (do_write) begin
            case (wr_addr)
                ADDR_CTRL:       ctrl_inj_en    <= wr_data[0];
                ADDR_INJ_LO:     inj_lo_stage   <= wr_data;
                ADDR_INJ_PERIOD: inj_period_reg <= wr_data;
                default: ;
            endcase
        end
    end

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
            if (ctrl_inj_en) begin
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inj_valid_r <= 1'b0;
            {i0_r,q0_r,i1_r,q1_r,i2_r,q2_r,i3_r,q3_r} <= 64'h0;
        end else begin
            inj_valid_r <= 1'b0;
            if (inj_pop) begin
                inj_valid_r <= 1'b1;
                if (!inj_fifo_empty) begin
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

    assign inj_en    = ctrl_inj_en;
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
                default:         s_axi_rdata <= 32'd0;
            endcase
        end
    end

endmodule
`default_nettype wire
