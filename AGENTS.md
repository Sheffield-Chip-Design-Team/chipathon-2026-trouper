/resources contains relevant datasheets
/sim contains the system simulation
/planning contains MD files for planning

## Running LibreLane (P&R)

Use the `hpretl/iic-osic-tools:chipathon26` Docker image. LibreLane is at `/foss/tools/bin/librelane` inside the container.

### Standard cells: `gf180mcu_fd_sc_mcu7t5v0` (default)

```bash
docker run --rm \
  --user $(id -u):$(id -g) \
  -v $(pwd):/foss/designs/lora-mimo \
  hpretl/iic-osic-tools:chipathon26 \
  --skip bash -c "cd /foss/designs/lora-mimo/rtl-test && librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 <block_dir>/config.json"
```

### Native 3.3 V cells: `gf180mcu_as_sc_mcu7t3v3` — **not the current tapeout plan**

> AS cells are unlikely to be used. The library is unproven (community-maintained, not a GF-qualified foundry library). Retain configs for reference; prefer FD cells + MCP for new work.

The AS cells are not in the container's PDK. A pre-built overlay at
`/foss/designs/pdk_overlay_as` (NFS-persistent) adds them alongside the
standard foundry cells. Use `--pdk-root` to point LibreLane at the overlay:

```bash
librelane --pdk-root /foss/designs/pdk_overlay_as \
          --pdk gf180mcuD --scl gf180mcu_as_sc_mcu7t3v3 \
          <block_dir>/config_as_mcu7t3v3.json
```

Config files that use AS cells must set `LIB` to
`dir::../../ip/gf180mcu_as_sc_mcu7t3v3/pdk/libs.ref/gf180mcu_as_sc_mcu7t3v3/lib/*.lib`
and use the dedicated **`clkbuff_*`** cells for CTS (not `buff_*` — those cause DRT-0073):

```json
"CTS_ROOT_BUFFER": "gf180mcu_as_sc_mcu7t3v3__clkbuff_12",
"CTS_CLK_BUFFERS": [
    "gf180mcu_as_sc_mcu7t3v3__clkbuff_4",
    "gf180mcu_as_sc_mcu7t3v3__clkbuff_8",
    "gf180mcu_as_sc_mcu7t3v3__clkbuff_12"
]
```

Also set `FP_CORE_UTIL` to **50** minimum (not the old FD default of 15–20%). Below ~50% util the
CTS root buffer lands in a sparse dead zone and DRT-0073 recurs even with correct clkbuff cells.
Above ~60% util the density wall kicks in (DRT-0073 from congestion). Safe window: **50–60% util / 55–65% density**.

See `ol_sd_decimator_cic_only/config_as_mcu7t3v3.json` for a working example.

**If the overlay is missing or broken**, rebuild it once via SGE:
```bash
hqsub --name rebuild-as-overlay --cpus 1 --mem 1G -- bash -c \
  "cd /foss/designs/lora-mimo/rtl-test && ./stage_as_scl.sh /foss/designs/pdk_overlay_as"
```

**Why AS cells were explored:** `fd_sc_mcu7t5v0` is characterised at 3 V (SS corner) but designed for 5 V — it fails 32 MHz SS timing across all blocks. AS cells are native 3.3 V and close timing correctly (~16% larger die area). However, the library is unproven and tapeout risk is high; the preferred approach is FD cells with MCP or clock-domain partitioning.

Replace `<block_dir>` with e.g. `ol_mrc_combiner`, `ol_picorv32`, `ol_sd_decimator`, `ol_nr_outer`.

Do **not** use `hpretl/iic-osic-tools:latest` or `hpretl/iic-osic-tools:2026.04` for chipathon tapeout work — use `chipathon26` only.

# homelab-sge Agents instructions

Guidance for AI agents using homelab-sge to run EDA workloads.

## Connecting to the scheduler

Set `HLAB_SGE_URL` to point all CLI tools at the correct daemon. The daemon
port is shown by `hqd status` on the host running the scheduler.

```bash
export HLAB_SGE_URL=http://nas.home:4783
```

Every `hq*` command and the REST API described below honours this variable.
Without it, tools default to `localhost` on the configured port.

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

`<user>` is the Unix username of the process that calls `hqsub`.

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

Alternatively, query a single job via the REST API:

```bash
curl -s http://nas.home:4783/api/jobs/643
# {"id":643,"state":"DONE","exit_code":0,"elapsed":"00:02:14", ...}
```

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
LOCAL=/home/timothyjabez/Documents/chipathon-2026/lora-mimo/rtl-test/$BLOCK/runs

# Remove any local runs/ directory first (if it exists)
rm -rf "$LOCAL"

# Ensure the NFS target exists
mkdir -p "$NFS"

# Create the symlink
ln -s "$NFS" "$LOCAL"
```

**To set up symlinks for all existing blocks at once:**

```bash
cd /home/timothyjabez/Documents/chipathon-2026/lora-mimo/rtl-test
for block in ol_*/; do
    block="${block%/}"
    nfs="/srv/eda/designs/timothyjabez/lora-mimo/rtl-test/$block/runs"
    local="$block/runs"
    rm -rf "$local"
    mkdir -p "$nfs"
    ln -s "$nfs" "$local"
done
```

**Accessing results after a job completes:**

```bash
# Latest run for a block
ls -t rtl-test/ol_weight_gen/runs/ | head -1

# Post-PNR SS timing
cat rtl-test/ol_weight_gen/runs/RUN_*/56-openroad-stapostpnr/max_ss_125C_3v00/wns.max.rpt

# Magic DRC error count
python3 -c "
import json, glob
state = glob.glob('rtl-test/ol_weight_gen/runs/RUN_*/66-checker-magicdrc/state_out.json')
d = json.load(open(sorted(state)[-1]))
print(d.get('metrics', {}).get('magic__drc_error__count', 'not found'))
"
```

---

## Reading results

```bash
# stdout (up to max_log_tail_lines via API)
curl -s http://nas.home:4783/api/jobs/643/log/out | python3 -c "
import json, sys; [print(l) for l in json.load(sys.stdin)['lines']]"

# full stdout directly from NFS
cat /srv/eda/logs/timothyn/job-643.o

# stderr
cat /srv/eda/logs/timothyn/job-643.e
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
    STATE=$(curl -s $HLAB_SGE_URL/api/jobs/$JOB_ID | python3 -c \
        "import json,sys; print(json.load(sys.stdin)['state'])")
    [ "$STATE" = "DONE" ] || [ "$STATE" = "FAILED" ] && break
    sleep 5
done

# 5. Check outcome
EXIT=$(curl -s $HLAB_SGE_URL/api/jobs/$JOB_ID | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['exit_code'])")
if [ "$EXIT" = "0" ]; then
    cat /srv/eda/designs/$USER/result.txt
else
    echo "Job failed — stderr:" >&2
    cat /srv/eda/logs/$USER/job-$JOB_ID.e >&2
fi
```
