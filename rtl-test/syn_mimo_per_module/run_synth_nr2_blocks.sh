#!/bin/bash
# Synthesise training_acc, mrc_combiner, weight_gen at NR=2.
# Method: instantiate NR=4 modules with ant2/3 inputs tied to zero;
# Yosys constant-propagation removes the dead datapath (multipliers,
# H/W/Hc registers for antennas 2-3). FSM overhead remains — estimate
# is within ~5% of a true NR=2 rewrite.
# Compares against NR=4 baselines from out_synth_top_flat.
# Cell library: AS cells (same as all other top-level synths).
set -euo pipefail

RTL=/foss/designs/lora-mimo
RT=$RTL/rtl-test
OUT=$RT/syn_mimo_per_module/out_nr2_blocks
CORE_LIB=$RTL/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib

mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== NR=2 block synth $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

synth_block() {
    local NAME=$1; local TOP=$2; shift 2
    local SRCS=("$@")
    local YS=$OUT/synth_${NAME}.ys
    local STAT=$OUT/stat_${NAME}.txt

    {
        for S in "${SRCS[@]}"; do echo "read_verilog $S"; done
        echo "hierarchy -top ${TOP}"
        echo "flatten"          # merge submodules so constant inputs propagate
        echo "synth -top ${TOP}"
        echo "dfflibmap -liberty ${CORE_LIB}"
        echo "abc -liberty ${CORE_LIB}"
        echo "setundef -zero"
        echo "opt_clean -purge"
        echo "tee -o ${STAT} stat -liberty ${CORE_LIB} -top ${TOP}"
    } > "$YS"

    echo "--- synth ${NAME} ---" | tee -a "$LOG"
    yosys -s "$YS" 2>&1 | tee -a "$LOG" | grep -E "Chip area|ERROR" | head -5
}

# ── NR=2 wrappers (inline, written to /tmp) ──────────────────────────────────

cat > /tmp/training_acc_nr2.v << 'EOF'
// training_acc_nr2: NR=4 module with ant2/3 tied to zero for area estimation.
`timescale 1ns/100ps
module training_acc_nr2 (
    input  wire        clk, rst_n, iq_valid,
    input  wire signed [7:0] raw_i0, raw_q0, raw_i1, raw_q1,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire [3:0]  sf,
    input  wire [1:0]  ref_sel,
    output wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1,
    output wire        training_done,
    output wire [9:0]  n_acc
);
    wire signed [31:0] Z_i2_nc, Z_q2_nc, Z_i3_nc, Z_q3_nc;
    training_acc u (
        .clk(clk), .rst_n(rst_n), .iq_valid(iq_valid),
        .raw_i0(raw_i0), .raw_q0(raw_q0),
        .raw_i1(raw_i1), .raw_q1(raw_q1),
        .raw_i2(8'sd0),  .raw_q2(8'sd0),
        .raw_i3(8'sd0),  .raw_q3(8'sd0),
        .sc_lock(sc_lock), .timing_ref(timing_ref),
        .sf(sf), .ref_sel(ref_sel),
        .Z_i0(Z_i0), .Z_q0(Z_q0),
        .Z_i1(Z_i1), .Z_q1(Z_q1),
        .Z_i2(Z_i2_nc), .Z_q2(Z_q2_nc),
        .Z_i3(Z_i3_nc), .Z_q3(Z_q3_nc),
        .training_done(training_done), .n_acc(n_acc)
    );
endmodule
EOF

cat > /tmp/mrc_combiner_nr2.v << 'EOF'
// mrc_combiner_nr2: NR=4 module with ant2/3 tied to zero for area estimation.
`timescale 1ns/100ps
module mrc_combiner_nr2 (
    input  wire        clk_16m, rst_n,
    input  wire signed [7:0]  x_i0, x_q0, x_i1, x_q1,
    input  wire        x_valid,
    input  wire signed [15:0] W_re0, W_im0, W_re1, W_im1,
    input  wire        W_valid, mode,
    input  wire [1:0]  bypass_ant,
    input  wire [2:0]  post_gain_shift,
    output wire signed [7:0] y_i, y_q,
    output wire        y_valid
);
    mrc_combiner u (
        .clk_16m(clk_16m), .rst_n(rst_n),
        .x_i0(x_i0), .x_q0(x_q0),
        .x_i1(x_i1), .x_q1(x_q1),
        .x_i2(8'sd0), .x_q2(8'sd0),
        .x_i3(8'sd0), .x_q3(8'sd0),
        .x_valid(x_valid),
        .W_re0(W_re0), .W_im0(W_im0),
        .W_re1(W_re1), .W_im1(W_im1),
        .W_re2(16'sd0), .W_im2(16'sd0),
        .W_re3(16'sd0), .W_im3(16'sd0),
        .W_valid(W_valid), .mode(mode),
        .bypass_ant(bypass_ant), .post_gain_shift(post_gain_shift),
        .y_i(y_i), .y_q(y_q), .y_valid(y_valid)
    );
endmodule
EOF

