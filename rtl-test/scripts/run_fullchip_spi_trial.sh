#!/usr/bin/env bash
# Bounded transistor-level whole-core SPI feasibility trial.
# Not padframe signoff: four stand-alone bi_t cells model CS/SCK/MOSI/MISO.
set -euo pipefail

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
export OMP_NUM_THREADS=4

OUT="${RUN_DIR:-/foss/runs}/fullchip_spi_trial"
SIM_TSTEP="${SIM_TSTEP:-1n}"
SIM_TSTOP="${SIM_TSTOP:-25u}"
MEAS_TIME="${MEAS_TIME:-19.80u}"
NGSPICE_TIMEOUT_SECONDS="${NGSPICE_TIMEOUT_SECONDS:-0}"
RUN_XYCE="${RUN_XYCE:-1}"
mkdir -p "$OUT"
CORE=/foss/designs/final/spice/trouper_top.spice
IO=/foss/designs/ip/sscs-chipathon-2026/resources/Integration/Chipathon2025_pads/xschem/gf180mcu_fd_io.spice
SC="$PDK_ROOT/$PDK/libs.ref/$STD_CELL_LIBRARY/spice/$STD_CELL_LIBRARY.spice"
MODEL="$PDK_ROOT/$PDK/libs.tech/ngspice/sm141064.ngspice"
GLOBAL="$PDK_ROOT/$PDK/libs.tech/ngspice/design.ngspice"
DECK="$OUT/trouper_fullchip_spi.sp"

test -r "$CORE"
test -r "$IO"
test -r "$SC"
test -r "$MODEL"
test -r "$GLOBAL"

echo "=== whole-chip SPI transient START $(date --iso-8601=seconds) ==="

# Replace Magic's empty standard-cell declarations with the PDK transistor
# models, retaining only the extracted top-level subcircuit and parasitics.
{
  printf '* full-core SPI transient feasibility trial\n'
  printf '.include %s\n' "$GLOBAL"
  printf '.lib %s typical\n' "$MODEL"
  printf '.lib %s diode_typical\n' "$MODEL"
  printf '.lib %s moscap_typical\n' "$MODEL"
  printf '.lib %s res\n' "$MODEL"
  printf '.lib %s res_statistical_par\n' "$MODEL"
  printf '.lib %s res_statistical\n' "$MODEL"
  # PDK nested .lib resolution does not propagate these into this flattened
  # standalone deck; spell out the nominal no-Monte-Carlo resistor defaults.
  echo '.param rsh_ppolyf_u=350 mc_rsh_ppolyf_u=0 mc_dw_ppolyf_u=0 mc_rt_ppolyf_u=0 res_mc_skew=0 sw_stat_global=0'
  printf '.include %s\n' "$SC"
  printf '.include %s\n' "$IO"
  # Magic's two-terminal physical-only filler/endcap views differ from the
  # four-terminal transistor-library views. They cannot affect SPI function,
  # so omit only these nonfunctional instances from this feasibility deck.
  awk '
    /^\.subckt trouper_top / {emit=1; header=1}
    !emit {next}
    {
      line=$0
      # Ngspice treats square brackets in node names as syntax rather than
      # identifiers.  Magic emits bus ports as e.g. HADDR[0], so make an
      # equivalent, SPICE-safe name throughout this flattened top section.
      gsub(/\[/, "_", line)
      gsub(/\]/, "", line)
    }
    header && /^\+/ {print line; next}
    header {print line; header=0; next}
    /^\+/ {record=record ORS line; next}
    record != "" {if (record !~ /gf180mcu_fd_sc_mcu7t5v0__(fill|fillcap|filltie|endcap)/) print record}
    {record=line}
    END {if (record != "" && record !~ /gf180mcu_fd_sc_mcu7t5v0__(fill|fillcap|filltie|endcap)/) print record}
  ' "$CORE"
} > "$DECK"

