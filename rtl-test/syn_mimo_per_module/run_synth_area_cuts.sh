#!/bin/bash
# Area cut candidates synthesis — three low-effort cuts:
#   1. mrc_combiner Option C: fix post_gain_shift=0 at synthesis time
#      (eliminates 33-bit barrel-shift MUX tree; Option A serialise I/Q deferred)
#   2. energy_meas_coarse: smaller shared-squarer structure
#   3. noise_floor_est_coarse: 17-bit EMA accumulator vs 23-bit original
#
# All configs NR=2 where applicable. AS cells throughout.
set -euo pipefail

RTL=/foss/designs/lora-mimo
RT=$RTL/rtl-test
OUT=$RT/syn_mimo_per_module/out_area_cuts
CORE_LIB=$RTL/ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/gf180mcu_as_sc_mcu7t3v3__tt_025C_3v30.lib

mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== area cuts synth $(date --iso-8601=seconds) ===" | tee "$LOG"

synth_mod() {
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

# ── 1. mrc_combiner baselines + Option C ────────────────────────────────────

# NR=4 baseline (already measured 121k, re-run for consistent cell lib/flow)
synth_mod mrc_nr4_base mrc_combiner "$RT/mrc_combiner.v"

# NR=2 baseline (constant-prop: ant2/3 = 0, already measured 107k)
cat > /tmp/mrc_nr2_base.v << 'EOF'
`timescale 1ns/100ps
module mrc_nr2_base (
    input  wire        clk_16m, rst_n,
    input  wire signed [7:0]  x_i0, x_q0, x_i1, x_q1, x_valid,
    input  wire signed [15:0] W_re0, W_im0, W_re1, W_im1,
    input  wire        W_valid, mode,
    input  wire [1:0]  bypass_ant,
    input  wire [2:0]  post_gain_shift,
    output wire signed [7:0] y_i, y_q,
    output wire        y_valid
);
    mrc_combiner u (
        .clk_16m(clk_16m), .rst_n(rst_n),
        .x_i0(x_i0), .x_q0(x_q0), .x_i1(x_i1), .x_q1(x_q1),
        .x_i2(8'sd0), .x_q2(8'sd0), .x_i3(8'sd0), .x_q3(8'sd0),
        .x_valid(x_valid),
        .W_re0(W_re0), .W_im0(W_im0), .W_re1(W_re1), .W_im1(W_im1),
        .W_re2(16'sd0), .W_im2(16'sd0), .W_re3(16'sd0), .W_im3(16'sd0),
        .W_valid(W_valid), .mode(mode), .bypass_ant(bypass_ant),
        .post_gain_shift(post_gain_shift),
        .y_i(y_i), .y_q(y_q), .y_valid(y_valid)
    );
endmodule
EOF
synth_mod mrc_nr2_base mrc_nr2_base "$RT/mrc_combiner.v" /tmp/mrc_nr2_base.v

# NR=4 + Option C: post_gain_shift fixed at 0 (saves barrel-shift MUX tree)
cat > /tmp/mrc_nr4_optC.v << 'EOF'
`timescale 1ns/100ps
module mrc_nr4_optC (
    input  wire        clk_16m, rst_n,
    input  wire signed [7:0]  x_i0, x_q0, x_i1, x_q1,
    input  wire signed [7:0]  x_i2, x_q2, x_i3, x_q3, x_valid,
    input  wire signed [15:0] W_re0, W_im0, W_re1, W_im1,
    input  wire signed [15:0] W_re2, W_im2, W_re3, W_im3,
    input  wire        W_valid, mode,
    input  wire [1:0]  bypass_ant,
    output wire signed [7:0] y_i, y_q,
    output wire        y_valid
);
    mrc_combiner u (
        .clk_16m(clk_16m), .rst_n(rst_n),
        .x_i0(x_i0), .x_q0(x_q0), .x_i1(x_i1), .x_q1(x_q1),
        .x_i2(x_i2), .x_q2(x_q2), .x_i3(x_i3), .x_q3(x_q3),
        .x_valid(x_valid),
        .W_re0(W_re0), .W_im0(W_im0), .W_re1(W_re1), .W_im1(W_im1),
        .W_re2(W_re2), .W_im2(W_im2), .W_re3(W_re3), .W_im3(W_im3),
        .W_valid(W_valid), .mode(mode), .bypass_ant(bypass_ant),
        .post_gain_shift(3'd0),   // Option C: fixed at synthesis time
        .y_i(y_i), .y_q(y_q), .y_valid(y_valid)
    );
endmodule
EOF
synth_mod mrc_nr4_optC mrc_nr4_optC "$RT/mrc_combiner.v" /tmp/mrc_nr4_optC.v

# NR=2 + Option C
cat > /tmp/mrc_nr2_optC.v << 'EOF'
`timescale 1ns/100ps
module mrc_nr2_optC (
    input  wire        clk_16m, rst_n,
    input  wire signed [7:0]  x_i0, x_q0, x_i1, x_q1, x_valid,
    input  wire signed [15:0] W_re0, W_im0, W_re1, W_im1,
    input  wire        W_valid, mode,
    input  wire [1:0]  bypass_ant,
    output wire signed [7:0] y_i, y_q,
    output wire        y_valid
);
    mrc_combiner u (
        .clk_16m(clk_16m), .rst_n(rst_n),
        .x_i0(x_i0), .x_q0(x_q0), .x_i1(x_i1), .x_q1(x_q1),
        .x_i2(8'sd0), .x_q2(8'sd0), .x_i3(8'sd0), .x_q3(8'sd0),
        .x_valid(x_valid),
        .W_re0(W_re0), .W_im0(W_im0), .W_re1(W_re1), .W_im1(W_im1),
        .W_re2(16'sd0), .W_im2(16'sd0), .W_re3(16'sd0), .W_im3(16'sd0),
        .W_valid(W_valid), .mode(mode), .bypass_ant(bypass_ant),
        .post_gain_shift(3'd0),   // Option C
        .y_i(y_i), .y_q(y_q), .y_valid(y_valid)
    );
endmodule
EOF
synth_mod mrc_nr2_optC mrc_nr2_optC "$RT/mrc_combiner.v" /tmp/mrc_nr2_optC.v

# ── 1b. mrc_combiner_serIQ: NR=4 and NR=2 ──────────────────────────────────

synth_mod mrc_serIQ_nr4 mrc_combiner_serIQ "$RT/mrc_combiner_serIQ.v"

cat > /tmp/mrc_serIQ_nr2.v << 'EOF'
`timescale 1ns/100ps
module mrc_serIQ_nr2 (
    input  wire        clk_16m, rst_n,
    input  wire signed [7:0]  x_i0, x_q0, x_i1, x_q1, x_valid,
    input  wire signed [15:0] W_re0, W_im0, W_re1, W_im1,
    input  wire        W_valid, mode,
    input  wire [1:0]  bypass_ant,
    input  wire [2:0]  post_gain_shift,
    output wire signed [7:0] y_i, y_q,
    output wire        y_valid
);
    mrc_combiner_serIQ u (
        .clk_16m(clk_16m), .rst_n(rst_n),
        .x_i0(x_i0), .x_q0(x_q0), .x_i1(x_i1), .x_q1(x_q1),
        .x_i2(8'sd0), .x_q2(8'sd0), .x_i3(8'sd0), .x_q3(8'sd0),
        .x_valid(x_valid),
        .W_re0(W_re0), .W_im0(W_im0), .W_re1(W_re1), .W_im1(W_im1),
        .W_re2(16'sd0), .W_im2(16'sd0), .W_re3(16'sd0), .W_im3(16'sd0),
        .W_valid(W_valid), .mode(mode), .bypass_ant(bypass_ant),
        .post_gain_shift(post_gain_shift),
        .y_i(y_i), .y_q(y_q), .y_valid(y_valid)
    );
endmodule
EOF
synth_mod mrc_serIQ_nr2 mrc_serIQ_nr2 "$RT/mrc_combiner_serIQ.v" /tmp/mrc_serIQ_nr2.v

# ── 2. energy_meas: baseline vs coarse ──────────────────────────────────────
synth_mod energy_base  energy_meas        "$RT/energy_meas.v"
synth_mod energy_coarse energy_meas_coarse "$RT/energy_meas_coarse.v"

# ── 3. noise_floor_est: baseline vs coarse ──────────────────────────────────
synth_mod nfe_base   noise_floor_est        "$RT/noise_floor_est.v"
synth_mod nfe_coarse noise_floor_est_coarse "$RT/noise_floor_est_coarse.v"

# ── Summary ─────────────────────────────────────────────────────────────────
echo "" | tee -a "$LOG"
echo "=== Summary (AS cells) ===" | tee -a "$LOG"
python3 - <<'PYEOF' 2>/dev/null | tee -a "$LOG"
import re

OUT = "/foss/designs/lora-mimo/rtl-test/syn_mimo_per_module/out_area_cuts"

def area(name):
    try:
        txt = open(f"{OUT}/stat_{name}.txt").read()
        vals = [float(x) for x in re.findall(r'Chip area for \S+ module[^:]*:\s*([\d.]+)', txt)]
        return max(vals) if vals else None
    except FileNotFoundError:
        return None

groups = [
    ("mrc_combiner",     [("mrc_nr4_base",  "NR=4 baseline (4 muls)"),
                           ("mrc_nr4_optC",  "NR=4 + opt-C (fixed gain)"),
                           ("mrc_serIQ_nr4", "NR=4 ser-IQ (2 muls)"),
                           ("mrc_nr2_base",  "NR=2 baseline (4 muls)"),
                           ("mrc_nr2_optC",  "NR=2 + opt-C (fixed gain)"),
                           ("mrc_serIQ_nr2", "NR=2 ser-IQ (2 muls)")]),
    ("energy_meas",      [("energy_base",   "baseline"),
                           ("energy_coarse", "coarse")]),
    ("noise_floor_est",  [("nfe_base",      "baseline"),
                           ("nfe_coarse",    "coarse")]),
]

total_nr2_base = 0; total_nr2_cut = 0
for grp, variants in groups:
    print(f"\n{grp}")
    base_a = None
    for key, label in variants:
        a = area(key)
        if base_a is None: base_a = a
        delta = f"  ({(a-base_a)/base_a*100:+.1f}% vs baseline)" if (a and base_a and a != base_a) else ""
        print(f"  {label:<36} {a:>10,.0f} µm²{delta}" if a else f"  {label:<36} (missing)")

# NR=2 total impact
nr2_mrc_base  = area("mrc_nr2_base")  or 0
nr2_mrc_optC  = area("mrc_nr2_optC")  or 0
e_base        = area("energy_base")   or 0
e_coarse      = area("energy_coarse") or 0
nfe_base      = area("nfe_base")      or 0
nfe_coarse    = area("nfe_coarse")    or 0

print(f"\n--- NR=2 combined saving ---")
mrc_sv  = nr2_mrc_base - nr2_mrc_optC
e_sv    = e_base - e_coarse
nfe_sv  = nfe_base - nfe_coarse          # or nfe_base if fully removed
total_sv = mrc_sv + e_sv + nfe_sv
print(f"  mrc_combiner opt-C:    {mrc_sv:>8,.0f} µm²")
print(f"  energy_meas coarse:    {e_sv:>8,.0f} µm²")
print(f"  nfe coarse:            {nfe_sv:>8,.0f} µm²")
print(f"  nfe fully removed:     {nfe_base:>8,.0f} µm²  (if eliminated entirely)")
print(f"  ─────────────────────────────────────")
print(f"  total (coarse nfe):    {total_sv:>8,.0f} µm²")
print(f"  total (remove nfe):    {mrc_sv+e_sv+nfe_base:>8,.0f} µm²")
PYEOF

echo "=== DONE ===" | tee -a "$LOG"
