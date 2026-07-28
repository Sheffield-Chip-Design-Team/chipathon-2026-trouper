---
name: pnr-results
description: Dig timing (WNS/TNS per corner), DRC error count, LVS status, and cell/area stats out of a completed (or in-progress) LibreLane run under rtl-test/ol_<block>/runs/. Use after a run-pnr job finishes, or when the user asks "what's the WNS", "did DRC pass", "how much area", or points at a specific RUN_* directory.
---

# pnr-results

LibreLane run directories (`rtl-test/ol_<block>/runs/RUN_<timestamp>/`) are numbered
stage subdirectories. Find the latest run, then pull only what's needed — these
directories are large, don't `cat` whole reports blindly.

## Locate the run

```bash
BLOCK=ol_trouper_top   # or whichever block
RUN=$(ls -td rtl-test/$BLOCK/runs/RUN_*/ | head -1)   # most recent
echo "$RUN"
```

If `runs/` is a symlink to NFS and looks stale/empty, check
`/srv/eda/designs/timothyjabez/lora-mimo/rtl-test/$BLOCK/runs/` directly — the local
symlink can lag if it wasn't re-pointed after a rename.

## Synth-only run (stops at Yosys.Synthesis)

```bash
cat "$RUN/06-yosys-synthesis/reports/chk.rpt"      # "Found and reported N problems" — must be 0
cat "$RUN/06-yosys-synthesis/reports/stat.rpt"     # cell count + area (µm²) at the bottom of the header block
grep -c "^Latch inferred" "$RUN/06-yosys-synthesis/reports/latch.rpt"   # must be 0 (lines say "No latch inferred" for expected combinational logic)
```

Note: stage numbers shift depending on which steps are gated on/off in the config —
if `06-yosys-synthesis` doesn't exist, `ls "$RUN"` and look for the dir matching
`*yosys-synthesis`.

## Full P&R run

```bash
# WNS per corner (repeat per corner listed in STA_CORNERS)
cat "$RUN"/*-openroad-stapostpnr/max_ss_125C_3v00/wns.max.rpt
cat "$RUN"/*-openroad-stapostpnr/max_ff_n40C_3v60/wns.max.rpt
cat "$RUN"/*-openroad-stapostpnr/nom_tt_025C_3v30/wns.max.rpt
# TNS (total negative slack) is in the sibling tns.max.rpt in the same dir if present

# Magic DRC error count
python3 -c "
import json, glob
f = sorted(glob.glob('$RUN/*-checker-magicdrc/state_out.json'))
print(json.load(open(f[-1])).get('metrics',{}).get('magic__drc_error__count','not found') if f else 'no DRC stage')
"

# LVS
python3 -c "
import json, glob
f = sorted(glob.glob('$RUN/*-lvs*/state_out.json'))
print(json.load(open(f[-1])).get('metrics',{}) if f else 'no LVS stage')
"

# Final cell/area summary + any flow-level warnings
tail -100 "$RUN"/../../*.log 2>/dev/null   # or the job's own .log if you named one in run-pnr
grep -i "warning\|error" "$RUN/info.log" 2>/dev/null | tail -40
```

## Interpreting WNS

- **Negative WNS at `max_ss_125C_3v00`** (slow-slow corner) is the known, ongoing
  battle — `gf180mcu_fd_sc_mcu7t5v0` is 5V-characterized cells run at 3.0-3.3V core,
  so SS timing is chronically tight. Don't treat a negative SS WNS alone as "this run
  regressed" — compare it against the *previous* run's SS WNS for the same config
  family before concluding anything. Best achieved so far is in the
  `project_item39_writearc_fixed` / `project_sclock_timingref_fanout_rootcause` memory
  trail — check current memory for the latest number before calling a result good or
  bad.
- `nom_tt_025C_3v30` and `max_ff_n40C_3v60` should normally be positive (met); a
  regression there is a real red flag, not corner-characterization noise.
- If `RUN_MAGIC_DRC`/`RUN_LVS` are `false` in the config (many exploratory configs
  disable these for speed), the checker stages won't exist — that's expected, not a
  failure to chase.

## Reporting back to the user

State: (1) exit code / did the flow reach `Flow complete`, (2) WNS per corner if full
P&R, (3) DRC/LVS error counts if enabled, (4) cell count/area, (5) anything in the
warnings that isn't already-known noise (e.g. new lint warnings on files just changed,
vs. long-standing warnings on untouched files like `sd_decimator_poly.v`).
