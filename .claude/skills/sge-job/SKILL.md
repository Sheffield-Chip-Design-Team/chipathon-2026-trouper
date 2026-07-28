---
name: sge-job
description: Chipathon-specific homelab-sge usage — PDK selection inside the chipathon26 container image, and the rtl-test/ol_*/runs NFS symlink layout. For general hqsub/hqstat/hqdel/hqhost/hqwait/hqlogin mechanics, use the hlab-sge skill first; this skill only covers what's specific to this repo. Triggers on "submit a job", "check job <ID>", "hqsub", "hqstat", "SGE", "job scheduler", "PDK on SGE", "runs symlink".
---

# homelab-sge — chipathon-specific usage

For the general `hq*` CLI (submit, poll, log, wait, cancel, interactive sessions,
auth token setup), use the **hlab-sge** skill — it's the synced source of truth for
that mechanics and shouldn't be duplicated here. This skill only covers what's
specific to this repo: PDK selection inside the `chipathon26` image, and the
`rtl-test/ol_*/runs` NFS symlink layout.

Existing example job scripts live in `fpga-emul/sge/` (`sim_psram.sh`, `sim_spi_reg.sh`).

```bash
export HLAB_SGE_URL=http://nas.home:4783
```

## PDK selection on SGE

Do **not** rely on an inherited `PDK` environment variable inside SGE jobs.
The `chipathon26` image contains multiple installed PDKs (`gf180mcuD`,
`ihp-sg13g2`, etc.), and scheduler/container startup can leave `PDK` pointing
at the wrong one for Magic-based flows.

For GF180 work, force the PDK explicitly inside the submitted job script:

```bash
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
```

For Magic extraction, also pass the rcfile explicitly instead of relying on
the ambient environment:

```bash
RCFILE="$PDK_ROOT/$PDK/libs.tech/magic/$PDK.magicrc"
magic -dnull -noconsole -rcfile "$RCFILE" ...
```

This is especially important for SRAM extraction jobs on SGE. A previous OCD
SRAM RC-extraction failure was made worse by Magic starting in `ihp-sg13g2`
before the script forced `gf180mcuD`.

## Shared filesystem paths (this repo's project)

**The SGE owner is `timothyn-dev`, not `timothyjabez`** (migrated 2026-07-27/28 —
if you see references to `timothyjabez` in older scripts/docs on NFS, that's the
old owner; sync and submit against `timothyn-dev` paths).

| Purpose | Host path (NFS) | Container path (no `--project`) |
|---------|-----------------|-----------------|
| Input files / designs | `/srv/eda/designs/timothyn-dev/lora-mimo/` | `/foss/designs/lora-mimo/` |
| Job stdout | `/srv/eda/logs/timothyn-dev/job-<ID>.o` | — |
| Job stderr | `/srv/eda/logs/timothyn-dev/job-<ID>.e` | — |
| Submitted script copy | `/srv/eda/logs/timothyn-dev/job-<ID>.sh` | — |

**`--project lora-mimo` changes the container mount point.** Without `--project`,
the whole designs root is mounted and this repo's project shows up at
`/foss/designs/lora-mimo/...` inside the container. **With** `--project lora-mimo`
(recommended — see below), the *project directory itself* is mounted directly at
`/foss/designs`, so paths inside job scripts become `/foss/designs/rtl-test/...`,
**not** `/foss/designs/lora-mimo/rtl-test/...`. Getting this wrong is an easy way
to burn a whole job on a `cd: No such file or directory` — check which mount mode
a script assumes before reusing it. `run_synth_trouper_top_breakdown.sh` already
handles both cases (see its `RTL_ROOT` fallback logic); a plain hand-written job
script usually does not, so write it for the `--project`-scoped path once you're
using `--project` (which should be the default here, see next section).

**Always pass `--project lora-mimo`** to `hqsub` for jobs in this repo — the
unscoped snapshot walks the entire multi-GB `timothyn-dev` designs root
(dozens of other project checkouts) and can hit the 180s client timeout or the
snapshot's size/file bounds outright.

Even `--project`-scoped, this project is large enough (~2GB: `rtl-test/cocotb_trouper_capture/`,
`ip/`, `cocotb/`, `fpga-emul/`, `lora-capture/`, `characterization/` are the big
non-P&R-relevant trees) that plain submits can still hit the 180s client
timeout. If that happens, reach for `hqsub`'s repeatable `--snapshot-exclude
<glob>` flag to cut those subtrees out of the snapshot — see the `hlab-sge`
skill for the flag's syntax.

Log path uses `timothyn-dev`, not `timothyjabez`/`timothyn` — see [[feedback_sge_user_timothyn_dev]].

## `/foss/designs` is read-only — LibreLane needs `--force-run-dir`

As of the 2026-07-27/28 NFS `manage_gids` change, `/foss/designs` (however it's
mounted — see the `--project` note above) is **read-only** inside the container.
This breaks anything that tries to write inside the design tree, including
LibreLane's default behavior of creating its `runs/<tag>/` output directory
*inside* the design directory the config file lives in
(`<design_dir>/runs/<tag>`) — a plain `librelane ... ol_trouper_top/config.json`
job fails with:

```
OSError: [Errno 30] Read-only file system: '/foss/designs/rtl-test/ol_trouper_top/runs'
```

Fix: pass **`--force-run-dir <path>`** (an internal-but-real CLI flag — confirmed
via `librelane/flows/cli.py`, click option `--force-run-dir` → `_force_run_dir` →
`Flow.start()`) pointing at a writable directory, using the same `$RUN_DIR`
env var the SGE scheduler already provides for exactly this purpose (see the
`run_synth_trouper_top_breakdown.sh` pattern). **The target directory must
already exist** — `--force-run-dir` is validated by click before LibreLane gets
a chance to `mkdir -p` it, unlike the default `runs/<tag>` path which LibreLane
creates itself:

```bash
OUT=${RUN_DIR:-/foss/runs}/my_pnr_run
mkdir -p "$OUT/run"          # must pre-exist, --force-run-dir won't create it
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
          --force-run-dir "$OUT/run" \
          ol_trouper_top/config_current_signoff.json
