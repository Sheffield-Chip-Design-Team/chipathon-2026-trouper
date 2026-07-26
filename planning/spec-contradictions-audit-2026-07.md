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

**All 31 items closed 2026-07-26.** Item 8 closed on branch `feat/noise-weighted-mrc`;
the rest on `audit/2026-07-26`. Three items turned out to be materially wider or
different than recorded rather than simple reconciliations — 15 (the truncation term was
overstated by ~1.7 dB and was the wrong *kind* of quantity), 21 (PSRAM utilisation was
~2.3× optimistic), and 22/26 (both stated premises that had already been measured false).

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
| 9 | closed 2026-07-26 | **PSRAM init trigger: reset vs firmware** |

TRPR-PSR-001 anchored init to "within 1 ms of RESETB de-assertion"; TRPR-SYS-018 said init
happens only once firmware sets `PSRAM_CTRL.PSRAM_EN=1`, "not automatically on reset".
Mutually exclusive.

RTL settles it for TRPR-SYS-018: `init_start = rb_psram_ctrl[0] & ~rb_psram_ctrl[3]`
(`trouper_top.v:473`) — i.e. `PSRAM_EN & ~QSPI_OWNER`. Nothing keys off reset.

*Resolution (2026-07-26):* TRPR-PSR-001's 1 ms budget is now measured from the
`init_start` trigger, with the register expression cited and the firmware-owned ≥150 µs
tPU delay cross-referenced (Open Risks #27.1).

| # | Status | Item |
|---|---|---|
| 10 | closed 2026-07-26 | **PSRAM enable/default policy was ambiguous** |

TRPR-SYS-017/018 made PSRAM mandatory ("board designs without PSRAM are not supported")
while `Register Map.md` called `PSRAM_EN` "enable **optional** same-packet PSRAM
buffering/replay" with reset 0, and TRPR-PSR-009 framed disable as bring-up-only. Not a
hardware contradiction — a mandatory fitted device can default disabled — but no document
stated the operating policy.

*Resolution (2026-07-26):* the policy is now stated once, in TRPR-PSR-009, with the other
rows deferring to it: the device is mandatory on the board; `PSRAM_EN=0` is the intended
reset state precisely because firmware owns the ≥150 µs tPU delay; normal operation is
reset → wait tPU → `PSRAM_EN=1` → same-packet MRC; a sustained 0 is factory-test/bring-up
only. The map now says "optional" applies to the register default, never the board.

| # | Status | Item |
|---|---|---|
| 11 | closed 2026-07-26 | **`PSRAM_STATUS.STATE=IDLE` is not a state** |

TRPR-PSR-017 and two places in `Register Map.md` gated debug readback on `STATE=IDLE`.
The enumeration is `0=UNINIT, 1=QE_INIT, 2=WRITE, 3=REPLAY` — no IDLE encoding.

RTL supplies the right gate, and it is a single signal rather than the guessed
`packet_active=0`: `dbg_busy = QSPI_OWNER | packet_active | dbg_fetch_busy |
!qe_init_done` (`psram_buf_ctrl.v:210`), already folding in all four blockers.

*Resolution (2026-07-26):* TRPR-PSR-017 and both map sites now gate on `DBG_BUSY=0`
(0x75[7]), and the `STATE` row states outright that no IDLE encoding exists.

**Recurrence, worth noting:** this exact error was already fixed once, in TRPR-PSR-011 on
2026-07-06 (`Traceability.md:166`, "effect only at `STATE=IDLE`" → "at the next QPI burst
boundary"). The same phrase survived in two other rows. A grep for `STATE=IDLE` would have
caught it then; it does now.

| # | Status | Item |
|---|---|---|
| 12 | closed 2026-07-26 | **Sticky-flag clear lists disagreed three ways** |

TRPR-PSR-007 listed OVERFLOW / REPLAY_MISSED / SAMPLE_SKIP; `Register Map.md`'s
`PSRAM_CLR_ERR` row listed only the first two; its `W_COMMIT_LATE` and `SAMPLE_SKIP` rows
each claimed `PSRAM_CLR_ERR` clears them, so the map contradicted itself too.

RTL settles it — `psram_buf_ctrl.v:320-325` clears exactly **four** flags on `clr_err`:
`overflow`, `replay_missed`, `w_commit_late`, `sample_skip`. So no document had the full
list; the union of the map's scattered rows was right and each individual list was short.
`w_commit_late` is additionally cleared at packet start (`:461`).

*Resolution (2026-07-26):* TRPR-PSR-007 and the `PSRAM_CLR_ERR` map row both now name all
four flags with their addresses, citing the RTL line.

| # | Status | Item |
|---|---|---|
| 13 | closed 2026-07-26 | **`ENERGY_GATE_EN` lived in a register that no longer exists** |

TRPR-SCD-015 told firmware to leave `ENERGY_GATE_EN` (SC_CFG bit 0) at 0, while
`Register Map.md` lists `SC_CFG.ENERGY_GATE_EN` under *Removed registers*. Confirmed
against `reg_bank.v`: neither `SC_CFG` nor `ENERGY_THR` exists anywhere in the RTL — both
went with `noise_est.v`. There was no bit to write.

*Resolution (2026-07-26):* TRPR-SCD-015 marked **REMOVED**, recording that pre-SC-lock
energy gating is neither implemented nor planned.

| # | Status | Item |
|---|---|---|
| 14 | closed 2026-07-26 | **AHB-Lite: three incompatible statements of the control interface** |

- §1 said Trouper "does not embed … an on-chip AHB-Lite master/slave fabric"; byte interface instead.
- §5 mandated a full 32-bit AHB3-Lite slave with a signal-level contract.
- TRPR-REG-002 said "an AHB-Lite slave with 8-bit address and 8-bit data" — neither of the above.

RTL settles it in §1's favour: `trouper_top` exposes `GRP_ADDR[7:0]`, `GRP_WDATA[7:0]`,
`GRP_WE`, `GRP_RE`, `GRP_RDATA[7:0]`, `GRP_READY` as flattened single-bit ports
(`trouper_top.v:69+`) and contains **no `H*` signal at all**. TRPR-REG-002's 8-bit AHB was
a third design appearing nowhere else, in RTL or documentation.

*Resolution (2026-07-26):* TRPR-REG-002 rewritten to describe the shipped `GRP_*` byte
request/acknowledge bus with Grouper priority, stating explicitly that it is not AHB-Lite.
§5 keeps its signal-level contract but gains a status banner retitling it as the target for
the **Grouper-side** adapter (TRPR-INT-001), not a description of Trouper's pins, and the
section heading changes from "On-Chip AHB-Lite + Host SPI" to "Grouper byte bus + Host
SPI".

| # | Status | Item |
|---|---|---|
| 15 | closed 2026-07-26 | **Preamble length / training-window length** |

TRPR-WGN-004 (`:259`) assumes a 12.25-symbol preamble with 8 consumed by training.
`blocks/Correlator Bank.md:126` and `DSP Chain SNR Loss Budget.md:78` assume an
8-symbol preamble with only **5 of 8** accumulated — and the loss budget books a
**−2.2 dB truncation loss** against that. `Test Plan.md:82` encodes the 5-symbol
version as a pass criterion (`n_acc == (8 − SC_HITS_REQ − 1) × M`). The spec's TACC
window (`timing_ref + TACC_WINDOW_SYMS × M`, default 8) gives 8 symbols.

**The −2.2 dB line item in the SNR loss budget may be stale by an entire design
change** — worth re-deriving, not just re-wording.

*Resolution (2026-07-26):* re-derived, not reworded. The item turned out to be two
separate things, and the "12.25 vs 8 symbols" half was **not** a contradiction.

**The 12.25/8 conflict dissolves.** `blocks/Weight Generation.md:256` already
documents 12.25M as *total pre-payload* overhead — 8 upchirps + 2 sync words +
2.25 downchirps — of which only the 8 upchirps are usable for symbol-period
autocorrelation. TRPR-WGN-004's "training window consumes 8 of the 12.25 preamble
symbols" and the block docs' "8-symbol preamble" are the same design stated at
different scopes. TRPR-WGN-004 now spells the 8 + 2 + 2.25 breakdown out, since it
had also called the residual 4.25 symbols "preamble symbols" when they are the sync
words and downchirps.

**The window arithmetic settles at `5M − 1`, and the 5-of-8 docs were right.**
`training_acc.v:247-249` places the window at `[timing_ref, timing_ref +
TACC_WINDOW_SYMS·M − 1]` but accumulates forward from arming at `sc_lock`, which
is already `(SC_HITS_REQ + 1)·M` past `timing_ref`. With the reset defaults
(`reg_bank.v:170` `sc_hits_req = 2`, `:186` `tacc_window_syms = 8`, clamped ≥ 8 on
write at `:240`) that is `n_acc = 5M − 1`. `Test Plan.md`'s
`(8 − SC_HITS_REQ − 1) × M` was right to within the one sample the RTL actually
drops; the criterion now carries the `−1`, which `cocotb/tests/test_trouper_top.py`
already asserts (as `7M − 1`, in its `SC_HITS_REQ = 0` configuration).

**The −2.2 dB was wrong twice over.** First it was the wrong ratio: it is the
`5M → 3M` entry of the late-lock table in `blocks/Training Accumulator.md`
(`10·log₁₀(3/5) = −2.2 dB`), mis-transcribed onto the `8M → 5M` baseline step,
which is `10·log₁₀(5/8) = −2.04 dB`. Second, and the reason re-deriving mattered
rather than correcting 2.2 to 2.04: **a training-SNR ratio is not a chain SNR
loss.** Every other line in that budget is SNR the demodulator loses. A shorter
window does not attenuate anything — it makes the channel *estimate* noisier, and
MRC is only weakly sensitive to that. Truncating 8M → 5M multiplies the
estimate-error term by 8/5, so it scales an already-small full-window estimation
loss by ≈1.6 instead of subtracting 2 dB from the link.

Measured (4000 Rayleigh trials/point, new script
`sim/sims/truncation_loss_rederive.py`): the post-combining increment is
**−0.46 dB worst case at SF7 / −16 dB per antenna**, −0.14 dB at SF9, −0.03 dB at
SF12, and under 0.02 dB above −10 dB per antenna. On the *shipped* fixed-point
firmware path it is smaller still (**−0.21 dB** worst case), because the
8-iteration power-method residual already dominates the estimate error. So the
budget was overstating this term by roughly 1.7 dB — the largest single error
found in the whole audit. **Book −0.5 dB.**

Landed in all three required places plus two more: the budget row and a new
derivation note (`DSP Chain SNR Loss Budget.md` §6), `blocks/Correlator Bank.md`
(which additionally claimed the accumulator uses "all 8 preamble symbols" — it
uses 5), `Test Plan.md` Block 4, the late-lock table in
`blocks/Training Accumulator.md` (now explicitly labelled as training-SNR ratios,
with the mis-transcription recorded so it cannot recur), and
`sim/notebooks/11_training_accumulator.ipynb` §2.

**Also found**, while in `Test Plan.md` Block 3/4 — the two items flagged in
passing when 18-21 closed, fixed here since they sit in the same criterion:
Block 3 was still titled "Correlator Bank ×8" (there is one shared correlator
time-multiplexed over 4 branches), and Block 4's firmware criterion demanded
`W_COMMIT` "within the SF5/SF6 timing budget" — SF5/SF6 are out of scope
(`SF_CFG` range 7–12), and the real constraint is that live mode only fits SF9+,
so SF7/SF8 must be tested in PSRAM replay mode (TRPR-WGN-004).

---

## Tier 3 — whole documents left behind by design changes

| # | Status | Item |
|---|---|---|
| 16 | closed 2026-07-26 | **`System Architecture.md` block diagram showed deleted hardware** |

Before resolution, `:124-125` instantiated "Frontend Buffer Controller / 1 kB rolling
SRAM" and wired PSRAM through it (`:170-172`). Spec §4.4 deletes that block;
TRPR-PHY-006 removes all on-chip SRAM. The replay path into the combiner — the
*primary* operating mode per TRPR-SYS-017 — was absent from the diagram entirely.

*Resolution (2026-07-26):* the `FBUF` node is replaced by `psram_buf_ctrl` (QPI circular
capture, SC delay reads at `write_ptr − M`, same-packet replay delay line) wired
directly to the external APS6404L. The replay path is now drawn: a `replay_active` mux
at the combiner input selects `rpl_*` from the PSRAM controller over the live `dc_removal`
output, matching `trouper_top.v:534-537`. Signal names were re-checked against RTL while
redrawing, which corrected three further diagram errors: `buf_freeze` is shown no longer
(the `packet_ctrl_fsm` output is deliberately dangling — `trouper_top.v:277`, "unused
without fbuf"), `safe_switch` no longer exists as a `packet_ctrl_fsm` output at all, and
an edge pointed at an undeclared `IRQC` node instead of `IRQO`.

| # | Status | Item |
|---|---|---|
| 17 | closed 2026-07-26 | **`System Architecture.md` specified the CLK_16M generated clock** |

Before resolution, `:288-303` documented two clock domains, a
`create_generated_clock -divide_by 2` SDC snippet, and listed `frontend_buf_ctrl` among
16 MHz blocks; the CDC table added two IQ_CLK↔CLK_16M crossing rows. Spec §3.1 (`:78`)
supersedes all of it — single clock net, `ce_16m` clock-enable, no generated clocks —
and TRPR-PHY-014 *forbids* that SDC construct. It was the highest-priority Tier 3 item
because it was directly actionable-wrong for anyone writing constraints.

*Resolution (2026-07-26):* the section is rewritten as "Clocking, timing tiers, and
asynchronous boundaries" and now mirrors spec §3.1's three *constraint* tiers
(full-rate 31.25 ns / paced-TDM MCP=3 93.75 ns / CE-gated MCP=2 62.5 ns), states
explicitly that there are no internal clock domains and no core CDC, and replaces the
generated-clock snippet with the TRPR-PHY-014 contract (`create_clock -period 31.25`
plus scoped MCPs, no generated clocks, no blanket override). The two CLK_16M crossing
rows are deleted, leaving the host SPI interface as the only asynchronous boundary.
The stale `frontend_buf_ctrl` and `sd_decimator_cic_tdm8` names are gone from the tier
table, and the obsolete "pipeline the sc_detector TDM accumulator" fix note with them.

| # | Status | Item |
|---|---|---|
| 18 | closed 2026-07-26 | **`Test Plan.md` Blocks 7/8/9 tested hardware Trouper does not have** |

Block 7 required extended firmware-load SPI opcodes `0x01`/`0x02`, a `CPU_RESET` boot
sequence, CPU SRAM banks `BANK0`–`BANK2`, a reserved `BANK3`/`CPU_SRAM_BORROW_BANK` and
per-bank BIST registers. Block 8 was an entire SPI-master-to-SX1257 test. Block 9 required
W "within one LoRa symbol period of correlator lock", an `H`/`N₀` register interface, and
NT=2 mode auto-switch. §4.11 removed the extended frame, §3.x removed the CPU,
TRPR-SPM-001 removed the SPI master, and TRPR-WGN-004 marks the one-symbol constraint
superseded.

*Resolution (2026-07-26):* Block 7 rewritten around what is actually tested (reset/access
sweep, W-shadow write-lock, mid-packet write gates, SPI CDC suite, Grouper arbitration).
Blocks 8 and 9 retired into a single section that states why each is untestable and maps
every old concern onto its current coverage — `test_weight_gen_spi_flow.py`, the
Eigenvector Timing Budget, the PSRAM replay suite, `test_w_missed_packet.py` — or marks it
software-owned / out of scope.

**Also swept, same defect class:** Block 2 tested `ENERGY[n]` registers and a lock-latched
energy snapshot, both removed with `noise_est.v` — retargeted to `ZDIAG_k / n_acc` and the
`TACC_NOISE_TRIG` noise window. The integration matrix's borrow-bank rows became PSRAM
replay and late-commit rows, and its NT=2 ALMMSE / mode-auto-switch rows became a
noise-weighted-MRC row. Two NT=2 ALMMSE rows in the Block 5 matrix are struck through as
out of scope.

| # | Status | Item |
|---|---|---|
| 19 | closed 2026-07-26 | **`Firmware Spec.md` memory map listed removed peripherals** |

The CPU memory map placed an SPI master peripheral, an IRQ controller and a JTAG/SWD TAP
"in Trouper" at `0x00010100`–`0x000103FF`. None exists: TRPR-SPM-001 removed the SPI
master, §4.16 removed JTAG, and interrupt aggregation is not a peripheral — it is the
sticky `IRQ_STATUS` register inside `reg_bank` (`0x02`, cleared via `0x03`).

*Resolution (2026-07-26):* the three entries are deleted and replaced with the single
`GRP_*`-reached register window, corrected to **128 bytes** (`0x00010000`–`0x0001007F`) —
the old map also implied a 256-byte window, but the register map is 7-bit.

| # | Status | Item |
|---|---|---|
| 20 | closed 2026-07-26 | **`DSP Flow.md` key-constraints table was pre-half-band** |

The table advertised "Decimation ratios R=256, 128, 64, 32", a 512 B Frontend Buffer SRAM,
"SC detection window L = min(M,256)", SF6 assumptions and a `< 5,000 cycles` firmware
weight budget, while `:84-91` of the same file correctly described the fixed R=64 chain.

*Resolution (2026-07-26):* table rewritten to fixed R=64 with BW selected by
`sample_shift`, `M = 1 << (SF + sample_shift)`, the PSRAM delay line and its 19-of-64
cycle cost, and the measured 2.08/2.28 ms weight-compute figures with the SF9+ live-mode
consequence.

**Wider than the audit recorded.** Fixing only the table would have left it contradicting
its own document, so two further stages were rewritten: **Stage 4** was still titled
"Frontend Buffer Controller" and described a block-based fixed-L buffer in a 512×8 SRAM
macro accepting 3–12 dB sub-symbol integration loss at SF9–SF12 — now the PSRAM full-M
delay line, where that loss does not arise; and **Stage 5**'s autocorrelation was still
`L = min(M, 256)`, now the full symbol period, with the `sc_ant_sel` branch selection and the
ant0 deep-fade risk cross-referenced. `CPU_RESET` removed from both `:30` and the AGC
section.

| # | Status | Item |
|---|---|---|
| 21 | closed 2026-07-26 | **`Memory Strategy.md` had residual Trouper content past its own banner** |

The document carries a superseded-banner for Trouper, but `:177` still asserted a live
"Frontend Buffer Controller FSM" timing budget across R=256/128/64/32, and `:45-51` gave a
PSRAM utilisation of **~38%** from ~1 µs write / ~0.5 µs read timings that match no
controller behaviour.

*Resolution (2026-07-26):* the PSRAM section now derives utilisation from the actual
sub-cycle budget — **69%** for capture + SC detection (44/64) and **88%** for capture +
replay (56/64), the replay phase being the binding case. That is materially tighter than
the ~38% the document claimed, and worth knowing before anyone proposes adding PSRAM
traffic. The frontend-buffer FSM paragraph is banner-annotated as historical, marked
*(superseded)*, and its tenses moved to the past; the R=32 / 1 MS/s extrapolation is
flagged out of scope.

---

## Tier 4 — minor

| # | Status | Item |
|---|---|---|
| 22 | closed 2026-07-26 | **TRPR-PHY-008 accepts an SS band never achieved.** `:596` accepts "−7 to −10 ns at MCP=2". `Open Risks.md` records best measured −12.11 ns (item 39) and official signoff −25.39 ns. |
| 23 | closed 2026-07-26 | **MCP tier mismatch.** PHY-008 says MCP=2; §3.1 / TRPR-SYS-015 put TDM cones at MCP=3 and only the control plane at MCP=2. |
| 24 | closed 2026-07-26 | **Register-map occupancy arithmetic.** `Register Map.md:113` says "110 implemented + 18 reserved = 128"; the map lists 13 reserved slots (`0x04–0x07`, `0x1A–0x1B`, `0x79–0x7E`, `0x7F`) → 115 + 13. |
| 25 | closed 2026-07-26 | **Register name mismatch.** TRPR-REG-006 (`:448`) names the bit's register `RX_GAIN_COMMIT 0x18[0]`; the map calls the register `RX_GAIN_CTRL`. Cosmetic. |
| 26 | closed 2026-07-26 | **Die-target drift.** TRPR-SYS-009 / PHY-003 target 1100×1100; all current signoff work in `Open Risks.md` runs 1200×1100. Target vs actual — spec doesn't acknowledge the gap. |

*Resolution (2026-07-26), items 22–26.* Two of these were cosmetic as recorded; three
were not.

**22 + 23 are one row and one root cause.** TRPR-PHY-008's "−7 to −10 ns at MCP=2" is
wrong on both halves, and both halves come from the same place: the row was never
updated after the blanket-MCP era ended. `Physical Design Change List.md:883` is the
origin — that band was measured on a **blanket** `set_multicycle_path 2` SDC, at 630 k
µm² cell area, on a 1100×1100 die. All three premises are gone. The blanket exception
was replaced by the scoped mixed set in `pnr_32m_scoped_v25_b6.sdc` (verified by
reading it: MCP=3 on the four paced TDM cones plus the quasi-static
`sc_detector`/`packet_ctrl_fsm`/`training_acc` control arcs; MCP=2 only on the
`reg_bank` write bus and barrel-shift registers — i.e. exactly TRPR-SYS-015's tiering,
so item 23 resolves in SYS-015's favour). Measured SS WNS under the honest set: best
ever **−12.11 ns** (jobs 3403/3404), **−14.91 ns** on the three 2026-07-25 runs (read
from `RUN_2026-07-25_14-{35-07,35-09,41-00}/*-openroad-stapostpnr/max_ss_125C_3v00/wns.max.rpt`,
all identical, TNS −5747 ns), and **−25.39 ns** for the older official figure
`Open Risks.md` #1 still treats as blocking. PHY-008 now states the accepted band as
the measured **−12 to −15 ns** and forbids claiming better without a citable run.
The historical entry is annotated rather than rewritten, so the provenance survives:
**a tighter number there is not progress, it is the blanket exception hiding paths.**

**24 — both terms were wrong; only the sum was right.** Counted the main map table
programmatically: **115 implemented + 13 reserved = 128**, exactly as predicted.
"110 + 18" summed correctly by coincidence, which is why it survived review.

**25 — cosmetic, but the reverse of how it was recorded.** There is no name conflict:
`RX_GAIN_CTRL` is the register at `0x18` and `RX_GAIN_COMMIT` is its bit [0]. The
defect is that TRPR-REG-006 listed three of its five W1P entries by bit name and two in
`REGISTER.BIT` form, which reads as though `RX_GAIN_COMMIT` and `PSRAM_CLR_ERR` were
registers of their own. Normalised all five to `REGISTER.BIT`, noting that only
`TACC_NOISE_TRIG` has an address to itself; same fix applied to `Traceability.md:57`.

**26 — not drift; a measured hard wall.** The audit called this "target vs actual".
`planning/die-shrink-routability-floor.md` is stronger than that: at the current ≈974 k
µm² cell area, 1100×1100 sits at 93.8% effective utilisation and fails **global**
routing (GRT-0116 congestion at step 39) on every variant tried — Metal1 and Metal2 pin
layers, cell padding 0 and 1 (jobs 3242/3243/3245). So 1100×1100 is blocked on RTL area
reduction, not floorplan tightening. Both rows now state the as-built **1200×1100**
(`DIE_AREA [0,0,1200,1100]`, `config_current_signoff.json`) and keep 1100×1100 only as a
target contingent on the area roadmap.

Documentation only — no RTL or SDC was changed, so nothing needed re-verification.

---

## Additions from post-audit RTL/source check

| # | Status | Item |
|---|---|---|
| 27 | closed 2026-07-26 | **SC delay-read cycle budget was internally inconsistent** |

Before resolution, TRPR-FBC-001 called the delay read 30 cycles, while TRPR-PSR-014/018
and `blocks/PSRAM Buffer Controller.md:35` budgeted it as 19 cycles within `25 + 19 = 44`.
TRPR-FBC-004 then called it an "additional" read even though the 19-cycle read is already
inside that 44-cycle `S_WRITE` budget.

RTL settles it — `psram_buf_ctrl.v:184` lays out the sub-cycle FSM explicitly: write on
sub 0–24 (25 cycles), del-read on sub 25–43 (**19 cycles**), rpl-read on sub 25–55 (31).
So 19 is right and 30 was simply wrong; TRPR-PSR-014's 44/56 totals and 20/8 spare against
the 64-cycle `iq_valid` period were already correct.

*Resolution (2026-07-26):* TRPR-FBC-001 corrected to 19 cycles with the sub-cycle range
cited, stated once and cross-referenced to TRPR-PSR-014 rather than restated; TRPR-FBC-004
reworded to say the delay read is *part of* the 44-cycle budget, not an additional
transaction, and to note the 20 spare cycles are what debug readback is serviced from.

**Also found:** `psram_buf_ctrl.v`'s own header comment still carried the pre-half-band
**R=128 / 128-cycle** period with **84/72 spare** in two places — stale by the entire
half-band migration, and optimistic by 4× on margin. Corrected in both RTL trees to
64 cycles / 20 and 8 spare, matching TRPR-PSR-014. Comment-only; no functional change.

> *Merge note (2026-07-26).* `origin/main` had fixed this same comment independently, in
> the `psram_buf_ctrl` verification series, and its version is a superset — same 64-cycle
> and 20/8-spare numbers plus the finding that a debug fetch is a fixed 31 sub-cycles and
> so **cannot** fit the 20-cycle idle margin, colliding with the next capture write every
> time (harmless: `sample_skip` flags it; Open Risks #30, jobs 3548-3550). Main's block was
> kept on merge and this audit's narrower wording discarded; the item-31 `del_n_c` range
> fix below was re-applied on top, since main had not made that one. Two independent
> fixes landing on one comment is itself evidence the stale figure was conspicuous.
| 29 | closed 2026-07-26 | **TRPR-PCF-002/008 were normative SHALLs on a dead duplicate signal** |

Found while fixing item 16. `TRPR-PCF-008` required "`buf_freeze` SHALL de-assert and the
frontend buffer SHALL resume rolling capture" — a normative requirement on the on-chip
frontend buffer that TRPR-PHY-006 removed, same defect class as items 13 and 16.
`TRPR-PCF-002` required asserting the same output. Both were signed off in
`Traceability.md` against `test_w_missed_packet.py`, whose own row already recorded that
the signal "drives nothing in `trouper_top`".

Investigation showed `buf_freeze` was not merely dead but a **bit-identical duplicate of
`packet_active`** — same four assignment sites, same values — which the formal harness
had itself been asserting (`a_freeze_iff_not_idle` alongside `a_active_iff_not_idle`,
both `state != ST_IDLE`). Its only consumer, `frontend_buf_ctrl.v`, is no longer
instantiated in the design; four legacy `tb_dsp_chain_*` benches tie it to constant 0.

*Resolution (2026-07-26):* `buf_freeze` deleted from `packet_ctrl_fsm.v`,
`trouper_top.v` (both the `src/` and `rtl-test/rtl/` trees), the formal harness port and
assertion, and the B6 equivalence TB's compare vector. PCF-002/008 reworded to
`packet_active`, and the four regression assertions in `test_w_missed_packet.py`
retargeted to the same signal at the same four points, so FSM-contract coverage is
preserved. `packet_ctrl_fsm_ref.v` keeps the port — it is a frozen pre-B6 snapshot.
Verified: exact P&R file set elaborates clean, yosys `check` count unchanged from the
last signoff run (367, pre-existing `reg_bank` mem2reg artifacts), B6 equivalence TB
bit-identical across 40 packets, `w_missed` cocotb regression re-run (jobs 3603–3605).

| # | Status | Item |
|---|---|---|
| 30 | closed 2026-07-26 | **`blocks/Packet Control FSM.md` described a different FSM than the one implemented** |

Found while closing item 29. Beyond the `buf_freeze` rows, the document asserted: a
4-state FSM (RTL has 5 — `ST_ACQ_SETUP` was added for Open Risk #39); a `W_ACTIVE` shadow
bank promoted at IDLE (no such bank — the combiner reads the live W register file, per the
item-7 resolution); `W_valid` persisting across packets so a stale weight vector is reused
(RTL clears it on the timeout path into IDLE — every packet must earn its own commit); a
mid-packet `W_commit` being *queued to the next IDLE* (RTL applies it immediately, in
`W_PENDING` and in `PAYLOAD_ACTIVE`); FSM outputs `psram_packet_arm`,
`psram_replay_start`, `psram_abort`, `payload_rd_base`, `safe_switch`, `combiner_source`,
`noise_sample_en`, `noise_thresh` (all deleted from the RTL); packet-end detection off a
new `sc_lock` (structurally impossible — `sc_lock` is level-held until `sc_clr`); a 16 MHz
clock; `M = 2^SF`; and an entire "Per-branch noise floor estimation" section built on the
removed `noise_est` block. The interface table carried a 2026-07-12 banner admitting the
port list was stale, but the body sections were never corrected.

The two most consequential were the `W_valid` lifetime and the `W_commit` deferral, which
inverted real firmware-visible behaviour rather than merely naming dead signals.

*Resolution (2026-07-26):* document rewritten against `src/control/packet_ctrl_fsm.v` —
5-state machine with `packet_phase` encodings, the three down-counter deadlines with
their real spans (`tacc_span + 2M` / `+ 5M` / `PKT_TIMEOUT_SYMS × M`) and the B6
rationale, correct `W_commit` semantics, live port list, IRQ aggregation as actually done
in `trouper_top`, and a verification table marked with real job numbers plus two honest
coverage gaps (mid-payload `W_commit`, training timeout). `TRPR-PCF-001` corrected from
four states to five in the same pass.

| # | Status | Item |
|---|---|---|
| 28 | closed 2026-07-26 | **Eigenvector firmware timing was stale by about 2×** |

Before resolution, TRPR-WGN-004 said 8 iterations take ~1.0–1.1 ms and called SF7
"roughly break-even". The cycle-accurate measurement supersedes that: **33,283 cycles =
2.08 ms** at 16 MHz for rv32im, **36,458 = 2.28 ms** for rv32emc (the current Grouper
plan), SF-independent because the matrix is always 4×4 (`blocks/Eigenvector Weight
Computation.md` Timing Budget, SGE jobs 3333–3335; `Open Risks.md` #7).

*Resolution (2026-07-26):* TRPR-WGN-004 now carries the measured cycle counts and both
ISA figures, and states the consequence explicitly — replay mode's deadline scales with
payload so every supported SF fits, while live mode's `4·M / 500 kHz` deadline fits only
SF9+ (SF7 ~1.02 ms and SF8 ~2.05 ms both miss on either ISA), making replay mandatory
rather than optional for SF7/SF8. The 16-iteration split (rv32im clears SF9, rv32emc does
not) and the external-host lever with its unmeasured IRQ-latency caveat are recorded too.

**Also found:** `blocks/Eigenvector Weight Computation.md:558` contradicted its *own*
Timing Budget section 150 lines earlier, still saying "~1.0–1.1 ms … comfortable only
from roughly SF8 upward". Corrected to 2.08/2.28 ms and SF9+.


| # | Status | Item |
|---|---|---|
| 31 | closed 2026-07-26 | **`psram_buf_ctrl.v` commented the delay depth as `128..16384`; the in-spec range is `256..16384`** |

Noticed while closing item 27, not fixed. `psram_buf_ctrl.v:183` annotates
`del_n_c = 15'd1 << (sf[3:0] + sample_shift)` as "`2^(SF+shift), 128..16384`". The low
bound implies `SF+shift = 7`, which no in-spec configuration produces: `sample_shift` is
derived at the top level as `rb_bw_sel ? 2'd2 : 2'd1` (`trouper_top.v:177`), so it is
always 1 or 2 — never 0 — and `SF_CFG`'s documented range is 7–12 (`Register Map.md:35`).
The in-spec minimum is therefore `2^(7+1) = 256`.

**The reason this is worth more than a comment fix:** `128` *is* reachable, via
`SF_CFG = 6` — because `reg_bank.v:217` writes `sf_cfg <= wdata[3:0]` with **no range
clamp at all**, only a `packet_active` gate. The register accepts any 4-bit value, so
firmware can also write `SF_CFG = 13..15`, giving `SF + sample_shift` up to 17 — and
`15'd1 << 17` truncates to **zero** in the 15-bit `del_n_c`, which would collapse the SC
delay depth. Compare `TACC_WINDOW_SYMS` (`0x27`), which *is* clamped in `reg_bank`.

*Resolution (2026-07-26):* comment bound corrected to `256..16384 in-spec (SF_CFG 7-12,
shift 1..2)` in both RTL trees.

*Decision (2026-07-26, user):* the unclamped `SF_CFG` stays **a firmware
consideration** — no hardware clamp, and no `Open Risks.md` entry. Keeping `SF_CFG` in
7–12 is the controlling firmware's responsibility; writing 6 or 13–15 is out of contract
and its consequences (a short delay depth, or a `del_n_c` that truncates to zero above
`SF+shift = 15`) are not guarded against in hardware. Recorded here so the reasoning is
findable, since the register's own map row states the 7–12 range without saying it is
unenforced.

---

## Suggested fix order

1. ~~**Items 1–6 and 27–28**~~ — all closed 2026-07-26. Settled by RTL, arithmetic, or
   cycle-accurate measurement, exactly as expected; no judgement calls were needed.
2. ~~**Item 17**, then 16~~ — both closed 2026-07-26. `System Architecture.md` was the doc
   most likely to be read by someone writing SDC or a new block; its clocking section and
   block diagram now match RTL.
3. ~~**Item 15**~~ — closed 2026-07-26. Re-derived: the term is **−0.5 dB**, not −2.2 dB.
   ~~**Item 31**~~ — closed 2026-07-26; the unclamped `SF_CFG` half is accepted as a
   firmware responsibility (no hardware clamp, no `Open Risks.md` entry — user decision).
4. ~~**Items 7–14**~~ — all closed 2026-07-26 (item 8 on branch `feat/noise-weighted-mrc`).
5. ~~**Items 18–21**~~ — all closed 2026-07-26, as one pass. Each turned out to be wider than its recorded line range; see the individual entries.
6. ~~**Tier 4**~~ — items 22-26 closed 2026-07-26. Items 22/23 (PHY-008) and 26
   (die target) were substantive, not minor: both were stating premises that had
   been measured false.

Items 1, 2 and 3 also require reopening `Traceability.md:126-127`, `:158`, `:160`,
which currently certify the wrong values.
