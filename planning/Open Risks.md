# Open Risks

Project-wide register of known open risks — design, verification, and
signoff gaps — ranked low to critical. This is an index: each entry is one
or two lines plus a pointer to the document that has the real detail.
Update in place as items close (move to a "Closed" section with the closing
evidence, don't delete) or as new ones are found.

**Priority key**

| Priority | Meaning |
|---|---|
| Critical | Blocks tapeout signoff as currently scoped |
| High | Does not block tapeout mechanically, but a real functional/yield/deployment failure mode if not addressed |
| Moderate | Affects a non-critical feature, a margin, or a documented-vs-verified mismatch; tapeout can proceed without it |
| Low | Tooling, documentation, or future-feature gap |
| Deferred | Accepted limitation with a known fix that is explicitly not being pursued; re-opened only when its stated trigger is met |

---

## Critical

### 1. Chip-wide SS-corner (32 MHz, `max_ss_125C_3v00`) closure is not on production RTL

The `gf180mcu_fd_sc_mcu7t5v0` FD cells fail 32 MHz timing at the slow corner.
The current production RTL has an SS setup WNS in the **−12 to −18 ns** band
(best **−12.11 ns**, jobs 3403/3404; 2026-07-25 runs **−14.91 ns**,
TNS −5747 ns; **latest, and the number to quote: −17.74 ns / TNS −416.9 ns**,
job 5279 on the A40 1675×1110 die with the debug pins — see the 2026-08-30
update below). The decimator's
share of that has been honestly closed (pure 3-cycle pacing + fanout fix, SS
WNS **+8.0 ns MET**, SGE job 2149), and sc_detector/training_acc have paced
fixes too. **Correction 2026-07-12: `ss-mcp-pacing` IS merged into `main`**
(`git log main..ss-mcp-pacing` is empty; the decimator 3-cycle HB pacing,
sc_detector's MCP=3 budget, and training_acc's dual-multiplier 16-step walk
are all present in current `src/`) — the previous "lives on a branch, not
merged" framing was stale. This does not close item 1: the same SS gap this
entry is about is exactly what items 39/40 are still chasing on the *merged*
RTL (cone-scoping + the newly-found `sc_detector`/`packet_active` wall).
The one remaining genuine (non-paceable) residual, the `u_psram` QSPI control
decode (≈ −10 to −13 ns, throughput-bound — needs a 1-cycle-ahead pipeline of
the `state`/`sub` → `sio_out`/address cone), is analyzed but not implemented.
The QSPI-pipeline verification contract (transaction equivalence after the
one-`sck` displacement, handover/pad safety, sustained no-skip, and replay
ordering) is defined in `ss-corner-decimator-pacing-closure.md` under "The
genuine residual: `u_psram` QSPI engine"; it is required before this path can
be treated as fixed.
~~The config-relaxed netlist needed to carry this fix currently **fails
detailed routing** (DRT-1231 / DRT-0073) on every floorplan tried — the
current floorplan has no routability headroom to absorb the SDC change.~~
**Superseded 2026-08-30:** that routing blocker was root-caused and fixed —
diodes were stealing pin access from the `IQ_CLK` clock buffers, and
`DIODE_PADDING: 4` clears it (item 6, item 51). Jobs 5214 and 5279 both route
to 0 antenna / 0 DRC / clean LVS on the A40 die, so routability no longer
gates carrying an SDC change; the remaining obstacle is the timing gap itself.

**2026-08-30 update — debug-pin P&R (job 5279): SS WNS −17.74 ns / TNS −416.9 ns.**
First full A40 P&R carrying the two-pin digital debug probes plus `ARRAY_ACQ_N`
(`src/config/trouper_top_dbgpins.json` — since collapsed into the canonical
`src/config/trouper_top.json`, 2026-09-01 — = the job-5214 signoff config with
the floorplan template extended for the three pads the integrator DEF predates; the
antenna-closure recipe — `DIODE_PADDING: 4`, `DPL_CELL_PADDING: 2`, mixed GRT/DRT
repair, 65 % density — carried through unchanged so the two are directly
comparable). Everything except SS setup is clean:

| metric | 5214 baseline | **5279 (+ debug pins)** |
|---|---|---|
| SS setup WNS (`max_ss_125C_3v00`) | −16.26 ns | **−17.74 ns** |
| SS setup TNS | −379.5 ns | **−416.9 ns** |
| setup, `nom_tt` / `max_ff` | met | met (WNS 0 / TNS 0) |
| hold WNS, all three corners | 0 | 0 |
| antenna | 0 net / 0 pin | 0 net / 0 pin |
| magic DRC / XOR / LVS | 0 / 0 / clean | 0 / 0 / clean |
| max slew / max cap violations | — | 0 / 0 (all corners) |
| die / utilisation | 1675×1110 / 65.0 % | 1675×1110 / 66.1 % |

**The debug pins cost ≈1.5 ns of SS setup margin (−1.48 ns WNS, −37.4 ns TNS)
for +1.1 pt utilisation, and cost nothing in DRC, LVS, antenna, hold, or DRV.**
That is the honest price of the observability feature — small against a gap of
this size, but it moves the wrong way and should be re-checked if the SS residual
is ever driven close to zero. Note this is the SS figure on the **A40 1675×1110
die**, not comparable with the −12.45 ns below (job 5122, the older 1650×1100
`config_1650x1100_full_rect` floorplan).

A companion run, **job 5276**, carried the *same* RTL (identical `VERILOG_FILES`,
so it too has both the array-sync and the debug pads) from the `rtl-test/` config
at **72 %** density rather than 65 %. It never completed — the flow stops at step
54/78 (`OpenROAD.FillInsertion`) with an empty `error.log` and no `final/`, so it
has no STA, DRC, LVS or antenna results and **must not be quoted**. Job 5279 is
the only finished run of this feature set.

**Run:** `/srv/eda/runs/timothyn-dev/lora-mimo-dbgpnr/5279/dbgpins/run`;
log `/srv/eda/logs/timothyn-dev/job-5279.o`. **See:**
`planning/two-pin-digital-debug-plan.md` (P&R review obligations).

**2026-08-27 update — current signoff SS WNS is −12.45 ns / TNS −897 ns**
(job 5122, `config_1650x1100_full_rect`), after the DRV closure (job 5105,
commit `b75fed9`) and three signoff-only MCP scope-miss fixes (v28–v30,
commit `4bf56f3`, see item 43). Those groups only correct dishonest
single-cycle reporting — no physical change, netlist byte-identical to job
5105. The residual is now cleanly characterized in `final/README.md`: ~140
paths are the genuine voltage-bound paced-DSP floor (mostly `u_remod`
OSR=64 MAC, needs ~4.5 V core — item 27 / item 44), the rest are
quasi-static cones left as documented waivers. This does not close the
item: 3.0 V SS still fails, and the honest-MCP obligation (item 43) is not
fully met. **Amended 2026-08-30:** the "needs ~4.5 V core" escape in that
sentence is no longer available — items 27 and 44 are closed as a decision:
no split rail and no 4.5 V core. Both rails stay tied, and the only voltage
lever left is raising **both together to ~3.5 V**, whose benefit is
uncharacterized (the measured points are 3.0 V → −12.11 ns and 4.5 V →
+1.96 ns on the same netlist; nothing has been run at 3.5 V). This item must
therefore close on honest RTL/SDC work plus at most a uniform ~3.5 V bump.

**Open action (documented, not scheduled):** characterise the uniform ~3.5 V
point. It is the only voltage lever the closed rail decision leaves, and it has
never been measured — the two known points are 3.0 V → −12.11 ns and 4.5 V →
+1.96 ns on the same netlist, so how much of that ~14 ns swing 3.5 V actually
buys is unknown. The cheap form is a re-time of an existing routed netlist +
SPEF at a 3.5 V corner (the harness used for the 2026-08-14 honest-SDC probe,
`rtl-test/ol_trouper_top/honest_sta.tcl`), not a new P&R. Until that number
exists, no closure plan for this item should assume voltage contributes
anything.

**Blocks:** any honest chip-wide SS signoff; die-shrink work (was blocked on
routability — that half is retired, see the strike-through above).

Re-confirmed 2026-07-05 on the current 1200×1100 signoff run
(`RUN_2026-07-05_00-56-34`, DRC=0/LVS=0): the same as-routed netlist meets
timing outright at both a realistic-silicon corner (`tt_025C_5v00`: +9.10 ns)
and a less-pessimistic SS point (`ss_n40C_4v50`: +3.28 ns), with zero
re-optimization — no SS corner at 25 °C is characterized in this PDK to check
directly. This is a corner-*policy* question (how much margin above
"realistic operating window" tapeout should require), not a fix — the
official `ss_125C_3v00` signoff number (−25.39 ns at this die size) still
stands as the blocking metric until that policy is decided.

2026-07-12 update: on the latest v20 runs the worst SS paths are **not**
`u_psram` but three quasi-static `rb_*` cones the scoped SDC's `-through`
wildcards miss (worst: `rb_sf_cfg → u_pcfsm.pkt_end_q`, −20.4 ns) — see
item 39 for the breakdown and the v21 fix plan.

**2026-07-13 re-confirmation on the item-39-fixed netlist (job 3407):**
post-hoc OpenSTA reload of the job 3404 routed netlist (mainline, item 39's
`packet_ctrl_fsm` write-arc fix + `M_val` cone, `config_current_signoff.json`,
1200×1100/87.09% achieved util) — same netlist/SPEF/SDC, only the liberty
corner swapped `ss_125C_3v00` → `ss_125C_4v50`: worst slack **−12.11 ns →
+1.96 ns**, **TNS 0**. Zero re-optimization. Same voltage-closes-it result as
the 2026-07-05 confirmation and the item-27 SS@4.5V precedent (+1.40 ns,
jobs 3231/3237), now reproduced on top of the item-39 fix specifically — the
honest single-cycle fixes and the voltage lever are independent and additive,
not alternatives. Per the roadmap's established caveat (`area-reduction-
roadmap.md`), this is a **reload**, not a full re-PnR *targeting* 4.5V — a
real 4.5V-targeted signoff needs a setup-slack margin fed to the resizer or
it under-drives (job 3235 landed −8.31 ns on a bare corner swap vs. the
reload's +1.17 ns on the older B1 netlist); the reload only proves the
design is closeable at 4.5V, not that a naive 4.5V P&R run will land there
for free. `ss_125C_5v00` is not a characterized liberty corner in this PDK
(only 1.62V/3.0V/4.5V exist for SS at both 125°C and −40°C).

**2026-07-31 — first real 4.5 V-targeted full P&R closes clean (not a reload):**
on the current signoff baseline (job 3733, `ss_125C_3v00` WNS −18.18 ns), a
bare `ss_125C_4v50` corner-swap P&R (job 3737) still fails at −2.74 ns, but
adding a 9 ns `PL/GRT_RESIZER_SETUP_SLACK_MARGIN` (job 3738) produces a clean
full signoff: WNS 0.0/TNS 0 at all three `STA_CORNERS`, worst slack +3.17 ns
at `ss_125C_4v50`, DRC 0, LVS clean, same 1200×1100 die/84.9% util. First
time the "9 ns margin recovers the bare-swap under-drive" pattern has been
reproduced on the current die/SDC baseline rather than an older one. Hold at
`ff_n40C_3v60` is positive but tight (+0.164 ns) and not yet separately
re-checked. Still a corner-policy decision, not a closed risk. See
`planning/5v-core-voltage-strategy.md` §2026-07-31.

**2026-08-14 — voltage does NOT substitute for the MCP exceptions (job 4349).**
The 4.5 V closure (job 3738) was always measured with the scoped MCP SDC; the
obvious follow-up question — does 4.5 V close *honestly* — had never been asked.
Answered by reloading 3738's own routed netlist + SPEF and re-timing it under an
MCP-free SDC derived from `pnr_32m_scoped_v25_b6.sdc` (22 `set_multicycle_path`
statements withdrawn, async/debug false paths and all clock/IO constraints kept
— `rtl-test/scripts/gen_honest_sdc.py`, `rtl-test/ol_trouper_top/honest_sta.tcl`):

| SDC | `max_ss_125C_4v50` setup WNS | TNS | hold WNS |
|---|---|---|---|
| scoped v25_b6 (control) | **+3.174 ns** | 0 | +0.962 ns |
| MCP-free (honest) | **−22.84 ns** | −5922 ns | +0.962 ns |

The control reproduces job 3738's recorded +3.17 ns exactly, so the harness is
faithful. **Conclusion: raising the core rail does not retire the multicycle
exceptions — it is additive to them, not a replacement.** Item 43's remaining
settling proofs are therefore unavoidable on every path, 3.0 V or 4.5 V.
Withdrawing the MCP *hold* exceptions changed no hold slack (+0.962 ns
unchanged at ss, +0.162 ns at ff), so nothing was being hidden on that side.

Usefully, the honest violations land almost entirely inside the cones the
exceptions already cover — worst two, traced through the netlist:
`rb_sf_cfg[2] → u_pcfsm.acq_cnt[4]` at −22.84 ns (the `pcfsm_quasi_static` /
`pcfsm_mval` groups) and `u_dec.hb1_stream[0] → u_dec.hb1_hold_i[3][2]` at
−22.13 ns (`paced_dsp`, whose settling proof is already closed). That is
evidence the exceptions are load-bearing and correctly targeted rather than
papering over unrelated debt.

**See:** `planning/ss-corner-decimator-pacing-closure.md` (Open Items),
`planning/5v-core-voltage-strategy.md` (§2026-07-05 re-confirmation,
§2026-07-31 full-P&R closure),
`planning/area-reduction-roadmap.md` (§"RAISE SS ONLY" voltage probe).

(Items 2 and 3 — `sc_lock` one-shot and un-clearable `IRQ_STATUS` bits —
were fixed and verified; see Closed.)

### 43. Scoped-MCP exceptions require an independently reproducible netlist audit

**Blocks:** timing signoff using any `set_multicycle_path` exception.

The current 32 MHz closure strategy relies on MCP=3 for paced DSP cones and
selected quasi-static writes, plus MCP=2 for the CE-gated register-bank write
path.  This is only valid when the RTL guarantees the advertised settle window
*and* the SDC resolves to precisely the intended post-synthesis/post-route
paths.  That second condition is not yet a signoff gate: hierarchy and net
names change during synthesis, and previous SDC revisions have had both
silent no-op collections (`STA-0361`/`STA-0472`) and overly broad endpoint
exceptions that temporarily hid a genuine one-cycle path.  The B6 integration
run also records an `iq_samp_cnt -> u_pcfsm.pkt_cnt` cluster suggesting that a
v25_b6 load-arc exception partially misses.

**Required closure evidence, for every signoff SDC revision:**

- Run an automated audit on both the synthesized and routed netlist.  It SHALL
  fail if any SDC collection used by an MCP is empty, changes unexpectedly
  between stages, or produces `STA-0361`/`STA-0472`/"no valid objects".
- Emit the fully resolved MCP-covered startpoint/endpoint arcs and retain them
  with the signoff artefacts; review that no fast-changing sibling input is
  relaxed by a broad `-through` or endpoint scope.
- For each exception, cite an RTL assertion, formal proof, or directed
  simulation demonstrating that the receiver cannot consume the value before
  the claimed 2- or 3-cycle settling window.  The proof must cover reset,
  re-arm, and configuration-write boundaries.
- Report unrelaxed single-cycle timing separately, so a scope miss is visible
  as a failing cone rather than being confused with a closed MCP path.

**2026-08-14 — `pcfsm_quasi_static` and `pcfsm_mval` settle proofs FAIL: the
exceptions are not justified by the RTL as it stands (job 4351).** New bench
`cocotb/mcp_pcfsm_settle/` + `cocotb/tests/test_mcp_pcfsm_settle.py`
(TOPLEVEL = `packet_ctrl_fsm`), 4 tests, 2 PASS / 2 FAIL — and the two
failures are the finding, not a broken test.

`packet_ctrl_fsm.v` captures the whole quasi-static cone
(`sf`, `sample_shift`, `pkt_timeout_syms`, `tacc_window_syms`, `M_val` →
`acq_load`/`wpend_load`/`pkt_load`) at exactly **one** instant per packet, the
`ST_ACQ_SETUP` edge, which is the cycle *immediately after* the `sc_lock`
rising edge that sets `packet_active`. `reg_bank.v` gates `sf_cfg`/`bw_sel`
writes on `!packet_active` (and does not gate `pkt_timeout_syms`/
`tacc_window_syms` at all, 0x0B/0x27), but `packet_active` only rises **at**
that same edge, so a host write is still accepted one cycle before it — and
even on it. Measured:

- `test_pcfsm_config_change_before_lock`: config write one cycle before lock →
  `M_val` (one pipeline stage behind `sf`) changes on the very edge before the
  capture. **1 cycle of settling where the SDC granted 3** → `pcfsm_mval`.
- `test_pcfsm_direct_source_change_at_lock`: write landing on the lock edge →
  `sf`, `pkt_timeout_syms`, `tacc_window_syms` all move within the window →
  `pcfsm_quasi_static`.
- `test_pcfsm_load_settle_normal` (config settled long before lock) and
  `test_pcfsm_midpacket_change_is_safe` both PASS — the latter usefully
  **bounds** the hazard: because the cone is single-capture, mid-packet changes
  to the ungated registers can never be captured. The exposure is only the
  ~3 cycles before `ST_ACQ_SETUP`.

The SDC's justification for these two groups ("host-writable, kHz-rate,
long-settled by the time any hit/lock event samples it") is therefore wrong in
kind: write *rate* is irrelevant, only the distance between the last change and
the single capture edge matters, and nothing in the RTL enforces that distance.
Reachability is through the real write path — `reg_bank` sees the combinational
`packet_active` with no extra pipeline stage (`trouper_top.v:741`), so it reads
0 at both u−1 and u.

**Caveat:** the bench is unit-level and drives `sf` etc. directly; the
write-lock it reasons about lives in `reg_bank`. The argument above closes that
gap by inspection, but an end-to-end version driving real SPI writes (the
`regbank_write` proof's method) would make reachability airtight.

**2026-08-14 — the defect is family-wide, not pcfsm-specific.** Checking the
other groups by inspection: `pcfsm_latched_timing_ref` has the same flaw (the
v24 #39 fix latches `lat_timing_ref` at u and captures it at u+1 — the SDC
argues stability *after* the capture, which is the wrong side);
`training_window` and both `timing_ref` groups capture at the `sc_lock`/
final-hit edge itself, one cycle earlier than pcfsm, so `packet_active` never
covers them; `sc_quasi_static` captures **continuously** (the correlator runs
before lock) and so cannot be fixed by delaying any single instant;
`sc_clear` is unsound for a different reason (a 1-cycle `packet_done_pulse`
cannot offer a 3-cycle window). `psram_barrel_shift` is the sole group with a
real structural guarantee (`psram_buf_ctrl.v:314`, `sf == sf_prev`) and needs
only a bench.

**Chosen route (2026-08-14, area/timing-driven): enforced firmware discipline,
not per-block settle logic.** `sc_clr` is already level-sensitive
(`sc_detector.v:492` holds `sc_lock`/`hit_count`/all accumulators cleared while
high), so a firmware-writable `RX_HOLD` bit ORed into it makes "config writable"
and "detector able to lock" mutually exclusive — the settling requirement then
holds vacuously for 6 of the 9 groups at ~4-6 flops, with **no enable terms
added to any wide register in `sc_detector`/`training_acc`**. Hardware must
*reject* the gated writes (with a sticky `CFG_WR_REJECTED` bit) or it is a
convention rather than evidence. Residual RTL: `pcfsm_latched_timing_ref` still
needs a 4-flop setup-delay counter (it is internal to the FSM and firmware
cannot affect it), and `sc_clear` needs separate treatment. Full design,
release-ordering argument, verification and contract changes:
`planning/mcp-config-settle-gate-design.md`.

**2026-08-15 — FIXED and verified (commit f1aa262).** `RX_HOLD` (0x1A[0], set
out of reset) ORs into the level-sensitive `sc_clr` and gates writes to
0x09/0x0A/0x0B/0x0E/0x27 on `rx_hold && !packet_active`, making "config
writable" and "detector able to lock" mutually exclusive; `packet_ctrl_fsm`
dwells 4 cycles in `ST_ACQ_SETUP` for the two operands firmware cannot protect
(`lat_timing_ref`, `M_val`). `test_mcp_pcfsm_settle` now 4/4 (job 4362), full
`packet_ctrl_fsm` block regression 7/7 incl. formal and the B6 equivalence TB
(job 4365), all 18 top-level suites PASS (4357/4359), reg_bank 13/13 on both
simulators (4353/4356). This closes the settling obligation for `pcfsm_quasi_static`, `pcfsm_mval`
and `pcfsm_latched_timing_ref`. **2026-08-15:** the RX_HOLD mutual-exclusion
bench (`cocotb/mcp_cfg_hold_settle/`, job 4368, 3/3) additionally closes
`sc_quasi_static`, `timing_ref_hits`, `timing_ref_config` and
`training_window` -- it asserts both halves of the interlock (no lock while
held, including via `SC_FORCE_LOCK`; no config net changes while the detector
is live) plus the §5 release-ordering obligation. **9 of the 11 manifest
groups now carry a passing proof**; **2026-08-15 (later):** `psram_barrel_shift` closed too (`cocotb/mcp_psram_bshift_settle/`, job 4372, 3/3 -- the `sf == sf_prev` gate genuinely buys the 2 cycles its MCP=2 claims, verified including a run with `sf` changing every cycle where no load occurs at all). That leaves **`sc_clear` as the only open group, and it should be DELETED rather than proven**: its source `packet_done_pulse` is a registered 1-cycle pulse into synchronous-clear registers that sample every cycle, so the capture is at t+1 and there is no 3-cycle window to grant -- and it has been hiding genuinely violating paths rather than relaxing a real settling window. **Withdrawn in SDC v26 (commit d7c21bd).** **2026-08-16 -- correction:** an earlier reading of this cone as "+3.94 ns MET at `max_ss_125C_3v00`" (job 4374) was measured on job 3738's netlist, built with `PL/GRT_RESIZER_SETUP_SLACK_MARGIN=9` for the 4.5 V experiment; that netlist is heavily buffered and does **not** represent `config_current_signoff`, where these paths violate at up to -5.35 ns (job 4376). The withdrawal instead rests on a controlled A/B with the exception restored and everything else byte-identical (job 4377, `config_ctl_scclr.json` + `pnr_32m_ctl_scclr.sdc`): **WNS unchanged to 12 decimal places** (-20.117533 either way -- the critical path is `u_remod.s3_i[2]`, which the exception never covered) and **TNS -32.87 ns, ~1% of -3246**. Withdrawal therefore costs no critical path, and the pulse-stretch alternative stays rejected: it would add flops and a dedicated signal to recover 1% of TNS.

**Superseded candidate fix:** delay the counter load by 3 cycles.
Once `packet_active` is 1 at u, no further config write can land (given the
0x0B/0x27 write-locks the design adds), so every source is stable from u+1 —
`M_val` included, one stage behind `sf`. Capturing at u+4 therefore leaves the
3 preceding edges quiet. The loads are computed as *remaining* ticks from the
live `sample_count` (`packet_ctrl_fsm.v:88-108`), so delaying them is
arithmetically self-correcting rather than a timing shift. Costs 3 cycles
(~94 ns) of packet-start latency against a ≥8 µs symbol, but it is a change to a verified
FSM and needs the full `packet_ctrl_fsm` regression.

**2026-08-14 — this item is on the critical path at every core voltage
(job 4349, see item 1).** Re-timing the 4.5 V routed netlist with the MCP
exceptions withdrawn gives WNS −22.84 ns / TNS −5922 ns against +3.17 ns with
them. The 4.5 V contingency therefore cannot be used to sidestep these proofs;
whichever rail is chosen, the 9 unproven groups below still gate signoff.

Until this audit passes, scoped MCP may be used for exploration but is not
sufficient evidence for tapeout timing closure.  See
`src/config/pnr_32m_scoped_v25_b6.sdc` and
`planning/b4-b6-area-cuts-2026-07.md` §4.1/§3.1.

**2026-07-31 implementation:** `rtl-test/ol_trouper_top/mcp_audit.tcl` now
loads the active SDC against a supplied synthesized or routed netlist and
emits every named MCP collection for independent review.
`rtl-test/scripts/run_mcp_audit.sh` runs it via `hqsub`/SGE (an earlier
version used a local `docker run` that could not reach P&R artifacts living
on NFS — fixed same day) and `audit_mcp.py` fails closed on empty/missing
collections, STA-0361/0472, or a changed reviewed baseline.

**2026-07-31 first real evidence + baselines approved (jobs 3740/3741 synth,
3742/3743 route):** ran against the current signoff netlist (job 3733,
`config_current_signoff.json`, `06-yosys-synthesis/trouper_top.nl.v` for
synth and `final/nl/trouper_top.nl.v` + `final/spef/max/trouper_top.max.spef`
for route). All 11 groups resolved to non-empty collections at or above the
manifest minimums at both stages, no `STA-0361`/`STA-0472`/"no valid
objects", and — notably — the resolved through-net and endpoint-register
names are **byte-identical between the synth and route evidence files**
(`diff` clean), i.e. no scope drift introduced by placement/routing/CTS for
this netlist. Both stage baselines reviewed and approved
(`mcp_audit_baseline.json`). This confirms the SDC's collections resolve to
real, non-trivial, stable objects — it does **not** confirm the RTL settling
claims themselves (still needs the per-group formal/assertion/simulation
evidence named in `mcp_audit_manifest.json`'s `proof` field, none of which
exist yet).

**2026-07-31 `iq_samp_cnt -> u_pcfsm.pkt_cnt` lead RESOLVED (not a scoping
bug):** chased using the new audit evidence. `packet_ctrl_fsm.v:98-104`'s own
comment and the SDC's v21 header (`pnr_32m_scoped_v25_b6.sdc:143-149`) both
explicitly state this arc is *intentionally* left at honest single-cycle
because it depends on the live `sample_count`/`iq_samp_cnt` operand, not a
quasi-static one. The audit confirms `pcfsm_timeout_regs` (the endpoint
covering `pkt_cnt`) resolves to exactly the intended 63 down-counter bits,
and no MCP group's `-through` collection touches `iq_samp_cnt`/`sample_count`
on a path into `u_pcfsm.*`. The `-6.65`/`-9.61 ns` STA hits on this cluster
are genuine, deliberately-unrelaxed SS timing debt — same class as the
`u_psram` QSPI residual and `training_armed → Zdiag`/`Zpair` arcs already
tracked under item 1. See `planning/b4-b6-area-cuts-2026-07.md`
§2026-07-31 follow-up.

**2026-08-09 `paced_dsp` group settling proof CLOSED:** added four unit-level
cocotb benches (`cocotb/mcp_decimator_settle/`, `cocotb/mcp_sc_settle/`,
`cocotb/mcp_tacc_settle/`, `cocotb/mcp_mrc_settle/`, tests
`cocotb/tests/test_mcp_decimator_settle.py`, `test_mcp_sc_settle.py`,
`test_mcp_tacc_settle.py`, `test_mcp_mrc_settle.py`), one per block in the
`paced_dsp` scope (`u_dec.* u_sc.* u_tacc.* u_comb.*`, SDC lines ~336-344).
Each bench runs the DUT directly (no trouper_top wrapper) and uses a
background clock-edge monitor to assert the block's MCP-relaxed consumed
result register (`hb1_hold_i/q`+`iq_out_i/q` for the decimator gated by
`hb1_wait`/`hb2_wait`; `tdm_mul_r` for sc_detector gated by `tdm_wait`;
`mul_out`/`mulB_out` for training_acc gated by `tdm_wait`/`pipe_active`;
`prod_i_r`/`prod_q_r`+`y_i`/`y_q` for mrc_combiner gated by `mac_wait`) never
changes unless its wait counter held its terminal `MAC_WAIT`/`TDM_WAIT` count
(2, i.e. 3 cycles) on the immediately preceding edge, plus a reset-mid-burst
case per block confirming the pacing counters clear and re-arm cleanly with
no stale/glitched result latched. training_acc's `mul_out`/`mulB_out` are
deliberately resetless (same pattern as `Zpair_*`/`Zdiag_*`); the test
documents this and instead asserts the *consuming* counters (`tdm_active`/
`acc_active`) clear and that a post-reset training window still produces a
bit-exact `Zdiag_0`, proving no stale product leaks into a live Z register.
All 8 testcases (2/block) PASS: SGE job 4083 (`mcp-paced-dsp-settle-v2`,
`cocotb/mcp_decimator_settle/run_regression_sge.sh`). Manifest's `paced_dsp`
group `proof` field updated accordingly
(`rtl-test/ol_trouper_top/mcp_audit_manifest.json`). This closes the
settling-proof obligation for `paced_dsp` only — the other 9 MCP groups in
the manifest remain open (see `regbank_write` closure immediately below).

**2026-08-09 `regbank_write` group settling proof CLOSED:** added
`test_regbank_write_bus_ce_gated` to `cocotb/tests/test_spi_cdc.py`, covering
the `regbank_write` MCP group (SDC lines ~347-354: MCP=2 setup / MCP=1 hold,
scope = `{rb_we, rb_addr[*], rb_wdata[*]}`). `trouper_top.v` (~667-701)
assigns `rb_addr`/`rb_wdata`/`rb_we` only inside `if (ce_16m)` of the single
`always @(posedge clk)` block that stages both the SPI and Grouper write
sources, and `reg_bank` is instantiated with `.clk_en(ce_16m)` — a structural
guarantee, not a settling-time argument, that the write bus cannot change
except on a `ce_16m`-gated edge. The test adds a background clock-edge
monitor asserting the converse directly (any observed change on
`rb_we`/`rb_addr`/`rb_wdata` must be paired with `ce_16m==1` sampled on the
preceding edge, `RESETB` transitions exempted) across three scenarios: reset
asserted mid-write-frame (bits 3/11/15), 64 back-to-back minimum-spacing SPI
writes, and a Grouper write (`GRP_WE`) injected mid-frame against an in-flight
SPI write — the two sources that both feed this bus. PASS: SGE job 4120
(`spi_cdc_regbank_write3`, `make -C cocotb/spi_cdc
TESTCASE=test_regbank_write_bus_ce_gated`). Manifest's `regbank_write` group
`proof` field updated accordingly. This closes the settling-proof obligation
for `regbank_write` only — the remaining 9 MCP groups in the manifest stay
open.

(Note: an earlier attempt at this same test, SGE job 4091, failed in 2s on a
`cd: No such file or directory` — submitted with `--project
lora-mimo-reg_bank` instead of this repo's required `--project lora-mimo`,
which mounts the container at the wrong path per `sge-job` skill's
documented convention. Not an RTL or test issue; job 4120 resubmitted
correctly and passed on the same script/test.)

**2026-08-27 — signoff SDC split; three more scope-miss cones relaxed
(v28–v30), and the `iq_samp_cnt → u_pcfsm.pkt_cnt` "deliberate debt" reading
above is now reversed.** Post-DRV-closure worst-path analysis on job 5105
found ~730 SS setup violators / TNS −3960 ns, mostly paced or quasi-static
cones being timed single-cycle because the `paced_dsp` `-through u_*.*`
wildcards never match their nets — the nets surface post-synthesis under
top-level array names (`Zpair_q[3][10]`, `comb_y_*`, `iq_samp_cnt[*]`), same
match-gap class as items 39/40 and the v27 `pcfsm_mval_write` fix.

Fix: `SIGNOFF_SDC_FILE` now points at a new
`rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6_signoff.sdc` = the P&R SDC +
three `set_multicycle_path 3 -setup / 2 -hold` groups. `PNR_SDC_FILE` is
**unchanged**, so the placed+routed netlist is byte-identical to job 5105
(`def/nl/pnl/lef/spice/vh` all match). Signoff-only because adding any of
these to the P&R SDC strands the IQ_CLK root clkbuf with no routing access
point (`DRT-0073`, job 5112 — the same routability-headroom limit item 1
and item 6 already track). Keeping them out of P&R also keeps the resizer
building those paths conservatively at single-cycle.

- **`tacc_accumulate`** — `Zpair_i/q[*]`/`Zdiag[*]` accumulator flops (512
  endpoints). The `training_acc` MAC recurrence, wired out to top-level
  `Zpair_q[*][*]` array nets for reg_bank readback. Proof: transitive via
  the shared `active_cycle` gate proven in `test_mcp_tacc_settle.py` (job
  4083) — the accumulate fires under the same `acc_active && active_cycle`
  the monitor asserts gates `mul_out`/`mulB_out`. A direct `Zpair`/`Zdiag`
  endpoint settle assertion would close it fully.
- **`iq_samp_cnt`** — the top-level 32-bit sample counter (`trouper_top.v:171`,
  `+1` per `dcr_valid`), 20 endpoints. Proof: new
  `cocotb/tests/test_mcp_iq_samp_cnt_settle.py` (TOPLEVEL = `trouper_top`),
  SGE job 5120, 3/3 PASS.
- **`pcfsm_tick_decrement`** — `$pcfsm_timeout_regs` (`acq_cnt`/`wpend_cnt`/
  `pkt_cnt`, 63 endpoints). Relaxes the two write arcs the v21/v24
  `-through` blocks miss: the `sample_count → ST_ACQ_SETUP load` operand,
  and the `if (iq_tick) cnt <= cnt-1` decrement recurrence. **This is the
  arc the 2026-07-31 follow-up above called "genuine, deliberately-
  unrelaxed SS timing debt".** That reading assumed `iq_tick` could be
  frequent. `test_mcp_iq_samp_cnt_settle.py::test_dcr_valid_single_cycle`
  (job 5120) now proves `dcr_valid` (= `iq_tick`) is a 1-clock pulse with
  min spacing 64 IQ_CLK cycles — `sd_decimator_poly.v:348` sets
  `iq_valid<=4'hf` on `hb2_stream_last` only, `dc_removal.v:110` is a
  1-cycle registered passthrough — so the decrement recurrence has ~63 idle
  cycles (21× the 3-cycle budget) and never a back-to-back launch. The load
  arc gets its 3 settled edges from the `ST_ACQ_SETUP` 4-cycle dwell
  (proven by `test_mcp_pcfsm_settle.py`, job 4362) and the `− iq_tick`
  correction term. MCP=3 is honest on both.

All three audited non-vacuous on job 5122's routed netlist via
`run_mcp_audit.sh --stage route --sdc …_signoff.sdc` (the script gains a
`--sdc` flag), SGE job 5124, baseline updated
(`mcp_audit_route.evidence` / `mcp_audit_baseline.json`); resolved endpoint
counts 512 / 20 / 63 match the RTL register widths exactly. Manifest
entries carry the full per-group rationale and mark each SIGNOFF-ONLY.

Result (job 5122, same silicon as 5105): **SS setup WNS −15.71 → −12.45 ns,
TNS −3960 → −897 ns**; nom_tt / max_ff still met; DRC 0, LVS 0; slew/cap
residual 15/6 unchanged. Committed `4bf56f3` on branch
`pnr/trouper-drv-closure-t4b`; `final/` regenerated (STA reports + metrics
only — geometry unchanged). Remaining 229 SS violators and the deliberate
stop are in `final/README.md` "SS timing residual": ~140 are the genuine
voltage-bound paced-DSP floor (item 1 / item 27 / item 44 — needs ~4.5 V
core), the rest are quasi-static cones (`psram_qe_init_done` one-shot,
`rb_comb_post_gain_shift → comb_y`, residual `timing_ref`) left as
documented waivers rather than growing the signoff MCP list further. The
`rb_comb_post_gain_shift → comb_y` cone (−8.59 ns, 14 paths) is the same
scope-miss class and could be a v31 signoff group if ever wanted.

**Still open:** the settling-proof obligation is now met for `paced_dsp`,
`regbank_write`, `psram_barrel_shift`, `pcfsm_mval_write`, `tacc_accumulate`,
`iq_samp_cnt`, `pcfsm_tick_decrement`; `pcfsm_quasi_static` /
`pcfsm_mval` / `pcfsm_latched_timing_ref` still fail their bench (the
2026-08-14 finding above) and the `sc_*` / `timing_ref_*` groups still lack
a dedicated proof.

---

## High

### 68. A firmware noise-window completion is aliased as packet-training completion — CLOSED 2026-09-03 (mode-tagged completion + noise-window pre-empt + round-2/3 follow-ups; regression + A40 P&R clean)

> **CLOSED 2026-09-03.** Fixed on `rtl/open-risk-fixes` (commits `a844409` /
> `8a30d2d`): `training_done_pkt` (packet-mode-only completion) + `noise_abort`
> pre-empt pulse, plus the three round-2/3 follow-up fixes (pipeline-flush via
> per-window `win_epoch`, retrigger-race single priority ladder, eval-boundary
> `noise_eval_armed`/`noise_eval_seen` gate with detector-dark bypass). All
> detailed in the body. Verified: `test_noise_trig.py` +
> `test_noise_window_edge.py` (10/10, SGE job 5498), combined `core` + `capture`
> regression 50 suites all PASS (SGE job 5496). A40 P&R SGE job 5499
> (`src/config/trouper_top.json`, rebased onto `pinout/dbg1-shared-irq-pad-27`):
> signoff-clean (DRC 0, LVS 0, XOR 0, antenna 0/0, hold MET), SS setup
> WNS −10.77 ns / TNS −370.4 — no regression vs reference runs 5379/5378.
> Full P&R write-up in #66.

`packet_ctrl_fsm` leaves `ST_IDLE` on any `sc_lock` rising edge
(`packet_ctrl_fsm.v:199`) with no check on `training_armed` / noise mode.
`training_acc` refuses to convert an in-flight window because `armed` is already
set (`training_acc.v:273`) and its disarm is suppressed in noise mode (`:263`),
so a firmware noise measurement armed while idle keeps running even after a real
packet is acquired. Its mode-untagged `training_done` then:
- sets `w_pending` (`trouper_top.v` w_pending block), and
- advances the packet FSM out of `ST_PREAMBLE_ACQ` into `ST_W_PENDING`
  (`packet_ctrl_fsm.v:242`).

Firmware therefore reads the noise (or noise + partial-preamble) Z accumulators
as if they were this packet's training correlations, and the packet's real
training window cannot even start until the long noise window drains — that
packet is guaranteed `W_MISSED` and the FSM can stay mis-phased for the next.
`test_noise_trig.py` only checked that `NOISE_READY` stays clear, so it missed
the state-machine corruption. `psram_buf_ctrl` was already immune (its
`buf_base_valid` gate explicitly excludes noise-mode `training_done`).

**Found:** 2026-09-03, P1 review finding while checking the #66 fix.

**FIXED 2026-09-03 (branch `rtl/open-risk-fixes`) — mode-tagged completion +
noise-window pre-empt.** `training_acc.v` gains:
- `training_done_pkt` — asserts **only** for a packet-mode window's completion;
  `training_done` still asserts for either mode (reg_bank `TRAINING_STATUS` bit
  / IRQ, per TRPR-TAC-007).
- `noise_abort` — 1-cycle pulse when `sc_lock` rises while a noise window is
  armed: the window is cancelled (`armed`/`noise_mode_r` clear), so the next
  edge re-arms a proper packet-mode window at `acc_start = timing_ref`.

`trouper_top.v` routes `training_done_pkt` (not `training_done`) to `w_pending`
and `u_pcfsm`; the #66 noise-qualification block drops its window on
`noise_abort` (no verdict — firmware's `NOISE_READY` wait times out and it
retries once the packet clears). Verified: new
`cocotb/tests/test_noise_trig.py::test_noise_window_preempted_by_real_packet`
(noise armed idle → CW packet locks → asserts `noise_abort` pulses,
`noise_window_active` drops, `NOISE_READY` never fires, `w_pending` not set by
the cancelled completion, real packet trains and the FSM reaches the payload
phase) + `noise_window_edge::test_noise_abort_drops_window`.

**Follow-up review round 2 (2026-09-03) — three more holes on the same path,
all fixed on the branch (regression + A40 P&R now complete, see below):**

1. **P1 — the pre-empt did not flush `training_acc`'s pipeline.** The abort
   cleared `armed`/`noise_mode_r` only; a final noise sample already latched in
   the TDM/accumulate pipeline could reach the completion block after
   `noise_mode_r` went low and assert `training_done_pkt` — a false packet
   completion (reviewer's boundary sim reproduced it). A first attempt with a
   global `acc_win_valid` *level* was **still broken** (round-3 review): a real
   packet re-arms on the very next cycle and re-raises the level long before the
   ~57-cycle stale pipeline drains. **Fix (round 3): per-window epoch.** A 2-bit
   `win_epoch` bumps on **every** arm and on the abort; each pipeline item
   carries the epoch it launched under (`tdm_epoch` → `acc_epoch`); the
   accumulate / completion block only fires when `acc_epoch == win_epoch`. A
   stale item from an aborted window carries the retired epoch and is dropped
   regardless of pipeline depth or how fast the re-arm follows.

2. **P1 — a noise retrigger on the drain-release cycle was silently lost.** The
   #66 block had two independent `if` chains; a fresh `noise_trig_accept` set
   `noise_window_active<=1` while the old window's verdict path set it `<=0` the
   same cycle (later assignment won). **Fix:** collapsed to one priority ladder
   — `noise_trig_accept` (fresh clean window) → `noise_abort` → active-window
   (sc_seen latch + drain + verdict). An accepted trigger always wins.
   New `test_retrigger_during_drain_not_lost` (retrigger swept onto the exact
   verdict-render cycle).

3. **P2 — the fixed drain could not cover un-evaluated SC symbol history, and a
   stale in-flight eval could not be told apart from a fresh one.**
   `sc_pipe_active` only marks activity *currently* in flight; an SC evaluation
   launches only at a symbol boundary, so a packet starting late in the noise
   window sat un-evaluated with `sc_pipe_active` low until the next boundary —
   thousands of clocks past the fixed drain. A first attempt (require any
   `sc_eval_done_pulse` after drain start) was **insufficient** (round-3
   review): an evaluation already in flight at `training_done` was fed the
   *previous* symbol yet its completion satisfied the requirement. **Fix
   (round 3):** `sc_detector` exports **both** `sc_eval_done_pulse`
   (`= metric_valid_pulse`) and `sc_eval_start_pulse` (`= metric_start_pulse`,
   1-cycle at eval launch). During the drain, `noise_eval_armed` latches only on
   a *start* pulse after the drain began, and `noise_eval_seen` only on a
   *done* pulse while armed — i.e. an evaluation that both started and finished
   inside the drain. Worst-case `NOISE_READY` latency +~1 symbol period.

4. **P1 — the eval requirement deadlocked a clean measurement when the SC
   datapath is disabled** (`test_noise_trig.py` Phase A: PSRAM off ⇒ no delayed
   samples ⇒ `sc_detector` never evaluates). **Fix:** track `noise_sc_was_active`
   (sticky: `sc_pipe_active` high anytime this window). The eval requirement
   (item 3) applies only when the SC detector actually ran; SC dark ⇒ no
   contamination possible ⇒ verdict on the fixed drain alone.

Tests: `test_noise_window_edge.py` reworked — 10 cases incl. detector-dark vs
detector-live clean paths, `test_verdict_waits_for_eval`,
`test_stale_inflight_eval_does_not_release`, `test_late_hit_after_drain_rejected`,
`test_retrigger_during_drain_not_lost`.

Verification: full `core` + `capture` regression, SGE job 5496 — 50 suites, all
PASS except `noise_window_edge` 9/10 on a stale test expectation
(`test_retrigger_during_drain_not_lost` latched a legitimate pre-retrigger
verdict); test fixed (monitor-latch reset) and re-verified `noise_window_edge`
10/10 in SGE job 5498.

A40 P&R regression check — SGE job 5499 (`src/config/trouper_top.json`, rebased
onto `pinout/dbg1-shared-irq-pad-27`): signoff-clean (DRC 0, LVS 0, XOR 0,
antenna 0/0, hold MET), SS setup WNS −10.77 ns / TNS −370.4, no regression vs
reference runs 5379/5378. Full P&R write-up in #66.

### 6. DRT-1231 clkbuf CTS pin-access failure — **CLOSED 2026-09-03** (the SPI_SCK CTS exclusion survived a netlist perturbation 2.6× the one that broke it)

> **CLOSED — the stated exit criterion was tested and did not fire.** This item
> stayed open on one specific ground: the adopted `SPI_SCK` CTS exclusion was
> **n=1 on netlist perturbation**. Jobs 5284 and 5286 were the same netlist
> twice, so they could not exercise the thing that actually triggers the bug.
> The original trigger was small — a 6-line `reg_bank.v` edit worth **144 cells**
> (35526 → 35670) turned the clean job 5279 into the DRT-1231 failure of 5281.
>
> The Grouper-boundary removal then changed the netlist by **370 cells**
> (35670 → 35300) — a perturbation **2.6× larger** than the one that originally
> broke it. Five runs have since routed on that new netlist with the exclusion
> in place, all clean, with **zero `SPI_SCK` DRT-1231 recurrences**:
>
> | Job | What it was | Result |
> |---|---|---|
> | 5378 | stock-PDN control | clean |
> | 5379 | adopted PDN (width + ring) | clean signoff |
> | 5392 | canonical config | clean signoff |
> | 5394 | PDN pitch ×1.4 | clean signoff |
> | 5413 | final bundle streamout | clean |
>
> **One failure in that set is deliberately not being hidden:** job 5393 (PDN
> pitch ×1.2) *did* die in detailed routing — but on `DRT-0073` at
> `clkbuf_2_1_0_IQ_CLK_regs/I`, the **IQ_CLK** tree. Different net, different
> error code, under a deliberately hostile PDN pitch that was rejected for other
> reasons. It is not an `SPI_SCK` recurrence and does not re-open this item; it
> belongs to the density/routability budget recorded in `_comment_density`.
>
> **What remains true and must not be lost with the closure:** `SPI_SCK` is now
> a plain routed net, so nothing in P&R optimises those paths. That makes item
> 54 (host-SPI post-route GLS/SDF) carry more weight, not less. The `REJECTED,
> do not retry` list in `_comment_cts_spi_sck` also stands — closing this item is
> not licence to re-roll `CTS_CLK_BUFFERS`, `CTS_ROOT_BUFFER` or the density
> knob. Original analysis retained below for the record.

A minimal fix is confirmed clean at 1380×1100 (v15c), but the same DRT-1231
violation (`clkbuf_*_IQ_CLK_regs/I` pin access) **returns** under the
honest-MCP/scoped-SDC config (v24, job 2211) and at every relaxed-SDC
floorplan tried since (jobs 2165–2168). Described in the source doc as
"timing-SDC-sensitive" — the fix does not generalize across SDC edits.

**Blocks:** further die-shrink; the honest-MCP signoff configuration (item 1).
**See:** `planning/area-reduction-roadmap.md` §4 (Gate 0 blocker);
`planning/ss-corner-decimator-pacing-closure.md`.

**CLOSED 2026-08-30 — root cause found and fixed; the framing above was chasing the
wrong variable.** `DRT-1231`/`DRT-0073` on `clkbuf_*_IQ_CLK_regs/I` was never a CTS
buffer-set, SDC, or density problem: **antenna diodes were abutting the clock buffers
and stealing their routing pin access**, because `DIODE_PADDING` was unset (`None`).
Setting `DIODE_PADDING: 4` clears it outright — job **5198** at 1675×1110: 0 antenna
net / 0 pin, magic DRC 0, XOR 0, LVS clear, hold met at all corners, clock skew
0.312 ns. Same evidence that closed item 51.

This also retires the "timing-SDC-sensitive, does not generalize" reasoning: the
investigation proved buffer *size* is irrelevant — variant C4 (job 5197) dropped
`clkbuf_16` from `CTS_CLK_BUFFERS` and the failure simply moved to a `clkbuf_12`
(`clkbuf_4_3_0_IQ_CLK_regs/I`). The failure follows the clock tree to whichever
buffer the diodes box in, so every earlier CTS-side "fix" was treating a symptom.
Note `DPL_CELL_PADDING` is *not* an alternative lever (3 causes `DPL-0036`);
`DIODE_PADDING` applies to diode cells only and avoids that.

Both of this item's stated blocks are also stale: the honest-MCP/scoped-SDC
configuration is canonical (`pnr_32m_scoped_v25_b6.sdc`) and routes, and die-shrink
is now gated on routing congestion (item 12) and pad allocation (item 46), not on this.

**Residual (accepted, not blocking):** the fix is confirmed on the current signoff
floorplan only. Two 2026-08 runs on *other* floorplan variants hit `DRT-1231` —
job 4485 (1167.5², default margins) and job 5159 (density 78 at 1675×1110) — and
neither was re-run with `DIODE_PADDING` set, so generalization across floorplans is
untested rather than disproven.
**Re-open if:** `DRT-1231`/`DRT-0073` recurs on a floorplan that already has
`DIODE_PADDING: 4` — that would mean a second, distinct mechanism.
**See:** `planning/antenna-closure-investigation-2026-08.md` §0; item 51;
`planning/1117sq-margin-reclaim-2026-08.md` §4.

**RE-OPENED the same day, by its own stated trigger (job 5281).** The closure
above was written on **n=1** — a single clean floorplan — and the first
perturbation broke it. Job 5281 re-ran the *byte-identical* config to job 5279
(`resolved.json` diff is empty: same `DIODE_PADDING: 4`, `DPL_CELL_PADDING: 2`,
65 % density, 1675×1110 die, same `CTS_CLK_BUFFERS`) and died at step 46/78:

```
[DRT-1231] Pin clkbuf_2_3__f_SPI_SCK/I does not have access point
```

**The only delta between the two runs is a two-line RTL change** — adding the
`0x19` term to `reg_bank.v`'s `cfg_wr_rejected` condition. Detailed routing was
already in trouble before it died (520 violations at 10–20 % completion, plus
`GRT-0243 Unable to repair antennas on net with diodes`).

Two corrections to the closure reasoning above:

1. **`DIODE_PADDING: 4` is a mitigation, not a root-cause fix.** Diode crowding
   was *a* mechanism and setting the padding did clear job 5198 — but it does not
   make the design robust, because the underlying fragility is unchanged: the
   `IQ_CLK` net still has a **5213-terminal fanout** (`GRT-0281`), the clock trees
   are still routed with no slack for pin access, and whether any given buffer
   gets boxed in remains a placement lottery that a trivial netlist change can
   re-roll.
2. **It is not confined to `IQ_CLK`.** Every prior instance on record named an
   `IQ_CLK` buffer; this one is on the **`SPI_SCK`** tree. Any statement scoping
   this failure to the IQ clock is wrong.

**What this means practically:** the tapeout floorplan cannot absorb routine RTL
edits. Any change — even one that is functionally correct and regression-clean,
as this one is (job 5280: all 42 cocotb suites pass) — may fail P&R for reasons
unrelated to its content. Item 1's SS-closure work implies many such edits.

**2026-08-30, five probes later — root-caused to the `SPI_SCK` CTS tree, and
there is a working fix (job 5284).** Two claims in the paragraphs above are
wrong and are corrected here.

| job | change from the 5281 recipe | result |
|---|---|---|
| 5279 | *(35,526-cell netlist)* | **routed clean 78/78** |
| 5281 | 35,670-cell netlist, 65 % density | `DRT-1231` `clkbuf_2_3__f_SPI_SCK/I` |
| 5282 | density 63 % | `DRT-1231` `clkbuf_2_1__f_SPI_SCK/I` |
| 5283 | density 60 % | `DRT-1231` `clkbuf_2_1__f_SPI_SCK/I` |
| 5285 | `clkbuf_4` added to `CTS_CLK_BUFFERS` | `DRT-1231`, step 46 |
| **5284** | **`SPI_SCK` not declared a clock in the P&R SDC** | **routed clean 78/78** |

**Correction 1 — it is not a placement lottery.** Densities 63 % and 60 % failed
on the *identical* buffer, and 65 % on a sibling of the same tree. For a given
netlist the failure is deterministic. Lowering density is not a lever at all.

**Correction 2 — it is not the `IQ_CLK` fanout.** Every failure is on `SPI_SCK`;
`IQ_CLK_regs` and its 5211 sinks route fine in all six runs. Nor is NDR the
differentiator: `CTS_APPLY_NDR: half` is global and the DEF carries one NDR root
net per clock (`CTS_NDR_0` `IQ_CLK`, `CTS_NDR_1` `IQ_CLK_regs`, `CTS_NDR_2`
`SPI_SCK`).

**The actual mechanism.** `SPI_SCK` is a 2 MHz clock with **51 sinks** that CTS
expands into 5 clock nets and drives with four **`clkbuf_16`** — the widest cell
in the set — on leaf nets of 2–7 sinks, with an NDR on the root. The pin
detailed routing cannot reach is the `I` input of one of those buffers. Job 5285
shows the buffer *list* is not the constraint: adding `clkbuf_4` changed nothing,
CTS still logged `Root buffer is clkbuf_16` / `Sink buffer is clkbuf_16` and
failed identically. It also retro-explains job 5197 (removing `clkbuf_16` moved
the failure to a `clkbuf_12`) — CTS picks by its own slew/cap targets, so neither
adding nor removing a size changes what it does.

**The fix (job 5284): give `SPI_SCK` no CTS tree at all.** A P&R-only SDC
(`pnr_32m_scoped_v25_b6_nospicts.sdc`) omits its `create_clock`, so TritonCTS
reports 2 clock nets instead of 3 and `SPI_SCK` routes as an ordinary net.
Result: **78/78, SS WNS −18.23 ns / TNS −459.8, antenna 0/0, DRC 0, XOR 0,
LVS clean, util 66.2 %.** A 2 MHz clock does not need a balanced tree.

**SPI timing is unaffected, and this was checked rather than assumed.** The
post-P&R signoff STA reads the *signoff* SDC, which still declares `SPI_SCK`, so
the domain is fully constrained at signoff: the `SPI_SCK` path group is present
with worst setup slack **241.77 ns MET** (5279: 241.14) and worst hold **2.10 ns
MET** (5279: 1.69) against a 500 ns period.

**Costs, stated honestly.** SS WNS is 0.49 ns worse than 5279 (−18.23 vs
−17.74) — but that is confounded with the +144-cell `reg_bank` netlist and
cannot be attributed to the SDC change from one run. Two marginal max-cap
violations appear at SS where 5279 had none (`_38228_/ZN` −0.0029 pF,
`_38209_/ZN` −0.000018 pF against an 0.082 pF limit); both are internal gates,
neither is on an SPI net.

**ADOPTED 2026-08-31 into the canonical SDC (job 5286).** The exclusion now
lives in `src/config/pnr_32m_scoped_v25_b6.sdc` itself rather than a variant, so
every config under `src/config` and the 13 under `rtl-test/ol_trouper_top`
inherit it; `rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6.sdc` was byte-identical and
was updated in step. Job 5286 re-ran the stock `trouper_top_dbgpins.json`
against that promoted SDC and reproduced job 5284 on every metric — SS WNS
−18.23 ns, TNS −459.8, antenna 0/0, DRC 0, XOR 0, LVS clean, util 66.2 % — so
the promotion is faithful to what was validated, not an approximation of it.
The `nospicts` variant config and SDC are deleted as redundant. **Superseded
2026-09-01:** the `_d63`, `_d60` and `_smallbuf` probe configs are now deleted
too — they inherited the fix and no longer reproduced the failures tabulated
above, so they had stopped being probes. The knobs they swept
(`PL_TARGET_DENSITY_PCT` 63/60, `clkbuf_4` in `CTS_CLK_BUFFERS`) and the reason
each was rejected are recorded in `_comment_cts_spi_sck` in
`src/config/trouper_top.json`; recover the files with
`git show <rev>:src/config/<file>` if the failure recurs.

**Why this item stays OPEN despite a working, adopted fix.** Jobs 5284 and 5286
are the *same netlist twice*, so the evidence is still **n=1** on the thing that
matters — whether the fix survives a netlist change. That is precisely the
mistake that produced the premature closure above, and it is not being repeated.

**Exit criterion (unchanged):** one clean route on a *different* perturbed
netlist. Until then, treat the floorplan as still fragile.

**Live caveat.** `SPI_SCK` is now a plain routed net carrying whatever skew the
router gives it. Signoff STA still constrains the domain and shows vast margin
(241.77 ns setup / 2.10 ns hold against a 500 ns period, job 5284), but nothing
in P&R optimises those paths any more — which makes item 54 (host-SPI post-route
GLS/SDF) more load-bearing, not less.

**Rejected alternative.** Making the `reg_bank` edit netlist-neutral, so the
+144 cells never appear, was considered and **rejected as too fragile**: it
would rest on ABC continuing to share an address decoder, which no constraint
enforces and any future edit could silently undo.
**Runs:** 5279/5281/5282/5283/5284/5285/5286 under
`/srv/eda/runs/timothyn-dev/lora-mimo-dbgpnr/`; configs
`src/config/trouper_top_dbgpins{,_d63,_d60,_smallbuf}.json`, all four since
collapsed into or deleted in favour of `src/config/trouper_top.json`
(2026-09-01) — see `git log -- src/config/`.
**See:** job 5281 log `/srv/eda/logs/timothyn-dev/job-5281.o`; job 5279 (clean,
same config); the rationale block inside `pnr_32m_scoped_v25_b6.sdc`;
`planning/antenna-closure-investigation-2026-08.md`; item 51.

### 8. AGC calibration and edge-case behavior are unverified on silicon

Trouper has no on-chip analogue AGC target/guard registers, and (as of
2026-07-28) no on-chip gain-shadow/commit register either — `RX_GAIN_SHADOW_0..3`/
`RX_GAIN_ACTIVE_0..3`/`RX_GAIN_CTRL` were removed since Trouper has no
SX1257 SPI/control outputs to apply them to. Gain is entirely an
external-SX1257 policy: Grouper/board firmware programs each SX1257 directly
at a packet-safe boundary, while fixed programmed gain remains the supported
fallback. Calibration, persistently bad-branch policy, and
strong-blocker/near-far behaviour are unverified on the real board; gain
changes are deliberately prohibited mid-packet.

**Risk:** deployment-time AGC misbehavior with no bench coverage.
**See:** `planning/blocks/AGC.md` (Open calibration items).

### 29. Grouper/AHB-Lite bus has no CDC — relies on an implicit same-clock assumption — **CLOSED 2026-09-01 (obsolete)**

> **CLOSED — the interface no longer exists.** Grouper is not taping out, and the
> `GRP_*` bus, the AHB-Lite `H*` endpoint and `IRQ_GROUPER` were removed from
> `src/top/trouper_top.v`. There is no inter-project bus left to synchronise, so
> this risk cannot materialise. Original analysis retained below for the record.


Grouper and Trouper are two **separately hardened MPW macros** joined by
inter-project wires (`planning/Pinout.md:93,97`), not a submodule inside
`trouper_top`. `trouper_top.v` has a single clock port (`wire clk = IQ_CLK;`,
line 69); `GRP_ADDR/GRP_WDATA/GRP_WE/GRP_RE/GRP_RDATA/GRP_READY` are plain
ports fed straight into a combinational mux and captured by one
`posedge clk` flop (`trouper_top.v:593-616`) — **no 2-flop synchronizer, no
async FIFO, no handshake**. `planning/System Architecture.md:189` lists the
link as nominally "32 MHz," but a shared nominal frequency does not mean a
shared clock tree — two independently hardened macros typically have
different PLLs/insertion delay/skew even at the same target frequency. By
contrast, the genuinely external SPI interface *does* get proper CDC:
`spi_slave.v` implements a persistent toggle + bundled-data mailbox
synchronizer (fixed 2026-07-12, commit `2b6af0f`, see Open Risk #15),
explicitly commented "Register writes cross into `clk_32m` via a toggle
synchroniser and bundled-data mailbox." No equivalent exists for `GRP_*`. Open Risk #16 already documents the
downstream *symptom* (SPI writes silently dropped if `GRP_WE`/`GRP_RE`
overlaps the SPI write window, plus an undocumented "hold `GRP_WE` ≥ 2
clocks" contract); this entry is the underlying root cause — if Grouper's
clock is not provably phase-aligned to Trouper's `IQ_CLK`, register writes/
reads across this bus are exposed to metastability, not just arbitration
drops.

**Risk:** silent register corruption or lost transactions on silicon if
Grouper's macro ends up on an independent clock tree (the normal case for
separately hardened blocks), with no bench-visible symptom besides
occasional bad register values.
**Action:** confirm with the Grouper team whether `IQ_CLK` and Grouper's bus
clock are the same physical net/phase-aligned, or add a proper CDC
synchronizer (2-3 FF handshake, matching the SPI pattern) on `GRP_WE`/
`GRP_RE`/`GRP_ADDR`/`GRP_WDATA`/`GRP_RDATA`/`GRP_READY`.
**See:** Open Risk #16 (arbitration symptom); `trouper_top.v:69,593-616`;
`spi_slave.v:159-202`; `planning/Pinout.md` (inter-project wire note).
**Found:** 2026-07-05 (Grouper bus clocking review).

**2026-08-16 — OWNED BY GROUPER TEAM, scheduled.** The Grouper team will build a
**bridge with proper CDC plus a 32-bit → 8-bit width conversion** in the week of
2026-08-17. This resolves the root cause on their side of the link, so no CDC
synchronizer is to be added inside `trouper_top` — doing so would double-
synchronize. Corroborating evidence that the two clocks are genuinely
independent: `ip/chipathon-2026-grouper/src/chip_core.sv:10` declares its own
top-level `input wire clk`, and the Grouper tree already carries a synchronizer
primitive at `src/rtl/sync.sv`.

**Trouper-side obligations that remain ours:**
- Agree the bridge's handshake contract (ready/valid vs the current
  `GRP_WE`/`GRP_RE` + "hold ≥ 2 clocks" convention) and update Open Risk #16,
  which documents that undocumented hold requirement as the arbitration symptom.
- Confirm the 32→8 conversion's byte order and address mapping against
  `planning/Register Map.md` (7-bit map, 24-bit Z readback at `[31:8]` — a
  32-bit bridge word maps onto that packing non-trivially).
- Re-verify `reg_bank` arbitration against the bridge once its RTL lands.

### 49. Grouper external-AHB endpoint is not yet an integration-safe macro interface — **CLOSED 2026-09-04 (obsolete)**

> **CLOSED — the endpoint no longer exists.** Grouper is not taping out this
> round. The `GRP_*` byte bus, the AHB-Lite `H*` endpoint added in `095ae2e`,
> and `IRQ_GROUPER` were all removed from `src/top/trouper_top.v` with the
> Grouper-boundary removal (2026-09-01; the only remaining trace is the removal
> note at `trouper_top.v:25`). SPI is now the sole register master, so there is
> no inter-project AHB interface left to harden, constrain, or BFM-test. If
> Grouper integration is revived in a future round this item must be re-opened
> against the re-added endpoint. Related: item 29 (CDC) and item 16 (SPI
> arbitration) are already closed-obsolete on the same grounds; item 50 (PSRAM
> debug-port arbitration) keeps only its non-Grouper residual — the `dbg_widx`
> wrap-after-8 bug; item 60 (functional sim of the removal itself) stays open.
> Original analysis retained below for the record.

Commit `095ae2e` adds Grouper's current 8-bit external-peripheral signals
(`HADDR`, `HWDATA`, `HTRANS`, `HSIZE`, `HWRITE`, `HRDATA`, `HREADY`, and
`HRESP`) to `src/top/trouper_top.v`, and adapts accepted byte transactions to
the CE-gated register-bank arbiter. This is an implementation start, not an
integration-closed endpoint:

1. The active IO-placement files still name only the legacy `GRP_*` bus. No
   physical pin list, placement, timing constraints, or macro-level wrapper
   has been updated for the new endpoint, so a P&R run cannot prove the
   intended inter-project connectivity.
2. The adapter accepts only `HSIZE=3'b000` and rejects `HADDR[7]`. Grouper's
   CPU bridge emits byte, halfword, and word accesses according to its native
   strobes (`hw/rtl/cpu_ss.sv` in Grouper `origin/dev`). Firmware must be
   constrained to byte MMIO accesses, or Grouper must provide the required
   width conversion before this endpoint is usable. Grouper currently does
   not turn `HRESP` into a software-visible fault.
3. The adapter samples its controls on Trouper's `IQ_CLK`. It is valid only
   after the clock relationship gate in item 29 is closed; with independent
   macro clocks, the AHB transfer must terminate in a Grouper-side CDC bridge,
   not cross these wires directly.
4. Existing cocotb wrappers tie the new port inactive, so SPI regressions
   establish only legacy non-regression. There is no AHB BFM test for normal
   accesses, error responses, wait-state persistence, or SPI collisions.

**Risk:** a superficially compiling interface can either be physically
unroutable, return errors for normal Grouper firmware accesses, or corrupt
transactions across a clock boundary.
**Action:** close the clock/pin contract; promote the endpoint through
Grouper's top/PD wrapper; decide byte-only firmware ABI versus width bridge;
add endpoint pin placement/constraints; and add a directed AHB BFM regression
before any integration P&R.
**See:** item 29 (CDC), item 16 (SPI arbitration),
`planning/grouper-trouper-control-integration-plan.md` (when merged), and
commit `095ae2e`.
**Found:** 2026-08-28, post-implementation review of `095ae2e`.

### 50. PSRAM debug data ports still bypass the proposed shared transaction arbiter

`PSRAM_DBG_DATA` (`0x76`) pops through the SPI-only `spi_reg_re` strobe and
`PSRAM_DBG_WDATA` (`0x79`) pushes directly from `spi_wr_new`. Neither event is
derived from the accepted AHB/CSR transaction. The new AHB endpoint therefore
cannot safely provide debug reads/writes with exactly-once semantics, and an
SPI debug-port access can bypass Grouper priority. The existing three-bit
`dbg_widx` also wraps after eight pushes, contradicting the documented rule
that a ninth byte is ignored until commit.

**Risk:** debug capture/writeback can tear, duplicate, or overwrite a line
when SPI and Grouper contend; future AHB debug support would have undefined
side effects.
**Action:** replace both bypasses with common post-arbitration read/write
accept events, latch read data before pop, make the write fill count saturate
at eight, define AHB error/no-side-effect behavior for invalid port accesses,
and add shared SPI/AHB debug-port tests.
**See:** item 16 and `planning/Grouper PSRAM CSR Exploration.md`.
**Found:** 2026-08-28, post-implementation review of `095ae2e`.

### 38. Host SPI CDC/pad timing is not fully signed off — write-event CDC low risk; volatile-read CDC accepted via firmware contract (Route 2, documented 2026-09-05); mailbox/pad-timing review still open

**Partially fixed 2026-07-12:** the persistent toggle/event CDC (commits
`2b6af0f`, `fef30de`) closes Open Risk #15 outright and makes completed writes
and read-side-effect events low functional risk at the specified 2 MHz rate.
Consecutive byte events are separated by about 128 `IQ_CLK` cycles, versus the
two-flop synchronizer's few-cycle delivery latency. The bundled mailbox and
the reverse, core-to-SPI read-data crossing still need the qualifications
below; this item must not be summarized as "all SPI CDC fixed."

**2026-08-29:** the interface limit is now 2 MHz. The canonical P&R and
signoff SDCs declare a 500 ns `SPI_SCK`, remove its blanket false path,
declare the SPI/core clocks asynchronous, and use SPI-relative zero-board-delay
MOSI/MISO constraints. This is an ASIC-only baseline, not board signoff.

**2026-09-05 CDC review — risk split and acceptance boundary.** The ordinary
SPI framing and persistent-toggle paths are sound at RTL under the 2 MHz
contract; the current standalone protocol suite passes 6/6, including
randomized legal/aborted frames, burst wrap, MISO byte atomicity, deselected
clocks and command-only recovery. That simulation cannot model metastability,
and two structural gaps remain:

1. `spi_slave.v` loads `miso_shreg` directly from the combinational
   `reg_bank` peek bus on `negedge SPI_SCK`. Configuration registers and fixed
   IDs are stable and therefore low risk, but live 32 MHz status can change
   inside the sampling aperture. A volatile byte can be metastable or
   incoherent even though the address had the full 250 ns half-period to
   decode. The byte-atomicity test changes data only after the load edge, and
   the formal checker declares `SPI_MISO`/`reg_rdata` as ports but does not
   assert read-data correctness, so neither closes this case.
2. `spi_wr_addr_lat`/`spi_wdata_lat` and `spi_re_addr_lat` are bundled data
   crossing beside the synchronized toggles. The architecture gives them
   ample settling time, but the signoff SDC's asynchronous clock grouping
   false-paths the crossings and there is no mailbox max-delay/bus-skew check
   or reviewed `ASYNC_REG` placement contract. `HOST_CS` recovery/removal and
   CS-to-SCK timing are also false-pathed rather than bounded by a board
   interface requirement.

**Risk decision:** it is defensible to treat the *deployment consequence* as
Low only with an explicit host-software contract: poll volatile flags rather
than acting on one sample; read multi-byte/live status twice and accept it only
when both copies match; read training/Z results only after the completion flag
has frozen them; and tolerate an extra poll for `DBG_BUSY`, packet phase and
similar state. This does not make the RTL "CDC clean." Without that firmware
contract, the volatile-read path remains a real intermittent register-
corruption risk and this High-section item stays open.

The P&R SDC deliberately omits the `SPI_SCK` clock to suppress its CTS tree;
the separate signoff SDC restores the 500 ns clock and zero-board-delay
MOSI/MISO constraints. Its asynchronous `SPI_SCK`/`IQ_CLK` clock group still
hides the core-to-SPI read snapshot and bundled mailbox crossings described
above.

The most critical read path has half an SCK period: the command address
completes on its eighth rising edge, the asynchronous `reg_bank` peek decode
must settle, and the MISO shifter loads on the following falling edge (250 ns at
2 MHz, before pad/PCB/host margin).

**Risk:** a design that passes the current top-level timing reports can still
return an occasional corrupt volatile status byte, or fail register reads or
writes at the specified 2 MHz after real pad/PCB timing is included.

**Action:** choose and document one closure route for volatile reads: preferably
snapshot `reg_rdata` in the core domain and return it through a stable
mailbox/handshake before the first MISO data bit; otherwise formally accept the
firmware retry/double-read contract above as a protocol limitation. In either
case, constrain and review the bundled mailbox settling path, add explicit
synchronizer placement intent, constrain `HOST_CS` recovery/removal and legal
CS-to-SCK timing, replace zero-delay MOSI/MISO assumptions with Raspberry Pi +
PCB + GF180-pad numbers, and run all-corner setup/hold plus an unconstrained-
endpoint/CDC review.

**2026-09-05 — Route 2 chosen and documented for this revision.** The
firmware two-transaction confirm-read contract is now normative: spec
`TRPR-SPS-012`, `planning/Register Map.md` § *Host SPI read coherency —
firmware contract* (per-register volatile/static/frozen classification + the
confirm-read rules), `planning/Firmware Spec.md` § Primary firmware inputs.
**It is a probabilistic mitigation, not a hardware coherency guarantee** —
the MISO register directly samples the async multi-bit core value with no
synchroniser; two agreeing *independent* reads (separate command+data
transactions, `HOST_CS` toggled between) lower the odds of accepting a torn
byte but cannot prove coherency or remove metastability. Residual CDC risk on
volatile reads stays under this item. It is genuinely coherent only for
**frozen** registers read with a stable address after their completion flag
(nothing in the core is changing). Route 1 (on-chip core-domain read snapshot,
a real guarantee) was prototyped and set aside: it regressed the
`spi_cdc`/`spi_slave` suites with a one-byte MISO pipeline shift and, done
naively, pulls the wide `reg_bank` peek mux onto a 31.25 ns IQ_CLK arc at the
SS corner — a timing-safe version needs a new CE-gated MCP group in the audited
signoff SDC. Left as a post-tapeout option. **Still open under this item:** the
bundled-mailbox settling constraint, synchronizer placement intent,
`HOST_CS`/CS-to-SCK board timing, real pad/PCB MOSI/MISO numbers, and the
all-corner/CDC review — Route 2 does not close those.

**See:** Open Risk #15; #54 (GLS/SDF); #61 (`spi_slave` formal BMC failure);
`src/control/spi_slave.v`; `src/config/pnr_32m_scoped_v25_b6.sdc`;
`planning/spi-slave-cdc-and-10mhz-timing-plan.md`;
spec `TRPR-SPS-012` / `TRPR-WGN-002`.
**Found:** 2026-07-11; re-scoped to 2 MHz on 2026-08-29; CDC risk split reviewed
2026-09-05; Route 2 contract documented 2026-09-05.

### 54. Host-SPI post-route GLS/SDF check is missing

The 2 MHz SPI timing constraints and all-corner STA establish the timing
contract, but no gate-level simulation has exercised the final routed
`trouper_top` netlist with annotated interconnect/cell delays.  RTL simulation
cannot expose a netlist/model integration error, reset/X propagation difference,
or an edge-ordering error at the SCK-domain/core-domain boundary.  Conversely,
one SDF simulation is **not** timing signoff: STA remains authoritative for
all setup/hold paths and PVT corners.

**Risk:** a routed-netlist or SDF-model issue can make a minimum-spacing host
SPI transaction fail on silicon despite clean RTL tests and STA, particularly
the minimum `CS_N` high interval and the first `MISO` bit after a read command.

**Action / exit:** after the tapeout-candidate P&R run has clean STA/DRC/LVS,
create a reproducible Icarus/Verilog gate-level harness using its final routed
Verilog netlist and the matching post-route SDF.  Run the `SPI_SCK` period and
I/O delays from the candidate signoff SDC, then pass directed cases for reset
release, minimum-spacing write/read transactions, the minimum `CS_N` gap, and
the first read-data bit.  Check readback and accepted writes against the RTL
contract, accounting only for the documented gate/pad latency.  Record the
run directory, netlist/SDF checksums, simulator version, and annotated corner;
repeat whenever the tapeout netlist, SDF, SPI RTL, or SPI constraints change.

**See:** `planning/verification-plan/spi-slave-verification-plan.md` test 18;
Open Risk #38; `src/control/spi_slave.v`; `src/config/pnr_32m_scoped_v25_b6.sdc`.
**Found:** 2026-08-30, post-P&R signoff review.

### 40. SS wall is several stacked problems, not one — root-caused 2026-07-12 by direct netlist/STA cross-check

**Root-cause pass complete.** Traced every major violator cluster in job
3367's `max_ss_125C_3v00/max.rpt` (`RUN_2026-07-12_21-56-16`) against
`final/nl/trouper_top.nl.v` (Q-net names of each startpoint/endpoint flop).
The original framing of this item ("`rb_bw_sel`/`rb_sf_cfg` fanout into
`sc_detector`") was directionally right but incomplete — the wall is
actually five distinct, separately-caused clusters:

| Startpoint (traced) | Violator count | Destination (traced) | What it is |
|---|---|---|---|
| `u_psram.state[0:1]` | 273 | `rpl_valid`, `u_psram.sub`, `u_psram.dbg_buf` | **the pre-existing `u_psram` QSPI decode residual item 1 has cited since before #39/#40 existed** — `u_psram` was never in `paced_nets`; the fix has always been a 1-cycle-ahead pipeline (item 1), not an MCP relaxation, and it's still not implemented |
| `rb_bw_sel` | 200 | `u_sc.eval_step`, `u_sc.mul_start` | config reg → sc_detector's serialized eval FSM. Wildcard-miss (see below) |
| `Zpair_i[*]/Zpair_q[*]` | 135 | (training_acc) | not previously characterized at all |
| `ce_16m` | 64 | — | 16 MHz clock-enable, broad fanout; not previously characterized |
| `packet_active` | 54 | `u_sc.acc_ci0` | **the single worst path, −16.01 ns — fully traced below** |
| `timing_ref[7]` | 46 | `u_pcfsm.acq_timeout_q` | this is the write-arc dishonesty item 39 already flagged as "confirmed real, not yet fixed" — showing up in the raw violator count too |
| `dcr_valid` | 26 | — | dc_removal; not previously characterized |

**The worst path, fully traced:** `_61285_` (`.Q(packet_active)`, the
`packet_ctrl_fsm` top-level flop) → net `packet_active` → 4 more hops,
2 of which survive named (`packet_done_pulse`) and the rest anonymized
(`_05436_`, `_06213_`, `_22787_`, `_23679_`, `_03962_`) → `_62498_`
(`.D(_03962_)`, `.Q(u_sc.acc_ci0[19])`). **Confirmed root cause:** the
`paced_nets` MCP=3 relaxation (`pnr_32m_scoped_v20.sdc:184-187`, `-through
[get_nets -hierarchical {u_dec.* u_sc.* u_tacc.* u_comb.*}]`) never touches
this path — every intermediate net between the two registers is either a
**top-level** net (`packet_active`/`packet_done_pulse` are declared in
`trouper_top.v`, sourced from `packet_ctrl_fsm`, not `u_sc.*`-prefixed) or
fully anonymized by synthesis. The endpoint register's own *output* net
happens to be named `u_sc.acc_ci0[19]`, but that's downstream of the
violating arc, not part of it — the D-pin's driving net (`_03962_`) has no
`u_sc.` name to match. **This confirms hypothesis 1 from the original #40
write-up** (wildcard silently not applying), not hypothesis 2 (budget too
small) — same "-through wildcard misses a cross-boundary/optimized-away net"
bug class as v8, v19, and the v20 `rb_sc_hits_req → timing_ref` miss (item
39's history). The `rb_bw_sel → u_sc.eval_step/mul_start` cluster (200
violators) is the same failure mode: `rb_bw_sel` itself is a top-level net,
not `u_sc.*`-prefixed, so `-through u_sc.*` never matches it either.

Not a new bug in the RTL sense for the `u_psram`/`rb_bw_sel`/`packet_active`
clusters (33 violators at −22.1 ns existed in the July 5 baseline,
`RUN_2026-07-05_00-56-34`, same 1200×1100/88% config) — but the violator
count has grown to 1000+ at −16.01 ns (job 3367, 2026-07-12) with the same
die/density, most plausibly from RTL added since (the PSRAM continuous-delay
replay redesign touches `sample_shift`/`packet_active` consumption heavily).

**Action:** generalize the fix pattern that already worked for item 39 (job
3367): replace the blanket `-through <hierarchy-wildcard>` with `-to
<get_cells -of_objects [surviving Q-nets] -filter {ref_name =~ *dff*}>`,
scoped per real quasi-static source, for each of: `rb_bw_sel →
u_sc.eval_step/mul_start`, `packet_active → u_sc.acc_ci0/acc_cq0` (and
siblings). The `u_psram.state` cluster is out of scope for an SDC fix — it's
item 1's original pipeline-fix residual. `Zpair_*`/`ce_16m`/`dcr_valid`
clusters are uncharacterized — need their own trace pass before deciding
MCP-relaxation vs. real RTL fix.

**2026-07-13 update — jobs 3370/3371 back; CE-retimer wins this round, v23
found an 8th cone:**

(1) v23 (job 3370, SDC-only fix for `rb_sf_cfg`/`rb_bw_sel` →
`u_sc.timing_ref`, the fifth missed cone) **made WNS worse: −17.16 ns**
(vs job 3368's −16.60 ns), DRC=0/LVS=0 clean. Closing `timing_ref` unmasked
a **sixth** missed cone nobody had traced before: `packet_ctrl_fsm.v:46-49`
has its own separate `M_val` register (`M_val <= 1 << (sf+sample_shift)`),
computed redundantly from the same `sf`/`sample_shift` operands as
`sc_detector`'s `M_val`, recomputed unconditionally every cycle, and never
covered by any of v21/v22/v23's scoping (`rb_sf_cfg → u_pcfsm.M_val[15]` is
now the worst path). Same whack-a-mole pattern as every prior round — one
more per-consumer SDC gap found only after the previous one stopped masking
it.

(2) The CE-retimer (job 3371, branch
`worktree-ce-gated-quasi-static-retimer`, independent div-4 enable — see
`planning/ce-gated-quasi-static-retimer-experiment.md`) **clearly wins**:
WNS **−16.07 ns**, essentially back to the original unfixed baseline
(−16.01 ns, job 3367), and — the important part — its worst path is `u_psram.sub[3] → ...`, the
**already-known, already-characterized** item-1 QSPI-decode residual, not a
newly-exposed cone. Retiming the source once absorbed the `rb_sf_cfg`/
`rb_bw_sel`-driven violators (including the `M_val` one that just hit v23,
since `packet_ctrl_fsm` in this branch reads the retimed `rb_sf_cfg_q`)
without needing to individually re-scope every consumer. **Job 3371 finished
DRC=0/LVS=0 clean** (elapsed 00:31:14) — same signoff bar as every other run
this session; the timing result is confirmed, not provisional.

**Recommendation:** adopt the CE-retimer
approach over continued per-consumer SDC patching, and extend it to
`rb_pkt_timeout_syms`/`rb_tacc_window_syms`/`rb_sc_hits_req` (same shape:
quasi-static `reg_bank` source, multiple consumers, same wildcard-miss risk
class). The `u_psram` residual remains the real, harder, separately-tracked
problem (item 1) — a throughput-bound pipeline fix, not an MCP/retiming
question.

**2026-07-13 update — extension CONFIRMED (jobs 3387–3400): recommendation
adopted and verified, still unmerged.** Folded `rb_sc_hits_req`,
`rb_pkt_timeout_syms`, `rb_tacc_window_syms` into the same `ce_8m`-gated
retimed bus and added an explicit `u_pcfsm.M_val` SDC endpoint (the cone that
broke v23). Full 12-suite cocotb regression (jobs 3388–3399) all PASS, plus
the SF/BW startup sweep (job 3387, 18/18 PASS) — no functional regression.
P&R signoff (job 3400, `ol_trouper_top/runs/RUN_2026-07-13_01-57-28`):
**DRC=0/LVS=0 clean, post-PNR SS WNS = −14.71 ns** — the best number in this
item's entire history (better than the base retimer's −16.07 ns/job 3371,
both SDC-only attempts −16.60/−17.16 ns, and the original unfixed baseline
−16.01 ns/job 3367). Worst path startpoint is `psram_qe_init_done`, still the
same already-characterized `u_psram` QSPI-decode residual (item 1) — closing
the extra three sources did not expose a ninth cone. The whack-a-mole class
of bug this item documents is fully absorbed by the retimer for every
`reg_bank` quasi-static source now in scope; only `u_psram`'s throughput-bound
pipeline fix remains.

**See:** `src/frontend/sc_detector.v`; `src/config/pnr_32m_scoped_v20.sdc`
(`paced_nets` wildcard); item 39; item 1;
`planning/ce-gated-quasi-static-retimer-experiment.md`.
**Found:** 2026-07-12 (v21 SDC signoff run, job 3367).
**Root-caused:** 2026-07-12 (direct netlist + STA violator-report
cross-check, `RUN_2026-07-12_21-56-16`).
**Extension verified:** 2026-07-13 (jobs 3387–3400).

**2026-07-18/19 addendum (mechanism found):** across the B4/B6 area-cut
signoff runs the `packet_active → packet_done_pulse → u_psram.*` cone swings
−3…−8 ns ↔ −22 ns for the same arcs between runs. Stage detail of the bad
run: 45 of 60 ns in four under-driven stages (x1 cells left at fanout 25–39,
slews 8–17 ns) — repair_design's DRC-driven upsizing is a cap-threshold knife
edge at the repair corner, so any nearby placement perturbation flips it.
Three consecutive runs produced three different chronic worst cones
(`rb_sf_cfg → M_val` / `packet_active → psram` / `u_remod.s3`): single-run
WNS at 88 % util measures the repair lottery, not the RTL delta. Fix
direction = deterministic fanout treatment (RTL split per the
sc_lock → timing_ref pattern, or max_transition SDC) on the chronic nets;
`u_psram` endpoints remain item 1's pipeline. See
`planning/b4-b6-area-cuts-2026-07.md` §4.

**2026-07-26 correction:** the main deterministic fanout treatment has since
shipped: commit `3af9619` split `packet_active` fanout and registered
`packet_done_pulse` (merged by `b47474d`), eliminating that chronic cone in
the B6 measurements and improving WNS from −25.5 to −15.9 ns at about +10.3 k
µm² area churn. A pulse-only A/B variant was worse due to synthesis remapping
sensitivity. Remaining closure work is the `u_psram` pipeline in item 1 and
the still-uncharacterized `Zpair_*`, `ce_16m`, and `dcr_valid` cones; single
run WNS should still be treated cautiously at this density.

---

### 41. Hold signoff corner pulls the wrong RCX deck; the corrected (min_ff) config fails routing at signoff density — **CLOSED 2026-09-04 (exit run clean)**

> **CLOSED — the one-run exit passed.** Job 5530 applied the `RCX_RULESETS`
> override (`max_ff_n40C_3v60` → `rules.openrcx.gf180mcuD.min`, `STA_CORNERS`
> unchanged — no corner rename) to the canonical 1675×1110 / 65 % A40 config
> (`src/config/trouper_top_minff_rcx.json` = canonical + that one key). Result on
> the current floorplan:
> - **Routes clean.** magic DRC 0, route DRC 0, LVS 0, XOR 0, antenna 0 net /
>   0 pin. **No `GRT-0116`, no `DRT-1231`, no `DRT-0073`** — the only "congestion"
>   log lines are routine `GPL-004x` placement stats (top-1 % ≈ 1.10). The
>   2026-07-18 congestion objection was measured on the retired 1200×1100 / 88 %
>   die and **does not reproduce** at 1675×1110 / 65 %.
> - **Hold MET against the real min-RC deck.** Hold WNS 0 at all three corners;
>   ff worst-slack +0.13 ns (unchanged vs the `.max`-deck baseline). RCX log
>   confirms `Using RCX ruleset '…rules.openrcx.gf180mcuD.min'` for the ff corner.
> - **SS setup slightly better, not worse:** WNS −11.34 ns / TNS −999 ns vs the
>   `.max`-deck baseline job 5527's −14.44 / −1009 (~3 ns improvement — the
>   honest optimistic-RC deck makes hold look less critical, so the resizer
>   over-buffers less; ff max-slew 4→0, ff max-cap 2→1). nom_tt / max_ff setup
>   still MET.
>
> **To adopt:** fold the `RCX_RULESETS` block into `src/config/trouper_top.json`
> (3 entries — nom→.nom, ss→.max made explicit, ff→.min). No RTL change, no SDC
> change. Config + wrapper staged at `src/config/trouper_top_minff_rcx.json` /
> `rtl-test/scripts/run_pnr_a40_minff_rcx.sh` (uncommitted). Run:
> `/srv/eda/runs/timothyn-dev/lora-mimo/5530/a40_minff_rcx/run`.
> The `.min` path is `/foss/pdks/gf180mcuD/libs.tech/librelane/rules.openrcx.gf180mcuD.min`
> (mechanism verified originally by job 3444; see `project_rcx_min_ff_ruleset_fix` memory).

`max_ff_n40C_3v60` extracts with a `.max` RCX ruleset, so hold is checked
against pessimistic-setup RC, not true min-RC. The working fix is an
`RCX_RULESETS` override to add a real `min_ff_n40C_3v60` corner — renaming
the corner instead breaks P&R (jobs 3423/3426). **New 2026-07-18:** the
carrier config (`config_current_signoff_minff.json`) **fails GRT-0116
congestion** at 1200×1100/88 % (job 3464) — min_ff hold buffering pushes the
design past routability, while the plain max_ff config routes clean. The RCX
fix is therefore currently unusable at signoff density; needs either lower
util, a smaller hold-fix scope, or die growth.

**2026-08-30 — the ruleset half is still true; the congestion half is stale evidence.**
Signoff still extracts hold against a `.max` RCX deck, so the underlying problem is
unchanged and this item stays open. But the "corrected config fails routing" verdict
was measured on a floorplan that no longer exists: job 3464 ran
`config_current_signoff_minff.json` at **1200×1100 / 88 % density**, whereas the
adopted floorplan is now **1675×1110 / 65 %** (`config_1675_c5_diodepad4.json`,
job 5198) — a much larger die at far lower density, with correspondingly more room
to absorb min_ff hold buffering. The GRT-0116 argument has not been retested there;
the C5 config still carries `max_ff_n40C_3v60`, not the `RCX_RULESETS` min_ff
override.

**Exit (one run):** apply the `RCX_RULESETS` min_ff override to the C5
1675×1110 / 65 % config and re-run. If it routes, the congestion objection is
retired and hold can be signed off against a real min-RC deck; if it still hits
GRT-0116, the item is confirmed on the *current* floorplan rather than a retired one.

**See:** `rtl-test/ol_trouper_top/config_current_signoff_minff.json`;
`rtl-test/ol_trouper_top/config_1675_c5_diodepad4.json`;
`planning/b4-b6-area-cuts-2026-07.md` §4;
`planning/antenna-closure-investigation-2026-08.md` (C5 adoption).
**Found:** 2026-07-15 (ruleset), 2026-07-18 (congestion, job 3464);
congestion evidence marked stale 2026-08-30.

---

### 58. The in-flow KLayout DRC gate is vacuous — signoff runs out of flow instead

`RUN_KLAYOUT_DRC` is `True` but `KLAYOUT_DRC_RUNSET` is unset, so
`67-klayout-drc` exits in 11 ms with no report and no metric, and
`69-checker-klayoutdrc` *passes* because the metric is absent rather than zero —
true of every run in this design's history. Run standalone against job 5379's
GDS, the PDK deck gives **62/63 tables at zero violations** (job 5384, `contact`
included); the 63rd (`mslot`) crashed on a PDK deck bug — `layers_def.drc` never
defines `contact`/`via1`/`via2` for that table, so it left an empty report reading
as "0 items". With three whitelist entries added, job 5391 runs `mslot` too:
**all 63 tables ran at zero violations** — the first genuine KLayout DRC signoff
in this design's history — so no rule needs waiving. Note that
`run_drc.py` prints "Klayout DRC run is clean. GDS has no DRC violations." even
on runs that lost a table to an exception (5384, 5386) — its own verdict is not a
signoff signal. Magic DRC, Netgen LVS, KLayout XOR and router DRC were all
genuinely running throughout.

**2026-09-03 — the shipped GDS now has a genuine pass (job 5415).** Everything
above was measured against job 5379's GDS, which is neither the current netlist
nor the geometry that ships: `final/gds/trouper_top.gds` is job 5413's streamout
*plus* the A40 power bridges, so the bridges had never been DRC'd at all. Job
5415 ran the full deck against that exact file (md5 `f0e740b4…`, asserted in the
job log): **63/63 tables ran, 0 reports missing, 0 truncated, 0 exceptions, 0
violations** — verified independently of the script's own verdict by counting
`<item>` across all 63 `.lyrdb` files and confirming each carries a closing
`</report-database>`. The bridge geometry is clean. Cost: 2 h 14 m, of which
`contact` was 67.6 min and `metal1` 45.2 min.

**Correction to the closing need stated above (2026-09-03).** `KLAYOUT_DRC_RUNSET`
*cannot* host `klayout_drc_guarded.sh`. LibreLane's step runs the runset as
`klayout -b -zz -r <script> -rd input=… -rd topcell=… -rd report=…` and parses a
single `.lyrdb` into `klayout__drc_error__count`
(`librelane/steps/klayout.py:486-540`). The GF180 deck is not that shape: it is a
Python driver (`run_drc.py`) that fans out into 63 tables and 63 reports. A bash
wrapper around it cannot be substituted for a `.drc` script, so the original
sentence described something that does not exist.

**What was done instead:** `RUN_KLAYOUT_DRC` is now explicitly `false` in
`src/config/trouper_top.json`. A gate that cannot run should not report a pass;
disabling it converts a silent false negative into an honest absence, and signoff
moves to the out-of-flow guarded run recorded above.

**This makes KLayout DRC a MANUAL gate — the standing obligation.** Nothing in
the flow re-runs it. Any change that alters the GDS — a new P&R run, or
re-running `tools/build_a40_pdn_bridges.py` — silently invalidates the job-5415
result, which will still be sitting in the config and `final/README.md` looking
current. The md5 is recorded in both places for exactly this reason: check it
before trusting either. A changed GDS needs a full 63-table run; the `TABLES=`
subset does **not** satisfy this and reports `PARTIAL` so it cannot be mistaken
for one. This is the cost of turning the gate off, and it is a live risk of the
result going stale unnoticed — which is why this item stays open.

**Still open:** the untested alternative is pointing `KLAYOUT_DRC_RUNSET` at the
PDK's monolithic `libs.tech/klayout/tech/drc/gf180mcu.drc`, which *is* the right
shape for the step. Nobody has checked whether it honours `input`/`topcell`/
`report`, nor whether it dodges the `mslot` bug (running whole-deck, `TABLE_NAME`
is not `mslot`, so it plausibly does). It would also add hours to every P&R,
which is likely disqualifying for a default gate. Signoff also still depends on a
locally patched `layers_def.drc` until the PDK is fixed upstream — the bug makes
`mslot` unrunnable for any gf180mcuD design, so it is worth reporting there. See
`planning/pdn-thickening-and-core-ring-2026-09.md` §6-§7.

### 60. The Grouper/AHB removal has never been functionally simulated

The 2026-09-01 removal of the `GRP_*` bus, the AHB-Lite `H*` endpoint and
`IRQ_GROUPER` from `src/top/trouper_top.v` has been proven to **synthesise,
place and route** — jobs 5378/5379/5392/5394/5413 all built the resulting
35300-cell netlist cleanly, and job 5415 DRC'd the shipped GDS. **None of that
is functional verification.** Every regression job number cited across the
verification plans (3863, 3868, 3879, 3883, 4674, 4843, 4845, 4858 …) predates
the removal and ran against a netlist that still had the arbiter in it.

**Why this is not merely bookkeeping.** The change was not confined to deleting
unused ports; it altered the live register access path:

- `rb_re` is tied to `1'b0` and `rdata`/`ready` are left unconnected, so
  synthesis drops `reg_bank`'s `read_valid` state and its output register. Host
  SPI reads now depend **entirely** on the combinational peek tap.
- The arbiter collapsed to a sequencer. The one-entry SPI pending slot is no
  longer a fallback behind a priority mux — it is the only write path.
- The PSRAM debug byte ports (0x76 pop / 0x79 push) lost one of their two
  sources and now rest solely on the SPI one-shot strobes.

A defect in any of those is a broken control plane, which on this chip means an
unusable part — the host cannot configure `SF_CFG`, commit weights, or service
PSRAM. It would not show up in DRC, LVS or timing, all of which are clean.

**Also unverified: the benches were edited in the same pass.** `test_spi_cdc.py`
lost 178 lines (the two `test_grp_*_addr_change_during_miso_shift` cases),
`cocotb/hdl/tb_trouper_cocotb.v` lost 61, `tb_array_pair.v` 39, and
`test_dbg_write.py` lost its Grouper-sourced cases. Those edits have not been
executed either, so a bench that no longer elaborates would currently look
identical to one that passes — nobody has run it. Note `tb_trouper_grp_arb.v`
was deleted outright, so the coverage it held (rows retired as VOID in the
spi-slave and reg-bank plans) is genuinely gone rather than relocated.

**Closing needs:** run the core cocotb regression against the current tree
(`SUITE_GROUPS=core`, plus the Icarus `sim_trouper_all` target — per
[[project_verilator_hides_use_before_declare]] the Icarus suites are the real
Verilog-legality gate, and Verilator will not catch a use-before-declare that
the removal may have introduced). Record the job number here. Until then the
functional status of the current netlist is **unknown, not good**.

**2026-09-03 — core cocotb regression run (SGE job 5471, Verilator): 41 / 42
suites PASS.** Every Grouper-removal-sensitive suite is green —
`trouper_top`, `spi_slave`, `spi_cdc`, `w_missed`, `w_shadow_lock`,
`host_only_e2e`, `dbg_write`, `dbg_write_collision`, `dbg_amask_wrap`,
`psram_ops`, `qspi_owner`, plus the peek-tap read path exercised throughout.
The one failure is **`reg_bank` / `test_reserved_addresses_zero_and_ignored`**:
`0x06` is asserted reserved but is now the live `DBG_CTRL1` register added by
the `pinout/dbg1-shared-irq-pad-27` work — a stale reserved-address list, not a
Grouper-removal regression (tracked as a follow-up: update the reserved set in
`cocotb/tests/test_reg_bank_rw_map.py`). **Still owed:** the Icarus
`sim_trouper_all` Verilog-legality pass.

**Found:** 2026-09-03, while assessing PR #51 for merge.

### 61. SC-detector full-symbol accumulators overflow and the delayed-energy snapshot drops the boundary sample — CLOSED 2026-09-03 (32-bit widen + M-dependent saturating snapshot; regression + A40 P&R clean)

> **CLOSED 2026-09-03.** Fixed on `rtl/open-risk-fixes` (commit `a844409`):
> `acc_*`/`sym_*` widened 24 → 32-bit signed, snapshot changed to the
> arithmetic M-scaled saturating `sat13(acc >>> (sf + sample_shift + 2))`,
> `acc_E0del` forward-combined at the symbol boundary. Verified:
> `cocotb/sc_acc_overflow/` 5/5 (was 1/5), SF7–SF12 × BW sweep + `sc_ant_sel`
> + `sc_dbg` PASS, full `core` + `capture` regression SGE job 5496
> (`sc_acc_overflow` promoted into the `core` group). A40 P&R SGE job 5499
> (`src/config/trouper_top.json`, rebased onto `pinout/dbg1-shared-irq-pad-27`):
> signoff-clean (DRC 0, LVS 0, XOR 0, antenna 0/0), SS setup WNS −10.77 ns /
> TNS −370.4 — between reference runs 5379 (−10.13) / 5378 (−11.17), TNS beats
> 5379's −383.5; no regression from the accumulator widening. Full P&R
> write-up in #66.

`src/frontend/sc_detector.v:141-160` supports `M = 128..16384` but keeps
`acc_ci0`/`acc_cq0`/`acc_E0cur`/`acc_E0del` as signed 24-bit values.  A
full-scale complex sample contributes up to 32768 energy counts, exhausting
that signed range in 256 samples; even under the documented 90-count AGC
operating point, the higher-SF full-symbol windows overflow.  The subsequent
signed snapshot `acc_*[22:10]` (`:379-381`) discards the real sign bit `[23]`,
so a positive accumulator above `2^22-1` is interpreted as negative before
the 24-bit accumulator itself wraps.  This can suppress or corrupt every
Schmidl-Cox hit at otherwise legal SF/BW/amplitude combinations and contradicts
TRPR-SCD-001/003's full-`M` contract.  The 24-bit headroom comment at the top of
the module still assumes the deleted 128-sample correlator.

There is a separate last-sample error in the same block: at TDM step 7,
`acc_E0del` is incremented and snapshotted with nonblocking assignments on the
same edge (`:365-396`).  `eval_E0del` therefore receives the old accumulator,
without the completed symbol's final delayed-energy contribution, after which
the working accumulator is cleared.  Correlation and current-energy terms are
updated at earlier TDM steps and do not share this particular omission.

**Required fix/evidence:** re-derive the accumulator, snapshot, serial-multiply,
and metric widths as one numeric pipeline for `M=16384`; include signed-range
proofs and directed boundary tests at the highest legal amplitude.  Snapshot
the final delayed-energy sum, not the pre-update register.  Re-run the full SF/BW
SC detector and measured-capture regressions after the width change.

**2026-09-03 — CONFIRMED by directed bench `cocotb/sc_acc_overflow/`
(unit-level, TOPLEVEL = `sc_detector`; SGE job 5474).** `test_baseline_sf7_no_overflow`
PASSES (M=256, no overflow, `sc_lock` fires). Failing cases, all four
sub-findings:
- `test_sf9_energy_snapshot_sign_flip` — M=1024, cur==del==(90,90): `acc_E0cur`
  dips to **−8 385 616** mid-symbol (true running sum +16 588 800) and the
  `eval_E0cur` snapshot reads **−184**.
- `test_sf9_amp64_lock_never_fires` — M=1024, amp=64: `acc_E0cur` peaks at
  exactly **2^23**, `eval_E0cur` snapshot = 0, **`sc_lock` never asserts** for a
  clean strong preamble.
- `test_e0del_drops_boundary_sample` — M=64, cur==del every sample:
  `eval_E0cur`=21 vs `eval_E0del`=**20** (step-7 same-edge NBA drops the last
  sample).
- `test_sf10_accumulator_true_wrap` — M=2048, amp=90: raw 24-bit `acc_E0cur`
  wraps past 2^24, never reaches the true +33 177 600.

**2026-09-03 — AFE scaling measured (`sim/models` decimator + LoRa preamble,
scratch `afe_scale2.py`).** The decimator is ~unity gain: at the −3 dBFS AGC
ceiling the `sc_detector` int8 input peaks at ~90 counts. `acc_E0cur` per
symbol vs 2^23: SF7–SF11 safe at every AGC setting (SF11 ~4× margin at the
ceiling); **SF12 overflows** — SF12/BW250 sign-flips at ~51-count signal and
hard-overflows above ~70; SF12/BW125 is borderline at the minimum useful
signal and overflows above it. So the fix is required for SF12 support.

**FIXED 2026-09-03 (branch `rtl/open-risk-fixes`) — option A (widen +
M-dependent snapshot shift).** `src/frontend/sc_detector.v`:
- `acc_ci0/acc_cq0/acc_E0cur/acc_E0del` and `sym_ci0/sym_cq0` widened
  24 → **32-bit signed** (one-symbol abs max ≈ 2^29, ~4× headroom; never wraps).
- Snapshot changed from the fixed non-arithmetic `acc[22:10]` slice to
  `sat13(acc >>> (sf + sample_shift + 2))` — **arithmetic** (sign-preserving),
  **M-scaled** so the 13-bit `eval_*` operand stays ~constant magnitude at every
  SF, and **saturating** at 13-bit for overdriven symbols (same graceful-
  degradation policy as #63). `K=2` keeps SF7/BW250 at the historical `>>10`.
- `sc_thr` is **unchanged and remains a single value for every SF/BW** — the
  threshold comparison is a k²/k² ratio, invariant under the shift.
- `acc_E0del` is forward-combined at the symbol boundary so the snapshot
  includes the final sample (was dropped by the step-7 same-edge NBA).
Blast radius was just `sc_detector.v` — `sim/models/sync.py` is a float
behavioural model and never modelled the fixed-point snapshot, so no model
change. Verified: `cocotb/sc_acc_overflow/` 5/5 PASS (was 1/5), `mcp_sc_settle`,
`trouper_top` SF7–SF12 × BW sweep, `sc_ant_sel`, `sc_dbg` PASS — full `core` +
`capture` regression SGE job 5496 (`sc_acc_overflow` now in the `core` group);
SS timing re-check on `ol_trouper_top` — **A40 P&R SGE job 5499**
(`src/config/trouper_top.json`, rebased onto `pinout/dbg1-shared-irq-pad-27`):
signoff-clean (DRC 0, LVS 0, XOR 0, antenna 0/0), SS setup WNS −10.77 ns /
TNS −370.4, between reference runs 5379 (−10.13) / 5378 (−11.17); TNS beats
5379's −383.5. No signoff regression from the 32-bit accumulator widening.
See #66 for the full P&R write-up.

**Found:** 2026-09-03 full `src/` RTL review; static analysis, reproduced by
`cocotb/sc_acc_overflow/`; fixed same day.

### 62. IDLE `W_COMMIT` splits controller and top-level `W_valid` state — **CLOSED 2026-09-04**

> **CLOSED — one authoritative `W_valid`, verified.** Fixed on
> `rtl/open-risk-fixes` (merged to `main` via PR #53): `packet_ctrl_fsm.v`
> promotes its internal `W_valid` to a module output (`:28`), and `trouper_top.v`
> deletes its own `W_valid_set`-pulse reconstruction, sourcing the single FSM
> level for the combiner, the `reg_bank` live-weight write-lock, and
> readback/debug. An IDLE-committed vector now legitimately applies to the next
> packet (combined, no false `W_MISSED_PACKET`). Verified: `cocotb/w_valid_split/`
> PASS (SGE job 5477), `packet_ctrl_fsm` formal PASS by k-induction (job 5479),
> full `core` cocotb regression (job 5476), A40 P&R signoff-clean (jobs 5499 /
> 5511, DRC/LVS/XOR/antenna/hold). Strengthens item 13's safety claim rather
> than weakening it. Detail retained below.

`packet_ctrl_fsm.v:122-184` deliberately accepts a commit in any state and
retains its own sticky internal `W_valid`.  `trouper_top.v:758-763` separately
reconstructs another `W_valid` from the one-cycle `W_valid_set` pulse, then
clears that copy whenever `packet_active=0`.  A commit consumed sufficiently
before the next packet therefore makes the top-level copy high for only one
idle cycle and leaves the FSM copy high.  On the next packet the FSM believes
weights are valid and can suppress `W_MISSED_PACKET`, while the combiner still
sees top-level `W_valid=0` and remains in bypass.  The same top-level copy drives
`reg_bank`'s live-weight write lock, so shadow writes can also be accepted while
the FSM believes the committed vector is valid.  This weakens the safety claim
in item 13.

The existing “commit before packet / in IDLE” test is standalone at the
`packet_ctrl_fsm` boundary and therefore checks only the internal copy; it
cannot observe the split introduced by `trouper_top`.

**Required fix/evidence:** make one register authoritative (preferably export
the FSM's `W_valid` level) and use it for the combiner, register readback, and
write lock.  Add a top-level regression that commits in IDLE, waits several
idle cycles, starts a packet, and checks combiner selection, miss status, and
weight-write rejection through packet end.

**2026-09-03 — CONFIRMED by directed bench `cocotb/w_valid_split/`
(top-level, TOPLEVEL = `tb_trouper_cocotb`; SGE job 5472).**
`test_idle_commit_then_unrefreshed_packet` commits a weight vector in
`ST_IDLE`, idles several symbols, then locks a packet with no fresh commit.
Result: **`u_pcfsm.W_valid` = 1 while `trouper_top.W_valid` = 0** — the packet
reaches `ST_PAYLOAD_ACTIVE` with `use_mrc_r` = 0 (combiner in bypass) and
**no `W_MISSED_PACKET`** (the stale FSM copy suppresses it). Neither
"combine with the committed vector" nor "declare it missed" happens.

**FIXED 2026-09-03 (branch `rtl/open-risk-fixes`).** `packet_ctrl_fsm.v`'s
internal `W_valid` reg is promoted to a module output; `trouper_top.v` deletes
its own `W_valid` reconstruction and sources the one authoritative level from
the FSM, feeding the combiner, the reg_bank live-weight write-lock, and the
readback/debug paths. An IDLE-committed vector now legitimately applies to the
next packet (combined, no false miss). Verified: `cocotb/w_valid_split/` PASS
(SGE job 5477); `packet_ctrl_fsm` formal PASS by k-induction (job 5479); full
`core` cocotb regression 41/42 incl. `w_missed`, `w_shadow_lock`,
`mcp_pcfsm_settle`, `trouper_top` (job 5476 — the one failure is the unrelated
stale `reg_bank` reserved-address test, fixed in the same branch).

**Found:** 2026-09-03 full `src/` RTL review; cycle-by-cycle static trace, now
reproduced by `cocotb/w_valid_split/`.

### 63. `training_acc` signed cross-pairs overflow at a legal 15-symbol window — **CLOSED 2026-09-04**

> **CLOSED — saturating accumulate, verified.** Fixed on `rtl/open-risk-fixes`
> (merged to `main` via PR #53): `training_acc.v` gains `sadd32`/`uadd32`
> saturating helpers (`:226-251`) applied to all 16 Z accumulate sites (6 complex
> `Zpair` + 4 `Zdiag` + `zdiag3_final`); a would-be wrap now clamps at
> `INT32_MAX/MIN` / `UINT32_MAX` so firmware weight computation degrades
> gracefully instead of reading a sign-inverted value. No readback / register-map
> / firmware change. `Trouper Chip Specification.md` §4.5 rewritten (normative
> "Z accumulator saturation" paragraph replaces the obsolete 8-symbol headroom
> note). Verified: `cocotb/tacc_acc_overflow/` PASS (`Zpair_i0` clamps at
> `INT32_MAX`, `Zdiag_0` stays monotonic — job 5477); `mcp_tacc_settle`,
> `tacc_window_clamp`, `noise_trig` bit-exact preserved at nominal levels
> (job 5476); A40 P&R signoff-clean (jobs 5499 / 5511). Detail retained below.

`TACC_WINDOW_SYMS` exposes 8..15 symbols and `M` reaches 16384, so the legal
maximum is 245760 accumulated samples (`training_acc.v:248-249`).  The six
complex cross-pair outputs are signed 32-bit accumulators (`:55-60`).

TRPR-MRC-009 bounds the per-branch *complex-envelope* amplitude
`sqrt(I^2+Q^2) <= 90` (−3 dBFS), not I and Q independently.  At that contract
point two equal-power phase-aligned branches add up to `90 x 90 = 8100` per
sample to a real cross-pair component, reaching ≈ 1.99e9 over the 245760-sample
window — only ≈ 8 % below the signed-int32 rail (2^31 ≈ 2.15e9).  Any AGC
excursion above −3 dBFS then wraps the accumulator negative and corrupts the
firmware MRC/eigenvector weights.  (Driving I and Q *each* to 90, i.e. envelope
≈ 127 / 0 dBFS — 3 dB hotter than the contract — gives 16200/sample ≈ 3.98e9
and wraps well inside the window; int8 full scale I=Q=127 wraps by sample
≈ 66 500, per the bench below.)  The unsigned 32-bit diagonals keep ≈ 2.16×
margin at the contract point and overflow only under sustained overdrive.  The
headroom note in the chip specification analysed only the reset-default
eight-symbol window and did not cover the register's legal maximum.

**Required fix/evidence:** either widen the Z accumulators/readback contract or
clamp `TACC_WINDOW_SYMS` to a value proven safe under an explicit component
amplitude bound.  Add maximum-window constant/correlated-vector tests plus a
noise-mode full-window stress test; document both signed cross-pair and unsigned
diagonal bounds in the chip specification.

**2026-09-03 — CONFIRMED by directed bench `cocotb/tacc_acc_overflow/`
(unit-level, TOPLEVEL = `training_acc`, noise mode; SGE job 5472).**
`TACC_WINDOW_SYMS`=15, SF12/BW125 (M=16384), branches 0 and 1 held at
int8 full scale (127,127):
- `test_zpair_i_overflows_within_legal_window` — `Zpair_i0` wraps to
  **−2 147 455 462 at sample 66 573** (of the 245 760-sample legal window).
- `test_zdiag_overflows_within_legal_window` — `Zdiag_0` wraps
  **4 294 959 152 → 24 114 at sample 133 145**.
Both match the predicted `2^31 / 32258` and `2^32 / 32258` bounds.

**FIXED 2026-09-03 (branch `rtl/open-risk-fixes`) — saturating accumulate, not
a window clamp.** At the TRPR-MRC-009 contract (per-branch envelope
`sqrt(I^2+Q^2) <= 90`, −3 dBFS) the full 15-symbol SF12/125 kHz window
(`n_acc = 245 760`) drives both `Zdiag` and each `Zpair` component to
≈ 1.99e9: `Zdiag` keeps ≈ 2.16× margin to `2^32`, but a **`Zpair` component
sits at ≈ 93 % of the signed `2^31` rail** — any AGC excursion above −3 dBFS
tips it over. (The measured-nominal `Zpair` ≈ 1470/sample / `Zdiag`
≈ 1730/sample cited earlier corresponds to an envelope ≈ 38 counts, ~12 dB
below the contract ceiling — not a safe-margin indication.) Overdrive (I=Q at
int8 full scale) wraps `Zpair` by sample ≈ 66 500. Rather than constrain a
legal input, `training_acc.v` gains `sadd32`/`uadd32` saturating helpers
applied to all 16 Z accumulate sites (6 complex `Zpair` + 4 `Zdiag`, plus
`zdiag3_final`): a would-be wrap now clamps at `INT32_MAX/MIN` / `UINT32_MAX`.
`Zdiag` (sum of squares) is monotone so a rail reading is a true "≥ 2^32";
`Zpair` is signed so a rail reading means only that a partial sum hit the
limit. The firmware weight computation degrades gracefully (bounded Z) instead
of reading a sign-inverted value. No readback / register-map / firmware change.
Verified: `cocotb/tacc_acc_overflow/` PASS — `Zpair_i0` clamps at `INT32_MAX`,
`Zdiag_0` stays monotonic (job 5477); `mcp_tacc_settle`, `tacc_window_clamp`,
`noise_trig` unaffected at nominal levels (job 5476, bit-exact preserved when
no saturation triggers).

**Spec updated (P2 review finding):** `Trouper Chip Specification.md` §4.5 —
the obsolete "Zdiag headroom note" ("8-symbol window … accepted; documented
rather than widened") is replaced by a normative "Z accumulator saturation"
paragraph stating the signed `Zpair` / unsigned `Zdiag` clamp values and
correcting the headroom arithmetic for the 8..15-symbol `TACC_WINDOW_SYMS`
range.

**Found:** 2026-09-03 full `src/` RTL review; arithmetic bound, now reproduced by
`cocotb/tacc_acc_overflow/`.

### 69. PSRAM QPI output pads launch on the same edge as the forwarded clock, and are unconstrained at signoff

`psram_buf_ctrl.v` drives `ce_n` / `sio_out` / `sio_oe` / `sck_en` from the
`always @(posedge clk_32m)` block (line 287) while `sck` is a bare
combinational gate of the core clock (`assign sck = sck_en & clk_32m`, line
282). Write data and CE# transitions are launched by the *same* edge the
PSRAM samples on — nominal setup/hold at the APS6404L is ~0 ns, met only by
accidental pad/board skew. The datasheet wants 2 ns data setup/hold, 3 ns CE#
hold, tCSP ≥ 2.5 ns (`resources/APS6404L_3SQR.pdf` p.23).

STA does not see it: `pnr_32m_scoped_v25_b6_signoff.sdc` has no PSRAM pad
constraints — no `create_generated_clock` on the SCK pad, no SCK-relative
`set_output_delay`. `PSRAM_SIO_*` / `PSRAM_CE_N` / `PSRAM_SCK` fall through
the generic `set_output_delay -max 2.0 -clock IQ_CLK $core_output_ports`,
an IQ_CLK→IQ_CLK model, not a source-synchronous one. Simulation misses it
too: `cocotb/hdl/psram_model.v` ignores `sck` and runs off `clk_32m`,
counting cycles from the CE# fall (header lines 14-18).

**Risk:** a replay-buffer QPI write / CE# path that passes top-level timing
and every existing sim can still fail data- or CE#-hold on silicon. Bounded
by degrade-to-bypass (#14) — a margin/functional risk, not a bringup blocker.

**Action:** move `ce_n` / `sio_out` to SCK **falling** edges, preload the
first command symbol before enabling SCK, terminate CE# in the SCK low
phase; add a pin-level PSRAM model driven by the real `sck`; add
`create_generated_clock` on the SCK pad plus SCK-relative `set_output_delay`
(SIO/CE#) and `set_input_delay` (read data) with PCB flight-time.

**See:** `src/control/psram_buf_ctrl.v:282,287`;
`src/config/pnr_32m_scoped_v25_b6_signoff.sdc`; `cocotb/hdl/psram_model.v`;
Open Risks #14, #38 (same class, Host SPI port).
**Found:** 2026-09-03 interface-timing review (applies equally to
`pinout/dbg1-shared-irq-pad-27` — the interface files are byte-identical).

**Fix landed 2026-09-03, reworked to a pad-boundary relaunch 2026-09-04.**
`trouper_top.v` relaunches the PSRAM `ce_n` / `sio_out` / `sio_oe` and the
SCK gate-enable (`psram_buf_ctrl.sck_en_o`, a new raw-enable output) onto
`negedge clk` at the pad boundary, and builds `PSRAM_SCK_OUT = sck_en_q &
clk`. CE#, SIO and SCK all change while SCK is low → the PSRAM samples a
stable bus on the SCK rising edge (~15.6 ns setup vs ~0); first command
nibble is on the same negedge as the SCK enable (half-cycle preload); no
glitch/runt since the enable only changes while `clk=0`. `psram_buf_ctrl.v`
is otherwise **byte-identical to pre-#69** (only a 1-port + 1-assign add) —
the FSM synthesises unchanged. `psram_model.v` keeps its sim-only guardrail
(`sio_out`/`ce_n`/`sio_oe` must not move while `sck` is high), wired via
`PSRAM_SCK_OUT`.

**Why the rework:** the first form put the negedge stage *inside*
`psram_buf_ctrl.v` (rename of all pad regs to `*_pre` + an in-module
`always @(negedge)`), which forced a full re-synth of the QPI FSM. Three
A40 runs (5504 −14.2, 5506 −18.7, 5507 −20.9 SS WNS) each surfaced a
*different* chronic worst cone in the re-synthesised `psram_buf_ctrl` /
debug-mux region (`buf_active`→`DBG0_OUT`, `_68608_`→`_67914_`, …) —
`_1`-strength unrepaired gates, −15..−21 ns, run-to-run lottery, not fixed
by the GRT repair-margin lever (jobs 5507 GRT-50 / 5508 GRT-40). The
in-module cell churn was the cause; the pad-boundary form removes it.

Signoff SDC (v29 divergence, unchanged by the rework — port names are the
same): `PSRAM_SCK` generated clock off `IQ_CLK`; SIO outputs
`-max 2.0 / -min -2.0` (APS6404L SIO setup/hold 2.0/2.0), `PSRAM_CE_N_OUT`
separately `-max 2.5 / -min -3.0` (CE# 2.5/3.0); read data
`-clock_fall -max 5.5 / -min 2.0` (falling→rising half-cycle); those pads
excluded from the generic core-output rule. Zero pad/PCB-flight baselines —
add measured trace delay before tapeout. The P&R SDC is left unchanged.

**Verification (pad-boundary form, commit `1af183a`):**
- **cocotb regression job 5510 CLEAN** — all 50 core+capture suites PASS
  (`dbg_probe` 12/12 with the +1 settle-cycle test fix, job 5509). The
  rework is functionally transparent.
- **A40 P&R job 5511:** physically **signoff-clean** — Magic DRC 0, LVS 0
  (device/net diff 0), XOR 0, antenna 0/0, route DRC 0, hold MET all
  corners (SS hold WS +1.79). nom_tt setup +3.34 MET. **SS DRV is the
  cleanest of the whole series: max-slew 9, max-cap 3** (baseline 5499 was
  39/11; in-module #69 was 22/8). 127 200 insts, die 1675×1110.
- **SS setup: WNS −14.44, TNS −1009** — recovered ~4 ns vs the in-module
  form (5506 −18.7) but still ~−3.7 ns short of the 5499 baseline (−10.77).
  Worst path `_66519_/Q → IRQ_OUT_OUT` (−14.4) is the `psram-status →
  debug_probe_mux → IRQ_OUT/DBG1 pad` cone that was already 2nd-worst in
  5499 (−10.44); plus a `_68745_` psram-internal register-load cluster at
  −11.0…−11.3. **0 violations from the IQ capture FFs** (the #70 two-stage
  capture holds).

**Root cause of the residual −3.7 ns:** not the launch-edge choice (the
pad-boundary form is strictly better than in-module) — it is that #69 + #70
add ~29 FFs to `trouper_top`, perturbing CTS/placement enough that the
already-marginal debug-output cone and one psram register cluster come out
starved in the repair lottery. `psram_buf_ctrl.v` is byte-identical to
pre-#69; only its placement moved.

**Recommended, NOT applied (2026-09-04 — deferred to avoid re-perturbing a
clean-enough netlist):** add `DBG0_OUT` + `IRQ_OUT_OUT` to an SS
`set_output_delay` exception (legitimate — debug-observability pads do not
need 32 MHz SS closure; already an open decision under #57 / #1). That
deletes the −14.4 worst path, leaving `_68745_` at −11.3 ≈ lottery range
vs baseline. The remaining SS gap is the #1/#40 voltage problem regardless.

**Status:** the interface fix is regression-clean and DRC/LVS/antenna/hold
signoff-clean; SS setup carries a bounded, understood, non-blocking
regression on debug + psram cones. Ready to merge on that basis; the SS
output-delay exception is a follow-up if/when the SS corner is revisited.

### 70. SX1257 IQ clock/data phase contract is undefined — capture edge and clock source both unpinned

`sd_decimator_poly.v` samples the raw `iq_in_i/q` 1-bit streams directly in
its `always @(posedge clk_32m)` block (line 265). The signoff SDC assumes
launch on the same rising `IQ_CLK` edge with a placeholder
`set_input_delay -max 2.0 / -min 1.0 -clock IQ_CLK` on the IQ ports
(`pnr_32m_scoped_v25_b6_signoff.sdc:481-482`). The SX1257 in fact presents
its I/Q data with a ~25 ns valid (setup-and-hold) window centred on the
*falling* clock edge (DS_SX1257 §3.7.4), so `posedge` capture lands near
the data transition and the SDC numbers do not model the real half-cycle
path.

The clock topology is also contradictory: `planning/Pinout.md` maps SX1257
pin 10 `CLK_OUT` → `IQ_CLK`, while `planning/System Architecture.md` says
`IQ_CLK` comes from the central TCXO / PCB fanout buffer. Different phase
contracts, no authoritative one recorded — so the launch↔capture
relationship the SDC should model is undefined.

**Risk:** the IQ inputs are the receiver's front door; a wrong capture edge
or uncharacterized phase relationship corrupts every branch. Passes STA
because the input delay is a guess.

**Action:** pin one authoritative clock topology in Pinout.md / System
Architecture.md; confirm the SX1257 RX data-valid edge and tDATA from the
datasheet; if data is valid at the falling edge, add falling-edge input
capture flops feeding the existing rising-edge decimator and constrain the
half-cycle path; replace the placeholder `set_input_delay` with
datasheet + PCB-derived values.

**See:** `src/decimator/sd_decimator_poly.v:265`;
`src/config/pnr_32m_scoped_v25_b6_signoff.sdc:481`; `planning/Pinout.md`;
`planning/System Architecture.md`; Open Risk #38.
**Found:** 2026-09-03 interface-timing review.

**Capture-edge fix landed 2026-09-03 (datasheet confirmed: SX1257 I/Q valid
around the falling clock edge), revised to a two-stage capture 2026-09-04.**
`trouper_top.v` samples the eight IQ pad bits on `negedge clk` (`*_neg`, mid
data-eye) and **retimes onto `posedge clk`** (`IQ_DATA_I/Q`) before the
decimator and debug probe use them. The negedge→posedge hop carries no
logic; every real datapath path (CIC integrators, comb, HB) runs on the
full 31.25 ns period. **Why the retime:** the first cut fed the negedge
regs straight into the datapath, putting the CIC 14-bit add on a half-cycle
(15.6 ns) path — job 5504 showed **73 SS setup violations** off those 8 FFs
(worst −8.5 ns, ~−350 ns TNS), nom_tt/max_ff still MET. **Confirmed fixed:**
A40 P&R jobs 5506/5511 show **0 SS violations from the IQ capture FFs**;
cocotb regression 5510 CLEAN (50/50). Cost of the retime: +1 clk latency
(31 ns) — negligible at the 500 kS/s output rate. Both SDCs:
IQ `set_input_delay -max 6.0 / -min 0.0 -clock IQ_CLK` is the pad→negedge-FF
half-period input path (checked vs the falling edge ~15.6 ns later; ~9 ns
slack); baseline for SX1257 clock-to-data + PCB flight, still to be replaced
with datasheet + measured values.
**Clock source — leaning SX1257_1 CLK_OUT direct (2026-09-03).** Board
owner's current plan is to drive `IQ_CLK` straight from SX1257_1 pin 10
`CLK_OUT` (simplest — matches `Pinout.md`, no extra PCB fanout buffer);
`System Architecture.md`'s "central TCXO / PCB buffer" wording is the one
to correct once confirmed. The **FPGA AFE PCB bring-up test (week of
2026-09-08)** decides it. This is also what makes the negedge-capture fix
above correct: it assumes the SX1257's data-launch clock *is* `IQ_CLK`
(same net, only matched PCB flight between them). If the PCB test forces a
separate fanout buffer, the extra buffer skew between the SX1257 launch
clock and `IQ_CLK` has to be re-characterised and the capture edge /
`set_input_delay` re-checked.

SGE regression **job 5503 CLEAN** (50/50 core+capture, `trouper_top` 18/18,
`dc_removal` / `trouper_capture` / `capture_two_packet` all PASS). A40 P&R
**job 5504** signoff-clean on DRC/LVS/XOR/antenna/hold; the negedge IQ
stage adds no datapath functional regression. SS setup WNS regressed
−10.77→−14.20 — full analysis under #69 (a `buf_active`→debug-pad cone, not
the IQ path; SS is #1/#40).

**Stays OPEN** pending: (1) the PCB-test decision above + the
`System Architecture.md` / `Pinout.md` reconciliation; (2) the shared
SS-regression follow-up tracked under #69.

## Moderate

### 59. Downstream foundational-block demonstration lacks an independent on-chip stimulus source

Trouper can independently prove SPI/register access, PSRAM QPI service, and packet/IRQ control (`SC_FORCE_LOCK`), and an FPGA can drive its existing one-bit IQ inputs for frontend testing. However, `mrc_combiner` and `sd_remod` have no deterministic internal source: their normal inputs depend on successful upstream capture/replay. A failure in the frontend, PSRAM, or acquisition chain can therefore prevent a standalone first-silicon proof of the final combiner/re-modulator foundation blocks even though their dedicated `REMOD_A_I/Q` output pads are working.

**Proposed mitigation — not approved or implemented:** one small, reset-off 500 kS/s deterministic complex source, muxed at either the re-modulator input (minimum scope) or combiner input (broader proof), enabled only under `RX_HOLD=1 && !PACKET_ACTIVE`. Required patterns are zero, bounded signed DC, and a repeating bounded I/Q tone; seeded PRBS is optional stress only. It uses no pins, but needs register allocation, assertions/cocotb coverage, top-level timing/P&R evidence, and a bench reconstruction procedure before it can be accepted. Do not add separate BIST engines to every block.

**Decision gate:** implement only if the first-silicon team judges this downstream demonstration path more valuable than the added mux/control/timing risk. The existing no-new-RTL bring-up sequence remains the baseline. See `planning/foundational-block-bringup-plan.md`.

**2026-09-04 — BRINGUP_SRC built, verified, and rebased onto `main`; decision still owed.**
`src/debug/bringup_src.v` (deterministic generator — modes zero / signed DC /
fs÷4 complex tone / PRBS, own 64-clock valid cadence, ±64 clamp) plus a 2:1 mux
at the **re-modulator input** (`bringup_en_q = BRINGUP_CTRL[0] && RX_HOLD &&
!PACKET_ACTIVE`, armed source takes absolute priority ahead of `psram_silence`,
`REMOD_BACKOFF_SHIFT` and the `comb_use_mrc` bypass select). Config regs
`BRINGUP_CTRL` **0x10** / `BRINGUP_AMPL` **0x11** (relocated from 0x06/0x07 on
the rebase — 0x06 is now `DBG_CTRL1`). Lives on branch `bringup-src-rebased`
(squash-rebase of `feat/bringup-src` onto `main`; **committed, not merged**).

- **Insertion point is the re-modulator input, not the combiner input.** MRC mode
  is unreachable while the source is armed (`W_valid` holds only during a packet;
  the armed source requires none), so the combiner-input option gave up almost
  nothing — bypass passthrough is a wire — while costing more. See
  `planning/foundational-block-bringup-plan.md`.
- **Functional verification (SGE job 5532, RTL rebased onto main):**
  `bringup_src` 23/23 (DC + fs÷4 + PRBS signatures end-to-end through `sd_remod`;
  all mux-priority cases; write-gate; cadence; reset determinism; DBG-probe
  visibility), `reg_bank` 39/39 (0x10/0x11 + reserved sweep), `trouper_top`
  18/18, plus `w_valid_split` / `bypass_backoff` (job 5536, after a Makefile
  fix — the #62/#65 RTL is intact under the merge). Every real suite passes;
  the only red is the pre-existing `dbg_qpi_busy` xfail (#67), unrelated.
- **Synthesis cost (post-synth, job 5533 vs bringup-free baseline 5527):**
  +118 cells (37 202 → 37 320), +6 155 µm² stdcell area (**+0.59 %**), 0 new
  latches.
- **P&R cost — A40 1675×1110 / 65 %, job 5533 vs job 5527 (identical config):**

  | metric | baseline 5527 | **+ BRINGUP_SRC 5533** | delta |
  |---|---|---|---|
  | magic DRC / route DRC / LVS / XOR | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 | clean |
  | antenna nets / pins | 0 / 0 | 0 / 0 | — |
  | hold WNS (ss / tt / ff) | 0 / 0 / 0 | 0 / 0 / 0 | MET |
  | setup nom_tt / max_ff | MET | +3.59 / +6.11 ns | MET |
  | **SS setup WNS** (`max_ss_125C_3v00`) | **−14.44 ns** | **−15.94 ns** | **−1.50 ns** |
  | **SS setup TNS** | **−1008.7 ns** | **−1480.7 ns** | **×1.47** |
  | placed cells / util | 50 894 / 68.7 % | 51 089 / 69.1 % | +195 / +0.4 pt |
  | SS max-slew violations | 9 | 8 | −1 |

  Physically signoff-clean; hold and the realistic-silicon corners unaffected.
  The cost is **SS setup: −1.5 ns WNS / +472 ns (×1.47) TNS** on a corner that is
  already ≈ −14 ns underwater (items 1 / 40 — the voltage problem, not this
  feature). Cheaper than the pre-rebase combiner-input version (×1.82 TNS,
  +8 790 µm², job 5404), but n=1 and +472 ns TNS is beyond repair-lottery
  scatter. Run: `/srv/eda/runs/timothyn-dev/lora-mimo-bringup/5533/a40_bringup/run`.

The "top-level timing/P&R evidence" the mitigation required now exists. The
decision gate stays open: accept the bounded (roughly-free to ×1.47 TNS,
see the 2026-09-04 update below) SS-timing cost for a standalone
`mrc_combiner` + `sd_remod` first-silicon proof, or drop the feature and rely on
the no-new-RTL bring-up sequence. If accepted, the branch needs merging and a
Register-Map / firmware review of the 0x10/0x11 assignment.

**2026-09-04 — two review findings on the branch, one fixed, one comment-only
(commit `edd6edc`, not yet re-run through P&R):**
- **DC mode dropped the sign of `BRINGUP_AMPL` (fixed).** `bringup_src.v`
  hardcoded the magnitude (`a_pos`) in `MODE_DC`, so `BRINGUP_AMPL=0xE0` (−32)
  emitted `+32` — contradicting the documented signed density
  (`BRINGUP_AMPL / 127`, Register Map 0x10–0x11) and the board procedure, which
  compares a capture against that signed reference. The bug had been enshrined
  in `test_dc_mode_polarity` (asserted `0xE0 → +32`) and
  `test_dc_signature_at_the_remod_output` never armed a negative level, so
  23/23 stayed green with it present. Fixed to select `a_neg`/`a_pos` off the
  sign, same as TONE/PRBS; both tests corrected/extended. Re-verified:
  `bringup_src` 23/23 (SGE job 5537).
- **PRBS period comment was wrong (comment-only).** Claimed period 511;
  simulating the exact Galois recurrence from seed `9'h1FF` returns to the
  seed after 255 steps — not maximal-length from this seed/tap pair. No RTL or
  test change: PRBS is documented as long-run switching stress only, and no
  test asserts a period.

**2026-09-04 — re-ran P&R with the DC-sign fix (job 5538): SS cost is bounded,
not fixed.**

  | metric | baseline 5527 | 5533 (pre-fix) | **5538 (fixed)** |
  |---|---|---|---|
  | DRC / route DRC / LVS / XOR | 0/0/0/0 | 0/0/0/0 | 0/0/0/0 |
  | antenna | 0/0 | 0/0 | 0/0 |
  | hold WNS (ss/tt/ff) | 0/0/0 | 0/0/0 | 0/0/0 |
  | nom_tt / max_ff setup | MET | +3.59 / +6.11 | +3.17 / +5.82, MET |
  | **SS setup WNS** | −14.44 ns | −15.94 ns | **−14.49 ns** |
  | **SS setup TNS** | −1008.7 ns | −1480.7 ns (×1.47) | **−834.9 ns** (better than baseline) |
  | placed cells / util | 50 894 / 68.7 % | 51 089 / 69.1 % | 51 197 / 68.8 % |

  Both post-fix runs are physically signoff-clean. The DC-sign fix only swaps
  which of two already-existing equal-width values a mux selects — no logic
  added or removed — so it should not move SS timing at all. The swing from
  5533's ×1.47 TNS down to 5538's near-baseline TNS is almost certainly
  resizer/CTS repair-order nondeterminism ("n=1 repair-lottery scatter", the
  same effect documented elsewhere in this file), not a causal result of the
  fix. **Read as bounded, not a fixed number:** BRINGUP_SRC's real SS-timing
  cost at the re-modulator input sits somewhere between "roughly free" and
  "×1.47 TNS" — narrower than pre-rebase (×1.82 TNS at the combiner input), but
  noisier than the +0.59 % synth-area delta alone suggests. Two runs is enough
  to bound it for the decision below; a third would only narrow the range, not
  change its shape.

### 11. Clock-net signal-integrity tradeoff is active in the current signoff config (not merely contingent)

At 1380×1100, `root_only` NDR preserved clock SI at no timing cost. Below
1380, `CTS_APPLY_NDR:"none"` is required instead — full clock-SI loss plus
~1 ns of additional SS penalty. Post-route clock skew/jitter/coupling-cap
signoff against baseline is still an outstanding step regardless of the die
size ultimately chosen.

**Updated 2026-07-11:** this entry previously read "contingent — only bites
if the die is shrunk further; not a risk at the current baseline," written
when 1380×1100 was still the production baseline. That's no longer true:
the current signoff config (`config_current_signoff.json`) is already at
**1200×1100 with `CTS_APPLY_NDR:"none"` set** — the same shrink closed out
by item #28 (fixed-pin floor). The clock-SI tradeoff has therefore already
been taken in the live signoff, not merely a future possibility. The
underlying technical content is unchanged; what changed is that the formal
post-route clock skew/jitter/coupling-cap signoff step this entry calls for
is now needed for the *actual* current config, not a hypothetical future
one.
**See:** `planning/area-reduction-roadmap.md` §6; `planning/die-shrink-routability-floor.md` §6–8.

### 12. 1100×1100 die target is blocked by measured global-routing congestion

The target is no longer speculative: at ≈974 k µm² cell area, 1100×1100 is
93.8% effective utilisation and fails global routing (GRT-0116 at step 39)
on every tried variant: Metal1/Metal2 pin layers and cell padding 0/1 (jobs
3242/3243/3245). The production/signoff size is 1200×1100. Reaching 1100×1100
requires RTL area reduction; floorplan tightening has been exhausted.

**Area/cost risk, not functional.**
**See:** `planning/area-reduction-roadmap.md` §6.

### 13. Live weight bank has no shadow→active promotion; writes are now structurally rejected while valid

`mrc_combiner` consumes the live `rb_w_shadow` bank; a separate `W_ACTIVE`
bank is deliberately not implemented. The old per-burst latches did not make
a 16-byte SPI burst atomic and were removed by B4. The actual safety mechanism
is hardware: after `W_COMMIT` makes `W_VALID` high, writes to `0x30–0x3F` are
blocked and sticky `WGT_CTRL[5] W_WR_REJECTED` records the attempt. Firmware
must write the complete vector before committing it; mid-payload `W_COMMIT`
still applies from that point onward.

**Found:** 2026-07-02 trouper_top RTL review.

### 14. PSRAM replay is truncated at packet timeout

In `S_REPLAY` the read pointer trails the write pointer and `packet_end` —
a live-time timeout — kills replay immediately, dropping the packet tail
unless `PKT_TIMEOUT_SYMS` exceeds actual packet length **plus** replay lag.

**Reduced 2026-07-12 by the continuous-delay replay implementation:** the
trailing gap is no longer unbounded-until-`W_COMMIT`; it is per-packet
deterministic — `TACC_WINDOW_SYMS·M + REPLAY_DELAY_SAMPLES` (≈ 8 symbols +
~6 symbols at SF7/default margin) — so firmware can budget
`PKT_TIMEOUT_SYMS` against a known quantity. Residual: still SF-dependent
via the training-window term, and no drain-then-exit exists; needs either
the documented timeout-margin rule in the firmware spec or a
replay-drain-then-exit condition.

**Found:** 2026-07-02 trouper_top RTL review.

### 16. Grouper/SPI register-bus arbitration silently drops SPI writes — **CLOSED 2026-09-01 (obsolete)**

> **CLOSED — the interface no longer exists.** With Grouper not taping out, the
> `GRP_*` bus and AHB endpoint were removed from `src/top/trouper_top.v`. Host
> SPI is the sole register master, so nothing can steer the mux away from an SPI
> write. The one-entry pending slot survives only to stage a completed SPI write
> onto the next `ce_16m` edge. Original analysis retained below for the record.


`trouper_top.v:578-581`: if `GRP_RE`/`GRP_WE` is asserted during the 2-cycle
SPI write window, the mux steers away and the SPI write vanishes — no
stall/queue as TRPR-SPS-007/TRPR-INT-003 require. Additionally the implicit
Grouper contract (hold `GRP_WE` ≥ 2 clocks for the CE latch; no write-side
`GRP_READY` handshake) is undocumented.

**Found:** 2026-07-02 trouper_top RTL review.

**Resolved:** 2026-08-04, regression job 3863. `trouper_top.v` now captures each completed SPI
write in a one-entry pending slot and commits it after the higher-priority
Grouper byte cycle releases. The byte-cycle contract requires release before a
second SPI data byte completes (≥ 4 µs at 2 MHz). Because pin-level SPI has
no WAIT response and the register bank has one combinational read port,
TRPR-SPS-007 now explicitly rejects a read byte whose MISO snapshot overlaps
`GRP_RE=1`; the host retries the complete read frame. Directed cases 3a/3b/4a
in `tb_trouper_grp_arb.v` cover priority, write preservation, and read recovery.

### 42. Packet-control FSM misses directed coverage for late weight commit and training timeout

The current verification matrix explicitly leaves two functional cases
uncovered: `W_COMMIT` during `PAYLOAD_ACTIVE` must enable combining only for
the remainder of the packet, and a missing `training_done` must let `acq_cnt`
enter bypass payload with `W_MISSED_PACKET` set. The existing miss test
withholds `W_COMMIT` entirely, so it does not establish either behaviour.

**Risk:** an untested packet-control transition can escape regression despite
the documented implementation. **Action:** add directed cocotb cases for both
rows, including observable combiner/bypass behaviour and sticky-status
readback. **See:** `planning/blocks/Packet Control FSM.md` (Verification
table); `planning/Trouper Chip Specification.md` TRPR-PCF-007/010.

### 7. Eigenvector power-iteration firmware timing does not fit SF7/SF8 (live mode) — MITIGATED, downgraded from High 2026-07-12

**Cycle-accurate measurement 2026-07-11 (SGE jobs 3333–3335).** The weight
kernel run on the real `picorv32.v` (slow non-`FAST_MUL` multiplier, corrected
7-bit-map kernel with faithful MMIO ingest) costs **33,283 cyc = 2.08 ms @16 MHz**
for the 8-iteration default on rv32im (36,458 cyc = 2.28 ms on the Grouper's
rv32emc/RV32E core, ~+10% from 16-register spilling), SF-independent. Against
the live-mode deadline (`4·M/500 kHz`): **SF7 (~1.02 ms) and SF8 (~2.05 ms) both
miss on both ISAs; only SF9+ fits.** 16 iterations (~3.88/4.28 ms) needs SF9+
(rv32im) or SF10+ (rv32emc). The 24-bit ZDIAG widening is timing-neutral
(−30/−54 cyc).

**Follow-up measurement 2026-07-12 (FPGA-emul, synthetic matrix).** The
MicroBlaze self-trigger benchmark on the Arty board, using a deterministic
4×4 synthetic matrix and `n_acc=1024`, reports `compute=3768 cyc` and
`total=3792 cyc` at 100 MHz (`37.68 us` / `37.92 us`) — a firmware-path sanity
check, not a live-mode deadline figure; it does not change the SF7/SF8 numbers
above.

**Why downgraded, not just documented:** the mitigation this entry always
pointed to — PSRAM replay mode, which relaxes the deadline from
`payload_start_estimate` to `packet_end_estimate − TACC_GUARD` and sidesteps
the live-mode race entirely — is no longer a plan, it's shipped: the
continuous-delay replay redesign is IMPLEMENTED and verified (all suites
PASS, SGE jobs 3347/3350/3354/3355; see item 5's fix and
`planning/psram-replay-continuous-delay-redesign.md`). With that mitigation in
place, "live-mode firmware weight compute needs SF9+" is a **known, quantified,
accepted architectural constraint** — not an unaddressed failure mode — for
any deployment that runs SF7/8 with MRC gain: replay mode is mandatory there,
same as it always was, and it now actually exists and is tested. Nothing
silently produces stale weights: a live-mode SF7/SF8 miss still degrades
cleanly to bypass via `W_MISSED_PACKET` (item 34, CLOSED), same fallback as
any other missed commit.

**What's still open (kept as Moderate, not fully closed):** this only covers
the on-chip PicoRV32 path. The unconstrained-host (RPi/Grouper SPI) live-mode
case still has unmeasured host IRQ/scheduling jitter that could itself blow
the SF7 window on a non-RT kernel — see
`planning/blocks/Eigenvector Weight Computation.md` §Timing — the actual
constraint. That residual is host-latency measurement work, not a firmware or
RTL defect.

**See:** `planning/blocks/Eigenvector Weight Computation.md` (Timing
Budget); `planning/DSP Chain SNR Loss Budget.md` §6;
`planning/psram-replay-continuous-delay-redesign.md`.

---

### 46. Trouper's pinout vs. a stricter 22-pad / 1117.5×1117.5 allocation — PIN HALF RESOLVED 2026-08-30 (allocation is 28 pads); die-size half stands

**Update 2026-08-30 — the pin-budget half of this item is closed.** The A40 ACV
allocation is confirmed at **28 pad slots**, not 22. `info.yaml` declares 26 pins — 24
signal + `VDD_CORE` + `VSS`, every one of which occupies a slot. (Superseded later the
same day: `DBG0_OUT`/`DBG1_OUT` took the last two, so the pinout is now **28 of 28 with
no spare** — item 54.) Neither the `IRQ_OUT`-removal
waiver nor NR=3 is needed to close a pin gap, because there is no pin gap. Everything below
about pins is retained as the record of the superseded assumption; the **die-size** half
(1117.5×1117.5 µm) is unaffected by this and is separately superseded for the A40 build,
which defers to the integrator DEF at 1675×1110 (item 52,
`planning/a40-padframe-integration-2026-08.md`).

Original entry follows.

Current pinout is 24 pads (23 signal + `VDD_CORE`; `VDD_IO` removed 2026-08-19 — it's the
same net as `VDD_CORE`, not a second pin, see `planning/5v-core-voltage-strategy.md`
§2026-08-19) against a possible 22-pad team allocation — a 2-pin gap, not 3. NR=3 alone now
closes it exactly, without also needing the `IRQ_OUT` waiver. The 1117.5×1117.5 µm square die target initially looked like a hard NR=4
dead-end (`DPL-0036` placement failure, job 4480), but that was a LibreLane floorplan
default (`*_MARGIN_MULT`) silently costing 4% of the die, not a structural limit —
reclaiming it (`config_1117sq_maxarea.json`) gets a **clean NR=4 physical signoff**
(DRC=0/LVS=0, job 4484), leaving only ordinary timing closure (−4.1 ns TT) still open. A 5V
retry on top of that fix does not help (job 4486, `DPL-0036` again, later stage). Separately,
**NR=3** (3 antenna channels instead of 4) also closes both the pin and die-size gap with
more headroom (jobs 4482/4483): exactly 2 pins recovered, 1117.5² routes clean at 84.7% util
and SS WNS −11.4 ns. Cost of NR=3: ~9%+ stdcell area saved, ~1.25 dB MRC combining-gain
loss, one diversity order given up. Preferred path is still an `IRQ_OUT`-removal pin waiver
to keep NR=4 at the current pin count; if the die-size rule alone is enforced, the
margin-reclaimed NR=4 config is now the first fallback (keeps 4-antenna MRC), with NR=3 as
the deeper fallback if timing closure on the reclaimed floorplan doesn't land. **See:**
`planning/1117sq-margin-reclaim-2026-08.md`, `planning/nr3-fallback-2026-08.md` (full
records), `planning/Pinout.md`.

---

### 47. Only 2 of 4 padframe quadrants get bonded per package — unconfirmed whether Trouper's quadrant is guaranteed included — **CLOSED 2026-09-04 (obsolete)**

> **CLOSED — no bonding lottery.** This round tapes out Trouper only, not
> Grouper. There is no 2-of-4 quadrant selection to lose: Trouper's quadrant is
> the one being fabricated and bonded. The pinout work this item was hedging is
> therefore not at risk. Re-open only if a future spin shares the padframe with
> other quadrant projects again. Original note retained below.

New organizer information (2026-08-19, not yet in any planning doc before this): the shared
padframe holds up to **4 quadrant projects, but only 2 are bonded out to package pins at
once**. All of this project's floorplan/pinout work (upper-left quadrant assignment,
clockwise `#N`/`#W` pin ordering, the L-shape/Grouper-notch keepout work) assumes Trouper
actually gets real package pins in whatever spin is produced. Not yet confirmed with
organizers whether Trouper's quadrant is guaranteed to be one of the 2 bonded, or whether
that's still an open assignment/lottery. If Trouper isn't bonded, the pinout is moot for that
spin (though the die itself is presumably still fabricated and could be bonded in a later
run). **Action:** confirm bonding-pair assignment with the track lead before treating any
pin-budget work as final.

### 48. Digital input pins may be shareable between quadrant projects — pin-budget lever not yet evaluated — **CLOSED 2026-09-04 (not needed)**

> **CLOSED — the lever it was reserved for is gone.** Digital input pins are
> **not** shared with other quadrant projects; each project bonds its own. That
> is fine: the pin budget is met anyway. This item existed only as a cheaper
> alternative to the `IRQ_OUT`-removal waiver / NR=3 fallback for closing the
> 22-pad / 1117.5² gap in item 46 — and item 46's pin half is already resolved
> (the real ACV allocation is 27 pads, not 22; see items 52 and 57). With no
> budget gap to close there is nothing for this lever to do. Re-open only if a
> future spin re-introduces a pin-count shortfall. Original note retained below.

Same 2026-08-19 organizer update as item 47: "it may be possible to share digital input pins
between projects." Not yet investigated for this design, but a real candidate exists —
`IQ_CLK` (external clock reference, a plain digital input with no project-specific timing
requirement that would prevent sharing) could potentially be bonded to a single shared
package pin across multiple quadrant projects rather than each project bonding its own copy,
recovering a pin without any RTL change. This is a materially different, and likely cheaper,
lever than the `IRQ_OUT`-removal waiver or NR=3 fallback already tracked in item 46 for
closing the 22-pad/1117.5² budget gap — see `planning/nr3-fallback-2026-08.md`. Needs
organizer confirmation of exactly which pins are shareable and the mechanics (does the
project still declare the pin in its own `info.yaml`, or is it wired externally by the
padframe integrator) before it can be relied on.

---

### 53. `ARRAY_ACQ_N` open-drain emulation has not received pad-level electrical review

The multi-ASIC acquisition-sync extension uses one `gf180mcu_fd_io__bi_24t`
bidirectional pad as an active-low, shared open-drain wire: RTL ties `A=0` and
uses `OE` to select drive-low versus high impedance while sampling `Y`.  This
is the appropriate logical use of the available pad, but the PDK provides no
dedicated open-drain primitive and no pad-level/silicon validation has yet
established that the selected control polarity, reset behaviour, input
thresholds, drive strength, leakage, or enable/disable transition are suitable
for a multi-chip wired net.

**Risk:** an incorrect interpretation of the `bi_24t` controls or an
unreviewed board pull-up can cause contention, an excessive low-level current,
slow/noisy rising edges, false synchronisation events, or an unintentional
drive during reset.  The net is optional for a single-chip receiver, but it is
required for the proposed coordinated multi-chip acquisition and should not be
committed to the board/pad allocation on RTL inference alone.

**Required review / closure evidence:**

- Review the exact `gf180mcu_fd_io__bi_24t` Liberty, Verilog model, and PDK
  documentation for `A`, `OE`, `Y`, `IE`, `CS`, `SL`, `PU`, `PD`, `PDRV0`, and
  `PDRV1`; confirm OE polarity, high-impedance state, reset/default state, and
  whether any keeper or implicit pull is active.
- Simulate the actual pad model at chip-top with an external pull-up and two
  pad instances.  Prove no device drives high, simultaneous local locks only
  sink current, and reset/enable transitions do not create a false accepted
  falling edge.
- Select and document a board pull-up resistance from the pad's sink-current
  limit, IO voltage, net capacitance, maximum trace length, and the required
  release/rise time.  Verify VIH/VIL margins and account for all attached
  chips' leakage.
- Confirm package/padframe integration maps the ten logical boundary signals
  (`OUT`, `IN`, `OE`, and seven controls) to exactly one physical bidirectional
  pad and that this additional physical pad remains available in the final
  allocation.
- Run a post-integration electrical/functional test with the real pad wrapper
  before relying on multi-chip beamforming or direction-finding experiments.

**Current RTL safeguards (updated 2026-08-30):** `ARRAY_SYNC_EN` (`ARRAY_SYNC_CTRL[0]`, register `0x18`)
resets to 0, so the pin is inert in both directions until firmware arms it; the
internal pull-up is **enabled** on this pad alone so an unpopulated pin cannot
float; Schmitt input is enabled; the driver only ever presents zero; a natural
local SC lock wins over a same-cycle peer edge; and a receiver ignores peer
events while `packet_active`.  These reduce protocol risk but are not
substitutes for the electrical review.

**No run in this project has ever checked a pad cell.** `trouper_top`
instantiates zero `gf180mcu_fd_io__*` cells, so the macro's LVS netlist and
layout contain none — verified on job 5279 (0 IO cells in the netlist, 0
`gf180mcu_fd_io` hits in the LVS report). Every "DRC/LVS clean" result to date,
including the runs that carry this pad, is a statement about the **Trouper macro
only**. The electrical questions below are therefore entirely open, not
partially covered. SPICE-level LVS/DRC and the specific simulations that would
close them are planned in `planning/pad-cell-signoff-plan.md`, gated on the
integrator confirming the padframe.

**Added to the pull-up review by the internal pull-up:** the board resistor is
now in parallel with one internal pull-up per participating chip. Size the
external resistor against the *combined* pull-up current, and confirm the
resulting V_OL at the 4 mA `PDRV=00` sink still meets every receiver's V_IL
across the worst-case number of chips on the net. The internal device's
strength is not characterised in our own data and must be read from the PDK
before this is closed.

**See:** item 52 above (the pad-slot allocation decision this depends on);
`planning/array-acquisition-sync.md`; `src/top/trouper_top.v`
(`array_acq_sync` and `ARRAY_ACQ_N_*` pad wiring).

---

**Additional points from the parallel writeup of this item (2026-08-30):**
`ARRAY_SYNC_CTRL[0]` (`0x18`) resets to **0** and gates both directions, so an
unpopulated pin on a single-chip board cannot start the receiver whatever the
floating pad does — the exposure is confined to boards that use the link. On a
shared net one internal pull-up **per participating chip** sits in parallel with
the board resistor and must be counted in both the sizing and the V_OL budget.
The pad configuration should also be reviewed against the GF180 IO databook gap
already recorded in item 27. The feature is synthesis-proven only: +111 cells /
+4030 µm² (+0.41 %), zero Yosys check problems, and explicitly not timing, DRC,
LVS, pad-ring or pull-up validated.


### 52. A40 ACV allocation is 28 pad slots — one spent on `ARRAY_ACQ_N`, two spare; slot N15 still needs a DEF regen — **CLOSED 2026-09-04**

> **CLOSED — ACV confirmed at 27 pads, integrator DEF regenerated, P&R against it
> clean.** The allocation is **27** (not 28 — see #57). The 159-entry
> `src/config/A40_ACV_rtlnames.def` was regenerated 2026-09-03 (commit `224c151`)
> by `rtl-test/scripts/regen_a40_def.sh`, which runs the integrator's own padring
> tooling (`ip/chipathon-2026-padring-system`, `make -f Makefile.padframe
> project-def-A40`) from the full 27-pin `info.yaml` — byte-for-byte reproducible,
> raw generator artifacts (`interface.yaml`, `pad_map.yaml`, `padring.v`,
> `selected_variants.json`) kept under `rtl-test/ol_trouper_top/a40_integrator/`.
> `ARRAY_ACQ_N` (N15) and `DBG0` (N16) carry real generator coordinates, not the
> old synthetic stopgap. First full A40 P&R against this template — **job 5511**
> (`FP_DEF_TEMPLATE = A40_ACV_rtlnames.def`, strict match), corroborated by
> DRV-sweep baseline **job 5527**: **physically signoff-clean** — magic DRC 0,
> route DRC 0, LVS 0 (all sub-counts), XOR 0, antenna 0 net / 0 pin, hold MET all
> three corners (worst slack +0.135 ns ff / +1.79 ns ss), setup nom_tt +3.34 /
> max_ff +5.94 MET; 1675×1110, util 68.7 %.
>
> **Residuals (tracked elsewhere, not blocking this item):**
> - SS setup WNS −14.44 ns / TNS −1008.7 ns — the pre-existing voltage-bound
>   floor plus the #69/#70 FF perturbation; **items 1 / 40 / 69**, not a DEF/pin
>   issue. The GRT repair-margin lever does **not** help on this netlist (jobs
>   5528/5529: SS TNS −1121.8, more DRV, not less).
> - DRV residual: SS max-slew 9 / max-cap 3 (nom_tt 2/2) — existing DRV waiver
>   (`_comment_drv_closure` / `_comment_drv_margin_sweep`).
> - `ARRAY_ACQ_N` open-drain pad-level electrical review — **item 53**.
> - `DBG0_OUT` / `IRQ_OUT_OUT` SS output-delay exception (**TRPR-DBG-012**) — open
>   under #57.
> - A literal integrator human sign-off that the 27 slot names / IO-cell types /
>   bonding match the regen — the regen used the integrator's tooling and
>   artifacts, so this is confirmation, not open design work.
>
> Original entry retained below.

The current A40 integration artifacts declare and place **25** Trouper pads (23 signal,
`VDD`, and `VSS`). The reported ACV allocation is **28** pads, leaving **three** slots
unassigned by the current `info.yaml`, A40 DEF template, and RTL pinout. This must be
confirmed against the current integrator `A40_ACV_pad_map.yaml` / regenerated DEF: the
slot names, IO-cell types, bonding status, and locations are not yet recorded locally.

**Decision required before finalising the A40 pin list:** retain all three as spares, or
allocate one to the physical `sc_lock_in` trigger-synchronisation link for
[multi-chip cascade operation](NR2-multi-ASIC-cascade.md) (the proposed shared
acquisition/SC-lock trigger extension). If selected, update `info.yaml`,
`planning/Pinout.md`, the top-level pad interface, the A40 template, and the integration
and regression evidence together; do not assume a spare slot is electrically or
package-bond available until the integrator confirms it.

**Update 2026-08-30 — allocation confirmed at 28; one slot spent, two remain.** The
28-pad ACV allocation is confirmed. `ARRAY_ACQ_N` is declared in `info.yaml` (appended
after `VDD`, so it takes N15 and no existing pin moves) and wired in `trouper_top.v`,
bringing `info.yaml` to 26 declared pins and leaving 2 of the 28 slots spare — both of
which were then spent on the debug probes the same day, see item 54. This
also closes the pin half of item 46: the 22-pad budget that
drove the NR=3 / `IRQ_OUT`-waiver contingency was never the real allocation.

**Still open on this pin** (the budget was never the hard part):

- No P&R run has been built against a 26-pin DEF. Request a regenerated `A40_ACV.def`
  from the integrator and re-run before treating N15 as committed.
- Slot names, IO-cell types, and bonding status for N15 and the two remaining spares are
  still not recorded locally — get the current `A40_ACV_pad_map.yaml`.
- Pad-level electrical review of the open-drain emulation is item 53.

The pad is self-contained: deleting the `info.yaml` entry, the two `io_placement` entries,
and the `ARRAY_ACQ_N_*` ports backs it out completely.

---

**Superseded on the spare count (2026-08-30):** this entry was written when two
slots were still spare. `DBG0_OUT`/`DBG1_OUT` have since taken both — the
allocation is now exactly 28/28 with none spare. See item 57, which is the
current statement of the pin budget; only the slot-confirmation half of this
entry is still live.

### 57. The pin allocation is now exactly full (27/27), and two of those slots are unconfirmed — **CLOSED 2026-09-04 (slots confirmed; TRPR-DBG-012 spun out)**

> **CLOSED — the "unconfirmed slots" half is resolved; the "no margin" half is a
> documented state, not an open action.** N15/N16 (`ARRAY_ACQ_N`, `DBG0`) and the
> `IRQ_OUT`/`DBG1` shared pad now come from a DEF regenerated with the
> **integrator's own padring tooling** from the full 27-pin `info.yaml` (commit
> `224c151`, `regen_a40_def.sh`; artifacts under
> `rtl-test/ol_trouper_top/a40_integrator/`), not our hand-extended template.
> P&R against that DEF — **job 5511** / DRV-sweep **job 5527** — is
> physically signoff-clean (DRC 0, route DRC 0, LVS 0, XOR 0, antenna 0/0, hold
> MET all corners; 1675×1110, util 68.7 %). The DBG0 slot is placed and routes
> clean, so "is spending the last dedicated slot on `DBG0_OUT` right" is a
> judgement call with no technical blocker; the two features remain independently
> back-outable (`array-acquisition-sync.md`, `two-pin-digital-debug-plan.md`).
>
> **Still open, spun out so this entry can close:**
> - **TRPR-DBG-012** — the `DBG0_OUT` / `IRQ_OUT_OUT` SS `set_output_delay`
>   exception decision (debug-observability pads don't need 32 MHz SS closure;
>   see #69's "recommended, not applied" note and #1). Recommend re-homing this
>   under #69 or #1.
> - The zero-pin-margin exposure (problem 1 below) — real, but it is a state to
>   manage, not a fix to land. Any future pin need displaces an allocated slot.
> - SS setup WNS −14.44 ns — items 1 / 40 / 69, not a pin issue.
> - Integrator human sign-off on the regenerated slot map (confirmation only).
>
> Original entry retained below.

**Update 2026-09-03 — the budget is 27, not 28.** Integrator feedback corrected
the ACV allocation to **27 pads**. Rather than drop a debug channel, `DBG1` was
merged onto the `IRQ_OUT` pad via a split-selector mux (`DBG_CTRL0` → `DBG0_OUT`,
`DBG_CTRL1` (`0x06`) → the shared `IRQ_OUT`/`DBG1` pad, which carries the sticky
interrupt unless `DBG_CTRL1.EN=1`). `IRQ_OUT_SL` moved slow→fast so the shared
pad can carry 32 MHz raw-RX debug; the board damps the RPi IRQ net with a series
resistor. Consequences now live: while `DBG_CTRL1` is armed the host has no
hardware interrupt line and must poll `IRQ_STATUS` (`0x02`); and `IRQ_OUT` can
no longer serve as an always-on analyser trigger. See
`planning/two-pin-digital-debug-plan.md` (status header) and `planning/Pinout.md`.
The rest of this entry still applies with "28→27", "three newest→two newest",
"N15/N16/N17→N15/N16".

`info.yaml` declares **27** pins against a **27**-slot allocation: 25 signal +
`VDD_CORE` + `VSS`. There is **no spare slot left**. The last two went to
`ARRAY_ACQ_N` (N15) and `DBG0_OUT` (N16); `DBG1` rides the already-allocated
`IRQ_OUT` pad.

**Two distinct problems, often conflated:**

1. **No margin.** Any further pin need — a second supply, a strap, a bring-up
   escape, a late interface fix — must now *displace* something already
   allocated. Historically this project has wanted a spare pin roughly once a
   month (`sc_lock_in`, the IRQ waiver, the NR=3 study). Zero margin at this
   stage is a real exposure, not a bookkeeping note.
2. **The three newest slots are not confirmed.** N15/N16/N17 exist in our
   `info.yaml` and in a locally extended floorplan template
   (`src/config/A40_ACV_rtlnames_dbgpins.def`, built by
   `rtl-test/scripts/a40_append_provisional_pads.py`). The integrator has not
   confirmed that those slots exist, are bondable, or can carry the cell types
   we assume. Nothing in any P&R run validates that — the run only proves the
   *design* closes with three more north-edge pads at coordinates **we chose**.

**What would close it:** a regenerated `A40_ACV.def` from the integrator
containing all 27 pads, a P&R run against that template rather than ours, and a
decision on whether spending the final dedicated slot on `DBG0_OUT` is the right
use of the last pin.

**P&R against our 27-pin template: done (job 5457, 2026-09-03).** Canonical
`src/config/trouper_top.json` + the regenerated 159-pin `dbgpins.def`. Magic DRC
0, route DRC 0, LVS 0, XOR 0, antenna 0, hold WNS +0.117 ns. SS setup WNS
−10.88 ns (baseline job 5379 −10.13; −0.75 ns is n=1 repair-lottery noise). The
old `DBG1_OUT` SS output violator moved to `IRQ_OUT_OUT` (−4.82 ns, *smaller*
than the pre-reshape −6.06); `DBG0_OUT` −6.16 ns; these two remain the only
`reg-out` violators. Still integrator-side: a real `A40_ACV.def` with these 27
slots, and the `DBG0_OUT`/`IRQ_OUT_OUT` SS output-delay exception decision
(TRPR-DBG-012).

**Note on what P&R proves here.** It proves the *macro* routes and closes with
three more boundary pins at coordinates we chose. It says nothing about the pad
cells — Trouper instantiates none — so no amount of clean Trouper P&R can
confirm a slot exists or is bondable. That needs the integrator, and the
electrical half needs `planning/pad-cell-signoff-plan.md`.

**If a slot is refused,** the two features are independently removable and
documented as such: `planning/array-acquisition-sync.md` and
`planning/two-pin-digital-debug-plan.md` each list the exact back-out steps.
The debug probe is the cheaper thing to drop — it is bring-up-only, whereas the
acquisition link is a functional feature.

**See:** item 52 (the slot-availability decision this grew out of), item 53
(`ARRAY_ACQ_N` pad electrics), `planning/Pinout.md` allocation status.

---

*(Numbered 54 on `feat/array-acq-sync`; renumbered to 57 on merge — 54, 55
and 56 were already taken on this branch by the host-SPI GLS/SDF, startup-
sequencing and IR-drop entries respectively.)*

### 64. Packet timeout is ignored until `PAYLOAD_ACTIVE` — **CLOSED 2026-09-04 (spec clarification, no RTL)**

> **CLOSED — `PKT_TIMEOUT_SYMS` redefined as a payload-phase deadline.** No RTL
> change. The FSM already bounds every phase: `PREAMBLE_ACQ` by `acq_cnt` and
> `W_PENDING` by `wpend_cnt` (both `TACC_WINDOW_SYMS`-derived, `packet_ctrl_fsm.v:245`
> / `:263` → IDLE), and `PAYLOAD_ACTIVE` by `pkt_cnt` (`:297`). So `packet_active`
> is finite for every legal register value — worst case is the sum of the three
> windows. The only real defect was semantic: TRPR-PCF-007 read as if
> `PKT_TIMEOUT_SYMS` were a global watchdog. Fixed in the docs:
> `Trouper Chip Specification.md` TRPR-PCF-007, `Register Map.md` `0x0B` (table +
> detail), `Traceability.md`, and packet-ctrl-fsm verification plan row 14 /
> item 3 — all now state payload-phase semantics and that the register cannot
> abort a bad acquisition early. `cocotb/pkt_timeout_states/` (job 5474) is
> retained: `test_payload_timeout_forces_idle` is the TRPR-PCF-007 regression,
> the ACQ/W_PENDING cases are documented expected behaviour.
> **Re-open only if** firmware/host turns out to need a hard global packet
> deadline shorter than the acquisition + weight-pending windows (would need the
> ~4-line RTL fix: `pkt_cnt==0` forces IDLE in `ACQ`/`W_PENDING` too).

`packet_ctrl_fsm.v:164-170` decrements `pkt_cnt` throughout
`PREAMBLE_ACQ`, `W_PENDING`, and `PAYLOAD_ACTIVE`, but the zero test exists
only in `PAYLOAD_ACTIVE` (`:290-297`).  If `PKT_TIMEOUT_SYMS` is shorter than
the acquisition or weight-pending deadline, the counter reaches zero without
forcing IDLE and `packet_active` can remain asserted past the configured packet
deadline, contrary to TRPR-PCF-007.  With `TACC_WINDOW_SYMS=8` the acquisition
and weight deadlines are approximately 10M and 13M respectively, so a
10-symbol timeout exposes the case when training or commit is late.  This is
distinct from item 14, which concerns truncating an already-running delayed
PSRAM replay at timeout.

The packet-control verification plan already marks the short-packet-deadline
case as a spec/RTL issue, but it was not present in this project-wide register.
**Decision/fix:** either give packet timeout priority in every active state and
add early-expiry tests, or explicitly redefine the register/specification as a
payload-only timeout and document the resulting upper bound.

**2026-09-03 — CONFIRMED by directed bench `cocotb/pkt_timeout_states/`
(unit-level, TOPLEVEL = `packet_ctrl_fsm`; SGE job 5474).** SF7/`M`=256,
`tacc_window_syms`=8, `pkt_timeout_syms`=4 (`pkt_span`=1024):
- `test_payload_timeout_forces_idle` (control) PASSES — the mechanism works in
  `ST_PAYLOAD_ACTIVE`.
- `test_preamble_acq_timeout_is_ignored` — `packet_active` stays asserted for
  **2562 ticks** (to the acquisition deadline ≈2560) instead of ≈1024.
- `test_wpending_timeout_is_ignored` — **3330 ticks** (to the weight-pending
  deadline ≈3328).

**Found:** confirmed 2026-09-03 during the full `src/` RTL review; previously
noted in `planning/verification-plan/packet-ctrl-fsm-verification-plan.md` row 14;
now reproduced by `cocotb/pkt_timeout_states/`.

### 65. Remodulator backoff attenuates bypass despite the direct-stream contract — **CLOSED 2026-09-04**

> **CLOSED — backoff gated to active MRC, verified.** Fixed on
> `rtl/open-risk-fixes` (merged to `main` via PR #53): `mrc_combiner.v` exports a
> burst-aligned `use_mrc` flag (`= W_valid && !mode`, sampled at the state-0
> burst start); `trouper_top.v:1109` applies `REMOD_BACKOFF_SHIFT` only when
> `comb_use_mrc` is set, so Mode-1 / no-`W_valid` bypass forwards `comb_y`
> unshifted per TRPR-PCF-011 / TRPR-RMD-008. The `< -3 dBFS` remod stability
> contract is unaffected (bypass carries the selected antenna's int8 sample
> directly, which already satisfies it). Verified: `cocotb/bypass_backoff/` PASS
> — `remod_in == comb_y` in bypass at reset defaults (job 5477); `bypass_e2e`,
> `bypass_antenna`, `remod_backoff`, `comb_remod_transfer`, `mcp_mrc_settle` all
> PASS (job 5476); A40 P&R signoff-clean (jobs 5499 / 5511). Detail retained below.

`trouper_top.v:924-926` applies `REMOD_BACKOFF_SHIFT` after the combiner for
all modes.  The reset value is one (`reg_bank.v:219`), so Mode 1 and the
no-`W_valid` fallback lose one bit (approximately 6 dB) instead of delivering
the selected antenna's int8 sample directly as TRPR-PCF-011/TRPR-RMD-008 and
the MRC/remod block documents require.  The current bypass end-to-end check
masks the mismatch by programming the shift to zero before comparing the remod
input with `comb_y`.

**Decision/fix:** either gate the shift to active MRC only and add a reset-default
bypass regression, or explicitly change the specification and link-budget
policy so bypass attenuation is intentional.  Any change must retain the
re-modulator's `< -3 dBFS` stability contract.

**2026-09-03 — CONFIRMED by directed bench `cocotb/bypass_backoff/`
(top-level, TOPLEVEL = `tb_trouper_cocotb`; SGE job 5472).**
`test_bypass_keeps_reset_backoff_and_attenuates` locks in Mode 1, restores
`COMB_CFG` to its **reset value** (`0x10`, backoff shift 1), waits for replay,
and compares `remod_in` against `comb_y`: **0 / 50 pairings matched;
all 50 were `comb_y >> 1`**. The reset-default bypass path loses ~6 dB.

**FIXED 2026-09-03 (branch `rtl/open-risk-fixes`).** `mrc_combiner.v` exports a
burst-aligned `use_mrc` flag (`= W_valid && !mode`, sampled at the state-0 burst
start). `trouper_top.v` applies `REMOD_BACKOFF_SHIFT` only when `comb_use_mrc`
is set; Mode-1 / no-`W_valid` bypass forwards `comb_y` unshifted. Verified:
`cocotb/bypass_backoff/` PASS — `remod_in == comb_y` in bypass at reset
defaults (job 5477); `bypass_e2e`, `bypass_antenna`, `remod_backoff`,
`comb_remod_transfer`, `mcp_mrc_settle` all PASS (job 5476).

**Found:** 2026-09-03 full `src/` RTL review; reproduced by `cocotb/bypass_backoff/`.

### 66. A same-cycle SC hit can falsely qualify a noise window as clean — CLOSED 2026-09-03 (fixed-drain + eval-boundary verdict; regression + A40 P&R clean)

> **CLOSED 2026-09-03.** Fixed on `rtl/open-risk-fixes` (commits `a844409` /
> `8a30d2d`): 72-clock fixed drain + `noise_eval_seen` eval-boundary gate +
> per-window `win_epoch` + single priority ladder (see body and **#68**).
> Directed bench `cocotb/noise_window_edge/` 10/10 (SGE job 5498); combined
> `core` + `capture` regression 50 suites all PASS (SGE job 5496). A40
> `ol_trouper_top` P&R regression after the rebase onto
> `pinout/dbg1-shared-irq-pad-27` — **SGE job 5499**, `src/config/trouper_top.json`:
> signoff-clean (Magic DRC 0, LVS 0, XOR 0, antenna 0/0, hold MET), SS setup
> WNS −10.77 ns / TNS −370.4 — inside the reference spread (job 5379 −10.13 /
> job 5378 −11.17; TNS beats 5379's −383.5). No signoff regression from the
> #61/#63/#66/#68 RTL. SS 32 MHz setup remains the pre-existing open voltage
> problem (#44 lineage), untouched by this change. Residual max-slew/max-cap
> counts rose vs the pre-RTL 27-pin run (job 5469 7/1 nom_tt → 17/7) — added
> flops/logic in the sc_detector-decode / training_acc DRV-waiver cones;
> tracked with the existing DRV waiver, not a #66 blocker. The drvp1 65→50
> GRT-margin variant (job 5500) did **not** reproduce its unmerged reference
> (job 5491) on the merged netlist — SS TNS −1020.9 — so `trouper_top.json`
> stays at 65/65.

In `trouper_top.v:704-723`, a contaminating `sc_hit_dbg` sets
`noise_window_sc_seen` and `training_done` qualifies `sigma2_valid_r` in the
same sequential block.  If both arrive together without `sc_lock`, the
nonblocking validity expression reads the old `noise_window_sc_seen=0` and can
assert `NOISE_READY` for a contaminated window.  Earlier hits and same-cycle
locks are rejected correctly; the exposed case is specifically a non-locking
hit on the completion edge.

**Required fix/evidence:** include the current-cycle hit in the completion
predicate (for example, reject on `noise_window_sc_seen || sc_hit_dbg ||
sc_lock`) and add an integration test for contamination one cycle before, on,
and one cycle after `training_done`.

**2026-09-03 — CONFIRMED by directed bench `cocotb/noise_window_edge/`
(SGE job 5474).** TOPLEVEL = `noise_window_qual`, a **verbatim copy** of the
`trouper_top.v` qualification always block (the same-cycle race cannot be
phase-aligned through the full datapath; the copy carries a KEEP-IN-SYNC
header). Contamination one cycle before / on / after `training_done`:
`test_clean_window_qualifies`, `test_hit_before_completion_rejected`,
`test_lock_on_completion_edge_rejected`, `test_hit_after_completion_ignored`
all **PASS**; `test_nonlocking_hit_on_completion_edge` **FAILS** —
`sigma2_valid` asserts for a window a non-locking `sc_hit_dbg` contaminated on
the completion edge. A follow-up end-to-end version (driving real SPI) would
also close the reachability argument.

**First fix attempt (`~(noise_window_sc_seen || sc_hit_dbg || sc_lock)`) was
INSUFFICIENT — P1 review finding.** `sc_hit_dbg`/`sc_lock` are *registered*
`sc_detector` outputs, and the serial metric engine is ~57 cycles deep, so a
non-locking hit whose evaluation overlapped the window can register its
`sc_hit_dbg` pulse a variable number of edges *after* `training_done`. Peeking
at `sc_hit_dbg` on the `training_done` edge catches only the exact-alignment
case (hit registers on that edge or the one before); a hit at
`training_done + 1` or later still qualified and closed the window before
`noise_window_sc_seen` could latch it. The verbatim-copy wrapper missed this
because it drove `sc_hit_dbg` as a settled input rather than modelling the
detector's registered pulse.

**Second fix attempt (drain-gated verdict, release on `!sc_pipe_active` alone)
was STILL INSUFFICIENT — P1 review finding.** `sc_detector.v` exports
`sc_pipe_active = tdm_busy | eval_busy | metric_valid_pulse | sc_hit_dbg`; on
`training_done` the gate enters a DRAIN phase (`noise_window_draining`,
`noise_window_active` held high so the `sc_hit_dbg`/`sc_lock` sampler keeps
running) and renders the verdict once `sc_pipe_active` falls. But the release
fired on the *first* cycle `sc_pipe_active` read low after `training_done`,
which can be the very next edge if the pipeline is momentarily idle at the
boundary — an `sc_lock` (or non-locking hit) that becomes visible two or more
edges later then slipped through. `test_lock_at_or_after_boundary` offset +2
FAILED (3/4), `test_hit_offset_sweep` was at risk for the same reason.

**FIXED 2026-09-03 (branch `rtl/open-risk-fixes`) — fixed grace window + drain.**
The DRAIN phase now also holds for a fixed `NOISE_DRAIN_MIN = 72` clocks
(7-bit down-counter loaded on `training_done`); the verdict
`sigma2_valid_r <= ~(noise_window_sc_seen || sc_lock)` is rendered only once
**both** `noise_drain_cnt == 0` **and** `!sc_pipe_active`. 72 is the SC serial
metric-engine depth (~57 cycles, `serial_mul13` × 4 products + handshake) plus
TDM-burst slack, rounded up — it bounds the latest edge at which an evaluation
that was already in flight at `training_done` can register `sc_hit_dbg`/
`sc_lock`. `noise_window_sc_seen` OR-accumulates hit/lock for the whole drain,
so any contamination inside the grace window latches. NOISE_READY latency grows
by ~72 clk ≈ 2.3 µs (irrelevant for the AGC noise-EMA use). Cost: one 7-bit reg
+ comparator. Still safe-biased: a stray hit *after* the window merely
suppresses this measurement (firmware retries) — it can never let a
contaminated window through. The wrapper MODELS the registered `sc_detector`
outputs (test drives `hit_ev` + `pipe_busy`, wrapper produces `sc_hit_dbg`/
`sc_pipe_active` with the real 1-cycle latency); `test_hit_offset_sweep` walks
the contaminating hit across offsets −2…+8 and `test_lock_at_or_after_boundary`
across 0/+1/+2, asserting rejection at every one. Verified: `cocotb/
noise_window_edge/` 4/4 PASS + full `core` 47/47 clean (SGE job 5485);
`capture` group (real captured IQ + weight-gen SPI e2e) clean at job 5486.

**Follow-up review (2026-09-03) — the fixed-drain verdict had a further hole
(P2), fixed together with the #68 follow-ups:** an SC evaluation launches only
at a symbol boundary, so `!sc_pipe_active` after the 72-clock drain did **not**
prove the symbol that was accumulating at `training_done` had been scored — a
packet starting late in the noise window stayed invisible past the drain.
`sc_detector` now exports `sc_eval_done_pulse` (`= metric_valid_pulse`) and the
verdict additionally requires `noise_eval_seen` (≥ 1 full metric evaluation
completed since the drain began). The two-`if`-chain structure of the block was
also collapsed to a single priority ladder so a noise retrigger accepted on the
drain-release cycle can no longer be lost to the old window's verdict. See
**#68** for the full write-up of the three follow-up fixes (pipeline-flush,
retrigger race, eval-boundary drain) and their tests.

**Combined `core` + `capture` regression covering #66 + #68 + the three
follow-ups: SGE job 5496** — 50 suites, all PASS bar a stale
`noise_window_edge` test expectation, fixed and re-verified 10/10 in SGE job
5498.

**A40 P&R regression check — SGE job 5499** (`src/config/trouper_top.json`,
rebased onto `pinout/dbg1-shared-irq-pad-27`): SS setup WNS −10.77 ns /
TNS −370.4, Magic DRC 0, LVS 0, XOR 0, antenna 0/0, hold MET. WNS sits
between reference runs 5379 (−10.13) and 5378 (−11.17); TNS improves on
5379's −383.5. No signoff regression. drvp1 65→50 GRT-margin variant
(job 5500) regressed SS TNS to −1020.9 on the merged netlist (unmerged ref
job 5491 did not carry over) → `trouper_top.json` stays 65/65. **CLOSED.**

**Found:** 2026-09-03 full `src/` RTL review; NBA precedence trace, reproduced by
`cocotb/noise_window_edge/`.


## Low

### 61. `formal/run_formal_both.sh` was broken and under-scoped — every proof silently unrun — FIXED 2026-09-03, one failure exposed

The formal runner has been non-functional since `/foss/designs` went read-only
(NFS `manage_gids`, 2026-07-27/28): `sby` creates its work directory in the CWD,
so **every** proof died with `OSError: [Errno 30] Read-only file system` before
doing any work. It also iterated only two of the four `.sby` files —
`spi_slave` was already missing before `bringup_src` was added. Fixed 2026-09-03
(stages into `$RUN_DIR`; iterates all four). Now: `psram_buf_ctrl` PASS,
`packet_ctrl_fsm` PASS, `bringup_src` PASS, and **`spi_slave` BMC FAILS** —
`a_addr_incr_wrap`, `formal/spi_slave_formal.sv:213`, step 33 (job 5438). That
failure is pre-existing and untriaged; it is not a `bringup_src` regression. It
needs its own investigation against
`planning/verification-plan/spi-slave-verification-plan.md` rows #13/#15.

**Priority: high** — an unrun proof is indistinguishable from a passing one in
every report that quotes it, and this one hid a real assertion failure for an
unknown number of weeks.

### 62. `DRT-0073` on the `IQ_CLK` clock tree is placement-perturbation sensitive, not netlist-size sensitive

`src/config/trouper_top.json` `_comment_density` frames the recurring
DRT-0073/DRT-1231 pin-access failures as "sensitive to netlist size, not to
anything about SPI", on the evidence of job 5281 (a 144-cell growth broke a
clean run). That framing is wrong in the general case and should not be relied
on when judging whether a change is safe.

Counter-example, 2026-09-03: moving `BRINGUP_SRC` from the combiner input to the
re-modulator input **shrinks** the netlist — 35,436 vs 35,597 cells at
synthesis, 48,900 vs 49,020 at CTS, 49,022 vs 49,137 at global routing — and yet
fails detailed routing reproducibly (jobs 5425, 5436, identical error):

```
[DRT-0073] No access point for clkbuf_2_2_0_IQ_CLK_regs/I
           (gf180mcu_fd_sc_mcu7t5v0__clkbuf_16)
```

while the larger combiner-insertion netlist (job 5404) routed clean at the same
settings. The mechanism is placement perturbation around the `IQ_CLK` tree, so
**"my change removes cells" is not evidence that it will route.** Any netlist
perturbation on this die is a fresh routability question.

Related and still standing: do not downsize the clock tree or drop `clkbuf_16`
(job 5197 moved the failure to a `clkbuf_12` instead), `DIODE_PADDING: 4` is
what cleared antenna without crowding the clkbufs (job 5198), and
`PL_TARGET_DENSITY_PCT: 65` is a routability floor rather than area headroom.

**Priority: medium** — it does not threaten the current signoff netlist, but it
invalidates a documented heuristic that a future change will otherwise be judged
by. Probes for the specific `BRINGUP_SRC` case are tracked in
`planning/foundational-block-bringup-plan.md` (TRPR-BRU-009): `DPL_CELL_PADDING`
3 (job 5439, cancelled, unevaluated) and `PL_TARGET_DENSITY_PCT` 64 (job 5440).

### 56. Trouper standalone flow has never run a real-source IR-drop analysis

`VSRC_LOC_FILES` (OpenROAD PSM's realistic-downbond-location IR-drop mode)
is not set anywhere in Trouper's own P&R configs (`rtl-test/ol_*/config*`,
`pdn_cfg.tcl`) — confirmed by search, 2026-08-23. Whenever Trouper's own
flow reaches `OpenROAD.IRDropReport`, it falls back to LibreLane's default
`LIB_VOLTAGE`/BTerm-source behavior, which treats every top-level power pin
as an idealized current source — optimistic relative to a real chip with
only a handful of actual bond wires. `planning/Open Risks.md` #46 and
several other docs flag IR drop as a qualitative unknown for exactly this
reason.

**Mitigated by context, not by data of Trouper's own:** Trouper is being
physically implemented together with Grouper on one shared die
(`lora-mimo/integration/pd/config_landscape_2235.yaml`,
`chip_top.v`), not packaged standalone, so the risk this entry names is
already being answered by that combined integration's own real-source IR-drop
analysis rather than needing a separate Trouper-only run. That analysis
(2026-08-23, both landscape SRAM-orientation topologies, real
via-connected vsrc downbond locations, `chip_top` job 4833/4834) came back
at **~3-5% worst-case drop on both VDD and VSS** (VDD 3.02%/5.13%
depending on topology, VSS 2.05%/2.84%) — a reasonable, non-alarming
number, not pinned to 0 (which would suggest a broken analysis) or blowing
up. See `lora-mimo/planning/grouper-trouper-landscape-floorplan-2026-08.md`
Open Item #9 for the full derivation and the two LibreLane/OpenROAD bugs
that had to be fixed to get a working number at all
(`lora-mimo/integration/pd/vsrc/README.md`).

**Amended 2026-09-02 (PDN work):** every IR figure produced by Trouper's own
flow is in this optimistic mode — the PDN trials measured 0.10-0.14 %, against
the ~3-5 % the real-source combined-die analysis reports. Absolute IR margin
from a Trouper-only run must not be used to argue a grid change is unnecessary;
relative comparisons between configs on the same netlist remain valid. Note also
that this entry's "mitigated by context" argument rests on Trouper sharing a die
with Grouper, which predates the 2026-09-01 decision that Grouper is not taping
out — whether the mitigation survives under A40 is unresolved. See
`planning/pdn-thickening-and-core-ring-2026-09.md` §5.

Still real padframe/downbond estimates, not final pad data — this entry
stays open until real physical downbond locations replace the geometric
via-connected estimates currently in `vsrc/*.loc`, same caveat the
combined-die doc itself carries.

### 22. NR=2/3-chip cascade risks unsimulated

Re-modulator SQNR accumulation across cascade stages, hierarchical-MRC
suboptimality vs. true NR=4 MRC, and inter-chip reset skew (undetectable at
runtime — no symptom besides corrupted MRC weights, mitigated only by
matched-trace-length reset routing, unverified) are all open for the
multi-ASIC cascade topology.

**Low for the current NR=1 tapeout** — becomes High if/when an NR=2 cascade
product ships.
**See:** `planning/NR2-multi-ASIC-cascade.md`, `planning/cascade-beamsteering.md`.

### 23. Weight Generation: noise-whitening — models + RTL flow CLOSED 2026-07-26, firmware equivalence verified; gating policy open

Float and fixed-point SNR-weighted eigenvector paths implemented and verified
end-to-end over SPI (jobs 3596/3598, combiner bit-exact). Firmware builds for
rv32emc (job 3602), was cycle-measured on the real PicoRV32 (job 3608), and
matches the fixed-point model bit-for-bit on a traced unequal-noise register
vector (job 3612). The remaining risk is the undecided runtime gating policy.
**See:** `planning/noise-weighted-mrc-2026-07.md`.

### 24. Residual Trouper Chip Specification drift: MRC numeric representation and RMD instability wording

The 2026-07-26 audit closed the clock-tree, register-map, W_ACTIVE/safe-switch,
PCF state/mode, and stale R=128-comment discrepancies. Two wording questions
remain: TRPR-MRC-001/006 must consistently describe the implemented
high-byte/8-bit weight representation rather than int16 Q1.15, and RMD-003's
instability wording must match the observed failure signatures.

**Doc gap — risk is firmware/bring-up written against the spec, not the map.**
**Found:** 2026-07-02 trouper_top RTL review.

### 25. trouper_top dead logic + minor RTL hygiene — packet_ctrl_fsm portion RESOLVED 2026-07-12

**Resolved (dead FSM signals):** all dead `packet_ctrl_fsm` outputs and
inputs deleted from the RTL — `psram_packet_arm`, `psram_replay_start`,
`payload_rd_base`, `safe_switch`, `combiner_source` (superseded by the
continuous-delay replay redesign, commit `46e1cdf`), plus the now-unused
inputs `iq_valid`, `psram_en`, `psram_replay_active`. `buf_freeze` was
initially KEPT because it was regression-covered (TRPR-PCF-002/008,
`test_w_missed_packet.py`) even though it drove nothing in `trouper_top`;
it was **deleted 2026-07-26** once it was established to be a bit-identical
duplicate of `packet_active` (same four assignment sites, same values — the
formal harness had been asserting both equal `state != ST_IDLE`). PCF-002/008
and the four regression assertions are retargeted to `packet_active`.

**Resolved (`psram_abort` — the "verify that path or wire/delete" item):
verified UNREACHABLE, branch deleted.** The mid-payload re-lock scenario
`psram_abort` guarded (a second `sc_lock` arriving while a replay is still
in flight, with `packet_active` never dropping so `packet_end` never fires)
is structurally impossible in the current design: `sc_detector` holds
`sc_lock` high until `sc_clr` (= `packet_done_pulse`, the falling edge of
`packet_active`), both the hit-count and `SC_FORCE_LOCK` lock paths are
gated `!sc_lock`, and the `SC_FORCE_LOCK` register write is additionally
blocked by `PACKET_ACTIVE`. Every packet acquisition therefore passes
through `ST_IDLE`/`packet_end` first — `psram_buf_ctrl`'s `packet_end` exit
from `S_REPLAY` is sufficient. The entire `ST_PAYLOAD_ACTIVE` re-lock branch
(and `psram_abort` with it) was deleted; a why-comment in
`packet_ctrl_fsm.v` and `psram_buf_ctrl.v` records the reasoning.
**Guard-rail for future work:** if `sc_detector` ever gains a mid-packet
re-arm path (e.g. an NR2/3 cascade `sc_lock_in` wired without the
`!sc_lock` gate), re-lock handling AND a replay-abort path must be
reintroduced in both `packet_ctrl_fsm` and `psram_buf_ctrl` — see the note
in `planning/NR2-multi-ASIC-cascade.md`.
Verified: 7 cocotb suites + `sc_force_lock` + `tb_trouper_two_packet`
regression after the deletions (SGE jobs 3359/3360).

**Still open (non-FSM items):** `mimo_mode[1]` never writable
(`reg_bank.v`) yet read back and forwarded; `mrc_combiner.v:126` assigns
`26'sd0` to an 18-bit reg; `mrc_combiner` port `clk_16m` is actually driven
at 32 MHz. The live-training `noise_trig` swallow is **closed 2026-08-29**:
the top gates the trigger while `training_armed`, raises sticky/W1C
`TACC_NOISE_TRIG.NOISE_TRIG_REJECTED` (0x1F[1]), and a directed cocotb test
proves no false `NOISE_READY` occurs.

**Found:** 2026-07-02 trouper_top RTL review.

---

### 55. Power-on / startup sequencing has no on-chip enforcement — unverified in silicon

Four related gaps surfaced while checking whether the PSRAM QSPI clock could
be run below 32 MHz:

1. **No hardware tPU wait for PSRAM init.** `trouper_top.v:414` wires
   `init_start = PSRAM_CTRL[0] & ~QSPI_OWNER` — a register-bit *level*, not a
   firmware-pulsed strobe as `planning/blocks/PSRAM Buffer Controller.md`
   describes ("firmware pulses `init_start` after tPU"). The APS6404L needs
   tPU ≥ 150 µs after its own power-up before RSTEN is safe; nothing in RTL
   times this. It is entirely a host/firmware discipline requirement (RPi
   must wait before writing `PSRAM_CTRL[0]=1`), unverified against real
   silicon + a real PSRAM part. `cocotb/tests/test_startup.py::
   test_psram_init_has_no_tpu_wait` measures ~2.9 µs from `RESETB` release
   to the first PSRAM CE# pulse when firmware issues the write immediately
   — confirms the gap is real and quantifies it, but only host-side
   discipline (or a real on-chip timer) prevents hitting it.
2. **tRST margin inside QE_INIT: re-measured, not thin.** Originally
   estimated by hand-counting FSM states as ~62.5 ns (12.5 ns margin over
   the APS6404L's tRST ≥ 50 ns) — that hand count was wrong.
   `cocotb/tests/test_startup.py::test_qe_init_trst_margin` measures the
   actual RST(`0x99`)→Enter-QPI(`0x35`) CE# gap in simulation at **750 ns**
   (700 ns margin) — comfortable. Left in as a regression test rather than
   a live risk; downgrading this sub-item accordingly.
3. **`rst_n` is the raw `RESETB` pin, unsynchronized, no on-chip POR or
   deglitch** (`trouper_top.v:70`: `wire rst_n = RESETB;`). Reset-ordering
   bugs have already hit this design once — see item 26 below (closed): SPI
   frame flops reset only on `posedge HOST_CS`, so the very first CS-low
   transaction after power-on parsed garbage, caught only because someone
   specifically tested first-transaction ordering rather than the normal
   packet-loop sweeps.
4. **SC-detector correlator is fully idle until `del_rdy` fires.** This is
   intentional (Gate 9 hold-off in
   `planning/decimator-hb-migration-impact-plan.md`, min 256 samples at
   SF7/BW250), but worst case (SF12/125 kHz, N=16384 samples ÷ 500 kS/s) is
   **≈32.8 ms** after `qe_init_done` before the receiver can register any
   lock. Reasonable by design, but it is a real "deaf window" on every PSRAM
   init or SF/BW change, and no spec states an explicit worst-case
   time-to-first-lock figure. `test_sc_correlator_idle_until_del_rdy`
   (SF9/BW125, ~4.1 ms case) confirms `tdm_busy` never activates before
   `del_rdy` and measures warm-up at 4.092 ms vs a 4.096 ms prediction —
   behaves exactly as designed; worst case scales linearly to SF12/125 kHz.

None of this surfaced in the existing cocotb SF/BW sweeps or
`tb_trouper_two_packet` because those testbenches start from an
already-initialized state or use idealized/instant power-up — they don't
exercise power-on ordering itself.

**5. PSRAM power-up SIO-low / CE#-high state is a board obligation the ASIC
cannot meet alone** (added 2026-09-04, interface review). During the
APS6404L's first 150 µs the datasheet requires SCK low, CE# high tracking
VDD, SIO[3:0] low, no commands, then a software reset. Under ASIC reset the
PSRAM pads are Hi-Z with internal pulls disabled (`trouper_top.v` ties
`PSRAM_SIO_*` / `PSRAM_SCK_*` / `PSRAM_CE_N_*` `_PU`=`_PD`=`0` — see the
`planning/Pinout.md` pad-tie-off table), so the ASIC does not hold the bus
in the required state. The board must provide: weak pull-downs on
`PSRAM_SCK` and `PSRAM_SIO[3:0]`; a pull-up on `PSRAM_CE_N` to the PSRAM
supply; a low-ESR 1 µF cap close to PSRAM VDD; firmware `PSRAM_EN` held off
≥ 150 µs after PSRAM power is valid (this is item 1's firmware wait, now
also an electrical requirement); total PSRAM-net loading within the
datasheet's 15 pF characterisation limit. Not checkable in RTL/sim — verify
on the test-PCB schematic and at bring-up. See #69 (PSRAM interface
timing).

**Found:** 2026-07-05, while investigating PSRAM QSPI clocking margin
(item 5 added 2026-09-04).

**Testbench added:** `cocotb/tests/test_startup.py` (6 tests, all PASS,
SGE job 3257) — first-transaction-after-reset at 3 clock phases (regression
for item 26), the tPU-race and tRST-margin characterizations above, and the
SC hold-off check. Items 1 and 3 remain open (no on-chip fix, by design
pending firmware/board discipline); item 2 is downgraded from risk to
regression coverage; item 4 is confirmed working as intended; item 5 is
board-only (no sim hook possible).

**Next steps:** first hardware bring-up on the test PCB (a few weeks out)
will validate items 1, 3 and 5 against a real PSRAM part and real RESETB
behavior — sim can characterize the digital logic's assumptions but not the
analog reset/power-rail behavior itself. Item 5 also needs a test-PCB
schematic review (PSRAM pull-downs / CE# pull-up / decoupling / net load)
before fab.

### 67. Debug probe's `qpi_busy` source is permanently asserted after PSRAM init — **CLOSED 2026-09-04 (redocumented, no RTL)**

> **CLOSED — probe redocumented as a coarse active-state indicator.** No RTL
> change. `101`/`SEL=0` d1 (`qpi_busy` = `|psram_state_dbg`) reads continuously
> high after PSRAM init because every steady-state post-init state is non-zero;
> it is not a per-transaction strobe and is now documented as
> "PSRAM initialised / active-state". `two-pin-digital-debug-plan.md` updated —
> the derivation note and the group-`101` table row both state this and point
> bring-up at `101`/`SEL=1` (`buf_active`/`replay_active`) or `SEL=2`
> (`sample_skip`/`replay_missed`) for per-transaction visibility. Functional
> operation and SPI-visible PSRAM status were never affected. Exporting the real
> `psram_buf_ctrl` transaction-busy level was judged not worth perturbing the
> already-marginal debug-output timing cone (see #69). **Re-open only if** the
> bring-up team needs true per-transaction busy on that specific probe position.

`trouper_top.v:1197-1201` feeds the debug mux's `qpi_busy` input with
`|psram_state_dbg`.  The normal initialized PSRAM states (`S_QE_INIT`,
`S_WRITE`, and `S_REPLAY`) are all nonzero, so debug group `101`, selector 0
reports busy continuously after initialization rather than showing individual
QPI transactions.  `psram_buf_ctrl` has the real internal `qpi_busy` level but
does not export it.  SPI-visible PSRAM status and functional operation are not
affected; this is a first-silicon observability failure.

**Fix/evidence:** export the actual transaction-busy level (or rename and
document the probe as “PSRAM initialized/active state” if that was intended),
then check idle/write/read transitions in the debug-mux regression and update
`planning/two-pin-digital-debug-plan.md`.

**2026-09-03 — CONFIRMED by directed bench `cocotb/dbg_qpi_busy/`
(top-level, TOPLEVEL = `tb_trouper_cocotb`; SGE job 5472).**
`test_qpi_busy_probe_stuck_after_init` points the shared `IRQ_OUT`/DBG1 pad at
group 101 / sel 0 and samples it for 40 000 cycles: the internal
`u_psram.qpi_busy` reads low on **12 500** of them, the probe pad on **0** —
stuck at 1 for every post-init state.

**Found:** 2026-09-03 full `src/` RTL review; reproduced by `cocotb/dbg_qpi_busy/`.

---

## Deferred

### 9. SC Detector acquisition is single-antenna at any instant (no diversity at lock time) — DEFERRED 2026-07-06, re-scoped 2026-08-14

`sc_detector.v` correlates only one antenna branch's `cur_i0/q0` / `del_i0/q0`
at a time via `psram_buf_ctrl`'s delay line; the `Sum_j` incoherent 4-branch
combine that `planning/DSP Flow.md` Stage 5 specifies is not implemented. If
the currently-selected antenna is in a deep Rayleigh fade, the gateway fails
to acquire the packet even when the other 3 antennas have strong signal —
the array provides no diversity gain for detection, only for post-lock MRC
combining. Confirmed both via measured-IQ playback (Rayleigh seed 7 vs 10)
and a Monte-Carlo sweep (`sim/notebooks/12_sc_detector.ipynb` §3: at 9 dB/
branch SNR, P(lock) with the selected antenna in deep fade is 0% single-
antenna vs 52% for the spec-intended combine). A spec-faithful fix (serial
4-channel TDM correlator, ~+20 k µm², no clock-period cost) is designed but
not implemented, pending an area-headroom check against the floorplan.

**Mitigation added 2026-07-11:** `sc_ant_sel` (`reg_bank` `SC_ANT_SEL` 0x1B[1:0];
was `BW_CFG` 0x0A[2:1] until 2026-08-30)
lets firmware pick *which* single antenna feeds the correlator, instead of
the old hardcoded antenna 0 — cheap (a byte-lane mux + address offset in
`psram_buf_ctrl.v`, no measurable area cost), verified bit-exact
(`cocotb/sc_ant_sel/test_sc_ant_sel.py`, SGE job 3328). This does **not**
close the underlying risk: the correlator is still single-antenna at any
instant, so acquisition still fails if the *currently selected* antenna is
the one in deep fade. It only means firmware can route around a
known-bad branch (e.g. after a noise-mode `Z_kk` energy scan) instead of
being permanently stuck on antenna 0. Firmware-side selection policy is not
yet designed. See `planning/Register Map.md` `0x0A`.

**Related mitigation added 2026-07-12 (different failure mode):**
`SC_FORCE_LOCK` (`reg_bank` 0x19[0], W1P) manually asserts `sc_lock`,
bypassing the correlator's hit-count logic entirely. This does not address
the ant0-fade diversity gap above — it is a bring-up / catastrophic
correlator-failure escape hatch for the case where `sc_detector` itself is
suspected non-functional (not just fed a faded antenna), so the rest of the
chain (`packet_ctrl_fsm` → PSRAM → combiner → IRQ) can still be exercised.
A forced lock has no verified preamble edge to anchor `timing_ref` on, so it
is not useful for recovering a real packet, only for proving downstream
logic is alive. Register-only for now; a physical `sc_lock_in` pin (the
NR2/3 cascade OR-lock scheme, `planning/NR2-multi-ASIC-cascade.md`) is
deliberately deferred — the pinout is at its 26-pad budget
(`planning/Pinout.md`) with no spare pad to bond. See `planning/Register
Map.md` `0x19`; regression `cocotb/sc_force_lock/test_sc_force_lock.py`
(SGE job 3356, 2/2 PASS: forced entry into `ST_PREAMBLE_ACQ` from IDLE, and
the `PACKET_ACTIVE` write-gate confirmed to block a second force mid-packet).

**Does not block tapeout** — silicon works correctly whenever the selected
antenna is not the faded branch; this is a robustness/diversity gap, not a
functional bug.
**Decision 2026-07-06:** the full 4-branch correlator deliberately DEFERRED —
no die-area headroom for the ~+20 k µm² cost at the current floorplan.
Revisit only if an area budget opens up (e.g. after further area cuts or a
die-size change); until then, `sc_ant_sel` is the accepted interim
mitigation and the diversity gap itself stays an accepted, documented
limitation.
**See:** `planning/sc-detector-ant0-fading-risk.md`.

**Deferred state (2026-08-14):** moved out of Moderate into this section. The
fix is designed and costed (~+20 k µm² serial 4-channel TDM correlator, no
clock-period cost) and is *not* to be re-proposed, re-costed, or re-explored
except when the re-open trigger below fires.

**Re-open trigger:** a signed-off floorplan with ≥ 20 k µm² of spare cell area
against the then-current die (e.g. after a further area-cut milestone, a die-size
increase, or the 4.5 V-core decision in item 44 freeing utilisation headroom).
Whoever hits that trigger re-files this as Moderate with the measured headroom
number attached.

**Until then, accepted as-is:** `sc_ant_sel` (0x1B[1:0]) is the shipped
mitigation, the firmware-side branch-selection policy is the only outstanding
work item, and the detection-diversity gap is a documented silicon limitation
rather than an open action.

---

## Closed

### 51. `trouper_top` @ 1675×1110 antenna violations — CLOSED 2026-08-29 (`DIODE_PADDING: 4`)

The A40 die-size rebuild had 26 antenna net / 35 pin violations (job 5158).
**Job 5198 (`config_1675_c5_diodepad4.json`) reaches 0 net / 0 pin**, fully
signoff-clean: DRC 0, XOR 0, LVS clear, hold 0 all corners, setup max_ss
−13.15 ns (better than the −13.52 ns baseline), clock skew 0.312 ns,
die 1675×1110.

Antenna *repair* was never the problem — inserted diodes crowded IQ_CLK clock
buffers and stole their routing pin access, so detailed routing died on
`DRT-0073`/`DRT-1231`. `DIODE_PADDING` was unset, so diodes could abut a clock
buffer; setting it to 4 fixes the interaction. The failing cell was a `clkbuf_16`
in every early run, but downsizing the tree is **not** the fix — job 5197 then
failed on a `clkbuf_12`, the very cell it downsized to, and cost skew
(0.442 vs 0.312 ns). Buffer size is irrelevant; diode proximity is the cause.

This also gives Open Risk #6 (recurring `DRT-1231` clkbuf pin-access failure) a
concrete mitigation. Full record:
`planning/antenna-closure-investigation-2026-08.md`.

### 5. ~~"Silence during PSRAM buffering" actually emits a ΣΔ-modulated DC tone~~ FIXED 2026-07-12

**Both halves fixed by the continuous-delay replay implementation**
(`planning/psram-replay-continuous-delay-redesign.md`, now IMPLEMENTED):
`trouper_top.v` keeps `in_valid` asserted and feeds zeros during buffering
(real modulated silence, asserted bit-exact by the updated
`_watch_bypass`), and the `W_COMMIT` rewind-to-`buf_base` jump is replaced
by a margin-gated delay line that never rewinds (`TRPR-RMD-009` met;
monotonicity watched at `rd_ptr` in `cocotb/tests/test_replay_delay.py`).
New registers `REPLAY_DELAY_SAMPLES` (0x77/0x78) + `WGT_CTRL[4]`
`W_COMMIT_LATE`.

**Found:** 2026-07-02 trouper_top RTL review. **Fixed:** 2026-07-12
(replay-delay regression + bypass_e2e/w_missed/psram_ops/qspi_owner/
reg-reset-sweep suites, SGE jobs 3347/3350).

### 39. Scoped-MCP SDC cone leaks and `timing_ref` write-arc dishonesty — CLOSED 2026-07-26 (v25_b6 canonicalized)

The v20 SDC's `-through` net wildcards miss three quasi-static
`rb_*` → derived-register cones (same bug class the v18/v20 headers document):
`rb_sf_cfg → u_pcfsm.pkt_end_q` (**−20.4 ns**, current worst SS path),
`rb_sc_hits_req → timing_ref` (−17.7 ns; endpoint net keeps the top-level
name, not `u_sc.*`), and `rb_tacc_window_syms → u_tacc.acc_end` (−16.6 ns;
arriving cone fully anonymized). Confirmed on the latest v20 signoff runs
(`ol_trouper_top` `RUN_2026-07-05_00-56-3x`, SS WNS −20.4 to −25.4) — these,
not `u_psram`, are the current residual SS wall (item 1's −25.39 figure).

Separately, the v20 `MCP=3 -to acq_timeout_q/wpend_timeout_q` fix is
**dishonest on the write side**: `sc_detector` sets `timing_ref` on the same
edge as `sc_lock` (`sc_detector.v:441/450`), and `packet_ctrl_fsm.v:112-116`
latches the timeout registers one cycle later — the
`timing_ref` → 32-bit-adder arc has **1 real cycle** but a 3-cycle STA budget
(the v20 header's justification covers only the read side). Since sibling
rb→adder cones measure ~48 ns at SS, this arc very likely also misses
31.25 ns: silicon could latch a corrupt per-packet timeout (worst case the
FSM hangs in `PREAMBLE_ACQ` until `iq_samp_cnt` passes a garbage threshold).

**Action (v21):** scope the three missed cones by `-to` register endpoints
(quasi-static sources, same justification as v18/v20); make the pcfsm
relaxation honest by delaying the timeout-register latch ≥2 cycles after
`sc_lock` (compute from `lat_timing_ref` on `ST_PREAMBLE_ACQ` entry — first
compared much later) or scoping `-from` only the quasi-static sources.
Tooling note: the NFS `ol_mimo_rx_top/runs` symlink is a self-loop (rsync
copied the local symlink); real runs live in `ol_trouper_top/runs/`.

**See:** `src/config/pnr_32m_scoped_v25_b6.sdc` (v20–v25 history and active
exceptions);
`src/control/packet_ctrl_fsm.v`; item 1.
**Found:** 2026-07-12 (SDC-vs-`src/` MCP audit + NFS STA cross-check).

**v21 update 2026-07-12:** the three missed cones are scoped via `-through
<quasi-static rb_* net> -to <register>` (not `-from` — OpenSTA's
`set_multicycle_path -from` rejects `Net` objects; caught as a hard STA error
in job 3365 and fixed before job 3366/3367). Scoping the intended sources
(`rb_sf_cfg`, `rb_sample_shift`, `rb_pkt_timeout_syms`, `rb_tacc_window_syms`,
`rb_sc_hits_req`) wasn't enough on its own: the worst path in job 3366
(SS WNS −27.19 ns, config `config_current_signoff.json`, 1200×1100/88%) still
routed through `u_pcfsm.wpend_timeout_q[31]` because synthesis merged the
`rb_sample_shift = rb_bw_sel ? 2'd2 : 2'd1` ternary straight into `rb_bw_sel`'s
fanout — `rb_sample_shift` never survives as its own net on that path, same
"-through wildcard misses an optimized-away net" failure class as every prior
bug in this file's history. Fix: added `rb_bw_sel` to the `-through` source
list for both the pcfsm and `u_tacc` blocks (job 3367).

**Verified CLOSED (cone-scoping only):** job 3367 (SGE, `RUN_2026-07-12_21-56-16`)
— cross-checked every violator against the synthesis netlist
(`06-yosys-synthesis/trouper_top.nl.v`): none of `u_pcfsm.pkt_end_q`,
`u_pcfsm.acq_timeout_q`/`wpend_timeout_q`, `u_tacc.acc_start`/`acc_end`, or the
`timing_ref` write arc still violate when driven from a genuine quasi-static
source (`rb_sf_cfg`/`rb_bw_sel`/`rb_pkt_timeout_syms`/`rb_tacc_window_syms`/
`rb_sc_hits_req`). SS WNS at this die/density improved −25.39 ns (July 5
baseline, same config) → **−16.01 ns** (job 3367), despite RTL growth in
between.

**Write-arc dishonesty (former "Action" item 2) is CONFIRMED REAL, still
open:** with the three cones no longer masking it, STA now shows genuine
single-cycle violations from `timing_ref` itself into `u_pcfsm.acq_timeout_q`
(e.g. `timing_ref[7] → acq_timeout_q[31]`, −15.69 ns; `→ acq_timeout_q[30]`,
−15.00 ns) — exactly the arc flagged as dishonest, now honestly exposed
instead of hidden under a false 3-cycle budget. Closing this still needs the
RTL fix described above (delay the timeout-register latch ≥2 cycles after
`sc_lock`, computed from `lat_timing_ref` on `ST_PREAMBLE_ACQ` entry) — not
implemented yet.

**CLOSED 2026-07-13 (RTL fix + v24 SDC).** `packet_ctrl_fsm.v` now has a
dedicated `ST_ACQ_SETUP` state between `ST_IDLE` and `ST_PREAMBLE_ACQ`: the
`sc_lock` rising edge only latches `lat_timing_ref <= timing_ref` (a plain
register copy); `acq_timeout_q`/`wpend_timeout_q`/`pkt_end_q` are computed one
cycle later, in `ST_ACQ_SETUP`, from `lat_timing_ref` — which cannot change
again until the next `sc_lock` edge (thousands of cycles later). That makes
the `lat_timing_ref → {acq_timeout_q, wpend_timeout_q, pkt_end_q}` arc
genuinely tolerant of a multicycle exception, unlike the old same-edge
combinational compute from the live `timing_ref` input. Added as a new v24
`set_multicycle_path -through u_pcfsm.lat_timing_ref[*] -to
$pcfsm_timeout_regs` exception in `src/config/pnr_32m_scoped_v20.sdc`
(mirrored to `rtl-test/ol_trouper_top/`).

While verifying, closing this arc exposed `u_pcfsm.M_val` (Open Risk #40's
"M_val not itself explicitly scoped" residual) as the new worst path
(−5.15 ns) — `packet_ctrl_fsm.v:46-49` has its own redundant `M_val` register,
separately derived from `sf`/`sample_shift` and never covered by the existing
`$pcfsm_qs_srcs` (rb_*-net) `-through` list, because the path from M_val's own
Q pin into the timeout registers never touches those rb_* nets. Folded into
the same v24 SDC change (`-through u_pcfsm.M_val[*] -to $pcfsm_timeout_regs`).

**Verified:** functional regression job 3402 (trouper_top 18-test SF/BW+startup
sweep, sc_force_lock, sc_dbg, sc_ant_sel, w_missed, replay_delay, psram_ops,
reg_reset_sweep, bypass_e2e, qspi_owner, spi_cdc, noise_trig, directed
two-packet re-arm) — all PASS, rc=0; two-packet re-arm cycle counts (PK1-1,
ARM-1, ARM-1b, PK2-1) unchanged, confirming the extra `ST_ACQ_SETUP` cycle
doesn't disturb functional timing. P&R signoff jobs 3403 (lat_timing_ref fix
only, worst path `packet_active → u_psram.sub[0]`, item 1's pre-existing
QSPI-decode residual) then 3404 (+ M_val fix, worst path moves to `sc_lock →
timing_ref[6]`, see new finding below — M_val cone itself confirmed closed, 0
remaining `u_pcfsm.M_val` violators), both `config_current_signoff.json`
(1200×1100/88%): DRC=0/LVS=0 clean both runs; SS WNS **−12.11 ns** (3403) and
**−12.11 ns** (3404, essentially flat — the M_val fix removed that specific
cone but the overall wall is now bounded by two other, already-present
residuals of similar magnitude). This is the best SS WNS in this item's
entire history (previous best was the CE-retimer's −14.71 ns, job 3400 in
`planning/ce-gated-quasi-static-retimer-experiment.md`, which never touched
this arc since it's not one of the CE-retimer's quasi-static `reg_bank`
sources). Netlist cross-check confirms the old `timing_ref → acq_timeout_q`
arc no longer appears anywhere in either run's violator list.

**New finding surfaced by this fix, NOT yet characterized or fixed:** with
the pcfsm write-arc and M_val cones both closed, `sc_lock → timing_ref[*]`
(inside `sc_detector`, 131 violators in job 3404, worst −12.11 ns — tied with
the `u_psram` residual) is now the dominant violator cluster. Traced
structurally: `sc_lock` and `timing_ref` are written in the same
`sc_detector.v` always-block guarded by `if (metric_valid_pulse && !sc_lock)`
— synthesis likely turns the `!sc_lock` qualifier into a mux-select feeding
`timing_ref`'s D input, making `sc_lock`'s own Q a genuine same-cycle input to
`timing_ref`'s compute. This is a different module and a different arc than
this item's `packet_ctrl_fsm` write-arc, was masked by larger violators until
now, and has never been traced before. Out of scope for this item — needs its
own root-cause pass before deciding an RTL or SDC fix, same as the
`Zpair_i/Zpair_q`, `ce_16m`, `dcr_valid` clusters item 40 already lists as
uncharacterized.

**Ported 2026-07-13** to `worktree-ce-gated-quasi-static-retimer`
(`planning/ce-gated-quasi-static-retimer-experiment.md`): same RTL change plus
both SDC exceptions (that branch was independently missing the
`M_val → timeout_regs` cone too, on top of the write-arc). Functional
regression (job 3405) all PASS, cycle-identical to mainline. P&R signoff
(job 3406) confirms the port itself is correct — neither `acq_timeout_q` nor
`M_val` appears in the violator list, and it even improved that branch's
separate `u_psram` residual (−14.71 → −6.08 ns) — but overall SS WNS
regressed to −17.97 ns because `training_armed` (training_acc's live,
packet-rate `armed` flag) and an internal `sd_remod` NTF-arithmetic cone both
got worse. Root-caused (see experiment doc): both clusters pre-date the port
(present already in job 3400, smaller) and are substantially worse on the
CE-retimer branch than on mainline even before the port — most likely the
retimer's own extra RTL (six retimed registers + free-running divider)
costing physical margin on unrelated paths, with the port's two closed cones
freeing up P&R repair effort that landed on `u_psram` but not on these. Not
caused by, but exposed alongside, the port. CE-retimer's merge recommendation
is downgraded pending this.

**New finding, out of scope for this item — see #40:** the dominant residual
SS wall (most of job 3367's 1206 violators, worst −16.01 ns) is now rooted in
`u_sc.*` (sc_detector) internals plus `packet_active`/`u_remod`/`u_psram`
fanout from `rb_bw_sel`/`rb_sf_cfg` — pre-existing (33 violators, −22.1 ns in
the July 5 baseline at the same die/density) but roughly 4× wider now.

**2026-07-26 correction:** the current canonical signoff SDC is
`pnr_32m_scoped_v25_b6.sdc`, not the legacy v20 filename. It preserves the
v24 `M_val` exception and re-points the packet-control endpoints to B6's
`acq_cnt`/`wpend_cnt`/`pkt_cnt`; both `src/config/` and the signoff config use
it. The historical B4/B6 v20 measurement therefore does not describe the
shipping constraint set.

### 15. Final SPI write lost if host raises CS too soon after last SCK edge — FIXED

**FIXED 2026-07-12** (`spi_slave.v`, commit `2b6af0f`). The one-SCK pulse
request (`spi_reg_we_req`) is replaced by a persistent toggle + bundled-data
mailbox (`spi_we_toggle`/`spi_wr_addr_lat`/`spi_wdata_lat`), reset only by
chip reset, not `HOST_CS`. A completed write byte now survives CS
deassertion indefinitely until the 32 MHz domain's two-FF synchronizer
observes the toggle change, removing the CS-hold-time dependency entirely.
Covered by `cocotb/spi_cdc/` (8 scenarios, SGE job 3352, all PASS), including
randomized clock-phase sweep and immediate-CS-deassertion back-to-back
writes. See `planning/spi-slave-cdc-and-10mhz-timing-plan.md`.

`spi_reg_we_req` (`spi_slave.v:70-118`) is cleared asynchronously by
`HOST_CS` rising; the 2-FF synchronizer needs ~3 × 31.25 ns of request
persistence, but at 2 MHz SCK the natural gap is ~250 ns. The persistent-toggle
fix remains required for safe frame teardown; it cannot be replaced by assuming
the request will survive CS de-assertion or documenting "hold CS low ≥ 100 ns after
the final SCK edge" as a hard host requirement (and add it to the RPi driver).

**Found:** 2026-07-02 trouper_top RTL review.

### 18. PSRAM-replay sample staleness — CLOSED 2026-08-29

`cocotb/trouper_capture` now records the exact decimated 8-byte sample tuple
accepted at the `psram_buf_ctrl` write boundary while replaying a labelled,
measured SF7/BW125 capture.  It then requires the first 32 `rpl_*` tuples to
match one and only one offset in `timing_ref ± 3`.  Job 5218 passed with the
defined relation `rpl[k] == recorded[timing_ref - 1 + k]` for all 32 samples.
This detects a stale packet base, byte-lane error, or replay sample slip using
a non-periodic measured waveform, avoiding the periodic-CW ambiguity in the
older RPV-6 test.  It closes the RTL replay-alignment question for the current
PSRAM architecture; it does not constitute board-level PSRAM timing/SI proof.

### 19. `tb_mrc_fw_precision.v` DUT/testbench mismatch — CLOSED 2026-08-29

Root cause was testbench timing, not RTL: it drove and sampled on `posedge`
and retained a 20-cycle output timeout from the pre-pacing combiner. The
current combiner accepts at state 0 then holds states 1–10 for three cycles
each, so its defined latency is 31 clocks. The race mixed the prior case's
output into the next case and sometimes timed out before the current output.

The bench now drives/samples on `negedge` and allows 40 clocks. All five
parametric Q0.7 precision cases pass bit-exactly (`make sim_mrc_fw_precision`,
2026-08-29). This restores the unit-level complement to the existing SPI
end-to-end oracle coverage.

### 44. 4.5 V-core signoff is P&R-proven but NOT adopted — CLOSED 2026-08-30 (uniform rail, no 4.5 V core)

2026-07-31: a full P&R targeting `ss_125C_4v50` with a 9 ns
`PL/GRT_RESIZER_SETUP_SLACK_MARGIN` closes clean on the current 1200×1100
signoff baseline — WNS 0.0/TNS 0 at all `STA_CORNERS`, worst slack +3.17 ns,
DRC 0, LVS clean (job 3738; see `planning/5v-core-voltage-strategy.md`
§2026-07-31). A bare corner swap without the margin still fails (−2.74 ns,
job 3737). This is real signoff-quality evidence that the 4.5 V-core
contingency (item 27) *can* close 32 MHz outright — but it does not, by
itself, make 4.5 V the production core voltage. Do not let
`config_current_signoff_4v50_margin.json` or its SDC become the canonical
signoff config/SDC until all of the following are resolved:

1. **IO voltage crossing** — **partially closed 2026-08-14** (job 4347, see item
   27): the functional question is answered — `bi_24t` down-shifts correctly with
   core above pad at every corner, and 4.5 V core / 3.6 V pad passes on levels,
   timing and static current (19.5 µA/pad worst case). What remains is
   structural, not functional: ESD/latch-up, power-on rail sequencing, and
   pad-ring IR drop, none of which a single-cell sim can answer, plus the
   still-true fact that there is no PDK IO databook. The high-speed
   bidirectional PSRAM QSPI still rules out auto-direction external translators
   as a fallback. Use 3.6 V for the pad ring, not 3.3 V — the wider 4.5/3.3
   split triples the receiver crowbar current.
2. **Power budget** — P∝V²; 4.5 V vs 3.3 V is roughly ~1.9× dynamic power,
   not checked against any board/thermal budget.
3. **Hold margin re-verification** — job 3738's worst hold at
   `ff_n40C_3v60` was +0.164 ns: positive, but thin, and not yet separately
   stress-tested with the 9 ns margin's extra setup buffering in place.
4. **Explicit team sign-off on the rail decision** — per the 2026-07-04
   project framing, uniform 3.3 V is the stated *aim*; the 4.5–5 V core is a
   *contingency* only. Adopting it is a tapeout-architecture decision, not a
   config-file change.

**Action:** treat `config_current_signoff_4v50_margin.json` as a validated
candidate only. Keep `config_current_signoff.json` /
`pnr_32m_scoped_v25_b6.sdc` (3.0 V) canonical until 1–4 above are closed and
someone with authority over the tapeout architecture makes the call.
**Blocks:** nothing yet (informational gate) — but prevents item 1 from being
quietly "closed" by a voltage change nobody explicitly approved.
**See:** item 1, item 27, `planning/5v-core-voltage-strategy.md` §2026-07-31.
**Found:** 2026-07-31.

**CLOSED 2026-08-30 — the rail decision has been made: no split rail, no 4.5 V core.**
`VDD_CORE` and `VDD_IO` stay tied to a single net (see item 27). A 4.5 V core is
only meaningful against a lower pad rail, so with the split off the table the
4.5 V-core path is not an option. If the SS gap needs more margin, **both rails
are raised together to ~3.5 V** — a uniform bump, which raises none of gates 1–3
above (no IO voltage crossing, ~1.1× rather than ~1.9× dynamic power, and no
4.5 V-specific hold re-verification). Gate 4 is hereby answered: the team
decision is uniform supply.

**Consequences:** `config_current_signoff.json` / `pnr_32m_scoped_v25_b6.sdc`
stay canonical; `config_current_signoff_4v50_margin.json` is retained as a
historical experiment only and must not be promoted. Item 1 (SS closure) can
no longer be closed by a 4.5 V corner swap — it must close on honest RTL/SDC
work plus at most a uniform ~3.5 V bump.
**Re-open if:** a split-rail supply is ever put back on the table, which would
also re-open item 27 and every structural unknown listed there.

### 27. GF180 split-rail IO cell (core > pad) down-level-shift is uncharacterized — CLOSED 2026-08-30 (split-rail not taken)

The baseline supply is **uniform 3.3 V** (core + IO). If the 32 MHz SS gap (item 1)
cannot be closed at 3.3 V, the **contingency** is a **split-rail supply**: run the
digital core at ~5 V nominal (4.5 V slow-corner worst-case, where SS closes — proven
SS@`ss_125C_4v50` = **+1.40 ns**, DRC/LVS/route 0, jobs 3231/3237) while the pad ring
signals at **3.6 V** so the 3.3 V-class external parts survive. This risk applies only
if that contingency is taken. All three externals are
safe at 3.6 V (APS6404L PSRAM abs max 4.0 V / SX1257 3.9 V / RPi GPIO ESD clamp ~3.9 V).
**The single unproven link is the IO cell itself:** GF180 `bi_*` cells must down-level-
shift core (5 V) → pad (3.6 V), but the PDK only characterizes single-voltage IO
(`VDD = DVDD`) and ships no IO databook — the core > pad down-shift is **outside the
characterized envelope**. If GF180 IO cannot safely do this split, the whole 5 V-core
strategy collapses; the fallback (uniform 5 V chip + external PCB level translators) is
hard for the **high-speed bidirectional QSPI** (PSRAM `SIO[3:0]`, up to 133 MHz, direction
reverses mid-transaction — auto-direction translators do not cope).

**2026-08-14 — SPICE half CLOSED, structural half still open (SGE job 4347).**
Transistor-level characterisation of `gf180mcu_fd_io__bi_24t` (the cell the shared
padring instantiates) over 63 scenarios — both directions, 3 corners × 3 temps,
5 rail splits — in `characterization/io_levelshift/` (`RESULTS.md`). **The
down-shift works:** every output scenario drives PAD to exactly the pad rail
(3.600 V at 4.5/3.6) with zero static current, at every split and corner —
the specific failure this item feared does not occur. The up-shift also reaches
the full core rail everywhere; its cost is *static current in the input receiver*,
which scales with the split and binds at ff/125 °C: 19.5 µA/pad at 4.5/3.6,
64.4 µA at 4.5/3.3, and 182 µA at 5.0/3.3 (the only failing case, against a
100 µA/pad budget). Receiver trip point stays 0.965–1.165 V throughout, well
inside the 0.4–2.4 V a 3.3 V driver guarantees. **Recommended split if the
contingency is taken: 4.5 V core / 3.6 V pad** — narrowest split that still buys
`ss_125C_4v50` closure, ~30× less crowbar than 5.0/3.3. Note the PDK's own
`pfet_06v0` W bin does not cover `bi_24t`'s 120 µm pad devices; the deck extends
it (documented deviation, `README.md`).

**Action (bench/foundry, not PnR — SPICE now done):** the remaining unknowns are
structural, not functional: ESD/latch-up across the split rail, power-on
sequencing (which rail rises first, and shifter behaviour while one is at 0 V),
and pad-ring IR drop. Confirm with foundry/databook before committing the
voltage path. Also cross-check `bi_t` (fits the stock model bin) to
independently rule out the extended-W deviation.
**Blocks:** committing the split-rail 5 V-core SS-closure strategy (item 1); the die-shrink
and honest-MCP work that the voltage path would otherwise unblock.
**See:** `planning/area-reduction-roadmap.md` §2 (voltage analysis); `planning/Pinout.md`
(split-rail supply note); `planning/5v-core-voltage-strategy.md`.
**Found:** 2026-07-04 (voltage-corner + external-part datasheet review).

**2026-08-19:** cell-level finding above is unaffected, but the reference padring's PDN
config ties `VDD_CORE`/`VDD_IO` to one net by default (no secondary domain declared, no
`brk` cells in the pad spec) — independence must still be built, it isn't already there.
Corrects `planning/Pinout.md`'s prior "separate, independently-tunable... deliberate"
framing. **See:** `planning/5v-core-voltage-strategy.md` §2026-08-19.

**2026-08-19 (part selection for the external-translator fallback):** dual-independent-
supply, direction-controlled translators (`VCCA` fixed 3.3 V, `VCCB` tied to `VDD_CORE`)
are the right category — `VCCA=VCCB` is a normal operating point, so the same BOM works
at 3.3 V/3.3 V today and 4.5–5 V/3.3 V later with no board respin. The PSRAM QPI bus needs
an explicit-`DIR` part (e.g. `SN74AVC4T774`/`74AVC4T245`), driven by `psram_buf_ctrl.v`'s
existing QSPI ownership signal — auto-sensing shifters (TXB/TXS0108-class) still don't
cope with its mid-transaction direction reversal, as already noted above. **See:**
`planning/5v-core-voltage-strategy.md` §"external level-shifter part selection".

**CLOSED 2026-08-30 — the contingency this item guards is not being taken.**
Design decision: `VDD_CORE` and `VDD_IO` stay **tied to a single net** (which is
what the reference padring PDN config already does by default — see the 2026-08-19
note above). If the SS gap needs more margin, both rails are raised **together to
~3.5 V**; the remaining SS shortfall is small enough that a modest uniform bump is
the lever, not a split. With no core > pad split there is no down-level-shift to
characterize, no cross-rail ESD/latch-up or power-on-sequencing question, and no
need for the external-translator fallback or its QSPI direction-control problem.
The SPICE characterisation in `characterization/io_levelshift/` remains valid and
is retained as reference should a split ever be reconsidered.
**Re-open if:** a split-rail supply is put back on the table (e.g. the 4.5 V-core
path of item 44 is revived), since every structural unknown listed above returns
unanswered.

### 20. `firmware/picorv32/asic_regs.h` was stale — CLOSED 2026-07-26

The header now uses the current 7-bit register map and configurable 128-byte
ASIC bank: `REG_WGT_CTRL=0x1E`, `REG_ZDIAG_0..3=0x64/0x67/0x6A/0x6D`. Its
`WGT_CTRL` comment was also extended for `W_COMMIT_LATE` (bit 4) and
`W_WR_REJECTED` (bit 5).

### 21. `energy_meas_coarse` contingency — CLOSED 2026-07-26

The block is no longer present in either RTL tree; removal is complete rather
than a future contingency. The associated per-branch RSSI risk is documented
as Low in `planning/per-branch-rssi-via-sx1302.md`.

### 30. PSRAM debug-read R=64 collision budget — CLOSED 2026-07-26

The R=128 header comments were corrected in both RTL trees. Directed
`dbg_write_collision` verification proves that a 31-cycle fetch exceeds the
20-cycle R=64 idle margin, so the collision and `SAMPLE_SKIP` are deterministic:
fetch data remains intact, the capture write is cleanly dropped, and capture
resumes normally (job 3550; full block regression job 3551). This is a
documented debug-use tradeoff, not an unresolved failure mode.

### 2. `sc_lock` never de-asserts — receiver is one-shot — CLOSED 2026-07-02

`sc_detector.v` set `sc_lock` on lock with nothing clearing it except RESETB
(no clear input existed, contra TRPR-SCD-014), so after the **first** packet
no further packets were ever acquired, trained, or noise-measured
(`packet_ctrl_fsm` needs a rising edge to restart; `training_acc` and the
noise-window accept re-arm only on `!sc_lock`).

**Fix:** added an `sc_clr` input to `sc_detector` wired to `packet_done_pulse`
(falling edge of `packet_active` = packet FSM returned to IDLE). It clears
`sc_lock`, `hit_count`, `first_hit_sample`, the per-symbol accumulators,
`sym_cnt`, and the TDM/eval engine state; `sample_count` is left free-running
to keep the `timing_ref` domain aligned across packets. All single-packet TB
instantiations tie `sc_clr` low.

**Verified:** `rtl-test/tb/tb_trouper_two_packet.v` (SGE job 3203, TB PASS,
10/10 checks) — `ARM-1` confirms `sc_lock` de-asserts at IDLE and `PK2-1`
confirms a second packet re-acquires. Baseline single-packet `tb_trouper_top`
still passes (job 3202). Spec TRPR-SCD-014 strengthened to mandate re-arm.

**Re-verified against real captured IQ data 2026-07-05:** the above was
synthetic-only. `rtl-test/tb/test_capture_two_packet.py` re-runs the same
PK1-1/ARM-1/PK2-1 sequence against a real 2-packet capture
(`lora_20260619_144822_SF7-BW250-gain30.npy`) via the cocotb capture-playback
harness. PASS (SGE job 3273, ~52 min Verilator run): PK1-1 first lock at
~35.3 ms, ARM-1 de-assert/re-arm ~75 ms later, PK2-1 second lock ~1.93 s
after re-arm.

### 3. Level-driven `IRQ_STATUS` bits are un-clearable (IRQ_OUT sticks high) — CLOSED 2026-07-02

`rb_irq_set` fed `training_done` and `sc_lock` in as *levels*; `reg_bank.v`
re-ORs `irq_set` every CE, so an `IRQ_CLEAR` write to CORR_LOCK/TRAINING_DONE
was undone two cycles later (violated TRPR-IRQ-002), and combined with item 2
`IRQ_OUT` stuck high permanently after the first lock.

**Fix:** `trouper_top` now edge-detects `sc_lock`/`training_done`
(`sc_lock_r`/`training_done_r` → `sc_lock_pulse`/`training_done_pulse`) and
feeds the 1-cycle rising-edge pulses into `rb_irq_set_c` bits 0/1, matching
the `packet_done_pulse` pattern on bits 2–4; the 2-cycle `rb_irq_set_d`
stretch still bridges the CE domain. After a pulse `irq_set` returns low, so
an `IRQ_CLEAR` write sticks.

**Verified:** `tb_trouper_two_packet.v` (SGE job 3203) — `IRQ-1c` clears
IRQ[0] while `sc_lock` is still asserted and confirms it stays clear (the
discriminating check vs the old level behavior); `IRQ-2` confirms re-clearable
on packet 2. New spec requirement TRPR-IRQ-006 documents the edge-set
semantics.

### 26. First SPI transaction after power-on corrupted (no POR on SPI-domain frame flops) — CLOSED 2026-07-02

The SPI-clock-domain frame flops in `spi_slave.v` (`spi_shreg`, `spi_bit_cnt`,
`have_cmd`, `fp_rw`, `cur_addr`, `spi_reg_we_req`, …) were reset **only** on
`posedge HOST_CS`. `HOST_CS` idles high from power-on with no rising edge until
the *end* of the first transaction, so the flops came up in an unknown state
and the **first** CS-low transaction was parsed against garbage — the first
register access was silently dropped/misdirected (self-healing on the first CS
rising edge). Distinct from items 15/16. Found while bringing up
`tb_trouper_two_packet` (job 3201 dropped the first PSRAM-enable write; a
throwaway CHIP_ID read masked it — job 3203).

**Fix:** folded chip reset into a single OR'd async-clear term
`spi_frame_arst = HOST_CS | ~rst_n` (one edge-sensitive reset, not two — a
dual `posedge HOST_CS or negedge rst_n` form is rejected by yosys with
"Multiple edge sensitive events", job 3207). The reset pin is level-sensitive
in silicon, so the frame flops are held cleared for the whole `rst_n=0` window
regardless of `HOST_CS` — no host/bring-up mandate needed.

**Verified:** yosys `synth` clean, exit 0 (job 3209, vs the dual-form's hard
error). `tb_trouper_two_packet` now passes with the PSRAM-enable write as the
**first** transaction — no warm-up read (job 3208, PSRAM INIT_DONE at cycle
384, 10/10 checks). (TB models the power-on reset by holding CS low across the
reset pulse purely so iverilog's edge-triggered async-reset fires; silicon does
not require this.)

### 31. `SF_CFG` (0x09) had no `PACKET_ACTIVE` write-gate — mid-packet SF change would desync sc_detector/training_acc — CLOSED 2026-07-05

`reg_bank.v:194` wrote `sf_cfg` unconditionally on any SPI write to `0x09`,
unlike `BW_CFG` (`0x0A`), which is explicitly blocked while
`packet_active=1`. Since `sf` feeds `psram_buf_ctrl`, `sc_detector`,
`training_acc`, and `sd_decimator_poly` (`trouper_top.v:237/285/372/417),
a mid-packet `SF_CFG` write would change the symbol length `M =
2^(SF+sample_shift)` those blocks use, live. `psram_buf_ctrl`'s SC delay-line
is defensively re-armed for exactly this case (`del_rdy`/`del_cnt` reset on
any `sf`/`sample_shift` change, `psram_buf_ctrl.v:286-301`), but
`sc_detector.v` and `training_acc.v` have no equivalent guard (grepped both —
no re-arm logic keyed on `sf` at all), so a mid-packet SF write would
silently desynchronize their symbol-boundary arithmetic rather than fail
safely. Found while deriving the k-induction bound for
`formal/psram_buf_ctrl_formal.sv`'s debug-fetch property, which required
establishing that `sf`/`sample_shift` are actually quasi-static during a
packet — they turned out not to be, for `SF_CFG` specifically.

**Fix:** gated `sf_cfg` the same way as `bw_sel`:
`8'h09: if (!packet_active) sf_cfg <= wdata[3:0];` (`reg_bank.v:194`).
`planning/Register Map.md` updated (`0x09` summary row + detail section) to
document the gate and the asymmetric risk if it were ever removed.

**Verified:** added a direct regression to `rtl-test/tb/test_trouper_top.py`
mirroring the existing `BW_CFG` write-lock check — attempts to flip all four
`SF` bits mid-packet and asserts the readback is unchanged. Ran via SGE
(`hqsub`, job 3267) on the full SF7/BW250 and SF7/BW125 scenarios in
`cocotb_trouper_top` (the only scenarios that reach `PACKET_ACTIVE` with the
full chain): `SF_CFG write-lock during packet OK` on both, 2/2 tests PASS.

### 32. `PSRAM_CTRL.PSRAM_EN` (0x70[0]) had no `PACKET_ACTIVE` write-gate — same class of bug as #31, found by formal k-induction — CLOSED 2026-07-05

`reg_bank.v:233` wrote `psram_ctrl[0]` (`PSRAM_EN`) unconditionally on any SPI
write to `0x70`, with no `packet_active` gate — the same bug class as #31's
`SF_CFG`, but this one was found by a **formal proof**, not a manual RTL
review: a k-induction counterexample against `psram_buf_ctrl.v`'s
`buf_active` invariant showed that if `psram_en` drops mid-packet (after
`buf_active` was already set on `sc_lock`), `buf_active` stays stuck at 1
with `psram_en` now 0 — an inconsistent state the RTL's own logic assumes
can't happen (`buf_active` only ever gets set guarded by `psram_en`, but
nothing re-checks or clears it if `psram_en` later changes).

**Fix:** gated `psram_ctrl[0]` the same way as `sf_cfg`/`bw_sel`:
`8'h70: if (!packet_active) psram_ctrl[0] <= wdata[0];` (`reg_bank.v:233`;
`psram_ctrl[1:3]` — `CLR_ERR`/reserved-inert bit[2] (formerly documented as
`SAMPLE_WIDTH`)/`QSPI_OWNER` — left ungated,
matching their own documented semantics). `planning/Register Map.md` `0x70`
detail section updated with the same gate note as `SF_CFG`/`BW_CFG`.

**Verified:** full SF7-SF12 x BW250/125 cocotb sweep under Verilator (SGE job
3269, then re-confirmed job 3270 with full-depth `full=True` coverage at
every SF — see item below), 12/12 PASS both times, no regression from the
gate. Not a direct regression test of the gate itself (unlike #31's
`SF_CFG` write-lock check) — the formal proof is the actual verification
here; a matching cocotb write-lock regression for `PSRAM_EN` would be a
reasonable follow-up but wasn't added this session.

**Formal-verification effort, scope and status (2026-07-05):** this bug, and
#31, both came out of a broader session-long push to get real k-induction
proofs working against `psram_buf_ctrl.v` — worth recording here since
nothing else in `planning/` points at it. Key facts for anyone picking this
up:

- **Toolchain gotcha:** this project's yosys version (0.64, in the
  `chipathon26` container) silently drops SystemVerilog `bind` statements —
  no error, no warning. Every earlier attempt at binding a formal checker in
  via `bind` was checking zero properties (confirmed empirically: an
  unconditionally-false assertion still reported "PASS"). The working
  pattern is a direct `` `ifdef FORMAL `` instantiation of the checker module
  inside `psram_buf_ctrl.v` itself, right before its `endmodule` — dead code
  in every real build (`read_verilog` only defines `FORMAL` when passed
  `-formal`; LibreLane/cocotb never do), verified with a deliberate
  trivially-false assertion that it's actually caught (`FAIL`) when using
  this mechanism.
- **Location:** `formal/psram_buf_ctrl_formal.sv` (checker + properties) and
  `formal/psram_buf_ctrl.sby` (SymbiYosys run config, `mode prove`, depth 90).
  Run via `sby -f psram_buf_ctrl.sby` inside the `chipathon26` container.
- **Proven** (k-induction, both basecase and induction, current state):
  pointer/overflow-bound reasoning for the same-packet replay gap, sticky-
  flag causality (`replay_missed`, `sample_skip`), FSM state legality,
  `buf_active`/`replay_active` state-correlation invariants, QPI bus-driving
  safety (no contention during dummy cycles), SC delay-line warm-up
  correctness, and the `back_bytes` truncation-safety property (a genuine
  32-to-23-bit silent-truncation risk in `psram_buf_ctrl.v:397`, found via a
  Verilator `WIDTHTRUNC` lint warning, not previously guarded by any
  assertion).
- **Parked, NOT proven, NOT confirmed as bugs** (disabled in the file with
  full explanation, not deleted): (1) the PSRAM debug-fetch bounded-response
  property — needs an explicit launch-phase latch to separate the "waiting
  on packet_active" phase from the fixed 31-cycle execution phase, which a
  flat or relational counter bound can't cleanly express; (2) the overflow-
  unreachability property, which regressed after later environment
  assumptions were added and was not root-caused. Both are corroborated as
  likely proof-modeling gaps rather than real hardware defects by the full
  functional cocotb sweep (job 3270, 12/12 PASS at full depth) never
  triggering either condition, plus (for overflow specifically) the original
  analytical derivation — the replay backlog would need to land within 8
  bytes of a 2^23 wraparound, while real backlogs are bounded to <=1048576
  bytes (TRPR-PSR-015, >=8x headroom) — still holding unchanged.
- Two environment-modeling gaps had to be fixed along the way that are worth
  knowing about if extending this file: `sf`/`sample_shift` and `iq_valid`
  are free primary inputs to `psram_buf_ctrl.v` in isolation, so this proof
  had to explicitly assume the real chip's actual constraints on them
  (`sf` in 7-12, `sample_shift` in {1,2}, `iq_valid` periodic every 64
  cycles) — without those, the solver finds "valid" counterexamples using
  input combinations the real chip can never produce.

### 28. No signoff run uses the fixed / PCB pin order — DRT-0073 hazard — CLOSED 2026-07-05

`config_current_signoff.json` set no fixed pin-order config, so every signoff and
experiment to date (B1 −16.08 ns, the buffering study, the 5 V-rail runs) placed the
block port pins **automatically** — the router put them wherever was convenient. A
tapeout-ready macro needed to instead pin the ports where the padring/PCB expects
them, and forcing a fixed order had previously tripped DRT-0073 (`IQ_CLK` clkbuf
pin-access) on tighter baselines.

**Fix:** `io_placement_bl.cfg` — a fixed, PCB-realistic pin order (all real board pads
on S+W edges: `IQ_DATA[3:0]` I/Q + `IQ_CLK` + `PSRAM_*` on S; `RESETB`/`HOST_CS`/SPI/
`IRQ_OUT`/`REMOD_A_I/Q` on W; Grouper's inter-project bus, which carries no package
pads, pushed to E+N) — routes DRT=0 with **zero** board pads on the Grouper-only
edges. Confirmed across the full post-B1 die-width sweep with fixed pins (jobs
3250–3253): 1200×1100 is the fixed-pin routable floor (DRT/magic/LVS=0), one 50 µm
step above the 1150×1100 auto-pin floor — fixing pads to board-friendly edges costs
the router some congestion headroom, but 1200×1100 absorbs it cleanly.

`config_current_signoff.json` was updated the same day to `DIE_AREA=1200×1100`,
`IO_PIN_ORDER_CFG=dir::io_placement_bl.cfg` and remains the active signoff config —
this is the same run (`RUN_2026-07-05_00-56-34`, DRC=0/LVS=0) item 1 already cites as
the current chip-wide signoff baseline, so this item was effectively resolved the day
after it was opened; the Open Risks entry itself just hadn't been updated to reflect
it until now.

**Verified:** SGE jobs 3241 (1380×1100 fixed-pin confirmation) and 3250–3253 (fixed-pin
width sweep); `config_current_signoff.json` still carries `IO_PIN_ORDER_CFG` today.
**See:** `planning/die-shrink-routability-floor.md` §6–8 (`io_placement_bl.cfg` is the
"PCB-realistic" pin order referenced there); `rtl-test/ol_trouper_top/io_placement_bl.cfg`.

### 10. DC Removal: documented spec figures contradicted by verified sim results — CLOSED 2026-07-11

`planning/blocks/DC Removal.md`'s verification table claimed AC passband
droop < 0.1 dB at a 1 kHz test point, and reset-recovery settling to < 1 LSB
within 37 samples. `planning/DSP Chain SNR Loss Budget.md`'s bit-exact model
measured −8.5 dB droop at 1 kHz and 119 samples to < 1 LSB (64-code offset)
— both contradicting the doc. Flagged as an unreconciled doc-vs-sim
mismatch, not (at the time) confirmed as either a real RTL defect or a
doc-only error.

**Root cause (not an RTL defect):** both numbers in the block doc were
simply wrong test criteria, not RTL bugs:
- 1 kHz sits *inside* the DC-removal filter's own transition band (α=1/32
  gives a ~2.45 kHz corner) — droop there is legitimately large by design;
  the doc's own `TRPR-DCR-010` requirement ("< 0.1 dB across the LoRa
  signal band") was never actually violated, since the real LoRa signal
  band sits well above the corner. The block doc's test table had just
  picked an unrepresentative test frequency.
- 37 samples only reaches ≈68% settled for τ=32 — nowhere near < 1 LSB.
  The measured 119 samples (≈98.4% settled for a 64-code offset) is
  consistent with, not contradictory to, the doc's own correct ~74-sample/
  90%-settling figure elsewhere in the same file (`TRPR-DCR-005`/
  `TRPR-DCR-013` in the Chip Specification carry the correct 74-sample/90%
  number and were never wrong — only the block doc's separate verification-
  table entry was).

**Fix:** `planning/blocks/DC Removal.md` verification table corrected —
AC passband test point moved to 50 kHz (clear of the transition band, still
< 0.1 dB as designed); reset-recovery criterion corrected to 119 samples.
Added a note in the doc so the 1 kHz transition-band behavior isn't
rediscovered as a bug later.

**See:** `planning/DSP Chain SNR Loss Budget.md` §2 (bit-exact measurements);
`planning/blocks/DC Removal.md` (fixed verification table).

### 17. Noise Estimation Manhattan-norm bias/variance not quantified — CLOSED (superseded) 2026-07-11

`noise_est.v` used an L1 (Manhattan) approximation instead of an ideal L2
norm for `energy_snap`; the resulting bias/variance was never measured
against an ideal estimator.

**Disposition:** not fixed — **moot**. `noise_est.v` is dead code: it is not
instantiated in `trouper_top.v` (removed per the "Legacy energy-snapshot
path removed" comment at the old instantiation site) and not referenced by
the current signoff config. Noise qualification is now done entirely by
`training_acc`'s firmware-triggered noise-mode window (`TACC_NOISE_TRIG`)
plus the SC-contamination gate (`NOISE_READY` IRQ) — see CLAUDE.md's system
summary and `planning/Remove Noise Floor Estimator Migration Plan.md`. There
is no live Manhattan-norm estimate left to quantify. The source files
(`rtl-test/rtl/noise_est.v`, `noise_est_bb.v`) are still physically present
but orphaned — left in place for now rather than deleted; candidate for the
same cleanup pass as the other dead-logic items in Open Risks #25.

**See:** `planning/DSP Chain SNR Loss Budget.md` §5 (updated to match).

### 4. Bypass-antenna mux skips antenna 0 — CLOSED 2026-07-05

`trouper_top.v`'s `bypass_ant` mux tested `active_antenna_en[1..3]` and fell
back to 0, never actually testing bit 0 first — so with the reset default
`antenna_en=0xF` bypass mode selected **antenna 1**, not the lowest-enabled
antenna (TRPR-SYS-005, TRPR-MRC-005).

**Fix:** rewrote as an explicit lowest-bit priority mux:
```verilog
wire [1:0] bypass_ant = active_antenna_en[0] ? 2'd0 :
                        active_antenna_en[1] ? 2'd1 :
                        active_antenna_en[2] ? 2'd2 : 2'd3;
```

**Verified:** new regression `rtl-test/tb/test_bypass_antenna.py`, 4 cases
(all-enabled, skip-0, skip-0/1, only-3), each driving a full reset + SF7/
BW250 lock cycle with PSRAM enabled (required — `psram_buf_ctrl.v` is the SC
detector's delay line, so `sc_lock` can't fire without it) and reading
`active_antenna_en`/`bypass_ant` off the internal wires post-lock. 4/4 PASS
(SGE job 3276).

### 33. Weight-gen SPI flow verified end-to-end; two real findings along the way — CLOSED 2026-07-05

Built `rtl-test/tb/test_weight_gen_spi_flow.py`, a full closed-loop test of
the weight-generation path an off-chip MCU actually exercises: `sc_lock` →
`training_done` (IRQ) → SPI-read `Z_kl`/`Zdiag` (`0x40`–`0x6F`) →
firmware-accurate eigenvector computation (`sim/models/eigvec_fw.py`,
`compute_eigvec_fw`) → SPI-write `W_SHADOW` (`0x30`–`0x3F`) → `W_COMMIT` →
`W_VALID` → combiner output compared bit-exact against an independent
oracle (`sim/models/receiver.py`, `nonfft_combine_rtl_int8w`). Uses a real
4-antenna capture with distinct per-antenna gains
(`lora_20260619_144822_SF7-BW250-gain30.npy`, `gains_db=[0,-3,-6,-9]`) so the
computed weights are non-trivial. **Final result (SGE job 3286): PASS,
`best_lag=0`, `max_err=0.00`** — bit-exact match.

Getting there took ~10 SGE job iterations and surfaced three real findings,
not just test bugs:

- **Undocumented precision cliff:** `mrc_combiner.v` takes `signed [7:0]`
  weight inputs — only the HI byte of each `W_SHADOW` Q1.15 pair
  (`0x30`/`0x32`/… ) actually reaches the combiner; the LO byte is write-only
  and silently discarded. Nothing in `planning/Register Map.md` said this.
  Documented in the `0x30`–`0x3F` section.
- **Z-matrix reconstruction bug (test-side, not RTL):** the test's readback
  helper was left-shifting the `Zdiag` readback by 8 bits before handing it
  to `compute_eigvec_fw`, an artifact of an older 16-bit `Zdiag` truncation
  scheme that no longer applies (current scheme is already 8-bit-scaled).
  Produced plausible-looking but wrong weights (`[0.9999, 0.0038, ...]`
  instead of `[1, 0.71, ...]`) until caught by comparing against the
  firmware model directly.
- **Stale NFS staging copy of `sim/` (process gap, not RTL):** SGE jobs run
  against `/srv/eda/designs/timothyjabez/lora-mimo/`, a copy separate from
  the local repo. All session-long syncing had only ever `rsync`'d
  `rtl-test/`, never `sim/` — so the container's `sim/models/receiver.py`
  and `sim/models/eigvec_fw.py` were months-stale, still using a deprecated
  combiner shift formula (`(acc_i >> 1) << post_gain_shift` instead of
  `acc_i >> (8 - post_gain_shift)`). With `post_gain_shift=0` this divides by
  2 instead of 256 — massive overflow that saturates to exactly the `-128`
  symptom seen in the failing runs. Cost the most debugging time of the
  three: identical inputs reproduced correctly when run manually on the host
  but failed inside the SGE container, which only made sense once the NFS
  copy was diffed against the local one. **Lesson for any future SGE job
  whose test imports from `sim/`: sync `sim/` too, not just `rtl-test/`** —
  there is no automatic sync of the whole repo, only whatever directories
  each run script's `rsync` invocation names.

---

(Move items here as they're resolved, with the closing evidence — job ID,
commit, or doc reference.)
### 34. `W_MISSED_PACKET` register readback was firmware-invisible — CLOSED 2026-07-06

`packet_ctrl_fsm.v`'s `W_missed_packet` is a 1-cycle pulse consumed by the IRQ
edge-set path — and `trouper_top` wired that same pulse straight into
`reg_bank`'s combinational `w_missed_rb`. `PACKET_STATUS[7]` (0x1C) and
`WGT_CTRL[3]` (0x1E), both documented in `Register Map.md` as readable status
bits, therefore always read 0 to firmware (a 1-clock race is unwinnable over
SPI). Only the sticky `IRQ_STATUS[2]` captured the event.

**Fix:** sticky per-packet `W_missed_q` output in `packet_ctrl_fsm.v` — set at
both miss sites (ACQ timeout, W_PENDING timeout with `!W_valid`), held through
IDLE so firmware can still read it after `PACKET_DONE`, cleared at the next
packet start (both the IDLE and back-to-back PAYLOAD→PREAMBLE re-lock paths).
The pulse still feeds the IRQ path unchanged.

**Verified:** `cocotb/tests/test_w_missed_packet.py` (Verilator, SGE job 3305)
— also the first regression for the TRPR-PCF-005 `46e1da0` miss-path fix
itself: miss IRQ on a withheld `W_COMMIT`, sticky readback at both register
positions across W_PENDING/PAYLOAD/IDLE, bypass payload, `PACKET_DONE` IRQ,
clear-on-next-lock.

### 35. `SC_DBG_FLAGS.SC_HIT` had the same pulse-readback bug; `RX_GAIN_CTRL` "commit-pending" readback was fiction — CLOSED 2026-07-06

A pulse-vs-level audit of every `reg_bank` status input (prompted by #34)
found one more instance and one doc fiction:

- `sc_detector.v`'s `sc_hit_dbg` is default-cleared every clock (1-cycle
  pulse, correct for its internal consumer — the noise-window contamination
  latch), but it also fed `SC_DBG_FLAGS[0]` (0x26) directly → firmware always
  read 0. **Fix:** new `sc_hit_hold` — the most recent symbol evaluation's hit
  decision, held until the next evaluation, cleared on reset/`sc_clr` — wired
  to the register readback; pulse unchanged.
- `RX_GAIN_CTRL` (0x18[0]) claimed to "read back commit-pending", but the W1P
  auto-clears after one CE period and the shadow→active latch completes within
  one clock — no pending state is ever observable. **Fix:** readback hardwired
  to 0 (matching `WGT_CTRL[0]`), `rx_gain_pending` port and loopback deleted,
  Register Map reworded. All other status inputs audited clean (level or
  sticky at source).

**Verified:** `cocotb/tests/test_sc_dbg_flags.py` (Verilator, SGE job 3307) —
SC_HIT/SC_LOCK/hit-counter bits, nonzero `SC_STAT`, and
`SC_LOCK_SNAP == SC_FIRST_HIT + M` with `SC_HITS_REQ=1`; plus zero baseline
for 0x24–0x2F before the delay line exists. `tb_trouper_spi.v`'s
RX_GAIN_COMMIT self-clear check unaffected (asserts the bit reads 0).

### 36. `sc_detector` sample_count double-counted after the PSRAM delay-line migration — `timing_ref` in wrong units, error grew over the session — CLOSED 2026-07-06

Found by `test_sc_dbg_flags.py`'s `SC_LOCK_SNAP − SC_FIRST_HIT == M` assertion
(measured 2M). `sc_detector.v` counted each sample **twice** once delayed
samples flowed: once via the `iq_valid_r && !delayed_valid_r` path — written
for the old on-chip-SRAM delay line where delayed data arrived in the same
cycle as `iq_valid`, but `psram_buf_ctrl` asserts `del_valid` ~44 clocks later
so the guard passed for every sample — and again at TDM step 7 when the
delayed sample was processed.

Consequences: `eval_sample_mark`, `timing_ref`, `SC_FIRST_HIT` and
`SC_LOCK_SNAP` were in inflated units relative to `iq_samp_cnt` (packet FSM
timeouts) and `training_acc`'s own 1× counter. The skew was ~2 symbols by the
first lock (why every synthetic/stationary-CW test passed) but **grew with
session time**: a packet locking at true sample T got `timing_ref ≈ 2T`, so
packet-2+ training windows and FSM timeouts landed ~T samples late — the
two-packet tests only checked IRQ ordering and never caught it.

**Fix:** count each sample exactly once, at its `iq_valid_r` (keeping the
`iq_inc_pending` deferral so an increment never lands mid-TDM-burst before the
boundary mark latches); TDM step-7 increment removed; `eval_sample_mark`
becomes the plain count (was `+1` — same 1-based index, verified equivalent
for the legacy same-cycle-delay testbenches).

**Exposed design semantics, not a bug:** with correct units, `timing_ref`
points at the start of the locking-hit window — *before* `sc_lock` — and
`training_acc` accumulates forward from arming, so the window's first
`SC_HITS_REQ+1` symbols are never accumulated: `n_acc = 7M−1` at the default
8-symbol window with 1-hit lock, not `8M`. The old `n_acc == 8M` test
expectation encoded the counter bug (window pushed 2 symbols late, fully
forward-reachable by accident). Z is normalized by the `n_acc` readback, so
the partial window is functionally correct; `test_trouper_top.py`'s
expectation updated to `7M−1`.

**Verified:** SGE jobs 3307/3308 (sc_dbg delta==M, w_missed, bypass_e2e, SF7
BW250/125 full scenario with corrected `n_acc`, synthetic two-packet re-arm)
and job 3309 (real-capture two-packet re-arm — the packet-2 case where the
old skew was worst).

### 37. `QSPI_OWNER` handover glitched pads mid-burst and never suspended REPLAY — CLOSED 2026-07-06

Writing the first-ever PSR-010/011 test exposed two bugs in
`psram_buf_ctrl.v`'s ownership handover:

1. `sck_en` was gated by the **raw** `qspi_owner` — a request landing
   mid-burst froze SCK immediately while the internally-stepping burst kept
   CE# low and SIO driven for up to ~40 cycles: a selected, unclocked,
   still-driven device during a bus handover, exactly the pad glitch
   TRPR-PSR-011 prohibits. **Fix:** `qspi_owner_eff`, latched only between
   bursts — an in-flight transaction completes with its clock running; new
   bursts are blocked by the raw bit at every launch site.
2. `S_REPLAY`'s burst launch had **no `!qspi_owner` gate** (S_WRITE's did) —
   an owner request during REPLAY never suspended the replay bursts at all.
   **Fix:** gate added.

Spec cleanup in the same pass: PSR-011's "effect only at `STATE=IDLE`"
referenced a state that doesn't exist (reworded to "at the next QPI burst
boundary"), and PSR-012's `PAD_CONFLICT` was REMOVED (never implemented;
single-master design has no on-chip conflict case).

**Verified:** `cocotb/tests/test_qspi_owner.py` (job 3314) — per-clock
CE#-low ⇒ SCK-enabled invariant through buffering and replay handovers,
release within 8 clocks, 256-clock hold, DBG_BUSY under owner=1, resume on
release. `psram_ops` re-passed and the SymbiYosys k-induction proof
re-proves clean on the modified RTL (same job).
