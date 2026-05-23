// picorv32_wrap_bb.v — synthesis blackbox for picorv32_wrap.
// Prevents the 4 kB CPU SRAM from being synthesised as flip-flops.
// Replace with the real picorv32_wrap.v (or SRAM-macro version) for full synthesis.
(* blackbox *)
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
endmodule
