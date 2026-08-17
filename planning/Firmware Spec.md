# Firmware Spec (Grouper Project for Trouper)

This note is the implementation handoff for the ASIC PicoRV32 firmware workstream.

It is intentionally narrower than [blocks/PicoRV32 Integration](blocks/PicoRV32%20Integration.md):
the goal here is to define exactly what someone should build, what is out of scope, and how the
work will be accepted.

## Objective

Deliver PicoRV32 firmware residing in the **Grouper** project that:

- boots from the Grouper CPU SRAM via the SPI firmware-load path.
- services the control-plane tasks for both Grouper and **Trouper**.
- handles the primary weight-computation path for the Trouper MIMO RX datapath via the shared AHB-Lite bus.
- is simple enough to verify against the current register map and RTL.

## Key Architectural Rule

There is currently no dedicated hardware `weight_gen` block in the tapeout plan due to area
pressure.

That means:
- packet detection and training accumulation remain Trouper-owned (hardware).
- weight computation is firmware-owned (residing in Grouper).
- the firmware path is the primary path for MRC-class combining.

The system must still degrade safely if firmware is absent or late, but that degraded mode is no
longer "full baseline MRC". It is a fallback mode such as:
- bypass / passthrough
- strongest-antenna selection
- previous-packet weights, if explicitly accepted by policy

The firmware assignee therefore owns a functional datapath requirement, not just an enhancement
feature.

## Fallback Requirement

Because weights are firmware-computed in the current plan, the firmware spec must explicitly
define late/missing-weight behavior.

The default fallback policy for now should be:
- if no current-packet weights are ready by the safe-switch point, the current packet remains
bypass
- `W_MISSED_PACKET` is treated as a functional event to count and debug
- firmware may optionally reuse old weights later, but only if the team explicitly accepts that
behavior

This fallback policy should be implemented and verified, not left implicit.

## Implementation Scope

The firmware assignee owns:
- PicoRV32 bare-metal runtime
- interrupt handling
- register-bank access helpers
- SPI-master pass-through helpers for SX1257 transactions
- firmware-owned diagnostics registers
- AGC control logic
- primary software weight computation path
- per-branch noise floor estimation (EMA) via periodic Training Accumulator triggers
- ~~optional TX preparation / restore path~~ (out of scope — RX-only ASIC)

The firmware assignee does not own:
- RTL changes required to make the firmware possible
- host-side SPI loader / RPi tooling
- simulation-model algorithm studies outside the firmware control loop
- ChirpStack integration
- FPGA-emulation host utilities

If the assignee needs RTL changes, they should raise them as explicit blockers instead of silently
working around them.

## Interfaces

### CPU memory map

- `0x00000000`–`0x00000FFF`: 4 KiB unified CPU SRAM (in Grouper)
- `0x00010000`–`0x0001007F`: Trouper register bank, 7-bit map `0x00`–`0x7F`, reached over
  the `GRP_*` byte bus (Grouper has priority over the host SPI slave)

> **Corrected 2026-07-26 (audit item 19).** This list previously placed an **SPI master
> peripheral**, an **IRQ controller** and a **JTAG/SWD TAP** "in Trouper" at
> `0x00010100`–`0x000103FF`. None exists: TRPR-SPM-001 removes the SPI master (SX1257
> configuration is external), §4.16 removes JTAG, and interrupt aggregation is not a
> peripheral — it is the sticky `IRQ_STATUS` register inside `reg_bank`, read at `0x02`
> and cleared via `0x03`, driving the `IRQ_OUT` pad and `IRQ_GROUPER` line. The register
> window is also 128 bytes, not 256: the map is 7-bit.

### Primary firmware-visible events

From `IRQ_STATUS` / `IRQ_CLEAR`:
- `IRQ_CORR_LOCK`
- `IRQ_TRAINING_DONE`
- `IRQ_W_MISSED_PACKET`
- `IRQ_PACKET_DONE`
- `IRQ_NOISE_READY`

### Primary firmware-owned outputs

The firmware must be able to write:
- `COND_NUM`
- `SNR_0`
- `NULL_QUALITY`
- `W` shadow bank
- `W_COMMIT`
- `NOISE_WIN_CTRL`
- `SX_TARGET` / `SX_ADDR` / `SX_DATA` / `SX_CTRL`

### Primary firmware inputs

The firmware must be able to read:
- `PACKET_STATUS`
- `ACTIVE_MODE`
- `ACTIVE_ANTENNA_EN`
- `ENERGY_*`
- `SC_STAT`
- `TRAINING_STATUS`
- `N_ACC`
- `Z_SHIFT`
- `Z_j`

