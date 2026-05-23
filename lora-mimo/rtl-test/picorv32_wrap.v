// picorv32_wrap.v
// PicoRV32 RV32IM wrapper with AHB-Lite master port and unified 4 kB CPU SRAM.
//
// Memory map seen by PicoRV32:
//   0x00000–0x00FFF  Unified SRAM (4 kB, text + data + stack)
//   0x10000–0x103FF  AHB-Lite peripheral space (reg bank, SPI master, IRQ ctrl)
//
// The SRAM is a behavioural model here; it is replaced by the
// gf180mcu_ocd_ip_sram macro in the physical implementation.
//
// Firmware is loaded via the fw_ld_* port (from spi_slave) while cpu_reset=1.
// cpu_reset also gates the PicoRV32 reset_n input.
//
// GF180MCU, 3.3V, 32 MHz single clock domain

module picorv32_wrap (
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
    // fw_ld_we is a pulse from the SPI domain; the SRAM is written directly.
    input  wire [11:0] fw_ld_addr,
    input  wire [7:0]  fw_ld_wdata,
    input  wire        fw_ld_we,
    output wire [7:0]  fw_ld_rdata,
    output wire        fw_ld_ready    // always 1 (SRAM write is always ready)
);

    assign fw_ld_ready = 1'b1;

    // -----------------------------------------------------------------------
    // Unified 4 kB CPU SRAM (behavioural; replaced by macro in layout)
    // 4096 bytes = 1024 × 32-bit words
    // -----------------------------------------------------------------------
    reg [7:0] cpu_sram [0:4095];

    assign fw_ld_rdata = cpu_sram[fw_ld_addr];

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

    // PicoRV32 instantiation (external IP; port names from upstream repo)
    picorv32 #(
        .ENABLE_MUL    (1),
        .ENABLE_DIV    (1),
        .ENABLE_IRQ    (1),
        .ENABLE_REGS_DUALPORT (1),
        .STACKADDR     (32'h00001000)   // stack top = end of 4 kB SRAM
    ) u_cpu (
        .clk           (clk_32m),
        .resetn        (!cpu_reset && rst_n),
        .mem_valid     (mem_valid),
        .mem_instr     (mem_instr),
        .mem_ready     (mem_ready),
        .mem_addr      (mem_addr),
        .mem_wdata     (mem_wdata),
        .mem_wstrb     (mem_wstrb),
        .mem_rdata     (mem_rdata),
        .irq           (irq),
        .eoi           ()
    );

    // -----------------------------------------------------------------------
    // Memory request router: SRAM (0x0000–0x0FFF) vs AHB-Lite peripherals
    // -----------------------------------------------------------------------
    wire addr_is_sram  = (mem_addr[31:12] == 20'd0);         // 0x00000–0x00FFF
    wire addr_is_periph = (mem_addr[31:10] == 22'h40);       // 0x10000–0x103FF

    // -----------------------------------------------------------------------
    // SRAM access (word-wide, 1-cycle; 2-cycle multicycle path for 32 MHz timing)
    // -----------------------------------------------------------------------
    reg sram_valid_r;
    reg [31:0] sram_rdata_r;

    // Word address from byte address (PicoRV32 is byte-addressed, word-aligned)
    wire [9:0]  sram_waddr = mem_addr[11:2];
    wire [11:0] sram_baddr = mem_addr[11:0];

    // Read: 32-bit word assembled from 4 bytes
    wire [31:0] sram_rdata_word = {
        cpu_sram[{sram_waddr, 2'b11}],
        cpu_sram[{sram_waddr, 2'b10}],
        cpu_sram[{sram_waddr, 2'b01}],
        cpu_sram[{sram_waddr, 2'b00}]
    };

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            sram_valid_r  <= 1'b0;
            sram_rdata_r  <= 32'd0;
        end else begin
            sram_valid_r <= mem_valid && addr_is_sram;
            // Firmware-load write (only while cpu_reset=1; CPU held in reset — mutually exclusive with CPU writes)
            if (fw_ld_we && cpu_reset)
                cpu_sram[fw_ld_addr] <= fw_ld_wdata;
            if (mem_valid && addr_is_sram) begin
                sram_rdata_r <= sram_rdata_word;
                // Byte-enable write
                if (mem_wstrb[0]) cpu_sram[{sram_waddr, 2'b00}] <= mem_wdata[7:0];
                if (mem_wstrb[1]) cpu_sram[{sram_waddr, 2'b01}] <= mem_wdata[15:8];
                if (mem_wstrb[2]) cpu_sram[{sram_waddr, 2'b10}] <= mem_wdata[23:16];
                if (mem_wstrb[3]) cpu_sram[{sram_waddr, 2'b11}] <= mem_wdata[31:24];
            end
        end
    end

    // -----------------------------------------------------------------------
    // AHB-Lite master bridge (peripheral accesses)
    // PicoRV32 native interface → AHB-Lite
    // -----------------------------------------------------------------------
    localparam AHB_IDLE = 2'd0;
    localparam AHB_ADDR = 2'd1;   // address phase registered
    localparam AHB_DATA = 2'd2;   // waiting for HREADY

    reg [1:0]  ahb_state;
    reg [31:0] ahb_addr_lat;
    reg        ahb_write_lat;
    reg [31:0] ahb_wdata_lat;
    reg        ahb_valid_r;
    reg [31:0] ahb_rdata_r;

    // AHB-Lite master outputs
    assign HADDR  = (ahb_state == AHB_ADDR || ahb_state == AHB_DATA)
                    ? ahb_addr_lat : 32'd0;
    assign HTRANS = (ahb_state == AHB_ADDR) ? 2'b10 : 2'b00;  // NONSEQ or IDLE
    assign HWRITE = ahb_write_lat;
    assign HSIZE  = 3'b010;    // 32-bit
    assign HBURST = 3'b000;    // SINGLE
    assign HWDATA = ahb_wdata_lat;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            ahb_state    <= AHB_IDLE;
            ahb_addr_lat <= 32'd0;
            ahb_write_lat <= 1'b0;
            ahb_wdata_lat <= 32'd0;
            ahb_valid_r  <= 1'b0;
            ahb_rdata_r  <= 32'd0;
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
                    // Address phase: HTRANS=NONSEQ, HADDR valid
                    // Move to data phase on next cycle
                    ahb_state <= AHB_DATA;
                end

                AHB_DATA: begin
                    // Data phase: wait for HREADY
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
    assign mem_ready = (addr_is_sram   && sram_valid_r) ||
                       (addr_is_periph && ahb_valid_r)  ||
                       (!addr_is_sram && !addr_is_periph && mem_valid);  // unmapped: instant 0

    assign mem_rdata = addr_is_sram   ? sram_rdata_r :
                       addr_is_periph ? ahb_rdata_r  : 32'd0;

endmodule