# Extract the exact flattened port order from the extracted subcircuit.  The
# source top supplies output directions; all remaining inputs are held low
# unless driven below.  This keeps unrelated receiver/AHB/PSRAM inputs quiet.
awk '
  /^\.subckt trouper_top / {in_hdr=1; line=$0; sub(/^\.subckt trouper_top /,"",line); print line; next}
  in_hdr && /^\+/ {line=$0; sub(/^\+ /,"",line); print line; next}
  in_hdr {exit}
' "$CORE" | tr ' ' '\n' | sed '/^$/d;s/\[/_/g;s/\]//g' > "$OUT/ports.txt"

awk '
  /^[[:space:]]*output wire/ {
    line=$0; sub(/\/\/.*$/, "", line); gsub(/[,;]/, "", line)
    if (match(line, /\[[0-9]+:[0-9]+\]/)) {
      range=substr(line, RSTART+1, RLENGTH-2); split(range,a,":")
      n=split(line,w,/ +/); name=w[n]; gsub(/\[/, "_", name); gsub(/\]/, "", name)
      for (i=a[2]; i<=a[1]; i++) print name "_" i
    } else { n=split(line,w,/ +/); name=w[n]; gsub(/\[/, "_", name); gsub(/\]/, "", name); print name }
  }
' /foss/designs/src/top/trouper_top.v | sort -u > "$OUT/output_ports.txt"

{
  echo '* instantiate the entire extracted core'
  printf 'XUUT'
  while IFS= read -r port; do
    if [ "$port" = VSS ]; then printf ' 0'; else printf ' %s' "$port"; fi
  done < "$OUT/ports.txt"
  echo ' trouper_top'
  echo 'VVDD VDD 0 3.3'
  echo 'VRESET RESETB 0 PWL(0 0 200n 0 201n 3.3 25u 3.3)'
  echo 'VIQCLK IQ_CLK 0 PULSE(0 3.3 0 100p 100p 15.525n 31.25n 26u)'
  echo 'VSPISCK SCK_PAD 0 PULSE(0 3.3 1.25u 1n 1n 249n 500n 22u)'
  echo 'VHOSTCS CS_PAD 0 PWL(0 3.3 1u 3.3 1.001u 0 9u 0 9.001u 3.3 11u 3.3 11.001u 0 20u 0 20.001u 3.3 25u 3.3)'
  # MOSI: write 0x08,0x11 then read command 0x88 plus a dummy byte.
  echo 'VSPIMOSI MOSI_PAD 0 PWL(0 0 1.10u 0 3.10u 3.3 3.35u 0 9.00u 0 11.10u 3.3 11.60u 0 13.10u 3.3 13.35u 0 15.10u 0 20u 0)'
  # Tie only actual primary *inputs* low; outputs remain unforced for MISO
  # observation and avoid loading the core's pad-control outputs.
  idx=0
  while IFS= read -r port; do
    case "$port" in VDD|VSS|RESETB|IQ_CLK|SPI_SCK|SPI_MOSI|HOST_CS) continue;; esac
    if ! grep -Fxq "$port" "$OUT/output_ports.txt"; then
      idx=$((idx+1)); printf 'VQUIET%d %s 0 0\n' "$idx" "$port"
    fi
  done < "$OUT/ports.txt"
  # Individual temporary IO cells.  Their core-side Y terminals connect to
  # the real top-level SPI signals; OE/IE/CS controls use fixed test values.
  # bi_t terminals: A CS DVDD DVSS IE OE PAD PD PDRV0 PDRV1 PU SL VDD VSS Y
  echo 'XCS 0 0 VDD 0 1 0 CS_PAD 0 0 0 0 0 VDD 0 HOST_CS gf180mcu_fd_io__bi_t'
  echo 'XSCK 0 0 VDD 0 1 0 SCK_PAD 0 0 0 0 0 VDD 0 SPI_SCK gf180mcu_fd_io__bi_t'
  echo 'XMOSI 0 0 VDD 0 1 0 MOSI_PAD 0 0 0 0 0 VDD 0 SPI_MOSI gf180mcu_fd_io__bi_t'
  echo 'XMISO SPI_MISO_OUT 0 VDD 0 0 1 MISO_PAD 0 1 0 0 1 VDD 0 MISO_Y gf180mcu_fd_io__bi_t'
  echo 'RMISOLOAD MISO_PAD 0 1Meg'
  echo '.control'
  echo 'set noaskquit'
  echo 'set num_threads=4'
  echo 'save v(SPI_MISO_OUT) v(MISO_PAD) v(SPI_MOSI) v(SPI_SCK) v(HOST_CS)'
  echo "tran $SIM_TSTEP $SIM_TSTOP"
  echo "wrdata $OUT/spi_waveform.dat v(SPI_MISO_OUT) v(MISO_PAD) v(SPI_MOSI) v(SPI_SCK) v(HOST_CS)"
  echo "meas tran miso_final find v(MISO_PAD) at=$MEAS_TIME"
  echo 'quit'
  echo '.endc'
  echo '.end'
} >> "$DECK"

