// picorv32_core.v — thin parameter wrapper for OpenLane.
// Sets integration-spec parameters (MUL=1, DIV=1, IRQ=1) so OpenLane's
// Yosys step picks them up without a custom synth script.

module picorv32_core (
    input         clk,
    input         resetn,
    output        trap,

    output        mem_valid,
    output        mem_instr,
    input         mem_ready,
    output [31:0] mem_addr,
    output [31:0] mem_wdata,
    output [ 3:0] mem_wstrb,
    input  [31:0] mem_rdata,

    output        mem_la_read,
    output        mem_la_write,
    output [31:0] mem_la_addr,
    output [31:0] mem_la_wdata,
    output [ 3:0] mem_la_wstrb,

    output        pcpi_valid,
    output [31:0] pcpi_insn,
    output [31:0] pcpi_rs1,
    output [31:0] pcpi_rs2,
    input         pcpi_wr,
    input  [31:0] pcpi_rd,
    input         pcpi_wait,
    input         pcpi_ready,

    input  [31:0] irq,
    output [31:0] eoi,

    output        trace_valid,
    output [35:0] trace_data
);
    picorv32 #(
        .ENABLE_MUL          (1),
        .ENABLE_FAST_MUL     (0),
        .ENABLE_DIV          (1),
        .ENABLE_IRQ          (1),
        .ENABLE_COUNTERS     (1),
        .ENABLE_REGS_DUALPORT(1),
        .TWO_CYCLE_ALU      (1),
        .TWO_CYCLE_COMPARE  (1)
    ) u_core (.*);

endmodule
