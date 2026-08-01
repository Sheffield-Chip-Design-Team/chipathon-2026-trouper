#!/usr/bin/env bash
# Run the MCP collection audit via the homelab SGE scheduler (hqsub), not a
# local `docker run`. Stages the netlist/spef/sdc/tcl onto the synced NFS
# designs tree (they may live anywhere on the host, e.g. a P&R run's output
# under /srv/eda/runs/... which a raw docker run cannot see), submits an
# OpenROAD job under --project lora-mimo, waits for it, then runs the
# Python evidence check locally against the retrieved report.
# Example:
#   run_mcp_audit.sh --stage route --netlist rtl-test/.../trouper_top.nl.v \
#     --spef rtl-test/.../trouper_top.max.spef --liberty /foss/pdks/...lib
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
SGE_USER=${SGE_USER:-timothyn-dev}
DESIGNS="/srv/eda/designs/$SGE_USER/lora-mimo"
STAGE= NETLIST= LIBERTY= SPEF=
UPDATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --stage) STAGE=$2; shift 2;;
        --netlist) NETLIST=$2; shift 2;;
        --liberty) LIBERTY=$2; shift 2;;
        --spef) SPEF=$2; shift 2;;
        --update-baseline) UPDATE=1; shift;;
        *) echo "unknown argument: $1" >&2; exit 2;;
    esac
done
[ "$STAGE" = synth ] || [ "$STAGE" = route ] || { echo "--stage synth|route required" >&2; exit 2; }
[ -n "$NETLIST" ] && [ -n "$LIBERTY" ] || { echo "--netlist and --liberty required" >&2; exit 2; }
[ "$STAGE" = synth ] || [ -n "$SPEF" ] || { echo "--spef required for route" >&2; exit 2; }
[ -n "${HLAB_SGE_URL:-}" ] || { echo "HLAB_SGE_URL must be set (e.g. http://nas.home:4783)" >&2; exit 2; }

STAGE_REL="rtl-test/ol_trouper_top/_mcp_audit_stage_${STAGE}"
STAGE_DIR="$DESIGNS/$STAGE_REL"
mkdir -p "$STAGE_DIR"

stage_file() {
    local dst="$STAGE_DIR/$(basename "$1")"
    cp "$1" "$dst"
    chmod g+w "$dst"
    basename "$1"
}

if [[ "$LIBERTY" == /foss/* ]]; then
    LIB_CONTAINER=$LIBERTY
else
    LIB_CONTAINER="/foss/designs/$STAGE_REL/$(stage_file "$LIBERTY")"
fi
NL_CONTAINER="/foss/designs/$STAGE_REL/$(stage_file "$NETLIST")"
SPEF_CONTAINER=""
[ -z "$SPEF" ] || SPEF_CONTAINER="/foss/designs/$STAGE_REL/$(stage_file "$SPEF")"

# Sync the audit script + SDC too, in case of uncommitted local edits.
cp "$ROOT/rtl-test/ol_trouper_top/mcp_audit.tcl" "$DESIGNS/rtl-test/ol_trouper_top/mcp_audit.tcl"
cp "$ROOT/rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6.sdc" "$DESIGNS/rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6.sdc"
chmod g+w "$DESIGNS/rtl-test/ol_trouper_top/mcp_audit.tcl" "$DESIGNS/rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6.sdc"

JOB_SCRIPT="$STAGE_DIR/run_job.sh"
cat > "$JOB_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT="\${RUN_DIR:-/foss/runs}"
mkdir -p "\$OUT"
export MCP_AUDIT_LIBERTY="$LIB_CONTAINER"
export MCP_AUDIT_TECH_LEF=/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/techlef/gf180mcu_fd_sc_mcu7t5v0__nom.tlef
export MCP_AUDIT_CELL_LEF=/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lef/gf180mcu_fd_sc_mcu7t5v0.lef
export MCP_AUDIT_NETLIST="$NL_CONTAINER"
export MCP_AUDIT_SDC=/foss/designs/rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6.sdc
export MCP_AUDIT_STAGE=$STAGE
export MCP_AUDIT_REPORT="\$OUT/mcp_audit_${STAGE}.evidence"
export MCP_AUDIT_SPEF="$SPEF_CONTAINER"
openroad -exit /foss/designs/rtl-test/ol_trouper_top/mcp_audit.tcl 2>&1 | tee "\$OUT/mcp_audit_${STAGE}.log"
EOF
chmod +x "$JOB_SCRIPT"

JOB_NAME="mcp-audit-${STAGE}-$(date +%Y%m%d-%H%M%S)"
JOB_ID=$(hqsub --name "$JOB_NAME" --cpus 2 --mem 4G --project lora-mimo \
    --snapshot-exclude 'rtl-test/cocotb_trouper_capture/**' \
    --snapshot-exclude 'ip/**' \
    --snapshot-exclude 'cocotb/**' \
    --snapshot-exclude 'fpga-emul/**' \
    --snapshot-exclude 'lora-capture/**' \
    --snapshot-exclude 'characterization/**' \
    --snapshot-exclude 'rtl-test/ol_*/runs/**' \
    "$JOB_SCRIPT" | grep -oP '\d+')
echo "Submitted MCP audit job $JOB_ID ($JOB_NAME)" >&2

hqwait "$JOB_ID"
JOB_JSON=$(hqstat --json --all | python3 -c "
import json,sys
jobs=json.load(sys.stdin)
m=[j for j in jobs if j['id']==$JOB_ID]
print(json.dumps(m[0]) if m else '{}')
")
EXIT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('exit_code'))" "$JOB_JSON")
RUN_HOST_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('run_dir',''))" "$JOB_JSON")

if [ "$EXIT" != "0" ]; then
    echo "MCP audit job $JOB_ID failed (exit=$EXIT) -- stderr:" >&2
    cat "/srv/eda/logs/$SGE_USER/job-$JOB_ID.e" >&2
    exit 1
fi

EVIDENCE_SRC="$RUN_HOST_DIR/mcp_audit_${STAGE}.evidence"
LOG_SRC="$RUN_HOST_DIR/mcp_audit_${STAGE}.log"
EVIDENCE="$ROOT/rtl-test/ol_trouper_top/mcp_audit_${STAGE}.evidence"
LOG="$ROOT/rtl-test/ol_trouper_top/mcp_audit_${STAGE}.evidence.log"
cp "$EVIDENCE_SRC" "$EVIDENCE"
cp "$LOG_SRC" "$LOG"

PYARGS=(--manifest "$ROOT/rtl-test/ol_trouper_top/mcp_audit_manifest.json"
        --evidence "$EVIDENCE" --log "$LOG"
        --baseline "$ROOT/rtl-test/ol_trouper_top/mcp_audit_baseline.json")
[ "$UPDATE" -eq 0 ] || PYARGS+=(--update-baseline)
python3 "$ROOT/rtl-test/scripts/audit_mcp.py" "${PYARGS[@]}"
