# B4 + B6 area cuts — change record (2026-07-18/19)

Implementation + measurement record for area-reduction candidates **B4**
(mrc_combiner weight-latch delete) and **B6** (packet_ctrl_fsm relative
down-counter timeouts), per `area-reduction-roadmap.md` §8. Both live on
unmerged branches pending the merge decision:

| Branch | Worktree | Head |
|---|---|---|
| `b4-mrc-w-latch` | `.claude/worktrees/b4-mrc-w-latch` | `9b275ea` (B4 `29fbe79` + write-lock hardening) |
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
with bit 5 set). ~16 gated write-enables, no flops beyond the flag; stronger
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
| B4 (pre-lock) | 982,591 | 1,054,150 | **−7.9 K** | −13.04 | −4,222 |
| B4 + write-lock (job 3475) | *pending* | *pending* | | | |
| B6 round 2 | 973,674 | 1,043,230 | **−18.8 K** | −25.52 | −8,005 |

Combined ≈ −27 K placed if both merge. Both cuts **survive to placed area**,
disproving the B2-era "pure flop cuts get reabsorbed at 3.0 V" rule for these
shapes (B4 is flops+muxes, B6 is comparator-cone removal).

## 4. Timing findings from the measurement runs (tracked in Open Risks)

- **WNS deltas above are NOT attributable to the RTL cuts.** Worst paths are
  pre-existing quasi-static arcs; the same `packet_active → u_psram.sub[*]`
  arc swings −13.0 → −25.5 ns between runs (±6–12 ns repair-effort-allocation
  noise at 88 % util). → Open Risk #40 addendum.
- Baseline worst path `rb_sf_cfg → u_pcfsm.M_val[*]` is an unscoped
  quasi-static arc in the v20 SDC. → Open Risk #39 addendum.
- `config_current_signoff_minff.json` (Open Risk #41 RCX-fix carrier) fails
  GRT-0116 congestion at this density (job 3464); plain max_ff config routes
  clean. → Open Risk #41.

## 5. State / next steps

- Both branches verified + measured, **unmerged** — merge decision open
  (options: merge both; B4 only; more PnR seeds first).
- If `packet_ctrl_fsm` port lists change again, `tb_pcfsm_b6_equiv.v` +
  `packet_ctrl_fsm_ref.v` need the same edit in both instances.
- Per-branch NFS mirrors (`lora-mimo-b4/`, `-b6/`, `-base/`) dodge the shared
  worktree sync race — reuse the pattern.
