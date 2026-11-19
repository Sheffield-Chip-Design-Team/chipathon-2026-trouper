# risk72_spi_capture.tcl -- capture the HOST-SPI bus itself (sel_spi_sck,
# sel_spi_mosi, miso_w, sel_host_cs) during a fast-paced CMD_WRITE_VERIFY_PULSE
# burst, sampled at 100MHz (16x oversample of the 6.25MHz host SCK) with a
# 16384-sample depth window (163.84us) -- meant to span the whole ~24-txn
# burst so we can see whether axi_quad_spi_1's FIFO/state machine malforms
# the SPI protocol itself under tight back-to-back pacing.
#
# Trigger: ~sel_host_cs (CS falling edge), captured near the front of the
# window (TRIGGER_POSITION low) so the whole burst plays out post-trigger.

set out_dir "/tmp/risk72_spi_capture"
file mkdir $out_dir

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set ltx "[file normalize [file dirname [info script]]/../arty_dsp_emul_risk72_spitrace.ltx]"
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev

# 2026-09-14 follow-up #2: risk72_trigger is now RTL-wired directly to the
# READ debug op (dbg_mode && !dbg_wr_mode), not ~sel_host_cs -- see
# fpga_dsp_wrap.v. Trigger on that directly; TRIGGER_POSITION=700 keeps
# ~7us of pretrigger so the RD_TRIG SPI transaction itself is still visible,
# leaving ~15680 samples (~156.8us) post-trigger for the 3 busy-polls + all
# 8 DBG_DATA pops.
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
set csv "$out_dir/spi_attempt.csv"
write_hw_ila_data -csv_file $csv -force $wdata
puts "CAPTURED -> $csv"
exit 0
