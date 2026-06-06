#!/bin/bash
# Standalone synth + OpenSTA of baseline vs comb-chain sd_decimator at the
# 32 MHz SS corner (3.0 V, 125 C). Kill criterion: is the comb-chain WNS
# better than -1 ns? If yes, the stage-drop is timing-viable; if not, drop it.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_sta
TT_LIB=${RTL}/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib
SS_LIB=${RTL}/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__ss_125C_3v00.lib
PERIOD_NS=31.25     # 32 MHz
PERIOD_PS=31250
mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== sd_decimator STA A/B @32MHz SS_125C_3v00 $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

for VARIANT in baseline combchain; do
    if [ "$VARIANT" = "baseline" ]; then
        SRC=${RTL}/rtl-test/sd_decimator.v
        TOP=sd_decimator
    else
        SRC=${RTL}/rtl-test/sd_decimator_combchain.v
        TOP=sd_decimator_combchain
    fi
    YS=$OUT/synth_${VARIANT}.ys
    NETLIST=$OUT/netlist_${VARIANT}.v
    STA=$OUT/sta_${VARIANT}.log

    # Synthesise against the TT lib (ABC delay target = SS-side period to push
    # for fast structures); STA timed at the SS corner below.
    cat > "$YS" <<EOF
read_verilog ${SRC}
hierarchy -top ${TOP}
synth -top ${TOP}
dfflibmap -liberty ${TT_LIB}
abc -liberty ${TT_LIB} -D ${PERIOD_PS}
setundef -zero
opt_clean -purge
write_verilog -noattr ${NETLIST}
EOF
    echo "--- synth ${VARIANT} ---" | tee -a "$LOG"
    yosys -q -s "$YS" 2>&1 | tee -a "$LOG" | tail -3

    echo "--- STA ${VARIANT} @ SS_125C_3v00, ${PERIOD_NS} ns ---" | tee -a "$LOG"
    sta -exit <<EOF 2>&1 | tee "$STA" | tee -a "$LOG"
read_liberty ${SS_LIB}
read_verilog ${NETLIST}
link_design ${TOP}
create_clock -name clk_32m -period ${PERIOD_NS} [get_ports clk_32m]
set_input_delay  -clock clk_32m 0 [all_inputs]
set_output_delay -clock clk_32m 0 [all_outputs]
puts "----- WNS/TNS -----"
report_wns
report_tns
puts "----- worst max path (overall) -----"
report_checks -path_delay max -digits 3
puts "----- worst reg-to-reg -----"
report_checks -path_delay max -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 3
puts "----- area -----"
report_design_area
EOF
done

echo "=== DONE ===" | tee -a "$LOG"
