# risk72_wvp_capture.tcl -- single-shot capture of the fast CMD_WRITE_VERIFY_PULSE
# path (firmware-internal write+read+compare, no UDP/UART round trip between
# register accesses), which fails far more often than the slow python-driven
# path did. Same write-trace ILA/probes as risk72_write_capture.tcl.

set out_dir "/tmp/risk72_wvp_capture"
file mkdir $out_dir

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set ltx "[file normalize [file dirname [info script]]/../arty_dsp_emul_risk72_writetrace.ltx]"
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set probe0 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trigger*"}]
set probe1 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trace*"}]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $probe0
set_property CONTROL.TRIGGER_POSITION 64 $ila

run_hw_ila $ila
after 100
set rc [catch {exec python3 -c {
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
base = 0x00F800
body = bytes([(base>>16)&0xFF, (base>>8)&0xFF, base&0xFF])
s.sendto(b"CTLR" + bytes([15]) + body, ("192.168.10.2", 5008))
}} pyout]
puts "stimulus rc=$rc $pyout"
wait_on_hw_ila $ila -timeout 5
set upload_rc [catch {upload_hw_ila_data $ila} wdata]
if {$upload_rc != 0} {
    puts "upload failed: $wdata"
    exit 1
}
set csv "$out_dir/wvp_attempt.csv"
write_hw_ila_data -csv_file $csv -force $wdata
puts "CAPTURED -> $csv"
exit 0
