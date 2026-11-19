# SC `timing_ref` is structurally late → replay preamble shortfall (Open Risks #81)

2026-10-03. Found while repairing `sim/notebooks/03_nonfft_dsp_chain.ipynb`. Mitigated by
`REPLAY_BACKDATE_SYMS` (0x7B).

## 1. Finding

`src/frontend/sc_detector.v` makes one hit decision per symbol, on a symbol grid that
free-runs from reset and is not aligned to the packet. On the `(SC_HITS_REQ+1)`-th
consecutive hit it sets

```
timing_ref = eval_sample_mark − (SC_HITS_REQ+1)·M + 1
```

In 0-based terms, `timing_ref − 1` is the first sample of the **first hit's `cur` window**.
A hit needs preamble in both `cur` and `del` (the M samples before it), so that window
cannot start before the preamble. **`timing_ref` is therefore never early.** The preamble
actually starts inside the previous (`del`) window.

The RTL matches its own spec formula (TRPR-SCD-005). The defect is relative to the intent:
every consumer treats `timing_ref` as "preamble start" (`planning/DSP Flow.md`, the
`psram_buf_ctrl` port comment).

At the reset `SC_THR` = 0x1CC, the hit test `(|c|²>>1) ≥ thr·E[25:13]` is roughly a
normalised correlation of 0.335. The first hit therefore needs the `del` window to be at
least 11% preamble, which gives an expected late offset of

0.89 × 0.5 + 0.11 × 1.94 ≈ **0.61 symbol** (at most ≈ 1.9) at high SNR.

At low SNR, missed hits move lock to a later run of hits, so the offset grows.

## 2. Evidence

- **Integer model** `sim/models/sc_rtl.py` (grid evaluation, `sat13` snapshots, integer
  threshold, `timing_ref` formula) against the RTL in **`cocotb/sc_timing_golden`**
  (SGE job 5810): 42 packets, SF6/SF7, BW125/BW250, two `SC_THR`/`SC_HITS_REQ`
  settings, 29 locks, **0 lock or `timing_ref` mismatches**, and every lock late.
- **Model sweep**, SF7/BW125, single Rayleigh branch, 300 packets per point:

| Per-antenna SNR | Lock | Mean late | P(> 1 sym) | P(> 2 sym) | Max |
|---|---|---|---|---|---|
| 20 dB | 99% | 0.61 sym | 0.12 | 0 | 1.6 |
| 10 dB | 95% | 0.76 | 0.26 | 0 | 1.7 |
| 0 dB | 59% | 1.07 | 0.53 | 0.02 | 4.1 |
| −5 dB | 25% | 1.53 | 0.80 | 0.12 | 5.0 |

  BW250 gives the same figures within Monte-Carlo noise. No lock was ever early.

## 3. Impact

| Consumer | Effect |
|---|---|
| `psram_buf_ctrl` replay (`buf_base`) | Replay used to start reading at `timing_ref`, so **the SX1302 received a preamble shortened by the late offset**. |
| `training_acc` window | None. Z_kl is a cross-correlation between antennas and doesn't depend on which symbols the window covers. |
| `packet_ctrl_fsm` timers | Phases shift by the same offset. They have margin. |

The SX1302's minimum preamble requirement has **not** been confirmed (not in the text of
`resources/DS_SX1302_V1.2.pdf`).

No existing test caught this. The capture replay checks (jobs 5218/5219/5227) prove the
replay is bit-exact *from* `timing_ref`, not that the preamble is complete. Nothing in
simulation decodes the replay with an SX1302.

## 4. Mitigation — `REPLAY_BACKDATE_SYMS` (0x7B)

- `reg_bank`: 0x7B[1:0], reset **1**, write-gated `!packet_active`.
- `psram_buf_ctrl`: `n·2^(sf+sample_shift)·8` bytes is snapshotted at the `sc_lock` edge
  with the other `buf_base` operands, then added to `back_bytes` in stage 2. The replay
  starts at `timing_ref − n·M`.
- The capture buffer already holds those samples. At lock the history in use is at most
  ≈ (SC_HITS_REQ+1)·M plus pipeline lag; with backdate 3 at SF12/BW125 that is still
  ≪ the 1M-sample circular buffer. The worst-case replay-entry gap becomes ≈ 3.93 MB, still
  under the formal MAXG of 4 MiB.
- `timing_ref` and the training window are unchanged.
- With n = 1, high-SNR packets start at most ≈ 1 symbol *early* (a little pre-preamble
  noise) instead of up to 1.9 symbols late.

### Verification (2026-10-03)

- **Full cocotb regression, core + capture groups (job 5811):** 59 of 62 suites passed,
  including `trouper_capture`, `capture_two_packet`, `weight_gen_spi_flow`,
  `sc_timing_golden` and `remod_golden`. The three failures:
  - `reg_bank`: a stale reserved-address list. Fixed.
  - `replay_data`: the test edge cases below. Fixed.
  - `remod_backoff`: **already failing before this change** (job 5798, stuck-run 51 > 20).
- **Re-run of the fixed suites (job 5815):** `replay_data` 5/5, `reg_bank` 39/39,
  `reg_reset_sweep` 2/2. The new `test_replay_backdate_register` asserts that
  `buf_base == wr_ptr@lock − ((iq_cnt@lock − timing_ref) + n·M)·8` exactly for n = 0 and
  n = 3, and that the replay is bit-exact from that address.
- **Formal (`psram_buf_ctrl.sby`):** `a_buf_base_matches_full_precision` now includes the
  backdate. The bounded base case passes to depth 90. Induction is **UNKNOWN**, but the
  baseline proof *without* this change is also UNKNOWN (job 5814, `a_replay_sub_bound`):
  other uncommitted PSRAM edits (#72 read-burst split, #77 `PSRAM_RD_TRIM`) broke
  inductiveness first. The last full PASS was job 5565.

**Test lessons.**
- A CW stimulus repeats exactly over whole symbols (a 2M-shifted anchor matched 32/32), so
  replay *data* checks cannot detect whole-symbol anchor errors. `buf_base` must be checked
  as an address.
- A packet that locks within n·M samples of `PSRAM_EN` backdates to before capture start.
  The first ≤ n·M replay slots then read never-written PSRAM, which is harmless
  pre-preamble junk on silicon. `replay_data` skips those slots.

## 5. Residual risk

1. **Low SNR.** A fixed backdate of 1 doesn't cover 4–5-symbol shortfalls. n = 2–3 helps,
   at the cost of more noise before the preamble and a longer replay latency. The right
   default depends on (2).
2. **SX1302 minimum preamble is unconfirmed.** Measure by replaying shortened preambles on
   the FPGA/AFE bench, or get the figure from Semtech.
3. **P&R timing is not yet measured.** Stage 2 of the `buf_base` computation gains one
   23-bit add. `buf_base` is consumed thousands of cycles later, so the arc is MCP-able,
   but it has not been through P&R.
4. **First packet after `PSRAM_EN`.** Up to n·M samples of stale or uninitialised PSRAM can
   precede the replayed preamble (≤ 3 ms after enable). Probably harmless; it is not clamped.
5. **`sim/models/sync.py:SchmidlCoxDetector` does not model the RTL.** It slides every
   sample, locks after `hits_req` hits (the RTL needs `+1`), defaults to threshold 0.9, and
   refines `timing_ref` to a noisy energy plateau. Use `sim/models/sc_rtl.py` for anything
   about RTL lock or timing.
