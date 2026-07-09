// axi_clk_sync_mon.v
// AXI4-Lite peripheral: SX1257 CLK_OUT phase-lock measurement harness.
//
// Purpose (de-risks the single-clock ASIC): the ASIC clocks its whole DSP on
// ONE sample clock (IQ_CLK = an SX1257 CLK_OUT). All four SX1257s share one
// TCXO, so their CLK_OUTs are guaranteed FREQUENCY-locked, but a static
// inter-chip PHASE skew is possible (each chip's /2^n CLK_OUT divider can start
// in a different count; a synchronized RFFE_RST would align them). This block
// lets firmware prove the other CLK_OUTs are locked to the one used as the DSP
// clock, before committing the one-clock design to silicon.
//
// Method: this peripheral runs on dsp_clk (the F4 = CLK_OUT_2 sample clock),
// same domain as fpga_dsp_wrap. The other CLK_OUTs (CLK_OUT_1=F3, CLK_OUT_3=D3,
// CLK_OUT_4=C15->D15) come in as ordinary inputs and are sampled by dsp_clk.
// Two 32 MHz clocks from the same TCXO, sampled one against the other, give a
// STATIC sampled level (0 toggles) when phase-locked; if they are not locked the
// sampled value walks at the beat frequency, producing many toggles. So over a
// fixed window of dsp_clk cycles we count toggles per channel:
//     toggles ~ 0        -> frequency-locked (static phase)  [PASS]
//     toggles large      -> not locked (scales with window)  [FAIL]
// The captured sampled LEVEL is a coarse (1-bit) phase indicator between locked
// channels. For a fine phase magnitude, sweep an IDELAY / MMCM fine phase on the
// dsp_clk and re-measure (future extension; not in this block).
//
// A 2-flop synchronizer per input handles metastability. Note a channel whose
// sampled point sits exactly on the measured clock's edge can toggle from jitter
// even when locked, giving a small (not window-scaled) nonzero count — read a
// handful of counts as "locked but near the sampling edge", not "unlocked".
//
// Clock domain: entirely dsp_clk (== s_axi_aclk). A Vivado AXI clock converter
// bridges the 100 MHz MicroBlaze bus to it, same pattern as axi_inj_ctrl.v.
//
// Register map (byte addresses, 32-bit access):
//   0x00 CTRL    R/W  [0] ARM (write 1: start one measurement window; self-
//                         clearing)  [1] CONTINUOUS (auto-restart each window)
//   0x04 STATUS  RO   [0] DONE (a window finished, results valid)
//                     [1] RUNNING
//                     [8] LEVEL0  [9] LEVEL1  [10] LEVEL2  (last sampled level)
//   0x08 WINDOW  R/W  [4:0] window exponent W; window = 2^W dsp_clk cycles.
//                         default 25 (~1.05 s at 32 MHz). Clamped to [4,31].
//   0x10 TOGGLES0 RO  toggle count for CLK_OUT_1 (F3),  saturating 32-bit
//   0x14 TOGGLES1 RO  toggle count for CLK_OUT_3 (D3)
//   0x18 TOGGLES2 RO  toggle count for CLK_OUT_4 (C15/D15)
//
// Read TOGGLES/LEVEL after DONE. In CONTINUOUS mode results refresh each window;
// for a tear-free read use one-shot (ARM, poll DONE, then read).

