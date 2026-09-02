---
name: block-regression
description: Use when running the regression suite for a specific src/ RTL block via SGE (not a single one-off test). Triggers on "run regression for <block>", "regress psram_buf_ctrl", "regress packet_ctrl_fsm", "regress spi_slave", "regress SPI slave", "regress reg_bank", "regress register bank", "run the full test suite for this block", "smoke test <block>". Currently onboarded blocks: psram_buf_ctrl, packet_ctrl_fsm, spi_slave, reg_bank. See "Adding a new block" to extend.
---

# Per-block regression via SGE

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

## Harness scope and suite selection

Most cocotb suites instantiate the **full `trouper_top.v`** via
`cocotb/hdl/tb_trouper_cocotb.v` + `cocotb/hdl/psram_model.v`. The exception currently
onboarded is `cocotb/packet_ctrl_fsm`, which instantiates `packet_ctrl_fsm.v` directly and
compares every sampled register with a Python reference model. Consequences:

- A regression in block X can surface in a suite that doesn't look X-specific at a glance —
  run every suite in the block's mapping row, not just a same-named suite.
- Conversely, a failing suite after a block-X change doesn't automatically mean the bug is in X —
  check whether the failure is in code the change actually touches before assuming otherwise.
- A Makefile that compiles a shared full-top block is only a **candidate** for that block's
  regression. The linked verification plan is authoritative about requirement ownership; do
  not inflate every shared block to every full-top suite merely because its source appears in
  `VERILOG_SOURCES`.

## Block → suite mapping

| Block (`src/.../<file>.v`) | Self-contained suites (`cocotb/<dir>`, plain `make`) | Special / additional targets | Verification plan |
|---|---|---|---|
| `control/psram_buf_ctrl.v` | `replay_delay`, `replay_data`, `psram_ops`, `qspi_owner`, `sc_ant_sel`, `noise_trig`, `reg_reset_sweep`, `trouper_top`, `bypass_e2e` | `trouper_capture` with a measured `.npy`; `formal/psram_buf_ctrl.sby` | `planning/verification-plan/psram-buf-ctrl-verification-plan.md` |
| `control/packet_ctrl_fsm.v` | `packet_ctrl_fsm`, `w_missed`, `bypass_e2e`, `sc_force_lock`, `trouper_top` | `formal/packet_ctrl_fsm.sby`; `rtl-test/tb/tb_pcfsm_b6_equiv.v`; measured-capture `test_weight_gen_spi_flow.py` and `test_capture_two_packet.py` when available | `planning/verification-plan/packet-ctrl-fsm-verification-plan.md` |
| `control/spi_slave.v` | `spi_cdc`, `psram_ops` | legacy `rtl-test/tb/tb_trouper_spi.v` (`tb_trouper_grp_arb.v` deleted 2026-09-01 with the Grouper boundary); standalone/formal targets are planned but do not exist yet | `planning/verification-plan/spi-slave-verification-plan.md` |
| `control/reg_bank.v` | `reg_reset_sweep`, `w_shadow_lock`, `sc_force_lock`, `noise_trig`, `psram_ops`, `w_missed`, `bypass_e2e`, `spi_cdc` | legacy `rtl-test/tb/tb_trouper_spi.v` (`tb_trouper_grp_arb.v` deleted 2026-09-01 with the Grouper boundary); standalone/formal targets are planned but do not exist yet | `planning/verification-plan/reg-bank-verification-plan.md` |

These four blocks are onboarded. For packet-control, SPI-slave, and register-bank
regressions, run the extra targets exactly as specified in the linked plan's §3; the
plain-`make` loop below covers only the self-contained cocotb column.

## Procedure

### 1. Sync the working tree to your NFS designs dir

SGE jobs run against `/foss/designs/lora-mimo` → `/srv/eda/designs/<user>/lora-mimo` (NFS), which
is a plain file copy, **not** a git checkout — it does not auto-track your local working tree,
including uncommitted changes. Sync before every run:

```bash
USER=$(whoami)
NFS=/srv/eda/designs/$USER/lora-mimo
mkdir -p "$NFS"
rsync -au src/           "$NFS/src/"
rsync -au cocotb/        "$NFS/cocotb/"
rsync -au formal/        "$NFS/formal/"
rsync -au rtl-test/rtl/  "$NFS/rtl-test/rtl/"
rsync -au rtl-test/tb/   "$NFS/rtl-test/tb/"
# sanity check the actual DUT file matches before trusting the run:
DUT=control/<block>.v
diff "src/$DUT" "$NFS/src/$DUT" && echo "DUT IN SYNC"
```

Do **not** `rsync --delete` or sync `ip/` (≈400 MB, third-party, unchanged) — this NFS tree may
hold other users'/other blocks' state you don't want to disturb.

### 2. Submit the block's suites through the unified runner

Do **not** hand-roll a suite loop. `cocotb/run_toplevel_regression_sge.sh` already does the
per-suite `make`, the writable `SIM_BUILD`/`COCOTB_RESULTS_FILE` redirection (`/foss/designs`
is read-only under SGE), the per-suite `run.log` + tally, and the summary. Pass the block's
suites via `SUITES`, which overrides its group selection:

```bash
cat > /srv/eda/designs/$USER/<block>_regression.sh << 'EOF'
#!/bin/bash
# SUITES = the block's row from the mapping table above.
export SUITES="<space-separated suite list from the table above>"
export JOBS=4     # suites run concurrently; needs ~1 core each
exec "${DESIGN_ROOT:-/foss/designs}/cocotb/run_toplevel_regression_sge.sh"
EOF

export HLAB_SGE_URL=http://nas.home:4783
hqsub --name <block>-regression --project lora-mimo --cpus 8 --mem 24G \
  /srv/eda/designs/$USER/<block>_regression.sh
```

The capture-driven suites (`trouper_capture`, `weight_gen_spi_flow`, `capture_two_packet`)
are runnable from the same script — they default to a `.npy` on the read-only shared mount
(`$SHARED_DIR/lora-mimo-captures/captures`) and are selected by `SUITE_GROUPS=capture` (or
`all`), so §3 below is only needed when you want a *different* capture or window. Note the
env var is `SUITE_GROUPS`, not `GROUPS` — bash owns that name.

For a whole-chip check rather than one block, submit the script with no `SUITES` at all:
`SUITE_GROUPS=core` (default) runs every self-contained suite, `SUITE_GROUPS=all` adds the
capture ones. It fails if any `cocotb/<dir>/Makefile` is in neither group, so a newly added
suite cannot go unrun.

Poll to completion per the `hlab-sge` skill (`hqstat --json` or `hqwait`, terminal states
`DONE`/`FAILED`/`CANCELLED`). Prefer `Bash` with `run_in_background: true` running the poll loop
rather than sleeping in the foreground.

### 3. Special-arg suites — measured-capture flows

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

For `packet_ctrl_fsm`, the legacy measured-capture tests named in its mapping row are not
the `cocotb/trouper_capture` suite. Follow
`planning/verification-plan/packet-ctrl-fsm-verification-plan.md` §3 and the existing
legacy runner/environment rather than substituting a bare `trouper_capture` invocation.

### 4. Formal and other non-cocotb targets

Run separately, not part of the pass/fail suite loop — check whether the block's `ifdef FORMAL`
instantiation is actually wired into the RTL before trusting a green result (`psram_buf_ctrl.v`
did not have one as of 2026-07-19; a "pass" with zero assertions wired in is vacuous, not
coverage):

```bash
sby -f formal/<block>_formal.sby
```

Also run every legacy/differential target in the mapping row. In particular,
`packet_ctrl_fsm` is not complete without `tb_pcfsm_b6_equiv.v`. Its runner must require
the explicit `TB: PASS` marker (and reject any `TB: FAIL` marker), not trust process exit
alone; the testbench historically used `$finish` on failure and could otherwise false-green.

