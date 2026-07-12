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

The `gf180mcu_fd_sc_mcu7t5v0` FD cells fail 32 MHz timing at the slow corner —
worst-case blanket-`MCP=3` SS setup WNS was **−11.95 ns**. The decimator's
share of that has been honestly closed (pure 3-cycle pacing + fanout fix, SS
WNS **+8.0 ns MET**, SGE job 2149), and sc_detector/training_acc have paced
fixes too, but **all of this lives on branch `ss-mcp-pacing`, not merged**.
The one remaining genuine (non-paceable) residual, the `u_psram` QSPI control
decode (≈ −10 to −13 ns, throughput-bound — needs a 1-cycle-ahead pipeline of
the `state`/`sub` → `sio_out`/address cone), is analyzed but not implemented.
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

**See:** `planning/ss-corner-decimator-pacing-closure.md` (Open Items),
`planning/5v-core-voltage-strategy.md` (§2026-07-05 re-confirmation).

(Items 2 and 3 — `sc_lock` one-shot and un-clearable `IRQ_STATUS` bits —
were fixed and verified; see Closed.)

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

### 7. Eigenvector power-iteration firmware timing does not fit SF7/SF8 (live mode)

**Cycle-accurate measurement 2026-07-11 (SGE jobs 3333–3335) — worse than estimated.**
The weight kernel run on the real `picorv32.v` (slow non-`FAST_MUL` multiplier,
corrected 7-bit-map kernel with faithful MMIO ingest) costs **33,283 cyc = 2.08 ms
@16 MHz** for the 8-iteration default on rv32im (36,458 cyc = 2.28 ms on the
Grouper's rv32emc/RV32E core, ~+10% from 16-register spilling), SF-independent —
**~2× the old ~1.0–1.1 ms back-of-envelope**, which had wrongly assumed ~1 cyc/instr
for the non-multiply work (real CPI ≈ 10). Against the live-mode deadline
(`4·M/500 kHz`): **SF7 (~1.02 ms) and SF8 (~2.05 ms) both miss on both ISAs; only
SF9+ fits.** 16 iterations (~3.88/4.28 ms) needs SF9+ (rv32im) or SF10+ (rv32emc).
The 24-bit ZDIAG widening is timing-neutral (−30/−54 cyc). PSRAM replay mode
sidesteps the deadline entirely (`W_COMMIT` can arrive any time up to `packet_end`)
and is therefore **mandatory for SF7/SF8 MRC gain, not optional**; this risk is
specifically about the live-mode (no same-packet replay) path.

**Risk:** silently missing the weight-computation deadline at SF7/SF8 in live
mode, producing stale/garbage MRC weights with no error indication.
**See:** `planning/blocks/Eigenvector Weight Computation.md` (Timing
Budget); `planning/DSP Chain SNR Loss Budget.md` §6.

### 8. AGC calibration and edge-case behavior are unverified on silicon

`AGC_TARGET_LO/HI` and `AGC_SAT_GUARD` require real-PCB calibration; the
branch-masking policy for a persistently saturated/dead/noisy antenna is
undefined; behavior under strong blockers / near-far interference is
untested; there is no mid-packet AGC recovery path (by design, but never
exercised against a real scenario).

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
`spi_slave.v:159-202` implements a 3-stage pulse synchronizer, explicitly
commented "Register writes cross into `clk_32m` via a pulse synchroniser."
No equivalent exists for `GRP_*`. Open Risk #16 already documents the
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

### 38. Host SPI 10 MHz timing is not constrained or signed off

The production SDC declares only `IQ_CLK` and globally false-paths
`SPI_SCK`. It also constrains `SPI_MOSI` relative to `IQ_CLK`, even though MOSI
is captured by `SPI_SCK`-clocked flops. Consequently, STA does not prove the
advertised 10 MHz SPI interface: SCK-domain register paths, MOSI setup/hold,
and the falling-edge `SPI_MISO` output timing are either hidden or referenced
to the wrong clock.

The most critical read path has only half an SCK period: the command address
completes on its eighth rising edge, the asynchronous `reg_bank` peek decode
must settle, and the MISO shifter loads on the following falling edge (50 ns at
10 MHz, before pad/PCB/host margin). Separately, Open Risk #15 shows that the
current pulse CDC can lose the final write when normal Raspberry Pi CS timing
clears the request before the 32 MHz synchronizer observes it.

**Risk:** a design that passes the current top-level timing reports can still
fail register reads or writes at the specified 10 MHz on silicon. Slowing SCK
may not cure the final-write CS race because it is caused by event lifetime,
not serial shift timing.

**Action:** implement the persistent toggle/mailbox CDC; declare a 100 ns
`SPI_SCK` clock; add SCK-relative MOSI and MISO I/O delays; declare SCK and
`IQ_CLK` asynchronous while excepting only the intentional synchronizer paths;
constrain the bundled mailbox crossing; and run all-corner setup/hold plus
unconstrained-path review. Derive board I/O delays from the Raspberry Pi, PCB,
and GF180 pad timing rather than guessing them.

**See:** Open Risk #15; `src/control/spi_slave.v`;
`src/config/pnr_32m_scoped_v20.sdc`;
`planning/spi-slave-cdc-and-10mhz-timing-plan.md`.
**Found:** 2026-07-11 (10 MHz SPI implementation/constraint research).

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

### 12. 1100×1100 target die may be physically unreachable

1380×1100 is the measured routing-congestion floor for the current
(un-paced) design on 7-track/5LM GF180; the honest-MCP SDC needed for item 1
can't even reach 1550×1150 without routing failures. The original
1100×1100 target may not be achievable on this stack without further RTL
area cuts.

**Area/cost risk, not functional.**
**See:** `planning/area-reduction-roadmap.md` §6.

### 13. No shadow→active weight promotion (TRPR-MRC-004 not implemented)

`mrc_combiner` consumes `rb_w_shadow` live (`trouper_top.v:492-495`) and
re-latches weights every sample — there is no active bank latched on
`W_COMMIT` at a safe-switch boundary. A 16-byte SPI weight burst is not
atomic, so a write landing mid-replay applies a half-updated W to samples.
Mitigated by firmware discipline (write only in W_PENDING); a proper fix
latches an active bank on `W_valid_set`.

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

### 15. Final SPI write lost if host raises CS too soon after last SCK edge

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

### 30. PSRAM debug-read timing budget is stale (assumes R=128, chip is R=64) — causes `sample_skip`

`psram_buf_ctrl.v`'s header comment (lines 11-13) budgets the debug-readback
path (`PSRAM_DBG_CTRL`/`PSRAM_DBG_DATA`, TRPR-PSR-017) against "CIC R=128 →
iq_valid every 128 cycles" (25 write + 19 del-read = 44 sub-cycles, 84 spare
per period). The decimator is now the fixed R=64 half-band chain (`iq_valid`
every 64 cycles, per `test_trouper_top.py`), leaving only ~20 idle sub-cycles
per period. A debug fetch takes a fixed 31 sub-cycles once launched and runs
to completion regardless of an arriving `iq_valid` (`psram_buf_ctrl.v:434-478`)
— it does not abort or restart — so any debug read in flight when the next
capture write is due collides with it, and the RTL's own `sample_skip` logic
(line 283) correctly flags the dropped sample. Debug reads are only issuable
when `packet_active=0` (bring-up/idle use, e.g. `PSRAM_DBG_CTRL.RD_TRIG`
during pre-lock SC acquisition), so the exposure is confined to host
debug-read usage rather than the primary same-packet capture/replay path —
but the header's implicit "no timing tradeoff" framing no longer holds, and
neither TRPR-PSR-017 nor the register map document the hazard.

