// sram1024x8_bb.v — Yosys blackbox stub for gf180mcu_ocd_ip_sram__sram1024x8m8wm1
// CPU SRAM is built from four byte-wide instances of this macro.
(* blackbox *)
module gf180mcu_ocd_ip_sram__sram1024x8m8wm1 (
    input         CLK,
    input         CEN,
    input         GWEN,
    input  [7:0]  WEN,
    input  [9:0]  A,
    input  [7:0]  D,
    output [7:0]  Q
);
endmodule
