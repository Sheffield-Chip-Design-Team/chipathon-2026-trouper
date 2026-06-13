# Q0.7 Weight Interpretation Observations

Date: 2026-06-13

## Scope

This note records the outcome of the weight-format experiments in:
- `sim/notebooks/08_mrc_output_headroom.ipynb`
- `sim/notebooks/09_q07_failure_map.ipynb`

The goal was to separate two different issues:
- raw-int8 combiner clipping caused by absolute weight scale
- relative-weight quantisation error between branches

## Key distinction

The current live RTL behavior and the intended firmware behavior are different concepts:

- **Current live combiner interpretation**: the `mrc_combiner` consumes signed 8-bit weight values as raw integers.
- **Proposed fractional interpretation**: the same signed 8-bit values are interpreted as `Q0.7`, so the effective weight is `W / 128`.

This distinction dominates the results.

## Observation 1: raw-int8 weights are the real problem

Under raw integer semantics, the smallest nonzero effective weight is `1`.

That is too coarse in high-amplitude coherent cases. In the equal-branch equal-phase corner:

- 4 branches
- each branch amplitude about `90` counts
- fixed combiner guard shift `>>> 1`

Even weights `[1, 1, 1, 1]` produce a pre-saturation combiner output of:

`4 * 90 / 2 = 180`

which exceeds the int8 output limit `127`.

So with raw-int8 semantics, firmware normalization alone cannot represent the required equal nonzero weights in that corner. The problem is not MRC mathematics; it is the lack of fractional weight representation.

## Observation 2: 8-bit relative precision is already good

Representative normalized branch-ratio patterns quantized very cleanly into 8-bit mantissas.

Examples:

- `[1.00, 0.89, 0.79, 0.71] -> [127, 113, 100, 90]`
- `[1.00, 0.79, 0.63, 0.50] -> [127, 100, 80, 64]`
- `[1.00, 0.63, 0.40, 0.25] -> [127, 80, 51, 32]`

Observed ratio error was only about `0.3%` to `1.0%` in these tests.

This suggests the main issue is not branch-to-branch quantisation fidelity. The main issue is absolute scale interpretation.

## Observation 3: Q0.6 is too hot, Q0.7 is plausible, Q0.8 is conservative

A few direct format tests on coherent worst-case input:

- **Q0.6** (`W_eff = W / 64`): too aggressive; clips in several realistic cases.
- **Q0.7** (`W_eff = W / 128`): workable; preserves more output amplitude, but still relies on firmware choosing an appropriate normalization.
- **Q0.8** (`W_eff = W / 256`): conservative; naturally pushes the equal-90 corner close to the `-3 dBFS` target.

Representative `equal_90` result with full-scale equal weights `[127,127,127,127]`:

- `Q0.6`: pre-sat output about `357.2` -> clips
- `Q0.7`: pre-sat output about `178.6` -> clips
- `Q0.8`: pre-sat output about `89.3` -> safe

So `Q0.8` is safer by construction, but gives away another factor-of-2 in output amplitude.

## Observation 4: firmware-normalised Q0.7 behaved cleanly in the tested sweep

`sim/notebooks/09_q07_failure_map.ipynb` tested the optimistic-but-relevant firmware model:

1. compute matched-filter direction `conj(h)`
2. choose the best scalar normalization for that direction
3. quantize into signed 8-bit `Q0.7`
4. reject any solution that clips the combiner
5. keep the best no-clip solution

Within the tested sweep, no Q0.7 failure cases were found:

- strongest branch amplitudes: `32`, `45`, `64`, `90`
- branch spreads: `0` to `20 dB`
- coherent equal-phase corner
- random-phase Monte Carlo

Measured outcome from the reduced Monte Carlo run:

- failure probability: `0.000` everywhere tested
- mean SNR loss: essentially `0 dB`
- 95th-percentile loss: at most about `0.0001 dB`

This means the earlier raw-int8 failures do **not** carry over to `Q0.7` semantics.

## Observation 5: shared-shift / mantissa ideas solve scale, not ratio precision

An `8-bit mantissa + shared shift` approach does not materially improve branch-ratio quantisation if the mantissas remain 8-bit.

It does help with absolute scale because the effective minimum nonzero weight becomes smaller:

- no shift: minimum nonzero weight `1`
- shift 1: `0.5`
- shift 2: `0.25`
- ...
- shift 7: `1/128`

So shared-shift ideas address output headroom and clipping. They do not create new relative levels between branches.

## Current recommendation

Based on the simulations above:

1. Do **not** keep raw-int8 weight semantics if linear MRC behavior matters.
2. If multiplier width must remain `8x8`, reinterpret the existing signed 8-bit weights as a fractional format.
3. `Q0.7` looks like a strong low-area candidate when firmware normalization is active.
4. `Q0.8` is the safer-by-construction alternative if more hardware-level margin is desired.
5. The next useful simulation question is no longer "does Q0.7 fail?" but rather:
   - how small the resulting mantissas become in weakly scaled cases
   - whether `COMB_POST_GAIN_SHIFT` is needed to recover output amplitude
   - whether the recovered amplitude remains comfortably above downstream quantisation noise concerns

## Files generated during this investigation

- `sim/notebooks/08_mrc_output_headroom.ipynb`
- `sim/notebooks/09_q07_failure_map.ipynb`
- `sim/plots/mrc_output_headroom_regions.png`
- `sim/plots/mrc_output_examples.png`
- `sim/plots/q07_failure_map_coherent.png`
- `sim/plots/q07_failure_map_random_phase.png`
