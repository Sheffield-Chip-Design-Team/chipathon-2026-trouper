# External PSRAM hardware bring-up — 2026-09-10/13

## Outcome

The `psram_buf_ctrl.v` ↔ real APS6404L QPI interface works end-to-end on
actual hardware: an Arty A7-100T driving a bare AP Memory APS6404L breakout
(sold unbranded by Adafruit) over Pmod JA, confirmed via a debug-port write
then read-back that came back bit-exact. The chip itself is confirmed
genuine AP Memory silicon (`MF_ID=0x0D`, `KGD=0x5D` — datasheet's documented
"known good die, passed test" encoding), not a clone.

Two real bugs were found and fixed along the way, both bring-up-tooling
issues, not RTL:

1. The FPGA emulator's `BENCH_CLK` build silently used the on-chip BRAM
   `psram_model` instead of the real external pads (`USE_EXT_PSRAM=0`) — every
   test against it was hitting a stub, not the breakout board.
2. A loose jumper on `SIO3`/K16/JA10, found by scoping each QPI line
   individually against a continuous debug-read/write burst.

One real, quantified hardware finding survived both fixes: a cable-length-
dependent read-capture timing margin, now mitigated with a new firmware-
trimmable register (`PSRAM_RD_TRIM`, `0x7A`) rather than an RTL change,
because it traces to Open Risks #69's already-known gap (no PCB flight-time
baseline in the PSRAM pad SDC constraints), not a protocol/cycle-count bug.

## Timeline

### 1. `USE_EXT_PSRAM=0` trap

`fpga-emul/vivado/create_project.tcl` ties `BENCH_CLK` (no-AFE-board bench
clocking, on-board MMCM 32 MHz instead of the SX1257 `CLK_OUT`) to
`USE_EXT_PSRAM=0` — the BD wires `psram_buf_ctrl` to the on-chip BRAM model
and ties the JA pads off (`fpga_dsp_wrap.v`: `psram_ce_n = 1'b1` etc.) when
bench-clocked. Every debug write/read-back run against `arty_dsp_emul_bench.bit`
this session round-tripped through that internal model, not the breakout —
diagnosed by scoping CE# (D13/JA7) during continuous debug-read bursts and
finding it never left idle-high.

**Fix:** `FORCE_EXT_PSRAM` env override added to `create_project.tcl`
(`fpga-emul/vivado/create_project.tcl`), keeping the MMCM 32 MHz bench clock
(no AFE board needed) while bringing the real pads out. New Makefile targets
`vivado_project_bench_extpsram` / `bench_bitstream_extpsram` build
`arty_dsp_emul_extpsram.bit`.

### 2. SIO3 continuity

Once on the real pads, CE#/SCK/SIO0-2 scoped clean but SIO3 (K16/JA10) was
flat — a half-width QPI bus, explaining garbled reads. Reseated; all four
lines then scoped identical.

### 3. Read-back offset — cable margin, not an RTL bug

With the bus electrically sound, an 8-byte debug write/read-back came back
shifted by one byte (`00 A5 5A DE AD BE EF 10` for a written
`A5 5A DE AD BE EF 10 27`). Two lines of evidence separated "RTL bug" from
"bring-up-rig timing":

- **Datasheet cross-check:** the debug-read sub-FSM's 6-cycle wait window
  (`psram_buf_ctrl.v`, `sub8`–`sub14`) matches the APS6404L's QPI Fast Quad
  Read timing (`resources/APS6404L_3SQR.pdf` Figure 14) exactly — not an
  off-by-one against spec.
- **Zero-delay sim control:** a new cocotb test
  (`cocotb/tests/test_psram_ops.py::test_dbg_write_readback_roundtrip`)
  reproduces the identical host sequence against the behavioural
  `psram_model.v` and comes back bit-exact with no priming read, at any
  simulated frequency (sim has no propagation delay). This is the
  deterministic control that clears the RTL.
