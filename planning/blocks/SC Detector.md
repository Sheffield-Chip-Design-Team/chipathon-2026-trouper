# SC Detector

RX path stage 3b. Schmidl-Cox preamble detector — locks onto the LoRa preamble and provides a sample-accurate `timing_ref` to the downstream Training Accumulator and Weight Generation blocks.

**Owner:** TBD
**Status:** RTL complete, P&R clean (TT/FF timing met; SS corner −7.3 ns at 32 MHz — known GF180 3V wall)

---

## Function

Computes the Schmidl-Cox metric using a block-based correlator with `L = min(M, 256)` samples per symbol block, where `M = 2^SF` is the full symbol length. For `SF6–SF8`, `L=M`, so the detector sees the full symbol. For `SF9–SF12`, `L=256`, so the detector compares only the stored phase subset of each symbol block rather than a true full-symbol circular `M`-sample delay. The ignored phase region contributes no correlation energy; this is the documented 3–12 dB integration loss accepted to keep the buffer to one 512x8 SRAM macro.

```
|C|² = (Σ_{n in stored phase set} x*[n] · x[n−M])²
E     = Σ_{n in stored phase set} |x[n]|² · Σ_{n in stored phase set} |x[n−M]|²
lock  = |C|² > sc_thr · E  for sc_hits_req+1 consecutive symbols
```

On lock, `timing_ref` is set to the sample index of the first valid symbol boundary. `c_i0`/`c_q0` expose the final correlation phasor for diagnostic use.

---

## Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | 32 MHz system clock |
| `rst_n` | in | 1 | Active-low async reset |
| `iq_valid` | in | 1 | New sample available |
| `cur_i0/q0` | in | 8 | Current sample (antenna 0, I/Q) |
| `del_i0/q0` | in | 8 | Delayed sample from the stored phase subset of the previous symbol block |
| `delayed_valid` | in | 1 | Delay buffer has produced a valid stored-phase delayed sample; deasserted during the ignored phase region |
| `sf` | in | 4 | Spreading factor select (only SF6 special-cases M) |
| `sc_thr` | in | 16 | Threshold (firmware; see note below) |
| `sc_hits_req` | in | 2 | Number of consecutive hits required before lock |
| `sc_lock` | out | 1 | Preamble locked |
| `timing_ref` | out | 32 | Sample index of first symbol boundary |
| `c_i0/q0` | out | 32 | Final correlation phasor (diagnostic) |
| `sc_stat` | out | 16 | `sym_mag_sc[27:13]` — rolling metric magnitude (top 15 bits of 28-bit accumulator) |
| `sc_hit_dbg` | out | 1 | Pulse on each metric hit |
| `sc_hit_count_dbg` | out | 2 | Hit counter at lock time |
| `sc_first_hit_dbg` | out | 32 | Sample index of first hit |
| `sc_lock_sample_dbg` | out | 32 | Sample index at lock |

---

## Architecture

### TDM per-sample accumulator (8 steps)

At `SF9–SF12`, the accumulator is only active during the stored `L=256` phase region of each `M`-sample symbol. This is a partial-window correlator, not a full `M`-sample sliding circular correlator.

One 8×8 signed multiplier shared across all per-sample products.  Each sample
triggers an 8-step TDM FSM:

| Steps | Computation | Destination |
|-------|------------|-------------|
| 0, 1 | `ci0·di0`, `qi0·dq0` | `acc_ci0` (re corr) |
| 2, 3 | `qi0·di0`, `ci0·dq0` | `acc_cq0` (im corr) |
| 4, 5 | `ci0²`, `qi0²` | `acc_E0cur` |
| 6, 7 | `di0²`, `dq0²` | `acc_E0del` |

Accumulators are 24-bit signed (max value ≈ 8.3 M = 23 bits; 8-bit sign extension of 16-bit products).

### Per-symbol metric evaluation (4 steps)

Single `signed_mul24_pipe` (13-bit × 13-bit, 2-stage pipeline, 3-cycle latency).
Inputs are right-shifted by 10 from the 24-bit accumulators (`acc[22:10]`).

| Step | Computation | Destination |
|------|------------|-------------|
| 0 | `ci0_e²` | `eval_mag_acc` |
| 1 | `cq0_e²` | `eval_mag_acc` |
| 2 | `E0cur_e × E0del_e` | `eval_e_acc` |
| 3 | `sc_thr[12:0] × e_acc[25:13]` | threshold compare |

`eval_hit` is set when `e_acc > 0 && mag_acc[47:1] ≥ eval_prod`.

### sc_thr calibration note

The threshold comparison uses `sc_thr[12:0]` (lower 13 bits only; upper 3 bits ignored).  The eval inputs are right-shifted by 10 (not 6 as in the pre-reduction RTL), so the effective scale factor is `k = 1/1024`.  Both sides of the comparison scale as k², so the ratio — and thus the detection threshold — is invariant, but firmware must set `sc_thr` in the 0–8191 range (not 0–65535).

---

## Area history

All figures: Yosys synthesis, `gf180mcu_fd_sc_mcu7t5v0` TT/25°C/3.3 V.

| Version | Yosys area | Change | Notes |
|---------|-----------|--------|-------|
| Original (16 parallel multipliers) | 561 k µm² | — | Baseline |
| Round 1: 1 shared TDM multiplier, 16 steps | 193 k µm² | −368 k | SGE job 1108 |
| Round 2: NR=1 + 24-bit acc + 13-bit eval | **164 k µm²** | **−29 k** | SGE job 1138 |

### Round 2 breakdown (2026-06-01)

Three changes applied together:

**A — Single-channel SC detection (−50 k estimated, ~−20 k actual)**
- Removed ch1 inputs, ch1 accumulators, ch1 TDM steps 4–7 and 12–15
- TDM steps: 16 → 8; eval steps: 7 → 4
- `training_acc` does independent 4-channel accumulation; sc_detector ch1 was not load-bearing for MIMO combining

**B — Accumulator width 32 → 24 bit**
- `acc_ci0/cq0/E0cur/E0del` narrowed; max value is 23 bits so 32-bit had 8 bits of headroom
- Sign extension in TDM: `{{8{mul[15]}}, mul}` (was 16-bit extension)
- `c_i0/q0` outputs kept 32-bit with sign extension from 24-bit sym snapshot

**C — Eval multiplier 17 → 13 bit**
- `signed_mul24_pipe` ports: `[16:0]` → `[12:0]`, output `[33:0]` → `[25:0]`
- Snapshot shift: `acc[22:10]` (was `[22:6]`)
- 13-bit gives ~78 dB SNR on metric; channel estimation noise dominates well before that

---

## P&R results (Round 2, job 1138)

| Metric | Value |
|--------|-------|
| Yosys synthesis area | 164 k µm² |
| Post-PNR stdcell area | 261 k µm² |
| DRC errors | 0 |
| Lint errors | 0 |
| TT 25°C WNS | 0 ns (clean) |
| FF −40°C WNS | 0 ns (clean) |
| SS 125°C WNS | −7.3 ns |
| Die bbox | 1058 × 1076 µm |

SS corner fails at 32 MHz — consistent with the GF180 3V SS wall seen on other blocks. No regressions vs previous run.

---

## Related blocks

- [Training Accumulator](Training%20Accumulator.md) — consumes `timing_ref` and `sc_lock`
- [ALMMSE-MRC Combiner](ALMMSE-MRC%20Combiner.md)
