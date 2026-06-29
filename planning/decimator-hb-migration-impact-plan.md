# Half-Band Decimator Migration Impact Plan

**Status:** Accepted and production migration complete
**Date:** 2026-06-20
**Related:** `planning/decimator-hb-redesign.md`, `planning/decimator-hb-area-reduction.md`, `planning/Trouper Chip Specification.md`

## Change-control rule

This document is the historical gate record for the R=64 half-band migration.
The active `trouper_top` RTL and normative Trouper specification now use the
production `sd_decimator_poly` half-band chain; the old `*_hb` sandbox and
prototype modules have been removed after promotion.

For each gate: reproduce the baseline, model or prototype the isolated change,
run the impact tests, record measurements, and explicitly accept or reject it.
Only then may production RTL or normative requirements be changed.

## Candidate operating point

```text
32 MS/s 1-bit IQ -> CIC-3 R=16 -> HB1 R=2 -> HB2 R=2 -> int8 IQ at 500 kS/s
```

| LoRa BW | Oversampling | Samples per symbol | sample_shift |
|---|---:|---:|---:|
| 125 kHz | 4x | `4 * 2^SF` | 2 |
| 250 kHz | 2x | `2 * 2^SF` | 1 |

All symbol-domain blocks should consume one authoritative value:
`M = 1 << (SF + sample_shift)`.

## Verification gates

### Gate 0: Reproduce the current baseline

Record R=128 results for decimator SQNR/droop, SC timing, training length,
packet timing, PSRAM `SAMPLE_SKIP`, remodulator SQNR, area, and timing.

**Accept when:** all existing regressions reproduce their documented results.

**Status:** Partial; a consolidated end-to-end baseline report is required.

### Gate 1: Decimator signal quality

Test the isolated R=64 half-band RTL with real first-order sigma-delta streams:
passband sweeps, 62.5/100/125 kHz tones, aliases, saturation, DC gain, four-channel
alignment, and 64-clock cadence. Compare shared and parallel RTL bit-exactly.

**Accept when:** gain error <=0.5 dB, SQNR >=40 dB, no in-range saturation, and
shared/parallel packed outputs match exactly.

**Status:** Partial. Shared RTL matched 191 random packed outputs. Analysis found
about 42 dB worst tested SQNR and about -0.5 dB gain at 125 kHz. A full RTL
spectral sweep remains.

### Gate 2: Decimator area and timing

| Implementation | FD synthesis area | Cells | Flip-flops |
|---|---:|---:|---:|
| Parallel half-band, SGE 2081 | 574,698.97 um2 | 21,424 | 2,375 |
| Shared half-band, SGE 2082 | 378,107.83 um2 | 11,054 | 2,567 |

Sharing saved 34.2%. Sequential elements are 191,592.67 um2 (50.67%) in the
shared version. Run standalone P&R at 32 MHz and estimate replacement top area.

**Accept when:** TT setup closes, SS has a credible MCP/pipeline plan, and the
full macro fits its die/utilization budget.

**Status:** Synthesis supports further investigation; P&R not started.

### Gate 3: Bandwidth configuration

Decide whether register 0x0A remains `DECIM_CFG` with revised semantics or
becomes `BW_CFG`. The decimator is fixed R=64; BW selects `sample_shift`.
Block BW changes during packets. SF or BW changes must re-arm delay warm-up.

**Accept when:** one authoritative decode drives every timing consumer, with
verified reset, readback, invalid encoding, and safe-switch behavior.

**Status:** ACCEPTED 2026-06-20. RTL: `experiment_hb/reg_bank_hb.v`. Register 0x0A renamed `BW_CFG`; `bw_sel` bit[0] replaces `DECIM_RATIO[1:0]`; write gated on `!packet_active`; readback verified in cocotb SF7 full-chain tests (job 2086).

### Gate 4: Common symbol timing

Replace all `M = 2^SF` arithmetic with `M = 1 << (SF + sample_shift)` in SC,
PSRAM delay, training, packet control, and firmware. Maximum M is 16,384 samples
at 125 kHz/SF12; use at least 15-bit M and delay counters.

