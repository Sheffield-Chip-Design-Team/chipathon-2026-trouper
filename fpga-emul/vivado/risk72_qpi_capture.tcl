# risk72_qpi_capture.tcl -- capture psram_buf_ctrl's internal debug-read
# pointer (dbg_idx, dbg_addr_cur) plus the raw QPI SIO pins to the PSRAM
# chip during a live failing CMD_WRITE_VERIFY_PULSE, to see whether the
# debug engine reads the WRONG address (stale/aliased read) or the RIGHT
# address but wrong data comes back over the QPI wires.
#
# Sampled natively at dsp_clk (32 MHz, same domain as ps_sck) -- 16384
# samples = 512us. Trigger: dbg_mode && !dbg_wr_mode (RD_TRIG specifically),
# same as the RISK72_SPI_TRACE variant.

set out_dir "/tmp/risk72_qpi_capture"
file mkdir $out_dir

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set ltx "[file normalize [file dirname [info script]]/../arty_dsp_emul_risk72_qpitrace.ltx]"
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set probe0 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trigger*"}]
set probe1 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trace*"}]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $probe0
set_property CONTROL.TRIGGER_POSITION 700 $ila

run_hw_ila $ila
after 100
set rc [catch {exec python3 -c {
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
base = 0x00F800
body = bytes([(base>>16)&0xFF, (base>>8)&0xFF, base&0xFF])
for _ in range(20):
    s.sendto(b"CTLR" + bytes([15]) + body, ("192.168.10.2", 5008))
    time.sleep(0.1)
}} pyout]
puts "stimulus rc=$rc $pyout"
wait_on_hw_ila $ila -timeout 5
set upload_rc [catch {upload_hw_ila_data $ila} wdata]
if {$upload_rc != 0} {
    puts "upload failed: $wdata"
    exit 1
}
set csv "$out_dir/qpi_attempt.csv"
write_hw_ila_data -csv_file $csv -force $wdata
puts "CAPTURED -> $csv"
exit 0
