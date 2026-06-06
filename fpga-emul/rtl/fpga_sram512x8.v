// fpga_sram512x8.v
// FPGA BRAM substitute for gf180mcu_ocd_ip_sram__sram512x8m8wm1.
// Provides the identical port interface used by frontend_buf_ctrl so the
// ASIC RTL can be instantiated unmodified on the Arty A7-100T.
//
// Interface semantics (matching the GF180MCU macro):
//   CEN  = active-low chip enable  (1 → device inactive, Q holds)
//   GWEN = active-low global write (0 → write D→mem, 1 → read mem→Q)
//   WEN  = active-low per-bit write mask (always 8'h00 in current design)
//   A    = 9-bit address (512 words)
//   D    = 8-bit data in
//   Q    = 8-bit data out (registered, 1-cycle read latency)
//
// On write:  Q reflects D (write-through to output register).
// On read:   Q is registered mem[A], available next cycle.
// Synthesis: Vivado infers block RAM automatically.

`default_nettype none

module gf180mcu_ocd_ip_sram__sram512x8m8wm1 (
    input  wire       CLK,
    input  wire       CEN,    // active-low chip enable
    input  wire       GWEN,   // active-low global write enable
    input  wire [7:0] WEN,    // active-low per-bit write mask (unused: tied 0)
    input  wire [8:0] A,
    input  wire [7:0] D,
    output reg  [7:0] Q
);
    (* ram_style = "block" *)
    reg [7:0] mem [0:511];

    always @(posedge CLK) begin
        if (!CEN) begin
            if (!GWEN) begin
                // Write: byte-masked by WEN (0 = write that bit)
                // In the current design WEN is always 8'h00 (write all),
                // but implement it generically.
                mem[A] <= (D & ~WEN) | (mem[A] & WEN);
                Q      <= (D & ~WEN) | (mem[A] & WEN);
            end else begin
                Q <= mem[A];
            end
        end
        // CEN=1: device idle, Q unchanged (hold)
    end

endmodule
`default_nettype wire
