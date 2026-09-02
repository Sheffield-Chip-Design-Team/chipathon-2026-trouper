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

**Host-side path:** `$RUN_DIR`/`/foss/runs` resolves on the host to
`/srv/eda/runs/<user>/<--project value>/...` — a sibling of `/srv/eda/designs/`
and `/srv/eda/logs/`. Confirmed by inspection: `hqsub --project synth_area ...`
produced `/srv/eda/runs/timothyn-dev/synth_area/trouper_top_src_20260728_v3/`.
See the "Complete example" below for how this plays out end to end.

## Static/shared input data — `$SHARED_DIR`/`/foss/shared`

For large static input files that shouldn't be staged into the project
snapshot on every submit (e.g. captured IQ datasets), hlab-sge's
`shared_data_dir` feature mounts a fixed host directory **read-only at
`/foss/shared` automatically in every job** (batch, interactive, and VNC —
no per-submit flag needed), with a `SHARED_DIR=/foss/shared` env var set
inside the container. Nothing needs to be passed at `hqsub` submit time —
it's always there.

For this repo, that mount is populated with real measured LoRa IQ captures:
`$SHARED_DIR/lora-mimo-captures/captures/*.{npy,iq,json}` (SF7–SF12, various
BW/preamble/SNR/pathloss combos), sourced from
`/srv/eda/shared/lora-mimo-captures/captures/` on the host.

Confirmed end-to-end (job 3706): `rtl-test/scripts/run_capture_playback.sh`
reads a capture straight from `$SHARED_DIR` with no staging step and no
`--project`-time argument:

```bash
SHARED=${SHARED_DIR:-/foss/shared}
CAPTURE_NPY=${CAPTURE_NPY:-$SHARED/lora-mimo-captures/captures/lora_20260621_092430_SF7-BW125-Pre8.npy}
```

Two gotchas found while validating this:
- Inside the job, `/foss/shared` is read-only, same as `/foss/designs` — only
  read captures from it, never write there; write outputs to `$RUN_DIR`.
- `test_capture_playback.py`'s own defaults (`CAPTURE_START=0`,
  `CAPTURE_NSAMP=60000`) do **not** reliably land on the packet burst for a
  given capture file — this looks like a passing infra check but fails with
  a misleading `"sc_lock never fired over the capture window"` DSP
  assertion, not an SGE/mount problem. Compute the real window first with
  `python3 cocotb/tests/sweep_captures.py <captures_dir>` (pure Python/numpy,
  runs fine outside the container) and use its `start`/`nsamp` columns —
  see the `block-regression` skill §3 for the general pattern.

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
#    container, not under the read-only /foss/designs mount. On the host,
#    $RUN_DIR resolves to /srv/eda/runs/<user>/<--project value>/... — a
#    sibling of /srv/eda/designs/ and /srv/eda/logs/ — so the raw file here
#    would be at /srv/eda/runs/timothyn-dev/lora-mimo/result.txt)
EXIT=$(hqstat --json --all | python3 -c \
    "import json,sys; jobs=json.load(sys.stdin); m=[j for j in jobs if j['id']==$JOB_ID]; print(m[0]['exit_code'] if m else '')")
if [ "$EXIT" != "0" ]; then
    echo "Job failed — stderr:" >&2
    cat /srv/eda/logs/$USER/job-$JOB_ID.e >&2
