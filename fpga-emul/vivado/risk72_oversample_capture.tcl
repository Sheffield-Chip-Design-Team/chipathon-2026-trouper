# risk72_oversample_capture.tcl -- 200 MHz capture of the QPI pads during ONE
# debug read of a stored `0F 0F ...` line (the 2026-11-18 read-side stuck-high
# fault). Needs arty_dsp_emul_risk72_oversample.bit + its .ltx programmed and the
# firmware running (host link up). Usage:
#   vivado -mode batch -source vivado/risk72_oversample_capture.tcl -tclargs <tag> [<hex addr>]
# Output: tools/risk72_bench/caps/2026-11-18/ila_<tag>.csv; decode with ila_decode.py.
set here  [file normalize [file dirname [info script]]]
set bench "$here/../tools/risk72_bench"
set tag   [expr {[llength $argv] > 0 ? [lindex $argv 0] : "read0F"}]
set addr  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "210000"}]
# optional 3rd arg: the 8-byte line to store, comma-separated hex (default 0F x8)
set pat   [expr {[llength $argv] > 2 ? [lindex $argv 2] : "0F,0F,0F,0F,0F,0F,0F,0F"}]
set out_dir "$bench/caps/2026-11-18"
file mkdir $out_dir
# Vivado's launcher points PYTHONHOME/PYTHONPATH at its bundled Python; clear
# them so /usr/bin/python3 (with pyserial) starts cleanly.
foreach v {PYTHONHOME PYTHONPATH} { catch {unset ::env($v)} }

# 1) store the test line (write path not under test; check the stored image separately), capture ring off
puts [exec /usr/bin/python3 -c "
import sys; sys.path.insert(0, '$bench')
from psr import *
a = 0x$addr
wr(0x70, 0); wr(0x7A, 0)
pwrite(a-8, \[0\]*8); pwrite(a, \[int(x, 16) for x in '$pat'.split(',')\]); pwrite(a+8, \[0\]*8)
setaddr(a)
print('stored line + read address set')
"]

# 2) arm the ILA on the debug-read engine going active
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
# ILA_LTX env override: probe file of the programmed image (default: the working-tree oversample build)
set ltx [expr {[info exists ::env(ILA_LTX)] ? [file normalize $::env(ILA_LTX)] : "$here/../arty_dsp_emul_risk72_oversample.ltx"}]
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set p0 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trigger*"}]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $p0
set_property CONTROL.TRIGGER_POSITION 128 $ila
run_hw_ila $ila
after 200

# 3) fire exactly one debug read (RD_TRIG), then print what firmware read back
puts [exec /usr/bin/python3 -c "
import sys; sys.path.insert(0, '$bench')
from psr import *
wr(0x75, 0x01)
while rd(0x75) & 0x80: pass
print('readback', ' '.join('%02X' % rd(0x76) for _ in range(8)))
"]

wait_on_hw_ila $ila -timeout 5
set wdata [upload_hw_ila_data $ila]
set csv "$out_dir/ila_${tag}.csv"
write_hw_ila_data -csv_file $csv -force $wdata
puts "CAPTURED -> $csv"
close_hw_target
exit
