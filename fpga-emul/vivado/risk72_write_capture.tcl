# risk72_write_capture.tcl — arm the RISK72_ILA core, fire single debug
# write+read attempts via the UDP register-poke path (psram_dbg_single.py),
# and dump BOTH passing and failing captures with maximal pre-trigger
# history, to compare the CE#-idle gap preceding a failing write against a
# passing one (refresh-collision hypothesis).
#
# ILA layout (create_project.tcl, RISK72_ILA=1 branch):
#   PROBE0 [1 bit]  = dbg_mode && qpi_busy   (any debug transaction active)
#   PROBE1 [32 bits]:
#     [31]    ps_sck
#     [30:27] dbg_wbuf[3:0]
#     [26:19] wr_data[7:0]
#     [18:15] ps_sio_in
#     [14:11] ps_sio_out
#     [10]    ps_sio_oe[0]
#     [9]     ps_ce_n
#     [8]     dbg_wr_mode
#     [7]     dbg_mode
#     [6]     qpi_busy
#     [5:0]   sub
# Sampled at 100 MHz (clk_wiz_0/clk_out1), 1024-sample depth = 10.24 us.
# TRIGGER_POSITION near the END of the buffer maximises pre-trigger history
# (~9.4 us / ~4-6 preceding S_WRITE cycles) so we can see the CE#-idle gap
# before the triggering transaction, not just the transaction itself.

set max_attempts 120
set max_fails_to_catch 3
set out_dir "/tmp/risk72_write_capture"
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
if {$ila eq ""} {
    puts "ERROR: no hw_ila found -- is this the RISK72_ILA bitstream?"
    exit 1
}
puts "Using ILA: $ila"

set probe0 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trigger*"}]
set probe1 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trace*"}]
puts "probe0=$probe0"
puts "probe1=$probe1"

set_property TRIGGER_COMPARE_VALUE eq1'b1 $probe0
set_property CONTROL.TRIGGER_POSITION 960 $ila

set n_fail 0
set n_pass_saved 0
for {set i 0} {$i < $max_attempts} {incr i} {
    run_hw_ila $ila
    after 100
    set rc [catch {exec python3 /tmp/psram_dbg_single.py} pyout]
    wait_on_hw_ila $ila -timeout 5
    set upload_rc [catch {upload_hw_ila_data $ila} wdata]
    if {$upload_rc != 0} {
        puts "attempt $i: rc=$rc  $pyout  (upload failed: $wdata)"
        continue
    }
    if {$rc != 0} {
        incr n_fail
        set csv "$out_dir/fail_${n_fail}.csv"
        write_hw_ila_data -csv_file $csv -force $wdata
        puts "attempt $i: FAIL -> $csv   ($pyout)"
        if {$n_fail >= $max_fails_to_catch} { break }
    } elseif {$n_pass_saved < 5} {
        incr n_pass_saved
        set csv "$out_dir/pass_${n_pass_saved}.csv"
        write_hw_ila_data -csv_file $csv -force $wdata
        puts "attempt $i: pass -> $csv (kept for comparison)"
    } else {
        puts "attempt $i: pass (discarded, already have enough pass samples)"
    }
}

puts "Done: $n_fail fail captures, $n_pass_saved pass captures saved in $out_dir"
exit 0
