# Verification Traceability Matrix

Maps each `TRPR-*` requirement ID in `planning/Trouper Chip Specification.md` to the
test(s) that actually exercise it, plus known gaps. Filled in block by block as each
block's verification is (re-)done — see `planning/Open Risks.md` for narrative
history and SGE job numbers behind specific fixes.

**Convention going forward:** new testbenches/cocotb tests should carry a header
comment listing the `TRPR-*` IDs they exercise (as `tb_trouper_two_packet.v`,
`tb_trouper_spi.v`, and `test_capture_two_packet.py` already do), so this matrix can
be refreshed by grepping rather than re-auditing by hand.

**Status legend:** ✅ tested (RTL-level or SPI/register-level) · ⚠️ partially tested ·
❌ no test · 🗑️ requirement references a register/feature removed from current RTL

---

## Register Address Reconciliation — RESOLVED 2026-07-05

While building the per-block sections below, individual requirements kept citing
register addresses that don't match `planning/Register Map.md`. This section
documents the full sweep — every `0x..` address cited anywhere in `Trouper Chip
Specification.md`'s `TRPR-*` rows, cross-checked against the active register
table, covering the **whole spec** (not just the blocks traced below, so it
includes WGN/AGC findings for blocks that don't have a traceability section yet)
— **and the corrective edit applied directly to `Trouper Chip Specification.md`.**
All 14 rows below are now fixed in the spec; this table is kept as the change record.

Root cause, in every case checked: the register map was reshuffled at least
twice (the 128-register repack, and the Zdiag 16→24-bit widening in commit
`46e1da0`) and the spec's per-requirement address citations were never
re-swept afterward. None of these were RTL bugs — the RTL and `Register
Map.md` agreed with each other throughout; only the spec text lagged.

| Requirement | Spec said | Actually is | Note |
|---|---|---|---|
| TRPR-TAC-005 | `ZDIAG_k` at 0x64–0x6B, 16-bit | `ZDIAG_0..3` at **0x64–0x6F**, 24-bit each | Stale since the Zdiag widening fix (`46e1da0`); **fixed** |
| TRPR-TAC-006 | `Z_SHIFT` at 0x63 | *(removed — hardwired 0)* | Reworded to REMOVED, cross-referencing TRPR-WGN-009; **fixed** |
| TRPR-TAC-008 | `TRAINING_STATUS` at 0x60 | **0x20** | 0x60 is unallocated in the current map; **fixed** |
| TRPR-TAC-011 | `TACC_REF_SEL` at 0x6B | *(removed — superseded by `TACC_NOISE_TRIG`)* | Reworded to REMOVED; **fixed** |
| TRPR-SCD-008 | `SC_HITS_REQ` at 0x1B | **0x0E** | RTL and tests both correctly use 0x0E; **fixed** |
| TRPR-SCD-009 | `SC_STAT` at 0x50–0x51 | `SC_STAT_HI/LO` at **0x24–0x25** | Also untested at either address (coverage gap unchanged); **address fixed** |
| TRPR-PCF-006 | `ACTIVE_MODE`/`ACTIVE_ANTENNA_EN` at 0x30/0x31 | Packed into `ACTIVE_STATUS` at **0x1D** | 0x30/0x31 are actually `W_0_RE_HI/LO` — collision risk; **fixed** |
| TRPR-PCF-007 | `PKT_TIMEOUT_SYMS` at 0x16 | **0x0B** | RTL and tests both correctly use 0x0B; **fixed** |
| TRPR-PCF-009 | `PACKET_STATUS` at 0x34 | **0x1C** | 0x34 is actually `W_1_RE_HI` — collision risk; **fixed** |
| TRPR-MRC-007 | `COMB_POST_GAIN_SHIFT` at 0x36[2:0] | `COMB_CFG` at **0x0F**[2:0] | 0x36 is actually `W_1_IM_HI` — collision risk; **fixed** |
| TRPR-MRC-011 | `WGT_CTRL` at 0x35 | **0x1E** | 0x35 is actually `W_1_RE_LO` — collision risk; **fixed** |
| TRPR-WGN-006 | `ZDIAG_k` at 0x64–0x6B, bits [31:16] | **0x64–0x6F**, bits [31:8] | Same widening staleness as TAC-005, plus wrong bit slice; **fixed**, and the now-redundant left-shift-to-align-scales instruction was removed since both Z_kl and Zdiag are read at the same [31:8] scale post-widening |
| TRPR-WGN-009 | `Z_SHIFT` at 0x63 | *(removed — hardwired 0)* | Same root cause as TAC-006, initially miscategorised as "checked clean" in an earlier draft of this table — caught on a second pass; **fixed**, reworded to REMOVED |
| TRPR-AGC-001 | Zdiag at 0x64–0x6B | **0x64–0x6F** | Same widening staleness as TAC-005/WGN-006; **fixed** |
| TRPR-AGC-002 | `AGC_THR_HI` at 0x2B–0x2C, `AGC_THR_SAT` at 0x2D–0x2E | *(removed — never implemented in RTL, AGC comparison is software-owned)* | 0x2B–0x2E are actually `SC_FIRST_HIT`/`SC_LOCK_SNAP` — collision risk; **fixed**, reworded to make clear the strategy is real but the comparator registers never existed in RTL |

**Checked clean** (address citations that do match the current register map,
included for completeness since they were part of the same sweep, no edits
needed): SPS-002, SPS-006 (`CHIP_ID` 0x00), SPS-010/011 (`PSRAM_DBG_DATA` 0x76,
`0x7F` reserved), REG-004, REG-006 (`TACC_NOISE_TRIG` 0x1F, `WGT_CTRL.W_COMMIT`
0x1E, `RX_GAIN_COMMIT` 0x18, `PSRAM_CLR_ERR` 0x70, `PSRAM_DBG_CTRL.RD_TRIG` 0x75),
REG-007/IRQ-001/002/006 (`IRQ_STATUS` 0x02, `IRQ_CLEAR` 0x03), AGC-003
(`RX_GAIN_SHADOW`/`ACTIVE` 0x10–0x17), AGC-004 (`TACC_NOISE_TRIG` 0x1F), INT-002/009
(0x00–0x7F range, W shadow 0x30–0x3F, `WGT_CTRL` 0x1E), TAC-002/003/004/007
(Z pairs 0x40–0x63, `N_ACC` 0x21–0x23, `TACC_WINDOW_SYMS` 0x27), PSR-006/007/
009/010/017/020 (`PSRAM_STATUS` 0x71, `PSRAM_CTRL` 0x70, `PSRAM_DBG_*` 0x72–0x76),
SCD-010/011/012, WGN-003/007.

**Two distinct classes of finding, kept separate in the edits applied:**
1. **Wrong address for a register that exists** (TAC-005/008, SCD-008/009,
   PCF-006/007/009, MRC-007/011, WGN-006, AGC-001) — pure spec-text address
   swap. Several pointed at addresses that are now *other* live registers
   (weight-shadow bytes, mostly) — a real collision risk for anyone who'd
   hand-implemented firmware straight from the spec table.
2. **Register removed or never implemented** (TAC-006/011, WGN-009, AGC-002) —
   not a simple address swap. Reworded each row to `Pri/Type = —`, requirement
   text `**REMOVED.**`/clarified, matching the existing style already used for
   `TRPR-PSR-008` (`**DELETED.**`).

**Not covered by this pass:** `TRPR-WGN-008`'s `DBG_MISSED_PKTS` counter
register doesn't appear anywhere in `Register Map.md` either, but it wasn't
caught by this sweep (no hex address to grep for) — worth a follow-up check,
and ties into the already-tracked `W_MISSED_PACKET` untested-bit gap in the
PCF-005/PCF-009/MRC-011 findings below.

---

## 4.5 Training Accumulator (`training_acc.v`) — TRPR-TAC

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-TAC-001 | Compute 6 off-diag Z_kl + 4 diag Z_kk | T | `tb_training_acc_equiv.v`, `tb_dsp_chain_rand.v` (job 1789), `sim/tests/test_training_allpairs_stress.py` | ✅ |
| TRPR-TAC-002 | Window controlled by `TACC_WINDOW_SYMS`, reset clamps to 8 | T | `tb_training_acc_equiv.v`, `tb_tacc_resetless_equiv.v` | ✅ |
| TRPR-TAC-003 | `training_done` asserts; `n_acc` latched 18-bit | T | `tb_training_acc_equiv.v`, `tb_tacc_resetless_equiv.v` | ✅ |
| TRPR-TAC-004 | Z_kl readback format, 0x40–0x63, 24-bit BE | T | `test_weight_gen_spi_flow.py` (job 3286) | ✅ (via SPI, real capture data) |
| TRPR-TAC-005 | Zdiag readback 0x64–0x6F, 24-bit | T | `test_weight_gen_spi_flow.py` (job 3286) | ✅ Spec address/width fixed 2026-07-05 (was 0x64–0x6B/16-bit, stale since the Zdiag widening in `46e1da0`) — see Register Address Reconciliation above. The test itself always read the correct current registers; only the spec text had lagged. |
| TRPR-TAC-006 | *(REMOVED — no hardware `Z_SHIFT` register in the current revision)* | — | — | ✅ Spec reworded 2026-07-05 to state the register doesn't exist, cross-referencing TRPR-WGN-009 — see Register Address Reconciliation above. Was previously describing a register hardwired 0 in `trouper_top`. |
| TRPR-TAC-007 | Firmware noise-trigger mode (`TACC_NOISE_TRIG`) | T | `tb_trouper_spi.v` (W1P mechanics), `cocotb/tests/test_noise_trig.py` (job 3310, functional) | ✅ Closed 2026-07-06. Full functional flow with independent per-antenna Gaussian noise: arm without `sc_lock` (PSRAM disabled → contamination impossible by construction), `NOISE_READY` IRQ fires, `n_acc == 8M` exactly (forward window — contrast with lock-mode's `7M−1`), all four Zdiag > 0, every normalized \|Z_kl\| < 0.2 (≈0.02 expected for independent noise). Plus the contamination case: SC hits/lock inside a triggered window suppress `NOISE_READY` while `training_done` still fires. First functional test of the `sigma2_valid` gate and IRQ bit 4. |
| TRPR-TAC-008 | `TRAINING_STATUS` (0x20) exposes DONE/ARMED bits | T | `tb_training_acc_equiv.v`, `tb_tacc_resetless_equiv.v` (signals), `cocotb/tests/test_noise_trig.py` (job 3310, SPI readback) | ✅ Closed 2026-07-06: register 0x20 now read over SPI — 0x00 before any trigger, `ARMED` (bit 1) observed high during an active window, `DONE` (bit 0) after completion. |
| TRPR-TAC-009 | Z_kl/n_acc matches Python `h_k·conj(h_l)` within Q1.15 | T | `test_weight_gen_spi_flow.py` (job 3286, oracle compare), `sim/tests/test_eigvec_fw.py` | ✅ |
| TRPR-TAC-010 | Auto-reset on each `sc_lock` | T | `tb_tacc_resetless_equiv.v` (B2, job — see `project_area_cuts_b1_banked_b2_rejected_3v` memory), `test_capture_two_packet.py` (job 3273, real-capture two-packet re-arm) | ✅ |
| TRPR-TAC-011 | *(REMOVED — no hardware `TACC_REF_SEL` register in the current revision)* | — | — | ✅ Spec reworded 2026-07-05 — see Register Address Reconciliation above. Was previously describing a legacy register in the map's "Former addresses / removed" table, superseded by `TACC_NOISE_TRIG`. |

**Open items surfaced by this pass:**
1. **TAC-006 / TAC-011 spec-RTL mismatch** — both requirements describe registers (`Z_SHIFT`, `TACC_REF_SEL`) that `planning/Register Map.md` lists as removed/hardwired-0. These aren't test gaps, they're stale spec text — needs a spec update pass, not a test.
2. ~~**TAC-007 functional gap**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_noise_trig.py` (job 3310): clean-window measurement (NOISE_READY, Zdiag/Z_kl statistics, n_acc=8M) and contamination suppression both exercised.
3. ~~**TAC-008 register-level gap**~~ — **CLOSED 2026-07-06** by `test_noise_trig.py` (job 3310): TRAINING_STATUS (0x20) DONE/ARMED bits read over SPI.

---

## 4.3 Schmidl-Cox Detector (`sc_detector.v`) — TRPR-SCD

There is no standalone `tb_sc_detector.v` — the detector is only ever exercised
embedded in a full-DSP-chain testbench (`tb_dsp_chain*.v`, `tb_trouper_top.v`,
`test_trouper_top.py`) or the Python behavioral model (`sim/models/sync.py`,
`sim/tests/test_sync.py`).

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-SCD-001 | Per-symbol complex autocorrelation `C[s]` on branch 0 | I | `tb_dsp_chain_sf.v`, `tb_dsp_chain_rand.v` (job 1789), `sim/tests/test_sync.py` | ✅ (functional, via downstream sc_lock/Zdiag correctness) |
| TRPR-SCD-002 | Divider-free hit test `\|C[s]\|² ≥ THR_eff·E[s]` | T | `tb_dsp_chain_sf.v`, `tb_dsp_chain_rand.v`, `sim/tests/test_sync.py` | ✅ (functional) |
| TRPR-SCD-003 | One hit decision per completed symbol, full-M delayed samples via PSRAM | I | `tb_dsp_chain_real_probe.v`, `test_capture_two_packet.py` (job 3273) | ✅ |
| TRPR-SCD-004 | `sc_lock` asserts after `SC_HITS_REQ+1` consecutive hits | T | `tb_dsp_chain.v`, `tb_dsp_chain_sf.v`, `tb_dsp_chain_rand.v` (direct-wired `sc_hits_req`, not via register), `test_trouper_top.py` (via SPI `SC_HITS_REQ` write) | ✅ |
| TRPR-SCD-005 | `timing_ref = lock_sample − (SC_HITS_REQ+1)·M + 1` | T | `cocotb/tests/test_sc_dbg_flags.py` (job 3307, adjacent evidence) | ⚠️ Still no direct closed-form assertion on `timing_ref` itself, but materially strengthened 2026-07-06: the formula's inputs were in **wrong (double-counted) units** until the Open Risks #36 fix — `timing_ref` was inflated by an amount growing over the session, and no downstream Z-correctness check ever noticed (stationary stimuli). `test_sc_dbg_flags.py` now pins the mark arithmetic (`SC_LOCK_SNAP == SC_FIRST_HIT + M`), and the corrected `n_acc = 7M−1` expectation in `test_trouper_top.py` is a direct downstream consequence of the corrected formula. |
| TRPR-SCD-006 | RTL operates on antenna branch 0 only (by design) | I | — | ℹ️ Not a testable requirement — it's a documented design limitation. Tracked as an open risk: `planning/sc-detector-ant0-fading-risk.md` (ant0 deep-fade SPOF, no 4-branch pooling before lock). |
| TRPR-SCD-007 | `SC_THR_HI/LO` (0x0C/0x0D) writable, RTL consumes low 12 bits, reset default `0x01CC` | I | `tb_trouper_top.v`, `test_trouper_top.py` (write `SC_THR_HI/LO` over SPI) | ⚠️ Write path exercised; reset-default value (`0x01CC`) not asserted anywhere. |
| TRPR-SCD-008 | `SC_HITS_REQ` configurable via register **0x0E** | T | `test_trouper_top.py`, `tb_trouper_top.v` (write via SPI) | ✅ Spec address fixed 2026-07-05 (was `0x1B` — see Register Address Reconciliation above). RTL and both tests already correctly used 0x0E. |
| TRPR-SCD-009 | `SC_STAT_HI/LO` (0x24–0x25) exposes `\|C[s]\|²` telemetry | I | `cocotb/tests/test_sc_dbg_flags.py` (job 3307) | ✅ Closed 2026-07-06: read over SPI at both addresses — zero before any symbol evaluation exists (pre-PSRAM-init baseline), nonzero after lock (frozen at the last pre-lock symbol's telemetry). |
| TRPR-SCD-010 | Debug regs `SC_DBG_FLAGS` (0x26), `SC_FIRST_HIT` (0x28–0x2B), `SC_LOCK_SNAP` (0x2C–0x2F) | T | `cocotb/tests/test_sc_dbg_flags.py` (job 3307) | ✅ Closed 2026-07-06, with two RTL fixes found in the process: (1) `SC_DBG_FLAGS.SC_HIT` was the 1-cycle `sc_hit_dbg` pulse wired to combinational readback — firmware-invisible, same class as the W_MISSED_PACKET bug — fixed with held `sc_hit_hold` (Open Risks #35); (2) the snapshot delta check (`SC_LOCK_SNAP == SC_FIRST_HIT + M` at `SC_HITS_REQ=1`) exposed the sc_detector `sample_count` double-count (Open Risks #36). All three registers now read and value-checked over SPI, plus an all-zero pre-evaluation baseline. |
| TRPR-SCD-011 | `CORR_MAG_n` (0x48–0x4F) reserved, tied to 0 | I | — | ✅ (by inspection — matches Register Map "Former addresses" table; nothing to functionally test) |
| TRPR-SCD-012 | `C_POOL_I/Q` (0x64–0x67) reserved, tied to 0 | I | — | ✅ (by inspection — matches Register Map; nothing to functionally test) |
| TRPR-SCD-013 | `sc_lock` within ±1 symbol of Python model, SF7/125 kHz/0 dB SNR | T | `sim/tests/test_sync.py` (Python-only) | ⚠️ Python reference model is tested against itself; no test compares **RTL** `sc_lock` timing directly against the Python block-model prediction — the gap this requirement is actually about. |
| TRPR-SCD-014 | `sc_lock` de-asserts and re-arms on Packet Control FSM → IDLE | T | `tb_trouper_two_packet.v` (job 3203), `test_capture_two_packet.py` (job 3273, real capture) | ✅ |
| TRPR-SCD-015 | `ENERGY_GATE_EN` reserved, left at 0 (energy gating not implemented) | I | — | ✅ (by inspection — `noise_est.v` energy gating removed per Register Map "Former addresses") |
| TRPR-SCD-016 | e_slice guard suppresses hits when `eval_e_acc[25:13] == 0` | I | `test_trouper_top.py`, `tb_trouper_top.v` | ⚠️ Only exercised in the "guard passes" direction (stimulus amplitude chosen to clear the ≥27-count threshold). No negative-case test confirms a genuinely low-energy hit gets suppressed. |

**Open items surfaced by this pass:**
1. **SCD-008 / SCD-009 spec-RTL address mismatches** — `SC_HITS_REQ` is at `0x0E` in the register map (RTL matches), not the `0x1B` the spec cites; `SC_STAT` is at `0x24–0x25` (RTL matches), not `0x50–0x51`. Same pattern as the TAC-006/TAC-011 findings — spec text drifted from the register map after address reshuffles.
2. **No isolated `sc_detector` testbench** — every test instantiates it inside the full DSP chain or `trouper_top`. Fine for integration confidence, but harder to pin down which requirement a given chain-level pass/fail actually validates.
3. ~~**Debug/telemetry register readback untested**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_sc_dbg_flags.py` (job 3307). "Wired correctly per the register map" turned out to be false twice over: `SC_HIT` was pulse-wired (firmware-invisible, Open Risks #35) and the snapshot registers were in double-counted units (Open Risks #36) — both found by this test and fixed. |
4. **SCD-005 and SCD-013 are functionally exercised but not directly asserted** — `timing_ref`'s formula and RTL-vs-Python lock-timing agreement are both only checked indirectly (via downstream correctness), not as standalone assertions.
5. **SCD-016 guard is untested in the negative case** — no test drives low enough energy to confirm the guard actually suppresses a would-be false hit.
6. **SCD-006 ant0 SPOF** is a known, already-tracked open risk (`sc-detector-ant0-fading-risk.md`), not a new finding — cross-referenced here for completeness.

---

## 4.10 PSRAM Buffer Controller (`psram_buf_ctrl.v`) — TRPR-PSR

This block has two independent verification legs: RTL/cocotb simulation (chain
testbenches, `tb_trouper_spi.v`, `cocotb/tests/test_startup.py`) and a
SymbiYosys k-induction formal proof (`formal/psram_buf_ctrl_formal.sv`,
`formal/psram_buf_ctrl.sby`) covering pointer/overflow bounds, sticky-flag
correctness, FSM legality, bus-driving safety, and delay-line warm-up.

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-PSR-001 | QSPI init completes within 1 ms of RESETB de-assertion | T | `cocotb/tests/test_startup.py::test_qe_init_trst_margin` (measures 750 ns RST→EnterQPI gap, job 3257) | ⚠️ The on-chip QE_INIT sequence itself is fast and measured, but the requirement's implicit dependency — firmware must not write `PSRAM_EN=1` until ≥150 µs after board power-up (tPU) — is explicitly **not** enforced in hardware. `test_startup.py::test_psram_init_has_no_tpu_wait` demonstrates this gap numerically rather than closing it; it's host/board discipline only (Open Risks #27). |
| TRPR-PSR-002 | Continuous circular-buffer streaming; latch packet-start pointer on `sc_lock` | T | `test_capture_playback.py`, formal `a_gap_invariant` (pointer/gap tracking) | ✅ |
| TRPR-PSR-003 | `REPLAY_ACTIVE` on `W_commit`; replay from latched start incl. preamble, at 500 kS/s | T | `test_weight_gen_spi_flow.py` (job 3286), `test_capture_playback.py`, formal `a_replay_active_matches_state`, `a_replay_clears_on_end` | ✅ |
| TRPR-PSR-004 | `REPLAY_MISSED` asserts/latches if `W_COMMIT` is late; combiner falls back to next-packet weights | T | formal `a_replay_missed_cause`/`a_replay_missed_sticky`, `cocotb/tests/test_psram_ops.py::test_replay_missed_late_commit` (job 3313) | ✅ Closed 2026-07-06: a genuinely late `W_COMMIT` (after `packet_end`) is driven in sim — `REPLAY_MISSED` latches at its register bit, the late commit is inert (no zombie replay, packet base invalidated), `PSRAM_CLR_ERR` clears the sticky over SPI, and the next in-time-committed packet replays clean with the flag staying 0. Note the auto re-arm behavior this test had to accommodate: SC re-locks immediately at IDLE, so every uncommitted packet correctly re-latches the flag (the test's first draft flagged that correct behavior as a failure, job 3312). |
| TRPR-PSR-005 | 8 bytes/sample storage, order i0,q0,i1,q1,i2,q2,i3,q3 | T | `test_capture_playback.py`, `test_weight_gen_spi_flow.py` (byte order implicitly confirmed — replayed/read-back samples only match reference if order is correct) | ✅ (functional, no test asserts byte order in isolation) |
| TRPR-PSR-013 | Nominal write rate 2 MB/s, ~3% of device capacity | A | — | ✅ (analysis-only per spec `Verif` column; arithmetic, not a test target) |
| TRPR-PSR-014 | QPI timing headroom: 20 spare cycles (write), 8 spare (replay) | A | Formal `a_no_drive_during_dummy`, `a_ce_n_matches_activity` indirectly confirm no overrun; `test_startup.py` timing measurements | ✅ (analysis + formal bus-timing safety) |
| TRPR-PSR-015 | Max buffer depth ≈256 kB at SF12, no overflow ≤ SF12 | A/T | Formal `a_gap_invariant` (bounded backlog), `test_capture_playback.py` SF sweep | ✅ |
| TRPR-PSR-006 | `PSRAM_STATUS` (0x71) bit layout: state/SAMPLE_SKIP/INIT_DONE/REPLAY_ACTIVE/REPLAY_MISSED/OVERFLOW/BUF_ACTIVE | I | `test_trouper_top.py`, `tb_trouper_top.v` (poll `INIT_DONE` bit[3]), `cocotb/tests/test_bypass_e2e.py` (job 3304, polls `REPLAY_ACTIVE` bit[4] after `W_COMMIT`) | ⚠️ 4/7 bits now read back over SPI at their register positions: `INIT_DONE` bit[3], `REPLAY_ACTIVE` bit[4] (set + negative cases), `REPLAY_MISSED` bit[5] (set + clear, `test_psram_ops.py` job 3313), `SAMPLE_SKIP` bit[2] (asserted 0 end-of-packet in every SF sweep scenario, job 3311). Remaining 3 (`state`, `OVERFLOW`, `BUF_ACTIVE`) are proven as internal *signals* by formal but not at their register bit positions. |
| TRPR-PSR-007 | Sticky flags clearable via `PSRAM_CLR_ERR` (0x70[1]); simultaneous set+clear not lost | T | `tb_trouper_spi.v` (W1P self-clear mechanics only), formal `a_replay_missed_sticky`/`a_sample_skip_cause` (found and fixed a same-cycle `clr_err`-timing bug in the proof itself, 2026-07-05) | ✅ (formal covers the actual race the requirement is about; RTL-sim only covers the register mechanics) |
| TRPR-PSR-008 | *DELETED* (`PSRAM_PKT_BYTES` removed) | — | — | — n/a |
| TRPR-PSR-009 | `PSRAM_EN=0` disable mode: idle, no QSPI pad assertion | T | formal `a_buf_active_needs_en` | ✅ |
| TRPR-PSR-010 | `QSPI_OWNER` selects active master; owner 1 suspends buffering/replay, tri-states pads | T | `cocotb/tests/test_qspi_owner.py` (job 3314) | ✅ Closed 2026-07-06: owner=1 releases CE#/SIO_OE/SCK within 8 clocks and holds them released (checked per-clock for 256 clocks), `DBG_BUSY` held, and buffering AND replay both resume after owner returns to 0. Found+fixed a missing `!qspi_owner` gate on the S_REPLAY burst launch — owner previously could never suspend an active replay (Open Risks #37). |
| TRPR-PSR-011 | `QSPI_OWNER` writes during BUFFERING/REPLAY don't glitch pads; effect deferred to the QPI burst boundary | T | `cocotb/tests/test_qspi_owner.py` (job 3314) | ✅ Closed 2026-07-06, with an RTL fix: `sck_en` was gated by the RAW owner bit — a mid-burst request froze SCK while CE# stayed low and SIO kept driving (the exact prohibited glitch). Fixed with `qspi_owner_eff` latched between bursts; the test asserts CE#-low ⇒ SCK-enabled on every clock through both handovers. Spec's "effect only at STATE=IDLE" wording also corrected (no such state exists) to "at the next QPI burst boundary". Formal k-induction re-proven on the modified RTL (job 3314). |
| TRPR-PSR-012 | *(REMOVED — no `PAD_CONFLICT` signal in RTL)* | — | — | ✅ Spec reworded 2026-07-06: the signal was never implemented and none is needed — `psram_buf_ctrl` is the only on-chip QSPI driver and tri-states under owner=1 (PSR-010/011), so no on-chip simultaneous-driver case exists. Same REMOVED treatment as TAC-006/011, AGC-002. |
| TRPR-PSR-016 | SC delay reads at `write_ptr − M`, interleaved with writes, cease after `sc_lock` | T | `test_capture_playback.py` (delayed-sample correctness via full-chain sc_lock), formal `a_del_valid_needs_rdy`, `a_del_cnt_bounded` | ✅ |
| TRPR-PSR-017 | PSRAM debug readback protocol (host SPI): addr write → RD_TRIG → poll DBG_BUSY → read 8 data bytes → AUTO_INC | T | `tb_trouper_spi.v` (mechanics), `cocotb/tests/test_psram_ops.py::test_dbg_readback_content` (job 3313) | ✅ Closed 2026-07-06: full host protocol run packet-free, 16 bytes read over SPI compared **bit-exact** against the behavioural psram_model's nibble memory at the same addresses (i.e. exactly what the QPI engine physically stored), including the `AUTO_INC` re-fetch at base+8. Formal section E remains parked — no longer load-bearing given the sim coverage. |
| TRPR-PSR-018 | QPI-only interface mandate (no SPI/1-bit mode) | A | — | ✅ (by construction — RTL has no 1-bit mode to test against) |
| TRPR-PSR-019 | SF fixed per session; re-arm SC delay warm-up on `sf`/`sample_shift` change | T | `cocotb/tests/test_startup.py::test_sc_correlator_idle_until_del_rdy` (warm-up latency at fixed SF/BW only) | ⚠️ Warm-up hold-off itself is verified (measured SF9/BW125 at 4.092 ms vs 4.096 ms predicted). The re-arm-on-**change** clause specifically is untested — no test changes `sf`/`sample_shift` mid-session (formal explicitly *assumes* these are session-constant, `m_sf_valid_range`/`m_sample_shift_valid_range`, to keep the proof tractable). |
| TRPR-PSR-020 | Sticky `SAMPLE_SKIP` flag; spec claims "verified by a directed sustained-`iq_valid` test... at 125 and 250 kHz" | T | `cocotb/tests/test_trouper_top.py` SF7 BW250/BW125 full scenarios (job 3310), formal `a_sample_skip_cause` | ✅ Closed 2026-07-06 — by making the spec's claim true rather than removing it: both full-packet scenarios now read `PSRAM_STATUS[2]` at end-of-packet and assert `SAMPLE_SKIP == 0` after sustained `iq_valid` at both bandwidths. (Relevant to Open Risks #30's stale-budget concern: at the current R=64 rate the flag stays clean.) The flag's *cause* condition remains formally proven. |

**Open items surfaced by this pass:**
1. ~~**PSR-020 is a false verification claim in the spec itself**~~ — **CLOSED 2026-07-06** by adding the claimed directed check to both SF7 full scenarios (`SAMPLE_SKIP == 0` at end-of-packet, BW250+BW125, job 3310) — the claim is now true.
2. ~~**`QSPI_OWNER` handover (PSR-010/PSR-011) has zero test coverage**~~ — **CLOSED 2026-07-06** by `test_qspi_owner.py` (job 3314), which found and regressed two real RTL bugs: the raw-owner SCK gate (mid-burst pad glitch) and the ungated S_REPLAY launch (owner couldn't suspend replay). PSR-012 removed from the spec as never-implemented/unneeded. See Open Risks #37.
3. ~~**PSR-004 replay-miss fallback is only proven at the flag level**~~ — **CLOSED 2026-07-06** by `test_psram_ops.py` (job 3313): late commit driven for real; flag latch/clear/recovery all confirmed at the register level.
4. ~~**PSR-017 debug readback is only mechanically tested**~~ — **CLOSED 2026-07-06** by `test_psram_ops.py` (job 3313): 16 bytes bit-exact vs the model's stored content incl. AUTO_INC. The parked formal section E is superseded by this sim coverage.
5. **PSR-006 status-bit register mapping is 1/7 tested** over SPI (`INIT_DONE` only); the other six bits' correctness is proven at the signal level by formal but never checked at their register bit positions.
6. **PSR-001's real gap (tPU wait) is known and tracked** (Open Risks #27, `[[project_startup_delay_risks]]` memory) — flagged here for cross-reference, not a new finding.

---

## 4.7 Packet Control FSM (`packet_ctrl_fsm.v`) — TRPR-PCF

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-PCF-001 | 4 states IDLE→PREAMBLE_ACQ→W_PENDING→PAYLOAD_ACTIVE→IDLE | T | `tb_trouper_top.v`, `tb_trouper_two_packet.v` (job 3203), `test_capture_two_packet.py` (job 3273) — sequence inferred from IRQ timeline (`t_sc_lock`/`t_train_done`/`t_w_commit` cycle stamps) | ⚠️ The overall sequence order is confirmed via IRQ events, but no test reads `PACKET_STATUS.PACKET_PHASE[2:0]` directly to confirm the FSM is actually in the state the sequence implies. |
| TRPR-PCF-002 | On `sc_lock`: assert `buf_freeze`, → PREAMBLE_ACQ | T | `cocotb/tests/test_w_missed_packet.py` (job 3310) | ✅ Closed 2026-07-06: `buf_freeze` observed as a `packet_ctrl_fsm` output for the first time — asserted after `sc_lock`, held through PAYLOAD_ACTIVE, re-asserted at the next packet start. Note the signal is currently consumed by nothing in `trouper_top` (marked "unused without fbuf" at its declaration) — the check pins the FSM contract, not a datapath effect. |
| TRPR-PCF-003 | On `training_done`: → W_PENDING, assert `TRAINING_DONE` IRQ | T | `test_weight_gen_spi_flow.py` (job 3286, `IRQ_STATUS[TRAINING_DONE]`) | ✅ |
| TRPR-PCF-004 | On `W_COMMIT`: latch `W_ACTIVE` at safe-switch boundary, → PAYLOAD_ACTIVE | T | `test_weight_gen_spi_flow.py`, `test_capture_playback.py` (`W_COMMIT`→`WGT_CTRL[1]` W_VALID→combiner uses committed weight) | ✅ (via `WGT_CTRL`, not `PACKET_STATUS`, mirror — see PCF-009) |
| TRPR-PCF-005 | No `W_COMMIT` before payload boundary → stay in bypass, set `W_MISSED_PACKET`, assert IRQ | T | `cocotb/tests/test_w_missed_packet.py` (job 3305) | ✅ Closed 2026-07-06. Lock → training_done → `W_COMMIT` withheld → miss IRQ (`IRQ_STATUS[2]`) fires at the W_PENDING timeout (the exact `46e1da0` fix path), payload provably runs in bypass (`use_mrc_r=0`, `comb_y` bit-equals raw ant0 for 20 pairings), and the flag reads back at both register positions. **Second RTL fix found by this test**: the 1-cycle `W_missed_packet` pulse was wired straight into reg_bank's combinational `w_missed_rb`, making `PACKET_STATUS[7]`/`WGT_CTRL[3]` firmware-invisible — fixed with a sticky per-packet `W_missed_q` in `packet_ctrl_fsm.v` (set at both miss sites, held through IDLE, cleared at next packet start), regression included in the same test. |
| TRPR-PCF-006 | `ACTIVE_MODE`/`ACTIVE_ANTENNA_EN`, packed into `ACTIVE_STATUS` (0x1D), latched from `MIMO_CTRL` only at safe-switch (IDLE) | T | `test_bypass_antenna.py` | ⚠️ Spec address fixed 2026-07-05 (was two separate registers at `0x30`/`0x31`, which are actually `W_0_RE_HI`/`W_0_RE_LO` weight-shadow bytes — see Register Address Reconciliation above). Test coverage is still partial: confirms the write→readback mux logic itself (`bypass_ant` selection), explicitly scoped to avoid the latch-timing behavior — no test writes `MIMO_CTRL` **during an active packet** to confirm the change is deferred rather than taking effect immediately. |
| TRPR-PCF-007 | Packet timeout via `PKT_TIMEOUT_SYMS` (0x0B) forces IDLE, asserts `PACKET_DONE` IRQ | T | `tb_trouper_two_packet.v` (job 3203), `cocotb/tests/test_w_missed_packet.py` (job 3305) | ✅ Spec address fixed 2026-07-05 (was `0x16`). The remaining gap — the `PACKET_DONE` IRQ bit itself — closed 2026-07-06: `test_w_missed_packet.py` writes `PKT_TIMEOUT_SYMS=20` pre-lock and polls `IRQ_STATUS[3]` firing on the timeout→IDLE transition, then confirms `PACKET_STATUS` reads idle and the receiver re-locks. |
| TRPR-PCF-008 | On IDLE entry: `buf_freeze` de-asserts, frontend buffer resumes | T | `cocotb/tests/test_w_missed_packet.py` (job 3310) | ✅ Closed 2026-07-06 (FSM half): `buf_freeze` confirmed de-asserted after the timeout→IDLE transition. The "frontend buffer resumes" half is moot in the current integration — `buf_freeze` drives nothing (PSRAM buffering is controlled by `packet_active`/replay state instead); see PCF-002 note. |
| TRPR-PCF-009 | `PACKET_STATUS` (0x1C) exposes PACKET_ACTIVE/PHASE/TRAINING_DONE/W_PENDING/W_VALID/W_MISSED_PACKET | I | `tb_trouper_spi.v` (RO-write-ignored), `cocotb/tests/test_w_missed_packet.py` (job 3305, live-packet bit content) | ✅ Closed 2026-07-06: bit content now checked over SPI *during a live packet* at three phases — W_PENDING (`PACKET_ACTIVE=1`, `PHASE=2`, `TRAINING_DONE=1`, `W_PENDING=1`, miss clear), post-miss PAYLOAD_ACTIVE (`PHASE=3`, `W_VALID=0`, `W_MISSED=1`), and IDLE (`PACKET_ACTIVE=0`, sticky miss held). Note this required the `W_missed_q` RTL fix (see PCF-005) — before it, bit[7] could never read 1. Residual: the `W_VALID=1` case at this register is untested (the committed-weights path reads it via `WGT_CTRL[1]` instead, `test_weight_gen_spi_flow.py`). |
| TRPR-PCF-010 | No deadlock: W_PENDING → timeout → IDLE when firmware absent/no `W_COMMIT` | T | `tb_trouper_two_packet.v` (job 3203) — every packet in this test completes via the timeout path since `W_COMMIT` is never sent | ✅ (functional — the test's entire premise depends on this path not deadlocking) |
| TRPR-PCF-011 | Mode 1 passthrough: route lowest-enabled antenna to remod, bypass training/weights | T | `test_bypass_antenna.py` (mux), `cocotb/tests/test_bypass_e2e.py` (job 3304, end-to-end) | ✅ Closed 2026-07-06 with one spec-wording nuance. The routing half is now proven end-to-end (see TRPR-RMD-008: selected antenna's raw sample reaches `sd_remod`, bit-exact, for masks 0xF→ant0 and 0xC→ant2), and committed weights are proven *ignored* in Mode 1 (`use_mrc_r=0` with non-trivial weights committed). Nuance: `packet_ctrl_fsm.v` has no Mode-1 special-casing — training accumulation still physically runs and `W_PENDING` still waits for `W_commit`/timeout; what Mode 1 "bypasses" is weight *application*, not weight/training *computation*. If the spec text means the latter, it needs a wording pass. |

**Open items surfaced by this pass:**
1. ~~**PCF-005 is an RTL fix with no regression test**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_w_missed_packet.py` (job 3305), which also found and regressed a second bug in the same area: the pulse-vs-readback wiring that made `PACKET_STATUS[7]`/`WGT_CTRL[3]` firmware-invisible (fixed via sticky `W_missed_q` in `packet_ctrl_fsm.v`). `DBG_MISSED_PKTS` (TRPR-WGN-008) still has no register and no coverage — unchanged.
2. ~~**`buf_freeze` (PCF-002/008) is completely untested**~~ — **CLOSED 2026-07-06** by `test_w_missed_packet.py` (job 3310): observed across start/hold/IDLE/re-start. Residual observation: `buf_freeze` currently drives nothing in `trouper_top` (dead output since the PSRAM migration) — a candidate for removal or re-purposing, see PCF-002/PCF-008 row notes.
3. **PCF-007/PCF-009 spec addresses are wrong** (0x16 vs real 0x0B; 0x34 vs real 0x1C) — same recurring class of stale-spec-text finding as three earlier blocks. Worth a dedicated pass reconciling every register address in the spec against `planning/Register Map.md` rather than finding these one block at a time.
4. ~~**PACKET_STATUS register content is essentially untested**~~ — **CLOSED 2026-07-06** by `test_w_missed_packet.py` (job 3305): bit content checked over SPI at W_PENDING, PAYLOAD_ACTIVE and IDLE phases (see PCF-009 row; only the `W_VALID=1` case at 0x1C remains indirect).
5. ~~**PCF-011's "bypass training/weights" claim is unverified**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_bypass_e2e.py` (job 3304): the selected antenna's data provably reaches the re-modulator in Mode 1 and committed weights are ignored. Residual: the spec's "bypass training" wording doesn't match the RTL (training still runs in Mode 1, its results are just unused) — see the PCF-011 row note.

---

## 4.8 MRC Combiner (`mrc_combiner.v`) — TRPR-MRC

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-MRC-001 | ŷ[n] = Σ conj(w_k)·x_k, x_k int8, w_k int16 Q1.15 | T | `tb_mrc_combiner.v`, `tb_mrc_fw_rand.v`, `tb_mrc_fw_precision.v`, `test_weight_gen_spi_flow.py` (job 3286, bit-exact vs. oracle) | ✅ |
| TRPR-MRC-002 | 18-bit acc; combined shift `>>>(8−pgs)`; saturate int8 | T | `tb_mrc_combiner.v` (pgs clip-boundary cases #4/#5), `test_remod_backoff.py` (job 3294, `sat_i`/`sat_q` clip confirmed via forced near-full-scale `comb_y`) | ✅ |
| TRPR-MRC-003 | 500 kS/s, one output per `iq_valid` | I | Every chain test sampling on `comb_y_valid` pulses (`test_weight_gen_spi_flow.py`, `test_remod_backoff.py`) | ✅ (functional) |
| TRPR-MRC-004 | Shadow bank promoted to `W_ACTIVE` atomically on `W_COMMIT` at a safe-switch boundary | T | `test_weight_gen_spi_flow.py` | ⚠️ **Spec describes an atomicity guarantee the RTL doesn't actually implement.** `mrc_combiner.v`'s `W_re0..W_im3` ports are wired directly to `rb_w_shadow` (`trouper_top.v:493-496`) — there is no separate `W_ACTIVE` latch gated on a "safe-switch boundary." The combiner just reads whatever is currently in the shadow bank each time it latches inputs at state 0 (once per ~500 kS/s sample). Functionally harmless in every test so far (weights are always written well before the next sample), but a mid-packet `W_SHADOW` rewrite would take effect within one combine cycle, not at a packet boundary as the spec implies. Not previously documented anywhere. |
| TRPR-MRC-005 | Before `W_COMMIT`: output bypass signal (lowest-enabled antenna, no weighting) | T | `test_bypass_antenna.py` (job 3276, Open Risks #4 fix), `cocotb/tests/test_bypass_e2e.py` (job 3304) | ✅ Closed 2026-07-06. `test_mode0_pretraining_auto_bypass` exercises the pre-training auto-fallback *as such*: in MRC mode (`MODE=0`) with no `W_COMMIT`, `comb_y` bit-equals the raw lowest-enabled-antenna sample for 40 clean pairings (`use_mrc_r=0` via `W_valid=0`, not via explicit bypass mode); after `W_COMMIT`, `use_mrc_r` flips to 1 and all 60 subsequent outputs diverge from the raw sample (weights applied). The mux itself remains covered 4/4 by `test_bypass_antenna.py`. |
| TRPR-MRC-006 | Weights stored as 4 complex int16 Q1.15 pairs at 0x30–0x3F | I | `test_weight_gen_spi_flow.py` | 🗑️ **Real precision gap, not just a stale claim.** `mrc_combiner.v` takes `signed [7:0]` weight inputs — only the HI byte of each Q1.15 pair (`W_0_RE_HI` at `0x30`, etc.) reaches the combiner; the LO byte (`0x31`, etc.) is write-only and silently discarded. Effective precision is Q0.7 (int8, ±127), not the full Q1.15 this requirement and the register names imply. Found while building `test_weight_gen_spi_flow.py` (job 3286); now documented in `planning/Register Map.md`'s `0x30`–`0x3F` section and Open Risks #33. Spec text needs updating to say Q0.7. |
| TRPR-MRC-007 | `COMB_POST_GAIN_SHIFT` (pgs) at `COMB_CFG` 0x0F[2:0], effective division 2^(8−pgs) | T | `tb_mrc_fw_rand.v` (job 2010, quantisation-loss figures cited directly in the spec text), `test_remod_backoff.py` (writes pgs via `COMB_CFG`) | ✅ Spec address fixed 2026-07-05 (was a standalone `0x36[2:0]` — see Register Address Reconciliation above). `COMB_POST_GAIN_SHIFT` is actually packed together with `REMOD_BACKOFF_SHIFT` at bits[5:4] in `COMB_CFG` (0x0F). |
| TRPR-MRC-008 | Post-combining SNR gain ≥ 5 dB vs. single-antenna (flat channel, equal power) | A | `sim/tests/run_ber.py` (Python `--nt 1` MRC sweep) | ✅ (Python model only — no RTL-level SNR-gain measurement, consistent with the requirement's `Verif=P` (Python) column) |
| TRPR-MRC-009 | AGC keeps branch amplitude ≤ −3 dBFS (≤90 counts) so combined sum fits after ÷2; int8 saturation is a safety net, not the normal path | P | — | ❌ Not testable at the RTL level — this requirement is about AGC's firmware control loop, which has no test at all (Open Risks #8). `test_remod_backoff.py` shows the combiner reaches near-full-scale (`comb_y` peak ~120, i.e. above the 90-count/−3 dBFS line) quite easily under a synthetic forced-weight stimulus — a reminder that the RTL provides no independent enforcement of this constraint; it depends entirely on AGC/firmware discipline plus the `REMOD_BACKOFF_SHIFT` margin (TRPR-RMD-004) as a second line of defense. |
| TRPR-MRC-010 | ŷ matches numpy `W@x` within ±2 LSB (int8) | T | `test_weight_gen_spi_flow.py` (job 3286) | ✅ **Exceeds requirement** — bit-exact (`max_err=0.00`), not just within ±2 LSB. |
| TRPR-MRC-011 | `WGT_CTRL` (0x1E) exposes `W_COMMIT`/`W_VALID`/`W_PENDING`/`W_MISSED_PACKET` | I | `tb_trouper_spi.v` (`W_COMMIT` W1P mechanics), `cocotb/tests/test_w_missed_packet.py` (job 3305) | ✅ Closed 2026-07-06: `W_PENDING` (bit[2]) and `W_MISSED_PACKET` (bit[3]) now read over SPI in a live packet — including that `W_MISSED` stays readable through IDLE and clears at the next packet start (needed the `W_missed_q` RTL fix, see PCF-005). `W_VALID` (bit[1]) is checked in the 0 case here and implicitly in the 1 case by `test_weight_gen_spi_flow.py`'s commit flow. |

**Open items surfaced by this pass:**
1. **MRC-006 is a real, previously-undocumented precision cliff**, not a stale-spec issue like the address mismatches elsewhere — the combiner silently drops half of every committed weight's precision. Now documented in the Register Map; spec text (`Trouper Chip Specification.md` TRPR-MRC-006) still says Q1.15 and should be corrected to Q0.7.
2. **MRC-004's "safe-switch boundary" atomicity is spec-only** — the RTL has no such latch; `rb_w_shadow` is read live every combine cycle. Harmless today but worth knowing before anyone relies on the promotion timing the spec describes.
3. **MRC-007/MRC-011 spec addresses are wrong** (`0x36`→real `0x0F`; `0x35`→real `0x1E`) — same recurring class as TAC-006/011, SCD-008/009, PCF-007/009. Reinforces the case for one dedicated spec-vs-register-map reconciliation pass rather than finding these piecemeal.
4. **MRC-009 (AGC-enforced input headroom) has zero RTL coverage** and can't have any until AGC firmware itself is tested (Open Risks #8) — cross-referenced, not a new finding.
5. ~~**MRC-005's pre-training auto-bypass trigger is untested as such**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_bypass_e2e.py::test_mode0_pretraining_auto_bypass` (job 3304): the `W_valid && !mode` trigger is exercised directly in both directions (bypass before `W_COMMIT`, MRC after).

---

## 4.9 ΣΔ Re-modulator (`sd_remod.v`) — TRPR-RMD

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-RMD-001 | 3rd-order ΣΔ, int8 I/Q → 1-bit I/Q | T | `tb_sd_remod.v`, `tb_remod_decim_const.v` | ✅ |
| TRPR-RMD-002 | 32 MS/s output, OSR=64 | T | `tb_sd_remod.v` (parametrised OSR), `test_remod_backoff.py` (`clk_per_iq=64` throughout) | ✅ |
| TRPR-RMD-003 | Saturating integrators; wrap-around prohibited (wrapped integrator ⇒ permanent instability) | T | `test_remod_backoff.py` (job 3294) | ✅ **with a methodology finding worth recording.** `sat16` structurally prevents literal register wraparound by construction (always clips to ±32767/−32768) — confirmed empirically across all forcing scenarios, integrator states never wrapped. But the requirement's "permanent instability" framing turned out not to be the right failure signature to test *for*: even a forced near-full-scale input recovers from railing rather than sticking forever (job 3290-3292 diagnostics) — s3 sits near the rail even during definitely-healthy low-amplitude operation, which is normal CIFF cascade behavior, not a fault. The real, correct instability signature for a 1-bit noise shaper is the **quantizer output losing its dither** (frozen for an extended run), which is what the test actually measures (see RMD-004/006 below). |
| TRPR-RMD-004 | Input strictly < −3 dBFS (<90 counts); over-range SHALL be detected/flagged or prevented by AGC | T | `test_remod_backoff.py` (job 3294, `REMOD_BACKOFF_SHIFT` register) | ⚠️ Confirms the RTL mechanism (`REMOD_BACKOFF_SHIFT`) that provides margin against this constraint works end-to-end and measurably reduces output-freezing severity at a forced near-full-scale input. But neither of the requirement's two named mitigations exists as tested: there is no on-chip detection/flag for an over-range remod input, and AGC-based prevention is completely untested (Open Risks #8) — the backoff shift is a third, structural mitigation not named in the requirement text. |
| TRPR-RMD-005 | In-band SQNR > 40 dB at −6 dBFS | T | `tb_sd_remod.v` (SQNR ≈ 55 dB, correlation-threshold check) | ✅ |
| TRPR-RMD-006 | Stable (no divergence) for any int8 input in [−90, +90] | T | `test_remod_backoff.py` (job 3294: healthy at `comb_y` peak=30 and at `shift=1`'s effective remod input ≈60, both within ±90 — output stuck-run stays at the healthy baseline, 43-68 cycles) | ⚠️ Corroborating evidence at two points inside the claimed range, not an exhaustive sweep of it. No test drives the input at or near the ±90 boundary itself. |
| TRPR-RMD-007 | Re-demod matches int8 input ±1 LSB RMS at −6 dBFS | T | `tb_sd_remod.v` | ✅ |
| TRPR-RMD-008 | Mode 1 passthrough: remod receives single-antenna stream directly | T | `cocotb/tests/test_bypass_e2e.py` (job 3304) | ✅ Closed 2026-07-06. `test_mode1_e2e_ant0`/`_ant2` drive real `MIMO_CTRL.MODE=1` end-to-end with per-antenna-distinct CW amplitudes: during PSRAM REPLAY, `remod_in_i/q == comb_y_i/q ==` the selected antenna's raw combiner-input sample, bit-exact at `REMOD_BACKOFF_SHIFT=0`, with `psram_silence=0` and `REMOD_A_I` toggling. Deliberately non-trivial committed weights (0x40 in every W-shadow byte) are proven ignored (`use_mrc_r=0`). The PSRAM-replay-delay complication that made `test_remod_backoff.py` avoid true bypass is sidestepped by comparing combiner input→output rather than against the original stimulus. |

**Open items surfaced by this pass:**
1. **RMD-003's "permanent instability" framing doesn't match observed RTL behavior** — `sat16` prevents literal wraparound, and even adversarial forcing doesn't produce a signal that stays stuck forever; it produces measurably more frequent output-freezing instead. Worth a spec wording pass so future test-writers don't repeat the same false start (three wasted job iterations, 3290-3292, chasing a "stuck forever" signature that isn't how this RTL actually fails).
2. **RMD-004's detect/flag mitigation doesn't exist on-chip**, and its AGC-prevention alternative is untested (Open Risks #8) — the only proven mitigation is the `REMOD_BACKOFF_SHIFT` margin itself.
3. **RMD-006 is only spot-checked at two amplitudes**, not swept across the full claimed stable range.
4. ~~**RMD-008 / MRC-005 / PCF-011 all converge on the same untested claim**~~ — **CLOSED 2026-07-06** by exactly the single test proposed here: `cocotb/tests/test_bypass_e2e.py` (Verilator, job 3304, 3/3 PASS) drives real `MIMO_CTRL.MODE=1` end-to-end with per-antenna-distinct amplitudes and confirms `remod_in_i/q` tracks the selected antenna's raw decimated sample bit-exact, with committed weights ignored. Also picked up `PSRAM_STATUS.REPLAY_ACTIVE` register-level readback (PSR-006, now 2/7 bits) for free.
