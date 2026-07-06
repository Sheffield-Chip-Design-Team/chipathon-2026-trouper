#!/bin/bash
set -euo pipefail
cd /foss/designs/lora-mimo/rtl-test

iverilog -g2005 -o tb_trouper_grp_arb.vvp tb/tb_trouper_grp_arb.v \
    ../src/top/trouper_top.v \
    ../src/decimator/sd_decimator_poly.v \
    ../src/frontend/dc_removal.v \
    ../src/frontend/sc_detector.v \
    ../src/combiner/training_acc.v \
    ../src/control/packet_ctrl_fsm.v \
    ../src/control/psram_buf_ctrl.v \
    ../src/combiner/mrc_combiner.v \
    ../src/remod/sd_remod.v \
    ../src/control/spi_slave.v \
    ../src/control/reg_bank.v

vvp tb_trouper_grp_arb.vvp
