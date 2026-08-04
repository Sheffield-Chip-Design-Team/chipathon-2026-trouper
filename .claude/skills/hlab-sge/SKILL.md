---
name: hlab-sge
description: Run and manage EDA jobs on a homelab-sge job scheduler using its CLI (hqsub, hqstat, hqhost, hqlog, hqwait, hqdel, hqlogin). Use when a project needs to submit a batch EDA/simulation job to the scheduler, check queue or node status, follow job logs, wait on a job in a pipeline, cancel a job, or open an interactive/VNC session. This is the everyday job-operations skill; for chipathon-specific SGE usage (PDK selection on this image, the rtl-test/ol_*/runs NFS symlink layout), use the sge-job skill instead.
---

<!--
SYNCED COPY — source of truth is git.home/TimothyNewman/homelab-sge, .claude/skills/hlab-sge/SKILL.md
Last synced from upstream commit b654aa19b456f463fd458ba4d716e413644fd3e7 (2026-07-28, dev branch).
This is a manual copy, not a submodule/symlink — re-sync periodically by diffing against
the homelab-sge repo checkout (see project_hlab_sge_skill_split memory for why).
NOTE: the frontmatter `description` here is intentionally customized (points at this repo's
own `sge-job` skill, not upstream's `hlab-sge-jobs-debug`) — don't overwrite it wholesale on
future syncs, merge in body/content changes only.
-->

# homelab-sge — running jobs

homelab-sge is an SGE-style job scheduler that runs EDA workloads in isolated Docker
containers with CPU/RAM/GPU accounting. You interact with it through a handful of `hq*`
CLI tools. Treat `<cmd> --help` as the source of truth for the full flag list; this skill
covers the commands and the flags you'll actually reach for.

## Prerequisites

- The `hq*` CLIs must be installed and on `PATH`, and a daemon must be reachable.
- Auth is by API token. Provide it via the `HLAB_SGE_TOKEN` env var, or write it to
  `~/.config/hlab-sge/token` (chmod 600). Without a valid token every call returns 401.
- If you don't have a token, ask the scheduler's admin for one — it's not self-serve.

## Submit a batch job — `hqsub`

```bash
hqsub --name <name> --cpus <n> --mem <8G> [options] <script.sh>
```

The positional argument is a shell script; it runs as `bash <script>` inside the container.
Common flags:

- `--name <name>` — human label shown in the queue.
- `--cpus <n>` — CPU cores to reserve.
- `--mem <8G|512M>` — memory; accepts `G`/`M` shorthand.
- `--gpu 0|1` — whether the job needs the GPU. It's a single on/off slot, **not** VRAM or
  fractional — request `1` if the job touches the GPU at all, `0` otherwise.
- `--priority <1-10>` — higher runs sooner among pending jobs.
- `--node <name>` — pin the job to a specific worker node (otherwise scheduler picks one).
- `--after <id,id>` — hold this job until the listed job IDs finish (dependencies).
- `--retry-on-exit <codes>` — auto-retry the job if it exits with one of these codes.
- `--storage default|nfs|scratch` — where designs are staged. Use `scratch` for
  metadata-heavy flows (lots of small file opens) where shared-storage latency hurts.
- `--project <name>` — scope the input snapshot to `designs_dir/<user>/<project>` instead
  of the user's whole designs root. **Use this whenever the design repo is more than a
  few hundred MB** — an unscoped submit against a multi-GB or multi-project root can take
  well over a minute to stage (see the timeout note below) or hit the snapshot's size/file
  bounds outright (`413`).
- `--snapshot-exclude <glob>` — repeatable; skip extra paths from the snapshot on top of
  whatever the daemon already excludes (it can only add exclusions, not remove one the
  daemon config sets). No `/` matches a basename at any depth (e.g. `*.vcd`); a `/` in
  the pattern matches a source-relative path (e.g. `fpga-emul/vivado_proj/**`). Reach for
  this when a project has large generated/output content next to its inputs that isn't
  worth changing the daemon config for.

**Never submit concurrently from two worktrees (or any two working directories) against
the same `--project` name.** The snapshot destination is keyed by `<user>/<project>`, not
by the local directory you ran `hqsub` from — two overlapping submits under the same
project both hash/copy into that one NFS location with no locking of their own, so one
submit's in-flight copy can be partially overwritten by the other's, and the job that gets
staged may run against a corrupted mix of both trees. Serialize with `hqwait` between them
so one snapshot finishes staging before the next begins:

```bash
id=$(hqsub --project lora-mimo --name from-worktree-a build.sh | awk '{print $NF}')
hqwait "$id"   # must return before a second worktree submits under the same --project
```

Before submitting under a shared `--project`, check whether another submit against it is
already in flight — `hqstat --all --json` and filter for jobs in `STAGING`/`PENDING` state
whose name or script path indicates the same project. There's no per-project lock to query
directly, so this check is best-effort: a job already past `STAGING` into `RUNNING` is no
longer a staging risk, but one still `STAGING` (or one submitted moments ago that hasn't
shown up in `hqstat` yet) means you must hold off and `hqwait` on it first rather than
submitting anyway.

`hqsub` prints the assigned job ID. For interactive or GUI work, use `hqlogin` instead —
`hqsub` is batch-only.

### Submit can still take a while to return

`hqsub` blocks until snapshot staging (hashing + copying) finishes, which can take a good
while for a real project even with `--project` scoping — 100–150 s isn't unusual for a
multi-GB design tree. The client timeout was raised to 180 s specifically for this, so a
plain hang usually means it's still staging, not stuck. If you ever do see a timeout error
(`Error: Request to http://<host>:4783/api/jobs timed out after ...s`), treat it as a
client-side timeout, not a submission failure — the job was very likely already accepted
and is staging server-side. Check `hqstat` before resubmitting; resubmitting on sight of
this error can queue a duplicate job.

## Check status — `hqstat` / `hqhost`

- `hqstat` — table of active and recent jobs (ID, name, state, resources), **your own jobs
  only** by default. Add `--all` to see every user's jobs (e.g. after the 10 s-timeout case
  above, when you need to find the job you just submitted by name). `hqstat --wide` adds
  peak RAM / CPU% columns; `hqstat --json [--all]` for machine-readable output when
  scripting a poll loop.
