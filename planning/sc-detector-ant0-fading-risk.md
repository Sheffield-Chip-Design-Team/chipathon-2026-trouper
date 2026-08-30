# SC Preamble Detector — Antenna-0 Deep-Fade Single Point of Failure

**Status:** **DEFERRED** — accepted silicon limitation, not an open action item
(found 2026-06-21 via measured-IQ MIMO playback; deferred 2026-07-06, re-filed
under Open Risks §Deferred 2026-08-14). `sc_ant_sel` (`SC_ANT_SEL`, 0x1B[1:0]) is the shipped
mitigation. Re-open only on the trigger in `planning/Open Risks.md` item 9:
a signed-off floorplan with ≥ 20 k µm² spare cell area. Do not re-propose or
re-cost the correlator before then.
**Severity:** High for real multipath deployments; zero impact for line-of-sight
/ equal-power bench tests (which is why it was not caught earlier).

## Summary

Packet detection (`sc_detector` → `sc_lock`) operates on **antenna 0 only**. If
antenna 0 is in a deep fade, the gateway fails to detect the packet **even when
antennas 1–3 have strong signal**. The four-antenna front end provides *no*
diversity for the acquisition step — diversity only kicks in after lock, in MRC
training and combining. A single faded antenna therefore drops the whole packet.

## Spec vs RTL discrepancy

`planning/DSP Flow.md` Stage 5 specifies an **incoherent combine across
branches**:

```
Mag_SC     = Σ_j |c_j|²
Energy_Ref = Σ_j E_j_curr · E_j_del
Lock:  Mag_SC >= θ_SC² · Energy_Ref
```

This `Σ_j` over all four branches **is not implemented**:

- `rtl/sc_detector.v` declares only `cur_i0/cur_q0/del_i0/del_q0` (one antenna).
- `rtl/trouper_top.v` (`sc_detector u_sc`) wires only `psram_cur_i0/q0` and
  `psram_del_i0/q0` into it.
- The sums collapse to their `j=0` term — i.e. `NR=1`, channel 0 only (which the
  same Stage-5 text also states in its opening line, contradicting the formulas).

The formulas describe the *intended* diversity-combining detector; the RTL
implements a reduced single-antenna version.

## Evidence (measured-IQ playback)

`rtl-test/cocotb_trouper_capture` drives `trouper_top` with a real SF7/BW250
capture, fanned to NR=4 through independent per-antenna multipath
(`iq_capture.py`, `make_channels(model="rayleigh")`).

| Rayleigh seed | realised branch_power `[a0,a1,a2,a3]` | ant0 | result |
|---------------|----------------------------------------|------|--------|
| 7  | `[0.016, 1.39, 0.52, 0.13]` | faded ~18 dB | **no `sc_lock`** over the whole packet (`sc_stat=0`) |
| 10 | `[0.77, 0.48, 0.20, 0.03]`  | strongest    | `sc_lock` at ~3.58 ms, training + ZDIAG ranking pass |

Same capture, same SNR, same threshold — the only difference is whether the
random channel happened to fade antenna 0. (Both realisations have plenty of
total received power across the array.)

> Note: an earlier version of the test masked this because the ΣΔ stimulus
> normalised **each branch to its own peak**, artificially lifting a faded ant0
> back to full scale. The bug is only visible once a *common* scale is used
> across branches so relative per-antenna power is preserved — which is the
> physically correct stimulus.

## Why it matters

- Rayleigh deep fades of >15 dB on any single antenna are common; with 4
  independent antennas the probability that *antenna 0 specifically* is the
  faded one is ~25% per fade event. The array should make detection *more*
  robust, not gate it on one antenna.
- MRC post-lock gain is wasted if acquisition never happens.

## Mitigation options

1. **Implement the real Σ_j incoherent combine** (restores detection diversity).
   Cost: 4× the autocorrelator multiply work, or 4× TDM sub-steps in the
   existing FSM (`sc_detector` is already 108 k µm² and on the 32 MHz SS-timing
   critical path — adding TDM steps needs a timing re-check, see
   `System Architecture.md` line ~300 on the SC TDM path). This is the
   spec-faithful fix.