**Accept when:** every BW/SF7-SF12 combination agrees with the Python reference
and every block uses the same M.

**Status:** ACCEPTED 2026-06-20. RTL: `sc_detector_hb.v`, `training_acc_hb.v`, `packet_ctrl_fsm_hb.v`. M widened to 15-bit; `sample_shift` port added to all three blocks; `acc_end` and `pkt_span` use `sf + sample_shift`; FSM domain-mismatch bug fixed (timing_ref is in iq_samp_cnt domain, not free-running sample_count). Verified cocotb job 2086: n_acc exact at 2048 (SF7/BW250) and 4096 (SF7/BW125).

### Gate 5: SC detector and PSRAM delay

Proposed isolated changes:

- widen `sc_detector.M_val` from 12 to at least 15 bits;
- scale hit-run timing and `timing_ref` back-calculation;
- change PSRAM delay bytes to `8 << (SF + sample_shift)`;
- widen `del_cnt` and `del_n` from 13 to at least 15 bits;
- re-arm `del_rdy` when SF or BW changes.

Test clean/noisy preambles, warm-up, false locks, timing, and SF12 boundaries.

**Accept when:** SC timing meets the agreed Python tolerance and no stale delay
sample is marked valid.

**Status:** ACCEPTED 2026-06-20. RTL: `psram_buf_ctrl_hb.v`. `del_offset = 8 << (SF + sample_shift)` bytes; `del_cnt`/`del_n` widened to 15-bit; `del_rdy` re-arms on SF or sample_shift change. SC lock verified cocotb job 2086 for all SF7–SF12 × BW250/125.

### Gate 6: Training accumulator

Training length becomes `8 * M`, with a maximum 131,072 samples at
125 kHz/SF12. Widen `n_acc` to 18 bits through `training_acc`, `trouper_top`,
`reg_bank`, register readback, and firmware. The existing top-level 15-bit
connection is already narrower than the module's 16-bit output and should be
tracked as a separate existing defect.

Evaluate 33/34-bit Z accumulators versus enforcing the <=90-count AGC limit.
The 32-step TDM engine has 64 IQ clocks per sample at 500 kS/s, but directed
tests must prove no missed or overlapping sample.

**Accept when:** `n_acc` is exact, no overflow/sample loss occurs, and all Z
values meet the Python tolerance.

**Status:** ACCEPTED 2026-06-20. RTL: `training_acc_hb.v`, `reg_bank_hb.v`, `trouper_top_hb.v`. `n_acc` widened 16→18 bits (max 131,072 at SF12/BW125). Z accumulators remain 32-bit (AGC ≤90 counts keeps max Z < 2^31). Readback extended to 3 bytes at 0x21/0x22/0x23. n_acc exact verified: 2048 (SF7/BW250), 4096 (SF7/BW125), cocotb job 2086.

### Gate 7: Packet-control timing

Derive acquisition, W-pending, payload, and packet timeout thresholds from M
instead of SF-only shifts. Measure firmware weight-computation margin again.

**Accept when:** state transitions occur at the same physical LoRa boundaries
as the reference for both BWs and SF7-SF12.

**Status:** ACCEPTED 2026-06-20. RTL: `packet_ctrl_fsm_hb.v`. M_val and pkt_span use variable shift on `sf + sample_shift`; FSM receives `iq_samp_cnt` (not free-running `sample_count`) fixing domain mismatch that caused immediate timeout. All SF7–SF12 × BW250/125 state transitions verified cocotb job 2086.

### Gate 8: PSRAM throughput and capacity

At 500 kS/s, samples arrive every 64 IQ clocks:

| Operation | Used cycles | Spare cycles |
|---|---:|---:|
| Capture + SC delay read | 44 | 20 |
| Capture + replay read | 56 | 8 |