- `hqhost` — per-node resource summary (free vs. used CPU/RAM/GPU). Use this to see whether
  there's room before submitting, or `hqhost --json` for machine-readable output.

Job states: `STAGING → PENDING → RUNNING → DONE | FAILED | CANCELLED`. A cancel of a
running job goes through an intermediate `RUNNING → CANCELLING → CANCELLED` — the job keeps
its resource reservation until the container is confirmed dead, so don't assume `hqhost`
shows the freed capacity the instant you run `hqdel`.

## Follow logs — `hqlog`

```bash
hqlog <id> [--stream out|err] [--follow]
```

- `--stream err` — show stderr (default is stdout).
- `--follow` / `-f` — stream live as the job runs.

## Wait for a job — `hqwait`

```bash
hqwait <id>
```

Blocks until the job reaches a terminal state and **exits with the job's own exit code** —
so it composes in pipelines:

```bash
id=$(hqsub --name build --cpus 4 --mem 8G build.sh | awk '{print $NF}')
hqwait "$id" && ./next-step.sh
```

## Cancel — `hqdel`

```bash
hqdel <id> [id...] [--force]
```

Cancels queued or running jobs. Jobs already `DONE`/`FAILED`/`CANCELLED` can't be cancelled.
Without `--force`, `hqdel` prompts `Cancel job <id> (<name>, <state>)? [y/N]` and waits for
input — in a non-interactive context (script, no TTY) either pass `--force` or pipe an
answer, e.g. `echo y | hqdel <id>`.

## Interactive / GUI sessions — `hqlogin`

For an interactive shell, X11-forwarded tools, or a browser-based VNC desktop, use
`hqlogin` (not `hqsub`). It allocates the session and handles X11/VNC setup for you; see
`hqlogin --help` for the session flags.

## If a job won't start

Work through it in order:

1. `hqstat` — is it `PENDING` because of a `--after` dependency that hasn't finished yet?
2. `hqhost` — is there actually free CPU/RAM/GPU on the target node? A `--node`-pinned job
   waits until *that* node has room; an unpinned job waits until *some* node does.
3. `hqlog <id> --stream err` — read the container's error output for a real failure.
4. A `FAILED` state with a nonzero exit code usually means the job **script** failed — that's
   the script's bug, not the scheduler. Check the log before assuming an infrastructure issue.
