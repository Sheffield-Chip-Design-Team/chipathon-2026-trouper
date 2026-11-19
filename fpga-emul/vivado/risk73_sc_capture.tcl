# risk73_sc_capture.tcl — arm the RISK73_SC_TRACE ILA on the first dcr_valid
# pulse after a replay is started, to see whether the SC-detector path ever
# sees live samples and reacts at all.
#
# ILA layout (create_project.tcl, RISK73_SC_TRACE=1 branch), sampled at
# dsp_clk (32 MHz), 4096-sample depth = 128 us window:
#   PROBE0 [1 bit]  = dcr_valid (decimator/dc_removal output valid)
#   PROBE1 [32 bits]:
#     [31:16] sc_stat[15:0]      -- live |C[s]|^2 metric
#     [15]    sc_lock
#     [14]    sc_hit_dbg
#     [13]    sc_pipe_active
#     [12]    sc_tdm_busy_dbg
#     [11]    dcr_valid
#     [10]    psram_del_valid
#     [9]     rb_rx_hold
#     [8]     packet_done_pulse
#     [7:0]   reserved (0)

set out_dir "/tmp/risk73_sc_capture"
file mkdir $out_dir

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE "[file normalize [file dirname [info script]]/../vivado_proj/arty_dsp_emul.runs/impl_1/system_wrapper.ltx]" $dev
set_property FULL_PROBES.FILE "[file normalize [file dirname [info script]]/../vivado_proj/arty_dsp_emul.runs/impl_1/system_wrapper.ltx]" $dev
refresh_hw_device -update_hw_probes true $dev

set ila [lindex [get_hw_ilas -of_objects $dev] 0]
puts "Using ILA: $ila"

set probe0 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trigger*"}]
set probe1 [get_hw_probes -of_objects $ila -filter {NAME =~ "*risk72_trace*"}]
puts "probe0=$probe0"
puts "probe1=$probe1"

## dcr_valid (probe0) toggles continuously regardless of replay content --
## not a useful trigger. Trigger instead on sc_stat (probe1[31:16]) ever
## being nonzero, don't-care on the rest of probe1 -- if this never fires,
## that's a direct, decisive answer: the correlator metric never leaves
## zero, at full 32 MHz sample resolution, not just under slow SW polling.
set_property TRIGGER_COMPARE_VALUE {neq32'h0000XXXX} $probe1
set_property CONTROL.TRIGGER_POSITION 32 $ila

run_hw_ila $ila
puts "ILA armed on sc_stat != 0 -- now trigger the replay externally (CMD_START)"
puts "READY_FOR_REPLAY"

wait_on_hw_ila $ila -timeout 30
set status [get_property STATUS.CORE_STATUS $ila]
puts "ila status: $status"
set upload_rc [catch {upload_hw_ila_data $ila} wdata]
if {$upload_rc != 0} {
    puts "upload failed: $wdata"
    exit 1
}
set csv "$out_dir/capture.csv"
write_hw_ila_data -csv_file $csv -force $wdata
puts "CAPTURED -> $csv"
exit 0
