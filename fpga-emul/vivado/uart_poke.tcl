# uart_poke.tcl — isolate the UART pin fix from firmware.
# Programs the bitstream, halts the MicroBlaze, then drives the UARTLite TX FIFO
# directly over the debug AXI path. Independent of any ELF.
set bit_file [file normalize "[file dirname [info script]]/../arty_dsp_emul.bit"]

set UART_BASE 0x40600000
set UART_TX   [expr {$UART_BASE + 0x04}]
set UART_STAT [expr {$UART_BASE + 0x08}]
set UART_CTRL [expr {$UART_BASE + 0x0C}]

connect
targets -set -filter {name =~ "xc7a100t*"}
fpga $bit_file
after 5000

targets -set -filter {name =~ "MicroBlaze #0*"}
stop

# Sanity: read UART status (expect TXEMPTY bit). A sane, stable value here means
# the 32 MHz clock, reset fabric, and AXI peripheral bus are all alive.
puts "UART status before reset: [mrd -value $UART_STAT]"
mwr $UART_CTRL 0x03   ;# reset TX+RX FIFOs
mwr $UART_CTRL 0x00
puts "UART status after  reset: [mrd -value $UART_STAT]"

# Transmit a recognisable banner, polling TX-not-full each byte.
set msg "UART-PIN-FIX-OK\r\n"
for {set rep 0} {$rep < 20} {incr rep} {
    foreach ch [split $msg ""] {
        # wait until TX FIFO not full (status bit3)
        set tries 0
        while {([mrd -value $UART_STAT] & 0x08) && $tries < 1000} { incr tries }
        mwr $UART_TX [scan $ch %c]
    }
}
puts "Poke complete: status=[mrd -value $UART_STAT]"
exit
