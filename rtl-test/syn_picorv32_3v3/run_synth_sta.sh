#!/bin/bash
# Standalone yosys synthesis + OpenSTA of picorv32_wrap onto a given std-cell
# library. Used to compare the OSU 3.3V-native cells against the stock 5V
# mcu7t5v0 cells run at 3.3V (the underdrive question). SRAM is blackboxed for
# the netlist but its .lib is read for STA so SRAM-touching paths are real.
#
# Usage: run_synth_sta.sh <core_lib> <cell_prefix> <period_ns> <outdir> [sram_lib]
set -euo pipefail
CORE_LIB="$1"; PREFIX="$2"; PERIOD="$3"; OUT="$4"; SRAM_LIB="${5:-}"
PERIOD_PS=$(python3 -c "print(int(float('$PERIOD')*1000))")
RTL=/foss/designs/lora-mimo
mkdir -p "$OUT"

echo "=== yosys synth: lib=$(basename "$CORE_LIB") period=${PERIOD}ns ==="
yosys -q -p "
read_verilog ${RTL}/ip/picorv32/picorv32.v ${RTL}/rtl-test/picorv32_wrap.v ${RTL}/rtl-test/sram1024x8_bb.v
hierarchy -top picorv32_wrap
synth -top picorv32_wrap -flatten
dfflibmap -liberty ${CORE_LIB}
abc -liberty ${CORE_LIB} -D ${PERIOD_PS}
setundef -zero
hilomap -hicell ${PREFIX}__tieh Y -locell ${PREFIX}__tiel Y
splitnets
opt_clean -purge
tee -o ${OUT}/stat.txt stat -liberty ${CORE_LIB}
write_verilog -noattr ${OUT}/netlist.v
"

echo "=== OpenSTA ==="
SRAM_READ=""
[ -n "$SRAM_LIB" ] && SRAM_READ="read_liberty ${SRAM_LIB}"
sta -exit <<EOF 2>&1 | tee ${OUT}/sta.log
read_liberty ${CORE_LIB}
${SRAM_READ}
read_verilog ${OUT}/netlist.v
link_design picorv32_wrap
create_clock -name clk_32m -period ${PERIOD} [get_ports clk_32m]
puts "----- WNS/TNS @ ${PERIOD}ns -----"
report_wns
report_tns
puts "----- worst max path -----"
report_checks -path_delay max -digits 4
puts "----- worst reg-to-reg (exclude IO) -----"
report_checks -path_delay max -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 4
puts "----- area -----"
report_design_area
EOF
echo "=== DONE $(basename "$OUT") ==="
