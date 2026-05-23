// picorv32_stub.v  — elaboration-only stub; replaced by upstream picorv32 IP in build
module picorv32 #(
    parameter ENABLE_MUL          = 0,
    parameter ENABLE_DIV          = 0,
    parameter ENABLE_IRQ          = 0,
    parameter ENABLE_REGS_DUALPORT = 0,
    parameter STACKADDR           = 32'hFFFFFFFF
) (
    input  wire        clk,
    input  wire        resetn,
    output wire        mem_valid,
    output wire        mem_instr,
    input  wire        mem_ready,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata,
    input  wire [31:0] irq,
    output wire [31:0] eoi
);
    assign mem_valid = 1'b0;
    assign mem_instr = 1'b0;
    assign mem_addr  = 32'd0;
    assign mem_wdata = 32'd0;
    assign mem_wstrb = 4'd0;
    assign eoi       = 32'd0;
endmodule
