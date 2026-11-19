# JB/JC breadboard PSRAM pinout, full drive -- the arty_dsp_emul_extpsram_jball.bit
# configuration (2026-09-28). Pass as PSRAM_PIN_XDC=... to create_project.tcl;
# read after arty_dsp_emul.xdc so these override the JA pins.
set_property PACKAGE_PIN E15  [get_ports {psram_sck}]     ;# PSRAM_SCLK  JB pin 1
set_property PACKAGE_PIN C15  [get_ports {psram_ce_n}]    ;# PSRAM_nCE   JB pin 4
set_property PACKAGE_PIN J17  [get_ports {psram_sio[0]}]  ;# SI  / SIO0  JB pin 7
set_property PACKAGE_PIN K15  [get_ports {psram_sio[1]}]  ;# SO  / SIO1  JB pin 9
set_property PACKAGE_PIN U12  [get_ports {psram_sio[2]}]  ;# SIO2        JC pin 1
set_property PACKAGE_PIN V10  [get_ports {psram_sio[3]}]  ;# SIO3        JC pin 3
set_property SLEW FAST        [get_ports {psram_sck psram_ce_n psram_sio[*]}]
set_property DRIVE 16         [get_ports {psram_sck}]
