---
name: block-regression
description: Use when running the cocotb regression suite for a specific src/ RTL block via SGE (not a single one-off test). Triggers on "run regression for <block>", "regress psram_buf_ctrl", "run the full test suite for this block", "smoke test <block>". Currently onboarded blocks: psram_buf_ctrl. See "Adding a new block" to extend.
---

# Per-block cocotb regression via SGE

Runs the full set of cocotb suites relevant to one RTL block, as an SGE job (or jobs), and
reports pass/fail per suite. This is the operational counterpart to a block's verification-plan
doc under `planning/verification-plan/` (e.g. `psram-buf-ctrl-verification-plan.md` §3) — that doc
says *what* to run and *why*; this skill runs it.

**Known constraint (do not silently "fix"):** the SGE daemon's default job image is
`hpretl/iic-osic-tools:2026.04` (`/etc/hlab-sge/config.yaml`), and `hqsub` has no per-job image
override. CLAUDE.md forbids `:2026.04`/`:latest` — only `chipathon26` — but that policy is aimed
at physical-design flows (PDK/cell-library version sensitivity); cocotb/Verilator/Icarus sim
doesn't touch the PDK. Confirmed acceptable to run block regressions on the default image
(user decision, 2026-07-20) — **do not** edit the shared daemon config to "fix" this without
asking first, it affects every user's jobs.

## Why every suite shares one harness

Every block's cocotb suites instantiate the **full `trouper_top.v`** (not the block in isolation)
via `cocotb/hdl/tb_trouper_cocotb.v` + `cocotb/hdl/psram_model.v`. There is no per-block isolated
testbench. Two consequences:
- A regression in block X can surface in a suite that doesn't look X-specific at a glance —
  run every suite in the block's row below, not just the ones with the block's name in them.
- Conversely, a failing suite after a block-X change doesn't automatically mean the bug is in X —
  check whether the failure is in code the change actually touches before assuming otherwise.

## Block → suite mapping

| Block (`src/.../<file>.v`) | Suites (`cocotb/<dir>`, plain `make`) | Special-arg suites | Verification plan |
|---|---|---|---|
| `control/psram_buf_ctrl.v` | `replay_delay`, `replay_data`, `psram_ops`, `qspi_owner`, `sc_ant_sel`, `noise_trig`, `reg_reset_sweep`, `trouper_top`, `bypass_e2e` | `trouper_capture` (needs a real `.npy` capture — see below) | `planning/verification-plan/psram-buf-ctrl-verification-plan.md` |

Only `psram_buf_ctrl` is onboarded today. See **Adding a new block** below before running this
for anything else — do not guess a suite list from the block's name.

## Procedure

### 1. Sync the working tree to your NFS designs dir

SGE jobs run against `/foss/designs/lora-mimo` → `/srv/eda/designs/<user>/lora-mimo` (NFS), which
is a plain file copy, **not** a git checkout — it does not auto-track your local working tree,
including uncommitted changes. Sync before every run:

```bash
USER=$(whoami)
NFS=/srv/eda/designs/$USER/lora-mimo
mkdir -p "$NFS"
rsync -au src/     "$NFS/src/"
rsync -au cocotb/  "$NFS/cocotb/"
rsync -au formal/  "$NFS/formal/"
# sanity check the actual DUT file matches before trusting the run:
diff src/control/psram_buf_ctrl.v "$NFS/src/control/psram_buf_ctrl.v" && echo "DUT IN SYNC"
```

Do **not** `rsync --delete` or sync `ip/` (≈400 MB, third-party, unchanged) — this NFS tree may
hold other users'/other blocks' state you don't want to disturb.

### 2. Write and submit the self-contained-suites job

```bash
cat > /srv/eda/designs/$USER/<block>_regression.sh << 'EOF'
#!/bin/bash
set -uo pipefail
cd /foss/designs/lora-mimo

SUITES="<space-separated suite list from the table above, minus special-arg suites>"

FAILED=""
for d in $SUITES; do
  echo "=== cocotb/$d ==="
  ( cd "cocotb/$d" && make )
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "*** FAILED: $d (exit $rc) ***"
    FAILED="$FAILED $d"
  else
    echo "*** PASSED: $d ***"
  fi
done

echo ""
echo "===== SUMMARY ====="
if [ -z "$FAILED" ]; then
  echo "ALL SUITES PASSED"
  exit 0
else
  echo "FAILED SUITES:$FAILED"
  exit 1
fi
EOF

export HLAB_SGE_URL=http://nas.home:4783
hqsub --name <block>-regression --cpus 4 --mem 8G \
  /srv/eda/designs/$USER/<block>_regression.sh
```