## Deliverables

## 0. Config interlock — RX_HOLD (`0x1A`) — READ THIS FIRST

**The receiver comes up disabled.** `RX_HOLD` (`0x1A[0]`) is **set out of
reset**: it holds the SC detector cleared, so no packet can be detected until
firmware clears it. A driver that configures the chip and then waits for a lock
will wait forever.

`RX_HOLD` also gates configuration. These registers are writable **only** while
`RX_HOLD == 1` *and* `PACKET_STATUS.ACTIVE == 0`; outside that window hardware
**drops the write** and latches `CFG_WR_REJECTED` (`0x1A[1]`, RO sticky, W1C):

| Addr | Register |
|---|---|
| `0x09` | `SF_CFG` |
| `0x0A` | `BW_CFG` (`bw_sel`, `sc_ant_sel`) |
| `0x0B` | `PKT_TIMEOUT_SYMS` |
| `0x0E` | `SC_HITS_REQ` |
| `0x27` | `TACC_WINDOW_SYMS` |

**Required sequence, at boot and for every later reconfiguration:**

```c
asic_cfg_begin();                  /* RX_HOLD = 1 (no-op straight after reset) */
reg_write8(REG_SF_CFG, sf);
reg_write8(REG_BW_CFG, bw);
/* ... remaining gated writes ... */
if (asic_cfg_write_rejected())     /* optional but recommended */
    /* sequence bug: a gated write was dropped */;
asic_cfg_commit();                 /* RX_HOLD = 0 -> detector may lock */
```

Helpers are in `firmware/picorv32/asic_regs.h`. Note `asic_cfg_clear_rejected()`
is a read-modify-write: `reg_bank` takes `rx_hold` from `wdata[0]` on *every*
write to `0x1A`, so clearing the sticky bit naively would release the hold too.

**Why it exists:** it makes "config writable" and "detector able to lock"
mutually exclusive, which is what allows the 32 MHz timing constraints to treat
these registers as quasi-static (Open Risks #43,
`planning/mcp-config-settle-gate-design.md`). It is enforced in hardware, not a
convention — the write is refused, not merely discouraged.

## 1. Minimal Bring-Up Firmware

This is the first milestone and must be delivered before AGC or software weights.

### Required behavior
- boot from SPI-loaded image
- **clear `RX_HOLD` after writing the gated configuration** (§0) — without this
  the receiver never locks and every downstream milestone is untestable
- enter a stable main loop
- read and clear IRQs
- update firmware diagnostics registers
- avoid writes outside the intended SRAM/program footprint

### Acceptance criteria
- host can load the image and release `CPU_RESET`
- firmware stays alive and repeatedly services `IRQ_STATUS`
- writes to `COND_NUM`, `SNR_0`, and `NULL_QUALITY` are visible over the register map
- no reserved-bank corruption is observed in the CPU SRAM strategy defined by hardware

## 2. AGC and Noise Floor Estimation Firmware

This is the first tapeout-useful firmware feature.

### Required behavior
- trigger on `IRQ_CORR_LOCK` for AGC updates.
- periodically trigger noise measurement via `TACC_NOISE_TRIG` (0x1F) during idle windows (when `!PACKET_ACTIVE`).
- maintain per-branch `sigma2` estimate via EMA in DMEM.
- read `ENERGY_*` (at lock) and `ZDIAG_k` (after noise trig completion).
- decide whether to adjust gain per branch.
- handle gain-owner semantics cleanly when `CPU_RESET=0`.

### Required policy
- start from the thresholds and gain-step model in [blocks/PicoRV32 Integration](blocks/PicoRV32%20Integration.md).
- use BB gain for fine adjustment first.
- use LNA steps only when BB is at limit or saturation guard is crossed.
- mark any packet whose gain changed as unsuitable for EMA reuse.
- **Noise Measurement Path:** Estimation SHALL use the periodic Training Accumulator trigger mechanism (`TACC_NOISE_TRIG`) and SHALL NOT depend on the PSRAM replay path.

### Acceptance criteria
- gain changes are staged and applied externally (board-level SPI master); Trouper has no on-chip gain-shadow/commit register to observe.
- `sigma2` estimates converge in firmware memory during idle periods.
- AGC converges on a static channel within the planned packet budget.
- firmware never blocks the packet path waiting for AGC or noise measurement completion.

## 3. Software Weight Computation

This is the primary weight path in the current architecture.

