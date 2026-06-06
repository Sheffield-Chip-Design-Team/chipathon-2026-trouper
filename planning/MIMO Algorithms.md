# MIMO Algorithms Study

Study note for comparing alternative MIMO combining and separation algorithms against the current `NT=1 MRC` and `NT=2 ALMMSE` design.

This is intended as an assignment handoff. The goal is not to change RTL immediately. The goal is to decide which algorithms are worth carrying forward into the simulation model, hardware plan, and verification matrix.

This is a software-first workstream: simulation, algorithm selection, and firmware-feasible control policy should be treated as a separate owner from the RTL block implementation.

## Simulation Ladder

The software and verification workstream should progress in three stages:

1. **Python system simulation**
   - build and exercise the behavioral model first
   - select algorithms, thresholds, and fallback rules
   - validate SC sensitivity, AGC policy, MRC/SC/EGC comparisons, and `NT=2` extension assumptions

2. **End-to-end RTL verification**
   - compare RTL against the Python reference at the packet and block level
   - verify register behavior, capture handoff, AHB-Lite transactions, `W` commit timing, and fixed-point loss

3. **In-the-loop simulation**
   - run real firmware and control flow against RTL or hardware
   - verify AGC convergence, IRQ handling, branch masking, packet handoff, and full RX-to-remod behavior

This ladder is the intended route from algorithm exploration to hardware confidence.

---

## Objective

Evaluate practical alternatives to the current MIMO algorithms under the actual constraints of this project:

- `NR=4` receive antennas
- `NT=1` or `NT=2` transmit streams
- channel estimate derived once per packet from the preamble
- no mid-packet switching
- live stream must fall back cleanly to bypass if current-packet W is not ready
- weight computation must remain feasible on PicoRV32 RV32IM
- output is still LoRa baseband for SX1302 demodulation

The point is to compare algorithms that are realistic for this architecture, not to survey generic MIMO literature.

---

## Current Baseline

### `NT=1`

Current baseline is MRC:

```text
y[n] = w^H x[n]
```

using the preamble-derived channel estimate `H` and per-antenna `N0`.

### `NT=2`

Current baseline is ALMMSE:

```text
W = H^H (H H^H + sigma^2 I)^-1
y[n] = W x[n]
```

with `H` estimated from the preamble and `W` written by PicoRV32 into the combiner shadow register bank.

Current architectural conclusion:

- `NT=2` remains a future extension, not the primary product path
- the most realistic candidate is simultaneous transmission with payload separation driven mainly by spatial processing
- a small `delta_f` may still be useful as an identification or channel-estimation aid
- that `delta_f` should be treated only as a helper, not the main separation mechanism
- if `delta_f` becomes large enough to separate users easily, it risks channel-occupancy and compatibility problems

So the intended `NT=2` direction is:

```text
small delta_f for identification / estimation aid
+ spatial MMSE-style separation for the actual payload
```

not:

```text
large delta_f as the primary separator
```

---

## Candidate Algorithms

The useful comparison set is different for `NT=1` and `NT=2`.

### `NT=1` candidates

#### 1. Selection Combining (SC)

Choose the single best antenna for the packet.

Typical score choices:

```text
j* = argmax |h_j|^2 / N0_j
```

and then:

```text
y[n] = x_j*[n]
```

Why it matters:

- cheapest possible diversity combiner
- robust when channel estimates are noisy
- likely to beat badly estimated MRC in some low-SNR cases
- good baseline against current bypass mode

#### 2. Equal-Gain Combining (EGC)

Use phase alignment only, with equal magnitudes:

```text
w_j = exp(-j angle(h_j))
```

Why it matters:

- less sensitive than MRC to amplitude-estimation error
- still captures most coherent combining gain when phase estimates are decent
- likely interesting at low SNR, especially where `|H|` is noisy but phase is still usable

#### 3. Maximum Ratio Combining (MRC)

Keep as baseline and likely preferred implementation for `NT=1`.

Reason:

- best linear combiner when the single-stream channel estimate is good
- already fits the architecture

### `NT=2` candidates

#### 1. Matched Filter / Per-user MRC

Use:

```text
W = H^H
```

Why it matters:

- simplest two-user linear front end
- useful as a lower-complexity reference
- expected to be weak when the two users are not well separated spatially