`default_nettype none

module axi_clk_sync_mon #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 8,
    parameter integer WIN_DEFAULT = 25
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

    // Measured CLK_OUTs — async inputs, sampled by s_axi_aclk (dsp_clk).
    //   [0] = CLK_OUT_1 (F3), [1] = CLK_OUT_3 (D3), [2] = CLK_OUT_4 (C15/D15)
    input  wire [2:0]                       clk_meas
);

    wire clk   = s_axi_aclk;
    wire rst_n = s_axi_aresetn;

    localparam [7:0] ADDR_CTRL     = 8'h00;
    localparam [7:0] ADDR_STATUS   = 8'h04;
    localparam [7:0] ADDR_WINDOW   = 8'h08;
    localparam [7:0] ADDR_TOGGLES0 = 8'h10;
    localparam [7:0] ADDR_TOGGLES1 = 8'h14;
    localparam [7:0] ADDR_TOGGLES2 = 8'h18;

    // =========================================================================
    // AXI write channel (mirrors axi_inj_ctrl.v)
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
                aw_addr_lat   <= s_axi_awaddr;
                aw_pend       <= 1'b1;
                s_axi_awready <= 1'b1;
            end
            if (s_axi_wvalid && !w_pend) begin
                w_data_lat   <= s_axi_wdata;
                w_pend       <= 1'b1;
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
    // AXI read channel. rdata is a COMBINATIONAL mux of the registered read
    // address (below), so it is valid in the same cycle rvalid is asserted —
    // avoiding the one-cycle-late rdata that a registered-on-do_read mux would
    // produce (which returns the previous transaction's data).
    // =========================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] rd_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b0;
            rd_addr       <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            s_axi_arready <= 1'b0;
            if (s_axi_arvalid && !s_axi_rvalid) begin
                rd_addr       <= s_axi_araddr;
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Control registers
    // =========================================================================
    reg        ctrl_cont;         // 0x00[1]
    reg [4:0]  win_bits;          // 0x08[4:0]
    wire       arm_pulse = do_write && (wr_addr == ADDR_CTRL) && wr_data[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_cont <= 1'b0;
            win_bits  <= WIN_DEFAULT[4:0];
        end else if (do_write) begin
            case (wr_addr)
                ADDR_CTRL:   ctrl_cont <= wr_data[1];
                ADDR_WINDOW: begin
                    // clamp to [4,31] so the window is always a sane length
                    if (wr_data[4:0] < 5'd4) win_bits <= 5'd4;
                    else                     win_bits <= wr_data[4:0];
                end
                default: ;
            endcase
        end
    end

    // =========================================================================
    // Input synchronizers + toggle detect (dsp_clk domain)
    // =========================================================================
    reg [2:0] sync0, sync1, sync1_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync0 <= 3'b0; sync1 <= 3'b0; sync1_d <= 3'b0;
        end else begin
            sync0   <= clk_meas;
            sync1   <= sync0;
            sync1_d <= sync1;
        end
    end
    wire [2:0] tog = sync1 ^ sync1_d;

    // =========================================================================
    // Measurement window + saturating toggle counters
    // =========================================================================
    reg         running, done;
    reg [31:0]  wcount;
    reg [31:0]  cnt0, cnt1, cnt2;             // live counters
    reg [31:0]  tog0_r, tog1_r, tog2_r;       // latched results
    reg [2:0]   level_r;                      // latched sampled levels

    wire [31:0] wmax  = (32'd1 << win_bits) - 32'd1;
    wire        wlast = (wcount == wmax);

    // saturating +tog helper values
    wire [31:0] cnt0_n = (tog[0] && (cnt0 != 32'hFFFFFFFF)) ? cnt0 + 32'd1 : cnt0;
    wire [31:0] cnt1_n = (tog[1] && (cnt1 != 32'hFFFFFFFF)) ? cnt1 + 32'd1 : cnt1;
    wire [31:0] cnt2_n = (tog[2] && (cnt2 != 32'hFFFFFFFF)) ? cnt2 + 32'd1 : cnt2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0; done <= 1'b0; wcount <= 32'd0;
            cnt0 <= 32'd0; cnt1 <= 32'd0; cnt2 <= 32'd0;
            tog0_r <= 32'd0; tog1_r <= 32'd0; tog2_r <= 32'd0;
            level_r <= 3'b0;
        end else begin
            if (!running) begin
                // Start a window on a manual ARM, or auto-restart in continuous
                // mode after the previous window completed.
                if (arm_pulse || (ctrl_cont && done)) begin
                    running <= 1'b1;
                    done    <= 1'b0;
                    wcount  <= 32'd0;
                    cnt0    <= 32'd0; cnt1 <= 32'd0; cnt2 <= 32'd0;
                end
            end else begin
                cnt0 <= cnt0_n; cnt1 <= cnt1_n; cnt2 <= cnt2_n;
                if (wlast) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                    tog0_r  <= cnt0_n; tog1_r <= cnt1_n; tog2_r <= cnt2_n;
                    level_r <= sync1;
                end else begin
                    wcount <= wcount + 32'd1;
                end
            end
        end
    end

    // =========================================================================
    // Register reads — combinational mux on the registered read address.
    // =========================================================================
    always @(*) begin
        case (rd_addr)
            ADDR_CTRL:     s_axi_rdata = {30'd0, ctrl_cont, 1'b0};
            ADDR_STATUS:   s_axi_rdata = {21'd0, level_r, 6'd0, running, done};
            ADDR_WINDOW:   s_axi_rdata = {27'd0, win_bits};
            ADDR_TOGGLES0: s_axi_rdata = tog0_r;
            ADDR_TOGGLES1: s_axi_rdata = tog1_r;
            ADDR_TOGGLES2: s_axi_rdata = tog2_r;
            default:       s_axi_rdata = 32'd0;
        endcase
    end

endmodule
`default_nettype wire