Found while deriving the exact worst-case bound for a k-induction proof of
the debug-fetch bounded-response property (`formal/psram_buf_ctrl_formal.sv`):
K = 44 (worst-case wait for an in-flight write to finish) + 31 (fixed fetch
execution) = 75 cycles total service latency, which is fine for *when the
fetch finishes*, but the 31-cycle fetch itself does not fit inside the
~20-cycle idle margin left by a 64-cycle period, so it collides with the very
next write regardless of latency budget.

**Found:** 2026-07-05, deriving formal bounds for `formal/psram_buf_ctrl_formal.sv`.

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

### 20. `firmware/picorv32/asic_regs.h` is stale

Uses an old memory-mapped AHB-Lite address scheme (`ASIC_REG_BASE + 0x00`–
`0xEF`) that predates the current 7-bit SPI register map.
`planning/Register Map.md` is authoritative; this header has not been
resynced.

**Tooling/doc gap** — a risk only if someone builds firmware against the
stale header without noticing.

### 21. NW-MRC / `energy_meas_coarse`-removal contingency stack not implemented

If `energy_meas_coarse` (a ~70 k µm² area-cut candidate) is ever removed,
none of its three proposed AGC/noise-estimate replacements
(`live-iq-agc-calibration.md`, `per-branch-rssi-via-sx1302.md`,
`psram-software-energy-meas.md`) are implemented yet. Currently a
contingency, not triggered.

