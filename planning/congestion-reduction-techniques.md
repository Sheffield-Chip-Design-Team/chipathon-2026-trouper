# Routing Congestion Reduction Techniques

Collected during `ol_trouper_top` die-shrink investigation (June 2026).
Applies to `gf180mcu_fd_sc_mcu7t5v0` / LibreLane / `hpretl/iic-osic-tools:chipathon26`.

---

## Background

`ol_trouper_top` routes cleanly at 35–60% utilisation on a 1300×1300 µm die
(see `rtl-test/librelane_gf180mcu_pnr_notes.md`).  Cell area with taps/endcaps
is ~982K µm², giving ~60% actual utilisation on that die.  Attempts to shrink
to 1200×1200 or smaller require utilisation above 70%, where routing congestion
and placement padding overhead become limiting factors.

The techniques below are ordered by estimated impact.

---

## 1. Clock gating — RTL level (highest impact)

### Why it helps routing

Clock gating reduces switching activity, which is a secondary benefit.
The primary routing benefit is **cell count reduction**: when Yosys infers an
ICG (integrated clock gate) cell it replaces a register's clock enable logic
with a single gate, collapsing what would otherwise be a wide enable mux tree
into one cell and one wire.  Fewer cells → lower utilisation → less congestion.

### Opportunities in this design

#### `training_acc.v` — multiplier pipeline (biggest win)

The 8×8 multiplier operand registers and product register run **every clock
cycle** but are only consumed when `tdm_active` is high — 32 cycles out of
every 64 (50% duty cycle at R=64):

```verilog
// Current — unconditional:
always @(posedge clk) begin
    op_a    <= ...;
    op_b    <= ...;
    mul_out <= op_a * op_b;
end
```

Adding a gate:

```verilog
// Gated — Yosys infers ICG around op_a, op_b, mul_out:
always @(posedge clk) begin
    if (tdm_active) begin
        op_a    <= ...;
        op_b    <= ...;
        mul_out <= op_a * op_b;
    end
end
```

Estimated savings: ~75% switching reduction on the multiplier + feed muxes.

#### `training_acc.v` — accumulator output registers

The 12 × 32-bit `Zpair_*` and 4 × 32-bit `Zdiag_*` registers (640 flip-flops)
write only when `acc_active` is high (same 25% duty cycle).  The accumulate
block already has `if (acc_active)` guards on the write paths, so Yosys should
already infer ICG here if `SYNTH_CLOCK_GATING: true` is set.  Verify by
checking the post-synthesis cell report for `CLKGATE` instances.

#### `sc_detector.v` — `signed_mul24_pipe`

The 13×13 pipelined multiplier inside `sc_detector` runs unconditionally.
It is only meaningful when the TDM FSM is active (triggered by `iq_valid_r`,
every 128 cycles).  Adding `if (tdm_active)` around the pipeline registers
gives the same benefit as above.

### Synthesis-level clock gating

LibreLane exposes:

```json
"SYNTH_CLOCK_GATING": true
```

This enables the Yosys `-clockgate` pass, which scans for `if (en) reg <= ...`
patterns and replaces them with ICG cells.  It requires that the PDK Liberty
file contains a cell matching the `CLKGATE` pattern (GF180MCU FD library does).
**This is a prerequisite for the RTL-level changes above to take full effect
at the gate level.**

---

## 2. Fanout reduction

High-fanout nets force the router to spread buffers across the die, creating
long wires and congestion hotspots.  The `DRT-0120` warnings seen during
`ol_trouper_top` DRT identified two nets with 120–138 pins:

```
[DRT-0120] Large net net374 has 120 pins — may impact routing performance
[DRT-0120] Large net net375 has 138 pins — may impact routing performance
```

**Config lever:** reduce `MAX_FANOUT_CONSTRAINT` from the current 8 to 4–6.
This causes Yosys to insert more explicit buffer trees during synthesis,
distributing high-fanout nets into shorter, more local connections before
placement begins.

```json
"MAX_FANOUT_CONSTRAINT": 4
```

Lower fanout → shorter average net length → lower routing congestion.
Tradeoff: slightly more cells, so monitor that utilisation stays within bounds.

**RTL lever:** if `net374`/`net375` are identified as wide buses (e.g. a
broadcast clock-enable or reset), pipelining the enable with a register stage
per cluster of sinks removes the long-range wire entirely.

---

## 3. Post-GPL design repair

```json
"RUN_POST_GPL_DESIGN_REPAIR": true
```

Currently disabled.  When enabled, OpenROAD runs a resizer pass after global
placement to break up any remaining high-fanout nets before detailed placement.
This is the placement-stage equivalent of fanout reduction and can improve
routability without changing RTL or synthesis.

Tradeoff: adds buffers, raising cell count slightly.  At high utilisation this
can cause DPL-0036; set in conjunction with a slightly looser density target.

---

## 4. DPL_CELL_PADDING and the density–padding tradeoff

`DPL_CELL_PADDING=4` (2 sites each side, 1.12 µm) is required to prevent
DRT-0073 on GF180MCU FD cells (see `rtl-test/librelane_gf180mcu_pnr_notes.md`).
At utilisation above ~65% the padding overhead causes DPL-0036.

`DPL_CELL_PADDING=2` (1 site each side, 0.56 µm) halves the overhead and may
be sufficient to prevent DRT-0073 — this is under test.

| Padding | Overhead | Max safe util (DPL step 33) | DRT-0073 risk |
|---------|----------|----------------------------|---------------|
| 0 | none | any | **certain** |
| 2 | low | ~75% | **none** (confirmed, job 1613) |
| 4 | moderate | ~65% | none (confirmed on 1300×1300) |

**Confirmed (June 2026):** `DPL_CELL_PADDING=2` is sufficient to prevent
DRT-0073 on GF180MCU FD cells.  1200×1200 µm at 75% density, padding=2 passed
cleanly (job 1613, post-PNR SS WNS = 0.0 ns).

Post-CTS DPL-0036 (step 34) is a separate failure mode — the hold-buffer
resizer overflows at very high density (≥80% on 1150×1150).  This is distinct
from the initial placement failure (step 33) and is resolved by lowering density.

---

## 5. Summary — recommended sequence for die shrink

1. Enable `SYNTH_CLOCK_GATING: true` in config.
2. Add `if (tdm_active)` guard to `training_acc` multiplier pipeline.
3. Drop `MAX_FANOUT_CONSTRAINT` to 4.
4. Enable `RUN_POST_GPL_DESIGN_REPAIR: true`.
5. Re-run density sweep on 1200×1200 with `DPL_CELL_PADDING=4`.
   - If still failing DPL-0036 at 65%+, try `DPL_CELL_PADDING=2`.
6. If routing passes, run a timing check — clock gating changes the critical
   path slightly; verify SS WNS is still ≥ 0 with MCP.

---

## Reference

- `rtl-test/librelane_gf180mcu_pnr_notes.md` — DRT-0073 root cause, DPL-0036 fix, density sweep results
- `planning/Physical Design Change List.md` — full P&R trial history
- `planning/die-area-analysis.md` — die area budget analysis