```

This applies to **every** LibreLane invocation against this repo's designs now
(synth-only or full P&R) — not just this one config. The synth-only
`run_synth_trouper_top_breakdown.sh` script doesn't need this because it's pure
Yosys with its own `$OUT`/`$RUN_DIR` handling, not a LibreLane flow.

## NFS symlinks for P&R run outputs

Source files (`.v`, `config.json`, `pnr.sdc`) are tracked in git under `rtl-test/`.
Run outputs (`runs/`) live on NFS only and are referenced via symlinks so the local repo
stays small.

**Layout:**

```
rtl-test/ol_<block>/runs  →  /srv/eda/designs/timothyn-dev/lora-mimo/rtl-test/ol_<block>/runs
```

The `.gitignore` excludes `rtl-test/ol_*/runs` (matches both directories and symlinks).

**To set up a symlink for a new block** (after the first P&R run has created the `runs/` dir on NFS):

```bash
BLOCK=ol_my_new_block
NFS=/srv/eda/designs/timothyn-dev/lora-mimo/rtl-test/$BLOCK/runs
LOCAL=/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/$BLOCK/runs

# Remove any local runs/ directory first (if it exists)
rm -rf "$LOCAL"

# Ensure the NFS target exists
mkdir -p "$NFS"

# Create the symlink
ln -s "$NFS" "$LOCAL"
```

**To set up symlinks for all existing blocks at once:**

```bash
cd /home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test
for block in ol_*/; do
    block="${block%/}"
    nfs="/srv/eda/designs/timothyn-dev/lora-mimo/rtl-test/$block/runs"
    local="$block/runs"
    rm -rf "$local"
    mkdir -p "$nfs"
    ln -s "$nfs" "$local"
done
```

**Accessing results after a job completes:** see the `pnr-run` / `pnr-results` skills for WNS/DRC reading commands.

## Environment inside the container

| Variable | Value |
|----------|-------|
| `JOB_ID` | Numeric job ID |
| `JOB_NAME` | Job name passed to `hqsub` |
| `PDK_ROOT` | `/foss/pdks` |

## Complete example

```bash
export HLAB_SGE_URL=http://nas.home:4783
USER=timothyn-dev

# 1. Write script to NFS designs dir. Note: with --project lora-mimo below,
#    the project dir is mounted directly at /foss/designs (not
#    /foss/designs/lora-mimo) — see "Shared filesystem paths" above. Also
#    remember /foss/designs is read-only; any tool that writes into the
#    design tree (LibreLane's runs/, etc.) needs its output redirected to
#    $RUN_DIR — see "/foss/designs is read-only" above.
cat > /srv/eda/designs/$USER/lora-mimo/sim.sh << 'EOF'
#!/bin/bash
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
OUT=${RUN_DIR:-/foss/runs}
ngspice -b /foss/designs/netlist.spice > "$OUT/result.txt"
EOF

# 2. Place input file
cp netlist.spice /srv/eda/designs/$USER/lora-mimo/

# 3. Submit (--project scopes the snapshot to this project only — see above)
JOB_ID=$(hqsub --name ngspice-sim --cpus 2 --mem 4G --project lora-mimo \
    /srv/eda/designs/$USER/lora-mimo/sim.sh \
    | grep -oP '\d+')
echo "Submitted job $JOB_ID"

# 4. Wait for completion (see hlab-sge skill for hqwait, the simpler alternative)
hqwait "$JOB_ID"

# 5. Check outcome (result.txt was written under $RUN_DIR inside the
#    container, not under the read-only /foss/designs mount — read it back
#    via the job's log, or check hqlog/hqsub --help for the host-side path
#    $RUN_DIR resolves to if you need the raw file)
EXIT=$(hqstat --json --all | python3 -c \
    "import json,sys; jobs=json.load(sys.stdin); m=[j for j in jobs if j['id']==$JOB_ID]; print(m[0]['exit_code'] if m else '')")
if [ "$EXIT" != "0" ]; then
    echo "Job failed — stderr:" >&2
    cat /srv/eda/logs/$USER/job-$JOB_ID.e >&2
fi
```