#### 2. Zero Forcing (ZF)

Use:

```text
W = (H^H H)^-1 H^H
```

Why it matters:

- direct interference nulling baseline
- shows how much MMSE gain comes from regularization rather than nulling alone
- expected to degrade badly for ill-conditioned `H` or low SNR

#### 3. MMSE / ALMMSE

Keep as baseline and likely preferred implementation for `NT=2`.

Reason:

- balances interference suppression and noise enhancement
- much more robust than ZF when `H` is poorly conditioned
- already aligned with the current architecture and firmware plan

#### 4. MMSE-SIC or ZF-SIC

Successive interference cancellation:

1. detect stronger user
2. reconstruct and subtract it
3. detect the weaker user

Why it matters:

- may outperform linear MMSE when user powers are unequal
- useful as an upper-end simulation experiment

Why it is risky:

- subtraction error depends on estimation quality, CFO residual, symbol timing, and LoRa waveform reconstruction accuracy
- much harder to trust in a preamble-estimate-only architecture
- likely not a first hardware target

---

## What Is Worth Studying

Recommended shortlist:

- `NT=1`: `SC`, `EGC`, `MRC`
- `NT=2`: matched filter, `ZF`, `MMSE`

Optional stretch:

- `NT=2`: `MMSE-SIC`

Not recommended as a priority:

- sphere decoding
- ML detection
- iterative turbo-style receivers
- payload-adaptive channel tracking tied directly to a new combiner design

Those may be academically interesting, but they do not match the current implementation path.

---

## Additional `NT=1` Gateway Risks To Study

The main product path is `NT=1, NR=4` gateway reception with MRC. Two practical risks deserve explicit study because they can erase the expected diversity gain even when the nominal MRC math is correct.

### Doppler and within-packet channel drift

Current MRC assumes:

- one preamble-derived `h`
- one set of phase corrections `phi_j`
- one set of real weights `c_j`
- channel stable enough that these remain valid over the packet

This is weakest at:

- high SF, especially `SF11` and `SF12`
- long payloads
- mobile nodes
- vibrating assets or time-varying indoor multipath

Failure mode:

- antenna phases drift after the preamble
- coherent addition degrades during the payload
- MRC gain collapses toward `EGC`, `SC`, or worse

Required study questions:

- For what Doppler range does preamble-only MRC remain acceptable?
- At what packet duration or SF does weight staleness become material?
- Does `SC` or `EGC` become more robust than MRC in fast-varying channels?
- Does packet-to-packet EMA help, or does it make the drift problem worse?

Minimum comparison set:

- static channel, preamble-only MRC
- time-varying channel, preamble-only MRC
- time-varying channel, `EGC`
- time-varying channel, `SC`

Stretch option:

- packet-level or symbol-level channel tracking if preamble-only MRC is not robust enough

### Interference from other transmitters

Plain MRC is a diversity combiner, not an interference canceller.

It will help when the dominant impairment is fading plus thermal noise. It does not directly solve:

- same-channel overlapping LoRa packets
- strong co-channel interferers
- contaminated preambles
- structured interference that biases the desired `h` estimate

Failure mode:

- the preamble estimate locks onto a mixture rather than the desired user
- MRC coherently boosts the wrong spatial component
- packet FFT decisions fail even when the desired node would have decoded in isolation

Required study questions:

- How much desired-packet gain remains under one overlapping interferer?
- When does interferer power erase the MRC advantage over single-antenna reception?
- Does `SC` ever beat MRC when the preamble estimate is contaminated?
- Are there operating points where the gateway should reject MRC and fall back to a simpler mode?

Minimum comparison set:

- desired packet only
- desired + weaker interferer
- desired + equal-power interferer
- desired + stronger interferer

Useful sweep dimensions:

- desired/interferer power ratio
- same SF vs different SF
- partial preamble overlap vs full overlap
- correlated vs uncorrelated spatial channels

These two risks should be treated as part of the `NT=1` algorithm assignment, not only as late validation items.

---

## Adaptive / Learned Channel-Aware Methods

There is a second class of algorithm worth studying for this project: methods that adapt based on the observed channel environment rather than replacing the receiver with a fully learned detector.

