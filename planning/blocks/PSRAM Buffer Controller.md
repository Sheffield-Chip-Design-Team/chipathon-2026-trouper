# PSRAM Buffer Controller

External-memory subsystem for the Trouper receive chain. One shared QPI engine serving the external APS6404L provides three user-facing functions — **SC correlator delay RAM**, **same-packet capture & continuous-delay replay**, and **host debug readback** — specified in Trouper Chip Specification §4.10.1–§4.10.4. This document carries the implementation detail the spec stays terse on.

**Owner:** TBD
**Status:** Implemented (`src/control/psram_buf_ctrl.v`; suites `cocotb/replay_delay`, `cocotb/replay_data`, `cocotb/psram_ops`, `cocotb/qspi_owner` — SGE jobs 3347/3350/3354/3355; k-induction formal harness in `formal/`)
**Target device:** APS6404L-3SQR (AP Memory, 64 Mbit QPI PSRAM)
**Design record:** `planning/psram-replay-continuous-delay-redesign.md` (2026-07-12 replay redesign)

> Superseded content note: earlier revisions of this document described a W_COMMIT-triggered
> rewind replay, a JTAG/QPI pad mux, functional sample-width selection, and a 16 MHz controller-clock
> constraint. None of these exist: replay is margin-timed continuous-delay, the four SIO pads
> are dedicated (JTAG removed, spec §4.16), storage is fixed 8 bytes/sample
> (`PSRAM_CTRL[2]` is reserved, ignores writes, and reads zero), and the
> controller runs at 32 MHz.

---

## Function 0 — Shared QPI core (spec §4.10.1)

### Power-up initialisation