2. **Runtime reference-antenna selection (cheap — the data is already buffered).**
   Keep single-antenna detection but let firmware pick the SC reference branch
   (e.g. the one with the largest `Zdiag`/RSSI, regs `0x64`–`0x6B`). Contrary to
   an earlier note here, the delay buffer does **not** need redesign: PSRAM stores
   **all four channels** every sample (8 bytes: `i0,q0,i1,q1,i2,q2,i3,q3`), the
   current samples are all latched in `wr_data` (64-bit), and the delayed 8-byte
   sample for all four sits at `del_addr` — today `psram_buf_ctrl` simply reads
   back only branch 0's 2 bytes. To select channel *k*: mux `cur_ik/cur_qk` from
   `wr_data` (free) and read the delayed 2 bytes at `del_addr + 2k` (same QPI
   cost), plus a `sc_ant_sel[1:0]` register. There are ~84 spare sub-cycles in the
   128-cycle window, so even reading all 8 delayed bytes is affordable. Removes the
   fixed-ant0 dependency, no combine gain. **Caveat:** do NOT time-scan
   ("one antenna at a time / round-robin") — packets arrive asynchronously, so a
   scan can sit on the wrong antenna during the preamble and miss the packet, and
   rotating per symbol breaks SC's consecutive-same-antenna hit requirement. Use a
   *static* firmware-chosen reference per packet, or prefer option 1.

   Because reading all four delayed channels costs the same PSRAM access, option 1
   (parallel `Σ_k` combine) is barely more work than this and strictly better —
   the only reason to prefer option 2 is if `sc_detector` (already on the 32 MHz
   SS critical path) cannot absorb four parallel autocorrelators.
3. **Document-and-accept.** Mark antenna 0 as the "primary" port and require the
   installer to feed it the most reliable antenna. No silicon change; transfers
   the risk to deployment. Weakest option for a diversity gateway.

## Proposed solution (option 1, preferred) — serial 4-channel TDM correlator

**Status: designed, not implemented, DEFERRED (2026-06-21; deferred 2026-07-06).
Do not implement — blocked on the ≥ 20 k µm² area-headroom trigger in
`planning/Open Risks.md` item 9.**

Extend the existing single-multiplier TDM correlator to process all four channels
**serially** (one after the other), reusing the same multiplier rather than adding
parallel ones. This is the spec-faithful `Σ_k` incoherent combine and, crucially,
it is **timing-safe** — it does not touch the 32 MHz SS critical path.

### Why it does not worsen Fmax

The worst combinational path today is `tdm_a_r → 8×8 multiply → sign-extend →
24-bit accumulate`. Serialising 4 channels reuses that **same** path in more time
slots; it does not widen or deepen it, and adds no parallel multiplier. The only
new logic on a timing-sensitive node is a wider input mux (8:1 vs 2:1) feeding
`tdm_a_r/tdm_b_r`, but that path terminates at a flop (mux→FF, not through the
multiplier) — negligible. So the block's Fmax is unchanged; the cost is cycles
and area, not clock period.

### Cycle budget (the real constraint, and it fits)

The inner correlator runs once per `iq_valid`. HB chain R=64 → **64 clk @ 32 MHz**
between decimated samples (the old CIC-only path gave 128 — even more headroom).

| | TDM steps | of 64 clk | spare |
|---|---|---|---|
| Inner TDM now (1 ch) | 8 | ~8 | 56 |
| Inner TDM, 4-ch serial | 32 (+~2 pipeline ≈ 34) | ~34 | **~30** |

The metric/eval engine runs once per **symbol** (M·64 clk apart, ≥ 8192 clk), so
growing it from 4 steps to ~13–16 (four channels' `|c_k|²` and `E_k`, the `Σ_k`
combine, threshold) is trivially within budget.

### Area estimate (flops dominate; multiplier/adders are reused)

