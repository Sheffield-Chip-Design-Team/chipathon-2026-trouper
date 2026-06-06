# Remove Noise Floor Estimator Migration Plan

## Decision being evaluated

Remove the dedicated hardware `noise_floor_est` block and move the entire noise-estimation loop into firmware.

This is based on the current architectural reality:

- hardware combining uses shift-MRC, not NW-MRC
- NW-MRC remains software-only
- AGC needs coarse energy, not hardware `sigma2`

Under those assumptions, a dedicated hardware EMA for `sigma2_j` is no longer on a critical datapath.

---

## Short conclusion

If NW-MRC remains software-only, removing hardware `noise_floor_est` is architecturally clean and technically reasonable.

The replacement model is:

1. hardware measures per-branch energy or a coarse normalized noise metric
2. firmware reads those values during idle windows
3. firmware maintains the per-branch EMA
4. firmware computes NW-MRC weights when that mode is desired

This removes a dedicated RTL block whose output is only consumed by software policy.

---

## What hardware NFE does today

Current block: [noise_floor_est.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/noise_floor_est.v)

Current role:

- takes `energy_sum_[0..3]`
- converts to `energy_sum >> sf`
- runs a per-branch EMA
- exposes `sigma2_hw_[0..3]`
- muxes between hardware estimate and software override (`sigma2_src`)

Current consumer:

- the weight-generation path, but only for the software/NW side of the architecture

Current non-consumers:

- baseline hardware MRC
- AGC
- SC detector
- training accumulator

So in the current design, hardware NFE is not enabling baseline receive correctness. It is precomputing a firmware-visible convenience estimate.

---

## Proposed replacement architecture

### Hardware keeps

- `energy_meas` or `energy_meas_coarse`
- per-branch AGC snapshot path
- optional per-window coarse noise metric output

### Hardware removes

- `noise_floor_est`
- `sigma2_hw_[0..3]` generation
- hardware `sigma2_active` muxing
- `sigma2_valid` and `n_updates` state in RTL

### Firmware takes over

- idle-window sampling policy
- EMA state for each branch
- validity tracking after gain changes
- optional SW override becomes the only path
- NW-MRC weight calculation from firmware-maintained `sigma2_j`

---

## Recommended replacement interface

The cleanest hardware/firmware boundary is:

- keep `ENERGY[0..3]` for AGC/status
- add or reuse a coarse per-window noise metric
- firmware reads the metric and maintains:
  - `sigma2_est[4]`
  - `sigma2_valid`
  - `n_updates`

Recommended metric:

```text
noise_metric_j = sat_u10(((sum |x_j|^2 over one symbol) >> sf) >> 5)
```

This is the same coarse metric used in the current prototype note.

Why this is enough:

- NW is software-only
- ratios matter more than absolute scaling
- firmware can normalize however it wants
- the hardware no longer needs to expose full raw `energy_sum`

---

## Exact RTL changes

## 1. Remove `noise_floor_est` instantiation from top level

Primary file:

- [mimo_rx_top.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/mimo_rx_top.v)

Changes:

- delete `u_nfe`
- delete internal wires:
  - `sigma2_hw[0..3]`
  - `sigma2_active[0..3]`
  - `sigma2_valid`
  - `n_updates_nfe`
- delete `noise_sample_en` wiring if it is only used for NFE

If the packet-control FSM produces `noise_sample_en` solely for NFE, that signal can be removed or repurposed as a firmware interrupt/event source.

## 2. Remove the block file from build/synthesis lists

Files likely affected:

- [rtl-test/Makefile](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/Makefile)
- `rtl-test/ol_mimo_rx_top/config*.json`
- `rtl-test/syn_mimo_per_module/run_synth_*.sh`
- `rtl-test/synth_gf180.ys`

Changes:

- remove `noise_floor_est.v` from legacy integration builds if NFE is fully deleted
- or keep it temporarily for legacy test targets only during migration

## 3. Remove NFE-specific RTL block target if desired

Files:

- `rtl-test/ol_noise_floor_est/*`

This is optional during migration. It can be left in place until the new architecture is stable.

## 4. Simplify energy-measurement output path

If deleting NFE fully, then `energy_sum_[0..3]` no longer has a hardware consumer.

That opens three options:

1. keep `energy_sum` temporarily for debug only
2. replace it with a coarse `noise_metric_[0..3]`
3. remove it entirely once firmware no longer depends on it

Recommended path:

- first replace NFE-facing usage with `noise_metric`
- then remove `energy_sum` from the integrated top if unused

This likely impacts:

- [energy_meas.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/energy_meas.v)
- or replacement with [energy_meas_coarse.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/energy_meas_coarse.v)

## 5. Remove sigma2 plumbing from weight generation hardware path

Check files:

- [weight_gen.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/weight_gen.v)
- [mimo_rx_top.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/mimo_rx_top.v)

Expected change:

- baseline hardware path should not require `sigma2_active`
- any remaining sigma2 connection should be removed from the hardened AUTO path

If software still writes weights directly, no hardware sigma2 interface is needed for normal operation.

---

## Register-map changes

Primary file:

- [reg_bank.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/reg_bank.v)

Current relevant registers:

- `ENERGY[0..3]` at `0x40`–`0x47`
- `SIGMA2_HW[0..3]` at `0xE0`–`0xE7`
- `sigma2_valid`
- SW override controls / shadows

Recommended migration:

### Keep

- `ENERGY[0..3]`

### Remove