### 4b. Long suites — emit progress, and check it correctly

Most suites here finish in seconds; a few run for tens of minutes
(`capture_two_packet` ~14 min, `trouper_capture` sweeps, anything spanning more
than one packet). For those, "is it hung or just slow?" comes up mid-run.

**Checking:** never judge from log size/mtime — job logs are capped at 2 MiB,
and event-driven tests legitimately print nothing for most of their wall-clock
(`capture_two_packet` logged nothing for 11 minutes and then passed). See the
`sge-job` skill for the full checking convention and the `hqdel`-as-read-only-
probe trick.

**Instrumenting:** a long cocotb sim usually has no incremental artifact at all,
so add one. Heartbeat on **simulation-time milestones**, not wall-clock, and
include a quantity that comes from the DUT:

```python
# ~10 lines total regardless of runtime; bounded so the 2 MiB log cap can
# never swallow the verdict at the end.
next_mark = 0.0
...
    t_ns = cocotb.utils.get_sim_time("ns")
    if t_ns >= next_mark:
        dut._log.info(f"{tag}: {t_ns/1e6:.0f} ms / {total_ns/1e6:.0f} ms "
                      f"({100*t_ns/total_ns:.0f}%), poll={poll_i}")
        next_mark += total_ns / 10
```

Three rules, each of which failed in practice without it:

1. **Bound the line count** (~10–20 for the whole run). Unbounded progress
   output loses the result to the log cap — the end of the log is where the
   verdict lives.
2. **Include the denominator.** `0.20 s / 2.075 s (10%)` lets a human compute an
   ETA from a single line. Extrapolating an ETA from one early sample is
   unreliable — a 2%-progress reading suggested ~1 h for a run that took 845 s.
3. **Include a DUT-sourced quantity** (poll index, `sample_count`, capture
   position). A wall-clock heartbeat only proves the coroutine is alive, not
   that the simulation advanced.

Do **not** shorten a long window just to speed a suite up without checking what
the elapsed time covers. `capture_two_packet`'s ~4.07 M-sample inter-packet gap
is load-bearing: `dc_removal` settles across it, `psram_buf_ctrl` pointers
advance and wrap, and `sc_detector`'s counters accumulate — the last is where
the double-count bug hid, since its error grew with elapsed samples. Dropping
`--trace` is the legitimate speed-up (845 s vs ~52 min, zero coverage cost).

### 5. Report

Summarize as a table: suite → PASS/FAIL/error, one row per suite in the block's mapping row
(including special, formal, legacy, and differential targets). Cross-check any failure
against the block's `planning/verification-plan/*.md` before concluding it's a regression —
rule out harness/argument mistakes (missing capture params, stale NFS sync) first, the same
way `trouper_capture`'s first two runs against this block turned out to be invocation errors,
not RTL bugs.

## Adding a new block

1. Find every cocotb `Makefile` whose `VERILOG_SOURCES` includes the block's `.v` file:
   `grep -l '<block>.v' cocotb/*/Makefile`. Treat these as candidates, then reconcile them
   against the block's verification-plan requirements; shared full-top source inclusion by
   itself is not enough to make a suite part of the block regression.
2. Check each selected Makefile's header comment / `COCOTB_TEST_MODULES` for required env vars
   (the `trouper_capture` pattern — grep for `os.environ` in the test module `cocotb/tests/test_*.py`
   if unsure) — put those in the "special-arg suites" column, not the plain-`make` column.
3. Check whether `formal/<block>_formal.sv`/`.sby`, a differential testbench, or a legacy
   non-cocotb regression exists; list every selected extra target explicitly.
4. Add a row to the mapping table above and link the block's verification-plan doc if one exists
   under `planning/verification-plan/` (or `planning/` for older ones) — create one first if not,
   per the pattern in `psram-buf-ctrl-verification-plan.md`.
