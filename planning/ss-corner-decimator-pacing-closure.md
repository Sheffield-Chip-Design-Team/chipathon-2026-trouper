# SS-Corner Closure: DSP-Chain Multicycle Honesty + 16 MHz Clock-Enable Partition

**Status:** Prototype on branch `ss-mcp-pacing`; not yet merged to production RTL
**Date:** 2026-06-21 (decimator), 2026-06-22 (sc + tacc + combiner + reg_bank CE + u_psram analysis)
**Related:** `planning/decimator-hb-migration-impact-plan.md`, `planning/Physical Design Change List.md`, `planning/die-area-analysis.md`, `planning/sc-detector-ant0-fading-risk.md`
**RTL:** `sd_decimator_poly.v`, `sc_detector.v`, `training_acc.v`, `mrc_combiner.v`, `trouper_top.v`, `reg_bank.v`, `spi_slave.v`
**Configs:** `config_current_signoff_v9b.json` (winning decimator); `config_scoped_v9..v13c.json` (scoped SDC + CE partition)
**Benches:** `tb/tb_decimator_poly_equiv.v`, `tb/tb_training_acc_equiv.v`, + `*_ref.v` reference modules

> **Scope:** Part 1 (below) closes the **decimator** honestly and records two wrong
> turns. Later sections extend honesty to **sc/tacc/combiner**, then a **scoped SDC**
> that exposed the **control-plane** violators, the **16 MHz clock-enable partition**
> that closes the SPI/reg_bank write decode, the genuine residual (`u_psram` QSPI),
> a **routing-marginal** floorplan blocker, and the **corner-relaxation** analysis.

## Summary

The `gf180mcu_fd_sc_mcu7t5v0` FD cells fail 32 MHz timing at the slow corner
(`max_ss_125C_3v00`). For `trouper_top` the worst SS setup WNS was **−11.95 ns**
even with a blanket `MCP=3` (`pnr_32m_mcp_v6.sdc`). This work closes the
decimator's contribution **honestly** — SS WNS **−11.95 → +8.0 ns (MET)** — and
documents two wrong turns so they are not repeated.

**Winning recipe:** pure 3-cycle *pacing* of the half-band MAC (so `MCP=3` is
genuinely legitimate) + a *deterministic fanout fix* (`repair_design` splitting
the high-fanout `hb2_stream` select net per `MAX_FANOUT_CONSTRAINT=8`).

## Root cause

100 % of the 106 SS violators originated from three source registers, all
500 kS/s DSP datapaths clocked at 32 MHz:

| Source reg | Block | What | Worst slack (MCP=3) | # paths |
|---|---|---|---|---|
| `u_dec.hb2_stream` | decimator | HB2 9-tap constant-MAC select | −11.95 ns | 64 |
| `u_dec.hb1_stream` | decimator | HB1 7-tap constant-MAC select | −11.14 ns | 26 |
| `u_tacc.acc_pair` | training_acc | all-pairs cross-correlator | −3.10 ns | 12 |

The HB MAC is a ~40-level constant-multiply cone (`−27(a0+a7)+45(a1+a6)…`) driven
by a **140-fanout, unbuffered select net** (`hb2_stream[0]`: 12.2 ns Q-delay +
15.7 ns slew alone — ~17 ns of the 104 ns path). The original RTL advanced
`hb2_stream` **every clock**, so the MAC was functionally a *single-cycle* path;
the blanket `MCP=3` was therefore **functionally optimistic** (STA was told the
path had 3 cycles; the FSM gave it 1).

### Why the MAC does not need 32 MHz

The 1-bit ΣΔ IQ input is 32 MS/s and the CIC runs at 32 MHz, but the HB MAC sits
behind R=16 decimation, so it only needs results at:

| Stage | Input rate | Burst window | MACs/window | Clocks/MAC available |
|---|---|---|---|---|
| HB1 | 2 MS/s | 32 clk | 8 (4 ant × I/Q) | **4** (3 clean) |
| HB2 | 1 MS/s | 64 clk | 8 | **8** |

The honest MCP ceiling = window ÷ ops. **HB1 is the binding constraint** (only
R=16 deep → fires every 32 clocks → max ~4 cycles/MAC). HB2 has 8 cycles of
headroom. The original RTL wasted this by running one result per clock.

## What did NOT work (recorded so we don't repeat it)

