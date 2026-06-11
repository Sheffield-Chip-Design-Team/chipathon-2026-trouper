// Trouper DSP-only stub: replaces the on-chip PicoRV32 for lightweight synthesis and floorplan experiments.
// All AHB-Lite master outputs are tied to IDLE — no CPU transactions.
// fw_ld_ready=1 keeps the SPI slave firmware-load path unblocked.
`default_nettype none
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
    assign HADDR     = 32'b0;
    assign HTRANS    = 2'b00;  // IDLE
    assign HWRITE    = 1'b0;
    assign HSIZE     = 3'b0;
    assign HBURST    = 3'b0;
    assign HWDATA    = 32'b0;
    assign fw_ld_rdata = 8'b0;
    assign fw_ld_ready = 1'b1;
endmodule
`default_nettype wire
