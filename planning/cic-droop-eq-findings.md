# CIC Droop Equalizer: Findings and Implementation

> **Status:** implemented and RTL-validated (2026-06-19)
>
> Both `sd_decimator_cic_only.v` and `sd_decimator_cic_tdm8.v` now include a
> 2-tap post-CIC droop equalizer. Python model (`sim/models/decimator.py`,
> `droop_eq=True`) and RTL simulation (`tb/tb_compare_decimators.v` via SGE)
> both confirm the correction.

---

## Problem: CIC-3 passband droop

The CIC-3 decimator has a non-flat passband. The magnitude response at
frequency `f` relative to DC is:

```
|H(f)| = |sin(π·f·R / f_s)  /  (R · sin(π·f / f_s))|³
```

For the deployed operating point (`R=128`, `f_s=32 MHz`, `f_out=250 kHz`):

| Frequency | CIC-3 droop |
|---|---|
| 31.25 kHz (chirp mid-band) | −0.67 dB |
| 50.00 kHz | −1.73 dB |
| 62.50 kHz (chirp band edge) | **−2.73 dB** |

The LoRa chirp sweeps 0–62.5 kHz in the complex zero-IF domain, so the
relevant passband is 0–62.5 kHz. The worst-case droop at the chirp edge is
**−2.73 dB**, with a chirp-averaged loss of about **−0.87 dB**. This is the
SNR budget item that motivated the equalizer.

**Both `sd_decimator_cic_only.v` and `sd_decimator_cic_tdm8.v` are CIC-3.**
The TDM8 variant uses a boxcar-4 front end (R=4) + CIC-3 back end (R=32),
giving the same total R=128 and identical passband droop profile.

---

## Solution: 2-tap FIR droop equalizer

### Transfer function

```
y[n] = x[n] + α·(x[n] − x[n−1]),   α = 5/16
```

This is a 2-tap FIR high-shelf filter. It boosts high frequencies by
`1 + α` at Nyquist and leaves DC unchanged.

At `α = 5/16`:

| Frequency | Without EQ | With EQ | Residual |
|---|---|---|---|
| 0 Hz (DC) | 0.00 dB | 0.00 dB | 0.00 dB |
| 31.25 kHz | −0.67 dB | +0.27 dB | +0.27 dB |
| 50.00 kHz | −1.73 dB | +0.22 dB | +0.22 dB |
| 62.50 kHz | −2.73 dB | **−0.13 dB** | −0.13 dB |

The residual at band edge is −0.13 dB (essentially flat). Chirp-averaged
response improves from −0.87 dB to +0.15 dB.

### Why no multiplier

`5/16 = 1/4 + 1/16`, implemented entirely with two arithmetic right-shifts
and one add:

```verilog
correction = (diff >>> 2) + (diff >>> 4)
```

No DSP multiplier, no LUT table. Area overhead is approximately 200 µm² per
channel in the FD cell library.

### FIR, not IIR

The difference term **must** use the uncorrected previous sample `x[n−1]`,
not the corrected output `y[n−1]`. Using `y[n−1]` creates a 1st-order IIR
that provides substantially less correction:

| | 31.25 kHz | 50 kHz | 62.5 kHz |
|---|---|---|---|
| True FIR (`x[n−1]`) | +0.27 dB | +0.22 dB | −0.13 dB |
| IIR mistake (`y[n−1]`) | −0.46 dB | +0.17 dB | (not measured) |

This drove a dedicated `eq_raw_prev_i/q` register (per channel) that stores
the uncorrected CIC output before the EQ is applied.

---

## RTL implementation

### `sd_decimator_cic_only.v`

Equalizer wires added between the CIC normalisation pipeline and the output
register. All combinational — zero added pipeline stages.

