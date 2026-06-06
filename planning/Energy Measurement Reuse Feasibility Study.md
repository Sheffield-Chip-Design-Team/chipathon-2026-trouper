# Energy Measurement Reuse Feasibility Study

## Question

Can the current `energy_meas` function be implemented by reusing arithmetic already present in the Schmidl-Cox detector / correlator path, rather than keeping `energy_meas` as a separate block?

The specific reuse idea evaluated here is:

- reuse the SC detector's existing multiplier infrastructure
- schedule energy measurement work onto that datapath when it is not needed for SC correlation
- keep the current architectural behavior of `energy_meas` unchanged (`ENERGY[0..3]`, `energy_sum[0..3]`, lock snapshot, NFE input)

## Short answer

Yes, this is feasible.

The most credible reuse path is to fold `energy_meas` into `sc_detector` and time-multiplex the existing per-sample `8x8` multiplier.

However:

- this only reuses the multiply/square engine and some local control
- it does not remove the need for separate per-branch energy accumulators, snapshot registers, and status outputs
- therefore the likely area win is moderate, not transformational

## Current implementation snapshot

### `energy_meas`

Current RTL: [rtl-test/energy_meas.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/energy_meas.v)

Current structure:

- one shared `8x8` squarer
- 9-step TDM sequence per `iq_valid`
- computes all four branches:
  - `i0^2 + q0^2`
  - `i1^2 + q1^2`
  - `i2^2 + q2^2`
  - `i3^2 + q3^2`
- 4 independent accumulators (`acc_0..acc_3`)
- per-window outputs:
  - `energy_sum_[0..3]` = 32-bit zero-extended sums
  - `energy_[0..3]` = 16-bit saturated snapshot values
- `sc_lock` snapshot path for AGC / status

Standalone synthesis against `gf180mcu_fd_sc_mcu7t5v0` gives:

- area: `63,140.54`
- cells: `2,277`
- sequential area: `30,153.27` (`47.76%`)

There is also a hierarchical `mimo_rx_top` synthesis report in [rtl-test/syn_mimo_per_module/README.md](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/syn_mimo_per_module/README.md) showing:

- `energy_meas`: `98,040 um^2`
- `3.9%` of the as_sc top-level standard-cell area

### `sc_detector`

Current RTL: [rtl-test/sc_detector.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/sc_detector.v)

Important facts:

- single-antenna SC detector (`NR=1`, antenna 0 only)
- has a shared per-sample `8x8` multiplier with an 8-step TDM schedule
- has a separate pipelined `13x13` multiplier (`signed_mul24_pipe`) for end-of-symbol metric evaluation

Per-sample `8x8` TDM work in SC:

1. `cur_i0 * del_i0`
2. `cur_q0 * del_q0`
3. `cur_q0 * del_i0`
4. `cur_i0 * del_q0`
5. `cur_i0^2`
6. `cur_q0^2`
7. `del_i0^2`
8. `del_q0^2`

So SC already computes:

- correlation terms for `C`
- current-window energy for branch 0
- delayed-window energy for branch 0

This is strong evidence that arithmetic reuse is structurally possible.

## Feasibility of multiplier reuse

## Reuse target 1: SC `8x8` per-sample multiplier

This is the best reuse target.

Reason:

- `energy_meas` also needs only `8x8` square operations
- both blocks run at the same sample cadence (`iq_valid` in the decimated domain)
- both are naturally expressed as micro-scheduled TDM datapaths

A merged schedule could be:

- SC work: 8 cycles per valid sample
- energy work: 8 square operations for 4 branches, plus control / commit cycle(s)
- total: about 17 cycles per valid sample, very close to the current `energy_meas` 9-step style

At the fastest supported output rate:

- decimator output = `1 MHz`
- core clock = `32 MHz`
- available budget = `32 cycles / sample`

Therefore:

- `8 (SC) + 9 (energy)` = `17 cycles / sample`
- this fits within the worst-case `32-cycle` budget
- lower bandwidth modes only increase the slack

Conclusion:

- sharing the SC `8x8` multiplier with energy measurement is timing-feasible at the current 32 MHz clock

## Reuse target 2: SC `13x13` metric multiplier

This is not the right reuse target for `energy_meas`.

Reason:

- it is used only for end-of-symbol metric evaluation
- `energy_meas` needs per-sample `8x8` squares, not per-symbol `13x13` products
- retargeting the `13x13` path to do four-branch energy work would add width conversion and scheduling complexity without removing the need for the `8x8` stream datapath

Conclusion:

- do not plan around reusing `signed_mul24_pipe` for energy measurement
- the useful reuse point is the SC `8x8` multiplier, not the metric engine

## What reuse does and does not remove

### What can be shared

A merged SC + energy implementation can reasonably share:

- the per-sample `8x8` multiplier datapath
- some TDM scheduling / step control
- `iq_valid`-domain sample latching
- `sc_lock` snapshot timing
- symbol-window counters, if the window definitions are made consistent

### What still has to exist

Even with multiplier reuse, the following energy-specific state still has to remain:

- 4 per-branch accumulators for `sum |x|^2`
- 4 `energy_sum` outputs (or equivalent internal state if the external interface changes)
- 4 snapshot registers for `ENERGY[0..3]`
- saturation / zero-extension logic
- per-window valid generation for NFE / telemetry

This matters because the standalone synthesis shows that `energy_meas` is not dominated only by arithmetic. A large fraction of its area is sequential state.

Conclusion:

- multiplier reuse helps
- but it will not eliminate most of `energy_meas`
- area savings are likely modest unless the merged implementation also collapses duplicated latches, counters, and output registers

## Architectural mismatches to resolve

There are several non-trivial mismatches between the current blocks.

### 1. Antenna coverage mismatch

Current SC RTL is `NR=1`.

Current energy measurement is `NR=4`.

Implication:

- SC arithmetic currently only sees antenna 0
- energy measurement requires all four branches every sample

So a merged design must still carry all four branches through the energy side of the datapath, even if SC remains single-antenna.

This does not block reuse, but it means reuse is only partial.

### 2. Input-source mismatch

Current top-level wiring in [rtl-test/mimo_rx_top.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/mimo_rx_top.v):

- `sc_detector` consumes `cur_i/q` and `del_i/q` from the frontend buffer / SC path
- `energy_meas` consumes `dcr_i/q[0..3]` directly from the DC-removed live stream

Implication:

- the merged block must still have access to the full four-branch DC-removed live samples
- reusing the SC multiplier does not imply reusing the SC sample source as-is

### 3. Window-definition mismatch

Current docs describe energy measurement as per-symbol `sum |x|^2` over a single symbol window.

Current SC energy terms are:

- `E0cur`: current symbol-sized window on branch 0
- `E0del`: delayed symbol-sized window on branch 0

Implication:

- branch-0 energy can align naturally with SC internals
- branches 1..3 still need their own accumulation passes

## Implementation options

## Option A: Keep `energy_meas` separate

Pros:

- lowest design risk
- easiest to verify
- current behavior preserved exactly
- no coupling between AGC / NFE support and SC detector timing

Cons:

- no reuse benefit
- preserves a ~63k to ~98k area block depending on library / synthesis mode

Assessment:

- safest baseline

## Option B: Fold `energy_meas` into `sc_detector`, share only the `8x8` multiplier

Pros:

- technically feasible within cycle budget
- removes one standalone arithmetic datapath
- allows some control and latching reuse

Cons:

- still requires most of the energy-specific register state
- SC block becomes more complex
- verification burden rises because AGC / NFE observability is now entangled with SC micro-scheduling
- branch 1..3 support remains energy-only, not SC-shared

Assessment:

- best compromise if modest area savings are worth moderate RTL complexity

## Option C: Attempt deeper fusion of SC and energy state

Pros:

- largest possible area reduction if counters, sample staging, and outputs are all rationalized together

Cons:

- highest risk
- likely to perturb SC timing behavior and debug visibility
- requires a more substantial redesign than simple multiplier reuse

Assessment:

- not recommended as a first optimization step


## Concrete merged micro-schedule

A low-risk merged design would keep the current SC detector behavior intact and append energy work onto the same per-sample `8x8` multiply engine.

One plausible schedule per `iq_valid` sample is:

| Cycle group | Operation | Notes |
|---|---|---|
| 0..7 | Current SC TDM sequence | Existing `sc_detector` work for branch-0 correlation and branch-0 current/delayed energies |
| 8..15 | Energy squares for branches 0..3 | `i0^2`, `q0^2`, `i1^2`, `q1^2`, `i2^2`, `q2^2`, `i3^2`, `q3^2` |
| 16 | Commit / accumulator update / window-end handling | Equivalent to current `energy_meas` finalization cycle |

