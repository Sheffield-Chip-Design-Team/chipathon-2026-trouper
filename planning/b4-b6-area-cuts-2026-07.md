# B4 + B6 area cuts — change record (2026-07-18/19)

Implementation + measurement record for area-reduction candidates **B4**
(mrc_combiner weight-latch delete) and **B6** (packet_ctrl_fsm relative
down-counter timeouts), per `area-reduction-roadmap.md` §8. Both live on
unmerged branches pending the merge decision:

| Branch | Worktree | Head |
|---|---|---|
| `b4-mrc-w-latch` | `.claude/worktrees/b4-mrc-w-latch` | `f9ef89f` (B4 `29fbe79` + write-lock `9b275ea` + indexed-write recode) |
| `b6-pcfsm-relative-timeouts` | `.claude/worktrees/b6-pcfsm-relative-timeouts` | `7fb4228` |

Baseline for all comparisons: mainline `9d22bfe` (includes the 2026-07 DSP-review
fixes), `config_current_signoff.json` (1200×1100, density 88 %, plain corners,
v20 SDC), `RUN_2026-07-18_17-02-25`.

## 1. B4 — mrc_combiner per-burst weight-latch delete (+ reg_bank write-lock)

**Change:** deleted the `wr_re/wr_im[0:3]` latches (64 flops + enable muxes) that
re-captured the reg_bank W-shadow at the start of every 8-state MAC burst;
states 1–8 read the `W_re*/W_im*` ports (= `rb_w_shadow`) directly. The `xr_*`
input latches remain (they guard the live/replay source mux, which no protocol
constrains).

**Hazard analysis (review 2026-07-19):** with the latch gone, a 0x30–0x3F write
mid-burst reaches the MAC walk immediately — one output sample could use a torn
complex weight (new `re`, old `im`). Findings from the trace:

- The old latch only ever gave *per-sample snapshot coherence*; it never gave
  atomic weight updates (a 16-byte SPI rewrite spans many samples, so
  progressively-mixed snapshots occurred per-sample even with the latch), and
  `W_COMMIT` never latched data — it only sets `W_valid`.
- The in-protocol late-commit flow is safe without the latch: a W_PENDING
  timeout degrades to **bypass** (`W_valid=0`, there is no old-weights
  fallback — `W_valid` clears at `!packet_active`), the late shadow writes land
  while `W_valid=0`, and the pending commit is applied mid-payload
  (`packet_ctrl_fsm.v` PAYLOAD_ACTIVE pending-apply). The bypass→MRC switch is
  burst-atomic because the combiner samples `use_mrc_r <= W_valid && !mode`
  only at burst state 0.
- The only exposure is a shadow write while `W_valid=1` — out-of-protocol
  (nothing to write: one weight computation per packet), but reachable by
  bring-up register pokes or SPI/GRP dual-master interleaving, silent, and with
  a worst case of a clamped full-scale sample into `sd_remod` (whose >−3 dBFS
  instability is permanent until reset).

**Hardening (chosen over documentation-only and over a commit-latched active
bank):** reg_bank drops 0x30–0x3F writes while `w_valid_rb` is high and latches
the rejection sticky in `WGT_CTRL[5] W_WR_REJECTED` (W1C via `WGT_CTRL` write
with bit 5 set). One shared lock term on a single indexed bank write (see §3
recode note), no flops beyond the flag; stronger
than the deleted latch (also removes the pre-existing per-sample tear).
Register Map 0x1E / 0x30–0x3F sections updated (including removal of the stale
"`W_ACTIVE` separate copy" language — no such copy ever existed).

*Considered and rejected:* keeping old weights on W_PENDING timeout. It would
require a commit-latched active W bank (~64 flops, re-spending most of the cut)
to avoid latching a half-rewritten shadow at the timeout instant, and stale
weights from a different packet's channel can combine destructively — bypass is
the safer degrade. Decision 2026-07-19: bypass stays.

**Verification (all SGE, `lora-mimo-b4` mirror):**
- `cocotb/w_shadow_lock` (new): lock, sticky flag, W1C, re-arm, packet-end
  unlock — PASS (job 3473).
- Full-chip SF7–12 × BW250/125 sweep: 18/18 PASS (jobs 3462 pre-lock, 3474
  post-lock).
- `test_weight_gen_spi_flow` bit-exact vs oracle: PASS (jobs 3462, 3474).

## 2. B6 — packet_ctrl_fsm relative down-counter timeouts