This is a better fit than end-to-end neural receivers because:

- the system already has packet-level channel features such as `H`, `N0`, condition number, and packet-to-packet drift
- the control decisions happen once per packet, not once per sample
- PicoRV32 can plausibly support small policy logic or a tiny classifier
- the current architecture already exposes natural tuning knobs such as `ALPHA_SHIFT`, W regularization, and combiner selection

The right question is:

```text
Can the receiver infer whether the channel is static indoor, dense multipath, weak-LoS, or time-varying, and then choose a better estimator or combiner policy?
```

### Level 1: Rule-based adaptation

This is the recommended first step.

Use measured packet-level features such as:

- packet-to-packet change in `H`
- per-antenna power spread
- `cond(H)` or antenna correlation
- residual CFO drift
- `N0`
- AGC movement over time
- packet success or CRC success rate
- `W_MISSED_PACKET` rate

Then adapt one or more of:

- `ALPHA_SHIFT` for H and `N0` smoothing
- MMSE regularization strength
- `NT=1` combiner selection: `SC`, `EGC`, or `MRC`
- `NT=2` detector selection: matched filter, `ZF`, or `MMSE`
- a confidence score on whether current-packet `H` should be trusted

Example policy directions:

- static indoor: longer EMA, normal `MMSE`, default to `MRC`
- mobile / fast-varying: disable or shorten EMA, trust latest preamble only
- dense multipath / ill-conditioned `H`: stronger regularization, avoid `ZF`
- poor `H` confidence at low SNR: consider `SC` or `EGC` instead of `MRC`

### Channel model note

The current simulation baseline has used packet-static Rayleigh fading (`K=0`).
That is the right stress case for non-LoS multipath, but it is not the only
deployment condition worth studying.

For weak or strong line-of-sight conditions, the channel model should also be
swept over packet-static Rician fading with non-zero `K`:

- `K=0`: Rayleigh, no dominant path
- small positive `K`: weak-LoS / mixed multipath
- large `K`: strong LoS with reduced deep-fade probability

This does not change the `NT=1` MRC or `NT=2` MMSE math directly; it changes
the operating distribution of `H`, fade depth, and spatial correlation risk.
For `NT=2`, stronger LoS can make column correlation more important than in the
independent-Rayleigh baseline, so detector comparisons should not rely only on
`K=0` sweeps.

### Level 2: Small learned classifier

This is worth studying only after the rule-based baseline exists.

Use a compact feature vector derived once per packet, for example:

```text
features = [
    packet_to_packet_H_delta,
    per_antenna_power_spread,
    cond_H,
    antenna_correlation,
    N0_mean,
    N0_variance,
    CFO_drift,
    AGC_step_rate,
    recent_packet_success_rate
]
```

Possible output classes:

- static indoor
- slow fading outdoor
- dense multipath
- fast-varying / mobile
- ill-conditioned 2-user channel

The classifier output would not directly produce symbols. It would select a policy, for example:

- EMA depth
- regularization level
- `NT=1` combiner choice
- whether to trust `NT=2` spatial separation this packet

### What not to prioritize

Do not prioritize:

- end-to-end neural receivers
- sample-by-sample learned equalizers
- large learned models that require a training and deployment stack
- anything that assumes perfect transfer from simulation to hardware without real-capture validation

Those belong in a research branch, not the main architecture path.

### Additional tasks for this study track

#### Task A: Define packet-level channel features

Specify a minimal feature set that can be derived from the current receiver outputs and firmware-visible registers.

#### Task B: Build rule-based adaptive baselines

Implement at least one adaptive baseline in simulation, for example:

- adaptive `ALPHA_SHIFT`
- adaptive `NT=1` combiner choice
- adaptive MMSE regularization

#### Task C: Compare fixed vs adaptive policies

Compare:

- fixed `MRC` / fixed `MMSE`
- rule-based adaptive controller
- optional learned classifier

#### Task D: Evaluate by environment class

At minimum:

- static indoor
- dense outdoor multipath
- mildly time-varying channel
- fast-varying / mobile channel

### Questions to answer

