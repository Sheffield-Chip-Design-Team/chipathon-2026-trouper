---
name: run-pnr
description: Submit a LibreLane synthesis or full P&R run for a trouper RTL block to the homelab SGE scheduler, then poll it to completion and summarize the outcome. Use whenever the user asks to "run synth", "run P&R", "do PnR", "check timing on my RTL changes", or similar for any rtl-test/ol_<block> design.
---

# run-pnr

Runs LibreLane (synth-only or full flow) on SGE for a block under `rtl-test/ol_<block>/`,
against a config the user names (or the most-recently-modified `config_current*.json` /
`config_scoped_v*.json` in that block dir if they don't specify one — check `ls -lat` and
confirm with the user before submitting, since these repos accumulate dozens of config
variants and guessing wrong wastes a run).

Ask the user (via AskUserQuestion if ambiguous) whether they want:
- **Synth-only** (`--to Yosys.Synthesis`) — fast (~30s), checks elaboration/latches/cell
  count, no timing/DRC/LVS signal.
- **Full P&R** — placement, CTS, route, STA, and (if the config enables
  `RUN_MAGIC_DRC`/`RUN_LVS`) DRC/LVS. Takes much longer (tens of minutes to hours
  depending on die size/utilization).

## Steps

1. **Sync RTL + the target config/SDC to NFS.** The SGE container reads
   `/foss/designs/lora-mimo/...`, which is `/srv/eda/designs/timothyn-dev/lora-mimo/...`
   on the host (NFS is mounted locally too — no need to go through a job just to copy files).
   `timothyn-dev` is the current working owner (migrated from `timothyjabez` 2026-07-27/28
   — if you see jobs stop around ID 2174, that's the old owner; don't sync there):

   ```bash
   LOCAL=/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper
   NFS=/srv/eda/designs/timothyn-dev/lora-mimo
   rsync -a --delete "$LOCAL/rtl-test/rtl/" "$NFS/rtl-test/rtl/" --exclude='*.vvp'
   rsync -a "$LOCAL/rtl-test/ol_<block>/<config>.json" "$NFS/rtl-test/ol_<block>/"
   # also sync any dir::-referenced SDC / .cfg files the config points to (PNR_SDC_FILE,
   # SIGNOFF_SDC_FILE, IO_PIN_ORDER_CFG, PDN_CFG) — grep the config for "dir::" and sync those too
   ```

   If the block also needs `sim/` (e.g. cocotb-driven flows, not plain LibreLane), sync
   that too — see the "Sync full scope to NFS" lesson: a stale NFS mirror costs debug
   cycles that look like RTL bugs but aren't.

2. **Write the job script to NFS** (not local — `hqsub` needs the script to already be
   at the `/srv/eda/designs/...` path):

   ```bash
   cat > /srv/eda/designs/timothyjabez/lora-mimo/rtl-test/<descriptive-name>.sh << 'EOF'
   #!/bin/bash
   set -e
   LOG=/foss/designs/lora-mimo/rtl-test/ol_<block>/<descriptive-name>.log
   exec > >(tee "$LOG") 2>&1
   echo "=== <what this checks> START $(date --iso-8601=seconds) on $(hostname) ==="
   cd /foss/designs/lora-mimo/rtl-test
   librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
             [--to Yosys.Synthesis] ol_<block>/<config>.json
   echo "=== EXIT $? $(date --iso-8601=seconds) ==="
   EOF
   chmod +x /srv/eda/designs/timothyjabez/lora-mimo/rtl-test/<descriptive-name>.sh
   ```

   Never `docker run` this locally — always via SGE (see `feedback_use_sge` memory).
   Do not use `hpretl/iic-osic-tools:latest` or `:2026.04` — only `:chipathon26`.

3. **Submit:**

   ```bash
   export HLAB_SGE_URL=http://nas.home:4783
   hqsub --name <descriptive-name> --cpus <2 for synth-only, 10 for full P&R (matches DRT_THREADS)> \
       --mem <4G synth-only, 12G full P&R> \
       /srv/eda/designs/timothyjabez/lora-mimo/rtl-test/<descriptive-name>.sh
   ```

4. **Poll to a terminal state without spamming updates.** Full P&R can run a long time —
   use the Monitor tool with a poll interval matched to expected duration (30s for
   synth-only, **180s+** for full P&R) so notifications don't fire every 30s for an hour:

   ```bash
   export HLAB_SGE_URL=http://nas.home:4783
   while true; do
     state=$(hqstat --json | python3 -c "
   import json,sys
   for j in json.load(sys.stdin):
       if j.get('id')==<JOB_ID>:
           print(j.get('state')); break
   ")
     [ "$state" = "DONE" ] || [ "$state" = "FAILED" ] || [ "$state" = "CANCELLED" ] && { echo "terminal: $state"; break; }
     sleep 180
   done
   ```

5. **On completion, use the `pnr-results` skill to summarize** (exit code, cell/area for
   synth-only; WNS per corner + DRC/LVS error counts for full P&R). Read
   `/srv/eda/logs/timothyjabez/job-<ID>.o` / `.e` if exit code is non-zero.

## Gotchas learned the hard way

- This dev machine (`gaming-pc`) **is** an SGE worker node — cap concurrent P&R jobs at
  ~3 to avoid starving other runs (see `project_this_host_is_gamingpc` memory).
- `ol_mimo_rx_top` is currently a symlink back to `ol_trouper_top` (self-loop) — real
  trouper_top work happens in `ol_trouper_top`, not `ol_mimo_rx_top`, despite what the
  top-level CLAUDE.md repo-layout comment says.
- Concurrent worktree sessions share one NFS mirror — a sync from another worktree can
  silently clobber yours mid-job. Re-verify the NFS copy (`diff -rq`) before deep-diving
  a confusing failure.
- AS-cell configs (`gf180mcu_as_sc_mcu7t3v3`) are a different flow entirely — see
  AGENTS.md `--pdk-root /foss/designs/pdk_overlay_as` invocation. Don't mix them up with
  the default FD-cell flow above.