# Create the same circuit and stimuli for Xyce.  Do not reuse the ngspice
# model wrapper: GF180 publishes a separate Xyce wrapper.  The installed
# mcu7t5v0 cell deck uses legacy 05v0 names, so retain the verified aliases
# to the Xyce package's 06v0 primitive wrappers.
XYCE_DECK="$OUT/trouper_fullchip_spi_xyce.cir"
awk '
  /^\.include .*design\.ngspice/ {next}
  /^\.lib .*sm141064\.ngspice/ {next}
  /^\.param rsh_ppolyf_u=/ {next}
  /^\.include .*gf180mcu_fd_sc_mcu7t5v0\/spice\/gf180mcu_fd_sc_mcu7t5v0\.spice/ && !models {
    print ".include /foss/designs/sim/models/gf180_xyce/design.xyce"
    print ".lib /foss/designs/sim/models/gf180_xyce/sm141064.xyce typical"
    print ".lib /foss/designs/sim/models/gf180_xyce/sm141064.xyce diode_typical"
    print ".lib /foss/designs/sim/models/gf180_xyce/sm141064.xyce res_typical"
    print ".lib /foss/designs/sim/models/gf180_xyce/sm141064.xyce moscap_typical"
    print ".subckt nfet_05v0 d g s b params: w=1e-6 l=6e-7 nf=1 m=1"
    print "X0 d g s b nfet_06v0 W={w} L={l} NF={nf} M={m}"
    print ".ends nfet_05v0"
    print ".subckt pfet_05v0 d g s b params: w=1e-6 l=5e-7 nf=1 m=1"
    print "X0 d g s b pfet_06v0 W={w} L={l} NF={nf} M={m}"
    print ".ends pfet_05v0"
    models=1
  }
  /^\.control/{exit}
  {print}
' "$DECK" > "$XYCE_DECK"
{
  echo ".tran $SIM_TSTEP $SIM_TSTOP"
  echo '.print tran format=csv file=spi_waveform_xyce.csv v(SPI_MISO_OUT) v(MISO_PAD) v(SPI_MOSI) v(SPI_SCK) v(HOST_CS)'
  echo '.end'
} >> "$XYCE_DECK"

set +e
if [ "$NGSPICE_TIMEOUT_SECONDS" -gt 0 ]; then
  timeout --signal=TERM --kill-after=30 "$NGSPICE_TIMEOUT_SECONDS" \
    /usr/bin/time -v -o "$OUT/ngspice.time" ngspice -b -o "$OUT/ngspice.log" "$DECK"
else
  /usr/bin/time -v -o "$OUT/ngspice.time" ngspice -b -o "$OUT/ngspice.log" "$DECK"
fi
NG_RC=$?
if [ "$RUN_XYCE" = 1 ]; then
  /usr/bin/time -v -o "$OUT/xyce.time" mpirun -np 4 Xyce -l "$OUT/xyce.log" "$XYCE_DECK"
  XYCE_RC=$?
else
  XYCE_RC=skipped
fi
set -e

printf 'ngspice_rc=%s\nxyce_rc=%s\n' "$NG_RC" "$XYCE_RC" | tee "$OUT/result.txt"
tail -80 "$OUT/ngspice.log" || true
tail -80 "$OUT/xyce.log" || true
echo "=== whole-chip SPI transient COMPLETE $(date --iso-8601=seconds) ==="
