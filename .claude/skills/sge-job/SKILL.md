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

| Purpose | Host path (NFS) | Container path |
|---------|-----------------|----------------|
| Input files / designs | `/srv/eda/designs/timothyjabez/lora-mimo/` | `/foss/designs/` |
| Job stdout | `/srv/eda/logs/timothyjabez/job-<ID>.o` | — |
| Job stderr | `/srv/eda/logs/timothyjabez/job-<ID>.e` | — |
| Submitted script copy | `/srv/eda/logs/timothyjabez/job-<ID>.sh` | — |

Log path uses `timothyjabez`, not `timothyn` — see [[feedback_sge_log_path]].

## NFS symlinks for P&R run outputs

Source files (`.v`, `config.json`, `pnr.sdc`) are tracked in git under `rtl-test/`.
Run outputs (`runs/`) live on NFS only and are referenced via symlinks so the local repo
stays small.

**Layout:**

```
rtl-test/ol_<block>/runs  →  /srv/eda/designs/timothyjabez/lora-mimo/rtl-test/ol_<block>/runs
```

The `.gitignore` excludes `rtl-test/ol_*/runs` (matches both directories and symlinks).

**To set up a symlink for a new block** (after the first P&R run has created the `runs/` dir on NFS):

```bash
BLOCK=ol_my_new_block
NFS=/srv/eda/designs/timothyjabez/lora-mimo/rtl-test/$BLOCK/runs
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
    nfs="/srv/eda/designs/timothyjabez/lora-mimo/rtl-test/$block/runs"
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
USER=timothyjabez

# 1. Write script to NFS designs dir
cat > /srv/eda/designs/$USER/lora-mimo/sim.sh << 'EOF'
#!/bin/bash
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
ngspice -b /foss/designs/netlist.spice > /foss/designs/result.txt
EOF

# 2. Place input file
cp netlist.spice /srv/eda/designs/$USER/lora-mimo/

# 3. Submit
JOB_ID=$(hqsub --name ngspice-sim --cpus 2 --mem 4G \
    /srv/eda/designs/$USER/lora-mimo/sim.sh \
    | grep -oP '\d+')
echo "Submitted job $JOB_ID"

# 4. Wait for completion (see hlab-sge skill for hqwait, the simpler alternative)
hqwait "$JOB_ID"

# 5. Check outcome
EXIT=$(hqstat --json --all | python3 -c \
    "import json,sys; jobs=json.load(sys.stdin); m=[j for j in jobs if j['id']==$JOB_ID]; print(m[0]['exit_code'] if m else '')")
if [ "$EXIT" = "0" ]; then
    cat /srv/eda/designs/$USER/lora-mimo/result.txt
else
    echo "Job failed — stderr:" >&2
    cat /srv/eda/logs/$USER/job-$JOB_ID.e >&2
fi
```
