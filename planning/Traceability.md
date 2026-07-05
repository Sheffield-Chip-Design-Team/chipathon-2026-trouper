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

## Register Address Reconciliation

While building the per-block sections below, individual requirements kept citing
register addresses that don't match `planning/Register Map.md`. This section is
the full sweep: every `0x..` address cited anywhere in `Trouper Chip
Specification.md`'s `TRPR-*` rows, cross-checked against the active register
table. It covers the **whole spec**, not just the blocks traced so far — so it
includes findings (WGN, AGC) for blocks that don't have a traceability section
yet.

Root cause, in every case checked: the register map was reshuffled at least
twice (the 128-register repack, and the Zdiag 16→24-bit widening in commit
`46e1da0`) and the spec's per-requirement address citations were never
re-swept afterward. None of these are RTL bugs — the RTL and `Register
Map.md` agree with each other throughout; only the spec text lags.

| Requirement | Spec says | Actually is | Note |
|---|---|---|---|
| TRPR-TAC-005 | `ZDIAG_k` at 0x64–0x6B, 16-bit | `ZDIAG_0..3` at **0x64–0x6F**, 24-bit each | Stale since the Zdiag widening fix (`46e1da0`) |
| TRPR-TAC-006 | `Z_SHIFT` at 0x63 | *(removed — hardwired 0)* | Register retired, spec never updated |
| TRPR-TAC-008 | `TRAINING_STATUS` at 0x60 | **0x20** | 0x60 is unallocated in the current map |
| TRPR-TAC-011 | `TACC_REF_SEL` at 0x6B | *(removed — superseded by `TACC_NOISE_TRIG`)* | Register retired, spec never updated |
| TRPR-SCD-008 | `SC_HITS_REQ` at 0x1B | **0x0E** | RTL and tests both correctly use 0x0E |
| TRPR-SCD-009 | `SC_STAT` at 0x50–0x51 | `SC_STAT_HI/LO` at **0x24–0x25** | Also untested at either address |
| TRPR-PCF-006 | `ACTIVE_MODE`/`ACTIVE_ANTENNA_EN` at 0x30/0x31 | Packed into `ACTIVE_STATUS` at **0x1D** | 0x30/0x31 are actually `W_0_RE_HI/LO` — collision risk |
| TRPR-PCF-007 | `PKT_TIMEOUT_SYMS` at 0x16 | **0x0B** | RTL and tests both correctly use 0x0B |
| TRPR-PCF-009 | `PACKET_STATUS` at 0x34 | **0x1C** | 0x34 is actually `W_1_RE_HI` — collision risk |
| TRPR-MRC-007 | `COMB_POST_GAIN_SHIFT` at 0x36[2:0] | `COMB_CFG` at **0x0F**[2:0] | 0x36 is actually `W_1_IM_HI` — collision risk |
| TRPR-MRC-011 | `WGT_CTRL` at 0x35 | **0x1E** | 0x35 is actually `W_1_RE_LO` — collision risk |
| TRPR-WGN-006 | `ZDIAG_k` at 0x64–0x6B, bits [31:16] | **0x64–0x6F**, bits [31:8] | Same widening staleness as TAC-005, plus wrong bit slice — a firmware author following this spec text verbatim would misread every Zdiag value |
| TRPR-AGC-001 | Zdiag at 0x64–0x6B | **0x64–0x6F** | Same widening staleness as TAC-005/WGN-006 |
| TRPR-AGC-002 | `AGC_THR_HI` at 0x2B–0x2C, `AGC_THR_SAT` at 0x2D–0x2E | *(removed — never implemented in RTL, AGC comparison is software-owned)* | 0x2B–0x2E are actually `SC_FIRST_HIT`/`SC_LOCK_SNAP` — collision risk. This requirement describes hardware comparator registers that were never built; the strategy itself (max-gain-before-saturation) is real, but entirely a firmware/host computation with no on-chip threshold registers to point at |

**Checked clean** (address citations that do match the current register map,
included for completeness since they were part of the same sweep): SPS-002,
SPS-006 (`CHIP_ID` 0x00), SPS-010/011 (`PSRAM_DBG_DATA` 0x76, `0x7F` reserved),
REG-004, REG-006 (`TACC_NOISE_TRIG` 0x1F, `WGT_CTRL.W_COMMIT` 0x1E, `RX_GAIN_COMMIT`
0x18, `PSRAM_CLR_ERR` 0x70, `PSRAM_DBG_CTRL.RD_TRIG` 0x75), REG-007/IRQ-001/002/006
(`IRQ_STATUS` 0x02, `IRQ_CLEAR` 0x03), AGC-003 (`RX_GAIN_SHADOW`/`ACTIVE` 0x10–0x17),
AGC-004 (`TACC_NOISE_TRIG` 0x1F), INT-002/009 (0x00–0x7F range, W shadow 0x30–0x3F,
`WGT_CTRL` 0x1E), TAC-002/003/004/007 (Z pairs 0x40–0x63, `N_ACC` 0x21–0x23,
`TACC_WINDOW_SYMS` 0x27), PSR-006/007/009/010/017/020 (`PSRAM_STATUS` 0x71,
`PSRAM_CTRL` 0x70, `PSRAM_DBG_*` 0x72–0x76), SCD-010/011/012, WGN-003/007/009.