**Change:** replaced the three 32-bit absolute deadline registers
(`acq_timeout_q`, `wpend_timeout_q`, `pkt_end_q`) and their continuous 32-bit
`sample_count >` comparators with down-counters (`acq_cnt[19:0]`,
`wpend_cnt[19:0]`, `pkt_cnt[22:0]`) decremented per captured sample via a new
`iq_tick` input (= `dcr_valid`, wired in `trouper_top`); timeouts fire on
zero. `M_val` shrank 32→15 bits. Loads are one-shot in `ST_ACQ_SETUP`,
preserving the item-39 honest-MCP structure. Round 2 replaced the 32-bit
elapsed subtract in the load path with a 20-bit modular subtract
(`sample_count[19:0] − lat_timing_ref[19:0]`, exact because true elapsed is
structurally ≤ ~2¹⁷) after round 1's carry chain became its own worst SS path.
Bonus: the down-counters are wrap-immune (the old `>` compares mis-time at the
~2.4 h `iq_samp_cnt` wrap).

**Verification:** dual-instance equivalence TB `rtl-test/tb/tb_pcfsm_b6_equiv.v`
(old FSM extracted from main as `packet_ctrl_fsm_ref.v`) — 40 randomized
packets, SF7–12, 4 scenarios including expired-load clamp, **all outputs
bit-identical every clock** incl. timeout-fire edges (jobs 3463, 3471
post-round-2). Full-chip 18/18 sweep, `w_missed`, `replay_delay` 8/8 all PASS.
SDC variant `pnr_32m_scoped_v25_b6.sdc` re-points the timeout-register
exceptions at the new counters (load arc relaxed only; decrement stays MCP=1);
config `config_current_signoff_b6.json`.

## 3. Measured PnR results (1200×1100 / 88 %, plain corners, all DRC 0 / LVS 0)

| Run | Synth area (µm²) | Placed area (µm²) | Δ placed | SS WNS (ns) | SS TNS |
|---|---|---|---|---|---|
| Baseline `RUN_2026-07-18_17-02-25` | 990,966 | 1,062,010 | — | −22.70 | −3,645 |
| B4 (pre-lock) | 982,591 | 1,054,150 | −7.9 K | −13.04 | −4,222 |
| B4 + per-byte lock (job 3475) | 987,736 | 1,058,230 | −3.8 K | −16.23 | −5,210 |
| **B4 + recoded lock (job 3479, final)** | **977,303** | **1,047,910** | **−14.1 K** | −22.79 | −3,351 |
| B6 round 2 | 973,674 | 1,043,230 | −18.8 K | −25.52 | −8,005 |
| B6 + fanout split (job 3481) | 982,512 | 1,053,490 | −8.5 K | −15.95 | −4,650 |
| **COMBINED B4+B6+split (job 3484, `b4-b6-integration` `f2e3ab1`)** | **974,329** | **1,044,720** | **−17.3 K** | **−14.91** | −5,747 |

B4's final form is the *recoded* lock (branch head `f9ef89f`): the first-cut
per-byte `if (!w_valid_rb)` guards cost +5.1 K synth (+397 cells, only 1 a
flop — ABC remapped the 128-flop enable cone). Recoding the shadow bank as a
single indexed write (`w_shadow_r[addr[3:0]]`, one shared lock term) removed
the original 16-way case decode as well, ending up 5.3 K *below* pre-lock B4.
Full re-verification on the recode: `w_shadow_lock` (job 3477), 18/18 sweep +
weight-gen oracle (job 3478), signoff DRC 0 / LVS 0 (job 3479).
Combined B4+B6 stack ≈ **−33 K placed**.

Both cuts **survive to placed area**,
disproving the B2-era "pure flop cuts get reabsorbed at 3.0 V" rule for these
shapes (B4 is flops+muxes, B6 is comparator-cone removal).

## 4. Timing findings from the measurement runs (tracked in Open Risks)