- **Frequency sweep, real hardware:** re-running the write/read-back at
  32 → 8 → 5 MHz `psram_sck` (via a new `BENCH_CLK_MHZ` override, same
  `create_project.tcl`) shrank the observed shift from 2 nibbles to 1 nibble
  between 32 and 8 MHz, then plateaued unchanged from 8 to 5 MHz — a fixed
  absolute round-trip delay eating a shrinking fraction of a longer clock
  period is exactly the signature of real cable/board propagation delay, not
  a cycle-counted logic bug. (2 MHz itself is below this `clk_wiz`
  configuration's achievable floor, 4.687 MHz for this VCO — not reached.)
  Bounds the round-trip delay on this specific bring-up rig (long flying
  leads, bare breakout, no series termination) at roughly 125–200 ns —
  much larger than the APS6404L's own `tACLK` (2–5.5 ns, Table 10), so
  chip response time is not the limiting factor; cable length/quality is.

This is the same gap already tracked as **Open Risks #69** ("PSRAM QPI
output pads launch on the same edge as the forwarded clock, and are
unconstrained at signoff"): its own SDC section already notes *"Zero
pad/PCB-flight baselines — add measured trace delay before tapeout"*. Real
production PCB trace lengths are far shorter than this bring-up rig's flying
leads, so this is not read as a new tapeout risk on its own — see #69 for
the still-open STA action.

### 4. `PSRAM_RD_TRIM` (0x7A)

Added as cheap, safe insurance rather than resolving #69's STA gap outright:
a firmware-writable extra-wait-cycle count (`[3:0]`, 0–15, default 0 =
today's exact datasheet timing) applied uniformly to all three QPI read
sub-FSMs in `psram_buf_ctrl.v` (debug read, delay-line `del_i0`/`del_q0`
read, replay `cur_rd` read — found to share the identical 6-cycle template).
Unsigned/extra-only by design: the chip's 6-cycle minimum is a hard floor
(`tACLK_min` = 2 ns), and `sio_in` has no synchronizer stage between the pad
and the capture FSM (`trouper_top.v`: `PSRAM_SIO_IN` is a bare wire), so
sampling *earlier* than the datasheet-mandated point can only race the chip
harder, never help.

See `planning/Register Map.md` `0x7A` for the register description.
Implementation: `src/control/psram_buf_ctrl.v` (`rd_wait_trim` port + 3
patched sub-FSMs), `src/control/reg_bank.v`, `src/top/trouper_top.v`.

Regression: full core suite (job 5762, 50 suites) — one real failure, a
stale reserved-address entry in `cocotb/tests/test_reg_bank_rw_map.py`
(`0x7A` was in its reserved-address sweep list); fixed and reconfirmed clean
(job 5763, `reg_bank` 39/39).

### 5. Chip authenticity (`MF_ID`/`KGD`)

Built a standalone Vivado block design — `jtag_axi` (JTAG-to-AXI master, no
MicroBlaze) → `smartconnect` → `axi_gpio` (4-bit bidirectional `SIO[3:0]` +
2-bit output `{sck, ce_n}`) — to bit-bang the datasheet's SPI-mode-only
`0x9F` Read ID command directly, outside `psram_buf_ctrl`'s fixed QPI
command set. Sequence: QPI-framed Reset (`RSTEN`/`RST`, CE# toggling between
per Figure 18) then SPI-framed Reset (CE# held low through both per Figure
17) to force the chip to SPI standby regardless of which mode it was
actually in (it had almost certainly been left in QPI mode by the whole
session's prior testing), then `0x9F` + 24 don't-care address bits + 16
response bits.

Result: `MF_ID=0x0D`, `KGD=0x5D` — the latter matches Table 4's documented
"known good die, PASS" encoding exactly (`0x55` would be FAIL). Genuine AP
Memory silicon.

## Files touched

- `fpga-emul/vivado/create_project.tcl` — `FORCE_EXT_PSRAM`, `BENCH_CLK_MHZ`
  env overrides
- `fpga-emul/Makefile` — `vivado_project_bench_extpsram` /
  `bench_bitstream_extpsram` targets
- `src/control/psram_buf_ctrl.v` — `PSRAM_RD_TRIM` (`rd_wait_trim` port + 3
  sub-FSM patches)
- `src/control/reg_bank.v` — `0x7A` storage/read/write
- `src/top/trouper_top.v` — wiring
- `planning/Register Map.md` — `0x7A` documented, occupancy updated
- `cocotb/tests/test_psram_ops.py` — new
  `test_dbg_write_readback_roundtrip` (permanent regression coverage)
- `cocotb/tests/test_reg_bank_rw_map.py` — `0x7A` reserved→RW correction

## Follow-up: PSRAM pad drive strength

**Corrected 2026-11-02 — no pad-type change.** This section originally said
`PSRAM_CE_N`/`PSRAM_SIO_0..3` were on "default drive" and moved them to
`bidirectional_24ma` for consistency with `PSRAM_SCK`. That premise was
wrong: they are `bidirectional` (`bi_t`) with `PDRV1,PDRV0` tied `1,1` in
`trouper_top.v`, i.e. already max 16 mA (`planning/Pinout.md`). `PSRAM_SCK`
alone is on `bi_24t` because of the APS6404L `t_KHKL` ≤ 1.5 ns clock
edge-rate limit, which does not apply to CE#/SIO. The change was reverted in
`info.yaml` (it would also have dropped 10 `_PDRV*` pins from the DEF that
`trouper_top.v` still drives). If ringing/overshoot shows up on the real PCB
(see the "IO drive strength" discussion above), the mitigation is board-level
series termination, not a pad-type change.

## Part 2: real-hardware debug-port reliability at 32 MHz — unresolved (see Open Risks #72)

After the write-up above, the plan was to run an injection-based full-chain
test at 32 MHz `psram_sck` with `PSRAM_RD_TRIM` set correctly. Before doing
that, `PSRAM_RD_TRIM` needed an actual value for 32 MHz on this rig —
sweeping it (rebuilt `arty_dsp_emul_extpsram.bit`, current RTL) found the
corruption pattern was **not** a clean, trim-fixable shift at 32 MHz the way
it was at 8/5 MHz: it was inconsistent between runs at the same trim value.

A scope check (SIO0/1/2/3 individually against SCK, and pairwise against
each other, both write- and read-direction, both real hardware) found
**every line electrically clean and mutually synchronized** — ruling out
cable propagation delay and inter-line skew as the explanation, which
contradicted the frequency-dependent shift seen in Part 1. Re-examining that
result: `BENCH_CLK_MHZ` slows the *entire* DSP-domain clock, not just
`psram_sck`, and the JTAG polling loop's round-trip time is fixed in real
wall-clock time — so the earlier "frequency confirms cable delay" evidence
was confounded by internal-clock-cycles-per-poll changing, not by cable
delay changing. Retracted.

A controlled Icarus cosim (`tb_psram_delay.v`, injecting a real 3+3=6-cycle
round-trip delay into the PSRAM pad wiring between `psram_buf_ctrl`/
`trouper_top` and `psram_model.v`) found `PSRAM_RD_TRIM` behaves exactly as
designed — a clean, monotonic, fully predictable `trim = delay + 2`
relationship, bit-exact — both driving `psram_buf_ctrl`'s `dbg_*` ports
directly and through the full `reg_bank`/`spi_slave` SPI protocol path
(`tb_trouper_psram_delay.v`). This clears the RTL and the trim mechanism
completely for any *symmetric, whole-cycle* delay.

Systematically eliminated as explanations for the remaining real-hardware
corruption: DRAM refresh collision (spacing operations 0–200 ms apart
changed nothing), SPI burst-vs-separate-transaction framing (rewriting to
match the documented single-CS-assertion burst protocol for `0x79` changed
nothing), and host-SPI clock rate margin (already at the IP's maximum
divider, and the cycle-count math doesn't support a near-miss anyway).

**Net result: root cause not found this session.** Every simulation-
verified path is correct; something specific to driving the real hardware
via the JTAG-to-AXI harness (`axi_quad_spi_1` register pokes) is not yet
understood, and it does not reproduce in any simulation of the same
protocol. See Open Risks **#72** for the full elimination list and
suggested next steps (ILA capture of the real host-SPI waveform, or
sidestep via firmware-driven UDP injection instead of JTAG register pokes).

**Practical consequence:** the planned injection-based full-chain test at
32 MHz did not proceed — comms reliability has to be resolved (or worked
around) first, or the test would be validating against unreliable readback
rather than the actual receive chain.

## Part 3: RTL fix retested on hardware — write-side miss found, not read-side (same day, later)

The `psram_sio_in_q` negedge-domain capture register + `PSRAM_RD_TRIM` RTL
was rebuilt for real hardware (`make bench_bitstream_extpsram` against
current `src/`; final route WNS +0.946 ns / WHS +0.015 ns, all timing met)
and retested with a new path that sidesteps the JTAG-to-AXI harness
entirely: two new firmware UDP commands, `CMD_REG_WRITE`/`CMD_REG_READ`
(`sw/main.c`), call the exact same `reg_write`/`reg_read` SPI helpers every
other production command uses, with results echoed over UART for
confirmation.

At `PSRAM_RD_TRIM=0`, debug write/read-back is bit-exact most of the time
(55/60, then 75/80 across two runs) — a large improvement over the pre-fix
state — but not fully closed. Raising the trim made it monotonically worse,
ruling out "needs more read margin." Re-reading a failing address a second
and third time (no re-write) returned the same stable all-zero content each
time, which rules out read-side jitter: **the write itself is intermittently
not committing to the chip**, even though `DBG_BUSY` reports `WR_TRIG`
completing normally. One run's failures landed at a period-3 cadence
(i=1,4,7,10,13) that a second run reproduced at a different phase
(i=57,60,63,66,69) — noted, not explained.

This reclassifies the finding: it's a live hardware match for the
write/CE#-launch margin problem **Open Risks #69** already predicted from
static analysis (write data and CE# transitions launched on the same edge
the PSRAM samples on, ~0 ns nominal setup/hold, invisible to STA because the
interface has no SDC constraint at all — the clean +0.9 ns WNS this rebuild
reported bounds nothing on this path). The JTAG-to-AXI harness is now
cleared as a cause of the original Part 2 symptom, since the same
intermittent failure reproduces over the ordinary firmware/SPI path.

**Next step (not done this session):** on-chip ILA capture
(`system_ila_debug_pins_0`, already present in the bench BD) of
`ce_n`/`sck_en`/`sio_out` across a live failing `WR_TRIG`, to see the actual
waveform rather than infer from UART/UDP round-trip evidence.

## Part 4: ILA capture of a live failing write — FPGA-side signal generation cleared (same day)

Built a dedicated write-trace ILA (`RISK72_ILA=1`, retargeted from the
earlier debug-read investigation to `ps_sck`/`dbg_wbuf`/`wr_data`/
`ps_sio_in`/`ps_sio_out`/`ps_sio_oe`/`ps_ce_n`/`dbg_wr_mode`/`dbg_mode`/
`qpi_busy`/`sub`, 1024 samples @ 100 MHz — ~3x oversampled on the 32 MHz DSP
clock). This needed a new `set_false_path -through` on `risk72_trace`/
`risk72_trigger` in `arty_dsp_emul.xdc`: sampling the dsp_clk-domain probe
with a 100 MHz ILA clock is a deliberate, unsynchronized async capture (no
synchronizer needed — nothing downstream of the ILA feeds back into the
design), which STA otherwise scored as a real ~-2 ns `clk_out2`→`clk_out1`
violation it isn't; without the exception this build's WNS was -1.97 ns, with
it, +0.665 ns / WHS +0.016 ns, clean.

Orchestrated via a new `vivado/risk72_write_capture.tcl`: arm the ILA on
`risk72_trigger` (rising edge — any debug transaction start), fire one
write+read-back attempt over the UDP register-poke path
(`psram_dbg_single.py`), upload and save the capture only when the software
side detected a failure. Caught one on attempt 59/60.

Reconstructing the actual QPI nibble stream driven onto `ps_sio_out` for that
failing write: `02 00 65 00 A5 5A DE AD BE EF 10 27` — command `0x02`
(write), address `0x006500` (exactly the target address that attempt used),
and all 8 data bytes bit-exact to the pattern that was supposed to be
written. `ce_n` stayed low for the entire clean 25-state burst, `sck` toggled
normally throughout, and the transaction returned cleanly to idle. **The
FPGA-generated command was perfect.**

This clears `psram_buf_ctrl`'s write-side FSM and the pad-relaunch logic as
the source of this specific failure — the same conclusion applies to the
whole class of failures, since nothing about this attempt was special. It
narrows the remaining candidates to something the ILA structurally cannot
see, because it only captures the FPGA's own register values, not what
actually lands at the chip: either a collision with the APS6404L's
datasheet-documented **self-managed refresh** (invisible/uncommunicated to
the host — the chip decides when, not the controller, so no amount of
inter-command idle time on the FPGA side can guarantee avoiding it; see
`resources/APS6404L_3SQR.pdf`'s `tCPH`/`tCEM` timing and its self-refresh
section), or real signal integrity on the breadboard's unterminated flying
leads at 32 MHz that a purely-digital, FPGA-internal ILA is blind to by
construction.

**Practical consequence:** neither remaining candidate is fixable by further
`psram_buf_ctrl` RTL changes. Next steps are a physical scope on the actual
SIO/CE# wires captured across a live failure (to distinguish the two), or a
pragmatic write-verify-and-retry layer in the bring-up firmware/tooling —
acceptable for a debug port, not a precedent for the ASIC's own real receive
datapath, which never does read-modify-verify writes to PSRAM this way.

New files: `fpga-emul/vivado/risk72_write_capture.tcl`,
`fpga-emul/arty_dsp_emul_risk72_writetrace.bit` (not committed — regenerate
via `RISK72_ILA=1 FORCE_EXT_PSRAM=1 BENCH_CLK=1 make -C fpga-emul vivado_project vivado_synth`);
`arty_dsp_emul.xdc`'s new `set_false_path` is committed.

## Part 5: the full functional replay test does not lock against real PSRAM — new gap, not yet root-caused

With the write-trace ILA bitstream still programmed (functionally identical
to the plain `_extpsram` build for anything outside the new debug probes),
ran the actual documented acceptance test —
`tools/run_replay_sweep.py` against the same known-good
`lora_20260621_092907_SF7-BW250-Pre8.npy` capture the TODO's own reproduce
command names — through the real receive chain (decimator → dc_removal →
`sc_detector` → `psram_buf_ctrl` delay-line → combiner) with the real
APS6404L in the loop. **`sc_dbg_flags`/`irq_status`/`packet_status` all read
0 — no `sc_lock`.** Reproduced 3 times, including after a full firmware
reboot (`make run_eth_fw`) to rule out state left over from the write/read
stress testing in Parts 3-4 above.

**Important context, not previously flagged:** the `fpga-emul/TODO.md`
"hardware-validated 2026-09-06" result for this exact replay path predates
this session's discovery (Part 1 above) that `BENCH_CLK=1` alone ties
`USE_EXT_PSRAM=0` — that original validation almost certainly ran against
the on-chip BRAM `psram_model` stub, not real silicon. **This may be the
first time this specific test has ever been run against the real chip.** So
tonight's no-lock result is not necessarily a regression from any RTL change
made this session — it may be an already-existing, previously-untested gap.

A quick register-level health check found nothing obviously wrong:
`PSRAM_STATUS`=0x0A (`INIT_DONE`=1, state=`S_WRITE`, no `SAMPLE_SKIP`/
`OVERFLOW`), `RX_HOLD`=0, `BRINGUP_CTRL`=0 (bypass path not armed),
`SF_CFG`/`BW_CFG` correct, `SC_THR`=0x01CC (default). Polling `SC_STAT`
(0x24/0x25, the live correlation metric) throughout a replay read exactly
zero the entire time, on every sample — but `SC_STAT` is documented as
volatile, changeable between any two SCK edges, and this session's polling
was ~50-100 ms/read (UDP + UART-confirm round trip), several orders of
magnitude too slow to reliably sample a live register even if correlation
is running completely normally. **This all-zero result is therefore
inconclusive, not evidence that the SC engine never runs** — flagging the
methodology limit explicitly so it isn't mistaken for a finding.

**Not done this session:** a proper ILA trace (32 MHz, synced to
`CMD_REPLAY_START`, capturing `sc_pipe_active`/`sc_hit_dbg`/`c_i0`/`c_q0`/
`timing_ref`/`del_valid` for the full ~16 ms replay window) would give a
real answer here, the same way Part 4's ILA gave a real answer for the write
path. That needs care around exactly when to arm relative to `CMD_START`
(UDP + firmware dispatch latency is on the order of ms, so "arm then send"
ordering matters) and is a well-scoped next task rather than a five-minute
follow-up.

## Part 6: 2026-09-14 final-nibble guard and QPI-rate experiments

### CE#-low final-nibble guard

The controller was changed experimentally to keep `CE#` low and stop SCK
for one complete controller cycle after the final write-data nibble, before
deasserting `CE#`.  The guard was applied consistently to the capture write,
replay write, and debug-write paths.  This costs one additional sub-cycle:
S_WRITE is now 46 sub-cycles and S_REPLAY 58, still within the 64-cycle
`iq_valid` budget at the normal 32 MHz QPI rate.

Both the standalone PSRAM model (64/64 checks) and the focused cocotb debug
write/read-back test passed.  The external 32 MHz FPGA build also met timing,
bitgen/DRC completed without errors, and was programmed onto the Arty.

The real-device write-verify result remained a failure.  Expected payload was
`A5 5A DE AD BE EF 10 27`; observed final byte changed from the prior `20`
variant to `22` in this build.  Therefore a conventional post-write flush or
an extra CE#-low/SCK-quiet termination cycle is **not** sufficient to repair
the fault.  It may affect the marginal symptom, but it is not a corrective
fix.  The firmware already waits approximately 5 ms after write completion
before reading, far beyond the APS6404L's 18 ns minimum CE#-high interval.

### 8 MHz experiment: not a deployable mitigation

An initial whole-domain 8 MHz bench build was invalid as a PSRAM-rate test:
it also reduced the controller/`spi_slave` clock to 8 MHz while the internal
MicroBlaze host SPI remained at 6.25 MHz.  The UDP write-verify handler then
became inconsistent/stalled, so its output could not distinguish host-side
service failure from PSRAM failure.  Attempting to slow `axi_quad_spi_1`
further with `HOST_SPI_SCK_RATIO=64` was rejected by this IP configuration;
only 2/4/8/16 are accepted, with 16 already the slowest setting.

To isolate QPI speed, an experimental `PSRAM_QPI_CLK_DIV` parameter was added
through `psram_buf_ctrl`, `trouper_top`, `fpga_dsp_wrap`, and the Vivado build.
It keeps the controller and host SPI at 32 MHz while emitting/advancing QPI
once every N controller cycles.  Default is 1, so normal RTL behavior is
unchanged; the default standalone model remained 64/64 passing.

The divide-by-four hardware image (nominal 8 MHz QPI) returned a byte-shifted
debug payload, `5A DE AD BE EF 10 27 00`, rather than a valid write-verify
result.  The divide-by-four behavioral model also failed to produce a valid
delay-line result.  Independently, this operating point cannot support normal
capture/replay: a 46-sub-cycle transaction becomes 184 controller cycles,
which exceeds the 64-cycle `iq_valid` interval.  It would necessarily drop
samples even if its transaction phase were corrected.

**Conclusion:** slowing the live QPI bus to 8 MHz is neither a valid
diagnostic result with the first divider implementation nor a viable receiver
mode.  The board was restored to the prior 32 MHz external-PSRAM guarded
image after the experiment.  The remaining credible next step is observing
SCK/CE#/SIO at the breakout pins during a failure, or a separate redesign
that provides enough buffering/throughput for a slower memory interface.

## Part 7: 2026-09-28 — SCK edge rate (tKHKL) identified as the leading cause

Live session on the same rig (Arty A7-100T, APS6404L on a breadboard wired to
PMOD JA; TDS210 probes at the PSRAM pins). Tooling saved in
`fpga-emul/tools/risk72_bench/` (not committed): `psr.py` (UDP
`CMD_REG_WRITE`/`CMD_REG_READ` debug-port driver + UART parse), `rate.py`,
`exp5.py` (offset-aware pattern test), `asweep.py`, `tds.py` (TDS210 serial
control/decode), `cap.py`/`capw.py` (SCK-triggered read/write burst capture),
`dec.py`, `edge.py` (rise/fall measurement); raw captures in `caps/`.

### Reproduction

`CMD_WRITE_VERIFY_PULSE` on `arty_dsp_emul_risk72_writetrace.bit` + current
ELF: 5/5 MISMATCH (`…10 22`, then 4× all-zero) — the documented #72 signatures.

### Test-method artifact: the capture ring overwrites debug data

With `PSRAM_EN=1` the capture path writes 8 B every 2 µs across the full
8 MB (`AMASK`), lapping the chip every ~2.1 s. On the no-AFE bench it writes
zeros, so debug-written data vanishes within ~2 s (observed: five good reads,
then all-zero). Part of the historical slow-path "ALL_ZERO" rate is this, not
a PSRAM fault. **All debug-port tests must clear `PSRAM_EN` (`0x70=0x00`)
after init.** QPI init runs only from reset, so a chip knocked out of QPI mode
needs a reprogram/reset to recover.

### Symptom with capture frozen: structured nibble slips

Not random bit errors: whole nibbles dropped or duplicated with the rest of the
burst shifted (`11 22 33 44 55 66 77 88` → `11 22 33 44 56 67 78 89`), a
consistently wrong final write nibble (`27` → `20/22/2C`), some reads getting
no response at all (bus returns the last driven address nibble, e.g.
`11 11 …`/`88 88 …`), and occasional loss of QPI mode until reset. Each
failure is bit-for-bit repeatable for a given address/pattern within a period,
then the behaviour drifts (e.g. `EF`→`E1` dropped-`F` state held 5/5 across
~15 min, then the same write stored `F` correctly 19/20).

### Slow-clock test (`PSRAM_QPI_CLK_DIV=4`, 8 MHz QPI; no source edits)

Bitstream `fpga-emul/arty_dsp_emul_extpsram_div4.bit` (WNS +0.321 ns). Same
test, same corruption signatures as 32 MHz (e.g. `96 69 0F F1` → `96 60 00 00`
at both rates; toggle/sparse regions dead at both). **Correction (same day):
this is not a 4× timing-margin test.** The divider only skips cycles — data
still changes on the step's falling edge and SCK is one 32 MHz-wide pulse on
the very next rising edge, so write-data setup stays ~15.6 ns (measured 12–16
ns SIO-change→SCK-rise on the 8 MHz captures, SCK high ~17 ns in a 125 ns
period). It added hold margin only, so it did not rule out a slow-data-edge
setup failure. Two divider-only RTL artifacts seen (not relevant at div=1):
`sck_stop` is one controller cycle wide so it is ineffective at div>1 (25 SCK
edges with CE# low on a write instead of 24), and the read-capture offset
varies between 2 and 3 nibbles.

### Scope, at the PSRAM pins, 8 MHz write burst

SCK clean and full-swing (124–128 ns period); CE# one clean low window (peak
0.72 V during the burst); **SIO0, SIO1, SIO2, SIO3 each bit-exact against the
intended `02` + address + `A5 5A DE AD BE EF 10 27` on all 24 edges** — yet
the chip stored the burst with a nibble missing in the same run. Read-back of
one stored image from six start addresses gave the same image each time, so
the loss happened at write. Probe position does not matter (F-drop then
correct with the probe back in the same place).

### Root-cause candidate: SCK rise/fall time 2–4× over spec

APS6404L Table 10: **tKHKL (CLK rise/fall, 20–80 % VDD) max 1.5 ns**.
Measured SCK at the PSRAM: rise 6.7 ns, fall 7.2 ns (20–80 %), with a short
shelf at ~1.6 V (the input threshold) on the falling edge. Subtracting the
TDS210's own ~3.5–5.8 ns leaves a true edge of roughly 3.4–6 ns. Cause:
PMOD JA's on-board 200 Ω series resistors driving breadboard leads plus pin
capacitance (1.4·RC ≈ 4–7 ns for 15–25 pF). A slow clock edge lets the chip
miscount edges (dropped/doubled nibbles, garbled commands → mode loss). This
fits every observation: it is clock-frequency-independent (8 MHz did not
help); deterministic per data/address pattern (the same switching disturbs the
same slow edge); drifts with temperature/supply; and invisible in signal-level
checks, which all passed.

**Not yet proven** — the closing evidence is the fix: move the bus off JA
(JB/JC have no series resistors), shorten SCK, add the datasheet-required 1 µF
low-ESR decoupling at VDD (§14.3), then rerun `rate.py`/`exp5.py` at 32 MHz
with capture frozen.

### Fix step 1 result: SCK moved to JB pin 1 (E15, no series R), `SLEW FAST`/`DRIVE 16`, 1 µF at VDD, GND wire

32 MHz image `fpga-emul/arty_dsp_emul_extpsram_jbsck.bit` (WNS +1.017 ns).
SCK rise/fall 2.0–2.5 / 3.2 ns (scope-limited, near spec) but overshoot to
4.96 V / −0.8 V (abs-max allows VDD+0.5 V for ≤20 ns) → ~33 Ω series at the
JB pin recommended. `CMD_WRITE_VERIFY_PULSE` 10/10 PASS (was 5/5 FAIL);
aligned write/read 30/30 exact; every matching `exp5` read now at offset 0 (no
more nibble slips). Remaining failures: data that drives SIO high/toggles
(`0F 0F…` → `00…`, `…0F F1` → `…00 00`). Scoped SIO1 during a `0F` write:
every "1" measured 2.64–2.80 V at the SCK rising edge against **VIH =
VDD−0.4 V ≈ 2.9 V** (data still on JA's 200 Ω, 11.6 ns 20–80 %: 88 % of VDD
needs ~17 ns > the 15.6 ns half-cycle). Not yet explained: the second 8-byte
line of a region fails more than the first, including steady `FF` data. Next:
CE#/SIO0–3 moved to JB 4/7/9 + JC 1/3 (C15/J17/K15/U12/V10), `SLEW FAST`.

### Fix step 2: whole bus off JA, then probe and drive-strength experiments

CE#/SIO0–3 moved to JB pin 4/7/9 + JC pin 1/3 (C15/J17/K15/U12/V10),
`SLEW FAST` (`arty_dsp_emul_extpsram_jball.bit`, WNS +0.689 ns). SIO1 rise
11.6 → 2.5 ns. Results, in order:

1. **CH2 probe on a data line (SIO1, later SIO2):** the *probed* line
   collapsed to ~1.0–1.2 V (mid-rail) whenever the chip drove ≥3 lines high
   (`E`/`7`/`F` failed, `2`/`6`/`A`/`3`/`D` passed). The victim followed the
   probe from SIO1 to SIO2 → probe grounding/ground-loop artifact, not
   wiring. (A "read executed as a write" capture was a stale scope waveform
   — TDS210 failed to re-arm; `tds.arm()` now verifies `ACQ:STATE? == 1`.)
2. **CH2 removed, CH1 on SCK:** `E`/`7`/`B` 6/6; only the first nibble of an
   all-ones burst failed (`FF…` → `3F FF…`), i.e. four SIO lines rising
   together.
3. **Both probes removed:** nibble slips returned (12 reads at +1-nibble
   offset). CH1's ~15 pF had been damping SCK ringing (measured 4.8 V /
   −1.0 V overshoot with fast unterminated edges).
4. **`DRIVE 4` on SCK, `DRIVE 8` on CE#/SIO, no probes**
   (`arty_dsp_emul_extpsram_drv.bit`): all-`F` fixed 6/6, `rate.py` 20/20,
   `exp5` 42/72 exact + 3 slips, but a new failure: after an `F` nibble,
   following `0`s read back `F` (`0F 0F…` → `0F FF FF…`), consistent with
   weakened pull-down.

**Conclusion.** Every change moved the failure mode rather than removing it:
slow edges (JA 200 Ω) → SCK ringing (fast, unterminated) → 4-line
simultaneous switching → weak-drive stuck-high. The breadboard interconnect
(flying leads, single ground return, no termination) is marginal on several
axes at once; drive-strength tuning is not a real fix. Nothing in this whole
session implicated the RTL. Not done: SIO back to full drive with SCK kept at
`DRIVE 4` (would separate the last two effects); a ~33 Ω SCK series resistor
(none on hand).

**Implication for the AFE PCB (due week of 2026-09-28):** per
`fpga-emul/vivado/arty_dsp_emul.xdc` the PCB routes PSRAM via J8 → Arty
**JA**, i.e. through the same on-board 200 Ω series resistors that gave the
6.7 ns SCK edge and marginal SIO highs against VIH = VDD−0.4 V. Expect the
Part-7 slow-edge failure on the PCB unless the bus avoids JA (JB/JC have no
series resistors) or JA's resistors are bypassed. The XDC has been
restored to the JA pin block for the PCB; the breadboard JB/JC pin + DRIVE
block is saved as
`fpga-emul/tools/risk72_bench/breadboard_psram_pins.xdc.snippet`.

### Tapeout relevance

The same tKHKL ≤ 1.5 ns applies to the ASIC's `PSRAM_SCK` pad driving the PCB
(15 pF system CL): check the GF180 pad drive/slew against it under Open Risks
#69. Open Risks #73 (no `sc_lock` through real PSRAM) should not be re-judged
until the bench link passes the pattern test.

## Part 8: 2026-11-18 — retest on the JB/JC breadboard; the stuck-high fault is read-side

Same rig as the end of Part 7: Arty A7-100T, APS6404L on a breadboard with the
whole bus on JB/JC (`breadboard_psram_pins.xdc.snippet` pinout), TDS210
(60 MHz, 1 GS/s, 10× probe) on CH1 only. Host link: Arty Ethernet on
`enp5s0f1` (192.168.10.1/24), UART on the Digilent `if01` port. Bitstreams
and ELF unchanged from 2026-09-28 (`sw/lora_mimo_fw.elf`). All tests ran with
the capture ring off (`0x70=0x00`) and `PSRAM_RD_TRIM=0`. Tools (in
`fpga-emul/tools/risk72_bench/`, not committed): `score.py` (20-line
aligned write/read plus an unaligned read-offset sweep), `readshift.py`
(write-vs-read discriminator), `vddcap.py`/`railcap.py` (CH1 rail capture
armed around a single write burst); raw waveforms in `caps/2026-11-18/`.

### `PSRAM_RD_TRIM` behaves as designed

Sweeping `0x7A` = 0/1/2 shifted every read by exactly +1 nibble per step,
uniformly across start addresses. 0 is the correct setting on this rig, so
the FPGA's read sample point is not the problem. Aligned reads of a
good-pattern line (`A5 5A DE AD BE EF 10 27`) were 10/10 exact.

### Drive-strength variants

| Bitstream | Aligned write/read, 20 lines | Behaviour |
|---|---|---|
| `_drv` (SCK `DRIVE 4`, SIO/CE# `DRIVE 8`) | 2/20 | The first `0F 0F…` line knocks the chip out of QPI; every address then reads `FF`/decaying values until reprogram. Reproduced on two fresh programs. |
| `_jball` (full drive, `SLEW FAST`) | 8/20 | No mode loss; results identical on every re-read. |

On `_jball` the failures follow one rule: once a nibble has 3–4 SIO lines
rising together (0→F/7/E/B), that nibble and everything after it in the read
come back stuck high (`0F 0F…` → `03 FF FF…`, `B0 76 70…` → `B0 77 77…`,
`A9 EA 0E 75…` → `A9 EA 0E EE EE…`). Patterns that never raise three lines at
once (`A5 5A DE AD BE EF 10 27`) always pass. The unaligned read sweep also
shows address-dependent +1-nibble slips (start low nibble 2/4, sometimes F),
the same at two different base addresses.

### Rails: no burst-correlated event

- **PSRAM VDD (probe tip VDD, ground at PSRAM VSS):** 3.40 V DC; idle
  ±10 mV (AC, 20 mV/div). With the scope armed on a falling VDD edge at
  −30 mV, then −12 mV, failing `0F`/`FF` writes fired 0/6 and 1/6. The
  passing pattern fired just as often, and the captures look like idle noise,
  not burst-shaped. Sag above about 20 mV for longer than about 10 ns is ruled out.
- **PSRAM VSS vs Arty GND (tip VSS, ground at an Arty PMOD GND):** idle
  +80 mV DC with ±200 mV spikes while the PSRAM is untouched (a weak ground
  return, worth fixing). With a +350 mV rising trigger, failing writes fired
  0/6. The offset is in the harmless direction for a stuck-high fault.

Caveat: with only one channel the trigger was the rail itself, so nothing
proves the burst sat in the window. A CE# trigger on CH2 would close that.

### Decisive: the corruption follows the read, not the stored image

`readshift.py` writes a line between two zero lines, then reads it from
start offsets −3…+5:

```
wrote 0F 0F 0F 0F 0F 0F 0F 0F at 210000
   read @-3: 00 00 00 3F FF FF FF FF
   read @+0: 03 FF FF FF FF FF FF FF
   read @+4: 03 FF FF FF FF FF FF FF   <- last 4 bytes are the 00 padding line
```

Each read is correct up to its own first 0→F nibble, then reads all-high,
including the zero bytes past the line. A bad stored image would read
identically from every start address. **This `_jball` stuck-high signature is
a read-path fault:** once the PSRAM drives SIO lines high, the FPGA keeps
seeing them high. Part 7 attributed the high-data failures to the write side;
that attribution does not hold for this signature on this rig. The XDC sets
no `PULLUP`/`KEEPER` on `psram_sio[*]` and the wrapper uses plain IOBUFs, so
nothing on the FPGA side is holding the lines.

### 200 MHz pad capture: the PSRAM stops driving after the 4-line rise

New FPGA-only build `arty_dsp_emul_risk72_oversample.bit` (+ `.ltx`), made with
`BENCH_CLK=1 FORCE_EXT_PSRAM=1 RISK72_OVERSAMPLE=1
PSRAM_PIN_XDC=tools/risk72_bench/breadboard_psram_pins_jball.xdc` (env vars in
`vivado/create_project.tcl`; extra constraints `vivado/risk72_oversample.xdc`).
It uses the existing `risk72_trace` bus (`ce_n`, `sck`, `sio_out`, and `sio_in`
straight off the IOBUF outputs), sampled by a 200 MHz MMCM clock. That is
6.25 samples per SCK period, 5 ns resolution, 2048 samples, triggered on the
debug read. Post-route WNS +0.191 ns, WHS +0.019 ns. Capture:
`vivado/risk72_oversample_capture.tcl <tag> <addr> [<pattern>]`; decode:
`tools/risk72_bench/ila_decode.py`; CSVs in `caps/2026-11-18/ila_*.csv`.
Programming: `tools/risk72_bench/program_oversample_fw.tcl`.

**Failing read** (stored `0F…`, firmware got `03 FF FF FF FF FF FF FF`):
- Command `E B` (Fast Quad Read), address `2 1 0 0 0 0` and the 6 wait cycles
  are clean, and the first data nibble `0` is correct.
- At the first `F` nibble (~485 ns after CE# low) all four lines rise together
  and ring for ~30 ns (`1111 → 0011 → 1111 → 1011 → 1100 → 1111`).
- The lines never return to `0` for the rest of the read. They sit at `1111`
  with single-sample dips (`1110` on SIO0, `1011` on SIO2) locked to every SCK
  edge.

**Passing read** (stored `A5 5A DE AD BE EF 10 27`, read exact), same bitstream:
every nibble at the SCK rising edge is correct, and lines the chip holds high
stay solid for whole nibbles with no SCK-locked dips.

Full-logic-level dips locked to SCK edges are crosstalk onto lines nobody is
driving; driven lines in the passing read show none. **Reading: the 4-line
simultaneous rise on the PSRAM's own outputs disturbs the chip, which then
stops driving SIO for the rest of the read; the bus floats and holds high.**
This explains all the Part 8 signatures: the error follows the read (not the
stored data), the zero bytes past the line read `FF`, the address-independent
"stuck-high after a 3–4-line 0→1 nibble" rule, and, with weaker FPGA SCK drive
(`_drv`), the chip losing QPI mode altogether. The APS6404L's output drive is
fixed at 50 Ω (datasheet §8.3), so there is no firmware drive-strength fix.

Not proven: *why* the chip stops. It could be internal ground bounce from its
own SSO, or the ringing coupling into SCK/CE# at the chip as an extra edge.
A 5 ns ILA cannot see a sub-5 ns SCK glitch at the chip pin.

### Statistical campaign: 4,877 trials (2026-11-18/19)

`tools/risk72_bench/stats_campaign.py` writes an 8-byte line to a random
aligned address and reads it back twice. Lines are every nibble pair `ab`
repeated (×3 run 1, ×2 run 2) plus random lines, with the `A5 5A DE AD…`
reference every 50 trials. Run 2 adds a discriminator: on a failing read,
write zero lines on both sides and re-read from `a−1` and `a+1`.
`stats_analyze.py` classifies each read (pass / abort-high / abort-const /
nibble slip / last-nibble / other) and estimates the per-transition hazard:
aborts at a transition ÷ reads that reached it intact. Data:
`caps/2026-11-18/stats_run{1,2}.jsonl`, summary `stats_summary.json`. Same
`_risk72_oversample` image (JB/JC, full drive), capture ring off.

- **Overall:** pair lines 83.8% pass, random lines 63.0%; reference 97/97
  (the chip never lost state); the two reads agreed in 97% of trials. Run 1
  (2,824) and run 2 (2,053) agree to within a few percent.
- **Abort hazard by lines rising into the nibble:** 0 → 0.7% (n=16,810);
  1 → 0.4% (25,286); **2 → 0/14,148**; **3 → 11.9%** (2,886); **4 → 99.7%**
  (323). A sharp threshold at 3 simultaneous rising edges.
- **It is the rise, not the all-high state:** `F→F` 0/98; 1 line rising into
  `F` 1.3%, 2 rising into `F` 0/1,166; but 3 rising into `F` 47.4% (639).
  3-line rises that do not end at `F` abort 1.6% (2,459).
- **Falling edges barely matter:** 4 lines falling together aborted 0/88;
  3 falling 2.3–2.7%. The asymmetry (rising edges draw output current from
  the PSRAM's VDD) points at the chip's local supply/decoupling over ground.
- **Nibble slips are a second, separate mechanism:** 117/127 run-1 slips are
  `0→7` (SIO0–2 rise, SIO3 low): 51.5% slip rate on that transition, with no
  abort. SIO0/SIO1 share the JB connector with SCK. This fits edge coupling
  into SCK giving the chip an extra clock (not verified).
- **Write vs read (run 2):** a shifted re-read was exact (proving the stored
  line correct, so the fault is on the read) for 97/269 abort-high and 53/85
  slips. This is a lower bound: the shifted reads cross the same bad
  transitions, so "not exact" is inconclusive rather than write-side.
  Abort-const and "other" failures were mostly inconclusive (11/106, 13/147
  proven read-side). Some may be real write-side faults with the FPGA
  driving the same edges.

Consistent with the 200 MHz captures: a simultaneous-switching event on the
PSRAM's own outputs, with a clear dose-response in the number of rising
lines. This does not look like a protocol or RTL fault: the identical
transaction passes whenever the data avoids ≥3 simultaneous rises.

### A/B: the `/final` RTL (commit `7d0e749`) on the same bench — reads fail

`/final` (P&R job 5682) was built from commit `7d0e749` (2026-09-06). It
predates the uncommitted 2026-09-13/14 `#72` changes in `psram_buf_ctrl.v`
and `trouper_top.v`. Everything above was measured on the working tree. For
the A/B, the same bench image was rebuilt from a `git archive 7d0e749 src`
extract via the new `ASIC_SRC_DIR` env override in `create_project.tcl`
(bit/ltx `arty_dsp_emul_final7d0e749_oversample.*`, WNS +0.141 ns). The one
edit to the extract: an unused `PSRAM_QPI_CLK_DIV` parameter on
`trouper_top`, so the current wrapper can instantiate it. Same pins, drive,
firmware and capture ring off.

| | Working tree | `/final` (`7d0e749`) |
|---|---|---|
| Trials passing | 69% (4,877) | **0.3% (1/364)** |
| Reference `A5 5A DE AD BE EF 10 27` | 97/97 | **0/8** (`02 F5 E9 FE 9F BE FF 12`, deterministic) |
| Data on the pins, 200 MHz ILA | correct | **correct** (identical nibbles at the SCK edges) |

The chip outputs the right data under both RTLs; the `/final` controller
captures it wrongly. In `7d0e749`, `u_psram.sio_in` is the bare
`PSRAM_SIO_IN` pad sampled on the rising clock edge. On this rig the
SCK-to-data round trip puts that sample on the data transition: the ILA's
sample 5 ns before the edge still shows the old nibble. The working tree adds
`psram_sio_in_q`, a falling-edge capture register in `trouper_top.v`, which
samples mid-nibble. `/final` also has no `PSRAM_RD_TRIM`, so its capture
point cannot be moved by firmware.

**Tapeout reading:** the bench round trip (FPGA IO + flying leads + tACLK)
differs from the ASIC's (GF180 pad delays + PCB + tACLK). So this does not
prove `/final` fails in silicon. It does show that `/final`'s read capture
has no margin argument behind it: the PSRAM pad timing is still
unconstrained at signoff (Open Risks #69), and the one rig measured lands
exactly on the transition. `/final` should not be assumed to read PSRAM
correctly. The working-tree capture fix needs to reach a new P&R, or #69's
STA must show the bare-pad capture closes with real pad and PCB delays.

### VDD ripple, CE#-triggered and averaged (2026-11-19, working-tree image)

CH1 on PSRAM VDD (pin 8, 10×, AC, 20 mV/div), CH2 on CE# (pin 1, 10×),
both grounded at pin 4, triggered on CE# falling, TDS210 average of 64 reads
per stored line (`tools/risk72_bench/vddavg.py`, waveforms
`caps/2026-11-18/vddavg_*.json`). CE# low 999 ns per read, matching the ILA.
Readbacks with both probes attached matched the campaign: `00`/`03`/`A5`
pass, `07` slips, `0F` aborts.

| Stored line | Deepest dip, data phase (440–1000 ns) | Dip at 200–300 ns |
|---|---|---|
| `00` (nothing rising) | −28 mV | −110 mV |
| `03` (2 lines toggling) | −42 mV | −108 mV |
| `07` (3 lines toggling) | −82 mV | −112 mV |
| `0F` (4 lines; aborts) | −63 mV at the first `F` (400–500 ns), then flat | −112 mV |
| `A5…` reference (passes) | **−91 mV** | −109 mV |

- The largest dip, about −110 mV, sits at 200–300 ns (end of address /
  turnaround) for **every** pattern, passing ones included. It doesn't depend
  on the data, so it is probably the chip's internal array access, and it is
  not the failure trigger.
- Data-phase ripple grows with output switching (−28 → −42 → −82 mV). After
  `0F`'s first `F` the trace goes flat, which independently confirms the ILA
  reading that the chip stops driving after the abort.
- **VDD dip depth does not predict failure at this bandwidth:** the passing
  reference line dips deeper (−91 mV) than the failing `0F` event (−63 mV).
  Whatever upsets the chip on a 3–4-line rise is faster or more local than a
  60 MHz scope on the VDD pin can resolve, or it isn't the supply. Averaging
  across 64 reads would also smear sub-ns spikes. So supply droop is not
  confirmed as the mechanism. Edge coupling into SCK/CE# at the chip remains a
  candidate (next step 1).

### SIO0 at the PSRAM pin: the undriven line seen in analog (2026-11-19)

This capture was meant for SCLK, but CH1 was on pin 5 (SIO0); the trace
matches SIO0 bit-for-bit through the command and address phase. Single shots,
1 ns/sample, triggered on CE# falling (CH2 on pin 1), 4 reads each of stored
`03`, `0F`, `07` and `A5…` lines (`tools/risk72_bench/sckcap.py`, renamed
`caps/2026-11-18/sio0_*.json`).

- **The failure in analog:** in the `0F` read, after the first `F` nibble
  (~472 ns after CE# low), SIO0 never settles high or low. It wanders between
  **1.4 and 2.7 V** for the rest of the read. In the passing `03` read the
  same pin switches cleanly between ~0 V and the high level. A mid-rail,
  wandering level is an undriven line. It sits around the FPGA's ~1.5 V input
  threshold, which explains the ILA's SCK-locked `1110` dips (SIO0 pushed
  below threshold at each SCK edge). This directly confirms that the PSRAM
  stops driving after the 3–4-line rise.
- **Overshoot while the FPGA drives SIO0** (command and address phase): rings
  to **≥6.08 V**, clipped at the top of the 1 V/div screen, and down to
  **−1.6 V**, every read. That is far beyond a typical ±0.5 V-past-the-rails
  input absolute maximum. Cause: `SLEW FAST`, no termination, breadboard
  leads. A further reason for 22–33 Ω series resistors.
- **Unexplained:** with the chip driving SIO0 high (`03` read), CH1 reads
  3.8–4.3 V, above the 3.40 V rail. A true 4.2 V would forward-bias the
  chip's ESD diodes. Suspect CH1's ground lead or probe compensation; check
  before trusting CH1's absolute high level. The mid-rail and overshoot
  readings do not depend on it.

### SCLK at the PSRAM pin (pin 6), CE#-triggered (2026-11-19)

Same single-shot setup with CH1 moved to pin 6 (`sckcap.py`,
`caps/2026-11-18/sck_*.json`; 2 V/div unclipped shots `sck2v_*.json`).

- **Edge count is right:** exactly 32 SCK rising edges per read, all at
  31.25 ns spacing, in all 16 shots (`03`, `0F`, `07`, `A5…`). No extra or
  missing edge is visible at this bandwidth.
- **Severe ringing on SCK:** **+6.3 to +6.5 V and −2.1 to −2.2 V** at the
  PSRAM pin on every read, against a 3.4 V rail. That is ~3 V above VDD and
  ~2 V below VSS, far past the input absolute maximum, so the chip's input
  clamp diodes conduct on every edge. Measured through a 60 MHz front end,
  so the true peaks are at least this large. Injecting clamp current into the
  die on every clock edge is a credible way to upset the chip's internal
  state. It's a hypothesis, not shown: it doesn't by itself explain the data
  dependence.
- **The probe on SCK changes the failures, as in September:** with it
  attached, `07` read back exact 4/4 (it had slipped: `07 06 77…`), and `0F`
  survived two bytes (`0F 0F FF…` instead of `03 FF…`). The probe's ~15 pF
  damps SCK, which ties the slip mode and part of the abort mode to SCK
  signal integrity.

**Measurement limits (aliasing vs bandwidth):** the TDS210 sampled at 1 ns
(1 GS/s, Nyquist 500 MHz) behind a 60 MHz analog bandwidth. So the traces
are not aliased, but they are band-limited: ~6 ns rise time, with faster
ringing and sub-5 ns glitches attenuated or hidden. Peaks are lower bounds,
and "32 clean edges" doesn't exclude a sub-ns double-clock. The 200 MHz ILA
samples logic levels every 5 ns: enough for 31 ns nibbles, but a single-sample
event means "shorter than ~5 ns", not its true width. The averaged VDD traces
are further low-passed by trigger jitter.

### Damping SCK fixes the 3-line failures; the 4-line abort remains (2026-11-19)

`tools/risk72_bench/quick_load.py`: 15 reps each of the key lines at random
aligned addresses (`caps/2026-11-18/quick_*.jsonl`). CH2 stayed on CE#
(pin 1) throughout.

| Line | Campaign rate (SCK undamped) | A: CH1 probe on SCK, no R | B: 100 Ω series on SCK, no probe |
|---|---|---|---|
| `1F`, `8F` (3 rise → F) | 86% / 79% abort | 15/15, 15/15 pass | 15/15, 15/15 pass |
| `07` (3 rise, SIO3 low) | 51.5% slip | 15/15 | 15/15 |
| `0E`, `03` | ≤8% | 15/15 | 15/15 |
| `0F` (4 rise) | 99.7% abort | **0/15** | **0/15** |
| `A5…` reference | 97/97 | 3/3 | 3/3 |

Two independent ways of damping SCK (≈15 pF probe load, or 100 Ω series)
remove the nibble slips and the 3-line aborts entirely. **SCK ringing
(+6.5/−2.2 V) is the main mechanism**, most likely through the PSRAM
miscounting or mis-timing a ringing clock edge when 3+ of its outputs switch.
The 4-line simultaneous rise still aborts 100% under both, so a second,
SSO-driven mechanism (on-die bounce, or SIO→SCK coupling too strong for this
damping) remains.

**Same-session control C (resistor and SCK probe removed):** `0F` 0/15,
`1F` 15/15, **`8F` 3/15**, **`07` 11/15**, `0E` 15/15, `03` 15/15,
reference 3/3. The `8F` aborts come back strongly (15/15 damped vs 3/15
undamped; Fisher exact p ≈ 1e-5). The `07` slips come back but weakly
(15/15 vs 11/15, p ≈ 0.1 at n=15). `1F` passed undamped too this time,
against 86% abort in the campaign, so its rate varies across sessions or
wiring touches. n=15 per cell: enough for `8F`, too few for the rest.

**Run D: 100 Ω on SCK (Arty end) + 100 Ω on SIO0 and SIO1 (PSRAM end), no
probes on SCK/SIO.** A per-line walking test passed 3/3 on each of SIO0–3
and the reference 5/5, so all four lines work through the new wiring.
`quick_load.py`: identical to B. All 3-line lines 15/15, **`0F` still
0/15**. Damping the two SIO lines next to SCK does nothing for the 4-line
abort.

**Run E: one SIO resistor moved to SIO3** (100 Ω still on SCK). All four
lines passed the walking test 3/3. Results identical to D: every 3-line
line 15/15, **`0F` 0/15**. Untried: SIO2, or all four SIO lines together
(only three resistors on hand).

Caveat: 100 Ω slows the SCK edge: check it against
tKHKL ≤ 1.5 ns before treating it as a fix (22–33 Ω is the usual value).

### Next steps (not done)

0. Same-session control (no probe, no resistor) to confirm the 3-line
   failures return; then try series R on the four SIO lines for the 4-line
   abort; scope SCK edge rate with the 100 Ω in.
1. Scope SIO3 at the PSRAM pin (short ground spring to PSRAM VSS) during a
   failing read: floating lines should show slow droop and coupling spikes,
   not a solid driven level. Then scope SCK at the chip during the same read
   for a glitch at ~485 ns.
2. Hardware fixes, in order: 22–33 Ω series resistors at the PSRAM SIO pins
   (damps the chip's own output edges) and on SCK; 100 nF + 1 µF at the chip's
   VDD/VSS; a shorter, doubled ground return (the +80 mV idle offset).
3. Tapeout relevance: the same 4-line SSO from the PSRAM into the ASIC's
   `PSRAM_SIO` pads on the AFE/system PCB should get series termination on
   the board. Note under Open Risks #69.

## Open items

- Open Risks #69's SDC action (measured PCB trace-delay baseline in the
  signoff constraints) is still open and unaffected by this session — this
  bring-up work is evidence for that risk, not a substitute for closing it.
- `arty_dsp_emul_extpsram.bit`/`_8mhz`/`_5mhz` variants and the bit-bang
  harness project live only under the session scratchpad and
  `fpga-emul/arty_dsp_emul_extpsram.bit` — not committed; rebuild via the new
  Makefile targets if needed again.
- **Open Risks #72 (new): real-hardware debug-port reliability, root cause
  not found.** Blocks the injection-based full-chain test until resolved or
  worked around. `tb_psram_delay.v` / `tb_trouper_psram_delay.v` (the
  delay-injection cosims that cleared the RTL) also live only under the
  session scratchpad / NFS `psram_delay_isolate/` — not committed.