**Two distinct classes of finding, worth keeping separate when acting on this:**
1. **Wrong address for a register that exists** (TAC-008, SCD-008/009, PCF-006/007/009,
   MRC-007/011) — a pure spec-text fix: update the hex address to match
   `Register Map.md`. Several of these point at addresses that are now *other*
   live registers (weight-shadow bytes, mostly), so anyone hand-implementing
   firmware straight from the spec table would silently corrupt or misread
   unrelated state.
2. **Register removed or never implemented** (TAC-006/011, AGC-002) — not a
   simple address swap. These requirements describe functionality that was
   deliberately cut; the spec text needs to either be retired/reworded to
   match current scope, or (for AGC-002 specifically) reworded to make clear
   the strategy is real but purely a firmware/host computation with no
   on-chip register to back it.

**Suggested next step:** a single editing pass over `Trouper Chip
Specification.md` fixing every address in the left column above to the
middle/right column, plus a one-line note on TAC-006/011 and AGC-002 that the
referenced register doesn't exist. This doesn't require writing any new
tests — it's pure spec-text correction, orthogonal to the coverage gaps
tracked in the per-block sections below.

---

## 4.5 Training Accumulator (`training_acc.v`) — TRPR-TAC

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-TAC-001 | Compute 6 off-diag Z_kl + 4 diag Z_kk | T | `tb_training_acc_equiv.v`, `tb_dsp_chain_rand.v` (job 1789), `sim/tests/test_training_allpairs_stress.py` | ✅ |
| TRPR-TAC-002 | Window controlled by `TACC_WINDOW_SYMS`, reset clamps to 8 | T | `tb_training_acc_equiv.v`, `tb_tacc_resetless_equiv.v` | ✅ |
| TRPR-TAC-003 | `training_done` asserts; `n_acc` latched 18-bit | T | `tb_training_acc_equiv.v`, `tb_tacc_resetless_equiv.v` | ✅ |
| TRPR-TAC-004 | Z_kl readback format, 0x40–0x63, 24-bit BE | T | `test_weight_gen_spi_flow.py` (job 3286) | ✅ (via SPI, real capture data) |
| TRPR-TAC-005 | Zdiag readback 0x64–0x6B, 16-bit | T | `test_weight_gen_spi_flow.py` (job 3286) | 🗑️ **Spec is stale on both address range and width** (see Register Address Reconciliation below) — actual `ZDIAG_0..3` span `0x64`–`0x6F`, 24-bit each (widened by commit `46e1da0`, "widen Zdiag readback from top-16 to top-24 bits"). The test itself reads the correct current registers; only the spec text lagged the fix. |
| TRPR-TAC-006 | Common right-shift `Z_SHIFT` (0x63) applied to Z_kl | T | — | 🗑️ **`Z_SHIFT` (0x63–0x69) is hardwired 0 in `trouper_top`, per `planning/Register Map.md` "Former addresses" table** — the register this requirement describes does not exist in current RTL. Spec is stale; needs reconciling (either restore the register or retire/reword TAC-006). |
| TRPR-TAC-007 | Firmware noise-trigger mode (`TACC_NOISE_TRIG`) | T | `tb_trouper_spi.v` (W1P self-clear only) | ⚠️ Only the register self-clear behavior is tested (overlaps TRPR-REG-006). The actual noise-accumulation *function* (arm without `sc_lock`, Z_kl≈0, Zdiag≈σ²·n_acc) has no dedicated test. |
| TRPR-TAC-008 | `TRAINING_STATUS` (0x60) exposes DONE/ARMED bits | T | `tb_training_acc_equiv.v`, `tb_tacc_resetless_equiv.v` (internal `training_done`/`training_armed` signals only) | 🗑️⚠️ **Spec gives the wrong address** (see Register Address Reconciliation below) — `TRAINING_STATUS` is at **0x20**, not `0x60` (`0x60` is unallocated in the current 128-register map). Coverage is also still only at the RTL signal level: no test reads register 0x20 directly over SPI/AHB to confirm the bit mapping. |
| TRPR-TAC-009 | Z_kl/n_acc matches Python `h_k·conj(h_l)` within Q1.15 | T | `test_weight_gen_spi_flow.py` (job 3286, oracle compare), `sim/tests/test_eigvec_fw.py` | ✅ |
| TRPR-TAC-010 | Auto-reset on each `sc_lock` | T | `tb_tacc_resetless_equiv.v` (B2, job — see `project_area_cuts_b1_banked_b2_rejected_3v` memory), `test_capture_two_packet.py` (job 3273, real-capture two-packet re-arm) | ✅ |
| TRPR-TAC-011 | `TACC_REF_SEL` (0x6B) legacy, no functional effect | I | — | 🗑️ Same issue as TAC-006: `TACC_REF_SEL` (0x6A–0x6B) is in the register map's "Former addresses / removed" table, superseded by `TACC_NOISE_TRIG`. Requirement describes a register that no longer exists — spec is stale. |

