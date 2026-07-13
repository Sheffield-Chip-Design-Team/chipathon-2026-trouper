# CE-gated quasi-static retimer experiment (Open Risk #40 follow-up)

**Status: base result CONFIRMED (job 3371) AND extension CONFIRMED (job
3400), both DRC=0/LVS=0 clean. RECOMMENDATION DOWNGRADED 2026-07-13** after
porting the item-39 write-arc fix (job 3406) — root-caused below to a real
finding, not flow noise: this branch's own extra RTL (six retimed `_q`
registers + free-running `ce_8m` divider) measurably degrades unrelated paths
(`training_armed`, `u_remod`'s internal NTF arithmetic) beyond what mainline
pays for the same fix, and overall WNS (−17.97 ns) is now worse than
mainline's post-fix number (−12.11 ns, job 3404). Do not merge pending a
fix or re-evaluation of that cost — see "Item 39 write-arc fix ported"
below for the full root-cause. Branch: `worktree-ce-gated-quasi-static-retimer`
(worktree `ce-gated-quasi-static-retimer`). Isolated NFS staging at
`/srv/eda/designs/timothyjabez/lora-mimo-ce-retimer/` (kept separate from the
main `lora-mimo/` mirror to avoid the NFS sync race — see
`project_nfs_sync_worktree_race` precedent).

## Item 39 write-arc fix ported (2026-07-13, jobs 3405–3406)

Mainline fixed Open Risk #39's `timing_ref → acq_timeout_q` write-arc
dishonesty (see `planning/Open Risks.md` #39: `packet_ctrl_fsm.v` now has a
dedicated `ST_ACQ_SETUP` state, jobs 3402–3404, SS WNS −12.11 ns on the
mainline config). This branch had NOT been touched by that fix — its own
retiming work only consolidates `rb_*` config sources and never touched the
`timing_ref`-itself write arc. Ported the identical RTL change plus two SDC
exceptions: the new honest `lat_timing_ref → $pcfsm_timeout_regs` relaxation,
and one this branch was ALSO independently missing — `u_pcfsm.M_val`'s own Q
output driving OUT into the timeout registers (this branch's existing
`pcfsm_mval_reg` block only relaxed the WRITE *into* M_val from the retimed
`rb_*_q` sources, not M_val's own fan-out).

**Functional verification (job 3405):** full 12-suite regression + 18-test
SF/BW sweep + directed two-packet re-arm, all PASS, rc=0. Re-arm cycle counts
(PK1-1/ARM-1/ARM-1b/PK2-1) identical to mainline's job 3402, confirming the
port didn't change behavior on this branch either.

**P&R signoff (job 3406, `RUN_2026-07-13_15-25-20`):** DRC=0/LVS=0 clean.
Confirmed the port itself worked exactly as intended — cross-checked the
final netlist and neither `u_pcfsm.acq_timeout_q[30]`/`[31]` nor any
`u_pcfsm.M_val` endpoint appears anywhere in the violator list (0 hits) — but
**overall SS WNS is −17.97 ns**, worse than this branch's own prior best
(−14.71 ns, job 3400) and worse than mainline's post-fix −12.11 ns (job 3404).
Traced the new worst paths: `training_armed → (u_remod internal net)`
(−17.97 ns) and `rb_psram_ctrl[3] → (anonymized net)` (−14.09 ns) — 285
combined violators. **Neither traces anywhere near packet_ctrl_fsm or the
ported fix.** Both are quasi-static-shaped sources (`training_armed` is a
control flag, `rb_psram_ctrl` is a reg_bank config register) that are outside
this branch's 6-source retimed bus (`rb_sf_cfg_q`/`rb_sample_shift_q`/
`rb_bw_sel_q`/`rb_sc_hits_req_q`/`rb_pkt_timeout_syms_q`/
`rb_tacc_window_syms_q`) and outside mainline's v21–v24 scoping too — an
apparently pre-existing gap that this specific P&R run surfaced, most likely
because relaxing the two new pcfsm cones changed where OpenROAD's
timing-driven repair passes spent their (finite) buffering/sizing budget,
not because the ported RTL/SDC change itself broke anything.

**Root-caused 2026-07-13.** Parsed the full violator lists of both runs and
grouped by startpoint instance (not just eyeballing the top few lines), then
cross-checked each cluster's magnitude against job 3400 (this branch, before
the port) AND mainline job 3404 (after the port, different branch). Findings:

| Cluster (startpoint) | job 3400 (this branch, pre-port) | job 3406 (this branch, post-port) | mainline job 3404 |
|---|---|---|---|
| `training_armed` (training_acc's `armed` reg) | 362 violators, worst −9.58 ns | 276 violators, worst **−13.72 ns** | 109 violators, worst −3.01 ns |
| `u_remod` internal (`s3_i[1]`→NTF chain, sd_remod) | present, worst ≈−8.14 ns (`s3_i[1]→s3_i[2]`) | 17-20 violators, worst **−17.97 ns** (`s3_i[1]→q_i`) | 16 violators, worst −7.59 ns |
| `u_psram` (item 1's residual: `psram_qe_init_done`/`u_psram.sub`) | worst-overall, **−14.71 ns** | 29 violators, worst only **−6.08 ns** | separate residual, not compared here |

Both `training_armed` and the `u_remod` cone **pre-date the port** — they were
already present in job 3400, at smaller (but still real) magnitude, simply
masked because `u_psram` was the overall worst path at the time. The port
didn't create them. But three things did change between job 3400 and 3406:
`training_armed` and `u_remod` both got measurably *worse* (−9.58→−13.72 ns,
−8.14→−17.97 ns), while `u_psram` — a residual completely unrelated to the
ported fix — got dramatically *better* (−14.71→−6.08 ns). That's the
signature of the physical optimizer's finite iterative repair budget
(buffering/sizing/legalization passes) being reallocated once the two pcfsm
cones stopped competing for it: `u_psram` benefited, `training_armed`/`u_remod`
did not. This is emergent P&R behavior, not a bug in the ported RTL/SDC change
— the same whack-a-mole class of finding this file's own SDC history
documents repeatedly, just at the physical-implementation layer instead of
the SDC-scoping layer.

Separately, comparing this branch to mainline shows `training_armed` and
`u_remod` are **both substantially worse on this branch than on mainline**,
even before the port (109/−3.01 ns and 16/−7.59 ns on mainline vs.
362/−9.58 ns and (comparable count)/−8.14 ns on this branch already in job
3400). That points at the CE-retimer's own extra RTL (six retimed `_q`
registers + the free-running `ce_8m` divider, fanning out to seven consumers)
adding enough local congestion/routing pressure to measurably degrade
*unrelated* paths elsewhere in the design — consistent with the already-noted
Yosys synthesis resource cost (peak 237%/2.1 GiB vs 138%/1.2 GiB), just
showing up as a physical-implementation cost too, not only a compile-time one.

**What `training_armed` and `u_remod` actually are, for any future fix:**
- `training_armed` (`training_acc.v`'s `armed` register) is a genuinely LIVE,
  packet-rate control-flow flag (set on `sc_lock`/`noise_trig_rise`, cleared at
  packet/noise-window end) — NOT a host-rate quasi-static config value like
  the six `reg_bank` sources this retimer already handles. It cannot be given
  the same fix without its own justification (if one exists).
- The `u_remod` cone is `sd_remod`'s own internal 3rd-order NTF integrator
  arithmetic (`s1_i`/`s2_i`/`s3_i` → `q_i`, ~17 gate levels of combinational
  logic per the netlist trace). `u_remod` was never added to the `paced_nets`
  wildcard (only `u_dec.*`/`u_sc.*`/`u_tacc.*`/`u_comb.*` are), so it has
  always run honest single-cycle — this is a real, uncharacterized
  computation-depth problem in the re-modulator itself, unrelated to any
  reg_bank source.

**Conclusion:** the item-39 port is correct and should stay — it demonstrably
helped `u_psram` too. But this branch's overall recommendation (adopt over
per-consumer SDC patching) needs revisiting: on this specific die/density,
its own extra RTL now measurably costs more in physical margin on unrelated
paths than mainline pays, and the resulting overall WNS (−17.97 ns) is worse
than mainline's post-fix number (−12.11 ns). `training_armed` and `u_remod`
are new items for a future root-cause/fix pass — out of scope for both item 39
and this retimer experiment as originally scoped.

## Extension CLOSED (2026-07-13, jobs 3387–3400)

Implemented the two follow-ups identified after the base result: folded
`rb_sc_hits_req`, `rb_pkt_timeout_syms`, `rb_tacc_window_syms` into the same
`ce_8m`-gated retimed bus (`rb_sc_hits_req_q`/`rb_pkt_timeout_syms_q`/
`rb_tacc_window_syms_q`), rewired their three consumers
(`sc_detector.sc_hits_req`, `training_acc.tacc_window_syms`,
`packet_ctrl_fsm.pkt_timeout_syms`/`.tacc_window_syms`), and added an
explicit `u_pcfsm.M_val` SDC endpoint (the cone that broke v23 on the
mainline, job 3370) instead of relying on it being implicitly covered by a
wider source set.

**Caught and fixed during implementation:** the automated port-rewire
regex initially also repointed `reg_bank`'s own OUTPUT port connections
(`.sc_hits_req(rb_sc_hits_req_q)` etc.) to the retimed `reg`-typed nets —
illegal (a module output port cannot drive something declared `reg` outside
the module) and would have been a hard synthesis error. Caught by manual
review before any job was submitted; reg_bank's instantiation is correctly
back on the raw `wire` nets (only the four real *consumers* read the `_q`
copies).

**Verified (2026-07-13, jobs 3387–3400):**

- Job 3387 (cocotb SF7–SF12 × BW250/125 + startup sweep, post-extension):
  18/18 PASS.
- Jobs 3388–3399 (the same 12-suite functional regression as the base
  result: `sc_force_lock`, `sc_dbg`, `sc_ant_sel`, `w_missed`,
  `replay_delay`, `psram_ops`, `reg_reset_sweep`, `bypass_e2e`, `qspi_owner`,
  `spi_cdc`, `noise_trig`, two-packet re-arm): all exit 0 / all-PASS.
- Job 3400 (P&R signoff, `ol_trouper_top/runs/RUN_2026-07-13_01-57-28`):
  **DRC = 0** (`magic__drc_error__count: 0`, `route__drc_errors: 0` after the
  usual multi-iteration repair convergence), **LVS = 0** (all
  `lvs_*_difference`/`error`/`unmatched` counts zero), **post-PNR SS WNS =
  −14.71 ns** — better than every prior number in this experiment (base
  retimer −16.07 ns / job 3371; SDC-only v22 −16.60 ns; SDC-only v23
  −17.16 ns; original unfixed baseline −16.01 ns / job 3367). Worst path
  startpoint traces to `psram_qe_init_done` — the same already-characterized
  `u_psram` QSPI-decode residual (item 1), not a freshly-exposed cone, same
  conclusion as job 3371, now holding with the extended `rb_sc_hits_req`/
  `rb_pkt_timeout_syms`/`rb_tacc_window_syms` retiming and the explicit
  `M_val` endpoint folded in.

The extension didn't just hold the base result — it improved WNS by ~1.4 ns
and closed out the last known gaps (the `M_val` cone that broke v23, plus the
three extra `reg_bank` sources) with no functional regression.

## Result (2026-07-13, jobs 3370, 3371, 3400)

| Job | Approach | SS WNS | Worst path |
|---|---|---|---|
| 3367 | baseline (pre-fix) | −16.01 ns | `packet_active → u_sc.acc_ci0` |
| 3368 | v22 (2 cones fixed) | −16.60 ns | `rb_bw_sel → u_sc.timing_ref[31]` (newly exposed) |
| 3370 | v23 SDC-only (closes timing_ref) | **−17.16 ns** | `rb_sf_cfg → u_pcfsm.M_val[15]` — **new cone, never before traced**: `packet_ctrl_fsm.v:46-49` has its own redundant `M_val` register, separate from `sc_detector`'s, never covered by any prior scoping |
| 3371 | CE-retimer (div-4), base (`rb_sf_cfg`/`rb_bw_sel`/`rb_sample_shift` only) | −16.07 ns | `u_psram.sub[3] → ...` — the **pre-existing, already-characterized** item-1 QSPI residual, not a new miss |
| 3400 | CE-retimer (div-4), extended (+ `rb_sc_hits_req`/`rb_pkt_timeout_syms`/`rb_tacc_window_syms` + explicit `M_val` endpoint) | **−14.71 ns** | `psram_qe_init_done → ...` — same **pre-existing, already-characterized** item-1 QSPI residual, still not a new miss |

**The CE-retimer wins.** Pure per-consumer SDC patching (v23) kept the
whack-a-mole pattern going — closing one cone unmasked another nobody had
looked at. The retimer, by consolidating the source once, absorbed that
entire class of violator (including the `M_val` register that just broke
v23 — `packet_ctrl_fsm` in this branch reads the retimed `rb_sf_cfg_q`, so
its `M_val` register got the same relaxation for free) and landed back at
the one remaining, already-understood problem (`u_psram`) instead of
surfacing a fresh unscoped cone.

**Confirmed:** job 3371 finished (elapsed 00:31:14) DRC=0/LVS=0 clean — all
LVS device/net/property/pin difference counts zero, `magic__drc_error__count:
0`, `route__drc_errors: 0` after the usual multi-iteration repair
convergence. Same signoff bar as every other run this session. The
recommendation to adopt is no longer provisional.

## Problem

Open Risk #40's violator breakdown (job 3367, see `Open Risks.md` #40) showed
`rb_sf_cfg`/`rb_bw_sel` fanning into three separate consumers
(`packet_ctrl_fsm`, `training_acc`, `sc_detector`'s eval engine), each with
its own hand-scoped SDC `set_multicycle_path -through`/`-to` exception. Every
round of fixing this file (v20→v21→v22→v23) found one more consumer that had
been missed — the same source, re-derived as "quasi-static, safe to relax"
three-plus separate times, each a fresh opportunity for the wildcard-miss bug
class that dominates this SDC's history.

## Approach

Instead of re-deriving "this is quasi-static" per consumer in SDC, re-register
`rb_sf_cfg`/`rb_bw_sel`/`rb_sample_shift` **once**, in RTL
(`src/top/trouper_top.v`), through a clock-enable, producing
`rb_sf_cfg_q`/`rb_bw_sel_q`/`rb_sample_shift_q`. Every real consumer
(`sc_detector`, `training_acc`, `packet_ctrl_fsm`, `psram_buf_ctrl`) reads the
retimed copy instead of the raw combinational `reg_bank` output. This gives
one shared, guaranteed-to-survive-synthesis register net (flop Q outputs
never get optimized away, unlike arbitrary combinational wires) instead of
three fragile per-consumer wildcard matches.

### First attempt: reused `ce_16m` — no timing benefit, kept for the finding

The first version gated the retimer on `ce_16m`, the same 16 MHz
clock-enable `reg_bank` already uses for its own internal write path.
**Result: no WNS improvement.** Root cause: `reg_bank.v`'s own registers
(`sf_cfg`, `bw_sel`) are *already* gated by `clk_en = ce_16m` internally — so
re-registering an already-`ce_16m`-gated signal through the same `ce_16m`
just adds a redundant pipeline stage with the identical update cadence. No
new settling margin, just one extra cycle of latency for nothing. This is a
real negative finding, not a dead end to hide — it's why the div-4 rework
below exists.

### Current version: independent div-4 enable

```verilog
reg [1:0] div4_cnt;
always @(posedge clk or negedge rst_n)
    if (!rst_n) div4_cnt <= 2'd0;
    else        div4_cnt <= div4_cnt + 2'd1;
wire ce_8m = (div4_cnt == 2'd0);   // pulses once every 4 IQ_CLK cycles
```

`rb_sf_cfg_q`/`rb_bw_sel_q`/`rb_sample_shift_q` now update on `ce_8m` — a
free-running counter, **not** phase-locked to `ce_16m` — giving genuine
4-cycle stability, strictly more than the raw signals' native 2-cycle
cadence. The corresponding SDC (`src/config/pnr_32m_scoped_v20.sdc` in this
branch) mirrors the mainline v21/v22/v23 cone-scoping but points every
`rb_sf_cfg*`/`rb_sample_shift*`/`rb_bw_sel*` source at the retimed `_q` nets
instead. The `packet_active`/`packet_done_pulse` sc_clr sources are
unchanged (raw nets — genuinely live, not quasi-static, not part of this
retimer). `rb_pkt_timeout_syms`/`rb_tacc_window_syms`/`rb_sc_hits_req` were
initially unchanged too, but the 2026-07-13 extension (jobs 3388–3400) folded
them into the same `ce_8m`-gated bus — see "Extension CLOSED" above.

## What's confirmed so far (functional only, not timing)

- Job 3369 (`ce_16m` version): cocotb SF7–SF12 × BW250/125 + startup sweep,
  18/18 PASS.
- Job 3372 (div-4 rework): same sweep, 18/18 PASS again after the enable
  change.
- Jobs 3373–3386 (broader regression: `sc_force_lock`, `sc_dbg`,
  `sc_ant_sel`, `w_missed`, `replay_delay`, `psram_ops`, `reg_reset_sweep`,
  `bypass_e2e`, `qspi_owner`, `spi_cdc`, `noise_trig`, two-packet re-arm):
  all PASS. One initial failure (job 3384, two-packet) was an NFS sync gap
  (`fpga-emul/rtl/psram_model.v` never copied to the isolated staging dir),
  not an RTL defect — fixed, resubmitted as job 3386, passed.

None of the above proves the retimer closes timing — only that it doesn't
break function.

## Remaining before merge

- **Cost consideration:** the CE-retimer branch's Yosys synthesis ran
  measurably hotter than the SDC-only branch (peak ~237% CPU / 2.1 GiB vs
  ~138% CPU / 1.2 GiB, both jobs also ran longer than the ~25 min baseline)
  — extra RTL (now 6 retimed regs + a free-running div-4 counter, fanning
  out to 7 consumers after the extension) has a real signoff-iteration-time
  cost, not just an area one. Worth factoring in if this becomes the
  standing approach. Not re-measured post-extension (job 3400 elapsed time
  not yet compared against 3371's baseline).
- ~~Extend to the other quasi-static `reg_bank` sources
  (`rb_pkt_timeout_syms`, `rb_tacc_window_syms`, `rb_sc_hits_req`)~~ — DONE,
  job 3400.
- ~~`u_pcfsm.M_val` not itself explicitly scoped~~ — DONE, explicit SDC
  endpoint added and verified in job 3400.

## What this does NOT address (out of scope for this experiment)

- **`u_psram` QSPI decode** (273 violators, the largest cluster) —
  throughput-bound, not a stale-config problem; needs a real pipeline of the
  live `state`/`sub` → `sio_out`/address cone (item 1's original,
  still-unimplemented fix). Retiming would not help here.
- **`Zpair_i`/`Zpair_q`** (135 violators, `training_acc`) — these are live
  per-sample accumulators, not quasi-static config; if they're violating
  it's more likely a pacing/wildcard-miss bug inside `training_acc`'s own
  MAC structure, same class as the decimator/`u_comb` fixes, not something
  a slow source-retimer can fix.
- **`ce_16m`, `dcr_valid`** (64 + 26 violators) — unrooted; no investigation
  done yet on whether these fit this pattern.

## See also

- `planning/Open Risks.md` #40 (violator breakdown table, netlist trace of
  the worst path).
- `src/config/pnr_32m_scoped_v20.sdc` (mainline v21–v23 headers, main
  worktree) — the pure-SDC-scoping alternative this experiment is being
  measured against.