- **WNS deltas above are NOT attributable to the RTL cuts — root-caused
  2026-07-19** by clustering all reported violators (netlist-mapped names)
  across four runs. B6's extra −4.4 K TNS is almost entirely the
  `packet_active → packet_done_pulse → u_psram.{wr_data,rpl_i/q,cur_wr,
  wait_cnt,sub}` cone being left unrepaired in that one run: its worst path
  spends **45 of 60 ns in four under-driven stages** (x1 inverter at fanout
  39 / 15.7 ns slew, nand2_1 at fanout 25, x1 inverter into
  `packet_done_pulse`). The identical cone is buffered to −3…−8 ns in the
  baseline and B4 runs. None of B6's new logic (counters, `iq_tick`, load
  subtract) appears anywhere in its violator list. Mechanism: repair_design
  is DRC-driven, so upsizing depends on caps crossing a threshold at the
  repair corner — B6 deleted ~19 K µm² of pcfsm logic adjacent to the cone,
  the neighborhood re-placed, and the caps landed under threshold. Clincher:
  three runs, three different worst cones, all chronic — baseline
  `rb_sf_cfg → M_val` (−22.7), B6 `packet_active → psram` (−25.5), B4+lock
  `u_remod.s3_i` (−22.8, with its packet_active clusters quiet at −6). At
  88 % util, single-run WNS measures which chronic fanout cone lost the
  repair lottery, not the RTL delta. → Open Risk #40 addendum. Fix direction:
  RTL fanout split of `packet_active`/`packet_done_pulse` (the sc_lock →
  timing_ref pattern, job 3415) and/or max_transition SDC (job 3417 line).
- Baseline worst path `rb_sf_cfg → u_pcfsm.M_val[*]` is an unscoped
  quasi-static arc in the v20 SDC. → Open Risk #39 addendum.
- `config_current_signoff_minff.json` (Open Risk #41 RCX-fix carrier) fails
  GRT-0116 congestion at this density (job 3464); plain max_ff config routes
  clean. → Open Risk #41.

### 4.1 Fanout split RESULT (2026-07-19, b6 commit `3af9619`, jobs 3480/3481)

Implemented on the b6 branch: `(* keep *)` duplicate `packet_active_ps`
(mirrored at all four pcfsm assignment sites, wired only to `u_psram`) +
`packet_done_pulse` registered in `trouper_top` (1-cycle-later pulse; sc_clr /
psram `packet_end` / IRQ all tolerant — proven by equiv TB with a
`packet_active_ps ≡ packet_active` check, 18/18 sweep, w_missed, replay_delay,
job 3480). Signoff `RUN_2026-07-19_17-10-59` (job 3481): **DRC 0 / LVS 0,
SS WNS −15.95 (was −25.52), TNS −4,650 (was −8,005)** — every
`packet_active → u_psram` cluster vanished from the violator list; the worst
clusters are now the chronic `training_armed → Zdiag` / `Zpair` arcs
(−12.6 worst). New small cluster `iq_samp_cnt → u_pcfsm.pkt_cnt` (n=22,
worst −6.65) suggests the v25_b6 SDC load-arc exception partially misses —
follow-up. **Cost:** synth +8.8 K / placed +10.3 K vs B6 round-2 (+374 comb
cells, only +1 flop net — the same ABC remap-churn class as B4's per-byte
lock), so B6+split nets −8.5 K placed vs baseline. Refinement A/B TESTED
(branch `b6-split-pulseonly` `5f534de`, synth job 3482): the pulse-register-only
variant is *worse* — 984,442 µm² / +588 comb cells vs A+B's 982,512 — so the
churn is not the `(* keep *)` duplicate; it is intrinsic ABC remap sensitivity
to any perturbation of this cone (third data point of the class after B4's two
lock codings). A+B stands as the keeper; pulse-only branch retained for the
record, not to be pursued.

### 3.1 Combined integration run (2026-07-19)

Branch `b4-b6-integration` = main + both branches (zero file overlap, clean
ort merges). First netlist with both cuts + the fanout split:
**placed −17.3 K** (vs −22.6 K arithmetic — composition costs ~5 K of remap
churn), **SS WNS −14.91, best full-chip number of the current era**, DRC 0 /
LVS 0, util 82.6 %. `packet_active → u_psram` clusters stay dead; top
violators are the chronic `training_armed → Zdiag`/`Zpair` arcs and the
internal `u_psram.sub/state → rd_data/wr_data` QSPI residual (Open Risk
item 1). The `iq_samp_cnt → u_pcfsm.pkt_cnt` cluster persists (n=22, worst
−9.61) — v25_b6 SDC load-arc exception partial miss, open follow-up.
Functional gate: all 6 suites PASS on the merged RTL (jobs 3483/3485 — equiv
TB, 18/18 sweep, w_shadow_lock, w_missed, replay_delay 8/8, weight-gen
oracle bit-exact).

## 5. State / next steps

- Combined branch verified + measured; **merge to main not yet performed** —
  user decision open.
- If `packet_ctrl_fsm` port lists change again, `tb_pcfsm_b6_equiv.v` +
  `packet_ctrl_fsm_ref.v` need the same edit in both instances.
- Per-branch NFS mirrors (`lora-mimo-b4/`, `-b6/`, `-base/`) dodge the shared
  worktree sync race — reuse the pattern.