### Required behavior
- trigger on `IRQ_TRAINING_DONE`
- read `Z_j` and `Z_SHIFT`
- apply calibration coefficients
- compute weights
- write `W` shadow bank
- pulse `W_COMMIT`
- handle missed-deadline behavior explicitly
- leave a defined fallback output when weights are late

### First supported modes
The assignee should implement in this order:
1. software MRC
2. software SC
3. software EGC
4. optional noise-weighted MRC when per-branch `σ²_ema` estimates are available

Full `NT=2` ALMMSE is out of scope — this is an NT=1 design. NT=1 noise-weighted
MRC is allowed as the diagonal-noise MMSE special case; it is not a multi-user detector.

### Acceptance criteria
- software-computed `W` matches the reference model for the supported modes within the agreed
fixed-point tolerance
- `W_COMMIT` arrives within the SF6 timing budget under the intended operating mode
- late-commit behavior is observable via `W_PENDING` / `W_MISSED_PACKET`
- fallback behavior on missed commit is defined and demonstrated
- the team can quantify the miss rate under expected operating conditions

## 4. TX Preparation / Restore — **OUT OF SCOPE**

This is an RX-only ASIC. There is no transmit path, no TDD sequencing, and no PA or T/R switch. This deliverable is permanently removed from scope.

## 5. Null-Steering / Noise-Window Extension

This is explicitly a stretch task.

### Required behavior
- use `IRQ_NOISE_READY`
- read noise-window `Z_j`
- derive and commit null weights if this path is enabled
- write `NULL_QUALITY`
- clear `NOISE_EN` before normal preamble training resumes

### Acceptance criteria
- firmware respects the sequencing documented in the register map
- null-steering mode does not suppress normal training for subsequent packets

## Recommended Phase Order

The assignee should work in this order:
1. bare-metal runtime + build
2. minimal bring-up firmware
3. AGC
4. software MRC
5. SC / EGC software modes
6. null steering

This order is deliberate:
- AGC is more tapeout-relevant than combining mode variants
- MRC should be proven before adding SC and EGC

## Explicit Non-Goals For First Assignment

The first firmware assignment should not include:
- full ALMMSE or any multi-transmitter (NT≥2) algorithm (NT=1 noise-weighted MRC is allowed)
- SIC or advanced multi-user detectors
- dynamic runtime switching among many algorithms
- generic C library integration
- JTAG debug stack development
- polished operator UX or GUI tooling

If these are needed later, they should be separate tasks.

## Handoff Inputs The Assignee Should Use

Primary references:
- [blocks/PicoRV32 Integration](blocks/PicoRV32%20Integration.md)
- [Register Map](Register%20Map.md)
- [DSP Flow](DSP%20Flow.md)
- [System Architecture](System%20Architecture.md)
- [Test Plan](Test%20Plan.md)

The assignee should treat [Register Map](Register%20Map.md) as the interface source of truth and
the PicoRV32 Integration note as the intended behavior source of truth, but should not assume a
hardware `weight_gen` block exists unless the RTL proves otherwise.

## Required Outputs From The Assignee

The firmware assignee should return:
- firmware source tree
- build instructions
- produced image artifacts format (`.elf`, `.bin`, map file)
- register-level description of what the firmware touches
- short timing note for each IRQ path
- test evidence against at least the minimal bring-up and AGC milestones
- test evidence that software weight computation meets or misses the packet deadline under
representative cases

## Definition Of Done

This workstream is done when:
1. the team can boot the PicoRV32 from the host loader reliably
2. the minimal diagnostics firmware is stable
3. AGC behavior is implemented and verified
4. software weight computation is implemented and validated for `NT=1`, or the team explicitly
accepts a non-MRC fallback tapeout mode
5. all remaining extensions are clearly marked as out-of-scope or follow-on

## Open Questions To Resolve Before Assignment

These are small but should be answered explicitly when handing off the work:
- Is `NT=1` software MRC required for tapeout, or is bypass / SC fallback acceptable as the
tapeout baseline?
- ~~Is TX prep/restore in scope for the first assignee, or should firmware stop at RX-only?~~ **Resolved: RX-only. TX is not supported.**
- Should the assignee own the host-side firmware loader, or only the CPU image itself?
- Is null-steering a real milestone or only a research branch?
- Is reuse of previous-packet weights allowed, or must late weights always fall back to bypass?

If these are unresolved, the safe default is:
- RX-only firmware
- AGC in scope
- software `NT=1` MRC in scope
- TX not supported (RX-only ASIC); null-steering/`NT=2` deferred
- late weights fall back to bypass