Total worst-case budget:

- current SC per-sample work: `8` cycles
- energy measurement work: `9` cycles
- merged total: `17` cycles / sample

This still fits inside the worst-case decimated sample budget:

- `32 MHz` fabric clock
- `1 MHz` output sample rate
- `32 cycles / sample` available

So there is substantial timing slack even before any schedule tuning.

## Register inventory and likely savings

A rough persistent-state inventory from the current RTL gives:

- `energy_meas`: about `428` bits of state
- `sc_detector`: about `771` bits of state

Approximate `energy_meas` state breakdown:

| State group | Bits |
|---|---:|
| `energy_sum_[0..3]` outputs | 128 |
| `energy_[0..3]` snapshot outputs | 64 |
| 4 branch accumulators | 112 |
| latched 4-branch I/Q inputs | 64 |
| squarer pipeline / temp state (`sq_in`, `sq_out_r`, `i_sq_r`) | 40 |
| counter / FSM / valid state | 20 |
|
| **Total** | **428** |

This is the key reason the reuse win is bounded.

Even in a merged block, the following almost certainly remain mandatory:

- `energy_sum_[0..3]` or equivalent storage: `128` bits
- `ENERGY[0..3]` snapshot registers: `64` bits
- 4 branch accumulators: `112` bits

That is already `304` bits, before any local control or input staging.

The state most plausibly removed by merging is only the smaller tail:

- duplicated sample latches
- local TDM step / busy state
- local counter / window-end flags
- local multiplier pipeline registers

So the likely outcome is:

- arithmetic datapath sharing: real
- control/state sharing: partial
- mandatory energy-specific storage remains dominant

## Additional constraint discovered from the RTL

There is an important window-length mismatch between the current SC and energy implementations.

Current `sc_detector` behavior:

- `SF6`: `M_val = 64`
- `SF7`: `M_val = 128`
- `SF8` to `SF12`: `M_val = 256`

Current `energy_meas` behavior:

- window length is the full `2^SF` sample count for `SF7..SF12`
- internal counter supports up to `4096` samples

Implication:

- a merged design can share the sample-rate multiply engine cleanly
- but it cannot naively share the exact same symbol-window counter/state for `SF9..SF12`
- preserving the current `energy_meas` behavior would still require an energy-specific long-window counter, or a redesign of the SC detector windowing

This further reduces the likely area savings from a simple merge.

## Refined conclusion

A merged SC + energy design is still feasible, but the expected savings should be revised downward.

What is realistically saved:

- one standalone `8x8` square / multiply engine
- some local step-control and latching
- some glue around `sc_lock` snapshot timing

What is not realistically saved without deeper architectural change:

- 4-branch energy accumulators
- exported energy / snapshot registers
- long energy window tracking for `SF9..SF12`
- most of the NFE-facing storage semantics

So the practical recommendation is:

- pursue this only if you want a moderate area cleanup and are comfortable increasing SC block complexity
- do not expect the full `energy_meas` block area to disappear
- if area pressure is severe, larger wins still lie elsewhere than this optimization alone

## Recommended conclusion

The reuse idea is feasible and defensible, but only in a constrained form.

Recommended position:

1. If the goal is a low-risk cleanup, keep `energy_meas` separate.
2. If the goal is a moderate area reduction, merge `energy_meas` into `sc_detector` by sharing the existing per-sample `8x8` multiplier and associated sample/window control.
3. Do not try to reuse the SC metric (`13x13`) multiplier for this purpose.
4. Do not expect a transformational area drop, because much of `energy_meas` area is in accumulators, snapshots, and output state that must still exist.

In other words:

- arithmetic reuse: yes
- full block elimination via reuse: no
- likely value: moderate, not game-changing

## Practical next step

If this optimization is worth pursuing, the next concrete step should be a micro-architecture sketch for a merged `sc_detector + energy_meas` block with:

- one shared `8x8` multiplier
- a combined step schedule proving `<= 32` cycles / sample at `1 MHz`
- explicit state list showing which registers are shared vs preserved
- a before/after synthesis comparison

That would let us answer the only remaining open question: whether the area saved is large enough to justify the extra coupling and verification work.
