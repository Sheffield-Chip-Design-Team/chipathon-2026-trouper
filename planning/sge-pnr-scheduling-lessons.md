# SGE PnR Job-Scheduling Lessons

Operational lessons for running LibreLane `trouper_top` P&R on the homelab SGE
cluster (nas-server master + gaming-pc worker). Learned the hard way 2026-06-23
when a 10-wide P&R batch deadlocked gaming-pc.

## TL;DR rules

1. **Cap concurrent full-signoff P&R at ~3 per node.** Each job peaks **2–3 GB**
   at detailed routing. gaming-pc has 30 GB; ~7 fit by memory *reservation* but
   they collide at the peak-memory stage and deadlock.
2. **Request real resources** — defaults (`--cpus 1 --mem 4G`) are too thin:
   - `--cpus 2` so detailed routing actually parallelises (see #4).
   - `--mem 6G` for headroom over the 2–3 GB DRT peak.
3. **RAM is the binding constraint, not cores.** gaming-pc: 22 cores but 30 GB.
   Jobs run out of memory long before cores. Size batches by memory.
4. **`--cpus-hard` (default) caps each job to its reserved cores.** So
   `DRT_THREADS=10` in the config is a no-op at `--cpus 1` — 10 threads crammed
   onto 1 core. Give `--cpus 2`+ for DRT to use them. **Measured impact:** same
   `trouper_top` routing took **~2.5 h at 1 core vs ~35 min at 2 cores** —
   detailed routing is the long pole and it is the part that parallelises.
   1-core jobs *look* stuck but are just serial — confirm via incrementing
   `drt-run-*/` ODB count, not by assuming a hang.

## How to read true state (SGE lies by omission)

- **SGE shows *reservations*, not utilisation.** `hqhost` "Alloc" = sum of
  `req_cpus`/`req_mem`, not actual use. Per-job `peak_cpu_pct`/`peak_ram_mb` are
  **null** (not collected). For real memory use `free -g` *on the node*.
- **Job `state: RUNNING` does not mean progressing.** A swap-stalled/hung job
  stays RUNNING for hours. **Liveness = file-mtime age in the run dir**, not SGE
  state:
  ```
  find <run_dir> -type f -printf '%T@\n' | sort -rn | head -1   # newest write
  ```
  No new files for >10 min at a heavy stage = hung.
- **Beware clock skew** between this host and the cluster/NFS when comparing
  mtimes — use epoch (`%T@`) + `date +%s`, not `find -newermt`.

## Deadlock signature & recovery

**Signature:** many jobs frozen (no writes for tens of minutes), all clustered at
`45-openroad-detailedrouting` with **0-byte** `openroad-detailedrouting.log`
(OpenROAD froze before emitting routing output), node `free -g` near zero. The
only thing "alive" may be a cancelled-but-not-killed zombie hogging RAM.

**Recovery (this host *is* gaming-pc — docker access is direct):**
```bash
docker ps --format '{{.Names}}' | grep trouper
docker stop hlab-sge-job-<ID> ...        # frees REAL ram; SGE then marks FAILED
```
- `hqdel` does **NOT** stop the container (documented bug:
  `~/Documents/claude/homelab-sge/bugs/cancelled-running-job-container-keeps-executing.md`).
  Cancelling to relieve contention does not work — it just creates zombies that
  keep holding RAM. Only `docker stop` on the worker node frees memory.
- gaming-pc containers: stop directly here. nas-server containers: need
  `docker stop` on nas (no remote shell from gaming-pc) — `hqdel` leaves them
  running there too.

## Concurrency math (is parallel worth it?)

- Per-job runtime under heavy contention stretched ~2.4× (25 → 60 min). Total
  *batch* wall-clock is still lower than serialising **iff nothing deadlocks**.
  The deadlock risk is the cap: 3/node parallel = fast and safe; 10-wide =
  deadlock and net-slower (everything frozen).

### Measured 2026-06-24: 3-wide is NOT contention-bound (the slowdown is serial DRT, not sharing)

Three full-signoff P&R jobs running concurrently on gaming-pc (24 cores / 31 GB),
all in `45-openroad-detailedrouting`. Direct measurement (`ps`, `top`, `free`):

```
Total CPU used by ALL 3 openroad jobs:  ~1.9 cores of 24 busy  → 22 cores idle
RAM:  15 GB used, 15 GB available, swap 0                       → no memory pressure
Per job: 60–94% CPU (none pegged at a full core = none CPU-starved)
Load average: 29   ← a MIRAGE, see below
```

**Conclusion: at 3-wide, the jobs do not meaningfully starve each other.** Only ~2
of 24 cores do real work; 15 GB RAM free. Running them one-at-a-time would **not**
speed any of them up — the bottleneck is OpenROAD's **single-threaded DRT phases**
(pin-access analysis, parts of rip-up/reroute), which use ~1 core *regardless* of
how many are free or how many jobs run. A serial algorithm can't use idle cores.

**Load average is misleading here — do not size batches by it.** Each job spawns 10
OpenMP/TBB worker threads that **spin-wait** (busy-poll) during the serial phase.
They show as "running" (`ps -L` → `10 Rl`) and inflate load average, but burn almost
no useful CPU. Load said 29 on a machine that was actually ~92% idle. Use **`top`
openroad CPU-sum and `free -g`**, never load average, to judge real contention.

**Reconciles with rule #4 (2-core 35 min vs 1-core 2.5 h):** DRT has BOTH serial
phases (~1 core, can't be helped) AND parallel routing-worker passes (scale with
cores). The 2-core win is real — it's the *parallel* passes. But the *serial* passes
dominate wall-clock on a tight die and are immune to both more cores and fewer
co-tenants. So: give each job 2 cores for its parallel passes, run up to ~3 jobs
together (RAM-safe, ~free), and accept that a hard die's DRT is just slow.
- I/O is **not** the bottleneck — NFS measured healthy under load (synced 4 KB
  writes ~5 ms, stat instant). The slowdown and freezes are **memory** (swap +
  shrunken page cache), not disk/network.
- Jobs submitted in the same second phase-lock and pile up together at the same
  slow single-threaded stage (repair-antennas, detailed-routing setup) — another
  reason to keep batches small.

## Detecting "did detailed routing actually run?"

DRT-1231 (and OOM) abort *before* any routing. Proof a job got past it:
```
ls <run>/45-openroad-detailedrouting/drt-run-*/trouper_top.odb   # routed ODB exists
<run>/45-openroad-detailedrouting/drt-run-0/trouper_top.drc      # 0 bytes = clean
```
A routed ODB + advancement to `checkantennas-1`/`stapostpnr` = routing succeeded.

## Config-var gotchas (silent-ignore class)

- `DRT_THREADS` is capped by the cgroup `--cpus` (see #4) — looks set, does nothing.
- Verify list-valued knobs resolve: `GRT_LAYER_ADJUSTMENTS` is a 5-float list
  (Metal1–5); confirm in `runs/RUN_*/resolved.json` after a run, not just config.
- Same lesson as the SDC scoping bug: a wrong/ignored name fails silently — always
  confirm against `resolved.json`.

## Related

- Bug tracker: `~/Documents/claude/homelab-sge/bugs/cancelled-running-job-container-keeps-executing.md`
- Memory: `project_this_host_is_gamingpc`, `project_drt1231_clkbuf`