| Register group | now | 4-ch | added flops |
|---|---|---|---|
| Input sample regs (`cur_i/q`,`del_i/q`) | 4×8 = 32 | 16×8 = 128 | +96 |
| TDM latches (`tlat_*`) | 4×8 = 32 | 16×8 = 128 | +96 |
| Per-symbol accumulators (24-bit) | 4×24 = 96 | 16×24 = 384 | +288 |
| Eval snapshots (13-bit) | 4×13 = 52 | 16×13 = 208 | +156 |
| Channel index + `Σ_k` combine temp | — | — | ~+30 |
| **Total** | | | **≈ 666 flops** |

Does **not** grow: shared 8×8 + 13-bit multipliers, the accumulate adder (one
24-bit add reused with a 16-way write-enable decode), `eval_mag_acc`/`eval_e_acc`.

At ~24 µm²/DFF in `gf180mcu_fd_sc_mcu7t5v0` (7-track 5 V cells): ~666 × 24 ≈ 16 k
µm² of flops, + ~4–6 k µm² for the wider mux / 16-way accumulator write-decode /
combine adder → **≈ 20–23 k µm² (±30%, analytical)**. That is roughly **+20%** on
the `sc_detector` block (108 k → ~130 k µm²) and **~3%** on the 748 k µm² logic
total. Confirm with a synth-only run before committing — the floorplan is tight
(1100×1100 target).

### Implementation sketch (4 steps)

1. `sc_detector`: add a `ch[1:0]` index to the inner TDM (8→32 steps), replicate
   the per-symbol accumulators and eval snapshots ×4 (16-way write decode on the
   shared adder).
2. `sc_detector` eval: accumulate `Mag_SC = Σ_k |c_k|²` and `Energy_Ref =
   Σ_k E_k,cur·E_k,del`; keep the existing `Mag_SC ≥ θ²·Energy_Ref` lock test
   (now over the summed metric). Keep `c_i0/c_q0` (ch0) for debug, or widen if a
   per-branch readback is wanted.
3. `psram_buf_ctrl`: widen the SC delayed read from 2 bytes to the full 8
   (all four channels), ~+6 sub-cycles into S_WRITE (44 → ~50 of 128, within the
   84 spare). Add `del_i1..3/q1..3` outputs.
4. `trouper_top`: wire `cur_i1..3` (already in `wr_data`) and the new
   `del_i1..3` into `sc_detector`. Regress against the Rayleigh **seed-7**
   capture (`rtl-test/cocotb_trouper_capture`) that currently fails to lock — it
   should lock once detection sees all four antennas; seed-10 must still pass.

### Open items before implementing

- Synth-only area run to replace the ±30% estimate with a real number, checked
  against the floorplan density headroom.
- Re-confirm `sc_detector` still meets (or equally misses) the 32 MHz SS timing
  it does today — expectation is no change since Fmax is untouched, but the
  wider muxes warrant a post-synth STA check.

## Recommendation

Implement **option 1 (serial 4-channel TDM correlator)** above — it is the
spec-faithful fix, restores full detection diversity, and the timing analysis
shows it does not cost clock period, only ~20 k µm² of area. Gate the decision on
the synth-only area run vs floorplan headroom. Fall back to option 2 (static
firmware-selectable reference antenna) only if that area cannot be afforded;
option 3 (document-and-accept) only as a last resort, and if taken it must be
called out in the product/install docs.

## Pointers

- `rtl/sc_detector.v` — single-antenna port list
- `rtl/trouper_top.v` — `sc_detector u_sc` wiring (branch 0 only)
- `planning/DSP Flow.md` Stage 5 — spec formulas + implementation-gap note
- `rtl-test/cocotb_trouper_capture/` + `rtl-test/tb/test_capture_playback.py`,
  `rtl-test/tb/iq_capture.py` — reproduction (set `CAPTURE_CHAN=rayleigh
  CAPTURE_SEED=7` to trigger the failure, `=10` to pass)
