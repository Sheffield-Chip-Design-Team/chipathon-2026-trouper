# SF6 1kB Frontend Buffer Exploration

> **SUPERSEDED — HISTORICAL REFERENCE ONLY**
>
> The entire analysis in this document predates the block-based fixed-L=256 frontend buffer design.
> The current architecture stores only channel 0 (i0, q0) in a block-based buffer with
> L = min(M, 256) samples. One 512×8 SRAM macro supports **all SFs (SF6–SF12)**.
> The SRAM sizing constraints, 4-channel interleaving, and D=M vs D=2M analysis below are
> no longer applicable to the implemented design.
>
> See [`blocks/Frontend Buffer Controller.md`](blocks/Frontend%20Buffer%20Controller.md) for the current architecture.



## Goal

Record the implications of a **hard `1 kB` DSP sample-memory budget** for a non-FFT LoRa frontend, with focus on whether `SF6` is a workable operating point.

This note is about **frontend sample buffering**, not full packet replay.

## Key assumption

Across `NR=4`, with decimated samples represented as:

- `int8 I`
- `int8 Q`

each decimated sample time costs:

`4 branches * 2 bytes = 8 bytes`

With only `1 kB = 1024 bytes`, the frontend can hold:

`1024 / 8 = 128 sample times`

## Symbol capacity vs spreading factor

LoRa symbol length in samples is:

`M = 2^SF`

So the `1 kB` buffer holds:

| SF | `M` | Bytes / symbol across 4 branches | Symbols in `1 kB` |
| --- | ---: | ---: | ---: |
| `SF5` | 32 | 256 B | 4 |
| `SF6` | 64 | 512 B | 2 |
| `SF7` | 128 | 1024 B | 1 |
| `SF8` | 256 | 2048 B | 0.5 |

Immediate conclusion:

- `SF6` is the highest practical operating point if the `1 kB` limit is hard and the frontend needs a **2-symbol rolling buffer**
- `SF7` is extremely constrained
- `SF8` is not realistic for this design style

## Why `SF6` matters

At `SF6`:

- one symbol = `64` sample times
- one symbol across 4 branches = `64 * 8 = 512 B`
- two symbols across 4 branches = `128 * 8 = 1024 B`

So `1 kB` is exactly enough for:

- a **2-symbol rolling sample buffer**

That is a natural fit for Schmidl-Cox-style repeated-symbol correlation.

## What a 2-symbol `SF6` buffer supports

### 1. Repeated-upchirp SC-style acquisition

For repeated-symbol correlation:

`U_j = sum_n d_j[n+M] * conj(d_j[n])`

the frontend needs one-symbol delay history and a current symbol window.

At `SF6`, the `1 kB` buffer can hold exactly:

- previous symbol
- current symbol

across all 4 receive branches.

This makes `SF6` viable for:

- `UP_SC`
- energy normalization support
- coarse timing

### 2. Coarse timing back-calculation

Once the repeated-upchirp detector locks, the frontend can back-calculate:

- coarse packet start
- repeated-window alignment

without needing additional large stored sample windows.

### 3. Small post-lock region capture if the buffer is reused

If the same `1 kB` memory is **repurposed after acquisition**, it can store:

- `2` post-lock symbols

This is enough for:

- a tiny timing confirmation step
- a very short training field

provided the packet structure is chosen accordingly.

## What the `1 kB` buffer does not support well

Even at `SF6`, this memory is not enough for:

- full sync/downchirp plus long training storage
- packet replay
- same-packet payload buffering
- multi-symbol diagnostic capture
- wide timing search over a long stored sample region

So this is strictly a **frontend history/snapshot buffer**, not a packet buffer.

## Best buffer strategy at `SF6`

The best use of `1 kB` is a **shared buffer reused in phases**.

### Phase 1 — Acquisition mode

Use the memory as a circular `2M` rolling buffer:

- `2M = 128` sample times
- previous symbol + current symbol
- supports repeated-upchirp SC correlation

