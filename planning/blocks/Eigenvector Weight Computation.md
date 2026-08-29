# Eigenvector Weight Computation — Firmware Implementation Spec

**Scope:** This note defines the single firmware task of computing MRC combining
weights from the training accumulator output using the principal-eigenvector
method. It is a focused handoff for one software engineer.

Most of this document (Algorithm — Power Iteration, Platform Constraints, the
fixed-point flowchart) describes the **on-chip PicoRV32-constrained**
implementation: no FPU, 32-bit integer only, 8-iteration power method, int12
matrix normalisation. If PicoRV32 is not used on-chip, the same task can run
**unconstrained** on an external host (e.g. a Raspberry Pi over SPI) with
exact double-precision eigendecomposition instead of fixed-point power
iteration — see [Alternative: Unconstrained Host
Implementation](#alternative-unconstrained-host-implementation-eg-raspberry-pi)
below. The two implementations are drop-in equivalent from the ASIC's point of
view: both are just something writing the same registers.

---

## Background

The ASIC training accumulator produces a 4×4 Hermitian channel correlation
matrix Z by accumulating all C(4,2) = 6 branch-pair cross-correlations over
the preamble training window:

```math
Z_{kl} = \sum_{n=0}^{N_{acc}-1} \text{raw}_k[n] \cdot \overline{\text{raw}_l[n]}, \quad k,l \in \{0,1,2,3\}
```

The full matrix is:

```math
Z =
\begin{pmatrix}
Z_{00} & Z_{01} & Z_{02} & Z_{03} \\
\overline{Z_{01}} & Z_{11} & Z_{12} & Z_{13} \\
\overline{Z_{02}} & \overline{Z_{12}} & Z_{22} & Z_{23} \\
\overline{Z_{03}} & \overline{Z_{13}} & \overline{Z_{23}} & Z_{33}
\end{pmatrix}
```

where the diagonal entries $Z_{kk} = \sum_n |\text{raw}_k[n]|^2$ are real and
non-negative, and $Z_{lk} = \overline{Z_{kl}}$ (Hermitian symmetry).

For a rank-1 channel $\mathbf{h}$ corrupted by white noise $\sigma^2$:

```math
Z \approx N_{acc}\left(\mathbf{h}\mathbf{h}^H + \sigma^2 I\right)
```

The dominant eigenvector of $Z$ is the link to the combiner weights. For a
rank-1 signal term, $\mathbf{h}\mathbf{h}^H$ has principal eigenvector
$\mathbf{h}$ (up to an arbitrary complex scale and phase), and the added
white-noise term $\sigma^2 I$ shifts the eigenvalues without changing that
eigenvector direction. So the largest eigenvector of $Z$ is the best estimate
of the channel vector direction. MRC then chooses weights proportional to the
conjugate of that channel estimate so that each branch is phase-aligned before
summation:

```math
\mathbf{w}_{\text{MRC}} \propto \overline{\mathbf{v}_{\max}(Z)}
```

after normalisation to fit Q1.15. Relative to the legacy row-sum path, this
uses all 16 matrix entries coherently rather than collapsing $Z$ early to one
complex value per branch. The firmware fires on `IRQ_TRAINING_DONE`, reads $Z$
from registers, computes the principal eigenvector, conjugates and normalises
it, and commits the result to the weight shadow bank before the packet
safe-switch deadline.

Reference algorithm: `sim/models/training_accumulator.py::compute_eigvec_weights()`.

---

## Algorithm Flowchart (Conceptual)

```mermaid
flowchart TD
    A([IRQ_TRAINING_DONE]) --> B[Read Z matrix\n 6 cross-correlation pairs + 4 diagonal entries]
    B --> C[Build 4×4 Hermitian matrix Z]
    C --> D[Initialise v = 1, 0, 0, 0]
    D --> E{Converged?\nor 8 iterations done?}
    E -- No --> F[w = Z · v]
    F --> G[v = w / max w]
    G --> E
    E -- Yes --> H[w = conj v / max v]
    H --> I[Write weights to shadow bank]
    I --> J[Commit]
    J --> K([Done])
```

---

## Algorithm Flowchart (Fixed-Point Implementation)

```mermaid
flowchart TD
    A([IRQ_TRAINING_DONE]) --> B[Read 18-bit N_ACC\n from 0x21–0x23]
    B --> C{N_ACC == 0?}
    C -- Yes --> Z([Exit — no weights committed])
    C -- No --> D[Read 6 off-diagonal Z_kl pairs\n int24 bits 31:8 I+Q from 0x40–0x63]
    D --> E[Read 4 diagonal ZDIAG_k\n int24 bits 31:8 from 0x64–0x6F]
    E --> F[Find max_abs across all entries\n diagonal already at the same [31:8] scale\n as the off-diagonals — no alignment shift needed]
    F --> G{max_abs == 0?}
    G -- Yes --> Z
    G -- No --> H[Compute normalisation shift sh\n max_abs >> sh ≤ 4095]
    H --> I[Build normalised int16 matrix M\n off-diagonal: Z_kl >> sh\n diagonal: ZDIAG_k >> sh]
    I --> J[Initialise eigenvector estimate\n v = 1, 0, 0, 0 + j·0, 0, 0, 0]
    J --> K{iter < 8?}
    K -- Yes --> L[Matrix-vector multiply\n w = M · v\n 4 complex dot products\n using Hermitian symmetry]
    L --> M[Find w_max = max component magnitude]
    M --> N[Renormalise\n find smallest power-of-2 shift sh2\n such that w_max >> sh2 ≤ 4096\n v = w >> sh2]
    N --> O[iter = iter + 1]
    O --> K
    K -- No --> P[Find v_max = max component of v]
    P --> Q[Convert to Q1.15 MRC weights\n W_k_re =  v_k_re × 32767 / v_max\n W_k_im = −v_k_im × 32767 / v_max]
    Q --> R[Write W shadow bank\n 0x30–0x3F, 4 complex int16 pairs]
    R --> S[Pulse WGT_CTRL.W_COMMIT\n write 0x01 to 0x1E]
    S --> T([Done — weights pending safe-switch])
```

---

## Platform Constraints

| Item | Value |
|---|---|
| CPU | PicoRV32 RV32IM (integer + M-extension multiply/divide; **no FPU**) |
| Clock | 16 MHz |
| SRAM | 4 KiB total (code + data + stack) |
| Arithmetic | 32-bit integer; `MUL` produces lower 32 bits; `DIV`/`REM` available |

All arithmetic must be fixed-point. There is no `float` or `double` in this
firmware.

---

## Inputs — Register Reads

Read on `IRQ_TRAINING_DONE`. All values are big-endian in the register bank.

### Off-diagonal Z_kl pairs — 6 × complex int24 (bits [31:8])

Each pair holds:

```math
Z_{kl} = \sum_n \text{raw}_k[n] \cdot \overline{\text{raw}_l[n]} = Z_{kl,I} + j \cdot Z_{kl,Q} \quad (k < l)
```

| Pair | I register (MSB) | Q register (MSB) |
|---|---|---|
| Z_01 | `0x40` | `0x43` |
| Z_02 | `0x46` | `0x49` |
| Z_03 | `0x4C` | `0x4F` |
| Z_12 | `0x52` | `0x55` |
| Z_13 | `0x58` | `0x5B` |
| Z_23 | `0x5E` | `0x61` |

Each component is 3 bytes, MSB-first, holding bits [31:8] of the int32 accumulator (i.e. `Z_kl >> 8`). See `asic_regs.h` for byte-level defines.

### Diagonal Z_kk — 4 × uint24

Bits [31:8] of the 32-bit per-branch energy accumulator — **the same scale as
the off-diagonal Z_kl registers above** (widened from an earlier 16-bit
`[31:16]` readback; see `planning/blocks/Training Accumulator.md`, "ZDIAG
widening" note):

```math
Z_{kk} = \sum_n |\text{raw}_k[n]|^2 \in \mathbb{R}_{\geq 0}
```

The register holds $\lfloor Z_{kk} / 2^{8} \rfloor$. These are real and non-negative.

| Branch | Register (MSB) |
|---|---|
| 0 | `0x64` |
| 1 | `0x67` |
| 2 | `0x6A` |
| 3 | `0x6D` |

Because the off-diagonal and diagonal registers now share the same `[31:8]`
scale, no scale-alignment shift is needed before comparing or combining them
— unlike the earlier 16-bit ZDIAG revision, which required left-shifting
`ZDIAG_k` by 8 before use.

### Accumulation count

`N_ACC` is an 18-bit unsigned value across `0x21`–`0x23`, big-endian:
`((read(0x21) & 0x03) << 16) | (read(0x22) << 8) | read(0x23)`. Skip weight
computation if `N_ACC == 0`.

---

## Algorithm — Power Iteration

The goal is the principal eigenvector: the vector $\mathbf{v}$ satisfying

```math
Z\,\mathbf{v} = \lambda_{\max}\,\mathbf{v}
```

which is found iteratively without a full eigendecomposition.

### Step 1 — Normalise matrix entries to int12

Find the maximum absolute value across all matrix entries. Off-diagonal and
diagonal readbacks are both at scale 2^8 (bits [31:8]), so no scale-alignment
shift is needed before comparing them:

```math
M = \max\!\left(\max_{k<l}\bigl(|Z_{kl,I}|,\,|Z_{kl,Q}|\bigr),\; \max_k\, Z_{kk}\right)
```

Compute the common right-shift:

```math
\text{sh} = \max\!\left(0,\;\left\lceil\log_2\!\left(\frac{M}{4095}\right)\right\rceil\right)
```

Apply to all entries to produce the normalised int16 matrix $\tilde{Z}$:

```math
\tilde{Z}_{kl} = Z_{kl} \gg \text{sh}
```

This ensures every matrix entry satisfies $|\tilde{Z}_{kl}| \leq 4095$, so
the matrix-vector accumulations in Step 2 cannot overflow int32.

### Step 2 — Power iteration (8 iterations)

Starting vector $\mathbf{v}^{(0)} = [4096,\, 0,\, 0,\, 0]^T$ (real).

Each iteration $i = 0 \ldots 7$:

**1. Matrix-vector multiply:**

```math
\mathbf{w}^{(i)} = \tilde{Z}\,\mathbf{v}^{(i)}
```

Expanded into real and imaginary parts for row $k$, exploiting Hermitian
symmetry ($\tilde{Z}_{lk} = \overline{\tilde{Z}_{kl}}$):

```math
\text{Re}(w_k) = \sum_{l=0}^{3} \Bigl[\text{Re}(\tilde{Z}_{kl})\cdot\text{Re}(v_l) - \text{Im}(\tilde{Z}_{kl})\cdot\text{Im}(v_l)\Bigr]
```

```math
\text{Im}(w_k) = \sum_{l=0}^{3} \Bigl[\text{Re}(\tilde{Z}_{kl})\cdot\text{Im}(v_l) + \text{Im}(\tilde{Z}_{kl})\cdot\text{Re}(v_l)\Bigr]
```

where $\text{Im}(\tilde{Z}_{kl}) = -\text{Im}(\tilde{Z}_{lk})$ for $l < k$.
Each row accumulates 7 terms of (int12 × int12); the maximum sum is
$7 \times 2 \times 4095^2 \approx 235\text{M} \ll 2^{31}$, so int32
accumulators cannot overflow.

**2. Renormalise:**

```math
\text{sh}_2 = \left\lceil\log_2\!\left(\frac{\|\mathbf{w}^{(i)}\|_\infty}{4096}\right)\right\rceil, \qquad \mathbf{v}^{(i+1)} = \mathbf{w}^{(i)} \gg \text{sh}_2
```

where $\|\cdot\|_\infty$ is the maximum over all real and imaginary components.
The power-of-2 shift keeps $v$ in the ±4096 range without any multiplication.

### Step 3 — Set COMB_POST_GAIN_SHIFT and compute W_max

The combiner guard shift is `>>> 8` (Q0.7 scaling). The output before `post_gain_shift`
is:

```
y_pre ≈ W_max_byte × NR × A_est / 256
```

where `A_est` is the RMS input amplitude on the strongest branch and `NR = 4`.

**Estimate signal amplitude from Zdiag:**

```
// ZDIAG_k is the uint24 hardware register (= Z_kk >> 8).
// Left-shift by 8 to recover the Z_kk scale before dividing by N_ACC.
E_max    = (max(ZDIAG_k) << 8) / N_ACC    // ≈ A^2 (mean squared amplitude)
A_est    = isqrt(E_max)                    // integer square root; 0 if E_max == 0
```

Note: `A_est` is only useful when `ZDIAG_reg × N_ACC >= 256`. For very short
training windows or very weak signals the register may read zero; in that case
`A_est = 0` and the fallback defaults (pgs=0, W_max_byte=120) are applied.
(This threshold scales with the register's shift amount — it was `>= 65536`
under the earlier 16-bit ZDIAG readback; the 24-bit widening makes `A_est`
usable at much smaller signal levels / shorter windows than before.)

**Choose pgs to target ~90 counts output:**

```
y_pre_max = 120 × 4 × A_est / 256    // = 1.875 × A_est  (with W_max_byte = 120)
if y_pre_max >= 90:
    pgs = 0                           // no boost needed
else:
    pgs = clamp(floor_log2(90 / y_pre_max), 0, 7)
```

where `floor_log2(x)` is the position of the highest set bit of `floor(x)`, i.e.
`(90 / y_pre_max).bit_length() - 1` in Python. Returns 0 for x ≤ 1.
For strong signals (`A_est ≥ 48`) this yields `pgs = 0`; for weak signals it
increases to recover output amplitude.

**Compute W_max_byte to avoid clipping after the shift:**

```
W_max_byte = min(120, 8128 / (A_est × (1 << pgs)))   // 8128 = 127 × 64
```

If `A_est == 0`, set `W_max_byte = 120`. This caps the weight scale for strong signals
(A_est > 64) so that `y_pre × 2^pgs ≤ 127` always holds.

**Write COMB_CFG:**

Write `pgs` to bits [2:0] of register `0x0F` (`COMB_POST_GAIN_SHIFT`) before
committing weights.

---

### Step 4 — Convert to Q1.15 weights

The MRC weight is the conjugate of the principal eigenvector, normalised so that
the top byte maps to `W_max_byte`:

```math
W_{k,\text{re}} = \left\lfloor\frac{\text{Re}(v_k) \times W_{\max} \times 256}{v_{\max}}\right\rfloor, \qquad W_{k,\text{im}} = \left\lfloor\frac{-\,\text{Im}(v_k) \times W_{\max} \times 256}{v_{\max}}\right\rfloor
```

where $W_{\max} = \texttt{W\_max\_byte}$ from Step 3 and $v_{\max} = \|\mathbf{v}^{(8)}\|_\infty$.

The factor of 256 places the result in Q1.15 so `trouper_top` extracts the correct
top byte. Both products fit in int32: $v_k \leq 4096$, $W_{\max} \leq 120$,
$256 \times 120 \times 4096 = 125\text{M} < 2^{31}$.

**Special case — strong signal (A_est > 64):** `W_max_byte < 120`, so the weight
vector uses fewer than 7 bits of effective resolution. This is acceptable because
the SNR is high and branch-ratio precision matters less than clipping avoidance.

---

## Outputs — Register Writes

### COMB_CFG — post_gain_shift

Write `pgs` (0–7) to bits [2:0] of register `0x0F` **before** writing weights, so
the combiner is configured before the weight commit promotes the shadow bank.

### W shadow bank — 8 × int16 (4 complex weights, Q1.15)

Write the four complex weights to the shadow bank. Each component is a signed
int16 written as two bytes, MSB-first. The top byte of each word is the effective
int8 weight seen by the combiner multipliers.

| Branch | RE register (MSB) | IM register (MSB) |
|---|---|---|
| 0 | `0x30` | `0x32` |
| 1 | `0x34` | `0x36` |
| 2 | `0x38` | `0x3A` |
| 3 | `0x3C` | `0x3E` |

### Commit

After writing all four weights, pulse `WGT_CTRL.W_COMMIT` (bit 0 of register
`0x1E`). Write `0x01`, then the hardware self-clears.

The Packet Control FSM will promote the shadow bank to the active combiner at
the next safe-switch boundary.

---

## Timing Budget

> **2026-07-11: cycle-accurate measurement (supersedes all prior estimates).**
> The weight kernel was compiled (`riscv64-unknown-elf-gcc 15.2`, `-Os`) and run on
> the real `ip/picorv32/picorv32.v` core in Icarus Verilog, configured to match the
> project's PicoRV32 (`ENABLE_MUL=1`, `ENABLE_FAST_MUL=0`, `BARREL_SHIFTER=0`,
> `ENABLE_DIV=1`), with ideal 1-cycle SRAM; cycles read from `rdcycle`/`rdinstret`
> bracketing the call. Numbers below are from the **corrected kernel** (`bench2.c`)
> that matches the current 7-bit register map and `sim/models/eigvec_fw.py`, with
> Z ingested via realistic big-endian byte-loads (faithful MMIO cost). Harness +
> logs: `/srv/eda/designs/timothyjabez/eigvec_bench/`, SGE jobs 3333–3335. **The
> measured cost is ~2× the previous back-of-envelope**, because that estimate
> assumed ~1 cycle/instruction for the non-multiply work; PicoRV32 is a multi-cycle
> core (CPI ≈ 10 here — the 448 slow `mul`s eat roughly half the cycles, and every
> ALU/load/store op is itself multi-cycle).

**Multiply-heavy, independent of SF.** The kernel does 7 multiply terms × 2 (re/im)
× 4 rows = **56 MULs per power iteration**, regardless of SF (the matrix is always
4×4 — `M`/SF never enters the eigenvector computation). Measured at 16 MHz:

| Core config | 8 iterations (default) | @16 MHz | 16 iterations | @16 MHz |
|---|---|---|---|---|
| **rv32im** (32-reg — Trouper fw Makefile ABI) | **33,283 cyc** | **2.08 ms** | 62,083 cyc | 3.88 ms |
| **rv32emc** (16-reg RV32E — Grouper `picorv32_hello_top`) | 36,458 cyc | 2.28 ms | 68,503 cyc | 4.28 ms |

Instret (8 it): im = 3,201, emc = 3,776. RV32E costs **~+10% cycles** (16-register
spilling in this register-heavy kernel), partly offset in code size (~1.5 KB vs
~1.8 KB `.text`).

### Integrated IRQ-to-commit measurement (2026-08-29)

The combined Grouper--Trouper Verilator/cocotb test
`integration/ram_backdoor/test_grouper_trouper_psram.py` now measures the
hardware-visible service interval from the **second** `IRQ_GROUPER` rising edge
(the sticky `TRAINING_DONE` source, not the earlier `SC_LOCK` notification) to
Trouper's received `rb_w_commit_pulse`. The firmware enters the real PicoRV32
IRQ vector, clears the source, reads `N_ACC` and all 48 Z bytes through the
external AHB-to-GRP bridge, executes the fixed-point eight-iteration
eigenvector computation, writes the 16-byte W shadow bank, and commits it.

| Metric | Measured value |
|---|---:|
| `IRQ_GROUPER` (`TRAINING_DONE`) → `W_COMMIT`, production 8-iteration kernel | **2.145062 ms** (68,642 IQ_CLK cycles at 32 MHz; Grouper HCLK = 16 MHz) |
| Default replay margin | 3.000 ms (1,500 samples at 500 kS/s) |
| rv32emc 8-iteration kernel, prior cycle-accurate measurement | 2.279 ms (36,458 cycles at 16 MHz) |
| Direct end-to-end margin remaining | **854.938 µs** |

This test now directly closes the relevant path: its ISR runs the production
fixed-point eight-iteration power iteration on a non-zero Z matrix accumulated
by the live Trouper datapath, then writes the resulting W shadow bank and
commits it through the real bridge. The cocotb test asserts the measured
interval is below 3 ms. The earlier 2.279 ms benchmark remains useful as an
isolated, cycle-accurate kernel characterization; it must not be added to the
end-to-end result because the direct result already contains that computation.

> **rv32emc is the current Grouper plan** — the RV32E row is the operative one;
> read the SF-window table below against the rv32emc columns. Note also that
> these numbers bound only the *on-Grouper* mode: in the external-host mode
> (RPi over SPI, `## Alternative: Unconstrained Host Implementation` below) the
> compute itself is effectively free (float `eigh` on an application-class core
> runs in the tens of µs; the ~60-byte SPI exchange is < 100 µs) — the off-chip
> path is limited by host IRQ/scheduling latency, not by this kernel, and can
> beat the PicoRV32 numbers outright. Deployments that need live-mode SF7/SF8
> MRC therefore have a second lever besides replay mode: run the weight commit
> from the RPi — with the caveat that Linux scheduling jitter on a stock
> kernel can itself approach SF7's ~1 ms window, so the live-SF7 case needs
> the `IRQ_OUT` GPIO-edge path (not SPI polling) and measurement before it's
> counted on.

> **24-bit ZDIAG widening is timing-neutral.** The `ZDIAG` `[31:16]`→`[31:8]`
> widening (commit 46e1da0, the ~0.9 dB combining-gain fix) costs **nothing** on
> PicoRV32 — measured at **−30 cyc (rv32im) / −54 cyc (rv32emc)**, i.e. the 24-bit
> path is marginally *faster*: the wider value already sits at the off-diagonal
> scale, dropping a `<<8` align on all four diagonals, which outweighs the one
> extra byte-load each. The 32-bit datapath carries the extra 8 bits for free
> (24 bits fits one register; the slow multiply is a fixed 32 steps regardless of
> operand size). So the SPI-to-external-MCU backup path pays nothing for it either.
> `firmware/picorv32/main.c` and `asic_regs.h` now implement the current 7-bit
> map and read all diagonal and off-diagonal components as matched-scale 24-bit
> `[31:8]` values.

> **RV32E ABI requirement.** `firmware/picorv32/Makefile` targets
> `-march=rv32emc -mabi=ilp32e`, matching the Grouper
> `ENABLE_REGS_16_31=0`, `COMPRESSED_ISA=1`, `ENABLE_MUL=1` configuration.
> Building this firmware as `rv32im/ilp32` is invalid: a 32-register image traps
> on that RV32E core when it accesses x16–x31. The current image was verified to
> build with `riscv64-unknown-elf-gcc` in the `chipathon26` container and occupies
> 1,634 bytes of the 4 KiB SRAM.

**The deadline scales with SF; the compute cost does not.** In the baseline live
path, `training_done` fires at `timing_ref + PREAMBLE_LEN·M` and the payload
deadline is `payload_start_estimate = timing_ref + 12·M`
(`planning/blocks/Packet Control FSM.md`), so the compute window is
`(12 − PREAMBLE_LEN)·M` = `4·M` samples at `PREAMBLE_LEN=8`, i.e.
`4·M / 500 kHz` seconds:

| SF | M = 2^SF | Live window (`4·M / 500 kHz`) | rv32im 8it (2.08 ms) | rv32emc 8it (2.28 ms) |
|---|---|---|---|---|
| SF7 | 128 | ~1.02 ms | ❌ **miss** (~2× over) | ❌ miss |
| SF8 | 256 | ~2.05 ms | ❌ miss (~1.5% over) | ❌ miss |
| SF9 | 512 | ~4.10 ms | ✅ comfortable | ✅ comfortable |
| SF10–12 | 1024+ | ≥8.19 ms | ✅ | ✅ |

MicroBlaze FPGA-emul self-trigger benchmark on a synthetic 4x4 matrix
(`n_acc=1024`, 100 MHz): `compute=3768 cyc` and `total=3792 cyc`, i.e.
`37.68 us` and `37.92 us`. This is a firmware-path measurement, not an SF-
scaling deadline.

(SF6 is out of scope — `SF_CFG` valid range is 7–12 per `planning/Register Map.md`
`0x09`.) 16-iteration runs push SF9 harder still: rv32im/16it (3.88 ms) clears SF9;
rv32emc/16it (4.28 ms) *misses* SF9's 4.10 ms window — only SF10+ is safe at 16
iterations on the RV32E core.

**Revised conclusion — live-mode firmware weight compute fits only SF9 and up.**
This is materially worse than the old "SF7 break-even, SF8 comfortable" estimate.
At the 8-iteration default, **SF7 and SF8 both miss** on both ISAs (SF8 only just —
~1.5% over — but a miss). If `W_COMMIT` misses the deadline,
`W_MISSED_PACKET` asserts and the packet stays in bypass (fallback in
`Firmware Spec.md`) — a miss degrades to single-antenna reception, it does not
break the receiver — but SF7/SF8 losing MRC gain in live mode is a real coverage
gap, not an optimisation nicety.

**PSRAM replay mode is therefore mandatory for SF7/SF8, not optional.** The
deadline relaxes from `payload_start_estimate` to `packet_end_estimate −
TACC_GUARD` (the SX1302 sees zeros until `W_commit`, so there is no live-payload
race) — a packet-length-scaled window (tens of symbols) that gives ample margin
for 8–16 iterations at any SF on either ISA. Any deployment that wants MRC gain at
SF7/SF8 must run the weight commit through replay mode.

**Levers if live-mode SF7/SF8 is ever required** (in rough order of payoff):
enable `ENABLE_FAST_MUL` (single-cycle DSP multiplier — removes the dominant
~50% mul cost, at some area/timing cost); drop to fewer power iterations if
convergence allows; or move the weight compute off-core to the host/Grouper
(`## Alternative: Unconstrained Host Implementation` below), whose float `eigh`
is not multiply-bound.

---

## Alternative: Unconstrained Host Implementation (e.g. Raspberry Pi)

If PicoRV32 is dropped from the chip (or simply not used for this task), the
same weight-commit job can run on any external host wired to the ASIC's SPI
slave — `trouper_top` has no on-chip-CPU assumption baked in; the weight path
is purely register writes to `0x30–0x3F` gated by `WGT_CTRL.W_COMMIT`
(`0x1E`). Everything in **Inputs — Register Reads** and **Outputs — Register
Writes** above is unchanged. What changes is Step 2 (**Algorithm — Power
Iteration**): the host is not integer-only, so use exact math instead of the
8-iteration fixed-point approximation.

### Interface — same registers, over SPI instead of AHB-Lite

| Step | Registers | Notes |
|---|---|---|
| Trigger | `IRQ_STATUS` bit[1] (`0x02`), or the dedicated `IRQ_OUT` pad | Poll bit[1] over SPI, or take a GPIO edge interrupt on `IRQ_OUT` to avoid poll latency. Clear via `IRQ_CLEAR` (`0x03`). |
| Read Z | `0x40–0x63` (6 pairs × I/Q int24, 36 bytes) + `0x64–0x6F` (4 × ZDIAG int24, 12 bytes) | One 49-byte SPI burst read (auto-increment while CS held low). |
| Read N_ACC | `0x21–0x23` | Full 18-bit count; same representation as the constrained path; skip if zero. |
| Write weights | `0x30–0x3F` (8 × int16, Q1.15, top byte effective) | Same 8-byte-pair layout as the constrained path — top byte convention unchanged. |
| Write gain shift | `0x0F` bits [2:0] (`COMB_CFG.post_gain_shift`) | Must be written before `W_COMMIT`, same ordering requirement. |
| Commit | `0x1E` bit 0 (`WGT_CTRL.W_COMMIT`) | Self-clears in hardware. |

SPI is Mode 0, MSB-first, up to 2 MHz — the full read+write+commit sequence
is ~60 bytes of raw SPI traffic (about 240 µs of bus time at 2 MHz).
The bottleneck is host-side latency (see Timing below), not the transfer
itself.

### 2 MHz replay-margin budget

The default `REPLAY_DELAY_SAMPLES=1500` gives a **3.000 ms** post-
`training_done` response window at 500 kS/s. The host SPI transfer consumes
`60 bytes × 8 / 2 MHz = 240 µs`, leaving **2.760 ms** for `IRQ_OUT` delivery,
host wake-up/scheduling, the host eigensolve, driver overhead, and any
inter-frame gaps. An application-class host eigensolve is expected to take
tens of microseconds, but that is not a measured end-to-end bound; the full
2.760 ms remainder must therefore be treated as a **budget**, not claimed
slack. Firmware SHALL increase `REPLAY_DELAY_SAMPLES` if measured high-
percentile `IRQ_OUT → W_COMMIT` latency exceeds this budget.

This budget applies to the same-packet replay path. It does **not** make the
external host's live-mode deadline deterministic: that path is still governed
by host scheduling jitter and the SF/BW-dependent payload-start deadline.

### Algorithm — exact eigendecomposition instead of power iteration

Reconstruct the 4×4 Hermitian `Z` matrix from the register readback exactly
as in Step 1 of the constrained path (off-diagonal and diagonal both already
at the `[31:8]` scale — no scale-alignment shift, and no int12 normalisation
shift is required off-chip since there's no int12 ceiling to respect), then
call the float reference directly instead of reimplementing power iteration:

```python
from sim.models.training_accumulator import compute_eigvec_weights
w = compute_eigvec_weights(Z_matrix)   # np.linalg.eigh, exact, Q1.15-quantized output
```

This is `compute_eigvec_weights()` (exact `eigh`), not `compute_eigvec_fw()`
(the fixed-point power-iteration model of the constrained firmware). The
Step 3 signal-amplitude / `pgs` / `W_max_byte` logic (combiner gain scaling)
is unchanged in principle — it exists to size the Q1.15 output for the
combiner's 8-bit multiplier, not to work around PicoRV32's lack of an FPU —
but can be computed directly in floating point on the host and only
quantized at the final register-write step, rather than via the integer
`isqrt`/shift approximations in the constrained path.

**Historical note (partially superseded):** `sim/notebooks/11_training_accumulator.ipynb`
§3–4 originally quantified the constrained firmware's fixed-point path as
≈0.9 dB worse in mean combining gain than exact `eigh` (49% vs 31% SER at
−16 dB per-antenna SNR, SF7/NR4), and traced the *dominant* part of the gap
to the (then 16-bit) ZDIAG register truncation. **That part is now closed
on-chip** by the ZDIAG 16-bit→24-bit widening (see "ZDIAG widening" note in
`planning/blocks/Training Accumulator.md`). A smaller residual gap remains
at low SNR — re-testing after the ZDIAG fix found this residual *is*
iteration-count-limited after all (16 iterations roughly halves it), which
reverses the notebook's earlier claim that more iterations don't help: that
earlier test was run before the ZDIAG fix, when the 16-bit-truncation bias
dominated and completely masked this smaller, genuine convergence-rate
effect. So an unconstrained host is no longer required to close the
*dominant* accuracy gap, but still has a real (if smaller) accuracy edge at
low SNR unless the on-chip iteration count is also increased — which the
corrected Timing Budget above shows is not free at low-to-mid SF. Its other
advantage remains architectural (no on-chip CPU/SRAM area or verification
burden).

### Timing — the actual constraint

The PicoRV32 path is deterministic but, per the measured Timing Budget
above, is itself 2.08 ms (rv32im) / 2.28 ms (rv32emc) at 8 iterations
(SF-independent) against an SF-dependent deadline — in baseline live mode that
fits only from SF9 upward, with SF7 and SF8 both missing on either ISA. A general-purpose Linux host's `IRQ_OUT` interrupt-to-userspace
latency is a different, non-deterministic problem on top of that: not
guaranteed, and can run into the low milliseconds under load on a non-RT
kernel.

- **Baseline live mode**: deadline is `payload_start_estimate = timing_ref +
  12·M` samples from lock. At low SF (short `M`) this window is under 1.5 ms
  total from lock, of which `training_done` itself doesn't fire until ~5
  symbols in — likely too tight for a stock Raspberry Pi OS round trip at low
  SF, though it loosens proportionally as SF increases (`M = 2^SF`).
- **PSRAM replay mode**: deadline relaxes to `packet_end_estimate −
  TACC_GUARD` instead of the live-payload boundary, since the SX1302 sees
  zeros until `W_commit`. This gives millisecond-scale slack — comfortable
  for a non-RT host — and is the recommended mode for a host-computed weight
  path. It also extends the accumulation window itself (more samples, better
  Z estimate), so PSRAM mode is a strict win for this architecture, not just
  a timing workaround.

If the host misses the deadline, the existing fallback applies unchanged:
`W_MISSED_PACKET` sets, the combiner stays in bypass, and weights apply at
the next `safe_switch` — no new failure mode needs to be designed for a host
implementation.

### What's unchanged from the constrained spec

- Register map, addresses, byte ordering (Inputs / Outputs sections above)
- Step 3's gain-scaling *purpose* (avoid combiner clipping / target ~90
  counts output) — only its *implementation* (float vs integer arithmetic)
  differs
- The `W_MISSED_PACKET` / bypass fallback policy
- Acceptance criterion 2 (match `compute_eigvec_weights()` within ±1 LSB in
  Q1.15) — trivially satisfied by construction, since the host implementation
  *is* `compute_eigvec_weights()`, not an approximation of it

---

## What Is Out of Scope for This Task

- Noise-weighted eigenvector (requires sigma² EMA from `TACC_NOISE_TRIG` path)
- Calibration coefficient application
- Antenna masking via `ACTIVE_ANTENNA_EN`
- Warm-start from previous packet eigenvector
- Any other weight mode (MRC row-sum, EGC, SC)

These are follow-on tasks.

---

## Acceptance Criteria

1. On `IRQ_TRAINING_DONE` with non-zero `N_ACC`, firmware writes `COMB_CFG`,
   all 8 weight bytes, and pulses `W_COMMIT` within the SF5 timing budget.
2. With a known synthetic Z matrix (from the Python model), the firmware output
   direction matches `compute_eigvec_weights()` closely. In practice this is
   checked as an angular tolerance, not a literal ±1 LSB Q1.15 bound — see
   `sim/tests/test_eigvec_fw.py` (`test_weight_direction_vs_float_reference`,
   5° tolerance at typical SNR; `test_weight_direction_low_snr`, 15° at high
   noise). A literal ±1 LSB match is not achievable by an 8-iteration
   fixed-point power method against an exact `eigh` reference in general,
   even with the ZDIAG widening — see "ZDIAG widening" note in
   `planning/blocks/Training Accumulator.md` for what that fix did and did
   not close.
3. `COMB_POST_GAIN_SHIFT` is written before `W_COMMIT` for every packet.
4. For a strong-signal Z (A_est > 64), `pgs = 0` and `W_max_byte < 120`; the
   combiner output does not saturate.
5. For a weak-signal Z (A_est = 4), `pgs ∈ {2,3}` and combiner output is
   between 20 and 90 counts.
6. If `N_ACC == 0`, no weight write, no `COMB_CFG` write, and no commit occurs.
7. The implementation fits within the 4 KiB SRAM budget alongside the rest of
   the firmware (check with `make` → `size` output).

---

## Reference Files

| File | Purpose |
|---|---|
| `firmware/picorv32/asic_regs.h` | Register address definitions — **stale**: uses an old memory-mapped AHB-Lite address scheme (`ASIC_REG_BASE + 0x00`–`0xEF`) that predates the current 7-bit SPI register map (`0x00`–`0x7F`). Do not use for new work; treat `planning/Register Map.md` as authoritative until this header is resynced. |
| `firmware/picorv32/main.c` | Existing firmware structure to extend |
| `sim/models/training_accumulator.py::compute_eigvec_weights()` | Float reference |
| `planning/Register Map.md` | Authoritative register layout |
| `planning/Firmware Spec.md` | Broader firmware context |