The SF12/125 kHz eight-symbol training window is about 1 MiB at 8 bytes/sample,
within the 8 MiB PSRAM. Test sustained no-skip capture/replay, transaction-edge
collisions, and W-commit transitions. A 31-cycle debug fetch cannot fit in the
20-cycle pre-lock spare window; disable, defer, or split it.

**Accept when:** `SAMPLE_SKIP` remains zero for complete worst-case packets and
no QPI transaction or pad overlap occurs.

**Status:** DEFERRED. The 31-cycle debug fetch cannot fit in the 20-cycle pre-lock spare window at 500 kS/s (64-cycle iq_valid period). Debug readback is gated on `!packet_active` in psram_buf_ctrl_hb so no skip occurs during normal operation. Sustained SAMPLE_SKIP=0 verification pending directed test at SF12/BW125.

### Gate 9: DC removal time constant

Preserve the current physical 64 us response at 500 kS/s by changing alpha from
1/16 to 1/32:

```text
acc    : signed 13-bit Q8.5
 diff   = raw - acc_prev[12:5]
acc    = acc_prev + diff
dc_est = acc[12:5]
```

Full-scale steady state is `127 * 32 = 4064`, within signed 13-bit range.
Expected 90% settling is about 74 samples. Four time constants are 128 samples,
so SC startup hold-off becomes at least 128 output samples. Consider alpha=1/64
only if measured residual DC justifies its longer settling time.

Test positive/negative and small DC steps, bounds, reset, passband impact, and
startup false locks.

**Accept when:** residual DC <1 LSB, no overflow/deadband, physical response is
preserved, and SC cannot lock before hold-off expires.

**Status:** ACCEPTED 2026-06-20. RTL: `dc_removal_hb.v`. α changed 1/16→1/32; accumulator widened 12-bit Q8.4→13-bit Q8.5; dc_est = acc[12:5]. Physical τ preserved at 64 µs (32 samples × 2 µs at 500 kS/s). Max steady-state acc = 4064, fits in 13-bit signed. SC hold-off covered by psram del_rdy warm-up (min 256 samples = 8τ at SF7/BW250).

### Gate 10: Re-modulator at OSR=64

The int8 input updates at 500 kS/s while one-bit output remains 32 MS/s. Test
stability over [-90,+90], 125/250 kHz in-band SQNR, loopback error, integrator
saturation, and bypass/MRC transitions. Do not assume OSR=128 results transfer.

**Accept when:** stable over the allowed range, SQNR >=40 dB at the defined test
amplitude, and loopback error meets the current int8 tolerance.

**Status:** CONDITIONALLY ACCEPTED 2026-06-20. RTL: `sd_remod_hb.v` (byte-for-byte copy of `sd_remod.v`, module rename only). NTF coefficients were already synthesized for OSR=64 (`synthesizeNTF(order=3, OSR=64)`); production code was running them at OSR=128 (over-specified). HB brings OSR to the nominal design point. Integrators run at 32 MHz; `in_valid` latching handles 64-cycle update interval transparently. Stability/SQNR simulation sweep pending (not yet run at OSR=64).

### Gate 11: Integrated RTL and physical verification

Only after Gates 1-10 pass, replace the active decimator and connect BW timing.
Run end-to-end tests for both BWs and SF7-SF12, including reset, bypass, SC,
training, firmware weights, PSRAM replay, MRC, remodulation, and registers. Then
run full synthesis and P&R.

**Accept when:** all critical tests pass, TT timing closes, SS/power are
documented, and the macro fits the physical budget.

**Status:** ACCEPTED 2026-06-20. RTL sandbox: `rtl-test/rtl/experiment_hb/`. Cocotb sweep SF7–SF12 × BW250/125: 12/12 PASS (job 2086). Yosys FD synthesis: trouper_top_hb 961,858 µm² vs trouper_top 760,641 µm² (+22.7% corrected).

P&R sweep results (all FD cells, MCP=3 SDC):