- hardware-readback `SIGMA2_HW[0..3]`
- hardware `sigma2_valid`

### Optional repurpose

Use the `0xE0`–`0xE7` region for one of:

1. firmware-owned `SIGMA2_FW[0..3]`
2. coarse `NOISE_METRIC[0..3]`
3. debug readback of firmware-maintained EMA state

Best choice:

- repurpose as firmware-visible `SIGMA2_FW[0..3]`

Why:

- preserves the conceptual meaning of the register range
- minimizes firmware/user confusion
- avoids introducing a second register range for the same concept

Implementation note:

- if firmware owns the sigma2 estimate, these registers become plain RW shadow/state registers rather than RTL-generated outputs

---

## Packet-control / interrupt changes

Current concept:

- hardware NFE updates on `noise_sample_en`

Without NFE, firmware still needs to know when a valid idle noise window has occurred.

Options:

### Option A: no dedicated event, firmware polls

- firmware periodically reads coarse energy/noise metric in IDLE

Pros:

- simplest RTL

Cons:

- less deterministic
- wastes firmware cycles

### Option B: keep `noise_sample_en` semantics as an IRQ/event

- packet control still identifies valid idle noise windows
- firmware gets an interrupt or sticky status bit
- firmware reads the latest metric and updates EMA

Pros:

- preserves the current gating policy in hardware
- minimal firmware ambiguity

Cons:

- retains a small amount of support logic

Recommended:

- keep the gating policy in hardware
- expose a sticky `NOISE_SAMPLE_RDY` status/IRQ rather than a full hardware EMA block

That gives the firmware a clean trigger without hardening the estimator itself.

---

## Firmware changes

Firmware becomes responsible for:

1. maintaining `sigma2_est[4]`
2. clearing/reseeding after AGC gain changes
3. handling `n_updates`
4. deciding whether NW-MRC is valid yet
5. writing computed weights for SW combine mode if NW is enabled

Reference firmware algorithm:

```c
for each valid idle noise window and each branch j:
    x = read_noise_metric(j)          // or read normalized energy

    if (!sigma2_valid):
        sigma2_est[j] = x
    else:
        sigma2_est[j] += (x - sigma2_est[j]) >> alpha_shift;

sigma2_valid = true after first full update
```

On AGC gain change:

```c
sigma2_valid = false;
n_updates = 0;
```

This is nearly identical to the current RTL behavior, just moved into software.

---

## Documentation changes

### Must update

- [Noise Floor Estimator.md](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/planning/blocks/Noise%20Floor%20Estimator.md)
  - mark as removed or firmware-owned

- [Weight Generation.md](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/planning/blocks/Weight%20Generation.md)
  - clarify that `sigma2` exists only in firmware for NW mode

- [AGC.md](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/planning/blocks/AGC.md)
  - no major semantic change, but clarify that AGC still relies only on energy snapshots

- [Energy Measurement.md](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/planning/blocks/Energy%20Measurement.md)
  - clarify whether it exports `energy_sum`, coarse `noise_metric`, or both

- [DSP Flow.md](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/planning/DSP%20Flow.md)
  - remove hardware NFE stage from the datapath if present

### Should update

- register map docs
- firmware integration notes
- physical design change list

---

## Verification impact

Existing tests that directly instantiate `noise_floor_est` or expect `sigma2_hw` from RTL will need to change.

Likely affected:

- [tb_dsp.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/tb_dsp.v)
- `tb_dsp_chain*.v`

New verification split:

### RTL tests

- energy metric generation
- AGC snapshot correctness
- noise-window ready event generation, if retained

### Firmware or co-sim tests

- EMA convergence
- invalidation on AGC changes
- NW weight behavior using firmware-maintained sigma2

This is the right split if sigma2 is no longer hardware-owned.

---

## Expected benefits

### Architectural

- removes a block whose output is only used by software policy
- simplifies the story around hardware vs software responsibility
- eliminates duplicate EMA policy in RTL

### RTL

- removes one standalone block
- removes wide `energy_sum -> NFE` plumbing if migrated fully
- removes sigma2 muxing and validity state from hardware

### Firmware

- one place owns sigma2 behavior
- easier to evolve the estimator without RTL respins

---

## Expected costs

### Firmware complexity

- small increase
- firmware must own the EMA loop and validity state

### Latency / autonomy

- no autonomous hardware sigma2 tracking
- CPU-less operation loses hardware sigma2, but CPU-less mode also does not use software NW-MRC anyway

### Validation churn

- tests and docs need updates
- any existing sigma2 register assumptions must be migrated

---

## Recommended migration order

1. Keep legacy path intact.
2. Add coarse energy/noise metric readout if not already present.
3. Implement firmware EMA using that metric.
4. Validate software NW-MRC using firmware-owned sigma2.
5. Remove `noise_floor_est` from top-level integration.
6. Remove or repurpose `SIGMA2_HW` register space.
7. Remove raw `energy_sum` plumbing if no longer needed.

This avoids cutting off observability too early.

---

## Recommendation

If the project is committed to:

- shift-MRC in hardware
- NW-MRC only in software

then the dedicated hardware `noise_floor_est` block should be treated as a removal candidate, not a required architectural block.

The most defensible end state is:

- hardware exports energy / coarse noise metrics
- firmware owns sigma2 estimation
- firmware owns NW weighting

That is simpler, more consistent with the current architecture, and likely better aligned with the area pressure than preserving a hardware EMA that no critical hardware datapath actually needs.
