// sram512x8_bb.v — Yosys blackbox stub for gf180mcu_fd_ip_sram__sram512x8m8wm1
// Real macro: ip/gf180mcu_fd_ip_sram. The hard macro has explicit VDD/VSS pins,
// but the PD flow uses this power-pin-free blackbox during synthesis/import.
(* blackbox *)
module gf180mcu_fd_ip_sram__sram512x8m8wm1 (
    input         CLK,
    input         CEN,
    input         GWEN,
    input  [7:0]  WEN,
    input  [8:0]  A,
    input  [7:0]  D,
    output [7:0]  Q
);
endmodule