cat > /tmp/weight_gen_nr2.v << 'EOF'
// weight_gen_nr2: NR=4 module with ant2/3 tied to zero for area estimation.
`timescale 1ns/100ps
module weight_gen_nr2 (
    input  wire        clk, rst_n, training_done,
    input  wire signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1,
    input  wire [9:0]  n_acc,
    input  wire [3:0]  sf,
    input  wire        wgt_src, wgt_auto_commit,
    input  wire [1:0]  wgt_mode,
    input  wire signed [15:0] cal_re0, cal_im0, cal_re1, cal_im1,
    input  wire signed [15:0] fw_W_re0, fw_W_im0, fw_W_re1, fw_W_im1,
    input  wire        fw_W_commit,
    output wire signed [15:0] W_hw_re0, W_hw_im0, W_hw_re1, W_hw_im1,
    output wire signed [15:0] W_shadow_re0, W_shadow_im0,
    output wire signed [15:0] W_shadow_re1, W_shadow_im1,
    output wire        W_commit, wgen_hw_done, wgen_active,
    output wire [1:0]  wgen_mode_dbg
);
    wire signed [15:0] W_hw_re2_nc, W_hw_im2_nc, W_hw_re3_nc, W_hw_im3_nc;
    wire signed [15:0] W_sh_re2_nc, W_sh_im2_nc, W_sh_re3_nc, W_sh_im3_nc;
    weight_gen u (
        .clk(clk), .rst_n(rst_n), .training_done(training_done),
        .Z_i0(Z_i0), .Z_q0(Z_q0),
        .Z_i1(Z_i1), .Z_q1(Z_q1),
        .Z_i2(32'sd0), .Z_q2(32'sd0),
        .Z_i3(32'sd0), .Z_q3(32'sd0),
        .n_acc(n_acc), .sf(sf),
        .wgt_src(wgt_src), .wgt_auto_commit(wgt_auto_commit),
        .wgt_mode(wgt_mode),
        .antenna_en(4'b0011),   // only ant0/1 active — eliminates ant2/3 branches
        .cal_re0(cal_re0), .cal_im0(cal_im0),
        .cal_re1(cal_re1), .cal_im1(cal_im1),
        .cal_re2(16'sd0),  .cal_im2(16'sd0),
        .cal_re3(16'sd0),  .cal_im3(16'sd0),
        .fw_W_re0(fw_W_re0), .fw_W_im0(fw_W_im0),
        .fw_W_re1(fw_W_re1), .fw_W_im1(fw_W_im1),
        .fw_W_re2(16'sd0),   .fw_W_im2(16'sd0),
        .fw_W_re3(16'sd0),   .fw_W_im3(16'sd0),
        .fw_W_commit(fw_W_commit),
        .W_hw_re0(W_hw_re0), .W_hw_im0(W_hw_im0),
        .W_hw_re1(W_hw_re1), .W_hw_im1(W_hw_im1),
        .W_hw_re2(W_hw_re2_nc), .W_hw_im2(W_hw_im2_nc),
        .W_hw_re3(W_hw_re3_nc), .W_hw_im3(W_hw_im3_nc),
        .W_shadow_re0(W_shadow_re0), .W_shadow_im0(W_shadow_im0),
        .W_shadow_re1(W_shadow_re1), .W_shadow_im1(W_shadow_im1),
        .W_shadow_re2(W_sh_re2_nc),  .W_shadow_im2(W_sh_im2_nc),
        .W_shadow_re3(W_sh_re3_nc),  .W_shadow_im3(W_sh_im3_nc),
        .W_commit(W_commit), .wgen_hw_done(wgen_hw_done),
        .wgen_active(wgen_active), .wgen_mode_dbg(wgen_mode_dbg)
    );
endmodule
EOF

# ── NR=4 baselines ────────────────────────────────────────────────────────────
synth_block training_acc_nr4 training_acc    "$RT/training_acc.v"
synth_block mrc_combiner_nr4 mrc_combiner    "$RT/mrc_combiner.v"
synth_block weight_gen_nr4   weight_gen      "$RT/weight_gen.v"

# ── NR=2 with constant-propagation ───────────────────────────────────────────
synth_block training_acc_nr2 training_acc_nr2  "$RT/training_acc.v"  /tmp/training_acc_nr2.v
synth_block mrc_combiner_nr2 mrc_combiner_nr2  "$RT/mrc_combiner.v"  /tmp/mrc_combiner_nr2.v
synth_block weight_gen_nr2   weight_gen_nr2    "$RT/weight_gen.v"    /tmp/weight_gen_nr2.v

# ── Summary ───────────────────────────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "=== Summary (AS cells) ===" | tee -a "$LOG"

python3 - <<'PYEOF' 2>/dev/null | tee -a "$LOG"
import re

OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_nr2_blocks"

def area(name):
    try:
        txt = open(f"{OUT}/stat_{name}.txt").read()
        vals = [float(x) for x in re.findall(r"Chip area for module .*?:\s*([\d.]+)", txt)]
        return max(vals) if vals else None
    except FileNotFoundError:
        return None

blocks = ["training_acc", "mrc_combiner", "weight_gen"]
print(f"\n{'Block':<20} {'NR=4 (µm²)':>12}  {'NR=2 (µm²)':>12}  {'saving':>8}  {'%':>6}")
print("-" * 66)
for b in blocks:
    n4 = area(f"{b}_nr4"); n2 = area(f"{b}_nr2")
    if n4 and n2:
        sv = n4 - n2
        print(f"  {b:<18} {n4:>12,.0f}  {n2:>12,.0f}  {sv:>8,.0f}  {sv/n4*100:>5.1f}%")
    else:
        print(f"  {b:<18} {'(missing)':>12}  {'(missing)':>12}")

n4t = sum(area(f"{b}_nr4") or 0 for b in blocks)
n2t = sum(area(f"{b}_nr2") or 0 for b in blocks)
print("-" * 66)
print(f"  {'3-block total':<18} {n4t:>12,.0f}  {n2t:>12,.0f}  {n4t-n2t:>8,.0f}  {(n4t-n2t)/n4t*100:>5.1f}%")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
