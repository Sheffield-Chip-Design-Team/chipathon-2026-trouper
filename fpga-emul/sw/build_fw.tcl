# build_fw.tcl — xsct script to create BSP and build MicroBlaze firmware
set sw_dir   [file normalize "[file dirname [info script]]"]
set xsa_file "$sw_dir/arty_dsp_emul.xsa"
set ws_dir   "$sw_dir/vitis_ws"

setws $ws_dir

# Create hardware platform from XSA
platform create -name arty_dsp_emul -hw $xsa_file -os standalone -proc microblaze_0
platform write
platform active arty_dsp_emul

# Create standalone BSP domain
domain active {standalone_domain}

# Create application project
app create -name lora_mimo_fw -platform arty_dsp_emul \
    -domain standalone_domain -template "Empty Application(C)"

# Copy source file into application
importsources -name lora_mimo_fw -path $sw_dir/main.c

# Build BSP and application
platform generate
app build -name lora_mimo_fw

set elf "$ws_dir/lora_mimo_fw/Debug/lora_mimo_fw.elf"
if {[file exists $elf]} {
    puts "Build OK: $elf"
    file copy -force $elf "$sw_dir/lora_mimo_fw.elf"
    puts "ELF copied to sw/lora_mimo_fw.elf"
} else {
    puts "ERROR: ELF not found at $elf"
}