Poll to completion per the `hlab-sge` skill (`hqstat --json` or `hqwait`, terminal states
`DONE`/`FAILED`/`CANCELLED`). Prefer `Bash` with `run_in_background: true` running the poll loop
rather than sleeping in the foreground.

### 3. Special-arg suites — `trouper_capture` (psram_buf_ctrl, trouper_top-adjacent blocks)

`trouper_capture` replays a real captured `.npy` IQ file and is **not** self-contained — a bare
`make` asserts immediately (`CAPTURE_NPY` required), and its documented default
(`CAPTURE_NSAMP=60000` from `CAPTURE_START=0`) does **not** reliably land on the packet burst
(confirmed failure mode: `"sc_lock never fired over the capture window"`). Always compute the real
window first:

```bash
# capture .npy files are not in git — pull one from an existing NFS designs checkout if you
# don't have one, e.g.:
#   cp /srv/eda/designs/timothyjabez/lora-mimo/lora-capture/captures/<SF7-BW250-*.npy> \
#      /srv/eda/designs/$USER/lora-mimo/lora-capture/captures/

python3 cocotb/tests/sweep_captures.py lora-capture/captures
# -> one TSV row per (SF,BW) capture: <npy>  <sf>  <bw>  <start>  <nsamp>  <stage>
```

Then submit a separate job using that row's `start`/`nsamp`/`stage` verbatim:

```bash
cat > /srv/eda/designs/$USER/<block>_trouper_capture.sh << 'EOF'
#!/bin/bash
set -uo pipefail
cd /foss/designs/lora-mimo/cocotb/trouper_capture
make CAPTURE_NPY=/foss/designs/lora-mimo/lora-capture/captures/<file>.npy \
     CAPTURE_SF=<sf> CAPTURE_BW=<bw> CAPTURE_START=<start> CAPTURE_NSAMP=<nsamp> \
     CAPTURE_STAGE=<stage>
rc=$?
[ $rc -eq 0 ] && echo "*** PASSED: trouper_capture ***" || echo "*** FAILED: trouper_capture (exit $rc) ***"
exit $rc
EOF

hqsub --name <block>-trouper-capture --cpus 4 --mem 8G \
  /srv/eda/designs/$USER/<block>_trouper_capture.sh
```

### 4. Formal (if the block has a `formal/*.sby`)

Run separately, not part of the pass/fail suite loop — check whether the block's `ifdef FORMAL`
instantiation is actually wired into the RTL before trusting a green result (`psram_buf_ctrl.v`
did not have one as of 2026-07-19; a "pass" with zero assertions wired in is vacuous, not
coverage):

```bash
sby -f formal/<block>_formal.sby
```

### 5. Report

Summarize as a table: suite → PASS/FAIL/error, one row per suite in the block's mapping row
(including the special-arg ones). Cross-check any failure against the block's
`planning/verification-plan/*.md` before concluding it's a regression — rule out harness/argument
mistakes (missing capture params, stale NFS sync) first, the same way `trouper_capture`'s first
two runs against this block turned out to be invocation errors, not RTL bugs.

## Adding a new block

1. Find every cocotb `Makefile` whose `VERILOG_SOURCES` includes the block's `.v` file:
   `grep -l '<block>.v' cocotb/*/Makefile`. Every hit is a suite for that block's row.
2. Check each hit's `Makefile` header comment / `COCOTB_TEST_MODULES` for any required env vars
   (the `trouper_capture` pattern — grep for `os.environ` in the test module `cocotb/tests/test_*.py`
   if unsure) — put those in the "special-arg suites" column, not the plain-`make` column.
3. Check whether `formal/<block>_formal.sv`/`.sby` exists; note it even if currently dead (see §4).
4. Add a row to the mapping table above and link the block's verification-plan doc if one exists
   under `planning/verification-plan/` (or `planning/` for older ones) — create one first if not,
   per the pattern in `psram-buf-ctrl-verification-plan.md`.