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

---

## Critical

### 1. Chip-wide SS-corner (32 MHz, `max_ss_125C_3v00`) closure is not on production RTL

The `gf180mcu_fd_sc_mcu7t5v0` FD cells fail 32 MHz timing at the slow corner.
The current production RTL has an SS setup WNS in the **−12 to −15 ns** band
(best **−12.11 ns**, jobs 3403/3404; repeated 2026-07-25 runs **−14.91 ns**,
TNS −5747 ns). The decimator's
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
The config-relaxed netlist needed to carry this fix currently **fails
detailed routing** (DRT-1231 / DRT-0073) on every floorplan tried — the
current floorplan has no routability headroom to absorb the SDC change.

**Blocks:** any honest chip-wide SS signoff; die-shrink work (blocked on the
same routability issue).

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

---

## High

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

### 6. DRT-1231 clkbuf CTS pin-access failure is recurring, not proven robust

A minimal fix is confirmed clean at 1380×1100 (v15c), but the same DRT-1231
violation (`clkbuf_*_IQ_CLK_regs/I` pin access) **returns** under the
honest-MCP/scoped-SDC config (v24, job 2211) and at every relaxed-SDC
floorplan tried since (jobs 2165–2168). Described in the source doc as
"timing-SDC-sensitive" — the fix does not generalize across SDC edits.

**Blocks:** further die-shrink; the honest-MCP signoff configuration (item 1).
**See:** `planning/area-reduction-roadmap.md` §4 (Gate 0 blocker);
`planning/ss-corner-decimator-pacing-closure.md`.

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

### 27. GF180 split-rail IO cell (core > pad) down-level-shift is uncharacterized

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

**Action (bench/SPICE/foundry, not PnR):** confirm GF180 `bi_*` split-rail level-shift
(5 V core / 3.6 V pad) via IO-cell SPICE + foundry/databook before committing the voltage
path.
**Blocks:** committing the split-rail 5 V-core SS-closure strategy (item 1); the die-shrink
and honest-MCP work that the voltage path would otherwise unblock.
**See:** `planning/area-reduction-roadmap.md` §2 (voltage analysis); `planning/Pinout.md`
(split-rail supply note); `planning/5v-core-voltage-strategy.md`.
**Found:** 2026-07-04 (voltage-corner + external-part datasheet review).

### 44. 4.5 V-core signoff is now P&R-proven but NOT a decided architecture — gate before canonicalizing

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

1. **IO voltage crossing** — same open question as item 27: GF180 `bi_*`
   split-rail core>pad down-shift is uncharacterized (no PDK IO databook), and
   the high-speed bidirectional PSRAM QSPI rules out auto-direction external
   translators as a fallback.
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

### 29. Grouper/AHB-Lite bus has no CDC — relies on an implicit same-clock assumption

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

### 38. Host SPI 10 MHz timing is not constrained or signed off — CDC portion FIXED, SDC portion open

**Partially fixed 2026-07-12:** the persistent toggle/mailbox CDC (commits
`2b6af0f`, `fef30de`) closes the RTL half of this risk's Action item and
Open Risk #15 outright — see above. The SDC half (declaring `SPI_SCK`,
SCK-relative MOSI/MISO I/O delays, `SPI_SCK`/`IQ_CLK` asynchronous-clock
exceptions, mailbox settling constraint) is still open:
`src/config/pnr_32m_scoped_v25_b6.sdc` is the canonical signoff SDC. Remaining scope tracked as
Implementation order steps 6-8 in
`planning/spi-slave-cdc-and-10mhz-timing-plan.md`.

The production SDC declares only `IQ_CLK` and globally false-paths
`SPI_SCK`. It also constrains `SPI_MOSI` relative to `IQ_CLK`, even though MOSI
is captured by `SPI_SCK`-clocked flops. Consequently, STA does not prove the
advertised 10 MHz SPI interface: SCK-domain register paths, MOSI setup/hold,
and the falling-edge `SPI_MISO` output timing are either hidden or referenced
to the wrong clock.

The most critical read path has only half an SCK period: the command address
completes on its eighth rising edge, the asynchronous `reg_bank` peek decode
must settle, and the MISO shifter loads on the following falling edge (50 ns at
10 MHz, before pad/PCB/host margin).

**Risk:** a design that passes the current top-level timing reports can still
fail register reads or writes at the specified 10 MHz on silicon.

**Action:** declare a 100 ns
`SPI_SCK` clock; add SCK-relative MOSI and MISO I/O delays; declare SCK and
`IQ_CLK` asynchronous while excepting only the intentional synchronizer paths;
constrain the bundled mailbox crossing; and run all-corner setup/hold plus
unconstrained-path review. Derive board I/O delays from the Raspberry Pi, PCB,
and GF180 pad timing rather than guessing them.

**See:** Open Risk #15; `src/control/spi_slave.v`;
`src/config/pnr_32m_scoped_v25_b6.sdc`;
`planning/spi-slave-cdc-and-10mhz-timing-plan.md`.
**Found:** 2026-07-11 (10 MHz SPI implementation/constraint research).

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