### Phase 2 — Post-lock mode

After lock:

- stop treating it as an indefinite rolling history
- repurpose or freeze it to hold the immediate post-lock region
- use the same memory for:
  - short timing confirmation
  - very short training observation

This is the most realistic way to stretch `1 kB`.

## Proposed shared buffer model

Use one shared frontend memory:

`FRONTEND_BUF[2M][NR][IQ]`

At `SF6`:

- depth: `128` sample times
- width per sample time: `8 bytes`
- total: `1024 bytes`

Intended roles:

1. rolling history during acquisition
2. short snapshot / hold region after lock

This is better than trying to define:

- separate `ACQ_BUF`
- separate `TRAIN_BUF`

because the memory budget is too small for both.

## Proposed physical SRAM organization

Given the actual memory budget is:

- `2 x 512 B` SRAM macros

a clean physical organization is to split channels across macros:

- `SRAM0`: channels `0` and `1`
- `SRAM1`: channels `2` and `3`

This is preferable to splitting by time because the frontend naturally wants:

- the same sample index from all four branches at once

### Per-sample packing

One branch sample at the decimated interface is:

- `I[7:0]`
- `Q[7:0]`

so one branch sample consumes:

`16 bits = 2 bytes`

Therefore:

- `2` channels per sample index = `4 bytes`
- `4` channels per sample index = `8 bytes`

At `SF6`, with `2M = 128` sample times:

- per macro storage = `128 * 4 B = 512 B`

which fits exactly.

### Logical view

For sample index `k`:

- `SRAM0[k] = {ch1_IQ, ch0_IQ}`
- `SRAM1[k] = {ch3_IQ, ch2_IQ}`

where each `chX_IQ` is one complex sample:

- `8-bit I`
- `8-bit Q`

The exact byte/bit ordering can be chosen later, but this is the intended logical packing.

### Why this layout is useful

- one shared sample pointer can address both SRAMs
- all four branches for the same sample time are easy to read together
- repeated-symbol correlation can read delayed/current samples using the same sample index arithmetic across both macros
- post-lock reuse of the same memory is straightforward because both SRAMs track the same time axis

### Acquisition-mode use

During rolling acquisition:

- both SRAMs are written once per decimated sample time
- both use the same circular write pointer `wr_ptr`

For repeated-symbol SC-style correlation at `SF6`:

- delayed sample index = `(wr_ptr - M) mod 2M`
- current sample index = `wr_ptr`

So the frontend can obtain all four branches for:

- the current sample time
- the one-symbol-delayed sample time

by reading the same logical index from both SRAMs.

### Post-lock use

After lock, the same two-macro organization can be:

- frozen, or
- repurposed as a short post-lock observation window

without changing the channel packing model.

This reinforces the intended use of the SRAM macros as:

- shared frontend sample memory

rather than:

- separate per-block buffers

## What this means for the frontend chain

The `1 kB` constraint pushes the design toward:

- streaming acquisition
- schedule-driven training
- minimal stored-sample regions

Likely block structure:

- `DECIM_DC`
  - decimator
  - DC removal

- `LORA_ACQ`
  - dechirp
  - `UP_SC`
  - energy normalization
  - coarse lock / timing

- `POSTLOCK_PROC`
  - reuse `FRONTEND_BUF`
  - short downchirp/sync confirmation and/or short training observation

- `CAL_WGEN`
  - calibration
  - SC / EGC / MRC weight generation

- `COMB_REMOD`
  - combine
  - bypass fallback
  - handoff to `SX1302`

## Important implication for training

With `1 kB`, the frontend cannot assume a large dedicated training buffer.

So training must be one of:

1. **very short and captured immediately post-lock** using the repurposed `FRONTEND_BUF`
2. **fully streaming** after timing is known

This means:

- preamble-only training is not enough in a no-buffer design
- the packet must leave something usable after acquisition if same-packet live training is desired

