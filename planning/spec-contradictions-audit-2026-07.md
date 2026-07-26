# Spec Contradiction Audit — 2026-07-26

Cross-document consistency sweep over the planning set. Nothing here is a new design
decision — every item is two documents (or two rows of one document) asserting
incompatible things about hardware that already exists. Where RTL settles the
argument it is cited.

**Documents in scope:** `Trouper Chip Specification.md`, `Register Map.md`,
`System Architecture.md`, `DSP Flow.md`, `Firmware Spec.md`, `Test Plan.md`,
`Memory Strategy.md`, `Traceability.md`, `Pinout.md`, `DSP Chain SNR Loss Budget.md`,
`blocks/Correlator Bank.md`, `blocks/PSRAM Buffer Controller.md`.

**Not found contradictory:** `Pinout.md` (26-pad count and inter-project wire list are
self-consistent and match spec §4.16 / TRPR-PHY-003).

Status column: `open` = not yet fixed. Update in place as items close.

---

## Tier 1 — wrong addresses or wrong numbers; would mislead firmware or signoff

| # | Status | Item |
|---|---|---|
| 1 | closed 2026-07-26 | **`CORR_MAG_n` / `C_POOL_I/Q` claimed addresses that are live Z registers** |

Before resolution, TRPR-SCD-011/012 reserved `CORR_MAG_n` at `0x48–0x4F` and
`C_POOL_I/Q` at `0x64–0x67`, "tied to zero." The active map assigns `0x48` to
`Z_02_I`, `0x4C–0x51` to `Z_03`, and `0x64–0x6F` to `ZDIAG_0..3`.

RTL settles it: `rtl-test/rtl/reg_bank.v:366` returns `zpair_i1[15:8]` at `0x48`;
`:402` returns `zdiag_0[31:24]` at `0x64`. The stale spec rows could have caused
firmware to treat real ZDIAG data as reserved zeros.

Before resolution, `Traceability.md` incorrectly signed both requirements off by
inspection as matching the Register Map.

*Resolution (2026-07-26):* TRPR-SCD-011/012 are now marked REMOVED with their former
addresses explicitly reallocated to `Z_02`/`Z_03` and `ZDIAG_0`/`ZDIAG_1`. The Register
Map former-address rows and both Traceability rows now record the same disposition.

| # | Status | Item |
|---|---|---|
| 2 | closed 2026-07-26 | **PSRAM write-rate arithmetic used the pre-half-band sample rate** |

Before resolution, TRPR-PSR-013 used "4 channels × 2 bytes × **250 000 S/s** =
2 MB/s" even though the decimator output is 500 kS/s. The correct figure is
**4 MB/s (32 Mbit/s)**, ~6% of device capacity.

*Resolution (2026-07-26):* corrected TRPR-PSR-013, the PSRAM Buffer Controller
block summary, and Traceability to 500 kS/s / 4 MB/s / 32 Mbit/s / ~6%.

| # | Status | Item |
|---|---|---|
| 3 | closed 2026-07-26 | **PSRAM buffer-capacity worst case ignored `sample_shift`** |

Before resolution, TRPR-PSR-015 used "8 × 2^12 × 8 bytes = 256 kB" at SF12.
But `M = 1 << (SF + sample_shift)`, so SF12/125 kHz is 2^14 = 16384
samples/symbol → 8 × 16384 × 8 = **1 MiB**. §4.10.2 (`:367`) already states
the correct `M = 16384` delay depth. The APS6404L still has ≥8× headroom, so this
is not a design break.

*Resolution (2026-07-26):* corrected TRPR-PSR-015, Traceability, and the matching
Open Risks proof-bound note to 1 MiB maximum occupancy / ≥8× headroom.

| # | Status | Item |
|---|---|---|
| 4 | closed 2026-07-26 | **`N_ACC` was 16-bit in stale software-flow text, 18-bit elsewhere** |

Before resolution, the weight-flow pseudocode in `Trouper Chip Specification.md`
said "16-bit N_ACC (0x21–0x22)." TRPR-TAC-003, TRPR-AGC-001, and `Register Map.md`
all specify the full 18-bit count across `0x21–0x23`. Firmware following the stale
text would drop the two MSBs and mis-scale `Zdiag/n_acc` at SF11–12.

*Resolution (2026-07-26):* corrected the specification pseudocode and all three
stale reads in `blocks/Eigenvector Weight Computation.md` to use the full 18-bit
`N_ACC` representation at `0x21–0x23`.

| # | Status | Item |
|---|---|---|
| 5 | closed 2026-07-26 | **`SC_HITS_REQ` semantics differed by one across documents** |