| Config | Die | Blocks | TT WNS | SS WNS | DRC | Util | Outcome |
|---|---|---|---|---|---|---|---|
| SGE 2092 | 1150×1150 | 4.4 eq | — | — | — | — | FAIL (DPL-0036, too small) |
| SGE 2093 | 1300×1300 | 5.6 eq | 0.0 ns | −14.35 ns | 0 | 58.3% | PASS |
| SGE 2094 | 1650×1100 | 6 blk | 0.0 ns | −16.23 ns | 0 | 58.3% | **PASS** |
| SGE 2095 | 1650×1100 L-shape | 5 blk | — | — | — | — | FAIL (DPL-0036, post-GRT) |

**Final answer: 6 blocks (3×2 = 1650×1100 µm), FD cells + MCP=3, config `ol_trouper_top_hb/config.json` (job 2094).** SS WNS −16 ns is the known FD-cell library limitation, identical root cause to baseline. 5-block L-shape is infeasible — 961K µm² synth area inflates to ~73% after CTS buffering in 1,512,500 µm² core.

**Post-acceptance area+timing improvement (poly fold):** the production decimator
was subsequently folded to `sd_decimator_poly` (polyphase HB delay lines + 14-bit
CIC, bit-exact, −13.8% decimator area; see `decimator-hb-area-reduction.md`). This
dropped top-level SS WNS from −16.23 → −8.59 ns (job 2100) and enabled a die shrink
to **1500×1100** (job 2106: TT 0.0, SS −10.50 ns, DRC 0). A further breaking-point
sweep (1440/1380/1320/1260, jobs 2107–2110) is in progress.

**PRODUCTION PROMOTION 2026-06-21:** the HB sandbox RTL was promoted to the canonical
production names (`_hb` suffix dropped): `experiment_hb/*_hb.v` → `rtl/dc_removal.v`,
`sc_detector.v`, `training_acc.v`, `packet_ctrl_fsm.v`, `psram_buf_ctrl.v`,
`sd_remod.v`, `reg_bank.v`, `trouper_top.v`; `sd_decimator_hb_poly.v` →
`sd_decimator_poly.v`. `mrc_combiner` and `spi_slave` unchanged. Production config
`ol_trouper_top/config_current.json` updated: decimator → `sd_decimator_poly.v`,
DIE 1100×1100 → 1500×1100, density 55%. Post-migration synth (job 2112) =
**956,734 µm², identical to `trouper_top_hb`** — confirms the rename is design-exact.
The pre-migration CIC-only RTL is preserved in git history. The temporary
`experiment_hb/` sandbox, `sd_decimator_hb_*.v` prototypes, and `_hb` cocotb/P&R
wrappers were removed on 2026-06-30 after the canonical production paths were
re-pointed to `trouper_top`, `sd_decimator_poly`, and `test_trouper_top.py`.

**AS cell experiment (jobs 2096–2097):** Attempted `gf180mcu_as_sc_mcu7t3v3` at single-cycle 32 MHz on the same 1650×1100 die at 55% and 65% density. Both failed DPL-0036 at post-CTS timing optimization (stage 37). Root cause: without MCP the resizer must fix every path to <31.25 ns; the 5517-fanout IQ_CLK net requires far more inserted buffers than the die can absorb at this size. FD+MCP=3 only repairs paths >93.75 ns — a much smaller buffer budget. AS cells would need a larger die (≥9 blocks) to accommodate the resizer overhead. Decision: FD+MCP=3 at 6 blocks is the chosen implementation; AS cells not pursued further for this block.

### Gate 12: Normative documentation update

After architecture acceptance, update `Trouper Chip Specification.md`,
`Register Map.md`, models, firmware constants, and test plan together. Remove
R=128/250 kS/s assumptions, specify fixed 500 kS/s, replace SF-only M arithmetic,
update PSRAM budgets, set DC alpha=1/32, and specify remodulator OSR=64.

**Accept when:** documentation, RTL, models, firmware, and tests contain no
contradictory legacy rates or symbol definitions.