**Escalates to Moderate/High only if the area cut is taken.**

### 22. NR=2/3-chip cascade risks unsimulated

Re-modulator SQNR accumulation across cascade stages, hierarchical-MRC
suboptimality vs. true NR=4 MRC, and inter-chip reset skew (undetectable at
runtime — no symptom besides corrupted MRC weights, mitigated only by
matched-trace-length reset routing, unverified) are all open for the
multi-ASIC cascade topology.

**Low for the current NR=1 tapeout** — becomes High if/when an NR=2 cascade
product ships.
**See:** `planning/NR2-multi-ASIC-cascade.md`, `planning/cascade-beamsteering.md`.

### 23. Weight Generation: noise-whitening (NW-MRC) not implemented

Feature gap in both firmware and the Python reference model.
**See:** `planning/blocks/Weight Generation.md`.

### 24. Trouper Chip Specification drift vs. RTL (clock architecture, register addresses)

`Register Map.md` and `reg_bank.v` agree; the spec body does not.
**Progress 2026-07-05/06:** all the stale register addresses below were fixed
in the spec (Traceability.md "Register Address Reconciliation"), and
TRPR-INT-006 / TRPR-DCR-015 / TRPR-FBC-002 / TRPR-REG-005 / TRPR-WGN-008 /
TRPR-PSR-011/012 were reworded to the shipped design. **Still open:** spec
§3.1 / TRPR-SYS-003/015/016 / TRPR-PHY-014 still mandate a real `CLK_16M`
generated-clock tree (RTL is single-clock + `ce_16m` CE on reg_bank only);
TRPR-MRC-001/006 say int16 Q1.15 weights but hardware consumes the high byte
only (8-bit, per TRPR-MRC-002 / Open Risks #33); TRPR-MRC-004's safe-switch
"W_ACTIVE" latch is spec-only (Open Risks #13); PCF-011's "bypass training"
overstates Mode 1 (training runs, weights are ignored); RMD-003's "permanent
instability" framing doesn't match observed failure signatures.
Historical record of the fixed addresses: SC_HITS_REQ 0x1B→0x0E,
PKT_TIMEOUT_SYMS 0x16→0x0B, WGT_CTRL 0x35→0x1E, PACKET_STATUS 0x34→0x1C,
TRAINING_STATUS 0x60→0x20; ZDIAG width/address; `Z_SHIFT` removed; SCD-012
C_POOL double-booking. Stale R=128 comments remain in
`trouper_top.v:150`, `psram_buf_ctrl.v:11`, `mrc_combiner.v:19`,
`training_acc.v:15` (budgets still fit the 64-cycle window).

**Doc gap — risk is firmware/bring-up written against the spec, not the map.**
**Found:** 2026-07-02 trouper_top RTL review.

### 25. trouper_top dead logic + minor RTL hygiene

`packet_ctrl_fsm` outputs `psram_packet_arm`/`psram_replay_start`/
`psram_abort`/`payload_rd_base` are unconnected (`trouper_top.v:387-390`) and
`safe_switch`/`combiner_source` are unused — notably `psram_abort` is *not*
wired into `psram_buf_ctrl`, so a re-lock during replay relies solely on
`packet_end` (verify that path or wire/delete). Also: `mimo_mode[1]` never
writable (`reg_bank.v:191`) yet read back and forwarded; a `noise_trig`
written while a live training is armed is silently swallowed (top opens
`noise_window_active`, `training_acc` ignores the arm — TODO at
`trouper_top.v:257`); `mrc_combiner.v:126` assigns `26'sd0` to an 18-bit reg;
`mrc_combiner` port `clk_16m` is actually driven at 32 MHz.

2026-07-06 addition: `buf_freeze` joins the list — now *verified* to follow
the FSM contract (asserted at packet start, dropped at IDLE;
`test_w_missed_packet.py`, job 3310) but it drives nothing in `trouper_top`
(declared "unused without fbuf"); dead since the PSRAM delay-line migration
replaced `frontend_buf_ctrl`. Candidate for removal or re-purposing along
with the other dead FSM outputs above.

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
`psram_ctrl[1:3]` — `CLR_ERR`/`SAMPLE_WIDTH`/`QSPI_OWNER` — left ungated,
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
  bytes of a 2^23 wraparound, while real backlogs are bounded to <=262144
  bytes (TRPR-PSR-015, >=32x headroom) — still holding unchanged.
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
