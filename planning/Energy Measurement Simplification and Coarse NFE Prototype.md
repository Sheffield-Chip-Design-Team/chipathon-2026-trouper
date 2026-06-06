# Energy Measurement Simplification and Coarse NFE Prototype

## Goal

Capture the current architectural thinking around energy measurement, AGC, and software NW-MRC, then turn that into a first RTL prototype that simplifies the **noise-estimate** path without perturbing the **AGC** path.

This note is intentionally pragmatic. It records what we now believe is required, what looks overbuilt, and what the first RTL experiment should do.

---

## Current conclusions

### 1. Hardware MRC does not need energy-based normalization

The current non-FFT hardware path uses:

- `Z_j >>> sf`
- static calibration
- shared peak/headroom backoff

It does **not** use `energy_sum` or `E_ref` to normalize the hardware MRC weights.

Implication:

- Energy Measurement is no longer on the critical hardware combining path.

### 2. NW-MRC stays in software

The current plan is to keep noise-weighted combining in firmware/software.

Implication:

- the noise estimate does not need to be a precise, low-latency hardware operand
- it mainly needs to be stable and preserve branch-to-branch ordering
- absolute scale is secondary

### 3. AGC and noise estimation have different needs

AGC:

- packet-to-packet only
- 2 dB BB gain granularity
- coarse LNA steps
- mainly needs a stable monotonic energy metric

Software NW:

- needs per-branch relative noise information
- benefits from smoothing
- likely does not need raw 32-bit `energy_sum`

Implication:

- a single full-precision raw-energy interface is probably more than either consumer needs
- but AGC and software NW do not need exactly the same representation

### 4. The current raw-energy interface is wider than the downstream use

Today:

- `energy_meas` accumulates full 28-bit per-window energy
- exports `energy_sum_[0..3]` as 4x32-bit zero-extended registers
- `noise_floor_est` immediately reduces this to `energy_sum >> sf`

So the current NFE path is paying for:

- wide registered outputs
- wide top-level routing
- wide NFE input ports

only to discard most of that width at the first operation.

### 5. Most simplification room is on the noise-estimate path, not the AGC path

The cleanest first cut is:

- keep `ENERGY[0..3]` semantics for AGC/status unchanged
- simplify only the path feeding noise estimation

This avoids immediate churn in firmware AGC thresholds and register-map expectations.

---

## Area observations

Standalone synthesis of the current `energy_meas` block showed:

- area around `63k` in fd library synthesis
- almost half sequential area

The key takeaway is:

- sharing or removing multipliers alone will not collapse the block area
- output/state width matters

The wide `energy_sum_[0..3]` registers are a plausible simplification target because:

- AGC does not read them
- only NFE consumes them
- NFE only uses a normalized version

---

## Precision view

### AGC precision

AGC likely does not need anything close to full raw energy precision.

Reason:

- BB gain is 2 dB/step
- LNA gain is much coarser
- packet-to-packet decisions only need threshold stability, not exact power metrology

### Software NW precision

For software NW-MRC, the estimate should be:

- per-branch
- smoothed
- reasonably monotonic

Likely acceptable target:

- around `10 bits` useful precision

`12 bits` would be more conservative, but `10 bits` is a credible first simplification target.

---

## Prototype choice

The first RTL prototype should not rewrite the current shipping path in place.

Instead, create an **experimental coarse noise-estimation path**:

1. Keep AGC-facing `energy_[0..3]` unchanged.
2. Replace raw-sum NFE input with a normalized coarse metric.
3. Keep NW-MRC software-only.
4. Leave the existing legacy `energy_meas.v` and `noise_floor_est.v` available until the coarse path is validated.

This gives a low-risk comparison point.

---

## Proposed coarse metric

Start from the same physical statistic:

```text
eps_full_j = (sum |x_j|^2 over one symbol) >> sf
```

This is the per-sample branch energy.

For 8-bit signed I/Q:

```text
max eps_full = 127^2 + 127^2 = 32258
```

That is a 15-bit quantity.

To compress it to about 10 useful bits:

```text
noise_metric_j = sat_u10(eps_full_j >> 5)
```

This maps:

- full scale `32258` -> `1008`
- branch-noise ratios are preserved up to quantization
- the metric fits cleanly in 10 bits

This is the proposed prototype metric.

---

## Proposed prototype blocks

### `energy_meas_coarse`

Responsibilities:

- keep the current per-window `sum |x|^2` accumulation
- keep the 16-bit AGC/status snapshot output
- add a normalized 10-bit `noise_metric_[0..3]`
- assert `noise_metric_valid` at end-of-window

Notes:

- This still uses the existing TDM squarer architecture.
- It does not yet attempt SC multiplier reuse.
- It is a representation simplification first, not a datapath fusion exercise.

### `noise_floor_est_coarse`

Responsibilities:

- consume `noise_metric_[0..3]` directly
- remove `sf` dependence from NFE
- keep the existing EMA structure and SW override pattern

Key width change:

- current NFE accumulator: `23 bits` (`16 + 7`)
- coarse NFE accumulator: `17 bits` (`10 + 7`)

This is the first concrete RTL area reduction in the noise-estimate path.

---

## Why this prototype is a good first step

It preserves what matters:

- AGC still sees the legacy-style 16-bit energy snapshot
- software still gets per-branch `sigma2_hw`
- the control model stays the same

It simplifies what looks overbuilt:

- NFE no longer needs 4x32-bit raw energy inputs
- NFE no longer needs runtime `sf` shifting
- internal EMA state shrinks

It avoids unnecessary coupling:

- no SC/correlator micro-schedule merge yet
- no immediate top-level migration risk
- no firmware algorithm change beyond readout scaling for the experimental path

---

## Open questions

### 1. Should AGC eventually move to a coarser exported metric too?

Probably yes, but not in the first prototype.

The first prototype isolates the noise-estimate simplification from AGC threshold retuning.

### 2. Should the coarse noise metric be 10 bits or 12 bits?

Current recommendation:

- prototype `10 bits`
- keep `12 bits` as the fallback if branch-ranking jitter is worse than expected

### 3. Should the legacy `energy_sum` path be removed entirely?

Not yet.

First validate that:

- the coarse metric behaves sensibly in simulation
- the software NW path can use the reduced dynamic range

Then remove the legacy path from the integrated top-level.

---

## Prototype scope

For this iteration:

- add experimental coarse RTL modules
- do not replace the current integrated top-level path yet
- document the intended migration

That keeps the prototype useful without creating unnecessary integration churn.
