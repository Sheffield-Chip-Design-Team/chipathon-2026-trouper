// serv_wrap.v
// SERV RV32I wrapper — drop-in replacement for picorv32_wrap.v.
// Uses bit-serial SERV core + 2 kB unified SRAM (2× OCD 1024×8 macros).
// External peripheral bus: Wishbone (SERV native) → AHB-Lite bridge.
// No M extension — firmware must use software mul/div.
//
// Memory map:
//   0x00000–0x007FF  2 kB SRAM (code + data + stack + SERV register file)
//   0x10000–0x103FF  AHB-Lite peripherals
//
// SRAM layout (byte-serial, 8-bit interface):
//   Bank A: bytes 0–1023  (sram_addr[10]=0) → u_sram_A
//   Bank B: bytes 1024–2047 (sram_addr[10]=1) → u_sram_B
//   Top 144 bytes (1904–2047) reserved for SERV register file.
//
// GF180MCU, 3.3V, 32 MHz

module picorv32_wrap (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire        cpu_reset,
    input  wire        irq_in,

    output wire [31:0] HADDR,
    output wire [1:0]  HTRANS,
    output wire        HWRITE,
    output wire [2:0]  HSIZE,
    output wire [2:0]  HBURST,
    output wire [31:0] HWDATA,
    input  wire [31:0] HRDATA,
    input  wire        HREADY,
    input  wire        HRESP,

    input  wire [11:0] fw_ld_addr,
    input  wire [7:0]  fw_ld_wdata,
    input  wire        fw_ld_we,
    output wire [7:0]  fw_ld_rdata,
    output wire        fw_ld_ready
);

    assign fw_ld_ready = 1'b1;

    // -----------------------------------------------------------------------
    // Firmware loader CDC
    // -----------------------------------------------------------------------
    reg        fw_we_sync0, fw_we_sync1, fw_we_sync2;
    reg [11:0] fw_addr_meta, fw_addr_sync;
    reg [7:0]  fw_wdata_meta, fw_wdata_sync;

    wire fw_we_pulse = fw_we_sync1 && !fw_we_sync2;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            fw_we_sync0   <= 1'b0; fw_we_sync1  <= 1'b0; fw_we_sync2  <= 1'b0;
            fw_addr_meta  <= 12'd0; fw_addr_sync <= 12'd0;
            fw_wdata_meta <= 8'd0;  fw_wdata_sync <= 8'd0;
        end else begin
            fw_we_sync0   <= fw_ld_we;
            fw_we_sync1   <= fw_we_sync0;
            fw_we_sync2   <= fw_we_sync1;
            fw_addr_meta  <= fw_ld_addr;
            fw_addr_sync  <= fw_addr_meta;
            fw_wdata_meta <= fw_ld_wdata;
            fw_wdata_sync <= fw_wdata_meta;
        end
    end

    // -----------------------------------------------------------------------
    // SERV register-file / SRAM mux wires
    // -----------------------------------------------------------------------
    localparam MEM_DEPTH = 2048;
    localparam RF_REGS   = 36;
    localparam RF_AW     = $clog2(RF_REGS * 4);   // = 8

    wire [RF_AW-1:0] rf_waddr, rf_raddr;
    wire [7:0]       rf_wdata, rf_rdata;
    wire             rf_wen,   rf_ren;

    wire [10:0] sram_waddr, sram_raddr;   // 11-bit byte addr in 2 kB
    wire [7:0]  sram_wdata, sram_rdata;
    wire        sram_wen,   sram_ren;

    // Wishbone mem bus (SERV instruction/data → local SRAM)
    wire [31:0] wb_mem_adr, wb_mem_dat, wb_mem_rdt;
    wire [3:0]  wb_mem_sel;
    wire        wb_mem_we, wb_mem_stb, wb_mem_ack;

    // Wishbone ext bus (SERV peripheral access → AHB bridge)
    wire [31:0] wb_ext_adr, wb_ext_dat, wb_ext_rdt;
    wire [3:0]  wb_ext_sel;
    wire        wb_ext_we, wb_ext_stb, wb_ext_ack;

    // -----------------------------------------------------------------------
    // servile_rf_mem_if: multiplexes SERV register file into the SRAM
    // -----------------------------------------------------------------------
    servile_rf_mem_if #(
        .depth   (MEM_DEPTH),
        .rf_regs (RF_REGS)
    ) u_rf_mem_if (
        .i_clk       (clk_32m),
        .i_rst       (!rst_n | cpu_reset),
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
        .i_wb_adr    (wb_mem_adr[10:2]),   // 9-bit word addr within 2 kB
        .i_wb_stb    (wb_mem_stb),
        .i_wb_we     (wb_mem_we),
        .i_wb_sel    (wb_mem_sel),
        .i_wb_dat    (wb_mem_dat),
        .o_wb_rdt    (wb_mem_rdt),
        .o_wb_ack    (wb_mem_ack)
    );

    // -----------------------------------------------------------------------
    // SERV core (bit-serial RV32I)
    // -----------------------------------------------------------------------
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
    ) u_serv (
        .i_clk       (clk_32m),
        .i_rst       (!rst_n | cpu_reset),
        .i_timer_irq (irq_in),
        .o_wb_mem_adr(wb_mem_adr),
        .o_wb_mem_dat(wb_mem_dat),
        .o_wb_mem_sel(wb_mem_sel),
        .o_wb_mem_we (wb_mem_we),
        .o_wb_mem_stb(wb_mem_stb),
        .i_wb_mem_rdt(wb_mem_rdt),
        .i_wb_mem_ack(wb_mem_ack),
        .o_wb_ext_adr(wb_ext_adr),
        .o_wb_ext_dat(wb_ext_dat),
        .o_wb_ext_sel(wb_ext_sel),
        .o_wb_ext_we (wb_ext_we),
        .o_wb_ext_stb(wb_ext_stb),
        .i_wb_ext_rdt(wb_ext_rdt),
        .i_wb_ext_ack(wb_ext_ack),
        .o_rf_waddr  (rf_waddr),
        .o_rf_wdata  (rf_wdata),
        .o_rf_wen    (rf_wen),
        .o_rf_raddr  (rf_raddr),
        .o_rf_ren    (rf_ren),
        .i_rf_rdata  (rf_rdata)
    );

    // -----------------------------------------------------------------------
    // 2× OCD 1024×8 SRAM banks (byte-serial interface)
    //   Bank A: sram_addr[10]=0 → bytes 0–1023
    //   Bank B: sram_addr[10]=1 → bytes 1024–2047
    // -----------------------------------------------------------------------
    wire sram_req    = sram_ren | sram_wen;
    wire sram_bank   = sram_ren ? sram_raddr[10] : sram_waddr[10];
    wire [9:0] sram_baddr = sram_ren ? sram_raddr[9:0] : sram_waddr[9:0];

    // During cpu_reset, firmware loader overrides SRAM controls
    wire [9:0] sram_addr_mux = cpu_reset ? fw_addr_sync[9:0]  : sram_baddr;
    wire       sram_bank_mux = cpu_reset ? fw_addr_sync[10]    : sram_bank;
    wire       sram_wen_mux  = cpu_reset ? fw_we_pulse         : sram_wen;
    wire [7:0] sram_wdat_mux = cpu_reset ? fw_wdata_sync       : sram_wdata;
    wire       sram_active   = cpu_reset ? fw_we_pulse : sram_req;

    reg sram_bank_q;
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) sram_bank_q <= 1'b0;
        else if (sram_active) sram_bank_q <= sram_bank_mux;
    end

    wire [7:0] qA, qB;

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_sram_A (
        .CLK  (clk_32m),
        .CEN  (!(sram_active & ~sram_bank_mux)),
        .GWEN (!sram_wen_mux),
        .WEN  (8'h00),
        .A    (sram_addr_mux),
        .D    (sram_wdat_mux),
        .Q    (qA)
    );

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_sram_B (
        .CLK  (clk_32m),
        .CEN  (!(sram_active & sram_bank_mux)),
        .GWEN (!sram_wen_mux),
        .WEN  (8'h00),
        .A    (sram_addr_mux),
        .D    (sram_wdat_mux),
        .Q    (qB)
    );

    assign sram_rdata  = sram_bank_q ? qB : qA;
    assign fw_ld_rdata = fw_addr_sync[10] ? qB : qA;

    // -----------------------------------------------------------------------
    // Wishbone ext → AHB-Lite bridge
    // -----------------------------------------------------------------------
    localparam AHB_IDLE = 2'd0;
    localparam AHB_ADDR = 2'd1;
    localparam AHB_DATA = 2'd2;

    reg [1:0]  ahb_state;
    reg [31:0] ahb_addr_r;
    reg        ahb_we_r;
    reg [31:0] ahb_wdat_r;
    reg        ahb_valid_r;
    reg [31:0] ahb_rdat_r;

    assign HADDR  = (ahb_state != AHB_IDLE) ? ahb_addr_r : 32'd0;
    assign HTRANS = (ahb_state == AHB_ADDR)  ? 2'b10 : 2'b00;
    assign HWRITE = ahb_we_r;
    assign HSIZE  = 3'b010;
    assign HBURST = 3'b000;
    assign HWDATA = ahb_wdat_r;

    assign wb_ext_rdt = ahb_rdat_r;
    assign wb_ext_ack = ahb_valid_r;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            ahb_state   <= AHB_IDLE;
            ahb_addr_r  <= 32'd0;
            ahb_we_r    <= 1'b0;
            ahb_wdat_r  <= 32'd0;
            ahb_valid_r <= 1'b0;
            ahb_rdat_r  <= 32'd0;
        end else begin
            ahb_valid_r <= 1'b0;
            case (ahb_state)
                AHB_IDLE: begin
                    if (wb_ext_stb) begin
                        ahb_addr_r <= wb_ext_adr;
                        ahb_we_r   <= wb_ext_we;
                        ahb_wdat_r <= wb_ext_dat;
                        ahb_state  <= AHB_ADDR;
                    end
                end
                AHB_ADDR: ahb_state <= AHB_DATA;
                AHB_DATA: begin
                    if (HREADY) begin
                        ahb_rdat_r  <= HRDATA;
                        ahb_valid_r <= 1'b1;
                        ahb_state   <= AHB_IDLE;
                    end
                end
                default: ahb_state <= AHB_IDLE;
            endcase
        end
    end

endmodule