The device powers on in SPI mode. `init_start` is the register **level** `PSRAM_CTRL.PSRAM_EN & ~QSPI_OWNER` — not a firmware-pulsed strobe. RTL enforces no on-chip tPU wait, so firmware must not set `PSRAM_EN=1` until ≥ 150 µs after PSRAM power-up (Open Risks #27.1; `cocotb/tests/test_startup.py::test_psram_init_has_no_tpu_wait`). Once triggered:

1. **RSTEN** `0x66` — SPI, serial on SIO[0]
2. **RST** `0x99` — SPI, serial on SIO[0]; wait tRST ≥ 50 ns (measured 750 ns gap, `test_startup.py::test_qe_init_trst_margin`, job 3257)
3. **Enter QPI** `0x35` — SPI, serial on SIO[0]
4. Assert `qe_init_done`; all subsequent accesses are QPI

Init runs through the same serializer as QPI traffic (SPI = single-lane degenerate case: 1-bit lane-mode flag + stride/OE muxing, no second datapath). `x4` is set only after `0x35` has fully clocked out and clears only on reset.

### Sub-cycle budget (32 MHz, iq_valid every 64 clocks = 2.0 µs at 500 kS/s)

| Phase | QPI activity | Cycles | Spare |
|---|---|---|---|
| S_WRITE (pre-lock) | 8-byte write (25) + SC delay read (19) | 44 | **20** |
| S_REPLAY | 8-byte write (25) + replay read (31) | 56 | **8** |

Debug-readback fetches are serviced only in the S_WRITE idle slot, capture writes take priority. QPI-only mandate (TRPR-PSR-018): SPI-mode equivalents are ~200 cycles — 3× over budget — and cost zero fewer pads.

### APS6404L timing compliance at 32 MHz

| Parameter | Requirement | At 32 MHz |
|---|---|---|
| tCEM — max CE# low | ≤ 8 µs | < 1 µs ✓ |
| tCPH — CE# high between bursts | ≥ 18 ns | 31.25 ns (1 cycle) ✓ |
| tCLK — min clock period | ≥ 7.5 ns | 31.25 ns ✓ |
| tRST — RST → next command | ≥ 50 ns | 750 ns ✓ (measured, job 3257) |

Device runs at 24% of rated speed; refresh is self-managed (CE# deasserts between transactions; bus idle ≥ 31% of every sample period even in S_REPLAY).

### Pad ownership

`QSPI_OWNER` (0x70[3]) = 1 releases the pads for a future firmware-managed external-memory mode: CE# de-asserted, SCK gated, SIO tri-stated, BUFFERING/REPLAY suspended, `DBG_BUSY` held. Ownership changes take effect at the next QPI **burst boundary** (not "in IDLE" — the effective-owner latch `qspi_owner_eff` was added after job 3314 found a mid-burst SCK-freeze glitch, Open Risks #37). Buffering and replay resume when ownership returns.

### Registers (shared)

`PSRAM_CTRL` 0x70: [0] `PSRAM_EN`, [1] `PSRAM_CLR_ERR` (W1P), [3] `QSPI_OWNER`; other bits reserved.
`PSRAM_STATUS` 0x71: [1:0] `STATE`, [2] `SAMPLE_SKIP` (sticky), [3] `INIT_DONE`, [4] `REPLAY_ACTIVE`, [5] `REPLAY_MISSED` (sticky), [6] `OVERFLOW` (sticky), [7] `BUF_ACTIVE`. Sticky flags clear via `PSRAM_CLR_ERR`; a set coincident with a clear is not lost (formal `a_replay_missed_sticky`/`a_sample_skip_cause`).

---

## Function 1 — SC correlator delay RAM (spec §4.10.2, TRPR-FBC-001…005 / PSR-016/019/021)

Serves the SC detector's M-sample delayed stream `x[n−M]`, M = 1 << (SF + sample_shift). Worst case SF12/125 kHz: M = 16384 samples = 128 kB — this is why the on-chip SRAM (512×8) was removed and the delay lives off-chip.

- On each `iq_valid` (pre-lock), after the capture write, the controller issues a QPI read at `write_ptr − M×8` bytes and presents `del_i0/del_q0` + `del_valid` to the SC detector before the next `iq_valid`. `cur_i0/cur_q0` are captured from the write data at write-done time — same branch, aligned pair.
- **Branch select** (`sc_ant_sel`, BW_CFG 0x0A[2:1]): routes which of the four branches feeds the correlator's cur/del pair. Write-locked during `packet_active`. This is the cheap mitigation for the antenna-0 deep-fade SPOF (Open Risks #9); the correlator itself remains single-branch.
- **Warm-up:** `del_valid` (via `del_rdy`) is suppressed until N = M fresh samples have been captured since `qe_init_done`; the warm-up re-arms whenever `sf` or `sample_shift` changes (SF is fixed per session — TRPR-PSR-019). This warm-up also provides the DC-removal settling hold-off structurally (TRPR-DCR-015).
- After `sc_lock`, SC delay reads cease until the packet FSM returns to IDLE.

---

## Function 2 — Same-packet capture & continuous-delay replay (spec §4.10.3)

The "FIFO" between capture and weight availability. Capture never stops; replay is a fixed-depth delay line that starts on a timer, not on the weight commit.

### Sequence

1. **Capture (always, from power-on):** every decimated sample (8 bytes: i0,q0,…,i3,q3) is written to a circular buffer. At `sc_lock`, the current write address is latched as `buf_base`.
2. **Margin (armed at `training_done`):** a countdown of `REPLAY_DELAY_SAMPLES` (regs 0x77/0x78, reset 1500 ≈ 3 ms at 500 kS/s) captured samples begins. This is the firmware weight-computation window: sized to the measured Grouper rv32emc 8-iteration eigenvector cost (~2.3 ms incl. readout/IRQ overhead — `planning/blocks/Eigenvector Weight Computation.md`). Write-gated `!packet_active`.
3. **Replay (margin expiry):** `REPLAY_ACTIVE` asserts; the read pointer starts at `buf_base` and advances in lockstep with ongoing capture writes. The rd/wr gap is fixed for the rest of the packet — the PSRAM is a delay line that **never rewinds** (monotonic `rd_ptr`, checked in `cocotb/tests/test_replay_delay.py`; this is what satisfies TRPR-RMD-009 at the re-modulator input). The combiner receives the full stored packet including preamble at the live 500 kS/s rate.
4. **Weights:** `W_COMMIT` does not start, stop, or reposition replay — it only gates `W_VALID` in the combiner. Until it arrives, the replayed stream is combined in bypass (lowest-enabled antenna): a late or absent commit degrades gain, never produces silence or a time-index discontinuity. A commit after replay start sets sticky `W_COMMIT_LATE` (WGT_CTRL 0x1E[4]); no commit before `packet_end` latches sticky `REPLAY_MISSED` and invalidates the packet base (a later commit is inert — verified `test_psram_ops.py::test_replay_missed_late_commit`, job 3313).
5. **Packet end:** `REPLAY_ACTIVE` de-asserts; circular capture resumes.

Downstream, the SX1302 sees silence during the pre-replay window and then the complete packet (real preamble, delayed), so its own correlator locks normally. Introduced latency ≈ (training-window + margin) ≈ 8M + 1500 samples: ~5 ms at SF7/250 kHz up to ~265 ms at SF12/125 kHz — acceptable for LoRa.

### Capacity

| Quantity | Value |
|---|---|
| Storage format | 8 bytes/sample (int8 I+Q × 4 branches) — fixed, no other width |
| Write rate | 4 MB/s at 500 kS/s (~6% of device capability) |
| Max occupied depth (SF12) | ≈ 8 × 2^14 samples × 8 B ≈ 1 MiB at 125 kHz — APS6404L 8 MB, ≥ 8× headroom |
| Overflow / skip observability | sticky `OVERFLOW` (0x71[6]), sticky `SAMPLE_SKIP` (0x71[2], must stay 0 in-budget — TRPR-PSR-020) |

---

## Function 3 — Host debug readback (spec §4.10.4, TRPR-PSR-017)

Register-mediated PSRAM reads over host SPI — no Grouper required. Highest-value bring-up feature: problematic packets (false locks, weight misses, saturated captures) are inspected from the actual stored samples instead of being reproduced over the air.

Protocol: write 23-bit address to 0x72–0x74 → `RD_TRIG` (0x75[0]) → poll `DBG_BUSY` (0x75[7], ≤ ~1 µs) → read `PSRAM_DBG_DATA` (0x76) ×8 (bytes i0,q0,…,i3,q3) → optional `AUTO_INC` (0x75[1]) re-arms at +8. 0x76 is exempt from SPI burst auto-increment (TRPR-SPS-010). Blocked (`DBG_BUSY` held, data reads 0x00) while `packet_active=1`, `QSPI_OWNER=1`, or before `INIT_DONE`. Fetches use S_WRITE idle sub-cycles; capture writes always win. Verified bit-exact against the behavioural PSRAM model's memory (`test_psram_ops.py::test_dbg_readback_content`, job 3313).

---

## Interface summary

Port groups on `psram_buf_ctrl` (see RTL for the full list): config (`psram_en`, `init_start`, `qspi_owner`, `sf`, `sample_shift`, `sc_ant_sel`), live IQ in (4 × int8 I/Q + `iq_valid`), packet events (`sc_lock`, `training_done`, `packet_end`, `w_commit`, `clr_err`), SC delay out (`cur_*`, `del_*`, `del_valid`), replay out (`rpl_*`, `replay_active`), debug port (addr/trig/data to reg_bank), QPI pads (`sck_en`, `ce_n`, `sio_out/in/oe[3:0]`), status (`qe_init_done`, `buf_active`, sticky flags).

---

## Future capabilities enabled by packet memory (aspirational — none implemented)

Because the PSRAM stores packets rather than acting only as a live delay line, firmware-driven extensions are possible without RTL change (via debug readback) or with modest RTL change: extended/multi-window training accumulation and channel-stability checks, longer noise-estimation windows, offline combiner-law comparison on identical packets, adaptive reference-branch selection, packet-failure capture libraries, calibration/mismatch characterisation from stored raw packets. Priority order if revisited: debug capture analysis → longer noise windows → multi-window stability checks. None are tapeout-scope.

---

## Verification status

| Area | Coverage |
|---|---|
| QE init + tRST | `test_startup.py` (job 3257) — measured, plus the documented tPU gap (Open Risks #27.1) |
| Capture + SC delay correctness | `test_capture_playback.py` (full-chain sc_lock via real delayed samples); formal `a_del_valid_needs_rdy`, `a_del_cnt_bounded`, `a_gap_invariant` |
| Continuous-delay replay | `cocotb/replay_delay` + `cocotb/replay_data` (jobs 3347/3350): margin timing, monotonic rd_ptr, bit-exact replayed data |
| Late/missed commit | `test_psram_ops.py` (job 3313): REPLAY_MISSED latch/clear/inert-commit |
| Ownership handover | `test_qspi_owner.py` (job 3314): burst-boundary handover, no pad glitch, resume |
| Debug readback | `test_psram_ops.py::test_dbg_readback_content` (job 3313): bit-exact vs stored nibbles |
| Branch select | `cocotb/sc_ant_sel` suite: delay-line branch routing + packet write-lock |
| Formal | k-induction on pointer/gap/flag invariants (`ifdef FORMAL` direct instantiation — yosys 0.64 drops `bind` silently). Harness predates the continuous-delay merge in places; re-validate before relying on replay-side assertions |

---

## Related blocks

- [Packet Control FSM](Packet%20Control%20FSM.md) — `sc_lock`, `packet_end`, packet_active gating
- [ΣΔ Decimator](ΣΔ%20Decimator.md) — live `iq_in`
- [SC Detector](SC%20Detector.md) — consumes the delay-line `cur/del` pair
- [MRC Combiner](MRC%20Combiner.md) — combines the replayed stream; `W_COMMIT`/`W_VALID` gating
- [Register Map](../Register%20Map.md) — 0x70–0x78 (control/status/debug/replay margin), WGT_CTRL 0x1E[4]
