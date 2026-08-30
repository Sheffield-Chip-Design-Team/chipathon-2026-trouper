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
0x1E, `RX_GAIN_CTRL.RX_GAIN_COMMIT` 0x18, `PSRAM_CTRL.PSRAM_CLR_ERR` 0x70,
`PSRAM_DBG_CTRL.RD_TRIG` 0x75),
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
| TRPR-TAC-007 | Firmware noise-trigger mode (`TACC_NOISE_TRIG`) | T | `tb_trouper_spi.v` (W1P mechanics), `cocotb/tests/test_noise_trig.py` (jobs 3310; 2026-08-29 2/2 PASS) | ✅ Full functional flow with independent per-antenna Gaussian noise: arm without `sc_lock` (PSRAM disabled → contamination impossible by construction), `NOISE_READY` IRQ fires, `n_acc == 8M` exactly (forward window — contrast with lock-mode's `7M−1`), all four Zdiag > 0, every normalized \|Z_kl\| < 0.2 (≈0.02 expected for independent noise). SC hits/lock inside a triggered window suppress `NOISE_READY`. **Busy-trigger closure 2026-08-29:** a trigger during normal live training is rejected, sets sticky/W1C `0x1F[1]`, lets the original training complete, and cannot produce false `NOISE_READY`. |
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
| TRPR-SCD-003 | One hit decision per completed symbol, full-M delayed samples via PSRAM | I | `tb_dsp_chain_real_probe.v`, `test_capture_two_packet.py` (job 3273), `cocotb/trouper_capture` (jobs 5218–5220, 5227) | ✅ Current-top measured-capture sweep: SF7/BW125 locks at ~2.05 ms (job 5218), SF7/BW250 locks at ~1.54 ms and completes the full path (job 5219), and the deep SF12/BW125 window locks at ~32.77 ms (job 5220; full path job 5227). Job 5227 also proves 32 exact replay tuples at `timing_ref−1`; it runs the behavioural PSRAM at 2 MiB to avoid aliasing the approximately 1 MiB SF12 preamble. The current-top tests supersede the legacy probe as integration evidence. |
| TRPR-SCD-004 | `sc_lock` asserts after `SC_HITS_REQ+1` consecutive hits | T | `tb_dsp_chain.v`, `tb_dsp_chain_sf.v`, `tb_dsp_chain_rand.v` (direct-wired `sc_hits_req`, not via register), `test_trouper_top.py` (via SPI `SC_HITS_REQ` write) | ✅ |
| TRPR-SCD-005 | `timing_ref = lock_sample − (SC_HITS_REQ+1)·M + 1` | T | `cocotb/tests/test_sc_dbg_flags.py` (job 3307, adjacent evidence) | ⚠️ Still no direct closed-form assertion on `timing_ref` itself, but materially strengthened 2026-07-06: the formula's inputs were in **wrong (double-counted) units** until the Open Risks #36 fix — `timing_ref` was inflated by an amount growing over the session, and no downstream Z-correctness check ever noticed (stationary stimuli). `test_sc_dbg_flags.py` now pins the mark arithmetic (`SC_LOCK_SNAP == SC_FIRST_HIT + M`), and the corrected `n_acc = 7M−1` expectation in `test_trouper_top.py` is a direct downstream consequence of the corrected formula. |
| TRPR-SCD-006 | RTL operates on antenna branch 0 only (by design) | I | — | ℹ️ Not a testable requirement — it's a documented design limitation. Tracked as a deferred risk (Open Risks §Deferred item 9): `planning/sc-detector-ant0-fading-risk.md` (ant0 deep-fade SPOF, no 4-branch pooling before lock). |
| TRPR-SCD-007 | `SC_THR_HI/LO` (0x0C/0x0D) writable, RTL consumes low 12 bits, reset default `0x01CC` | I | `tb_trouper_top.v`, `test_trouper_top.py` (write `SC_THR_HI/LO` over SPI); `cocotb/reg_reset_sweep` | ✅ `reg_reset_sweep` reads `0x0C=0x01` and `0x0D=0xCC` immediately after reset, then dirties both bytes and verifies reset restores `0x01CC`. |
| TRPR-SCD-008 | `SC_HITS_REQ` configurable via register **0x0E**; locks after encoded value + 1 hits | T | `test_trouper_top.py`, `tb_trouper_top.v` (write via SPI) | ✅ Address fixed 2026-07-05 (was `0x1B`); semantics clarified 2026-07-26: values 1–3 are normal 2–4-hit settings and raw 0 is diagnostic-only one-hit mode. RTL and both tests use 0x0E. |
| TRPR-SCD-009 | `SC_STAT_HI/LO` (0x24–0x25) exposes `\|C[s]\|²` telemetry | I | `cocotb/tests/test_sc_dbg_flags.py` (job 3307) | ✅ Closed 2026-07-06: read over SPI at both addresses — zero before any symbol evaluation exists (pre-PSRAM-init baseline), nonzero after lock (frozen at the last pre-lock symbol's telemetry). |
| TRPR-SCD-010 | Debug regs `SC_DBG_FLAGS` (0x26), `SC_FIRST_HIT` (0x28–0x2B), `SC_LOCK_SNAP` (0x2C–0x2F) | T | `cocotb/tests/test_sc_dbg_flags.py` (job 3307) | ✅ Closed 2026-07-06, with two RTL fixes found in the process: (1) `SC_DBG_FLAGS.SC_HIT` was the 1-cycle `sc_hit_dbg` pulse wired to combinational readback — firmware-invisible, same class as the W_MISSED_PACKET bug — fixed with held `sc_hit_hold` (Open Risks #35); (2) the snapshot delta check (`SC_LOCK_SNAP == SC_FIRST_HIT + M` at `SC_HITS_REQ=1`) exposed the sc_detector `sample_count` double-count (Open Risks #36). All three registers now read and value-checked over SPI, plus an all-zero pre-evaluation baseline. |
| TRPR-SCD-011 | *(REMOVED — former `CORR_MAG_n` addresses reallocated to `Z_02`/`Z_03` readback)* | — | — | ✅ Superseded 2026-07-26: `0x48–0x4F` are live `Z_02`/`Z_03` bytes (TRPR-TAC-004), not tied-zero telemetry. |
| TRPR-SCD-012 | *(REMOVED — former `C_POOL_I/Q` addresses reallocated to `ZDIAG` readback)* | — | — | ✅ Superseded 2026-07-26: `0x64–0x67` are live `ZDIAG_0`/`ZDIAG_1` bytes (TRPR-TAC-005), not tied-zero telemetry. |
| TRPR-SCD-013 | `sc_lock` within ±1 symbol of Python model, SF7/125 kHz/0 dB SNR | T | `sim/tests/test_sync.py` (Python-only) | ⚠️ Python reference model is tested against itself; no test compares **RTL** `sc_lock` timing directly against the Python block-model prediction — the gap this requirement is actually about. |
| TRPR-SCD-014 | `sc_lock` de-asserts and re-arms on Packet Control FSM → IDLE | T | `tb_trouper_two_packet.v` (job 3203), `test_capture_two_packet.py` (job 3273, real capture) | ✅ |
| TRPR-SCD-015 | *(REMOVED 2026-07-26 — no `SC_CFG` register, no bit to write)* | — | — | ✅ Retired: the row instructed firmware to leave `ENERGY_GATE_EN` at 0, but `SC_CFG` and `ENERGY_THR` went with `noise_est.v` and appear nowhere in `reg_bank.v`. Audit item 13. |
| TRPR-SCD-016 | e_slice guard suppresses hits when `eval_e_acc[25:13] == 0` | I | `test_trouper_top.py` (positive), `test_sc_dbg_flags.py::test_low_energy_hit_suppression` (job 3315, negative) | ✅ Closed 2026-07-06: CW at amplitude 1 (energy slice ≈0.25 → 0) with the most permissive lock settings (1-hit, low threshold) produces zero hits and no lock across 15 evaluated symbols — watched via the held `SC_HIT` readback so no evaluation can slip between polls. Confirms the amplitude-independent ratio test alone would be unsafe and the guard is load-bearing. |

**Open items surfaced by this pass:**
1. **SCD-008 / SCD-009 spec-RTL address mismatches** — `SC_HITS_REQ` is at `0x0E` in the register map (RTL matches), not the `0x1B` the spec cites; `SC_STAT` is at `0x24–0x25` (RTL matches), not `0x50–0x51`. Same pattern as the TAC-006/TAC-011 findings — spec text drifted from the register map after address reshuffles.
2. **No isolated `sc_detector` testbench** — every test instantiates it inside the full DSP chain or `trouper_top`. Fine for integration confidence, but harder to pin down which requirement a given chain-level pass/fail actually validates.
3. ~~**Debug/telemetry register readback untested**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_sc_dbg_flags.py` (job 3307). "Wired correctly per the register map" turned out to be false twice over: `SC_HIT` was pulse-wired (firmware-invisible, Open Risks #35) and the snapshot registers were in double-counted units (Open Risks #36) — both found by this test and fixed. |
4. **SCD-005 and SCD-013 are functionally exercised but not directly asserted** — `timing_ref`'s formula and RTL-vs-Python lock-timing agreement are both only checked indirectly (via downstream correctness), not as standalone assertions.
5. ~~**SCD-016 guard is untested in the negative case**~~ — **CLOSED 2026-07-06** by `test_low_energy_hit_suppression` (job 3315).
6. **SCD-006 ant0 SPOF** is a known, already-tracked open risk (`sc-detector-ant0-fading-risk.md`), not a new finding — cross-referenced here for completeness.

---

## 4.10 PSRAM Buffer Controller (`psram_buf_ctrl.v`) — TRPR-PSR

This block has two independent verification legs: RTL/cocotb simulation (chain
testbenches, `tb_trouper_spi.v`, `cocotb/tests/test_startup.py`) and a
SymbiYosys k-induction formal proof (`formal/psram_buf_ctrl_formal.sv`,
`formal/psram_buf_ctrl.sby`) covering pointer/overflow bounds, sticky-flag
correctness, FSM legality, bus-driving safety, and delay-line warm-up.

### GF180 pad-cell model coverage (2026-08-29)

The PSRAM data lanes have a third, interface-level verification leg using the
foundry `gf180mcu_fd_io__bi_t` Verilog model.  The standalone
`cocotb/io_cell_controls` test compiles that model from the pinned OSIC PDK and
checks both legal control modes: output (`IE=0, OE=1`) and input (`IE=1,
OE=0`).  The integrated command below wraps all four `PSRAM_SIO` lanes in the
same cells during a real QPI debug-readback test:

```sh
cd cocotb/psram_ops
SIM=icarus GF180_IO_MODEL=1 COCOTB_TESTCASE=test_dbg_readback_content make
```

The wrapper asserts after each clock that `PSRAM_SIO_IE & PSRAM_SIO_OE == 0`;
this guards the GF180-disallowed/uncharacterized `IE=OE=1` control state while
the readback confirms the pad data path.  Icarus is required for this mode
because the foundry model uses primitives unsupported by Verilator.  This is a
functional foundry-model check, not post-layout or board signal-integrity
signoff.

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-PSR-001 | QSPI init completes within 1 ms of the `init_start` trigger (`PSRAM_EN & ~QSPI_OWNER`) — **not** of RESETB de-assertion (corrected 2026-07-26, audit item 9) | T | `cocotb/tests/test_startup.py::test_qe_init_trst_margin` (measures 750 ns RST→EnterQPI gap, job 3257) | ⚠️ The on-chip QE_INIT sequence itself is fast and measured, but the requirement's implicit dependency — firmware must not write `PSRAM_EN=1` until ≥150 µs after board power-up (tPU) — is explicitly **not** enforced in hardware. `test_startup.py::test_psram_init_has_no_tpu_wait` demonstrates this gap numerically rather than closing it; it's host/board discipline only (Open Risks #27). |
| TRPR-PSR-002 | Continuous circular-buffer streaming; latch packet-start pointer on `sc_lock` | T | `test_capture_playback.py`, formal `a_gap_invariant` (pointer/gap tracking) | ✅ |
| TRPR-PSR-003 | `REPLAY_ACTIVE` on `W_commit`; replay from latched start incl. preamble, at 500 kS/s | T | `test_weight_gen_spi_flow.py` (job 3286), `test_capture_playback.py`, formal `a_replay_active_matches_state`, `a_replay_clears_on_end` | ✅ Measured-capture current-top full-path runs: SF7/BW125 job 5218, SF7/BW250 job 5219, and SF12/BW125 job 5227 (all 1/1 PASS). A repeatable NFS result on 2026-08-30 uses `lora_20260619_162950_SF7-BW125-Pre8.npy[360000:390000]`: `sc_lock` at 12.29 ms, training completes, and 32 replay samples match the stored decimated stream bit-exactly at `timing_ref−1`. The scoreboard records the decimated PSRAM write stream; SF12 uses a 2 MiB behavioural PSRAM model because the default 64 KiB model would alias its approximately 1 MiB preamble. This closes replay-staleness Open Risk #18 for the current architecture. |
| TRPR-PSR-004 | `REPLAY_MISSED` asserts/latches if `W_COMMIT` is late; combiner falls back to next-packet weights | T | formal `a_replay_missed_cause`/`a_replay_missed_sticky`, `cocotb/tests/test_psram_ops.py::test_replay_missed_late_commit` (job 3313) | ✅ Closed 2026-07-06: a genuinely late `W_COMMIT` (after `packet_end`) is driven in sim — `REPLAY_MISSED` latches at its register bit, the late commit is inert (no zombie replay, packet base invalidated), `PSRAM_CLR_ERR` clears the sticky over SPI, and the next in-time-committed packet replays clean with the flag staying 0. Note the auto re-arm behavior this test had to accommodate: SC re-locks immediately at IDLE, so every uncommitted packet correctly re-latches the flag (the test's first draft flagged that correct behavior as a failure, job 3312). |
| TRPR-PSR-005 | 8 bytes/sample storage, order i0,q0,i1,q1,i2,q2,i3,q3 | T | `test_capture_playback.py`, `test_weight_gen_spi_flow.py` (byte order implicitly confirmed — replayed/read-back samples only match reference if order is correct) | ✅ (functional, no test asserts byte order in isolation) |
| TRPR-PSR-013 | Nominal write rate 4 MB/s, ~6% of device capacity | A | — | ✅ Corrected 2026-07-26: 4 channels × 2 bytes × 500 kS/s = 4 MB/s (32 Mbit/s); analysis-only per spec `Verif` column. |
| TRPR-PSR-014 | QPI timing headroom: 20 spare cycles (write), 8 spare (replay) | A | Formal `a_no_drive_during_dummy`, `a_ce_n_matches_activity` indirectly confirm no overrun; `test_startup.py` timing measurements; `cocotb/psram_ops` `SIM=icarus GF180_IO_MODEL=1` debug-readback integration | ✅ Analysis + formal bus-timing safety; the foundry-model run additionally checks legal SIO pad control and the functional pad data path, not SI timing. |
| TRPR-PSR-015 | Max buffer depth ≈1 MiB at SF12/125 kHz, no overflow ≤ SF12 | A/T | Formal `a_gap_invariant` (bounded backlog), `test_capture_playback.py` SF sweep | ✅ Corrected 2026-07-26: `M = 2^(12+2) = 16384`; 8 symbols × 8 B/sample = 1 MiB, leaving ≥8× headroom. |
| TRPR-PSR-006 | `PSRAM_STATUS` (0x71) bit layout: state/SAMPLE_SKIP/INIT_DONE/REPLAY_ACTIVE/REPLAY_MISSED/OVERFLOW/BUF_ACTIVE | I | `test_trouper_top.py`, `tb_trouper_top.v` (poll `INIT_DONE` bit[3]), `cocotb/tests/test_bypass_e2e.py` (job 3304, polls `REPLAY_ACTIVE` bit[4] after `W_COMMIT`) | ⚠️ 4/7 bits now read back over SPI at their register positions: `INIT_DONE` bit[3], `REPLAY_ACTIVE` bit[4] (set + negative cases), `REPLAY_MISSED` bit[5] (set + clear, `test_psram_ops.py` job 3313), `SAMPLE_SKIP` bit[2] (asserted 0 end-of-packet in every SF sweep scenario, job 3311). Remaining 3 (`state`, `OVERFLOW`, `BUF_ACTIVE`) are proven as internal *signals* by formal but not at their register bit positions. |
| TRPR-PSR-007 | All four sticky flags (`OVERFLOW`, `REPLAY_MISSED`, `SAMPLE_SKIP`, `W_COMMIT_LATE`) clearable via `PSRAM_CLR_ERR` (0x70[1]); simultaneous set+clear not lost. Flag list corrected 2026-07-26 (audit item 12) — the requirement previously named three | T | `tb_trouper_spi.v` (W1P self-clear mechanics only), formal `a_replay_missed_sticky`/`a_sample_skip_cause` (found and fixed a same-cycle `clr_err`-timing bug in the proof itself, 2026-07-05) | ✅ (formal covers the actual race the requirement is about; RTL-sim only covers the register mechanics) |
| TRPR-PSR-008 | *DELETED* (`PSRAM_PKT_BYTES` removed) | — | — | — n/a |
| TRPR-PSR-009 | `PSRAM_EN=0` disable mode: idle, no QSPI pad assertion | T | formal `a_buf_active_needs_en` | ✅ |
| TRPR-PSR-010 | `QSPI_OWNER` selects active master; owner 1 suspends buffering/replay, tri-states pads | T | `cocotb/tests/test_qspi_owner.py` (job 3314) | ✅ Closed 2026-07-06: owner=1 releases CE#/SIO_OE/SCK within 8 clocks and holds them released (checked per-clock for 256 clocks), `DBG_BUSY` held, and buffering AND replay both resume after owner returns to 0. Found+fixed a missing `!qspi_owner` gate on the S_REPLAY burst launch — owner previously could never suspend an active replay (Open Risks #37). |
| TRPR-PSR-011 | `QSPI_OWNER` writes during BUFFERING/REPLAY don't glitch pads; effect deferred to the QPI burst boundary | T | `cocotb/tests/test_qspi_owner.py` (job 3314) | ✅ Closed 2026-07-06, with an RTL fix: `sck_en` was gated by the RAW owner bit — a mid-burst request froze SCK while CE# stayed low and SIO kept driving (the exact prohibited glitch). Fixed with `qspi_owner_eff` latched between bursts; the test asserts CE#-low ⇒ SCK-enabled on every clock through both handovers. Spec's "effect only at STATE=IDLE" wording also corrected (no such state exists) to "at the next QPI burst boundary". Formal k-induction re-proven on the modified RTL (job 3314). |
| TRPR-PSR-012 | *(REMOVED — no `PAD_CONFLICT` signal in RTL)* | — | — | ✅ Spec reworded 2026-07-06: the signal was never implemented and none is needed — `psram_buf_ctrl` is the only on-chip QSPI driver and tri-states under owner=1 (PSR-010/011), so no on-chip simultaneous-driver case exists. Same REMOVED treatment as TAC-006/011, AGC-002. |
| TRPR-PSR-016 | SC delay reads at `write_ptr − M`, interleaved with writes, cease after `sc_lock` | T | `test_capture_playback.py` (delayed-sample correctness via full-chain sc_lock), formal `a_del_valid_needs_rdy`, `a_del_cnt_bounded` | ✅ |
| TRPR-PSR-017 | PSRAM debug readback protocol (host SPI): addr write → RD_TRIG → poll DBG_BUSY → read 8 data bytes → AUTO_INC. Gate corrected 2026-07-26 to `DBG_BUSY=0` (there is no `STATE=IDLE`; audit item 11) | T | `tb_trouper_spi.v` (mechanics), `cocotb/tests/test_psram_ops.py::test_dbg_readback_content` (job 3313) | ✅ Closed 2026-07-06: full host protocol run packet-free, 16 bytes read over SPI compared **bit-exact** against the behavioural psram_model's nibble memory at the same addresses (i.e. exactly what the QPI engine physically stored), including the `AUTO_INC` re-fetch at base+8. Formal section E remains parked — no longer load-bearing given the sim coverage. |
| TRPR-PSR-018 | QPI-only interface mandate (no SPI/1-bit mode) | A | — | ✅ (by construction — RTL has no 1-bit mode to test against) |
| TRPR-PSR-019 | SF fixed per session; re-arm SC delay warm-up on `sf`/`sample_shift` change | T | `cocotb/tests/test_startup.py::test_sc_correlator_idle_until_del_rdy` (warm-up latency at fixed SF/BW only) | ⚠️ Warm-up hold-off itself is verified (measured SF9/BW125 at 4.092 ms vs 4.096 ms predicted). The re-arm-on-**change** clause specifically is untested — no test changes `sf`/`sample_shift` mid-session (formal explicitly *assumes* these are session-constant, `m_sf_valid_range`/`m_sample_shift_valid_range`, to keep the proof tractable). |
| TRPR-PSR-020 | Sticky `SAMPLE_SKIP` flag; spec claims "verified by a directed sustained-`iq_valid` test... at 125 and 250 kHz" | T | `cocotb/tests/test_trouper_top.py` SF7 BW250/BW125 full scenarios (job 3310), formal `a_sample_skip_cause` | ✅ Closed 2026-07-06 — by making the spec's claim true rather than removing it: both full-packet scenarios now read `PSRAM_STATUS[2]` at end-of-packet and assert `SAMPLE_SKIP == 0` after sustained `iq_valid` at both bandwidths. (Relevant to Open Risks #30's stale-budget concern: at the current R=64 rate the flag stays clean.) The flag's *cause* condition remains formally proven. |
| TRPR-PSR-021 | `sc_ant_sel` (`SC_ANT_SEL` 0x1B[1:0]) routes SC delay-line branch; write-locked during packet | T | `cocotb/sc_ant_sel` suite (`test_sc_ant_sel.py`) | ✅ New ID (2026-07-18 §4.10 per-function restructure) — behaviour was already in RTL + tested (Open Risks #9 mitigation), previously unspec'd. |
| TRPR-PSR-022 | `REPLAY_DELAY_SAMPLES` (0x77/0x78) margin from `training_done` to replay start; write-gated `!packet_active`; default 1500 sized to rv32emc weight compute | T | `cocotb/tests/test_replay_delay.py` (job 3347): 3-rung margin timing; write-gate covered by reg-map gating tests | ✅ New ID (2026-07-18) — spec catch-up to the implemented continuous-delay design. |
| TRPR-PSR-023 | Replay runs in combiner bypass until `W_COMMIT` (degraded, never silent) | T | `cocotb/tests/test_replay_delay.py` / `test_replay_data.py` (jobs 3347/3350) exercise bypass-then-commit; `test_psram_ops.py` (job 3313) covers never-commit | ✅ New ID (2026-07-18). |
| TRPR-PSR-024 | Replay read pointer monotonically non-decreasing (never rewinds); mechanism for TRPR-RMD-009 | T | `cocotb/tests/test_replay_delay.py` monotonic-`rd_ptr` check (job 3347) | ✅ New ID (2026-07-18). |

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
| TRPR-PCF-002 | On `sc_lock`: assert `packet_active`, → PREAMBLE_ACQ | T | `cocotb/tests/test_w_missed_packet.py` (job 3310, retargeted 2026-07-26) | ✅ Closed 2026-07-06, requirement + test retargeted 2026-07-26: `buf_freeze` was deleted from the RTL (bit-identical to `packet_active`, consumed by nothing since the PSRAM migration). The four assertions now watch `packet_active` at the same points — asserted after `sc_lock`, held through PAYLOAD_ACTIVE, de-asserted at IDLE, re-asserted at the next packet start — so the FSM contract stays covered on the surviving signal. |
| TRPR-PCF-003 | On `training_done`: → W_PENDING, assert `TRAINING_DONE` IRQ | T | `test_weight_gen_spi_flow.py` (job 3286, `IRQ_STATUS[TRAINING_DONE]`) | ✅ |
| TRPR-PCF-004 | On `W_COMMIT`: assert `W_VALID`, → PAYLOAD_ACTIVE; combiner uses live write-locked W bank | T | `test_weight_gen_spi_flow.py`, `test_capture_playback.py` (`W_COMMIT`→`WGT_CTRL[1]` W_VALID→combiner uses committed weight) | ✅ Spec corrected 2026-07-26: no separate `W_ACTIVE` bank or safe-switch promotion exists in RTL. |
| TRPR-PCF-005 | No `W_COMMIT` before payload boundary → stay in bypass, set `W_MISSED_PACKET`, assert IRQ | T | `cocotb/tests/test_w_missed_packet.py` (job 3305) | ✅ Closed 2026-07-06. Lock → training_done → `W_COMMIT` withheld → miss IRQ (`IRQ_STATUS[2]`) fires at the W_PENDING timeout (the exact `46e1da0` fix path), payload provably runs in bypass (`use_mrc_r=0`, `comb_y` bit-equals raw ant0 for 20 pairings), and the flag reads back at both register positions. **Second RTL fix found by this test**: the 1-cycle `W_missed_packet` pulse was wired straight into reg_bank's combinational `w_missed_rb`, making `PACKET_STATUS[7]`/`WGT_CTRL[3]` firmware-invisible — fixed with a sticky per-packet `W_missed_q` in `packet_ctrl_fsm.v` (set at both miss sites, held through IDLE, cleared at next packet start), regression included in the same test. |
| TRPR-PCF-006 | `ACTIVE_MODE`/`ACTIVE_ANTENNA_EN`, packed into `ACTIVE_STATUS` (0x1D), latched from `MIMO_CTRL` only at safe-switch (IDLE) | T | `test_bypass_antenna.py` (mux), `test_bypass_e2e.py::test_mimo_ctrl_deferred_latch` (job 3315, latch timing) | ✅ Closed 2026-07-06: `MIMO_CTRL` written **mid-packet** (MODE=1/mask=0xC), `ACTIVE_STATUS` holds the at-lock values (0xF0) through the packet and latches the new config (0xC1, `bypass_ant`=2) only at the next lock. Also the first register-level read of `ACTIVE_STATUS` — which exposed a Register Map error: the reset column said `0x0F` but the FSM resets to mode 0 / antenna_en 0x1 = `0x10` (0x0F would decode to mode 3); map corrected. |
| TRPR-PCF-007 | Packet timeout via `PKT_TIMEOUT_SYMS` (0x0B) forces IDLE, asserts `PACKET_DONE` IRQ | T | `tb_trouper_two_packet.v` (job 3203), `cocotb/tests/test_w_missed_packet.py` (job 3305) | ✅ Spec address fixed 2026-07-05 (was `0x16`). The remaining gap — the `PACKET_DONE` IRQ bit itself — closed 2026-07-06: `test_w_missed_packet.py` writes `PKT_TIMEOUT_SYMS=20` pre-lock and polls `IRQ_STATUS[3]` firing on the timeout→IDLE transition, then confirms `PACKET_STATUS` reads idle and the receiver re-locks. |
| TRPR-PCF-008 | On IDLE entry: `packet_active` de-asserts | T | `cocotb/tests/test_w_missed_packet.py` (job 3310, retargeted 2026-07-26) | ✅ Closed 2026-07-06, reworded 2026-07-26: the requirement's "frontend buffer resumes" clause named hardware TRPR-PHY-006 removed and has been dropped; `buf_freeze` itself is deleted from the RTL. `packet_active` is confirmed de-asserted after the timeout→IDLE transition, and PSRAM circular capture resumes off that edge. |
| TRPR-PCF-009 | `PACKET_STATUS` (0x1C) exposes PACKET_ACTIVE/PHASE/TRAINING_DONE/W_PENDING/W_VALID/W_MISSED_PACKET | I | `tb_trouper_spi.v` (RO-write-ignored), `cocotb/tests/test_w_missed_packet.py` (job 3305, live-packet bit content) | ✅ Closed 2026-07-06: bit content now checked over SPI *during a live packet* at three phases — W_PENDING (`PACKET_ACTIVE=1`, `PHASE=2`, `TRAINING_DONE=1`, `W_PENDING=1`, miss clear), post-miss PAYLOAD_ACTIVE (`PHASE=3`, `W_VALID=0`, `W_MISSED=1`), and IDLE (`PACKET_ACTIVE=0`, sticky miss held). Note this required the `W_missed_q` RTL fix (see PCF-005) — before it, bit[7] could never read 1. Residual: the `W_VALID=1` case at this register is untested (the committed-weights path reads it via `WGT_CTRL[1]` instead, `test_weight_gen_spi_flow.py`). |
| TRPR-PCF-010 | No deadlock: W_PENDING → timeout → IDLE when firmware absent/no `W_COMMIT` | T | `tb_trouper_two_packet.v` (job 3203) — every packet in this test completes via the timeout path since `W_COMMIT` is never sent | ✅ (functional — the test's entire premise depends on this path not deadlocking) |
| TRPR-PCF-011 | Mode 1 passthrough: route lowest-enabled antenna to remod, bypass training/weights | T | `test_bypass_antenna.py` (mux), `cocotb/tests/test_bypass_e2e.py` (job 3304, end-to-end) | ✅ Closed 2026-07-06 with one spec-wording nuance. The routing half is now proven end-to-end (see TRPR-RMD-008: selected antenna's raw sample reaches `sd_remod`, bit-exact, for masks 0xF→ant0 and 0xC→ant2), and committed weights are proven *ignored* in Mode 1 (`use_mrc_r=0` with non-trivial weights committed). Nuance: `packet_ctrl_fsm.v` has no Mode-1 special-casing — training accumulation still physically runs and `W_PENDING` still waits for `W_commit`/timeout; what Mode 1 "bypasses" is weight *application*, not weight/training *computation*. If the spec text means the latter, it needs a wording pass. |

**Open items surfaced by this pass:**
1. ~~**PCF-005 is an RTL fix with no regression test**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_w_missed_packet.py` (job 3305), which also found and regressed a second bug in the same area: the pulse-vs-readback wiring that made `PACKET_STATUS[7]`/`WGT_CTRL[3]` firmware-invisible (fixed via sticky `W_missed_q` in `packet_ctrl_fsm.v`). `DBG_MISSED_PKTS` (TRPR-WGN-008) still has no register and no coverage — unchanged.
2. ~~**`buf_freeze` (PCF-002/008) is completely untested**~~ — **CLOSED 2026-07-06** by `test_w_missed_packet.py` (job 3310): observed across start/hold/IDLE/re-start. The residual "candidate for removal or re-purposing" note is also now **closed 2026-07-26**: `buf_freeze` was deleted from the RTL, the formal harness and the equivalence TB's compare vector (`packet_ctrl_fsm_ref.v` keeps it — that file is a frozen snapshot of the pre-B6 FSM, and its output is now simply left unconnected); PCF-002/008 and the four regression assertions are retargeted to `packet_active`, which the deleted output duplicated bit-for-bit.
3. **PCF-007/PCF-009 spec addresses are wrong** (0x16 vs real 0x0B; 0x34 vs real 0x1C) — same recurring class of stale-spec-text finding as three earlier blocks. Worth a dedicated pass reconciling every register address in the spec against `planning/Register Map.md` rather than finding these one block at a time.
4. ~~**PACKET_STATUS register content is essentially untested**~~ — **CLOSED 2026-07-06** by `test_w_missed_packet.py` (job 3305): bit content checked over SPI at W_PENDING, PAYLOAD_ACTIVE and IDLE phases (see PCF-009 row; only the `W_VALID=1` case at 0x1C remains indirect).
5. ~~**PCF-011's "bypass training/weights" claim is unverified**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_bypass_e2e.py` (job 3304): the selected antenna's data provably reaches the re-modulator in Mode 1 and committed weights are ignored. Residual: the spec's "bypass training" wording doesn't match the RTL (training still runs in Mode 1, its results are just unused) — see the PCF-011 row note.

---

## 4.8 MRC Combiner (`mrc_combiner.v`) — TRPR-MRC

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-MRC-001 | ŷ[n] = Σ conj(w_k)·x_k, x_k int8, effective w_k int8 Q0.7 | T | `tb_mrc_combiner.v` (including Q0.7-unity transfer sweep), `tb_mrc_fw_rand.v`, `tb_mrc_fw_precision.v` (2026-08-29, repaired, 5/5 PASS), `test_weight_gen_spi_flow.py` (job 3286, bit-exact vs. oracle), NFS `test_capture_playback.py` (2026-08-30) | ✅ The direct sweep holds only branch 0 active with `W=0x7f+j0`, checks signed I/Q rails and rounding boundaries at PGS=0/1 against `(x × 127) >>> (8−PGS)`, and separately confirms literal bit-exact identity belongs to bypass mode. The measured-capture integration run reaches equal-gain `W_COMMIT`, non-zero `comb_y`, and feeds its sampled complex output into the independent final-stream reconstruction check recorded under RMD-001. |
| TRPR-MRC-002 | 18-bit acc; combined shift `>>>(8−pgs)`; saturate int8 | T | `tb_mrc_combiner.v` (pgs clip-boundary cases #4/#5), `test_remod_backoff.py` (job 3294, `sat_i`/`sat_q` clip confirmed via forced near-full-scale `comb_y`) | ✅ |
| TRPR-MRC-003 | 500 kS/s, one output per `iq_valid` | I | Every chain test sampling on `comb_y_valid` pulses (`test_weight_gen_spi_flow.py`, `test_remod_backoff.py`) | ✅ (functional) |
| TRPR-MRC-004 | Live W bank is consumed after `W_COMMIT`/`W_VALID`; writes are rejected while valid | T | `test_weight_gen_spi_flow.py` | ✅ Spec corrected 2026-07-26: `mrc_combiner.v` reads `rb_w_shadow` directly; no separate `W_ACTIVE` latch or safe-switch promotion exists. The RTL write-lock prevents a mid-packet W-bank rewrite while `W_VALID` is high. |
| TRPR-MRC-005 | Before `W_COMMIT`: output bypass signal (lowest-enabled antenna, no weighting) | T | `test_bypass_antenna.py` (job 3276, Open Risks #4 fix), `cocotb/tests/test_bypass_e2e.py` (job 3304) | ✅ Closed 2026-07-06. `test_mode0_pretraining_auto_bypass` exercises the pre-training auto-fallback *as such*: in MRC mode (`MODE=0`) with no `W_COMMIT`, `comb_y` bit-equals the raw lowest-enabled-antenna sample for 40 clean pairings (`use_mrc_r=0` via `W_valid=0`, not via explicit bypass mode); after `W_COMMIT`, `use_mrc_r` flips to 1 and all 60 subsequent outputs diverge from the raw sample (weights applied). The mux itself remains covered 4/4 by `test_bypass_antenna.py`. |
| TRPR-MRC-006 | Weights stored as 4 complex int16 Q1.15 pairs at 0x30–0x3F | I | `test_weight_gen_spi_flow.py` | 🗑️ **Real precision gap, not just a stale claim.** `mrc_combiner.v` takes `signed [7:0]` weight inputs — only the HI byte of each Q1.15 pair (`W_0_RE_HI` at `0x30`, etc.) reaches the combiner; the LO byte (`0x31`, etc.) is write-only and silently discarded. Effective precision is Q0.7 (int8, ±127), not the full Q1.15 this requirement and the register names imply. Found while building `test_weight_gen_spi_flow.py` (job 3286); now documented in `planning/Register Map.md`'s `0x30`–`0x3F` section and Open Risks #33. Spec text needs updating to say Q0.7. |
| TRPR-MRC-007 | `COMB_POST_GAIN_SHIFT` (pgs) at `COMB_CFG` 0x0F[2:0], effective division 2^(8−pgs) | T | `tb_mrc_fw_rand.v` (job 2010, quantisation-loss figures cited directly in the spec text), `test_remod_backoff.py` (writes pgs via `COMB_CFG`) | ✅ Spec address fixed 2026-07-05 (was a standalone `0x36[2:0]` — see Register Address Reconciliation above). `COMB_POST_GAIN_SHIFT` is actually packed together with `REMOD_BACKOFF_SHIFT` at bits[5:4] in `COMB_CFG` (0x0F). |
| TRPR-MRC-008 | Post-combining SNR gain ≥ 5 dB vs. single-antenna (flat channel, equal power) | A | `sim/tests/run_ber.py` (Python `--nt 1` MRC sweep) | ✅ (Python model only — no RTL-level SNR-gain measurement, consistent with the requirement's `Verif=P` (Python) column) |
| TRPR-MRC-009 | AGC keeps branch amplitude ≤ −3 dBFS (≤90 counts) so combined sum fits after ÷2; int8 saturation is a safety net, not the normal path | P | — | ❌ Not testable at the RTL level — this requirement is about AGC's firmware control loop, which has no test at all (Open Risks #8). `test_remod_backoff.py` shows the combiner reaches near-full-scale (`comb_y` peak ~120, i.e. above the 90-count/−3 dBFS line) quite easily under a synthetic forced-weight stimulus — a reminder that the RTL provides no independent enforcement of this constraint; it depends entirely on AGC/firmware discipline plus the `REMOD_BACKOFF_SHIFT` margin (TRPR-RMD-004) as a second line of defense. |
| TRPR-MRC-010 | ŷ matches numpy `W@x` within ±2 LSB (int8) | T | `test_weight_gen_spi_flow.py` (job 3286) | ✅ **Exceeds requirement** — bit-exact (`max_err=0.00`), not just within ±2 LSB. |
| TRPR-MRC-011 | `WGT_CTRL` (0x1E) exposes `W_COMMIT`/`W_VALID`/`W_PENDING`/`W_MISSED_PACKET` | I | `tb_trouper_spi.v` (`W_COMMIT` W1P mechanics), `cocotb/tests/test_w_missed_packet.py` (job 3305) | ✅ Closed 2026-07-06: `W_PENDING` (bit[2]) and `W_MISSED_PACKET` (bit[3]) now read over SPI in a live packet — including that `W_MISSED` stays readable through IDLE and clears at the next packet start (needed the `W_missed_q` RTL fix, see PCF-005). `W_VALID` (bit[1]) is checked in the 0 case here and implicitly in the 1 case by `test_weight_gen_spi_flow.py`'s commit flow. |

**Open items surfaced by this pass:**
1. **MRC-006 is a real, previously-undocumented precision cliff**, not a stale-spec issue like the address mismatches elsewhere — the combiner silently drops half of every committed weight's precision. Now documented in the Register Map; spec text (`Trouper Chip Specification.md` TRPR-MRC-006) still says Q1.15 and should be corrected to Q0.7.
2. ~~**MRC-004's "safe-switch boundary" atomicity is spec-only**~~ — **CLOSED 2026-07-26:** specification now describes the live W bank and its `W_VALID` write-lock rather than a nonexistent active-bank promotion.
3. **MRC-007/MRC-011 spec addresses are wrong** (`0x36`→real `0x0F`; `0x35`→real `0x1E`) — same recurring class as TAC-006/011, SCD-008/009, PCF-007/009. Reinforces the case for one dedicated spec-vs-register-map reconciliation pass rather than finding these piecemeal.
4. **MRC-009 (AGC-enforced input headroom) has zero RTL coverage** and can't have any until AGC firmware itself is tested (Open Risks #8) — cross-referenced, not a new finding.
5. ~~**MRC-005's pre-training auto-bypass trigger is untested as such**~~ — **CLOSED 2026-07-06** by `cocotb/tests/test_bypass_e2e.py::test_mode0_pretraining_auto_bypass` (job 3304): the `W_valid && !mode` trigger is exercised directly in both directions (bypass before `W_COMMIT`, MRC after).

---

## 4.9 ΣΔ Re-modulator (`sd_remod.v`) — TRPR-RMD

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-RMD-001 | 3rd-order ΣΔ, int8 I/Q → 1-bit I/Q | T | `tb_sd_remod.v`, `tb_remod_decim_const.v`, NFS `test_capture_playback.py` (2026-08-30) | ✅ In the measured SF7/BW125 NFS run on `lora_20260619_162950_SF7-BW125-Pre8.npy[360000:390000]`, an independent Python FFT brick-wall LPF (250 kHz) and R=64 decimation of 8,192 final 1-bit I/Q clocks yields complex correlation **0.992** with the simultaneously recorded `comb_y` interval (best ±8 output-sample alignment; acceptance threshold >0.70). This is an end-to-end transfer check, not a replacement for the standalone SQNR requirements. |
| TRPR-RMD-002 | 32 MS/s output, OSR=64 | T | `tb_sd_remod.v` (parametrised OSR), `test_remod_backoff.py` (`clk_per_iq=64` throughout) | ✅ |
| TRPR-RMD-003 | Saturating integrators; wrap-around prohibited (wrapped integrator ⇒ permanent instability) | T | `test_remod_backoff.py` (job 3294) | ✅ **with a methodology finding worth recording.** `sat16` structurally prevents literal register wraparound by construction (always clips to ±32767/−32768) — confirmed empirically across all forcing scenarios, integrator states never wrapped. But the requirement's "permanent instability" framing turned out not to be the right failure signature to test *for*: even a forced near-full-scale input recovers from railing rather than sticking forever (job 3290-3292 diagnostics) — s3 sits near the rail even during definitely-healthy low-amplitude operation, which is normal CIFF cascade behavior, not a fault. The real, correct instability signature for a 1-bit noise shaper is the **quantizer output losing its dither** (frozen for an extended run), which is what the test actually measures (see RMD-004/006 below). |
| TRPR-RMD-004 | Input strictly < −3 dBFS (<90 counts); over-range SHALL be detected/flagged or prevented by AGC | T | `test_remod_backoff.py` (job 3294, `REMOD_BACKOFF_SHIFT` register) | ⚠️ Confirms the RTL mechanism (`REMOD_BACKOFF_SHIFT`) that provides margin against this constraint works end-to-end and measurably reduces output-freezing severity at a forced near-full-scale input. But neither of the requirement's two named mitigations exists as tested: there is no on-chip detection/flag for an over-range remod input, and AGC-based prevention is completely untested (Open Risks #8) — the backoff shift is a third, structural mitigation not named in the requirement text. |
| TRPR-RMD-005 | In-band SQNR > 40 dB at −6 dBFS | T | `tb_sd_remod.v` (SQNR ≈ 55 dB, correlation-threshold check); `test_remod_en.py::test_boundary_tone_quality` | ✅ The direct-DUT boundary-tone characterization (2026-08-30) adds output-only checks at 88/90 codes: fitted gain 0.998–1.004, correlation 0.867–0.877, fitted RMS 34.95–35.65 LSB using a simple 64-clock boxcar. These intentionally do **not** replace the −6 dBFS SQNR requirement or claim its tighter quality limit at the RMD-006 edge. |
| TRPR-RMD-006 | Stable output dither for any int8 input in [−90, +90] | T | `test_remod_en.py::{test_all_in_spec_dc_codes_retain_dither,test_boundary_transitions_retain_dither,test_bounded_random_iq_retain_dither,test_in_valid_holds_sample_and_retains_dither,test_boundary_reenable_equals_fresh_start}` (Verilator, 2026-08-30); `cocotb/negctl_remod_stuck_run.sh` | ✅ Exhaustive 181-code constant-I=Q sweep: worst 94 clocks at −90 in each 8,192-bit window (<100 limit). Boundary/zero steps peak at 126 clocks (<200 step-response guard); bounded asymmetric random I/Q peaks at 91; invalid-cycle input changes cannot alter the held sample; re-enable at ±90 is bit-exact to fresh reset. The controlled fault injection (forced `out_i=0`) is caught by the stuck-run diagnostic. Integrator states are intentionally not used as a stability metric. Out-of-spec characterization: ±100 reaches 119 clocks and ±127 rails for 8,190/8,191 clocks. |
| TRPR-RMD-007 | Re-demod matches int8 input ±1 LSB RMS at −6 dBFS | T | `tb_sd_remod.v`; `test_remod_en.py::test_boundary_tone_quality` (characterization only) | ✅ The 88/90-code tone results are recorded under RMD-005 as out-of-contract boundary characterization; the −6 dBFS RMD-007 acceptance evidence remains `tb_sd_remod.v`. |
| TRPR-RMD-008 | Mode 1 passthrough: remod receives single-antenna stream directly | T | `cocotb/tests/test_bypass_e2e.py` (job 3304) | ✅ Closed 2026-07-06. `test_mode1_e2e_ant0`/`_ant2` drive real `MIMO_CTRL.MODE=1` end-to-end with per-antenna-distinct CW amplitudes: during PSRAM REPLAY, `remod_in_i/q == comb_y_i/q ==` the selected antenna's raw combiner-input sample, bit-exact at `REMOD_BACKOFF_SHIFT=0`, with `psram_silence=0` and `REMOD_A_I` toggling. Deliberately non-trivial committed weights (0x40 in every W-shadow byte) are proven ignored (`use_mrc_r=0`). The PSRAM-replay-delay complication that made `test_remod_backoff.py` avoid true bypass is sidestepped by comparing combiner input→output rather than against the original stimulus. |
| TRPR-RMD-010 | Disabled state holds reset values; re-enable equals fresh reset | T | `cocotb/remod_en/test_remod_en.py::{test_disable_holds_reset,test_reenable_equals_fresh_start,test_boundary_reenable_equals_fresh_start}` | ✅ Direct `sd_remod` tests (the top-level ties `en` high) prove all integrators and outputs remain at reset while disabled and that re-enable produces a bit-identical stream to a fresh reset, including ±90 boundary inputs. |

**Open items surfaced by this pass:**
1. **RMD-003's "permanent instability" framing doesn't match observed RTL behavior** — `sat16` prevents literal wraparound, and even adversarial forcing doesn't produce a signal that stays stuck forever; it produces measurably more frequent output-freezing instead. Worth a spec wording pass so future test-writers don't repeat the same false start (three wasted job iterations, 3290-3292, chasing a "stuck forever" signature that isn't how this RTL actually fails).
2. **RMD-004's detect/flag mitigation doesn't exist on-chip**, and its AGC-prevention alternative is untested (Open Risks #8) — the only proven mitigation is the `REMOD_BACKOFF_SHIFT` margin itself.
3. ~~RMD-006 was only spot-checked at two amplitudes~~ — **RESOLVED 2026-08-30**: direct-DUT output-stuck-run boundary sweep covers ±88/±90; ±100/±127 characterize the out-of-range failure slope. Integrator states are intentionally not used as a stability metric.
4. ~~**RMD-008 / MRC-005 / PCF-011 all converge on the same untested claim**~~ — **CLOSED 2026-07-06** by exactly the single test proposed here: `cocotb/tests/test_bypass_e2e.py` (Verilator, job 3304, 3/3 PASS) drives real `MIMO_CTRL.MODE=1` end-to-end with per-antenna-distinct amplitudes and confirms `remod_in_i/q` tracks the selected antenna's raw decimated sample bit-exact, with committed weights ignored. Also picked up `PSRAM_STATUS.REPLAY_ACTIVE` register-level readback (PSR-006, now 2/7 bits) for free.

---

## Scope note — groups traced at block level only

`TRPR-SYS` (system), `TRPR-PHY` (pads/package), `TRPR-CAL` (calibration
procedures), `TRPR-VER` (verification-process meta) and `TRPR-SPEC` are
system/procedural requirement groups, not RTL blocks — they are exercised
via bring-up plans and signoff flows, not this matrix. Every RTL-block
group is now traced below or above.

**Exception added 2026-08-29:** the A40 padframe migration pushed part of
`TRPR-PHY` *into* the RTL — `trouper_top.v` now drives every pad's IO-cell
control interface itself. That surface is simulatable and is traced in the
section immediately below.

---

## A40 pad-control tie-offs — TRPR-PHY-004 / TRPR-SPS-008

The A40 (ACV) workshop padring has no output-only cell, so every functional
output sits on a bidirectional pad whose control pins (`_OE/_IE/_CS/_SL/
_PU/_PD/_PDRV0/_PDRV1`) are driven from `trouper_top.v` — 104 pad-control
outputs: 96 constant tie-offs, 4 dynamic `PSRAM_SIO_n_IE`, and the 4
pre-existing functional `PSRAM_SIO_n_OE`. Until 2026-08-29 **no simulation
read any of them**: an inverted `_IE`, a swapped `_PU`/`_PD` or a wrong
`_PDRV` code would pass every existing suite and surface only in silicon.

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-PHY-004 (pad-control leg) | Every A40 pad-control pin driven to the value documented in `planning/Pinout.md` "A40 pad-control tie-offs"; constants genuinely constant | T | `cocotb/pad_tieoffs/test_pad_tieoffs.py` (Verilator, job 5223, 2/2 PASS), `sim/tests/test_pad_tieoff_ports.py` (pytest, 4/4) | ✅ Closed 2026-08-29. All 96 constants are checked against a table transcribed **from Pinout.md, not from the RTL**, while reset is still asserted and again out of reset; then re-checked on *every* clock through QPI init and ~200 samples of sustained circular capture (416 k ns, >13 k clocks), so a tie-off accidentally driven by a real signal cannot hide between polls. The static companion proves no pad-control output is left undriven (would float in silicon), that only the 4 `SIO_n_IE` are non-constant, and that the 6 unused `_IN` paths are explicitly sunk. |
| TRPR-PHY-004 (SIO lane control) | `PSRAM_SIO_n_IE == ~PSRAM_SIO_n_OE`; the uncharacterized `IE=OE=1` state of `gf180mcu_fd_io__bi_t` never occurs | T | `cocotb/pad_tieoffs/test_pad_tieoffs.py` (job 5223) | ✅ Checked per-clock on all four lanes, with counters asserting the lanes were observed both driven and released so a stuck `OE` cannot pass vacuously. Complements the existing `GF180_IO_MODEL=1` foundry-model leg in `cocotb/psram_ops`, which checks the same invariant through the real `bi_t` cell on a single testcase. |
| TRPR-SPS-008 (pad leg) | `SPI_MISO_OE` tied 1 (Option A, point-to-point host link), not gated by `HOST_CS` | T | `cocotb/pad_tieoffs/test_pad_tieoffs.py` (job 5223) | ✅ The tie value is now asserted directly. The complementary functional half — the slave driving `SPI_MISO=0` while deselected, which is what makes `OE=1` safe — remains covered by `tb_trouper_spi.v` (job 3863). |

**Negative control (job 5225).** Because a tie-off test can easily be
vacuous, three faults were injected into `trouper_top.v` on a writable copy
and the suite re-run against each: `SPI_MISO_SL` 1→0 (slew mistake),
`PSRAM_SIO_2_IE` polarity inverted (`IE=OE`), and `IQ_DATA_I_1_PU` 0→1
(stray on-chip pull-up). **All three were caught by both testcases** with
diagnostics naming the offending port and its expected value. The script is
`cocotb/negctl_pad_tieoffs.sh` (kept on NFS; it must mutate under `$RUN_DIR`
because `/foss/designs` is mounted read-only).

**Note on the shared wrapper.** `cocotb/hdl/tb_trouper_cocotb.v` gained 96
pass-through output ports for this suite. They are pass-throughs only —
required because Verilator constant-folds unconnected constant outputs out of
the VPI hierarchy, so the tie-offs are unreachable from cocotb otherwise. The
4 `SIO_n_OE`/`_IE` are read from the wrapper's existing internal vectors.

**Open items:** `_PDRV*` and `_SL` values are *provisional pending SI review*
(Pinout.md). This suite proves the RTL drives what the document specifies; it
does **not** validate that those drive-strength/slew choices are electrically
correct. That remains a signoff/SI activity, and if the SI review changes a
value, `Pinout.md`, the expected table in `test_pad_tieoffs.py`, and the RTL
must be updated together.

---

## 4.1 ΣΔ Decimator (`sd_decimator_poly.v`) — TRPR-DEC

Migration record: `planning/decimator-hb-migration-impact-plan.md` (Gates
0–12) is the canonical evidence trail for the R=64 half-band chain.

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-DEC-001 | 1-bit I/Q @32 MS/s in → int8 I/Q out | T | `tb_decimator_poly_equiv.v`, every chain/cocotb test | ✅ |
| TRPR-DEC-002 | Fixed R=64 HB chain (CIC-3 R=16 → HB1 → HB2), 500 kS/s | T | `tb_decimator_poly_equiv.v` (bit-true vs `sd_decimator_poly_ref.v`/Python), migration Gates | ✅ |
| TRPR-DEC-003 | SQNR ≥ 30 dB at −3 dBFS | T | migration-plan Gate record; `tb_sqnr.v`/`tb_sqnr_4ch.v` | ⚠️ The standalone SQNR tbs target the pre-migration `sd_decimator_top`; the HB chain's SQNR evidence lives in the migration record's Python analysis, not a current-RTL testbench. |
| TRPR-DEC-004 | Identical branch inputs → bit-identical branch outputs (TDM) | T | `tb_dsp_chain_rand.v` (job 1789, per-branch oracle), `test_capture_playback.py` (distinct branches, ZDIAG ranking) | ✅ (functional) |
| TRPR-DEC-005 | CIC 14-bit modulo wrap-around; saturation prohibited | A | overflow-width derivation in the spec row; `sd_decimator_poly.v` arithmetic inspection | ✅ The requirement is analytical by design: 14 bits is the overflow-safe CIC width, and two's-complement wrap is required for comb cancellation. The prior matrix text incorrectly inverted the contract by calling for saturation and no wrap. |
| TRPR-DEC-006 | `iq_valid` every 64 clocks | T | every cocotb test (all timing math assumes `clk_per_iq=64`; any deviation fails lock/training immediately) | ✅ (functional) |
| TRPR-DEC-007 | Stopband > 40 dB | A | migration-plan filter analysis | ✅ (analysis, per Verif=A) |
| TRPR-DEC-008 | `bw_sel` selects BW only; R fixed at 64 | I | SF sweep (job 3311) passes both BWs with identical decimator timing | ✅ |
| TRPR-DEC-009 | Passband droop ≤ 0.5 dB (≈ −0.17 dB inherent) | A | migration record, `sim/tests/test_cfo_droop.py` | ✅ (analysis) |

**Open item:** DEC-003 standalone SQNR tb is stale vs the HB chain; regenerate it against `sd_decimator_poly` or retire it in favour of an explicitly versioned current-RTL SQNR regression. DEC-005 is an analysis requirement and does not call for saturation testing.

---

## 4.2 DC Removal (`dc_removal.v`) — TRPR-DCR

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-DCR-001..004, 009, 011 | Structure: 4 branches, Q8.5 acc, full-diff update, int8 I/O, fixed α=1/32, `out_valid` = `raw_valid`+1 | I | inspection + every chain test times downstream from `out_valid` | ✅ (per Verif=I; structure exercised continuously by all chain tests) |
| TRPR-DCR-005, 007, 008, 010 | τ=64 µs, no-saturation bound, acc-overflow-impossible bound, AC droop < 0.1 dB | A | arithmetic analysis in spec rows | ✅ (analysis) |
| TRPR-DCR-006 | Steady-state DC < 1 LSB after 256 samples | T | `cocotb/dc_removal/test_dc_removal.py::test_constant_dc_is_zero_within_256_samples` | ✅ Directed direct-DUT sweep of positive and negative DC codes through all 8 I/Q paths; every residual is 0 after 256 valid samples. |
| TRPR-DCR-012 | Reset clears accumulators/outputs | T | every cocotb test (full reset per case, immediate clean re-lock) | ✅ (functional) |
| TRPR-DCR-013 | Post-reset one-time-constant DC settling | T | `cocotb/dc_removal/test_dc_removal.py::test_reset_dc_settles_by_one_time_constant` | ✅ Directed full-scale ±127 DC from reset; all eight paths are within the mathematically correct ±13 LSB 90%-settling bound at 74 valid samples. The former “<1 LSB at 74” wording was inconsistent with a 32-sample IIR and was corrected in the spec. |
| TRPR-DCR-014 | No bypass port (by design) | I | — | ✅ (by construction) |
| TRPR-DCR-015 | ≥64-sample `sc_lock` hold-off after reset (provided by PSRAM warm-up) | T | `cocotb/tests/test_startup.py::test_sc_correlator_idle_until_del_rdy` | ✅ Spec reworded 2026-07-06: the old "open RTL gap" text predated the PSRAM migration — SC evaluations cannot begin until `del_rdy` (M ≥ 128 warm-up samples ≥ the required 64), measured by `test_startup.py`. |

**No remaining DC-removal traceability gap.** DCR-006/013 have direct-DUT coverage; DCR-015 is covered by PSRAM warm-up.

---

## 4.4 SC Delay Line / former Frontend Buffer — TRPR-FBC

The `frontend_buf_ctrl` block was removed; the PSRAM controller provides
the delay line. These rows are traced against their PSRAM equivalents.

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-FBC-001 | M-sample delay via PSRAM QPI read at `write_ptr − M` | T | = TRPR-PSR-016 | ✅ (see PSR-016) |
| TRPR-FBC-002 | At packet start: latch packet-start pointer, cease SC delay reads (off `sc_lock`) | T | = TRPR-PSR-002/016 (`test_capture_playback.py`, formal) | ✅ Spec reworded 2026-07-06 to the actual `sc_lock`-based plumbing (was written against the removed `buf_freeze` path; that FSM output was itself deleted 2026-07-26). Behavior fully verified via PSR-002/016. |
| TRPR-FBC-003 | `x[n]`/`x[n−M]` valid & stable before each evaluation | T | `test_capture_playback.py`, `test_startup.py` (warm-up), formal `a_del_valid_needs_rdy` | ✅ |
| TRPR-FBC-004 | Delay-read vs capture-write arbitration margin | A | = TRPR-PSR-014 | ✅ (analysis + formal) |
| TRPR-FBC-005 | Legacy frontend registers removed; status via `PSRAM_STATUS` | I | `tb_trouper_spi.v` (reserved/removed addresses read 0) | ✅ |

---

## 4.6 Weight Generation (firmware path) — TRPR-WGN

No hardware weight block exists (WGN-001); rows trace the firmware-facing
contract. (`CLAUDE.md`'s block list still names a `weight_gen.v` — stale.)

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-WGN-001 | No HW weight_gen block | I | — | ✅ (by construction — no such module in `src/`) |
| TRPR-WGN-002 | Z_kl/Z_kk exposure for firmware | T | = TAC-004/005 (`test_weight_gen_spi_flow.py`, job 3286) | ✅ |
| TRPR-WGN-003 | W shadow write + `W_COMMIT` within W_PENDING | T | `test_weight_gen_spi_flow.py`, `test_psram_ops.py` | ✅ |
| TRPR-WGN-004 | Firmware timing margins (same-packet replay) | A | spec-row margin analysis | ✅ (analysis) |
| TRPR-WGN-005 | Primary mode: MRC row-sum | T | `sim/tests/run_ber.py` (Python model only) | ⚠️ The full SPI flow test used the *eigenvector* mode; no end-to-end flow test commits MRC-row-sum weights. Low risk — the hardware path is weight-agnostic (proven bit-exact for arbitrary W by job 3286) — but the row-sum arithmetic itself is Python-only. |
| TRPR-WGN-006 | Secondary mode: power-iteration eigenvector | T | `test_weight_gen_spi_flow.py` (job 3286, bit-exact vs `sim/models/eigvec_fw.py`), `sim/tests/test_eigvec_fw.py` | ✅ |
| TRPR-WGN-007 | MRC/eigenvector/NW-MRC mode selectable in firmware, no HW register | I | — | ✅ (by construction) |
| TRPR-WGN-012 | Optional noise-weighted MRC uses per-branch `σ²_ema` | T | `test_eigvec_nw_fw.py::test_snrw_register_units_matches_picorv32_trace_job_3612`, SGE job 3612 | ✅ Firmware/model bit-exact on a traced unequal-noise 24-bit register vector; the model regression pins all eight Q1.15 components. |
| TRPR-WGN-008 | Bypass on missed commit + firmware-memory missed-packet counter | T | bypass half = PCF-005 (✅, jobs 3305/3310); HW inputs to the counter (IRQ[2], sticky `WGT_CTRL[3]`/`PACKET_STATUS[7]`) all verified | ✅ Spec clarified 2026-07-06: `DBG_MISSED_PKTS` is a **firmware variable**, not a Trouper register (same software-owned pattern as the AGC-002 thresholds) — the phantom-register ambiguity from the 2026-07-05 reconciliation is resolved. The firmware increment itself is untestable from RTL (tracked with the rest of firmware coverage, Open Risks #8). |
| TRPR-WGN-009 | *(REMOVED — no `Z_SHIFT`)* | — | — | ✅ (reworded 2026-07-05) |
| TRPR-WGN-010/011 | `cal_j` scalar-only correction; linear-combiner impairment documentation | A | — | ✅ (analysis/documentation statements, no test target) |

---

## SPI Slave (`spi_slave.v`) — TRPR-SPS

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-SPS-001/002/003 | Mode-0 frames, R/W#+7-bit-addr command byte, reg-bus translation | T | `tb_trouper_spi.v` (21 checks, job 1693), every cocotb SPI helper | ✅ |
| TRPR-SPS-004 | Max SPI clock 2 MHz | A | `test_clock_limit_sweep` exercises 1/2 MHz; 8/10 MHz are retained as over-spec stress tests | 🟨 Baseline SDC now declares 2 MHz, but board-specific pad delays and post-P&R STA remain open (Open Risk #38). |
| TRPR-SPS-005 | CS/SCK synchronisers (async domain) | I | inspection; POR frame-flop fix verified (Open Risks #26, closed 2026-07-02) | ✅ |
| TRPR-SPS-006 | `CHIP_ID` = 0xA7 | T | `tb_trouper_spi.v`, every cocotb test's settle read | ✅ |
| TRPR-SPS-007 | Grouper priority; pending SPI write; colliding-read retry | T | `tb_trouper_grp_arb.v` (full-strobe write overlap and MISO-load read overlap) | ✅ job 3863 |
| TRPR-SPS-008 | Dedicated `SPI_MISO` drives low while CS high | T | `tb_trouper_spi.v` (idle and post-read release checks) | ✅ job 3863 |
| TRPR-SPS-009 | Read-data timing (addr latched on 8th SCK edge) | T | `tb_trouper_spi.v` (the 2026-06-12 one-byte-late bug's regression) | ✅ |
| TRPR-SPS-010 | Burst auto-increment mod 128; `0x76` exception | T | `tb_trouper_spi.v` (16-byte burst + 0x7E→0x00 wrap) | ⚠️ Auto-increment fully tested. The `0x76` no-increment *exception* is proven only via repeated single-transaction reads (`test_psram_ops.py` drains 8 bytes that way, job 3313) — never inside one continuous CS-low burst. |
| TRPR-SPS-011 | `0x7F` reserved (protocol escape) | I | `tb_trouper_spi.v` | ✅ |

**Open item:** SPS-010 in-burst 0x76 case.

---

## SPI Master — TRPR-SPM

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-SPM-001/002 | No on-chip SPI master; SX1257 config is external | I | — | ✅ (by construction — no master RTL; `CLAUDE.md`'s "SPI Master (→ SX1257)" control-plane line is stale) |

---

## Register Bank (`reg_bank.v`) — TRPR-REG

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-REG-001 | All registers per map: reset values, R/W permissions | T | `tb_trouper_spi.v` (reset spot-checks: SF/MIMO/COMB_CFG/TACC_WINDOW; write masks; RO-write-ignored), `cocotb/reg_reset_sweep/test_reg_reset_sweep.py` (job 3319, full 128-address reset sweep) | ✅ Closed 2026-07-06: sweeps every SPI address 0x00-0x7F against `Register Map.md`'s Reset column, both immediately after power-on and after dirtying every safely-writable register and resetting again (catches a reset net coincidentally matching the all-zero power-on state). Found and fixed a second reset-value map error while writing it: `PSRAM_DBG_CTRL` (0x75) documented `0x00`, actual reset `0x80` (`DBG_BUSY` held until `qe_init_done`) — map corrected alongside the 0x1D fix. Z_kl/Zdiag bank (0x40-0x6F) is excluded by design: `training_acc.v` intentionally does not reset those accumulators (area optimisation, `tb_tacc_resetless_equiv.v`), so no fixed power-on value exists to assert. R/W permission sweep (write masks, RO-write-ignored) remains covered only by the existing spot-checks in `tb_trouper_spi.v`. |
| TRPR-REG-002 | `GRP_*` **byte** request/ack bus reachable from SPI bridge and Grouper master, Grouper priority (reworded 2026-07-26 from "8-bit AHB-Lite slave" — no `H*` signal exists in the RTL; audit item 14) | T | `tb_trouper_grp_arb.v` | ✅ |
| TRPR-REG-003 | Multi-byte registers big-endian | I | every multi-byte read in the suites (Z, N_ACC, SC snapshots, W) | ✅ (functional) |
| TRPR-REG-004 | Reserved reads 0, writes ignored | T | `tb_trouper_spi.v` | ✅ |
| TRPR-REG-005 | Register bank is custom RTL; Register Map.md is the source of truth, RTL+map updated together | I | register-level tests throughout the suites | ✅ Spec reworded 2026-07-06 (was "generated by the project Python tool" — no generator exists or is planned; reg_bank is deliberately hand-written). The discipline the reworded requirement demands is what this matrix enforces; a full generated reset/RW sweep test (REG-001 note) remains the recommended backstop. |
| TRPR-REG-006 | W1P registers self-clear | T | `tb_trouper_spi.v` + all four remaining W1Ps functionally exercised (W_COMMIT everywhere; NOISE_TRIG job 3310; CLR_ERR + RD_TRIG job 3313). `RX_GAIN_COMMIT` (former tb_spi #13) removed 2026-07-28 along with the register it belonged to — see TRPR-AGC-003. | ✅ |
| TRPR-REG-007 | Sticky status clears only via explicit clear register | T | `tb_trouper_two_packet.v` (job 3203), every IRQ_CLEAR use since | ✅ |

---

## IRQ — TRPR-IRQ

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-IRQ-001 | Five sticky sources at bits [4:0] | T | bit0/1: every suite; bit2: `test_w_missed_packet.py`; bit3: same; bit4: `test_noise_trig.py` (all job 3310+) | ✅ All five bits now exercised at their positions. |
| TRPR-IRQ-002 | Per-bit clear via `IRQ_CLEAR` | T | `tb_trouper_two_packet.v` (job 3203, the Open Risks #3 fix regression) + ubiquitous use | ✅ |
| TRPR-IRQ-003 | `IRQ_OUT` + `IRQ_GROUPER` both driven by `\|irq_status` | T | `cocotb/irq_pins/test_irq_pins.py::test_irq_pins_sticky_clear` (Verilator, 2026-08-29, 1/1 PASS, 2.33 s) | ✅ Both top-level pins are sampled directly: they assert together when `TRAINING_DONE` and `NOISE_READY` become sticky, and are always equal. |
| TRPR-IRQ-004 | Level-high until all bits cleared | T | `cocotb/irq_pins/test_irq_pins.py::test_irq_pins_sticky_clear` (pin-level), `tb_trouper_two_packet.v` (status-level) | ✅ Directed selective-clear proof: clearing `NOISE_READY` while `TRAINING_DONE` remains sticky holds both pins high; clearing the final bit drops both, and a 16-clock dwell proves no re-assertion from the held `training_done` level. |
| TRPR-IRQ-005 | *(DELETED — JTAG removed)* | — | — | — n/a |
| TRPR-IRQ-006 | Edge-set (no re-assert of cleared bit while source held) | T | `tb_trouper_two_packet.v` (job 3203 fix) | ✅ |

**No remaining pin-level IRQ gap.**

---

## AGC (firmware strategy + hardware hooks) — TRPR-AGC

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-AGC-001 | Per-antenna power via `Zdiag/n_acc` readback | T | `test_weight_gen_spi_flow.py` (3286), `test_noise_trig.py` (3310) | ✅ |
| TRPR-AGC-002 | Software-owned threshold strategy (no HW comparators) | T | — | ✅ (reworded 2026-07-05; nothing in RTL to test — firmware coverage tracked as Open Risks #8) |
| TRPR-AGC-003 | *(REMOVED 2026-07-28 — `RX_GAIN_SHADOW/ACTIVE/CTRL` at 0x10-0x18 deleted; Trouper has no SX1257 SPI/control outputs, so the on-chip shadow→active latch had no hardware consumer)* | — | — | — n/a |
| TRPR-AGC-004 | Noise window via `TACC_NOISE_TRIG` | T | `test_noise_trig.py` (job 3310) | ✅ |
| TRPR-AGC-005 | Per-antenna noise EMA in firmware | T | — | ℹ️ Firmware-only (no RTL surface); untested firmware is the substance of Open Risks #8 — not closable from this matrix. |

---

## JTAG — TRPR-JTG

All four rows **DELETED** in the spec (no TAP, no GPIO in RTL); nothing to trace. ✅ n/a.

---

## Integration / Control Fabric — TRPR-INT

| ID | Requirement (short) | Verif | Test(s) | Status |
|---|---|---|---|---|
| TRPR-INT-001/007/008 | Fabric exists; one shared map; byte-only transactions | I | `tb_trouper_grp_arb.v` + all SPI suites | ✅ |
| TRPR-INT-002 | Grouper path reaches full register map, same semantics | T | `tb_trouper_grp_arb.v` (GRP write → SPI readback and vice versa) | ✅ |
| TRPR-INT-003 | Arbiter: Grouper priority, SPI-write pending slot, read retry | T | `tb_trouper_grp_arb.v` (collision cases 3a/3b/4a) | ✅ |
| TRPR-INT-004 | Grouper idle/reset → SPI-only operation clean | T | `cocotb/tests/test_host_only_e2e.py::test_host_spi_only_same_packet_mrc_replay` (Verilator, 2026-08-29, 1/1 PASS, 2.19 s); all other top-level cocotb suites also tie `GRP_*` off in `tb_trouper_cocotb.v` | ✅ **Dedicated standalone proof added 2026-08-29.** Explicitly ties `GRP_ADDR`/`GRP_WDATA`/`GRP_WE`/`GRP_RE` low and rechecks them at every host-SPI transaction boundary. Host SPI alone enables and initialises PSRAM, configures and locks RX, observes `TRAINING_DONE`, reads `ZDIAG`, writes/commits W, and reaches monotonic same-packet MRC replay without `REPLAY_MISSED`. |
| TRPR-INT-005 | IRQ line to Grouper on any status bit | T | `cocotb/irq_pins/test_irq_pins.py::test_irq_pins_sticky_clear` (Verilator, 2026-08-29, 1/1 PASS) | ✅ `IRQ_GROUPER` is directly sampled alongside `IRQ_OUT` through assertion, selective clear, final clear, and post-clear dwell. |
| TRPR-INT-006 | Single 32 MHz clock; control plane CE-gated to 16 MHz effective (no `CLK_16M` net) | I | CE-gating verified by the SPI-write timing work (`[[project_ce16_partition]]`, all register suites) | ✅ Spec reworded 2026-07-06 to the implemented single-clock + clock-enable architecture (was written against a two-clock `CLK_16M` scheme that never shipped; this also retires the corresponding item of Open Risks #24's clock-architecture drift). |
| TRPR-INT-009 | Commit flow (Z read → W write → commit → latch) | T | `test_weight_gen_spi_flow.py` (job 3286) | ✅ |
| TRPR-INT-010 | Bypass when Grouper inactive / no commit | T | `test_w_missed_packet.py`, `test_bypass_e2e.py` (jobs 3304–3310) | ✅ |
| TRPR-INT-011 | Host pre-config over SPI without firmware | T | every cocotb suite's setup sequence is exactly this | ✅ |
| TRPR-INT-012 | Grouper-inactive Mode-1 = functional single-antenna path | T | `test_bypass_e2e.py` (job 3304, raw stream to remod end-to-end) | ✅ |

**Open items surfaced by this pass (all blocks above):**
1. ~~Two false/stale documentation claims~~ — **RESOLVED 2026-07-06**: REG-005 reworded to the deliberate custom-RTL + map-as-source-of-truth discipline; WGN-008's `DBG_MISSED_PKTS` clarified as a firmware variable; `CLAUDE.md` block list corrected.
2. ~~DCR-015's "open RTL gap" is stale~~ — **RESOLVED 2026-07-06**: spec reworded to the warm-up-provided hold-off.
3. ~~FBC-002 and INT-006 describe plumbing that doesn't exist~~ — **RESOLVED 2026-07-06**: both reworded to the shipped plumbing (`sc_lock`-latched pointer; single-clock + CE). `buf_freeze` itself was deleted from the RTL 2026-07-26 (Open Risks #25).
4. **Cheap remaining test add:** in-burst 0x76 non-increment (SPS-010). Pin-level `IRQ_OUT`/`IRQ_GROUPER` assertion/clear behavior closed 2026-08-29 by `cocotb/irq_pins`. (MISO deselected-low coverage for SPS-008 closed in job 3863; full reset register sweep for REG-001 closed 2026-07-06.)
5. **Stale standalone tbs:** `tb_sqnr*.v` predate the HB migration (DEC-003) — regenerate against `sd_decimator_poly` or retire in favor of the migration-record analysis.
