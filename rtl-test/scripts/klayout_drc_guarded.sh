#!/bin/bash
# Guarded KLayout DRC for gf180mcuD.
#
# WHY THIS EXISTS: a KLayout DRC table that crashes still leaves a well-formed,
# EMPTY .lyrdb, which is indistinguishable from a clean table if you only count
# <item> elements. Job 5384 hit exactly that -- the `mslot` table died and
# reported "0 items". Separately, LibreLane's in-flow 67-klayout-drc step is a
# no-op whenever KLAYOUT_DRC_RUNSET is unset (11 ms, no report, no metric), and
# 69-checker-klayoutdrc then PASSES on a metric that was never produced. So:
# counting violations is not verification. This script verifies that every table
# actually RAN, and only then reports counts.
#
# Usage: klayout_drc_guarded.sh <gds> <topcell> [variant]
#   <gds> must be readable inside the container (/foss/designs/... -- note that
#   /srv/eda/runs is NOT mounted there; stage the GDS into the design tree).
#   TABLES="contact metal1"  runs ONLY those tables (run_drc.py --table, which is
#   repeatable). Use it to re-run tables a previous run lost without repeating
#   the 60+ that already completed -- a full run is ~45 min, and `contact` and
#   `metal1` alone are most of it. A subset run is reported as PARTIAL and is
#   NOT a signoff on its own: the guard can only vouch for the tables it ran.
# Exits non-zero if any table failed to run, or if any real violation is found.
#   10 = run incomplete (a table did not run; any violation count is meaningless)
#   11 = the tables that ran had real violations
#    0 = every requested table ran, zero violations (PARTIAL unless TABLES unset)
# The codes are 10/11 rather than 2/3 because low codes collide with the shell's
# own failure exits and cannot be told apart from a guard verdict. Job 5386
# exited 2 from `error reading input file: Stale file handle` -- bash lost the
# script mid-run because it was rsynced over on NFS while the job was executing
# it -- which looked exactly like a clean "run incomplete" verdict. Do not
# overwrite this script on the shared mount while a job is running it; stage a
# copy per job if you need to.
#
# NOTE ON run_drc.py's OWN VERDICT: it prints "Klayout DRC run is clean. GDS has
# no DRC violations." even when a table raised an exception (observed on jobs
# 5384 and 5386, both of which lost `mslot`). That line is not a signoff signal.

set -uo pipefail

GDS=${1:?usage: klayout_drc_guarded.sh <gds> <topcell> [variant]}
TOPCELL=${2:?usage: klayout_drc_guarded.sh <gds> <topcell> [variant]}
VARIANT=${3:-D}          # gf180mcuD = metal_top 11K, mim_option B, 5LM
MP=${MP:-4}              # concurrent tables; each holds the full layout in flat mode
THR=${THR:-4}            # threads per table. MP*THR should not exceed the core count.
TABLES=${TABLES:-}       # optional space-separated subset; empty = the whole deck