### 41. Hold signoff corner pulls the wrong RCX deck; the corrected (min_ff) config fails routing at signoff density

`max_ff_n40C_3v60` extracts with a `.max` RCX ruleset, so hold is checked
against pessimistic-setup RC, not true min-RC. The working fix is an
`RCX_RULESETS` override to add a real `min_ff_n40C_3v60` corner — renaming
the corner instead breaks P&R (jobs 3423/3426). **New 2026-07-18:** the
carrier config (`config_current_signoff_minff.json`) **fails GRT-0116
congestion** at 1200×1100/88 % (job 3464) — min_ff hold buffering pushes the
design past routability, while the plain max_ff config routes clean. The RCX
fix is therefore currently unusable at signoff density; needs either lower
util, a smaller hold-fix scope, or die growth.

**See:** `rtl-test/ol_trouper_top/config_current_signoff_minff.json`;
`planning/b4-b6-area-cuts-2026-07.md` §4.
**Found:** 2026-07-15 (ruleset), 2026-07-18 (congestion, job 3464).

---

## Moderate

### 9. SC Detector acquisition is single-antenna at any instant (no diversity at lock time)

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

**Mitigation added 2026-07-11:** `BW_CFG.sc_ant_sel` (`reg_bank` 0x0A[2:1])
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
persistence, but at 10 MHz SCK the natural gap is only ~50 ns. Either make
the request survive CS de-assertion or document "hold CS low ≥ 100 ns after
the final SCK edge" as a hard host requirement (and add it to the RPi driver).

**Found:** 2026-07-02 trouper_top RTL review.

### 16. Grouper/SPI register-bus arbitration silently drops SPI writes

`trouper_top.v:578-581`: if `GRP_RE`/`GRP_WE` is asserted during the 2-cycle
SPI write window, the mux steers away and the SPI write vanishes — no
stall/queue as TRPR-SPS-007/TRPR-INT-003 require. Additionally the implicit
Grouper contract (hold `GRP_WE` ≥ 2 clocks for the CE latch; no write-side
`GRP_READY` handshake) is undocumented.

**Found:** 2026-07-02 trouper_top RTL review.

**Resolved:** 2026-08-04, regression job 3863. `trouper_top.v` now captures each completed SPI
write in a one-entry pending slot and commits it after the higher-priority
Grouper byte cycle releases. The byte-cycle contract requires release before a
second SPI data byte completes (≥ 800 ns at 10 MHz). Because pin-level SPI has
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

## Low

### 18. PSRAM-replay sample staleness unquantified

**Retitled/repointed 2026-07-11:** originally filed against
`frontend_buf_ctrl.v`, which is dead code — not instantiated in
`trouper_top.v`, replaced by `psram_buf_ctrl.v` (see CLAUDE.md system
summary). The underlying question is still real and still unanswered: does
same-packet PSRAM replay (`psram_buf_ctrl.v` `S_REPLAY`, `rpl_i*/rpl_q*`
feeding the combiner) introduce measurable sample staleness relative to the
live path, and has that been quantified? Not yet investigated against the
current PSRAM-based architecture — this entry just points at the right
module now instead of the removed one.
**See:** `planning/DSP Chain SNR Loss Budget.md` §4 (still titled/framed
around the old `frontend_buf_ctrl.v`, needs the same retarget).

### 19. `tb_mrc_fw_precision.v` testbench has a pre-existing DUT/testbench mismatch

4 of 5 cases fail with `y_valid` timeout / large output error, confirmed
identical on unmodified git-HEAD RTL (SGE jobs 3194/3195) — i.e. not caused
by the ZDIAG register-widening change made alongside it. Root cause not
investigated; out of scope when found.

**Verification-coverage gap, not a silicon risk** — the testbench doesn't
currently exercise this path correctly, so a real regression there could go
undetected.

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
(`reg_bank.v`) yet read back and forwarded; a `noise_trig` written while a
live training is armed is silently swallowed (top opens
`noise_window_active`, `training_acc` ignores the arm — TODO in
`trouper_top.v`); `mrc_combiner.v:126` assigns `26'sd0` to an 18-bit reg;
`mrc_combiner` port `clk_16m` is actually driven at 32 MHz.

**Found:** 2026-07-02 trouper_top RTL review.

---

### 27. Power-on / startup sequencing has no on-chip enforcement — unverified in silicon

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

**Found:** 2026-07-05, while investigating PSRAM QSPI clocking margin.

**Testbench added:** `cocotb/tests/test_startup.py` (6 tests, all PASS,
SGE job 3257) — first-transaction-after-reset at 3 clock phases (regression
for item 26), the tPU-race and tRST-margin characterizations above, and the
SC hold-off check. Items 1 and 3 remain open (no on-chip fix, by design
pending firmware/board discipline); item 2 is downgraded from risk to
regression coverage; item 4 is confirmed working as intended.

**Next steps:** first hardware bring-up on the test PCB (a few weeks out)
will validate items 1 and 3 against a real PSRAM part and real RESETB
behavior — sim can characterize the digital logic's assumptions but not the
analog reset/power-rail behavior itself.

---

## Closed

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