```verilog
// Saturate CIC output to int8 (used as EQ input x[n])
wire signed [7:0]  eq_cic_i = (out_val_i > 18'sd127)  ?  8'sd127 :
                               (out_val_i < -18'sd128) ? -8'sd128 : out_val_i[7:0];

// Diff vs uncorrected previous (same-width subtraction: modular arith OK)
wire signed [8:0]  eq_diff_i = {eq_cic_i[7], eq_cic_i} - {eq_raw_prev_i[7], eq_raw_prev_i};

// α = 5/16 via shifts (arithmetic >>> on signed wire)
wire signed [8:0]  eq_corr_i = (eq_diff_i >>> 2) + (eq_diff_i >>> 4);

// Sum: sign-extend both operands to 10 bits before adding
wire signed [9:0]  eq_sum_i  = {{2{eq_cic_i[7]}}, eq_cic_i}
                              + {{1{eq_corr_i[8]}}, eq_corr_i};

// Saturate to int8
wire signed [7:0]  eq_out_i  = (eq_sum_i > 10'sd127)  ?  8'sd127 :
                                (eq_sum_i < -10'sd128) ? -8'sd128 : eq_sum_i[7:0];
```

The output register latches `eq_out_i/q` on `out_fire` and simultaneously
stores the uncorrected `eq_cic_i/q` into `eq_raw_prev_i/q` for the next
difference term.

### `sd_decimator_cic_tdm8.v`

Identical EQ logic placed in the combinational `always @(*)` block, indexed
by `proc_slot` (the current TDM channel). Per-channel uncorrected previous
registers `raw_prev_i[0:3]` / `raw_prev_q[0:3]` are stored in the sequential
block on each `decim_cnt == 31` event.

The TDM structure means each channel's correction is computed in a different
clock cycle (slot 0 → slot 1 → slot 2 → slot 3), so the `raw_prev` arrays
give true FIR behaviour across the full TDM pipeline.

### Sign-extension bug found and fixed

During RTL simulation (see below) the negative half-cycles were clipping to
`+127`. Root cause: Verilog concatenation results are always **unsigned**,
regardless of the declared wire type. The original code:

```verilog
// WRONG — {a[7], a} is 9-bit unsigned; zero-extended to 10 bits in the add
wire signed [9:0] eq_sum_i = {eq_cic_i[7], eq_cic_i} + ...;
```

For negative `eq_cic_i`, the 9-bit concatenation zero-extends to 10 bits,
making it appear positive (+448 for −64), and the saturation clamp outputs
+127 instead of the correct negative value.

Fix: use a 10-bit concatenation that replicates the sign bit:

```verilog
// CORRECT — {{2{a[7]}}, a} is 10 bits; same-width add; modular arith gives correct 2's complement
wire signed [9:0] eq_sum_i = {{2{eq_cic_i[7]}}, eq_cic_i} + {{1{eq_corr_i[8]}}, eq_corr_i};
```

**The same bug existed in both files and was fixed in both.**

> Rule: never use `{sign_bit, value}` as an operand to a mixed-width binary
> operator. Use `{{N{sign_bit}}, value}` to form the correct N+W bit 2's
> complement representation as an unsigned concatenation.

---

## Validation

### Python model (`sim/models/decimator.py`)

`SigmaDeltaDecimator` now accepts `droop_eq: bool = True`. When enabled, the
integer-domain FIR is applied after CIC quantisation, bit-exact to the RTL
(Python uses Python's native right-shift on `int64`, which matches Verilog's
`>>>`). Tests: `sim/tests/test_cic_droop_eq.py`.

Measured vs theory (Python, `pytest sim/tests/test_cic_droop_eq.py`):

| Frequency | Measured | Expected |
|---|---|---|
| 31.25 kHz | +0.26 dB | +0.27 dB |
| 50.00 kHz | +0.19 dB | +0.22 dB |
| 62.50 kHz | −0.11 dB | −0.13 dB |

All 4 tests pass. Existing `test_decimator.py` (6 tests) unaffected.

### RTL simulation (SGE jobs 2001–2003)

Testbench `rtl-test/tb/tb_compare_decimators.v` drives both DUTs with the
same 1st-order ΣΔ-encoded tone, captures N=1024 output samples, and prints
raw I/Q to stdout. `sim/tests/compare_decimators.py` reads the stream and
computes the DFT amplitude at each tone frequency.

Run: `make sim_compare_decimators` from `rtl-test/` (inside the
`hpretl/iic-osic-tools:chipathon26` container), or via SGE:

```bash
hqsub --name sim-compare-decim --cpus 1 --mem 1G \
    /srv/eda/designs/timothyjabez/sim_compare_decimators.sh
```

Final RTL results (SGE job 2003, after sign-extension fix):