## Why `SF7` was much worse

At `SF7`:

- one symbol already consumes the full `1 kB`

That means:

- no true 2-symbol SC history
- no extra room for post-lock samples
- no realistic shared acquisition + training sample store

By contrast, `SF6` gives exactly the minimum structure needed for a useful repeated-symbol frontend.

## Provisional conclusion

Under a hard `1 kB` DSP sample-memory limit:

- `SF6` is plausible
- `SF7` is severely constrained
- `SF8` is not realistic

The recommended design direction is:

- use the full `1 kB` as a shared `2M` frontend buffer at `SF6`
- run repeated-upchirp SC acquisition first
- then reuse the same memory for a tiny post-lock observation window
- avoid any assumption of large training or packet buffers in the DSP memory budget

## SRAM fault tolerance and de-risking

Because the `SF6` frontend proposal depends on the `2 x 512 B` SRAM macros for sample history, SRAM failure should not be treated as an all-or-nothing hidden failure mode.

The architecture should include explicit de-risking.

### 1. Keep critical state out of SRAM

The SRAM macros should store:

- sample history
- short post-lock observation region

They should **not** store:

- lock FSM state
- timing counters
- SC accumulators
- energy accumulators
- training accumulators
- active weights
- calibration coefficients

Those should remain in flops/registers.

This ensures SRAM failure affects:

- acquisition history depth

not:

- the entire control plane

### 2. Boot-time SRAM BIST

At boot, run a simple SRAM test on both `512 B` macros independently.

Minimum intent:

- detect stuck-at faults
- detect address faults
- detect obvious read/write corruption

A simple march-style test is sufficient at this stage.

Recommended outputs:

- `SRAM0_BIST_PASS`
- `SRAM1_BIST_PASS`
- optional sticky failure bits in status registers

### 3. Independent macro health handling

Because the macros are partitioned by channels:

- `SRAM0 = ch0, ch1`
- `SRAM1 = ch2, ch3`

the design should support degraded operation if only one macro is bad.

Recommended policy:

- both macros pass:
  - full `NR=4` `SF6` acquisition mode
- only one macro passes:
  - reduced `NR=2` mode using the healthy macro's two channels
- both macros fail:
  - disable SRAM-dependent acquisition mode
  - fall back to minimal bypass / non-buffered mode

This avoids turning one bad macro into total loss of function.

### 4. Non-SRAM fallback path

There should always be a mode that does not depend on the frontend sample-history SRAM path.

This can be minimal:

- bypass one selected antenna
- continue feeding a valid stream to `SX1302`

This is useful for:

- chip bring-up
- isolating SRAM faults from unrelated digital issues
- basic functional recovery

### 5. Runtime sanity checks

Beyond boot BIST, the design should expose enough state to catch obvious integration or runtime errors.

Useful checks:

- legal pointer-range assertions
- lock/path consistency checks
- impossible-state flags in acquisition FSM
- optional idle-time spot-check read/write tests

These are not substitutes for BIST, but they help separate:

- memory faults
- control bugs
- correlation failures

### 6. Debug and observability

Recommended status visibility:

- per-macro BIST result
- active degraded mode
- active channel mask
- frontend mode selection
- current write pointer / freeze state

Without this visibility, SRAM faults may present as generic sync failure and become hard to isolate.

### 7. Design intent

The intended philosophy is:

- SRAM enables the best `SF6` frontend mode
- SRAM failure should degrade capability, not destroy all receive usefulness

So the sample-history SRAM path should be treated as:

- performance-enabling

not:

- single-point catastrophic dependency

## Next questions

1. Does the `1 kB` limit apply only to SRAM, or to all sample storage including flops/registers?
2. How many known post-lock symbols are actually available or acceptable in the packet format?
3. Should the `1 kB` buffer be strictly circular, or should it support a freeze/repurpose mode after lock?
4. Is the intended `SF6` path next-packet-only, or is a tiny same-packet training step still desired?