- Does adaptive EMA selection materially improve `NT=1` or `NT=2` performance?
- Can `SC` or `EGC` outperform `MRC` in the low-SNR / poor-estimate regime often enough to justify adaptive selection?
- Does environment-aware MMSE regularization outperform a fixed regularization level?
- Is a small learned classifier noticeably better than hand-designed rules?
- If there is a gain, is it large enough to justify added firmware complexity?

---

## Expected Behavior

These are hypotheses to verify in simulation.

### `NT=1`

- high SNR, good channel estimate: `MRC > EGC > SC`
- low SNR, noisy amplitude estimate: `EGC` may approach or beat estimated `MRC`
- very poor estimate: `SC` may beat estimated `MRC`

### `NT=2`

- well-separated channels, high SNR: `ZF ~= MMSE`
- low SNR or correlated channels: `MMSE > ZF`
- unequal user powers: `MMSE` likely safer than `ZF`; `SIC` may help if subtraction is accurate

---

## Simulation Tasks

Extend the existing Python receiver and BER sweep harness to support algorithm selection.

### Task 1: Add `NT=1` combiners

Implement:

- `SC`
- `EGC`
- current `MRC`

Suggested interface:

```text
nt1_combiner = {"sc", "egc", "mrc"}
```

### Task 2: Add `NT=2` linear detectors

Implement:

- matched filter
- `ZF`
- current `MMSE`

Suggested interface:

```text
nt2_detector = {"mf", "zf", "mmse"}
```

Optional:

```text
nt2_detector = {"mmse_sic"}
```

### Task 3: Compare estimated vs genie-aided channel knowledge

For each algorithm, compare:

- estimated `H`
- true `H`

This is important because some algorithms are much more sensitive than others to channel-estimation error.

### Task 4: Sweep the operating conditions that matter

At minimum:

- `SF7`, `SF9`, `SF12`
- `BW = 125 kHz`
- per-antenna SNR sweep
- static channel
- mildly time-varying channel
- unequal per-user powers for `NT=2`
- ill-conditioned / correlated `H` for `NT=2`

### Task 5: Record complexity, not just BER

For each algorithm, estimate:

- complex MAC count
- matrix inverse requirement
- division or reciprocal count
- whether it cleanly fits PicoRV32
- whether it needs new control states or buffer structure

---

## Evaluation Metrics

Primary metrics:

- BER or PER vs SNR
- gain over bypass / single-antenna baseline
- separation quality for `NT=2`

Secondary metrics:

- sensitivity to `H` estimation error
- sensitivity to CFO residual
- sensitivity to ill-conditioned channels
- robustness under unequal user powers

Implementation metrics:

- firmware complexity
- fixed-point risk
- runtime on RV32IM
- whether the current combiner datapath can already support it

---

## Deliverables

The assignee should return:

1. A short summary table comparing all studied algorithms.
2. BER or PER plots for the recommended operating points.
3. A recommendation for `NT=1`.
4. A recommendation for `NT=2`.
5. A note on whether any new algorithm justifies hardware or firmware changes.

The recommendation should be practical, not just theoretical.

---

## Decision Criteria

The study is successful if it answers these questions clearly:

### `NT=1`

- Is `MRC` still the best default once channel-estimation error is included?
- Is `EGC` a better low-SNR fallback than `MRC`?
- Is `SC` strong enough to justify a very-low-complexity alternative mode?

### `NT=2`

- Does `ZF` ever beat `MMSE` enough to justify its use?
- How much performance does `MMSE` buy over matched filter and ZF?
- Is `SIC` worth any further attention, or is it too fragile for this architecture?

---

## Recommended Outcome

Expected likely outcome before running the study:

- `NT=1`: keep `MRC` as primary mode, but add `SC` and `EGC` to simulation and evaluation
- `NT=2`: keep `MMSE` as primary mode, add `ZF` and matched filter as comparators
- do not plan hardware around `SIC` unless simulation shows a large and repeatable gain

This expectation should be tested, not assumed.

---

## Related Files

- [DSP Flow](./DSP%20Flow.md)
- [System Architecture](./System%20Architecture.md)
- [Test Plan](./Test%20Plan.md)
- [ALMMSE-MRC Combiner](./blocks/ALMMSE-MRC%20Combiner.md)
- [PicoRV32 Integration](./blocks/PicoRV32%20Integration.md)
- `sim/models/receiver.py`
- `sim/tests/run_ber.py`
