#!/bin/bash
# Synthesise reg_bank in three configurations:
#   baseline  — current NR=4, hardware weight_gen
#   nr2_hwwgt — NR=2 inputs zeroed, hardware weight_gen control kept
#   nr2_swwgt — NR=2 inputs zeroed, hw weight_gen control ports removed
#
# NR=2 zeroed inputs: z2/z3 readback, energy_2/3, corr_mag_2/3,
#   rx_gain_active_2/3, rx_gain_shadow_2/3, sigma2_hw_2/3.
# sw_wgt removed outputs: wgt_src, wgt_auto_commit, wgt_mode
#   (w_shadow, cal_coeff, w_commit_pulse all stay — firmware still uses them).
# Method: inline wrappers + flatten so Yosys constant-prop removes dead logic.
# Cell library: AS cells.
set -euo pipefail

RTL=/foss/designs/lora-mimo
RT=$RTL/rtl-test
OUT=$RT/syn_mimo_per_module/out_regbank_nr2
CORE_LIB=$RTL/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib

mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== reg_bank NR=2 synth $(date --iso-8601=seconds) ===" | tee "$LOG"

# ── Inline wrapper: NR=2, hardware weight_gen ──────────────────────────────
cat > /tmp/reg_bank_nr2_hwwgt.v << 'VEOF'
`timescale 1ns/100ps
module reg_bank_nr2_hwwgt (
    input  wire        clk, rst_n,
    input  wire [7:0]  addr, wdata,
    input  wire        we, re,
    output wire [7:0]  rdata,
    output wire        ready,
    input  wire [2:0]  gpio_in,
    input  wire [5:0]  cpu_sram_status,
    input  wire [1:0]  buf_mode,
    input  wire        buf_valid, sram0_bist_pass, sram1_bist_pass, buf_freeze,
    input  wire [6:0]  buf_wr_ptr,
    input  wire [7:0]  rx_gain_active_0, rx_gain_active_1,
    input  wire        rx_gain_pending, rx_gain_owner, rx_gain_error,
    input  wire [1:0]  active_mode_rb,
    input  wire [3:0]  active_antenna_en_rb,
    input  wire        packet_active,
    input  wire [2:0]  packet_phase,
    input  wire        training_done_rb, w_pending_rb, w_valid_rb, w_missed_rb,
    input  wire [7:0]  irq_set,
    input  wire [15:0] energy_0, energy_1,
    input  wire [15:0] corr_mag_0, corr_mag_1,
    input  wire [15:0] sc_stat,
    input  wire        training_armed,
    input  wire [9:0]  n_acc,
    input  wire [5:0]  z_shift,
    input  wire [15:0] c_pool_i, c_pool_q, cfo_diag,
    input  wire [31:0] z0_i, z0_q, z1_i, z1_q,
    input  wire        sc_hit_dbg,
    input  wire [1:0]  sc_hit_count_dbg,
    input  wire        sc_lock_dbg,
    input  wire [31:0] sc_first_hit_dbg, sc_lock_snap_dbg,
    input  wire        sram_dump_done,
    input  wire [7:0]  sram_dump_data,
    input  wire        sigma2_valid,
    input  wire [15:0] sigma2_hw_0, sigma2_hw_1,
    input  wire [7:0]  psram_status_rb,
    input  wire [15:0] psram_pkt_bytes,
    input  wire [7:0]  psram_rd_offset,
    output wire        cpu_reset, jtag_en,
    output wire [2:0]  gpio_dir, gpio_out,
    output wire [1:0]  cpu_sram_ctrl,
    output wire [2:0]  tx_ctrl,
    output wire [7:0]  low_bat_thr,
    output wire [1:0]  mimo_mode,
    output wire [3:0]  antenna_en,
    output wire [3:0]  sf_cfg,
    output wire [1:0]  decim_ratio,
    output wire        bist_run,
    output wire [15:0] sc_thr,
    output wire [1:0]  sc_hits_req,
    output wire        energy_gate_en,
    output wire [15:0] energy_thr,
    output wire [7:0]  pkt_timeout_syms,
    output wire [7:0]  rx_gain_shadow_0, rx_gain_shadow_1,
    output wire [7:0]  tx_gain_0, tx_gain_1,
    output wire        rx_gain_commit,
    output wire        wgt_src, wgt_auto_commit,
    output wire [1:0]  wgt_mode,
    output wire        w_commit_pulse,
    output wire [2:0]  comb_post_gain_shift,
    output wire [1:0]  remod_backoff_shift,
    output wire [127:0] w_shadow, cal_coeff,
    output wire [2:0]  psram_ctrl,
    output wire [1:0]  sx_target,
    output wire [6:0]  sx_addr,
    output wire [7:0]  sx_data_wr,
    output wire        sx_rnw, sx_start,
    output wire        sram_dump_start,
    output wire [9:0]  sram_dump_addr,
    output wire        sigma2_src,
    output wire [2:0]  noise_alpha_shift,
    output wire [15:0] noise_thresh,
    output wire        sigma2_commit,
    output wire [63:0] sigma2_sw,
    output wire        noise_en
);
    reg_bank u (
        .clk(clk), .rst_n(rst_n), .addr(addr), .wdata(wdata), .we(we), .re(re),
        .rdata(rdata), .ready(ready),
        .gpio_in(gpio_in), .cpu_sram_status(cpu_sram_status),
        .buf_mode(buf_mode), .buf_valid(buf_valid),
        .sram0_bist_pass(sram0_bist_pass), .sram1_bist_pass(sram1_bist_pass),
        .buf_freeze(buf_freeze), .buf_wr_ptr(buf_wr_ptr),
        .rx_gain_active_0(rx_gain_active_0), .rx_gain_active_1(rx_gain_active_1),
        .rx_gain_active_2(8'h00), .rx_gain_active_3(8'h00),   // NR=2: tied 0
        .rx_gain_pending(rx_gain_pending), .rx_gain_owner(rx_gain_owner),
        .rx_gain_error(rx_gain_error),
        .active_mode_rb(active_mode_rb), .active_antenna_en_rb(active_antenna_en_rb),
        .packet_active(packet_active), .packet_phase(packet_phase),
        .training_done_rb(training_done_rb), .w_pending_rb(w_pending_rb),
        .w_valid_rb(w_valid_rb), .w_missed_rb(w_missed_rb),
        .irq_set(irq_set),
        .energy_0(energy_0), .energy_1(energy_1),
        .energy_2(16'h0), .energy_3(16'h0),                   // NR=2
        .corr_mag_0(corr_mag_0), .corr_mag_1(corr_mag_1),
        .corr_mag_2(16'h0), .corr_mag_3(16'h0),               // NR=2
        .sc_stat(sc_stat), .training_armed(training_armed),
        .n_acc(n_acc), .z_shift(z_shift),
        .c_pool_i(c_pool_i), .c_pool_q(c_pool_q), .cfo_diag(cfo_diag),
        .z0_i(z0_i), .z0_q(z0_q), .z1_i(z1_i), .z1_q(z1_q),
        .z2_i(32'sd0), .z2_q(32'sd0), .z3_i(32'sd0), .z3_q(32'sd0),  // NR=2
        .sc_hit_dbg(sc_hit_dbg), .sc_hit_count_dbg(sc_hit_count_dbg),
        .sc_lock_dbg(sc_lock_dbg), .sc_first_hit_dbg(sc_first_hit_dbg),
        .sc_lock_snap_dbg(sc_lock_snap_dbg),
        .sram_dump_done(sram_dump_done), .sram_dump_data(sram_dump_data),
        .sigma2_valid(sigma2_valid),
        .sigma2_hw_0(sigma2_hw_0), .sigma2_hw_1(sigma2_hw_1),
        .sigma2_hw_2(16'h0), .sigma2_hw_3(16'h0),             // NR=2
        .psram_status_rb(psram_status_rb), .psram_pkt_bytes(psram_pkt_bytes),
        .psram_rd_offset(psram_rd_offset),
        .cpu_reset(cpu_reset), .jtag_en(jtag_en),
        .gpio_dir(gpio_dir), .gpio_out(gpio_out),
        .cpu_sram_ctrl(cpu_sram_ctrl), .tx_ctrl(tx_ctrl), .low_bat_thr(low_bat_thr),
        .mimo_mode(mimo_mode), .antenna_en(antenna_en), .sf_cfg(sf_cfg),
        .decim_ratio(decim_ratio), .bist_run(bist_run),
        .sc_thr(sc_thr), .sc_hits_req(sc_hits_req),
        .energy_gate_en(energy_gate_en), .energy_thr(energy_thr),
        .pkt_timeout_syms(pkt_timeout_syms),
        .rx_gain_shadow_0(rx_gain_shadow_0), .rx_gain_shadow_1(rx_gain_shadow_1),
        .rx_gain_shadow_2(), .rx_gain_shadow_3(),              // NR=2: dropped
        .tx_gain_0(tx_gain_0), .tx_gain_1(tx_gain_1),
        .rx_gain_commit(rx_gain_commit),
        .wgt_src(wgt_src), .wgt_auto_commit(wgt_auto_commit),
        .wgt_mode(wgt_mode), .w_commit_pulse(w_commit_pulse),
        .comb_post_gain_shift(comb_post_gain_shift),
        .remod_backoff_shift(remod_backoff_shift),
        .w_shadow(w_shadow), .cal_coeff(cal_coeff),
        .psram_ctrl(psram_ctrl), .sx_target(sx_target), .sx_addr(sx_addr),
        .sx_data_wr(sx_data_wr), .sx_rnw(sx_rnw), .sx_start(sx_start),
        .sram_dump_start(sram_dump_start), .sram_dump_addr(sram_dump_addr),
        .sigma2_src(sigma2_src), .noise_alpha_shift(noise_alpha_shift),
        .noise_thresh(noise_thresh), .sigma2_commit(sigma2_commit),
        .sigma2_sw(sigma2_sw), .noise_en(noise_en)
    );
endmodule
VEOF

# ── Inline wrapper: NR=2, software weight_gen ─────────────────────────────
# Same as above but wgt_src/wgt_auto_commit/wgt_mode outputs are left open
# (no fanout → Yosys opt_clean removes their source flops)
sed 's/output wire        wgt_src, wgt_auto_commit,/\/\/ wgt_src, wgt_auto_commit removed (sw wgt)/' \
    /tmp/reg_bank_nr2_hwwgt.v | \
sed 's/output wire \[1:0\]  wgt_mode,/\/\/ wgt_mode removed (sw wgt)/' | \
sed 's/module reg_bank_nr2_hwwgt/module reg_bank_nr2_swwgt/' | \
sed 's/\.wgt_src(wgt_src), \.wgt_auto_commit(wgt_auto_commit),/.wgt_src(), .wgt_auto_commit(),/' | \
sed 's/\.wgt_mode(wgt_mode), \.w_commit_pulse(w_commit_pulse),/.wgt_mode(), .w_commit_pulse(w_commit_pulse),/' \
    > /tmp/reg_bank_nr2_swwgt.v

synth_rb() {
    local NAME=$1; local TOP=$2; shift 2
    local SRCS=("$@")
    local YS=$OUT/synth_${NAME}.ys; local STAT=$OUT/stat_${NAME}.txt
    {
        for S in "${SRCS[@]}"; do echo "read_verilog $S"; done
        echo "hierarchy -top ${TOP}"
        echo "flatten"
        echo "synth -top ${TOP}"
        echo "dfflibmap -liberty ${CORE_LIB}"
        echo "abc -liberty ${CORE_LIB}"
        echo "setundef -zero"
        echo "opt_clean -purge"
        echo "tee -o ${STAT} stat -liberty ${CORE_LIB} -top ${TOP}"
    } > "$YS"
    echo "--- synth ${NAME} ---" | tee -a "$LOG"
    yosys -s "$YS" 2>&1 | tee -a "$LOG" | grep -E "Chip area|ERROR" | head -3
}

synth_rb baseline      reg_bank              "$RT/reg_bank.v"
synth_rb nr2_hwwgt     reg_bank_nr2_hwwgt    "$RT/reg_bank.v" /tmp/reg_bank_nr2_hwwgt.v
synth_rb nr2_swwgt     reg_bank_nr2_swwgt    "$RT/reg_bank.v" /tmp/reg_bank_nr2_swwgt.v

echo "" | tee -a "$LOG"
echo "=== Summary (AS cells) ===" | tee -a "$LOG"
python3 - <<'PYEOF' 2>/dev/null | tee -a "$LOG"
import re

OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_regbank_nr2"
def area(name):
    try:
        txt = open(f"{OUT}/stat_{name}.txt").read()
        vals = [float(x) for x in re.findall(r'Chip area for \S+ module[^:]*:\s*([\d.]+)', txt)]
        return max(vals) if vals else None
    except FileNotFoundError:
        return None

configs = [
    ("baseline",   "NR=4, hw weight_gen (current)"),
    ("nr2_hwwgt",  "NR=2, hw weight_gen           "),
    ("nr2_swwgt",  "NR=2, sw weight_gen (wgt regs removed)"),
]
base = area("baseline")
print(f"\n{'Config':<44} {'Area (µm²)':>12}  {'vs baseline':>12}")
print("-" * 72)
for key, label in configs:
    a = area(key)
    delta = f"{(a-base)/base*100:+.1f}%" if (a and base) else "—"
    print(f"  {label}  {a:>12,.0f}  {delta:>12}" if a else f"  {label}  {'(missing)':>12}")
PYEOF
echo "=== DONE ===" | tee -a "$LOG"