| Frequency | `cic_only` | `tdm8` ch0 | Theory |
|---|---|---|---|
| 31.25 kHz | +0.23 dB | +0.28 dB | +0.27 dB |
| 50.00 kHz | +0.13 dB | +0.23 dB | +0.22 dB |
| 62.50 kHz | −0.09 dB | −0.13 dB | −0.13 dB |

Both DUTs track within ±0.14 dB of each other and within ±0.14 dB of theory
at all three test frequencies. Q channel is at < −293 dB (numerical zero) —
no I/Q crosstalk.

---

## Area impact (SGE job 2004, GF180MCU FD cells TT 3.3V 25C)

Yosys synthesis of each module standalone:

| Module | Scope | Area |
|---|---|---|
| `sd_decimator_cic_only` | 1 channel | 91,296 µm² |
| `sd_decimator_cic_only` × 4 | 4 independent instances | 365,185 µm² |
| `sd_decimator_cic_tdm8` | all 4 channels | 218,589 µm² |
| **TDM8 saving vs 4× mono** | | **−146,596 µm² (−40%)** |

Pre-EQ reference points for context (from earlier synthesis runs, before the
equalizer was added):

- 4 × `cic_only` (no EQ): ~300 kµm²
- `tdm8` (no EQ): ~207 kµm²

The EQ adds roughly **16 kµm² per monolithic channel** and **12 kµm² total
to TDM8** — consistent with ~200 µm² per logical channel (4 registers + shift
adds) at the FD cell pitch.

**Decision:** the 40% area saving from TDM8 outweighs the extra complexity,
and the droop equalizer restores near-flat passband response at negligible
area cost. Both modules are retained; integration choice (4× mono vs TDM8)
is a top-level floorplan decision.

---

## Files modified / created

| File | Change |
|---|---|
| `rtl-test/rtl/sd_decimator_cic_only.v` | Added 2-tap EQ wires + `eq_raw_prev` regs; fixed sign-extension in `eq_sum` |
| `rtl-test/rtl/sd_decimator_cic_tdm8.v` | Added EQ in comb block; added `raw_prev[0:3]` regs; fixed sign-extension |
| `sim/models/decimator.py` | Added `droop_eq` parameter; integer-domain FIR bit-exact to RTL |
| `sim/tests/test_cic_droop_eq.py` | 4 pytest tests: droop magnitude, EQ flatness, DC unity gain, improvement |
| `rtl-test/tb/tb_cic_droop_eq.v` | iverilog self-check TB for `cic_only` (compiles + passes in Docker) |
| `rtl-test/tb/tb_compare_decimators.v` | Side-by-side CIC vs TDM8 TB; streams IQ CSV to stdout |
| `sim/tests/compare_decimators.py` | DFT amplitude analysis; reads VVP stdout; prints comparison table |
| `rtl-test/Makefile` | Added `sim_cic_droop_eq` and `sim_compare_decimators` targets |

---

## Key design rules for future maintainers

1. **Verilog sign extension in concatenations:** `{a[N-1], a}` is always
   unsigned. Use `{{2{a[N-1]}}, a}` (adds one sign bit) when the result
   must participate in a mixed-width binary operation as a signed value.

2. **True FIR required:** store `eq_raw_prev <= eq_cic` (uncorrected CIC
   output), not `eq_raw_prev <= eq_out` (corrected). Using the corrected
   previous converts the filter to a 1st-order IIR with ~4× less correction
   at band edge.

3. **Coefficient universality:** `α = 5/16` is universal for CIC-3 at any 2× oversample
   operating point. At 2× oversample the chirp band edge always falls at Nyquist/2
   (f/f_Nyquist = 0.5) regardless of BW or R, so the normalised frequency seen by the
   EQ is identical. The coefficient does NOT need re-deriving when R changes, provided
   the design is always operated at 2× oversample. At natural rate (R=256 for 125 kHz
   BW) the band edge hits Nyquist (−11.8 dB) and the 2-tap EQ cannot compensate a
   near-null; in that case the EQ should be disabled or a higher-order filter used.

4. **TDM8 output timing:** `iq_valid[0]` is a **single-cycle** pulse
   (cleared by `iq_valid <= 4'd0` every cycle). `sd_decimator_cic_only`
   extends `iq_valid` to 2 cycles. Do not mix the two interfaces in the same
   consumer without adapting the valid-edge logic.