fi
```

## Judging a long job: is it running, or hung?

For anything measured in tens of minutes, the question "is this still making
progress?" comes up before the job ends. Getting it wrong is expensive in both
directions: cancelling a healthy job wastes the run, and waiting on a wedged one
wastes the afternoon.

### Never use these as liveness signals

- **Log size or mtime.** Job logs are capped at **2 MiB**, so a long job can stop
  growing while perfectly healthy. Worse, many tests log only on *events* — a
  cocotb run that waits ~2 s of simulated time between packets legitimately
  prints nothing for 98% of its wall-clock. Observed 2026-08-16: job 4409 wrote
  nothing for 11 minutes mid-run and then passed.
  (A job that follows "Emit progress into the log too" below *is* readable this
  way — but only because it was instrumented to be; assume it wasn't until you
  see a heartbeat line.)
- **`docker ps` on one node.** The job may be on another worker. Checking only
  the local box has already produced a wrong "job is dead" call.
- **`hqstat`.** It does not display `STAGING` jobs and reports "No jobs found"
  for completed ones. A freshly submitted job is routinely invisible here.

### Use progress artifacts on the filesystem instead

Read incremental state under the run dir. Most job types already emit it:

| job type | progress artifact |
|---|---|
| P&R (LibreLane/OpenROAD) | numbered step folders appearing in the run dir |
| multi-point sweeps | a summary file appended per point (e.g. `sweep_summary.txt`) |
| formal (SymbiYosys) | per-property output |
| characterization | per-point result files |
| **long single-shot sims** | **usually nothing — needs instrumentation** |

Prefer these over the log in all cases: they are immune to the 2 MiB cap and
need no parsing. A sweep that appends one line per point can be read mid-run to
see exactly how far it got.

If a job type has no incremental artifact, add a minimal one rather than logging
more: a `progress.txt` under `$RUN_DIR` carrying a phase, a **monotonic
quantity**, and the **denominator** (e.g. `0.20 s / 2.075 s (10%)`), rewritten
at bounded intervals. Bound the number of writes so the log cap can never
consume the verdict. A wall-clock heartbeat is not enough on its own — it proves
the wrapper is alive, not that the work advanced; always include a quantity that
comes from the job itself.

Mirror that same line to stdout so it also shows up in the web UI — see below.

For test-side instrumentation of cocotb sims, see the `block-regression` skill.

### Emit progress into the log too, so the web UI shows it

The web UI (and `hqlog --follow`) renders the job's live stdout/stderr. A
progress artifact under `$RUN_DIR` is invisible there — it's on NFS, not in the
stream — so a job that only writes `progress.txt` still *looks* dead in the
browser. Write progress to **both**: the file for cheap mid-run polling, stdout
for the UI.

Two things have to be right for that to actually appear:

**1. Unbuffer the stream.** stdout is a pipe here, not a TTY, so C stdio and
Python switch to 4 KiB block buffering: a job can produce output for an hour and
the UI shows nothing until it exits or fills a block. Force line buffering on
anything long-running:

```bash
export PYTHONUNBUFFERED=1        # python, cocotb
stdbuf -oL -eL vvp sim.vvp       # iverilog/vvp, ngspice, magic, most C tools
librelane ... 2>&1 | stdbuf -oL cat   # ...including through a pipe
```

`echo`/`printf` from the job script itself is already unbuffered — this only
bites tools.

**2. Print a heartbeat on a bounded interval.** Same rule as `progress.txt`:
a phase, a **monotonic quantity from the job itself**, and the **denominator**.
Wall-clock alone proves the wrapper is alive, not that work advanced.

```bash
progress() {   # phase, done, total
  printf '[%s] %-14s %s/%s (%d%%)\n' \
    "$(date -u +%H:%M:%S)" "$1" "$2" "$3" $(( 100 * $2 / $3 ))
  printf '%s %s/%s\n' "$1" "$2" "$3" > "$RUN_DIR/progress.txt"
}
```

For a tool that emits its own progress but too densely, throttle rather than
suppress — one line per N units, not per unit:

```bash
stdbuf -oL librelane ... 2>&1 | awk 'NR%50==0 || /^\[(ERROR|WARNING)/'
```

**Budget the writes against the 2 MiB log cap.** Once a job hits the cap its
output is truncated and the *verdict* — the pass/fail line at the end — can be
the part that's lost, which is strictly worse than the silence you were trying
to fix. Pick the interval from the expected wall time so the whole run costs a
few hundred lines, not tens of thousands: roughly **one line per 30–60 s** for
a multi-hour P&R, per 10 s for a ~20-minute sim. Never per simulated packet or
per placement iteration.

### Checking a job's true state

`hqstat` is unreliable (above). `hqdel <id>` prints the real state in its
confirmation prompt, so it doubles as a **read-only probe** when answered `n`:

```bash
echo n | hqdel 4402      # -> "Cancel job 4402 (name, RUNNING)? [y/N]: Aborted!"
```

Also note `hqsub` can time out (`Request to .../api/jobs timed out after 180s`)
while the job **was** created — staging is synchronous and can outlast the HTTP
request. Do not retry blindly; probe first, or you create a duplicate (observed
2026-08-16: jobs 4393/4394).
