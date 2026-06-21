#!/bin/bash
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

RTL=/foss/designs/lora-mimo
OUT=\$RTL/rtl-test/syn_mimo_per_module/out_mimo_tdm_v2
CORE_LIB=\$PDK_ROOT/\$PDK/libs.ref/\$STD_CELL_LIBRARY/lib/\$STD_CELL_LIBRARY\__tt_025C_5v00.lib
mkdir -p "\$OUT"

RT=\$RTL/rtl-test
YS=\$OUT/synth.ys
cat > "\$YS" <<YEOF
read_verilog \$RTL/ip/picorv32/picorv32.v
read_verilog \$RT/rtl/sd_decimator_cic_tdm8.v
read_verilog \$RT/rtl/ahb_lite_bus.v
read_verilog \$RT/rtl/dc_removal.v
read_verilog \$RT/rtl/energy_meas_coarse.v
read_verilog \$RT/rtl/frontend_buf_ctrl.v
read_verilog \$RT/rtl/irq_ctrl.v
read_verilog \$RT/rtl/trouper_top.v
read_verilog \$RT/rtl/mrc_combiner.v
read_verilog \$RT/rtl/packet_ctrl_fsm.v
read_verilog \$RT/rtl/picorv32_wrap.v
read_verilog \$RT/rtl/reg_bank.v
read_verilog \$RT/rtl/sc_detector.v
read_verilog \$RT/rtl/sd_remod.v
read_verilog \$RT/rtl/spi_master.v
read_verilog \$RT/rtl/spi_slave.v
read_verilog \$RT/rtl/training_acc.v
read_verilog \$RT/rtl/weight_gen.v
hierarchy -top trouper_top
synth -top trouper_top
dfflibmap -liberty \$CORE_LIB
abc -liberty \$CORE_LIB
setundef -zero
opt_clean -purge
stat -liberty \$CORE_LIB -top trouper_top
YEOF

yosys -s "\$YS" > "\$OUT/yosys.log" 2>&1