**Open items surfaced by this pass:**
1. **TAC-006 / TAC-011 spec-RTL mismatch** — both requirements describe registers (`Z_SHIFT`, `TACC_REF_SEL`) that `planning/Register Map.md` lists as removed/hardwired-0. These aren't test gaps, they're stale spec text — needs a spec update pass, not a test.
2. **TAC-007 functional gap** — noise-trigger *mode* (vs. just the W1P bit mechanics) has no end-to-end test. Would be a natural extension of `test_weight_gen_spi_flow.py`.
3. **TAC-008 register-level gap** — `TRAINING_STATUS` (0x60) bit readback over SPI/AHB isn't directly tested, only the underlying signals.

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
| TRPR-SCD-005 | `timing_ref = lock_sample − (SC_HITS_REQ+1)·M + 1` | T | — | ⚠️ `timing_ref` is exercised (feeds `training_acc`'s window) in every DSP-chain testbench, but no test asserts its value against the closed-form formula directly — correctness is only inferred indirectly through downstream Z-value correctness. |
| TRPR-SCD-006 | RTL operates on antenna branch 0 only (by design) | I | — | ℹ️ Not a testable requirement — it's a documented design limitation. Tracked as an open risk: `planning/sc-detector-ant0-fading-risk.md` (ant0 deep-fade SPOF, no 4-branch pooling before lock). |
| TRPR-SCD-007 | `SC_THR_HI/LO` (0x0C/0x0D) writable, RTL consumes low 12 bits, reset default `0x01CC` | I | `tb_trouper_top.v`, `test_trouper_top.py` (write `SC_THR_HI/LO` over SPI) | ⚠️ Write path exercised; reset-default value (`0x01CC`) not asserted anywhere. |
| TRPR-SCD-008 | `SC_HITS_REQ` configurable via register **0x1B** | T | `test_trouper_top.py`, `tb_trouper_top.v` (write via SPI) | 🗑️ **Spec gives the wrong address.** `planning/Register Map.md` (line 40) has `SC_HITS_REQ` at **0x0E**, and both tests write `0x0E` — matches current RTL, not the `0x1B` the spec text cites. Spec is stale. |
| TRPR-SCD-009 | `SC_STAT` (spec says 0x50–0x51) exposes `\|C[s]\|²` telemetry | I | — | 🗑️ **Spec gives the wrong address.** Register Map has `SC_STAT_HI/LO` at **0x24/0x25**, not `0x50–0x51`. No test reads it at either address — untested regardless of the address mismatch. |
| TRPR-SCD-010 | Debug regs `SC_DBG_FLAGS` (0x26), `SC_FIRST_HIT` (0x28–0x2B), `SC_LOCK_SNAP` (0x2C–0x2F) | T | — | ❌ Addresses match the current register map, but no test reads any of these three registers over SPI/AHB. |
| TRPR-SCD-011 | `CORR_MAG_n` (0x48–0x4F) reserved, tied to 0 | I | — | ✅ (by inspection — matches Register Map "Former addresses" table; nothing to functionally test) |
| TRPR-SCD-012 | `C_POOL_I/Q` (0x64–0x67) reserved, tied to 0 | I | — | ✅ (by inspection — matches Register Map; nothing to functionally test) |
| TRPR-SCD-013 | `sc_lock` within ±1 symbol of Python model, SF7/125 kHz/0 dB SNR | T | `sim/tests/test_sync.py` (Python-only) | ⚠️ Python reference model is tested against itself; no test compares **RTL** `sc_lock` timing directly against the Python block-model prediction — the gap this requirement is actually about. |
| TRPR-SCD-014 | `sc_lock` de-asserts and re-arms on Packet Control FSM → IDLE | T | `tb_trouper_two_packet.v` (job 3203), `test_capture_two_packet.py` (job 3273, real capture) | ✅ |
| TRPR-SCD-015 | `ENERGY_GATE_EN` reserved, left at 0 (energy gating not implemented) | I | — | ✅ (by inspection — `noise_est.v` energy gating removed per Register Map "Former addresses") |
| TRPR-SCD-016 | e_slice guard suppresses hits when `eval_e_acc[25:13] == 0` | I | `test_trouper_top.py`, `tb_trouper_top.v` | ⚠️ Only exercised in the "guard passes" direction (stimulus amplitude chosen to clear the ≥27-count threshold). No negative-case test confirms a genuinely low-energy hit gets suppressed. |

**Open items surfaced by this pass:**
1. **SCD-008 / SCD-009 spec-RTL address mismatches** — `SC_HITS_REQ` is at `0x0E` in the register map (RTL matches), not the `0x1B` the spec cites; `SC_STAT` is at `0x24–0x25` (RTL matches), not `0x50–0x51`. Same pattern as the TAC-006/TAC-011 findings — spec text drifted from the register map after address reshuffles.
2. **No isolated `sc_detector` testbench** — every test instantiates it inside the full DSP chain or `trouper_top`. Fine for integration confidence, but harder to pin down which requirement a given chain-level pass/fail actually validates.
3. **Debug/telemetry register readback untested** — `SC_DBG_FLAGS`, `SC_FIRST_HIT`, `SC_LOCK_SNAP`, `SC_STAT` are never read over SPI/AHB by any test, despite existing and being wired correctly per the register map.
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
| TRPR-PSR-004 | `REPLAY_MISSED` asserts/latches if `W_COMMIT` is late; combiner falls back to next-packet weights | T | formal `a_replay_missed_cause`, `a_replay_missed_sticky` (flag correctness only) | ⚠️ Formal proves the flag sets and stays sticky under the documented condition. No RTL-sim test actually drives a late `W_COMMIT` and checks the combiner's fallback-to-next-packet behavior — every sim test commits weights well before the window closes. |
| TRPR-PSR-005 | 8 bytes/sample storage, order i0,q0,i1,q1,i2,q2,i3,q3 | T | `test_capture_playback.py`, `test_weight_gen_spi_flow.py` (byte order implicitly confirmed — replayed/read-back samples only match reference if order is correct) | ✅ (functional, no test asserts byte order in isolation) |
| TRPR-PSR-013 | Nominal write rate 2 MB/s, ~3% of device capacity | A | — | ✅ (analysis-only per spec `Verif` column; arithmetic, not a test target) |
| TRPR-PSR-014 | QPI timing headroom: 20 spare cycles (write), 8 spare (replay) | A | Formal `a_no_drive_during_dummy`, `a_ce_n_matches_activity` indirectly confirm no overrun; `test_startup.py` timing measurements | ✅ (analysis + formal bus-timing safety) |
| TRPR-PSR-015 | Max buffer depth ≈256 kB at SF12, no overflow ≤ SF12 | A/T | Formal `a_gap_invariant` (bounded backlog), `test_capture_playback.py` SF sweep | ✅ |
| TRPR-PSR-006 | `PSRAM_STATUS` (0x71) bit layout: state/SAMPLE_SKIP/INIT_DONE/REPLAY_ACTIVE/REPLAY_MISSED/OVERFLOW/BUF_ACTIVE | I | `test_trouper_top.py`, `tb_trouper_top.v` (poll `INIT_DONE` bit[3] only) | ⚠️ Only `INIT_DONE` is ever read back over SPI. The other 6 bits (`state`, `SAMPLE_SKIP`, `REPLAY_ACTIVE`, `REPLAY_MISSED`, `OVERFLOW`, `BUF_ACTIVE`) are proven correct as internal *signals* by the formal proof (group C, `a_buf_active_*`, `a_replay_active_matches_state`) but never verified at their **register bit positions** via SPI/AHB. |
| TRPR-PSR-007 | Sticky flags clearable via `PSRAM_CLR_ERR` (0x70[1]); simultaneous set+clear not lost | T | `tb_trouper_spi.v` (W1P self-clear mechanics only), formal `a_replay_missed_sticky`/`a_sample_skip_cause` (found and fixed a same-cycle `clr_err`-timing bug in the proof itself, 2026-07-05) | ✅ (formal covers the actual race the requirement is about; RTL-sim only covers the register mechanics) |
| TRPR-PSR-008 | *DELETED* (`PSRAM_PKT_BYTES` removed) | — | — | — n/a |
| TRPR-PSR-009 | `PSRAM_EN=0` disable mode: idle, no QSPI pad assertion | T | formal `a_buf_active_needs_en` | ✅ |
| TRPR-PSR-010 | `QSPI_OWNER` selects active master; owner 1 suspends buffering/replay, tri-states pads | T | — | ❌ No RTL-sim or formal property found that exercises `QSPI_OWNER=1` and checks CE#/SCK/SIO tri-state behavior. `tb_trouper_spi.v` only exercises `PSRAM_CTRL` bit masking, not this specific ownership-transfer behavior. |
| TRPR-PSR-011 | `QSPI_OWNER` writes during BUFFERING/REPLAY don't glitch pads; effect only at IDLE | T | — | ❌ Same gap as PSR-010 — no test drives a `QSPI_OWNER` write mid-BUFFERING/REPLAY to confirm the deferred-effect behavior. |
| TRPR-PSR-012 | `PAD_CONFLICT` asserts on simultaneous multi-driver pad conflict | T | — | ❌ No test found. Low priority (`Pri: L` in spec) but zero coverage. |
| TRPR-PSR-016 | SC delay reads at `write_ptr − M`, interleaved with writes, cease after `sc_lock` | T | `test_capture_playback.py` (delayed-sample correctness via full-chain sc_lock), formal `a_del_valid_needs_rdy`, `a_del_cnt_bounded` | ✅ |
| TRPR-PSR-017 | PSRAM debug readback protocol (host SPI): addr write → RD_TRIG → poll DBG_BUSY → read 8 data bytes → AUTO_INC | T | `tb_trouper_spi.v` (DBG_BUSY pre-init state, addr write/readback, RD_TRIG self-clear — register mechanics only) | ⚠️ No test performs a full readback that verifies actual **data content** (i0,q0,i1,q1,...) matches what was written to PSRAM, nor exercises `AUTO_INC` advancing through multiple 8-byte fetches. Formal section E (bounded `dbg_fetch_busy` response) is parked/disabled (see note below) — not currently a proven property. |
| TRPR-PSR-018 | QPI-only interface mandate (no SPI/1-bit mode) | A | — | ✅ (by construction — RTL has no 1-bit mode to test against) |
| TRPR-PSR-019 | SF fixed per session; re-arm SC delay warm-up on `sf`/`sample_shift` change | T | `cocotb/tests/test_startup.py::test_sc_correlator_idle_until_del_rdy` (warm-up latency at fixed SF/BW only) | ⚠️ Warm-up hold-off itself is verified (measured SF9/BW125 at 4.092 ms vs 4.096 ms predicted). The re-arm-on-**change** clause specifically is untested — no test changes `sf`/`sample_shift` mid-session (formal explicitly *assumes* these are session-constant, `m_sf_valid_range`/`m_sample_shift_valid_range`, to keep the proof tractable). |
| TRPR-PSR-020 | Sticky `SAMPLE_SKIP` flag; spec claims "verified by a directed sustained-`iq_valid` test... at 125 and 250 kHz" | T | — | 🗑️ **The test the spec text describes does not exist.** No file in the repo references `SAMPLE_SKIP`/`sample_skip` outside `psram_buf_ctrl.v` itself and the formal proof (`a_sample_skip_cause`, which proves the flag's *cause* condition, not a directed "SAMPLE_SKIP stays 0 across a full packet" regression). This is a spec claim about verification coverage that isn't backed by an actual test — should either be written or the claim removed. |

**Open items surfaced by this pass:**
1. **PSR-020 is a false verification claim in the spec itself** — the spec text asserts a specific directed test exists and passes; no such test is in the repo. This is a different class of problem than the earlier stale-address findings (TAC-006/011, SCD-008/009) — those were wrong *addresses*, this is a wrong *claim about test coverage*.
2. **`QSPI_OWNER` handover (PSR-010/PSR-011) has zero test coverage**, RTL-sim or formal, despite being a `C`/`H` priority requirement with defined pad-safety behavior (no glitching, deferred-until-IDLE effect).
3. **PSR-004 replay-miss fallback is only proven at the flag level**, never exercised as an actual late-`W_COMMIT` scenario through the combiner.
4. **PSR-017 debug readback is only mechanically tested** (register plumbing) — no test confirms the actual 8 bytes read back match real stored PSRAM content, and the formal liveness property for it is parked/disabled (see `formal/psram_buf_ctrl_formal.sv` section E comments — recast as a safety property requiring a fairness assumption not yet established).
5. **PSR-006 status-bit register mapping is 1/7 tested** over SPI (`INIT_DONE` only); the other six bits' correctness is proven at the signal level by formal but never checked at their register bit positions.
6. **PSR-001's real gap (tPU wait) is known and tracked** (Open Risks #27, `[[project_startup_delay_risks]]` memory) — flagged here for cross-reference, not a new finding.

---

## 4.7 Packet Control FSM (`packet_ctrl_fsm.v`) — TRPR-PCF

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-PCF-001 | 4 states IDLE→PREAMBLE_ACQ→W_PENDING→PAYLOAD_ACTIVE→IDLE | T | `tb_trouper_top.v`, `tb_trouper_two_packet.v` (job 3203), `test_capture_two_packet.py` (job 3273) — sequence inferred from IRQ timeline (`t_sc_lock`/`t_train_done`/`t_w_commit` cycle stamps) | ⚠️ The overall sequence order is confirmed via IRQ events, but no test reads `PACKET_STATUS.PACKET_PHASE[2:0]` directly to confirm the FSM is actually in the state the sequence implies. |
| TRPR-PCF-002 | On `sc_lock`: assert `buf_freeze`, → PREAMBLE_ACQ | T | — | ❌ No test found. `buf_freeze` only appears in unrelated testbenches as a hardwired-0 unused port on `frontend_buf_ctrl`/decimator standalone tests, never observed as an output of `packet_ctrl_fsm` in any chain test. |
| TRPR-PCF-003 | On `training_done`: → W_PENDING, assert `TRAINING_DONE` IRQ | T | `test_weight_gen_spi_flow.py` (job 3286, `IRQ_STATUS[TRAINING_DONE]`) | ✅ |
| TRPR-PCF-004 | On `W_COMMIT`: latch `W_ACTIVE` at safe-switch boundary, → PAYLOAD_ACTIVE | T | `test_weight_gen_spi_flow.py`, `test_capture_playback.py` (`W_COMMIT`→`WGT_CTRL[1]` W_VALID→combiner uses committed weight) | ✅ (via `WGT_CTRL`, not `PACKET_STATUS`, mirror — see PCF-009) |
| TRPR-PCF-005 | No `W_COMMIT` before payload boundary → stay in bypass, set `W_MISSED_PACKET`, assert IRQ | T | — | ❌ **RTL fix landed (commit `46e1da0`: "packet_ctrl_fsm: set W_missed_packet on the wpend timeout path when W_valid never arrived") with no accompanying regression test.** `W_MISSED_PACKET`/`DBG_MISSED_PKTS` have zero references anywhere in `rtl-test/tb/` or `cocotb/tests/`. |
| TRPR-PCF-006 | `ACTIVE_MODE` (spec says 0x30)/`ACTIVE_ANTENNA_EN` (spec says 0x31) latched from `MIMO_CTRL` only at safe-switch (IDLE) | T | `test_bypass_antenna.py` | 🗑️⚠️ **Spec gives the wrong addresses** (see Register Address Reconciliation below) — both bits are actually packed into a single register, `ACTIVE_STATUS` at **0x1D** (`[1:0]`=`ACTIVE_MODE`, `[7:4]`=`ACTIVE_ANTENNA_EN`); `0x30`/`0x31` are actually `W_0_RE_HI`/`W_0_RE_LO` (weight shadow bytes) — another real collision risk, same shape as PCF-009's `PACKET_STATUS`/`W_re1` collision. Test coverage is also still partial: confirms the write→readback mux logic itself (`bypass_ant` selection), explicitly scoped to avoid the latch-timing behavior — no test writes `MIMO_CTRL` **during an active packet** to confirm the change is deferred rather than taking effect immediately. |
| TRPR-PCF-007 | Packet timeout via `PKT_TIMEOUT_SYMS` (spec says 0x16) forces IDLE, asserts `PACKET_DONE` IRQ | T | `tb_trouper_two_packet.v` (writes `PKT_TIMEOUT_SYMS` at **0x0B**, job 3203) | 🗑️ **Spec gives the wrong address** — `planning/Register Map.md` (line 37) and the test both use `0x0B`, not the `0x16` the spec text cites. Same stale-address pattern as TAC-006/011, SCD-008/009, PCF-009. Functionally, the timeout path is exercised (FSM does return to IDLE and re-lock without ever sending `W_COMMIT`), but no test explicitly checks the `PACKET_DONE` IRQ bit fires on that transition. |
| TRPR-PCF-008 | On IDLE entry: `buf_freeze` de-asserts, frontend buffer resumes | T | — | ❌ No test found — same gap as PCF-002, `buf_freeze` is never observed coming out of `packet_ctrl_fsm` in any test. |
| TRPR-PCF-009 | `PACKET_STATUS` (spec says 0x34) exposes PACKET_ACTIVE/PHASE/TRAINING_DONE/W_PENDING/W_VALID/W_MISSED_PACKET | I | `tb_trouper_spi.v` (RO-write-ignored check only) | 🗑️ **Spec gives the wrong address.** Register Map (line 54) has `PACKET_STATUS` at **0x1C**; spec's `0x34` is actually the `W_re1` weight-shadow byte (see `tb_trouper_top.v:430`) — a real collision risk if anyone trusted the spec's address. Coverage itself is also weak: the only test touching `0x1C` confirms it's read-only, never checks its bit *content* during a live packet. |
| TRPR-PCF-010 | No deadlock: W_PENDING → timeout → IDLE when firmware absent/no `W_COMMIT` | T | `tb_trouper_two_packet.v` (job 3203) — every packet in this test completes via the timeout path since `W_COMMIT` is never sent | ✅ (functional — the test's entire premise depends on this path not deadlocking) |
| TRPR-PCF-011 | Mode 1 passthrough: route lowest-enabled antenna to remod, bypass training/weights | T | `test_bypass_antenna.py` (antenna-select mux logic only, explicitly scoped) | ⚠️ Mux selection is proven correct (4/4 cases). The requirement's second half — that training accumulation and weight computation are actually bypassed and the selected antenna reaches the re-modulator — is explicitly out of scope for this test per its own docstring ("without needing bypass mode's downstream"), and no other test covers it. |

**Open items surfaced by this pass:**
1. **PCF-005 is an RTL fix with no regression test** — this is a sharper version of the pattern seen elsewhere: the fix commit (`46e1da0`) explicitly describes the behavior change, but unlike the sc_lock re-arm fix in the same era (which got `tb_trouper_two_packet.v` + `test_capture_two_packet.py`), `W_missed_packet` got no test coverage at all.
2. **`buf_freeze` (PCF-002/008) is completely untested** as an output of `packet_ctrl_fsm` — every reference to it in the test tree is as a hardwired-0 unused input on unrelated standalone-block testbenches.
3. **PCF-007/PCF-009 spec addresses are wrong** (0x16 vs real 0x0B; 0x34 vs real 0x1C) — same recurring class of stale-spec-text finding as three earlier blocks. Worth a dedicated pass reconciling every register address in the spec against `planning/Register Map.md` rather than finding these one block at a time.
4. **PACKET_STATUS register content is essentially untested** — only its read-only-ness is checked, never its actual bits during a live packet (same shape of gap as PSR-006's status register).
5. **PCF-011's "bypass training/weights" claim is unverified** — only the antenna-select mux is tested; nothing confirms training_acc/weight_gen are actually skipped or that the selected antenna's data reaches the re-modulator in Mode 1.

---

## 4.8 MRC Combiner (`mrc_combiner.v`) — TRPR-MRC

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-MRC-001 | ŷ[n] = Σ conj(w_k)·x_k, x_k int8, w_k int16 Q1.15 | T | `tb_mrc_combiner.v`, `tb_mrc_fw_rand.v`, `tb_mrc_fw_precision.v`, `test_weight_gen_spi_flow.py` (job 3286, bit-exact vs. oracle) | ✅ |
| TRPR-MRC-002 | 18-bit acc; combined shift `>>>(8−pgs)`; saturate int8 | T | `tb_mrc_combiner.v` (pgs clip-boundary cases #4/#5), `test_remod_backoff.py` (job 3294, `sat_i`/`sat_q` clip confirmed via forced near-full-scale `comb_y`) | ✅ |
| TRPR-MRC-003 | 500 kS/s, one output per `iq_valid` | I | Every chain test sampling on `comb_y_valid` pulses (`test_weight_gen_spi_flow.py`, `test_remod_backoff.py`) | ✅ (functional) |
| TRPR-MRC-004 | Shadow bank promoted to `W_ACTIVE` atomically on `W_COMMIT` at a safe-switch boundary | T | `test_weight_gen_spi_flow.py` | ⚠️ **Spec describes an atomicity guarantee the RTL doesn't actually implement.** `mrc_combiner.v`'s `W_re0..W_im3` ports are wired directly to `rb_w_shadow` (`trouper_top.v:493-496`) — there is no separate `W_ACTIVE` latch gated on a "safe-switch boundary." The combiner just reads whatever is currently in the shadow bank each time it latches inputs at state 0 (once per ~500 kS/s sample). Functionally harmless in every test so far (weights are always written well before the next sample), but a mid-packet `W_SHADOW` rewrite would take effect within one combine cycle, not at a packet boundary as the spec implies. Not previously documented anywhere. |
| TRPR-MRC-005 | Before `W_COMMIT`: output bypass signal (lowest-enabled antenna, no weighting) | T | `test_bypass_antenna.py` (job 3276, Open Risks #4 fix) | ⚠️ The antenna-select mux (`bypass_ant` = lowest enabled bit) is proven correct 4/4 cases — this is the mux TRPR-MRC-005's bypass path depends on, and was the subject of a real bug fix (Open Risks #4: previously selected antenna 1, not the lowest-enabled). But the test drives bypass via explicit `MIMO_CTRL.MODE=1`, not the "no `W_COMMIT` yet" pre-training auto-fallback (`use_mrc_r <= W_valid && !mode` — same `bypass_ant` wire serves both cases, but the *pre-training* trigger condition itself is never directly exercised as such). |
| TRPR-MRC-006 | Weights stored as 4 complex int16 Q1.15 pairs at 0x30–0x3F | I | `test_weight_gen_spi_flow.py` | 🗑️ **Real precision gap, not just a stale claim.** `mrc_combiner.v` takes `signed [7:0]` weight inputs — only the HI byte of each Q1.15 pair (`W_0_RE_HI` at `0x30`, etc.) reaches the combiner; the LO byte (`0x31`, etc.) is write-only and silently discarded. Effective precision is Q0.7 (int8, ±127), not the full Q1.15 this requirement and the register names imply. Found while building `test_weight_gen_spi_flow.py` (job 3286); now documented in `planning/Register Map.md`'s `0x30`–`0x3F` section and Open Risks #33. Spec text needs updating to say Q0.7. |
| TRPR-MRC-007 | `COMB_POST_GAIN_SHIFT` (pgs) at spec-cited `0x36[2:0]`, effective division 2^(8−pgs) | T | `tb_mrc_fw_rand.v` (job 2010, quantisation-loss figures cited directly in the spec text), `test_remod_backoff.py` (writes pgs via `COMB_CFG`) | 🗑️ **Spec gives the wrong address.** `COMB_POST_GAIN_SHIFT` is at `0x0F` bits[2:0] (packed together with `REMOD_BACKOFF_SHIFT` at bits[5:4] in `COMB_CFG`, per `planning/Register Map.md`), not a standalone `0x36`. Same recurring stale-address pattern as TAC-006/011, SCD-008/009, PCF-007/009. |
| TRPR-MRC-008 | Post-combining SNR gain ≥ 5 dB vs. single-antenna (flat channel, equal power) | A | `sim/tests/run_ber.py` (Python `--nt 1` MRC sweep) | ✅ (Python model only — no RTL-level SNR-gain measurement, consistent with the requirement's `Verif=P` (Python) column) |
| TRPR-MRC-009 | AGC keeps branch amplitude ≤ −3 dBFS (≤90 counts) so combined sum fits after ÷2; int8 saturation is a safety net, not the normal path | P | — | ❌ Not testable at the RTL level — this requirement is about AGC's firmware control loop, which has no test at all (Open Risks #8). `test_remod_backoff.py` shows the combiner reaches near-full-scale (`comb_y` peak ~120, i.e. above the 90-count/−3 dBFS line) quite easily under a synthetic forced-weight stimulus — a reminder that the RTL provides no independent enforcement of this constraint; it depends entirely on AGC/firmware discipline plus the `REMOD_BACKOFF_SHIFT` margin (TRPR-RMD-004) as a second line of defense. |
| TRPR-MRC-010 | ŷ matches numpy `W@x` within ±2 LSB (int8) | T | `test_weight_gen_spi_flow.py` (job 3286) | ✅ **Exceeds requirement** — bit-exact (`max_err=0.00`), not just within ±2 LSB. |
| TRPR-MRC-011 | `WGT_CTRL` (spec-cited `0x35`) exposes `W_COMMIT`/`W_VALID`/`W_PENDING`/`W_MISSED_PACKET` | I | `tb_trouper_spi.v` (`W_COMMIT` W1P mechanics, reset value) | 🗑️ **Spec gives the wrong address** — `WGT_CTRL` is at `0x1E` (`planning/Register Map.md`), not `0x35`. Coverage is also partial: only `W_COMMIT`'s W1P behavior is tested; `W_VALID`/`W_PENDING`/`W_MISSED_PACKET` readback over SPI is untested (see PCF-005 above re: `W_MISSED_PACKET` specifically having zero coverage). |

**Open items surfaced by this pass:**
1. **MRC-006 is a real, previously-undocumented precision cliff**, not a stale-spec issue like the address mismatches elsewhere — the combiner silently drops half of every committed weight's precision. Now documented in the Register Map; spec text (`Trouper Chip Specification.md` TRPR-MRC-006) still says Q1.15 and should be corrected to Q0.7.
2. **MRC-004's "safe-switch boundary" atomicity is spec-only** — the RTL has no such latch; `rb_w_shadow` is read live every combine cycle. Harmless today but worth knowing before anyone relies on the promotion timing the spec describes.
3. **MRC-007/MRC-011 spec addresses are wrong** (`0x36`→real `0x0F`; `0x35`→real `0x1E`) — same recurring class as TAC-006/011, SCD-008/009, PCF-007/009. Reinforces the case for one dedicated spec-vs-register-map reconciliation pass rather than finding these piecemeal.
4. **MRC-009 (AGC-enforced input headroom) has zero RTL coverage** and can't have any until AGC firmware itself is tested (Open Risks #8) — cross-referenced, not a new finding.
5. **MRC-005's pre-training auto-bypass trigger is untested as such** — only the explicit `MODE=1` path and the underlying antenna-select mux are exercised.

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
| TRPR-RMD-008 | Mode 1 passthrough: remod receives single-antenna stream directly | T | — | ❌ Same gap as PCF-011 above — no test drives `MIMO_CTRL.MODE=1` and confirms the selected antenna's *raw sample* (not an MRC-weighted combination) actually reaches `sd_remod`'s input. `test_remod_backoff.py` deliberately used MRC mode with a forced single-branch weight instead of true bypass mode, specifically to avoid the PSRAM-replay-delay complications bypass mode introduces (see the test's docstring) — so it doesn't close this gap either. |

**Open items surfaced by this pass:**
1. **RMD-003's "permanent instability" framing doesn't match observed RTL behavior** — `sat16` prevents literal wraparound, and even adversarial forcing doesn't produce a signal that stays stuck forever; it produces measurably more frequent output-freezing instead. Worth a spec wording pass so future test-writers don't repeat the same false start (three wasted job iterations, 3290-3292, chasing a "stuck forever" signature that isn't how this RTL actually fails).
2. **RMD-004's detect/flag mitigation doesn't exist on-chip**, and its AGC-prevention alternative is untested (Open Risks #8) — the only proven mitigation is the `REMOD_BACKOFF_SHIFT` margin itself.
3. **RMD-006 is only spot-checked at two amplitudes**, not swept across the full claimed stable range.
4. **RMD-008 / MRC-005 / PCF-011 all converge on the same untested claim**: that Mode-1 bypass actually delivers a raw, unweighted single-antenna stream to the re-modulator, end-to-end. Three separate requirements reference this; a single new test (driving real `MIMO_CTRL.MODE=1` end-to-end and confirming `remod_in_i/q` tracks one antenna's raw decimated sample with no MRC math involved) would close all three at once.
