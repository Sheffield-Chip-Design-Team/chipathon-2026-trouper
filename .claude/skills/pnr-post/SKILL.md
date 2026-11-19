---
name: pnr-post
description: Take a completed, physically-clean full P&R run of trouper_top and drive it through the out-of-flow signoff sequence — insert the 12 A40 PDN bridges, run the guarded 63-table KLayout DRC (#58), the MCP scoped-exception audit (#43), and the host-SPI post-route GLS/SDF harness (#54) as SGE jobs, then refresh final/ and rewrite final/README.md. Use after a run-pnr job finishes clean and the user wants the run promoted / "another /final update".
---

# pnr-post

The counterpart to `run-pnr`. `run-pnr` produces a LibreLane run; `pnr-results` tells you
whether it is physically clean; **this skill takes a clean run and does everything that has
to happen against that exact netlist/GDS before it can ship** — the steps LibreLane does
*not* do in-flow — then promotes the curated subset into `final/`.

Every sub-job is submitted to SGE and polled to completion (per the answer that shaped this
skill). Total wall time is dominated by the KLayout DRC (~2 h 14 m on its own).

## Inputs

- An SGE **job ID** (or run dir) for a completed full P&R of `trouper_top` from the
  **canonical** `src/config/trouper_top.json` (not a probe config). Run dir shape:
  `/srv/eda/runs/timothyn-dev/lora-mimo/<JOBID>/<name>/run/`.
- The job must have `EXIT 0` / "Flow complete" in its log.

If you only have "the last run", find it: `ls -td /srv/eda/runs/timothyn-dev/lora-mimo/*/*/run 2>/dev/null | head`.

## Step 0 — gate on physical cleanliness (do not skip)

Use the `pnr-results` skill against `$RUN/final/metrics.json`. **Refuse to promote** unless
all of these hold — a promote of a dirty run is worse than no promote:

| Metric | Required |
|---|---|
| `magic__drc_error__count` | 0 |
| `route__drc_errors` | 0 |
| `design__lvs_error__count` (+ device/net diff) | 0 |
| `design__xor_difference__count` | 0 |
| `antenna__violating__nets` / `__pins` | 0 / 0 |
| `timing__hold__wns` / `__tns` | 0 / 0 (hold MET all corners) |

**Expected-and-carried, NOT gate failures** (the flow's `Checker.SetupViolations` /
`Checker.Max{Slew,Cap}Violations` are non-fatal by config): SS setup WNS/TNS at
`max_ss_125C_3v00`, and max-slew/max-cap counts. Record the numbers; they go in the README
"Known gaps" section, they do not stop the promote.

```bash
JOBID=<id>
RUN=$(ls -d /srv/eda/runs/timothyn-dev/lora-mimo/$JOBID/*/run | head -1); echo "$RUN"
grep -aE '^=== EXIT|Flow complete' /srv/eda/logs/timothyn-dev/job-$JOBID.o | tail -3
```

## Step 1 — insert the 12 A40 PDN bridges

`tools/build_a40_pdn_bridges.py` adds only geometry (6 VDD M2→M5 north, 6 VSS M2→M4 west) to
the flow streamout; no cell/macro coordinate moves. It runs under KLayout.

`/srv/eda/runs` is **not** mounted in the container — stage the input GDS into the design
tree first (`/srv/eda/designs/timothyn-dev/lora-mimo/...` = `/foss/designs/...`).

```bash
NFS=/srv/eda/designs/timothyn-dev/lora-mimo
mkdir -p "$NFS/pd/pnr_post_$JOBID"
cp "$RUN/final/gds/trouper_top.gds" "$NFS/pd/pnr_post_$JOBID/streamout.gds"

The bridge script prints only `wrote <gds> dbu 0.001 with 6 VDD and 6 VSS bridges` and
asserts the input dbu; the layer-by-layer delta check is a **separate** step in the same job
(it must run under `klayout -b -r`, not system `python3` — `pya` is only in KLayout's
interpreter):

```bash
cat > "$NFS/pd/pnr_post_$JOBID/verify_bridges.py" << 'PY'
import pya
a = pya.Layout(); a.read(globals()["streamout"])
b = pya.Layout(); b.read(globals()["bridged"])
want = {"m2":36, "via2":38, "m3":42, "via3":40, "m4":46, "via4":41, "m5":81}
ta, tb = a.cell("trouper_top"), b.cell("trouper_top")
for name, num in want.items():
    la = a.find_layer(pya.LayerInfo(num, 0)); lb = b.find_layer(pya.LayerInfo(num, 0))
    ca = ta.shapes(la).size() if la is not None else 0
    cb = tb.shapes(lb).size() if lb is not None else 0
    print(f"{name:5s} (L{num}): {ca} -> {cb}  (+{cb-ca})")
PY

cat > "$NFS/pnr_post_bridges_$JOBID.sh" << EOF
#!/bin/bash
set -e
OUT=\${RUN_DIR:-/foss/runs}/bridges
mkdir -p "\$OUT"
klayout -b -r /foss/designs/tools/build_a40_pdn_bridges.py \\
        -rd macro_gds=/foss/designs/pd/pnr_post_$JOBID/streamout.gds \\
        -rd output_gds=\$OUT/trouper_top.gds
klayout -b -r /foss/designs/pd/pnr_post_$JOBID/verify_bridges.py \\
        -rd streamout=/foss/designs/pd/pnr_post_$JOBID/streamout.gds \\
        -rd bridged=\$OUT/trouper_top.gds
md5sum /foss/designs/pd/pnr_post_$JOBID/streamout.gds "\$OUT/trouper_top.gds"
EOF
chmod +x "$NFS/pnr_post_bridges_$JOBID.sh"

export HLAB_SGE_URL=http://nas.home:4783
hqsub --name pnr-post-bridges-$JOBID --project lora-mimo --cpus 4 --mem 12G \
  "$NFS/pnr_post_bridges_$JOBID.sh"
```

Poll to a terminal state (see **Polling** below). On completion, confirm the delta line
matches the known-good set — **top-cell M2 +24, Via2 +1152, M3 +24, Via3 +1152, M4 +18,
Via4 +576, M5 +6** — and record the **new GDS md5**. That md5 is the staleness key:
it must end up in *both* `final/README.md` and the `_comment_klayout_drc` string in
`src/config/trouper_top.json`.

The bridged GDS is the run dir's `bridges/trouper_top.gds`. Stage it for step 2:
`cp <run>/bridges/trouper_top.gds "$NFS/pd/pnr_post_$JOBID/trouper_top.gds"`.

## Step 2 — guarded 63-table KLayout DRC (#58)

In-flow KLayout DRC is deliberately `false` in the config — this out-of-flow run is the only
real KLayout gate, and it is **manual**: nothing re-runs it, so a changed GDS (a new P&R, or
re-running the bridge script) silently invalidates the last result sitting in
`final/README.md` and the config comment.

- Runs against the **bridged** GDS from step 1, staged into the design tree.
- **Never** overwrite `rtl-test/scripts/klayout_drc_guarded.sh` on the shared mount while a
  job is running it — an rsync-over mid-run gives `Stale file handle` / exit 2 that looks
  exactly like a clean "run incomplete". Stage a per-job copy.
- A full run is required. `TABLES=` runs a subset, reports `PARTIAL`, and is **not** signoff.
- `run_drc.py` prints "Klayout DRC run is clean" even when a table crashed — trust the
  guard's table-ran count, not that line.

```bash
cp rtl-test/scripts/klayout_drc_guarded.sh "$NFS/pd/pnr_post_$JOBID/klayout_drc_guarded.sh"

cat > "$NFS/pnr_post_klaydrc_$JOBID.sh" << EOF
#!/bin/bash
set -uo pipefail
export RUN_DIR=\${RUN_DIR:-/foss/runs}
export MP=3 THR=3      # MP*THR must not exceed the reserved core count
/foss/designs/pd/pnr_post_$JOBID/klayout_drc_guarded.sh \\
    /foss/designs/pd/pnr_post_$JOBID/trouper_top.gds trouper_top D
echo "guard exit: \$?"
EOF
chmod +x "$NFS/pnr_post_klaydrc_$JOBID.sh"

# --cpus 10 / 24G is the known-schedulable P&R-class reservation on this pool
# (memory feedback_sge_mem_sizing: 32G never schedules; feedback_no_pnr_on_nas_node).
hqsub --name pnr-post-klaydrc-$JOBID --project lora-mimo --cpus 10 --mem 24G \
  "$NFS/pnr_post_klaydrc_$JOBID.sh"
```

**Pass = guard exit 0 AND the log shows every table ran (63/63) AND zero violations.** Exit
10 = a table did not run (counts meaningless); exit 11 = real violations. Record the job ID
and the GDS md5 the run was against.

## Step 3 — MCP scoped-exception audit (#43)

`rtl-test/scripts/run_mcp_audit.sh` stages inputs onto NFS, submits an OpenROAD job under
`--project lora-mimo`, `hqwait`s, then runs `audit_mcp.py` locally against the retrieved
evidence. Run **both** stages against this run's outputs and the active signoff SDC:

```bash
export HLAB_SGE_URL=http://nas.home:4783
SS_LIB=$(ls /foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/*ss*125*3v00*.lib | head -1)

rtl-test/scripts/run_mcp_audit.sh --stage synth \
  --netlist "$RUN/final/nl/trouper_top.nl.v" \
  --liberty "$SS_LIB"

rtl-test/scripts/run_mcp_audit.sh --stage route \
  --netlist "$RUN/final/nl/trouper_top.nl.v" \
  --spef    "$RUN/final/spef/max/trouper_top.max.spef" \
  --liberty "$SS_LIB"
```

It defaults `--sdc` to `src/config/pnr_32m_scoped_v25_b6_signoff.sdc` (the active one) — do
not override unless doing a deliberate historical comparison.

**Pass = `audit_mcp.py` prints `PASS: synth, N groups` and `PASS: route, N groups`.** Then:

- **Review any collection delta** before accepting — the audit only checks the collection
  resolves and matches the *written* baseline, not *why* it changed. In particular walk any
  `sc_quasi_static` startpoint→endpoint growth and confirm every added arc is genuinely the
  same quasi-static cone, not a real single-cycle path pulled in by the wildcard.
- Only after that human review, re-approve: re-run the failing/changed stage with
  `--update-baseline` and commit `rtl-test/ol_trouper_top/mcp_audit_baseline.json` +
  `mcp_audit_*.evidence`.

## Step 4 — host-SPI post-route GLS/SDF (#54)

Black-box Icarus gate-level host-SPI harness with `$sdf_annotate`, against this run's routed
netlist + post-route SDF. Not timing signoff (iverilog does not enforce `$setup`/`$hold`) —
a functional / netlist-integration / reset-X check.

```bash
mkdir -p rtl-test/gl_item54_inputs/sdf/nom_tt_025C_3v30
cp "$RUN/final/nl/trouper_top.nl.v"  rtl-test/gl_item54_inputs/trouper_top.nl.v
cp "$RUN/final/sdc/trouper_top.sdc"  rtl-test/gl_item54_inputs/trouper_top.sdc
cp "$RUN/final/sdf/nom_tt_025C_3v30/trouper_top__nom_tt_025C_3v30.sdf" \
   rtl-test/gl_item54_inputs/sdf/nom_tt_025C_3v30/
# sync rtl-test/ + the inputs dir to NFS (see block-regression skill for the rsync)
hqsub --name pnr-post-gls-$JOBID --project lora-mimo --cpus 8 --mem 24G \
  /srv/eda/designs/timothyn-dev/lora-mimo/rtl-test/gl_spi_sdf_item54.sh
```

**Pass = `EXIT 0` and the harness prints its PASS markers** (reset release, first-read-data
bit = CHIP_ID `0xA7` / CHIP_REV `0x01`, MISO-low after read, min-CS-hold write+readback,
min CS-high gap, 8-byte burst + auto-inc readback, read-byte snapshot stability). Record
netlist + SDF md5s and the job ID. Also note the standalone min_ff hold STA
(`gl_spi_sdf_item54_minff.sh`) if the fast/hold corner needs refreshing.

## Step 5 — promote into final/

`git ls-files final/` is the authority for what the tracked subset is. Refresh each of
those from this run; the **GDS is the bridged one from step 1**, everything else is the raw
run output.

| Tracked path | Source |
|---|---|
| `final/gds/trouper_top.gds` | **step-1 bridged GDS** (`<run>/bridges/trouper_top.gds`) |
| `final/def/trouper_top.def` | `$RUN/final/def/trouper_top.def` |
| `final/lef/trouper_top.lef` | `$RUN/final/lef/trouper_top.lef` |
| `final/nl/…` `pnl/…` `spice/…` `vh/…` `json_h/…` | `$RUN/final/<same>/` |
| `final/sdc/trouper_top.sdc` | `$RUN/final/sdc/trouper_top.sdc` |
| `final/lib/<corner>/*.lib` | `$RUN/final/lib/<corner>/` |
| `final/render/trouper_top.png` | `$RUN/final/render/trouper_top.png` |
| `final/metrics.{json,csv}` | `$RUN/final/metrics.{json,csv}` |
| `final/reports/sta/<corner>/{checks,max,min}.rpt` | `$RUN/57-openroad-stapostpnr/<corner>/` |
| `final/reports/drc/drc.magic.rpt` | `$RUN/66-magic-drc/reports/drc.magic.rpt` |
| `final/reports/lvs/lvs.netgen.rpt` | `$RUN/70-netgen-lvs/reports/lvs.netgen.rpt` |
| `final/reports/irdrop/irdrop.rpt` | `$RUN/58-openroad-irdropreport/irdrop.rpt` |

`final/gds` and `final/def` are ~58 MB / ~46 MB **plain git blobs, not LFS** — the commit is
large and that is expected.

Then rewrite `final/README.md`, keeping its section structure (intro / Configuration and
closure result / Signoff summary table / Post-P&R timing table / Known gaps / Contents):

- Job number, date, config, die size, util, instance count — from `$RUN/final/metrics.json`.
- **Bridged GDS md5** (step 1) — and update the same md5 in
  `src/config/trouper_top.json`'s `_comment_klayout_drc`.
- Signoff summary: antenna / route DRC / Magic DRC / LVS / XOR / PDN — all from metrics.
- **KLayout 63-table DRC**: now a real result (step 2 job ID + md5 + "63/63, 0 violations"),
  not PENDING — unless step 2 failed, in which case say so plainly.
- Post-P&R timing table: the three corners' setup WNS/TNS from metrics; note SS is the #1
  waiver corner.
- Known gaps: SS setup WNS/TNS regression vs the previous `final/` (quote both numbers),
  max-slew/max-cap per corner, and anything a gate surfaced.
- Note the MCP audit (#43) and GLS (#54) results + job IDs.

## Step 6 — report and commit

Summarise as a gate table — bridges / KLayout DRC / MCP audit synth / MCP audit route / GLS
— job ID and PASS/FAIL each, plus the metrics delta vs the previous `final/`.

Commit `final/` + the config comment + any re-approved MCP baseline together, message in the
style of the previous promote (`git log --oneline -- final/README.md | head`):

```
final: promote P&R job <ID> (<one-line what changed since last>)

<config, die, clean summary>
<bridged GDS md5>
<carried gaps with numbers>
<gate job IDs>
```

**Do not push** unless the user asks. If any gate failed, promote nothing — report the
failure and stop.

## Polling

`hqstat --json` on this scheduler build frequently returns `[]` even while a job is running
(and `hqstat` plain prints "No jobs found" while `Resources:` still shows the reservation) —
**do not treat an empty job list as "job gone / finished"**. Poll instead via:

- `hqwait <JOBID>` (blocks to terminal), or
- the run dir filling with numbered stage subdirs / `flow.log` growing / `=== EXIT` in
  `/srv/eda/logs/timothyn-dev/job-<JOBID>.o`, or
- `curl -s $HLAB_SGE_URL/api/jobs/<JOBID>` if you have a bearer token.

For a Monitor, poll the **log for `=== EXIT` / "Flow complete" / guard-exit lines**, not the
scheduler listing, and do not put a bare `DRT-[0-9]+` in the failure regex — benign
`[INFO DRT-0199] Number of violations = 0` lines will false-trigger it.

## Gotchas learned the hard way

- **Sync to NFS is a file copy, not git.** `rsync -a` to
  `/srv/eda/designs/timothyn-dev/lora-mimo/` throws `chgrp … Operation not permitted` on
  every dir — harmless, files still transfer; verify with `diff -q`, or use
  `rsync -rlpt --no-g`. Memory `project_nfs_manage_gids_and_readonly_designs`: g+w not o+w.
- **`/srv/eda/runs` is not in the container.** Anything a container job must read goes under
  `/srv/eda/designs/<user>/lora-mimo/` (= `/foss/designs/`).
- **This box (`gaming-pc`) is itself the SGE worker.** The KLayout DRC job holds ~16 cores
  for ~2 h — don't stack other heavy jobs on top.
- **KLayout DRC subset ≠ signoff.** `TABLES=` → `PARTIAL`; only a full 63-table run against
  the exact shipping md5 is a gate.
- **The bridge md5 lives in two places** and both are the staleness check: `final/README.md`
  and `src/config/trouper_top.json` `_comment_klayout_drc`. Update both or the next reader
  trusts a stale pass.
