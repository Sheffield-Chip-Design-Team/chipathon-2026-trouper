// picorv32_wrap.v
// PicoRV32 RV32IM single-port-regfile wrapper with AHB-Lite master port and unified 4 kB CPU SRAM.
//
// Memory map seen by PicoRV32:
//   0x00000–0x00FFF  Unified SRAM (4 kB, text + data + stack)
//   0x10000–0x103FF  AHB-Lite peripheral space (reg bank, SPI master, IRQ ctrl)
//
// The unified SRAM is implemented as four 1024x8 hard macros, one per byte lane.
// Firmware is loaded through the fw_ld_* port while cpu_reset=1, so the SRAM port
// can be borrowed for host access without contending with the CPU.
//
// GF180MCU, 3.3V, 32 MHz single clock domain

module picorv32_wrap_im_sp (
    input  wire        clk_32m,
    input  wire        rst_n,

    // CPU reset (from CPU_RESET register bit [0], active-high)
    input  wire        cpu_reset,

    // IRQ input (from irq_ctrl, level-high)
    input  wire        irq_in,

    // AHB-Lite master output (to ahb_lite_bus)
    output wire [31:0] HADDR,
    output wire [1:0]  HTRANS,
    output wire        HWRITE,
    output wire [2:0]  HSIZE,
    output wire [2:0]  HBURST,
    output wire [31:0] HWDATA,
    input  wire [31:0] HRDATA,
    input  wire        HREADY,
    input  wire        HRESP,

    // Firmware-load port (from spi_slave, byte-wide, SPI clock domain)
    input  wire [11:0] fw_ld_addr,
    input  wire [7:0]  fw_ld_wdata,
    input  wire        fw_ld_we,
    output wire [7:0]  fw_ld_rdata,
    output wire        fw_ld_ready
);

    assign fw_ld_ready = 1'b1;

    // -----------------------------------------------------------------------
    // PicoRV32 native memory interface
    // -----------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    // IRQ vector: map irq_in to IRQ[0] (PicoRV32 IRQ[31:0])
    wire [31:0] irq = {31'd0, irq_in};

    picorv32 #(
        .ENABLE_MUL           (1),
        .ENABLE_DIV           (1),
        .ENABLE_IRQ           (1),
        .ENABLE_REGS_DUALPORT (0),
        .STACKADDR            (32'h00001000)
    ) u_cpu (
        .clk       (clk_32m),
        .resetn    (!cpu_reset && rst_n),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .irq       (irq),
        .eoi       ()
    );

    // -----------------------------------------------------------------------
    // Memory request router: SRAM (0x0000–0x0FFF) vs AHB-Lite peripherals
    // -----------------------------------------------------------------------
    wire addr_is_sram   = (mem_addr[31:12] == 20'd0);
    wire addr_is_periph = (mem_addr[31:10] == 22'h40);

    // -----------------------------------------------------------------------
    // Firmware loader CDC into the 32 MHz domain
    // -----------------------------------------------------------------------
    reg        fw_we_sync0, fw_we_sync1, fw_we_sync2;
    reg [11:0] fw_addr_meta, fw_addr_sync;
    reg [7:0]  fw_wdata_meta, fw_wdata_sync;

    wire fw_we_pulse = fw_we_sync1 && !fw_we_sync2;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            fw_we_sync0   <= 1'b0;
            fw_we_sync1   <= 1'b0;
            fw_we_sync2   <= 1'b0;
            fw_addr_meta  <= 12'd0;
            fw_addr_sync  <= 12'd0;
            fw_wdata_meta <= 8'd0;
            fw_wdata_sync <= 8'd0;
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
    // Unified 4 kB CPU SRAM using four 1024x8 macros
    // -----------------------------------------------------------------------
    wire [9:0] cpu_sram_addr = mem_addr[11:2];
    wire [9:0] fw_sram_addr  = fw_addr_sync[11:2];
    wire [1:0] fw_byte_sel   = fw_addr_sync[1:0];

    wire       cpu_sram_req  = mem_valid && addr_is_sram;
    wire       cpu_sram_wr   = |mem_wstrb;

    wire [9:0] sram_addr = cpu_reset ? fw_sram_addr : cpu_sram_addr;

    wire [7:0] lane0_q, lane1_q, lane2_q, lane3_q;

    wire lane0_cen  = cpu_reset ? 1'b0 : !cpu_sram_req;
    wire lane1_cen  = cpu_reset ? 1'b0 : !cpu_sram_req;
    wire lane2_cen  = cpu_reset ? 1'b0 : !cpu_sram_req;
    wire lane3_cen  = cpu_reset ? 1'b0 : !cpu_sram_req;

    wire lane0_gwen = cpu_reset ? !(fw_we_pulse && (fw_byte_sel == 2'd0)) : !cpu_sram_wr;
    wire lane1_gwen = cpu_reset ? !(fw_we_pulse && (fw_byte_sel == 2'd1)) : !cpu_sram_wr;
    wire lane2_gwen = cpu_reset ? !(fw_we_pulse && (fw_byte_sel == 2'd2)) : !cpu_sram_wr;
    wire lane3_gwen = cpu_reset ? !(fw_we_pulse && (fw_byte_sel == 2'd3)) : !cpu_sram_wr;

    wire [7:0] lane0_wen = cpu_reset
        ? ((fw_we_pulse && (fw_byte_sel == 2'd0)) ? 8'h00 : 8'hFF)
        : (mem_wstrb[0] ? 8'h00 : 8'hFF);
    wire [7:0] lane1_wen = cpu_reset
        ? ((fw_we_pulse && (fw_byte_sel == 2'd1)) ? 8'h00 : 8'hFF)
        : (mem_wstrb[1] ? 8'h00 : 8'hFF);
    wire [7:0] lane2_wen = cpu_reset
        ? ((fw_we_pulse && (fw_byte_sel == 2'd2)) ? 8'h00 : 8'hFF)
        : (mem_wstrb[2] ? 8'h00 : 8'hFF);
    wire [7:0] lane3_wen = cpu_reset
        ? ((fw_we_pulse && (fw_byte_sel == 2'd3)) ? 8'h00 : 8'hFF)
        : (mem_wstrb[3] ? 8'h00 : 8'hFF);

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_cpu_sram_b0 (
        .CLK  (clk_32m),
        .CEN  (lane0_cen),
        .GWEN (lane0_gwen),
        .WEN  (lane0_wen),
        .A    (sram_addr),
        .D    (cpu_reset ? fw_wdata_sync : mem_wdata[7:0]),
        .Q    (lane0_q)
    );

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_cpu_sram_b1 (
        .CLK  (clk_32m),
        .CEN  (lane1_cen),
        .GWEN (lane1_gwen),
        .WEN  (lane1_wen),
        .A    (sram_addr),
        .D    (cpu_reset ? fw_wdata_sync : mem_wdata[15:8]),
        .Q    (lane1_q)
    );

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_cpu_sram_b2 (
        .CLK  (clk_32m),
        .CEN  (lane2_cen),
        .GWEN (lane2_gwen),
        .WEN  (lane2_wen),
        .A    (sram_addr),
        .D    (cpu_reset ? fw_wdata_sync : mem_wdata[23:16]),
        .Q    (lane2_q)
    );

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_cpu_sram_b3 (
        .CLK  (clk_32m),
        .CEN  (lane3_cen),
        .GWEN (lane3_gwen),
        .WEN  (lane3_wen),
        .A    (sram_addr),
        .D    (cpu_reset ? fw_wdata_sync : mem_wdata[31:24]),
        .Q    (lane3_q)
    );

    reg sram_req_r;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            sram_req_r <= 1'b0;
        end else if (cpu_reset) begin
            sram_req_r <= 1'b0;
        end else begin
            sram_req_r <= cpu_sram_req;
        end
    end

    wire [31:0] sram_rdata_word = {lane3_q, lane2_q, lane1_q, lane0_q};

    assign fw_ld_rdata = (fw_byte_sel == 2'd0) ? lane0_q :
                         (fw_byte_sel == 2'd1) ? lane1_q :
                         (fw_byte_sel == 2'd2) ? lane2_q :
                                                 lane3_q;

    // -----------------------------------------------------------------------
    // AHB-Lite master bridge (peripheral accesses)
    // PicoRV32 native interface -> AHB-Lite
    // -----------------------------------------------------------------------
    localparam AHB_IDLE = 2'd0;
    localparam AHB_ADDR = 2'd1;
    localparam AHB_DATA = 2'd2;

    reg [1:0]  ahb_state;
    reg [31:0] ahb_addr_lat;
    reg        ahb_write_lat;
    reg [31:0] ahb_wdata_lat;
    reg        ahb_valid_r;
    reg [31:0] ahb_rdata_r;

    assign HADDR  = (ahb_state == AHB_ADDR || ahb_state == AHB_DATA)
                    ? ahb_addr_lat : 32'd0;
    assign HTRANS = (ahb_state == AHB_ADDR) ? 2'b10 : 2'b00;
    assign HWRITE = ahb_write_lat;
    assign HSIZE  = 3'b010;
    assign HBURST = 3'b000;
    assign HWDATA = ahb_wdata_lat;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            ahb_state     <= AHB_IDLE;
            ahb_addr_lat  <= 32'd0;
            ahb_write_lat <= 1'b0;
            ahb_wdata_lat <= 32'd0;
            ahb_valid_r   <= 1'b0;
            ahb_rdata_r   <= 32'd0;
        end else begin
            ahb_valid_r <= 1'b0;

            case (ahb_state)
                AHB_IDLE: begin
                    if (mem_valid && addr_is_periph) begin
                        ahb_addr_lat  <= mem_addr;
                        ahb_write_lat <= (mem_wstrb != 4'd0);
                        ahb_wdata_lat <= mem_wdata;
                        ahb_state     <= AHB_ADDR;
                    end
                end

                AHB_ADDR: begin
                    ahb_state <= AHB_DATA;
                end

                AHB_DATA: begin
                    if (HREADY) begin
                        ahb_rdata_r <= HRDATA;
                        ahb_valid_r <= 1'b1;
                        ahb_state   <= AHB_IDLE;
                    end
                end

                default: ahb_state <= AHB_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // mem_ready / mem_rdata mux
    // -----------------------------------------------------------------------
    assign mem_ready = (addr_is_sram   && sram_req_r) ||
                       (addr_is_periph && ahb_valid_r) ||
                       (!addr_is_sram && !addr_is_periph && mem_valid);

    assign mem_rdata = addr_is_sram   ? sram_rdata_word :
                       addr_is_periph ? ahb_rdata_r    : 32'd0;

endmodule
