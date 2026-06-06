// servile_wrap_4macro.v
// SERV convenience wrapper with shared 4 kB unified SRAM implemented as
// four 1024x8 hard macros. The same byte-wide SRAM address space serves both
// code/data memory and the internal register-file backing store through
// servile_rf_mem_if.

`default_nettype none

module servile_wrap_4macro (
    input  wire        clk_16m,
    input  wire        rst_n,
    input  wire        timer_irq,

    output wire [31:0] WB_ADR,
    output wire [31:0] WB_DAT,
    output wire [3:0]  WB_SEL,
    output wire        WB_WE,
    output wire        WB_STB,
    input  wire [31:0] WB_RDT,
    input  wire        WB_ACK
);

    localparam integer MEM_DEPTH = 4096;
    localparam integer RF_REGS   = 36;
    localparam integer RF_AW     = $clog2(RF_REGS*4);

    wire [RF_AW-1:0] rf_waddr;
    wire [7:0]       rf_wdata;
    wire             rf_wen;
    wire [RF_AW-1:0] rf_raddr;
    wire [7:0]       rf_rdata;
    wire             rf_ren;

    wire [11:0] sram_waddr;
    wire [7:0]  sram_wdata;
    wire        sram_wen;
    wire [11:0] sram_raddr;
    wire [7:0]  sram_rdata;
    wire        sram_ren;

    wire [31:0] wb_mem_adr;
    wire [31:0] wb_mem_dat;
    wire [3:0]  wb_mem_sel;
    wire        wb_mem_we;
    wire        wb_mem_stb;
    wire [31:0] wb_mem_rdt;
    wire        wb_mem_ack;

    servile_rf_mem_if #(
        .depth   (MEM_DEPTH),
        .rf_regs (RF_REGS)
    ) u_rf_mem_if (
        .i_clk       (clk_16m),
        .i_rst       (!rst_n),
        .i_waddr     (rf_waddr),
        .i_wdata     (rf_wdata),
        .i_wen       (rf_wen),
        .i_raddr     (rf_raddr),
        .o_rdata     (rf_rdata),
        .i_ren       (rf_ren),
        .o_sram_waddr(sram_waddr),
        .o_sram_wdata(sram_wdata),
        .o_sram_wen  (sram_wen),
        .o_sram_raddr(sram_raddr),
        .i_sram_rdata(sram_rdata),
        .o_sram_ren  (sram_ren),
        .i_wb_adr    (wb_mem_adr[11:2]),
        .i_wb_stb    (wb_mem_stb),
        .i_wb_we     (wb_mem_we),
        .i_wb_sel    (wb_mem_sel),
        .i_wb_dat    (wb_mem_dat),
        .o_wb_rdt    (wb_mem_rdt),
        .o_wb_ack    (wb_mem_ack)
    );

    servile #(
        .width          (1),
        .reset_pc       (32'h0000_0000),
        .reset_strategy ("MINI"),
        .rf_width       (8),
        .sim            (1'b0),
        .debug          (1'b0),
        .with_c         (1'b0),
        .with_csr       (1'b1),
        .with_mdu       (1'b0)
    ) u_servile (
        .i_clk       (clk_16m),
        .i_rst       (!rst_n),
        .i_timer_irq (timer_irq),
        .o_wb_mem_adr(wb_mem_adr),
        .o_wb_mem_dat(wb_mem_dat),
        .o_wb_mem_sel(wb_mem_sel),
        .o_wb_mem_we (wb_mem_we),
        .o_wb_mem_stb(wb_mem_stb),
        .i_wb_mem_rdt(wb_mem_rdt),
        .i_wb_mem_ack(wb_mem_ack),
        .o_wb_ext_adr(WB_ADR),
        .o_wb_ext_dat(WB_DAT),
        .o_wb_ext_sel(WB_SEL),
        .o_wb_ext_we (WB_WE),
        .o_wb_ext_stb(WB_STB),
        .i_wb_ext_rdt(WB_RDT),
        .i_wb_ext_ack(WB_ACK),
        .o_rf_waddr  (rf_waddr),
        .o_rf_wdata  (rf_wdata),
        .o_rf_wen    (rf_wen),
        .o_rf_raddr  (rf_raddr),
        .o_rf_ren    (rf_ren),
        .i_rf_rdata  (rf_rdata)
    );

    reg [1:0] rbank_sel_q;
    wire [1:0] rbank_sel = sram_ren ? sram_raddr[11:10] : sram_waddr[11:10];
    always @(posedge clk_16m or negedge rst_n) begin
        if (!rst_n)
            rbank_sel_q <= 2'd0;
        else if (sram_ren || sram_wen)
            rbank_sel_q <= rbank_sel;
    end

    wire [9:0] bank_addr = sram_ren ? sram_raddr[9:0] : sram_waddr[9:0];
    wire [7:0] q0, q1, q2, q3;

    wire sel0 = (rbank_sel == 2'd0);
    wire sel1 = (rbank_sel == 2'd1);
    wire sel2 = (rbank_sel == 2'd2);
    wire sel3 = (rbank_sel == 2'd3);

    wire req = sram_ren || sram_wen;

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_mem0 (
        .CLK  (clk_16m),
        .CEN  (!(req && sel0)),
        .GWEN (!sram_wen),
        .WEN  (8'h00),
        .A    (bank_addr),
        .D    (sram_wdata),
        .Q    (q0)
    );
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_mem1 (
        .CLK  (clk_16m),
        .CEN  (!(req && sel1)),
        .GWEN (!sram_wen),
        .WEN  (8'h00),
        .A    (bank_addr),
        .D    (sram_wdata),
        .Q    (q1)
    );
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_mem2 (
        .CLK  (clk_16m),
        .CEN  (!(req && sel2)),
        .GWEN (!sram_wen),
        .WEN  (8'h00),
        .A    (bank_addr),
        .D    (sram_wdata),
        .Q    (q2)
    );
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_mem3 (
        .CLK  (clk_16m),
        .CEN  (!(req && sel3)),
        .GWEN (!sram_wen),
        .WEN  (8'h00),
        .A    (bank_addr),
        .D    (sram_wdata),
        .Q    (q3)
    );

    assign sram_rdata = (rbank_sel_q == 2'd0) ? q0 :
                        (rbank_sel_q == 2'd1) ? q1 :
                        (rbank_sel_q == 2'd2) ? q2 : q3;

endmodule

`default_nettype wire