# Build the repeatable --table arguments. Held in an array, not a string, so a
# name can never word-split into two flags.
TABLE_ARGS=()
for t in $TABLES; do TABLE_ARGS+=("--table=$t"); done
if [ ${#TABLE_ARGS[@]} -gt 0 ]; then
  echo "== PARTIAL run: ${#TABLE_ARGS[@]} table(s) only: $TABLES =="
fi

PDK_DRC=/foss/pdks/gf180mcuD/libs.tech/klayout/tech/drc
OUT=${RUN_DIR:-/foss/runs}/klayout_drc
DECK=$OUT/deck            # writable, patched copy of the PDK deck
mkdir -p "$OUT" || exit 1

# ---------------------------------------------------------------- deck patch --
# /foss/pdks is read-only, so copy the deck somewhere writable and patch there.
rm -rf "$DECK"; cp -r "$PDK_DRC" "$DECK" || exit 1

# PDK BUG (gf180mcuD, KLayout 0.30.8): rule_decks/layers_def.drc defines each
# layer only when the table being run is on that layer's whitelist, e.g.
#   contact_tables = %w[contact contact_split efuse geom dnwell ... main]
#   if contact_tables.include?(TABLE_NAME)
#     contact = get_polygons(33, 0)
#   end
# "mslot" is on NO whitelist in the whole file, but rule_decks/mslot.drc uses
# contact, via1 and via2 -- so under TABLE_NAME=mslot those three are nil and the
# slotting loop dies on its FIRST iteration (metal1, via_below = contact):
#   NoMethodError: undefined method `sized' for nil:NilClass  (mslot.drc:470)
# Unconditional and geometry-independent; it is NOT resource exhaustion (it
# reproduces running the table alone with the full memory budget, job 5390).
#
# The fix is to whitelist the layers, NOT to nil-guard the uses. Guarding the
# dereference is actively wrong: metal_slotted would then skip subtracting the
# contact/via areas it is supposed to exclude, so MSLOT.1 would check the wrong
# geometry and still report a clean 0. via3/via4 and the metal*_drawn /
# metal*_slot layers are defined ungated, so only these three lists need it.
LDEF=$DECK/rule_decks/layers_def.drc
[ -f "$LDEF" ] || { echo "GUARD FAIL: $LDEF not found (PDK layout changed?)"; exit 1; }
python3 - "$LDEF" <<'PYEOF' || exit 1
import re, sys
p = sys.argv[1]
s = open(p).read()
for wl in ("contact_tables", "via1_tables", "via2_tables"):
    m = re.search(r"(%s\s*=\s*%%w\[)(.*?)(\])" % wl, s, re.S)
    if not m:
        # Fail loudly rather than silently running an unpatched deck: if a PDK
        # update reworks these lists, the crash comes back looking like a 0.
        print("GUARD FAIL: %s whitelist not found in layers_def.drc." % wl)
        sys.exit(1)
    if re.search(r"\bmslot\b", m.group(2)):
        print("%s: already whitelists mslot (fixed upstream?)" % wl)
        continue
    s = s[:m.start(3)] + " mslot" + s[m.start(3):]
    print("%s: added mslot" % wl)
open(p, "w").write(s)
print("layers_def patch applied OK")
PYEOF

# ----------------------------------------------------------------------- run --
echo "== running KLayout DRC: variant=$VARIANT mp=$MP thr=$THR =="
cd "$OUT"
python3 "$DECK/run_drc.py" --path="$GDS" --variant="$VARIANT" --topcell="$TOPCELL" \
        --run_dir="$OUT" --mp="$MP" --thr="$THR" ${TABLE_ARGS[@]+"${TABLE_ARGS[@]}"}
DRC_RC=$?
echo "run_drc.py exit=$DRC_RC"

LOG=$(ls -t "$OUT"/drc_run_*.log 2>/dev/null | head -1)

# ------------------------------------------------------------------ validate --
# Three independent things must hold. Any one failing means the run is not a pass,
# regardless of how many zeros the reports contain.
fail=0

# (1) the driver itself must have succeeded
[ "$DRC_RC" != "0" ] && { echo "GUARD FAIL: run_drc.py exited $DRC_RC"; fail=1; }

# (2) no table may have raised
if [ -n "$LOG" ]; then
  # grep -c prints "0" and exits 1 on no match; `|| echo 0` would append a second
  # line, making "$exc" the unparseable "0\n0" and silently breaking [ -gt ].
  exc=$(grep -c "generated an exception" "$LOG" 2>/dev/null); exc=${exc:-0}
  if [ "$exc" -gt 0 ] 2>/dev/null; then
    echo "GUARD FAIL: $exc table(s) raised an exception:"
    grep "generated an exception" "$LOG" | sed 's/^/    /'
    fail=1
  fi
else
  echo "GUARD FAIL: no drc_run_*.log produced"; fail=1
fi

# (3) every generated table must have a COMPLETE report. run_drc.py emits one
# <table>.drc into the run dir per table; layers_def.drc is a shared include, not
# a table. A truncated .lyrdb (no closing tag) means the table died mid-write and
# its "0 items" is meaningless.
missing=0; truncated=0; tables=0
for d in "$OUT"/*.drc; do
  t=$(basename "$d" .drc)
  [ "$t" = "layers_def" ] && continue
  tables=$((tables+1))
  r="$OUT/$(basename "$GDS" .gds)_${t}.lyrdb"
  if [ ! -f "$r" ]; then
    echo "GUARD FAIL: table '$t' produced NO report"; missing=$((missing+1)); fail=1
  elif ! grep -q "</report-database>" "$r"; then
    echo "GUARD FAIL: table '$t' report is truncated (table died mid-write)"; truncated=$((truncated+1)); fail=1
  fi
done

# --------------------------------------------------------------- violations --
# Only meaningful once the above passed.
echo
echo "== violation counts =="
viol=0
for r in "$OUT"/*.lyrdb; do
  n=$(grep -c "<item>" "$r" 2>/dev/null); n=${n:-0}
  if [ "$n" -gt 0 ] 2>/dev/null; then echo "  $(basename "$r"): $n"; viol=$((viol+n)); fi
done
[ "$viol" = "0" ] && echo "  (none)"

echo
echo "== summary =="
echo "  scope           : ${TABLES:-FULL DECK}"
echo "  tables expected : $tables"
echo "  reports missing : $missing"
echo "  reports truncated: $truncated"
echo "  exceptions      : ${exc:-n/a}"
echo "  violations      : $viol"

if [ "$fail" != "0" ]; then
  echo "RESULT: FAIL (run incomplete - violation count above is NOT trustworthy)"
  exit 10
fi
if [ "$viol" != "0" ]; then echo "RESULT: FAIL ($viol DRC violations)"; exit 11; fi
if [ -n "$TABLES" ]; then
  # A subset run proves nothing about the tables it did not run. Say so in the
  # verdict itself: this line gets pasted into risk docs and commit messages,
  # and "PASS" on its own would read as a signoff it cannot support.
  echo "RESULT: PARTIAL PASS ($tables of 63 tables ran: $TABLES; 0 violations)"
  echo "        NOT a signoff -- the remaining tables were not run here."
else
  echo "RESULT: PASS (all $tables tables ran, 0 violations)"
fi