- Spec TRPR-SCD-004/008 (`:169,173`): lock after `SC_HITS_REQ+1` hits; values 1–3 mean 2–4 hits.
- `Register Map.md:40,227`: "Consecutive SC hits required for `sc_lock`, valid range 1-3" omits the hardware's `+1` convention, so it is ambiguous rather than an explicit contrary assertion.
- `blocks/Correlator Bank.md:230`: "asserts `sc_lock` when count reaches `SC_HITS_REQ`" is contrary in isolation, although that document's timing formula (`:123`) retains the required `+1`.

The `timing_ref` back-calculation `lock_sample − (SC_HITS_REQ+1)·M + 1` appears in
both the spec and Correlator Bank and only makes sense under the spec's reading. RTL
settles it: `sc_detector.v:440-450` locks when `hit_count == sc_hits_req`, after
counting the current hit, i.e. after `SC_HITS_REQ+1` hits.

*Resolution (2026-07-26):* corrected the map and affected DSP/block documentation to
state the encoded `+1` convention. Values 1–3 are the supported normal 2–4-hit
settings; raw 0 is explicitly documented as an unclamped, diagnostic-only one-hit
mode for controlled bring-up/characterisation.

| # | Status | Item |
|---|---|---|
| 6 | closed 2026-07-26 | **`SAMPLE_WIDTH` existed in the register map but was prohibited by the spec** |

Before resolution, `Register Map.md` defined `PSRAM_CTRL[2] SAMPLE_WIDTH` (16-bit vs
32-bit I/Q storage). `Trouper Chip Specification.md:389` (TRPR-PSR-005) specifies
fixed 8-byte samples and no other implemented storage width. RTL confirms bit [2] is
stored/read back in `reg_bank` but has no downstream consumer; its former 1 MS/s claim
was also out of scope.

*Resolution (2026-07-26):* `0x70[2]` is now documented as reserved/inert, with
firmware directed to write 0. The map and PSRAM block document explicitly state that
the retained readback bit has no functional effect and storage is fixed at 8 bytes per
sample. No RTL change was made.

---

## Tier 2 — real contradictions, lower blast radius

| # | Status | Item |
|---|---|---|
| 7 | closed 2026-07-26 | **Shadow-vs-active weight-bank mechanism differed between spec and RTL** |

Before resolution, TRPR-MRC-004 and TRPR-PCF-004 said weights were promoted atomically
to `W_ACTIVE`, while `Register Map.md` correctly said the combiner reads the W bank
directly with no separate active copy and write-locks it while `W_VALID`.

*Resolution (2026-07-26):* the specification now matches RTL: `W_COMMIT` asserts
`W_VALID`; the combiner reads the live W bank; and writes while valid are rejected with
sticky `W_WR_REJECTED` (`0x1E[5]`).

| # | Status | Item |
|---|---|---|
| 8 | closed 2026-07-26 | **ALMMSE terminology conflicted with the NT=1 weight-mode scope** |

Before resolution, TRPR-WGN-006 called eigenvector mode "not ALMMSE," while
TRPR-AGC-005 and `Register Map.md` described the noise EMA as feeding "ALMMSE" with
`w_k ∝ h_k/σ²_k`.

*Resolution (2026-07-26):* the NT=1 option is now explicitly named **noise-weighted
MRC** (TRPR-WGN-012): inverse-variance scaling of conventional MRC weights. It is
documented as the diagonal-noise MMSE special case, not a full ALMMSE/multi-user
detector; full NT≥2 ALMMSE remains out of scope.

| # | Status | Item |
|---|---|---|
| 9 | open | **PSRAM init trigger: reset vs firmware** |

TRPR-PSR-001 (`:353`): init "SHALL complete within 1 ms of RESETB de-assertion".
TRPR-SYS-018 (`:66`): init happens only once firmware sets `PSRAM_CTRL.PSRAM_EN=1`,
"**not automatically on reset**" (RTL enforces no on-chip tPU wait). Mutually
exclusive. See also `project_startup_delay_risks` / Open Risks #27.1.

| # | Status | Item |
|---|---|---|
| 10 | open | **PSRAM enable/default policy is ambiguous** |