### 1. Pure pacing alone — honest but insufficient
Holding the operands stable for 3 cycles and capturing the full combinational
MAC after 3 cycles makes `MCP=3` honest, but the 104 ns MAC still exceeds the
3-cycle budget (93.75 ns) → **−11.95 ns**. Pacing makes MCP=3 *correct*; it does
not by itself reduce the delay.

### 2. Pipelining the MAC — actively HARMFUL (do not do this)
Splitting the MAC into registered stages (`h_t*`, `h_sum`) aligned to the hold
**fragmented** the 3-cycle multicycle budget into three **1-cycle** segments.
Stage 1 (operands→`h2_t0`, the constant multiply) is ~74 ns but now gets exactly
**one** 31.25 ns cycle. It only appeared to pass because the blanket `MCP=3`
illegally handed a 1-cycle path 3 cycles — honest slack was ~**−43 ns**, *worse*
than the original. The reported "+12.16 ns MET" (config `…_v8b`) was an artifact
of that masking and is **invalid**.

> **Lesson:** For a *multicycle* scheme you want the whole MAC to soak up all N
> cycles. Inserting registers mid-MAC forces each piece into 1 cycle — the exact
> opposite of what helps. Pipelining only helps if taken *all the way* to stages
> that each meet 31.25 ns (≥4 balanced stages), which HB1's 4-clock budget barely
> allows and which removes MCP entirely — a different, heavier design.

## Winning approach

### RTL: pure 3-cycle pacing (`sd_decimator_poly.v`)
- `localparam MAC_WAIT = 2` + `hb1_wait`/`hb2_wait` counters hold each MAC index
  `MAC_WAIT+1 = 3` cycles; the *full combinational* MAC result is captured at
  `wait == MAC_WAIT`. No mid-MAC registers.
- **HB1 centre-tap snapshot** (`h1bc_snap_i/q`): the paced HB1 burst grows
  8→24 clocks, which now overlaps the phase-B CIC insert that shifts `h1b` every
  16 clocks → would corrupt streams 6–7. Latching the centre taps at burst start
  freezes the burst-start value for all 8 streams. (HB2 unaffected — its tap
  lines shift every 32 clocks, outside its 24-clock burst.)

### Physical: deterministic fanout fix (`config_current_signoff_v9b.json`)
- `MAX_FANOUT_CONSTRAINT = 8` + **`RUN_POST_GPL_DESIGN_REPAIR = true`** →
  `repair_design` splits the 133-fanout `hb2_stream` net into a buffer tree,
  removing the ~17 ns fanout tax so the 104 ns MAC fits the 93.75 ns budget.
- `DIE_AREA = 1550×1150` (+17 % vs the 1380×1100 baseline) — **headroom for
  buffer legalization only**, not logic growth. The post-GPL repair fails
  `DPL-0036` on the cramped die; the roomy die legalizes it.
- `GRT_RESIZER_SETUP_MAX_BUFFER_PCT = 40`. SDC unchanged (`pnr_32m_mcp_v6.sdc`,
  blanket MCP=3 — now *honest for the decimator*).

### Key finding: pressure ≠ a fix
`repair_timing -setup` pressure *alone* (post-GPL repair OFF, config `…_v9`,
SGE 2148) only reached **−1.18 ns** by partially buffering (133→108 fanout). The
deterministic `repair_design max_fanout=8` (post-GPL ON, SGE 2149) was required
to close the last 1.18 ns. **You must explicitly force the buffer tree.**

## Results (SGE job 2149, `config_current_signoff_v9b.json`)

