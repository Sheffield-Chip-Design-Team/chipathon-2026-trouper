---
name: sge-job
description: Use when submitting, polling, cancelling, or reading results from a homelab-sge (hqsub/hqstat/hqdel/hqhost) job, or setting up the rtl-test/ol_*/runs NFS symlinks that P&R/simulation results land in. Triggers on "submit a job", "check job <ID>", "hqsub", "hqstat", "SGE", "job scheduler".
---

# homelab-sge Agents instructions

Guidance for AI agents using homelab-sge to run EDA workloads. Existing example job scripts live in `fpga-emul/sge/` (`sim_psram.sh`, `sim_spi_reg.sh`).

## Connecting to the scheduler

Set `HLAB_SGE_URL` to point all CLI tools at the correct daemon. The daemon
port is shown by `hqd status` on the host running the scheduler.

```bash
export HLAB_SGE_URL=http://nas.home:4783
```

Every `hq*` command and the REST API described below honours this variable.
Without it, tools default to `localhost` on the configured port. (Note: this
machine *is* nas.home, so `localhost:4783` works identically.)

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

## Shared filesystem

All nodes mount the same NFS share. Use these paths:

| Purpose | Host path (NFS) | Container path |
|---------|-----------------|----------------|
| Input files / designs | `/srv/eda/designs/<user>/` | `/foss/designs/` |
| Job stdout | `/srv/eda/logs/<user>/job-<ID>.o` | — |
| Job stderr | `/srv/eda/logs/<user>/job-<ID>.e` | — |
| Submitted script copy | `/srv/eda/logs/<user>/job-<ID>.sh` | — |

Write input files to `/srv/eda/designs/<user>/` before submitting. Reference
them inside the job script as `/foss/designs/<file>`. Output files written to
`/foss/designs/` by the container are visible at `/srv/eda/designs/<user>/`
after the job completes.

`<user>` is the Unix username of the process that calls `hqsub`. New users'
NFS dirs need `chown <user>:hlab-sge`, not `chown <user>:<user>`.

## Submitting a job

Write a shell script, then submit it:

```bash
cat > /srv/eda/designs/timothyn/run.sh << 'EOF'
#!/bin/bash
set -euo pipefail
cd /foss/designs
# your commands here
EOF

HLAB_SGE_URL=http://nas.home:4783 hqsub \
    --name my-job \
    --cpus 4 \
    --mem 8G \
    /srv/eda/designs/timothyn/run.sh
# prints: Submitted job <ID>
```

Key options:

| Option | Default | Notes |
|--------|---------|-------|
| `--cpus FLOAT` | `1.0` | CPUs to reserve |
| `--mem TEXT` | `4G` | e.g. `8G`, `512M` |
| `--gpu 1` | `0` | Binary slot; omit unless CUDA is required |
| `--priority 1-10` | `5` | 10 = highest |
| `--node NAME` | auto | Pin to `master` or `gaming-pc` |
| `--after ID[,ID]` | — | Wait for these job IDs to finish first |

## Polling for completion

`hqstat --json` returns a JSON array of job objects. Poll it until the
target job reaches a terminal state.

```bash
# Wait for job 643 to finish (bash)
while true; do
    state=$(HLAB_SGE_URL=http://nas.home:4783 hqstat --json \
            | python3 -c "
import json, sys
jobs = json.load(sys.stdin)
match = [j for j in jobs if j['id'] == 643]
print(match[0]['state'] if match else 'UNKNOWN')
")
    echo "state: $state"
    case "$state" in
        DONE|FAILED|CANCELLED) break ;;
    esac
    sleep 5
done
```

Terminal states: `DONE` (exit code 0), `FAILED` (non-zero exit or error),
`CANCELLED` (cancelled by user).

To check a single job's full detail (state, exit_code, assigned_node, elapsed, etc.), filter `hqstat --json` by id rather than hitting the REST API directly:

```bash
hqstat --json | python3 -c "
import json, sys
jobs = json.load(sys.stdin)
match = [j for j in jobs if j['id'] == 643]
print(json.dumps(match[0], indent=2) if match else 'not found')
"
```

The REST API (`/api/jobs/...`) now requires a bearer token — a bare `curl` gets `401 {"detail":"Authentication required. Provide a Bearer token."}`. The `hq*` CLI tools read the token from `~/.config/hlab-sge/token` automatically, which is why `hqstat`/`hqsub`/`hqhost` work without extra flags. Prefer the CLI tools for anything they cover.

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

**Accessing results after a job completes:** see the `pnr-run` skill for WNS/DRC reading commands.

## Reading results

Prefer reading directly from NFS — no auth needed and it's the full log, not a tail:

```bash
# full stdout
cat /srv/eda/logs/timothyn/job-643.o

# stderr
cat /srv/eda/logs/timothyn/job-643.e
```

If NFS isn't mounted where you're running from, the log-tail API needs the bearer token (see above):

```bash
curl -s -H "Authorization: Bearer $(cat ~/.config/hlab-sge/token)" \
  http://nas.home:4783/api/jobs/643/log/out | python3 -c "
import json, sys; [print(l) for l in json.load(sys.stdin)['lines']]"
```

Check `exit_code` in the job object before reading results. A non-zero exit
code means the job failed; check `.e` for the error.

## Cancelling a job

```bash
HLAB_SGE_URL=http://nas.home:4783 hqdel --force <ID>
```

## Checking available resources before submitting

```bash
HLAB_SGE_URL=http://nas.home:4783 hqhost --json
# Returns per-node CPU/RAM/GPU totals, allocations, and state.
# Only submit if a node has enough free resources, or let the
# scheduler queue the job automatically (it will run when resources free up).
```

## Environment inside the container

| Variable | Value |
|----------|-------|
| `JOB_ID` | Numeric job ID |
| `JOB_NAME` | Job name passed to `hqsub` |
| `PDK_ROOT` | `/foss/pdks` |

## Complete example

```bash
export HLAB_SGE_URL=http://nas.home:4783
USER=timothyn

# 1. Write script to NFS designs dir
cat > /srv/eda/designs/$USER/sim.sh << 'EOF'
#!/bin/bash
set -euo pipefail
ngspice -b /foss/designs/netlist.spice > /foss/designs/result.txt
EOF

# 2. Place input file
cp netlist.spice /srv/eda/designs/$USER/

# 3. Submit
JOB_ID=$(hqsub --name ngspice-sim --cpus 2 --mem 4G \
    /srv/eda/designs/$USER/sim.sh \
    | grep -oP '\d+')
echo "Submitted job $JOB_ID"

# 4. Wait for completion
while true; do
    STATE=$(hqstat --json | python3 -c \
        "import json,sys; jobs=json.load(sys.stdin); m=[j for j in jobs if j['id']==$JOB_ID]; print(m[0]['state'] if m else 'UNKNOWN')")
    [ "$STATE" = "DONE" ] || [ "$STATE" = "FAILED" ] && break
    sleep 5
done

# 5. Check outcome
EXIT=$(hqstat --json | python3 -c \
    "import json,sys; jobs=json.load(sys.stdin); m=[j for j in jobs if j['id']==$JOB_ID]; print(m[0]['exit_code'] if m else '')")
if [ "$EXIT" = "0" ]; then
    cat /srv/eda/designs/$USER/result.txt
else
    echo "Job failed — stderr:" >&2
    cat /srv/eda/logs/$USER/job-$JOB_ID.e >&2
fi
```