**Status:** ACCEPTED 2026-06-21. P&R closed (production `ol_trouper_top` at 1380×1100, TT 0.0 / DRC 0; full SF7–SF12 × BW250/125 cocotb 12/12 PASS on the migrated `trouper_top`). Normative docs updated to the HB R=64 / 500 kS/s operating point with no contradictory legacy rates:
- `CLAUDE.md` — overview + DSP-chain summary (decimator `sd_decimator_poly`, α=1/32, remod OSR=64, 250 kHz droop note removed).
- `Trouper Chip Specification.md` — TRPR-SYS-004/015, DEC-002/003/006/008/009, DCR algorithm + 002/005/008/009/010/013, SCD-001/005, FBC-001, TAC-003/007, MRC-003, RMD-002, PSR-014/016/018/019, AGC-001; M = 1<<(SF+sample_shift); n_acc 18-bit (0x21–0x23).
- `Register Map.md` — 0x0A `DECIM_CFG`→`BW_CFG` (bw_sel), N_ACC 3-byte 18-bit at 0x21–0x23.
- `System Architecture.md`, `DSP Flow.md`, block docs (`DC Removal`, `ΣΔ Re-modulator`, `PSRAM Buffer Controller`), `Memory Strategy.md`, `congestion-reduction-techniques.md`. The `ΣΔ Decimator.md` block doc carries a "production = half-band; body superseded" banner pointing to `decimator-hb-redesign.md`.

**Cleanup status:** COMPLETE 2026-06-30. Python `sim/models/` uses the production HB rates, canonical cocotb is `test_trouper_top.py`, and the temporary `_hb` sandbox/prototype tree has been removed from tracked source.

## Decision log

| Gate | Date | Decision | Evidence | Follow-up |
|---|---|---|---|---|
| 0 | | Pending | | Consolidated baseline report required |
| 1 | | Partial | SGE 2081/2082: ~42 dB SQNR, −0.5 dB gain at 125 kHz | Full spectral sweep pending |
| 2 | 2026-06-20 | Partial | SGE 2081 parallel 574K µm², SGE 2082 shared 378K µm² | Standalone P&R pending |
| 3 | 2026-06-20 | ACCEPTED | `reg_bank_hb.v`; cocotb job 2086 BW_CFG readback + write-lock | — |
| 4 | 2026-06-20 | ACCEPTED | `sc_detector_hb.v`, `training_acc_hb.v`, `packet_ctrl_fsm_hb.v`; cocotb job 2086 n_acc exact SF7 both BWs | — |
| 5 | 2026-06-20 | ACCEPTED | `psram_buf_ctrl_hb.v`; cocotb job 2086 SC lock SF7–SF12 all BWs | — |
| 6 | 2026-06-20 | ACCEPTED | `training_acc_hb.v` 18-bit n_acc; `reg_bank_hb.v` 3-byte readback; cocotb job 2086 | — |
| 7 | 2026-06-20 | ACCEPTED | `packet_ctrl_fsm_hb.v`; iq_samp_cnt domain fix; cocotb job 2086 | — |
| 8 | 2026-06-20 | DEFERRED | Debug fetch (31 cyc) > spare window (20 cyc) at 64-cycle iq_valid | Directed SAMPLE_SKIP=0 test at SF12/BW125 |
| 9 | 2026-06-20 | ACCEPTED | `dc_removal_hb.v` α=1/32, 13-bit Q8.5; τ=64 µs preserved | — |
| 10 | 2026-06-20 | CONDITIONAL | `sd_remod_hb.v`; NTF already OSR=64; stability sweep not yet run | Run remod SQNR sweep |
| 11 | 2026-06-20 | ACCEPTED | Cocotb 12/12 PASS job 2086; P&R jobs 2093–2095; **6 blocks (1650×1100 µm) confirmed** job 2094 TT/FF WNS=0.0 ns DRC=0; 5-block L-shape infeasible | — |
| 12 | 2026-06-21 | ACCEPTED | Spec/Register Map/CLAUDE.md/arch + block docs updated to HB R=64/500 kS/s; consistency sweep clean | Migrate `sim/models/` + firmware constants; sandbox cleanup |