| Metric | Baseline | **v9b (honest)** |
|---|---|---|
| SS setup WNS (`ss_125C_3v00`) | −11.95 ns | **+8.01 ns (MET)** |
| tt / ff setup WNS | — | +52.4 / +68.7 ns |
| Hold WS (worst, all corners) | — | +0.17 ns |
| Magic DRC / KLayout route DRC | 0 / 0 | 0 / 0 |
| LVS errors | 0 | 0 |
| IR drop worst | — | 6.75 mV |
| stdcell area | — | 1.089 M µm² (leaner than the reverted pipeline's 1.119 M) |
| Antenna violations | — | 23 (minor; diode/jumper repair) |
| `DPL-0036` | — | none (post-GPL repair legalized) |

## Verification

`tb/tb_decimator_poly_equiv.v` drives the new `sd_decimator_poly` and the
git-original (`sd_decimator_poly_ref`) with identical pseudo-random 1-bit IQ and
compares every output sample. **4686/4686 bit-identical** (SGE 2147).

> The full-chain cocotb test (`cocotb_trouper_top` SF7) is **not** a reliable
> oracle for decimator arithmetic — it passed a *broken* intermediate version
> (n_acc is a counter; the weight rounds to 0x40 despite small errors). Use the
> equivalence bench for any decimator change.

## Extending honesty to the rest of the DSP chain

The blanket `MCP=3` masked the *same* 1-cycle-but-too-slow problem in every
500 kS/s block, not just the decimator. Each multiply/MAC is consumed every clock
by its TDM FSM, so it is functionally single-cycle and broken at 32 MHz in real
silicon (the FD `tdm_b_r`/`op_a*op_b` paths are ~73–76 ns). Fixed per block:

### sc_detector (`sc_detector.v`) — pacing
8-step TDM autocorrelation, triggered by `delayed_valid` once per 64-clock sample.
Plenty of idle room → **3-cycle pacing** (`tdm_wait`, burst 8→24 clocks). One
wrinkle: the longer burst now overlaps the next `iq_valid`, whose `sample_count++`
(gated by `!tdm_busy`) would be missed → a **deferred-increment latch**
(`iq_inc_pending`) applies it on the first idle cycle *after* the burst, which
preserves `eval_sample_mark`/`timing_ref` timing exactly. Verified: **12/12 SF
tests pass** (`sc_lock` + training + `n_acc` + demod all load-bearing here).

### training_acc (`training_acc.v`) — dual multiplier + pacing
**This one could NOT be paced as-is.** The TDM walk is **32 steps** (6 cross-pairs
× 4 sub + 4 diag × 2), sized for the old R=128 window (128 clocks). The HB
migration to R=64 halved the window to 64 clocks, so 32 steps fill half of it and
3-cycle pacing (96 clocks) **overruns** → dropped samples → training never
completes. tacc is **throughput-bound, not idle-bound**: 32 MACs per 2000 ns =
62.5 ns/MAC budget vs a 73 ns MAC → *one serial multiplier cannot keep up at any
clock* (clock division does not help — it is a throughput limit, not a clock-rate
limit). Fix = **2nd combinational multiplier**: two products per step halves the
walk to **16 steps** (cross-pairs 2 sub, diagonal 1 sub), which fits 3-cycle
pacing (48 + drain < 64). Bonus: the dual product eliminates the `p_latch`
even/odd interleave (the source of the historical cross-pair contamination bug).
Pacing uses the **active-cycle freeze model**: `tdm_wait` runs while
`pipe_active = tdm_active || acc_active` (the `||acc_active` keeps the cadence
alive for the trailing accumulator's drain step); the whole pipeline advances only
on `active_cycle`, freezing on hold cycles → the active-cycle sequence is
identical to the original, bit-exact by construction. Cost: **~one 8×8 multiplier
(~0.15–0.3 % of cell area)**; net minus `p_latch`. Verified: **`tb_training_acc_equiv.v`
PASS — all 16 Z accumulators (Zpair_i/q0..5, Zdiag_0..3) + n_acc bit-identical**
to the git-original.

**Lesson — pace vs pipeline vs parallelise by the block's bound:** idle-bound
blocks with burst room (decimator, sc) → pace; throughput-bound blocks
(tacc, 32 steps in 64 clocks) → cannot pace, must add parallelism (2nd mult) or
pipeline. Clock division never helps a throughput-bound block.

## Scoped honest SDC → control-plane violators (2026-06-22)

Replacing the blanket `MCP=3` with a scoped SDC (`MCP=3` confined to the paced
DSP blocks via `-through [get_nets {u_dec.* u_sc.* u_tacc.* u_comb.*}]`, `MCP=1`
elsewhere) made the relaxation honest — and **flushed out the control-plane paths
that had been hiding under the blanket**. Scoping gotcha: Yosys flattens register
*cells* to anonymous names (`_NNNNN_`), so `get_cells -hier *u_dec*` matches
nothing — scope on *net* names, which retain hierarchy (`u_dec.hb2_stream[1]`).

Honest-violator peeling, one block at a time (each was a real silicon bug the
blanket `MCP=3` masked), `ss_125C_3v00`:

| Step | Relaxation | SS WNS | New worst |
|------|-----------|--------|-----------|
| v9/v10 | scope MCP=3 to DSP blocks only | −18.6 → −22.5 | `spi_reg_we` (reg-bank write decode) |
| v11 | + 16 MHz CE-gate `reg_bank` | `spi_reg_we` **closed** | `u_psram.dbg_idx` −18.97 |
| v12 | + `false_path` PSRAM debug (`dbg_*`) | −16.45 | `sf_cfg → del_offset` barrel-shift |
| v13 | + relax SF/BW config (`sf_cfg`/`bw_sel`/`sample_shift`) | (routing-blocked) | `u_psram.state`/`sub` (live QSPI) |

### 16 MHz clock-enable partition (the SPI-write fix)

The reg-bank write decode (~54 ns of address-decode + 128-way write-enable
fanout) is `−22.5 ns` at 32 MHz single-cycle. It's **quasi-static** (host writes
at kHz; addr/data stable for the whole µs SPI transaction; only the 1-clock
`reg_we` strobe moves) — but it has **W1P trigger registers** (`w_commit_pulse`,
`noise_trig`), so a held-multi-cycle strobe would mis-fire them. Solution: gate
`reg_bank` with a `÷2` **clock-enable** (`ce_16m`, updates every other cycle), so
its internal write decode is a *genuine* 2-cycle path → **honest MCP=2 (62.5 ns)**
with one physical clock, one clock tree, **no async CDC** (derived clocks are
synchronous). Structure:

- `ce_16m` ÷2 toggle in `trouper_top`.
- **Write bus (`addr`/`wdata`/`we`) CE-latched together** + `reg_we` widened to
  2 cycles in `spi_slave` → the CE-gated bank writes **exactly once** per strobe
  → W1P triggers fire once (the CE elegance: solves the W1P hazard for free).
- **Separate combinational `raddr` read port** — peek reads need *no* CE latency
  (CE-latching the read address caused stale reads: `W0_re` returned the previous
  read's value).
- `irq_set` status pulses stretched to 2 cycles so the CE bank can't miss them.

Result (job 2163): `spi_reg_we` gone from the violator list, **zero `reg_bank`
restructure, no W1P hazard**; cocotb SF7 ×2 BW **PASS** (W0=0x40, n_acc exact,
BW write-lock, sc_lock+training_done). This is the throughput audit's payoff —
the control plane and 500 kS/s blocks close at 16 MHz; only the genuine 32 MHz
island (decimator + training_acc + remod) stays full-rate. `training_acc` is
throughput-marginal at 16 MHz (16 dual-mult steps × MCP2 = full 32-clk window),
so it stays 32 MHz-paced.

### The genuine residual: `u_psram` QSPI engine (NOT CE-able)

`psram_buf_ctrl` bit-bangs the APS6404L QPI interface: it generates `sck`@32 MHz
and walks **56 sub-cycles/sample** (S_REPLAY: 25 write + 31 read), one QSPI bit
per clock. `iq_valid = dcr_valid = 500 kS/s` → **64-clock window → 56/64 used,
8 spare**. (The header's "128-cycle / 72 spare" budget is **stale** — it predates
the R=128→R=64 half-band migration.) `sample_skip` fires if `iq_valid` arrives
while `qpi_busy`. So it is **throughput-bound** — CE-gating (2× → 112 clocks in a
64-clock window) overruns and drops samples. It belongs in the 32 MHz island; its
`state`/`sub` deep decode (≈ −10 to −13 ns) needs **depth reduction** — pipeline
the QSPI control/`sio_out`/address decode one cycle ahead (shifts the stream by
1 `sck`, throughput-transparent), *not* pacing/CE. This is the last honest RTL fix.

#### Required verification contract for the QSPI pipeline

This is a timing-only microarchitecture change, not a permission to change the
external protocol or relax a live path. Before it can replace the current
decode, first extract the exact post-route startpoint/endpoint from the target
netlist: B6 PnR exposed `packet_active → u_psram.sub[*]`, while earlier runs
also identify the same residual as `u_psram.state/sub →` QSPI-control decode.
The trace determines which local control decision is registered; do not add an
SDC exception for either form.

The implementation must pre-register the complete next QSPI micro-operation
(SIO value/drive-enable, CE#, read/write phase, and address/data-nibble select)
one IQ_CLK before it reaches the pads. The byte/nibble order and the number of
QSPI clocks per transaction must remain unchanged; the permitted observable
difference is a uniform one-`sck` displacement of the entire burst.

Verification MUST establish all of the following at the supported 125 and
250 kHz sample rates:

- cycle/nibble-accurate old-versus-new QSPI transaction equivalence after the
  allowed one-clock alignment, for init, capture+delay-read, replay, and debug
  readback;
- QSPI-owner handover still occurs only at a completed burst boundary, with no
  CE#-low/SCK-stopped or driven-SIO pad glitch;
- `SAMPLE_SKIP` remains clear under sustained capture and replay, proving the
  56-of-64-cycle replay budget remains intact; and
- replay payload order/alignment, `rpl_valid`, `del_valid`, late-commit, and
  packet-end/two-packet re-arm behavior remain unchanged.

Only after those functional gates pass should multi-seed SS PnR assess whether
the pipeline closes the live control cone. Buffer/repair variation can change
WNS, but is not a substitute for removing this roughly 25 ns combinational
decode path.

The PSRAM debug-readback path (`dbg_*`, regs 0x72–0x76) is genuinely quasi-static
(host reads at kHz, hard-gated to idle by `dbg_busy`) → `false_path`. The SF/BW
config (`sf_cfg`/`bw_sel`/`sample_shift`) is write-locked during a packet → its
barrel-shift cones (`M=1<<(SF+shift)`, `del_offset=8<<(sf+shift)`) → `false_path`
or wide MCP.

### Blocker: the floorplan is routing-marginal

Every config-relaxed PnR (v13 / retry / v13b-as-MCP8 / v13c-bigger-die, jobs
2165–2168) **failed detailed routing** — DRT-1231 (`clkbuf_2_2_0_IQ_CLK_regs/I`
pin access) at 1550×1150, DRT-0073 (no access point) at 1650×1250. v11/v12 routed;
the config SDC change shifts placement enough to tip an unroutable pin. The
floorplan has **no routability headroom to absorb perturbation** — this needs
floorplan/util work *regardless* of timing, and currently blocks the clean SS
residual number (mid-PnR STA is TT-only = 0.0).

## Open items

1. **Pipeline the `u_psram` QSPI control decode.** The one genuine residual
   (≈ −10 to −13 ns, throughput-bound). Register the `state`/`sub` → `sio_out`/
   address cone one cycle ahead; verify the QSPI stream is bit-identical (shifted
   1 `sck`) and `sample_skip` never fires.
2. **Floorplan routability headroom.** The config-relaxed netlist will not route
   on the current floorplan (DRT-1231/0073). Needed before *any* clean signoff and
   before die-shrink. Likely a CTS/util/pin-access fix, not just area.
3. **Die shrink** (after #2). The +17 % was buffer-legalization headroom; pure
   pacing is lean. Bounded by routability, not utilization.
4. **Corner relaxation (strategic lever, not a quick out).** The stock
   **gf180mcuD PDK ships only `ss_125C_3v00`** as the slow corner (+ `tt_025C_3v30`,
   `ff_n40C_3v60`). The slow *process* split is uncontrollable → **tt-only signoff
   is not safe**. But temp (125→85 °C, ~5–10 %) and especially **voltage
   (3.0→3.3 V, ~20–30 % — these are 5 V cells run voltage-starved)** are legitimate
   if the product spec caps the operating window. Requires **custom FD-stdcell
   characterization** at 3.3 V/85 °C (the `lib_char/` SRAM flow is extensible) and
   shifts the burden to spec/binning. Complementary to the honest constraints, not
   a substitute — won't close −16 ns alone.

## Reproduce

```bash
# bit-exact equivalence checks (fast, iverilog)
hqsub --node gaming-pc run_decim_equiv.sh           # → EQUIV: PASS 4686/4686
hqsub --node gaming-pc run_tacc_equiv.sh            # → TACC_EQUIV: PASS (all Z identical)

# full SF7-SF12 functional sweep (all 3 paced blocks)
hqsub --node gaming-pc run_sc_pace_sweep.sh         # → TESTS=12 PASS=12

# honest SS signoff (full flow, ~1 h) — decimator fanout fix
hqsub --cpus 12 --mem 20G --node gaming-pc run_trouper_7t_signoff_v9b.sh
# → max_ss_125C_3v00 setup WS = +8.0 ns, DRC/LVS = 0
```