TRPR-SYS-017/018 make PSRAM mandatory ("Board designs without PSRAM are not
supported"). `Register Map.md:421` calls `PSRAM_EN` "enable **optional** same-packet
PSRAM buffering/replay", reset 0; TRPR-PSR-009 frames disable as bring-up-only. This
is not necessarily a hardware contradiction — a mandatory fitted device can default
disabled for bring-up — but the intended operating policy is not stated consistently.
State explicitly that PSRAM is mandatory on the board while `PSRAM_EN=0` is the
intentional reset/bring-up state, and that normal same-packet MRC enables it after
the tPU delay.

| # | Status | Item |
|---|---|---|
| 11 | open | **`PSRAM_STATUS.STATE=IDLE` is not a state** |

TRPR-PSR-017 (`:402`) and `Register Map.md:443` gate debug readback on `STATE=IDLE`.
The enumeration at `Register Map.md:433` is `0=UNINIT, 1=QE_INIT, 2=WRITE, 3=REPLAY`.
No IDLE encoding exists. (`packet_active=0` is presumably the intended condition.)

| # | Status | Item |
|---|---|---|
| 12 | open | **Sticky-flag clear lists disagree three ways** |

- TRPR-PSR-007 (`:355`): `PSRAM_CLR_ERR` clears OVERFLOW, REPLAY_MISSED, **SAMPLE_SKIP**.
- `Register Map.md:422`: only OVERFLOW and REPLAY_MISSED.
- `Register Map.md:314`: `W_COMMIT_LATE` is *also* cleared by `PSRAM_CLR_ERR`.

(`Register Map.md:434` separately says SAMPLE_SKIP clears via `PSRAM_CLR_ERR`, so the
map contradicts itself as well.)

| # | Status | Item |
|---|---|---|
| 13 | open | **`ENERGY_GATE_EN` lives in a register that no longer exists** |

TRPR-SCD-015 (`:180`): "`ENERGY_GATE_EN` (SC_CFG bit 0) is reserved … SHALL be left at
0." `Register Map.md:467` lists `SC_CFG.ENERGY_GATE_EN` under **Removed registers**.
There is no bit to leave at 0.

| # | Status | Item |
|---|---|---|
| 14 | open | **AHB-Lite: three incompatible statements of the control interface** |

- §1 (`:23`): Trouper "does not embed … an on-chip AHB-Lite master/slave fabric"; byte interface instead.
- §5 (`:510-573`): mandates a full 32-bit AHB3-Lite slave with a signal-level contract.
- TRPR-REG-002 (`:444`): "register bank **SHALL be an AHB-Lite slave with 8-bit address and 8-bit data**" — neither of the above.

`Pinout.md` and `Register Map.md` describe the `GRP_*` byte bus as current, and §5.2's
implementation note acknowledges the adapter is pending (TRPR-INT-001). The unexplained
one is TRPR-REG-002's 8-bit AHB, a third design appearing nowhere else.

| # | Status | Item |
|---|---|---|
| 15 | open | **Preamble length / training-window length** |

TRPR-WGN-004 (`:259`) assumes a 12.25-symbol preamble with 8 consumed by training.
`blocks/Correlator Bank.md:126` and `DSP Chain SNR Loss Budget.md:78` assume an
8-symbol preamble with only **5 of 8** accumulated — and the loss budget books a
**−2.2 dB truncation loss** against that. `Test Plan.md:82` encodes the 5-symbol
version as a pass criterion (`n_acc == (8 − SC_HITS_REQ − 1) × M`). The spec's TACC
window (`timing_ref + TACC_WINDOW_SYMS × M`, default 8) gives 8 symbols.

**The −2.2 dB line item in the SNR loss budget may be stale by an entire design
change** — worth re-deriving, not just re-wording.

---

## Tier 3 — whole documents left behind by design changes

| # | Status | Item |
|---|---|---|
| 16 | open | **`System Architecture.md` block diagram shows deleted hardware** |

`:124-125` instantiates "Frontend Buffer Controller / 1 kB rolling SRAM" and wires
PSRAM through it (`:170-172`). Spec §4.4 deletes that block; TRPR-PHY-006 removes all
on-chip SRAM. The replay path into the combiner — the *primary* operating mode per
TRPR-SYS-017 — is absent from the diagram entirely.

| # | Status | Item |
|---|---|---|
| 17 | open | **`System Architecture.md:288-303` still specifies the CLK_16M generated clock** |

Documents two clock domains, a `create_generated_clock -divide_by 2` SDC snippet, and
lists `frontend_buf_ctrl` among 16 MHz blocks. Spec §3.1 (`:78`) explicitly supersedes
this — single clock net, `ce_16m` clock-enable, no generated clocks — and TRPR-PHY-014
*forbids* that SDC construct. **Highest-priority Tier 3 item:** directly
actionable-wrong for anyone writing constraints.

| # | Status | Item |
|---|---|---|
| 18 | open | **`Test Plan.md` Block 8/9 tests hardware Trouper does not have** |

`:147-161` requires extended firmware-load SPI opcodes, `CPU_RESET`, CPU SRAM banks,
and borrow-bank BIST registers. `:178` requires W "within one LoRa symbol period of
correlator lock". Spec §4.11 removed the extended frame, §3.x removed the CPU, and
TRPR-WGN-004 explicitly marks the one-symbol constraint superseded.

| # | Status | Item |
|---|---|---|
| 19 | open | **`Firmware Spec.md:78-82` memory map lists removed peripherals** |

SPI master, IRQ controller, and a JTAG/SWD TAP, all "in Trouper". Contradicts
TRPR-SPM-001 and §4.16.

| # | Status | Item |
|---|---|---|
| 20 | open | **`DSP Flow.md:288-292` key-constraints table is pre-half-band** |

"Decimation ratios R=256, 128, 64, 32", "Frontend Buffer SRAM 512 B", "SC detection
window L = min(M,256)", SF6 assumptions, `CPU_RESET` at `:279`. Everything above it in
the same file (`:84-91`) correctly describes fixed R=64.

| # | Status | Item |
|---|---|---|
| 21 | open | **`Memory Strategy.md` residual Trouper content past its own banner** |

Carries a superseded-banner for Trouper, but `:177` still asserts a live "Frontend
Buffer Controller FSM" timing budget at R=256/128/64/32, and `:45-51` gives a PSRAM
utilisation figure (~38%) that doesn't match TRPR-PSR-014's cycle budget.

---

## Tier 4 — minor

| # | Status | Item |
|---|---|---|
| 22 | open | **TRPR-PHY-008 accepts an SS band never achieved.** `:596` accepts "−7 to −10 ns at MCP=2". `Open Risks.md` records best measured −12.11 ns (item 39) and official signoff −25.39 ns. |
| 23 | open | **MCP tier mismatch.** PHY-008 says MCP=2; §3.1 / TRPR-SYS-015 put TDM cones at MCP=3 and only the control plane at MCP=2. |
| 24 | open | **Register-map occupancy arithmetic.** `Register Map.md:113` says "110 implemented + 18 reserved = 128"; the map lists 13 reserved slots (`0x04–0x07`, `0x1A–0x1B`, `0x79–0x7E`, `0x7F`) → 115 + 13. |
| 25 | open | **Register name mismatch.** TRPR-REG-006 (`:448`) names the bit's register `RX_GAIN_COMMIT 0x18[0]`; the map calls the register `RX_GAIN_CTRL`. Cosmetic. |
| 26 | open | **Die-target drift.** TRPR-SYS-009 / PHY-003 target 1100×1100; all current signoff work in `Open Risks.md` runs 1200×1100. Target vs actual — spec doesn't acknowledge the gap. |

---

## Additions from post-audit RTL/source check

| # | Status | Item |
|---|---|---|
| 27 | open | **SC delay-read cycle budget is internally inconsistent.** TRPR-FBC-001 (`Trouper Chip Specification.md:371`) calls the delay read 30 cycles, while TRPR-PSR-014/018 (`:362-363`) and `blocks/PSRAM Buffer Controller.md:35` budget it as 19 cycles within `25 + 19 = 44` cycles. TRPR-FBC-004 (`:374`) then calls this an “additional” read even though the 19-cycle delay read is already included in that 44-cycle `S_WRITE` budget. Use the RTL-measured/implemented transaction figure, state it once, and remove “additional.” |
| 28 | open | **Eigenvector firmware timing is stale by about 2×.** TRPR-WGN-004 (`Trouper Chip Specification.md:259`) says 8 iterations take ~1.0–1.1 ms and makes SF7 “roughly break-even.” The cycle-accurate measurement in `blocks/Eigenvector Weight Computation.md:374-448` and `Open Risks.md:723-730` supersedes that: 33,283 cycles = **2.08 ms** at 16 MHz for rv32im (2.28 ms for rv32emc). SF7 and SF8 miss the live deadline; only SF9+ fits. Update the normative requirement and its timing/risk references. |

---

## Suggested fix order

1. **Items 1–6 and 27–28** — unambiguous. Items 1–4 and 27–28 are settled by RTL,
   arithmetic, or cycle-accurate measurement; item 6 by `blocks/PSRAM Buffer Controller.md`.
   Item 5's `+1` convention is now confirmed in `sc_detector.v`.
2. **Item 17**, then 16 — `System Architecture.md` is the doc most likely to be read by
   someone writing SDC or a new block.
3. **Item 15** — re-derive the SNR loss budget's truncation term rather than reword it.
4. **Items 7–14** — spec/map reconciliation pass.
5. **Items 18–21** — bulk staleness; cheapest as one "delete the CPU-era sections" pass.
6. **Tier 4** — sweep up alongside the next spec revision.

Items 1, 2 and 3 also require reopening `Traceability.md:126-127`, `:158`, `:160`,
which currently certify the wrong values.
