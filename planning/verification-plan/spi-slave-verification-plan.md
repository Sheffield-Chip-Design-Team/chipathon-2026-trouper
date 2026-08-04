# SPI Slave — Verification Plan

**DUT:** `src/control/spi_slave.v` (mirrored to
`rtl-test/rtl/spi_slave.v`)

**Scope:** SPI Mode-0 framing, command decode, single and burst register
access, first-read-byte timing, frame abort/reset behavior, SPI-to-32 MHz CDC,
read-side-effect delivery, and Grouper/SPI arbitration at the
`trouper_top.v` integration boundary.

**Inputs reviewed:** `planning/Trouper Chip Specification.md` (§4.11
TRPR-SPS-001..011), `planning/Register Map.md`, `planning/Traceability.md`,
`planning/Open Risks.md` (#15, #16, #26, #38),
`planning/spi-slave-cdc-and-10mhz-timing-plan.md`,
`planning/blocks/SPI Slave.md`, `src/top/trouper_top.v`, the current RTL,
`cocotb/spi_cdc`, `cocotb/psram_ops`, and
`rtl-test/tb/tb_trouper_spi.v` and `tb_trouper_grp_arb.v`.

This is the block-level closure tracker for `spi_slave`. Register contents,
permissions, and control/status semantics belong to the separate
`reg-bank-verification-plan.md`.

---

## 1. Current methodology, and the path to constrained random

**Today:** normal SPI transactions and the persistent-toggle CDC have strong
directed integration coverage, including the 0x76 continuous-burst exception,
and there is now a standalone protocol oracle. The MISO-drive and
Grouper-arbitration requirement conflicts are resolved. Verification is not
closed because there is no formal checker yet, and 10 MHz physical timing
remains unsigned off.

- **Full-top cocotb simulation** — `cocotb/spi_cdc` has nine scenarios with a
  three-level scoreboard requiring completed SPI bytes, synchronized
  `reg_we`/`reg_re`, and CE-accepted writes to match one-for-one. It covers
  randomized SCK/core phase, 10 MHz operation, minimum CS spacing, continuous
  writes, reset interruption, aborted frames, read side effects (both
  separate-transaction and continuous CS-low burst at 0x76, the latter
  spanning the PSRAM debug engine's AUTO_INC refetch boundary), and W1P
  exactly-once delivery.
- **Standalone cocotb simulation** — `cocotb/spi_slave` instantiates
  `spi_slave.v` directly (not `trouper_top.v`), serviced by an independent
  dict-backed register stub (not `reg_bank.v`). `spi_slave_model.py` is a
  from-spec Python protocol oracle (command decode, 7-bit address
  progression including modulo-128 wrap and the 0x76 no-increment exception,
  first-data-byte timing, and the read-vs-write event-timing asymmetry: a
  write event fires only on its own completed 8th bit, a read event fires as
  soon as its own first bit starts). `test_spi_slave.py` cross-checks this
  model bit/byte-wise against the DUT over a deterministic wrap/no-inc case,
  150 randomized legal frames, and 80 randomized constrained aborts, and adds
  dedicated MISO byte-atomicity (row #11) and deselected-clock/command-only-
  frame-recovery (row #12) cases.
- **Legacy directed simulation** — `tb_trouper_spi.v` covers Mode 0 at 10 MHz,
  first-data-byte timing, ordinary burst access, modulo-128 wrap, and 0x7F.
  `tb_trouper_grp_arb.v` covers basic collisions and recovery.
- **No formal checker yet** — no property proves event conservation or
  bundled-mailbox stability; row #15 is still open.
- **No merged code or functional coverage** — closure remains scenario-based.
- **Physical timing remains open** — Open Risk #38 records that production SDC
  false-paths `SPI_SCK`, so RTL operation at 10 MHz does not prove MOSI
  setup/hold, the command-to-first-MISO-bit half-cycle path, or mailbox timing
  at signoff corners.

The active order is:

1. ~~Extend the existing CDC suite for the continuous 0x76 burst.~~ Done (job
   3865) — see `test_read_side_effect_continuous_burst` in
   `cocotb/spi_cdc/test_spi_cdc.py`.
2. ~~Add a standalone SPI harness and independent protocol model.~~ Done (job
   3868) for #11 (standalone half only; the top-level Grouper-address-change
   contention case is still open) and #14; see `cocotb/spi_slave`. Row #12 is
   fully closed by the same job. Row #13 (formal/analysis) is unaffected and
   remains open, deferred to step 3 below.
3. Add formal event-conservation and mailbox properties, and row #13's legal
   byte-spacing proof.
4. Instrument and close code/functional coverage.
5. Complete CDC/RDC, STA, gate-level, and bench signoff.

### 1a. Coverage model

At minimum, collect:

- `{read, write} × {single, burst} × {address 0x00, ordinary, 0x76, 0x7E,
  0x7F}` including modulo-128 wrap;
- command and data bytes with zero, ones, walking-one, walking-zero, and
  non-symmetric values;
- SCK frequency buckets from slow through exactly 10 MHz crossed with the full
  SCK/core relative phase range;
- minimum/legal CS lead, trail, and inter-transaction spacing;
- CS deassertion and reset at every command/data bit and at every
  synchronizer/write-extension phase;
- completed source byte crossed with `{exactly one destination event}` and
  partial byte crossed with `{no event}`;
- read-side-effect address and event count, including multiple data bytes
  under one CS assertion;
- first MISO data-bit timing and byte snapshot stability;
- Grouper/SPI overlap during command, data, toggle generation, synchronizer
  transit, extended `reg_we`, CE capture, and MISO load.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed test of a numbered requirement;
**EDGE-SIM** = robustness test found by RTL review; **FORMAL** = property proof;
**CDC/STA** = structural/timing signoff; **INTERFACE/SYSTEM** = behavior partly
owned outside `spi_slave`.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | Mode-0, MSB-first single write/read and 2-byte first-data-byte timing | SPEC-SIM | `tb_trouper_spi.v`; `cocotb/spi_cdc` | TRPR-SPS-001/002/003/006/009 | ✅ done (job 3865) — the reg-bank reserved-bit alignment (commit `78e8c6b`) had already corrected the legacy test's `BW_CFG` mask expectation to `0x07`; reran `tb_trouper_spi.v` at 10 MHz clean (all 42 checks, including the one-byte-late-bug guard and the 2-byte CHIP_ID first-data-byte timing check) plus `cocotb/spi_cdc` (9/9) |
| 2 | First transaction after reset, without warm-up | EDGE-SIM | cocotb bring-up; `test_reset_interruption` | Open Risk #26; TRPR-SPS-005 | ✅ done |
| 3 | Completed write survives immediate legal CS deassertion exactly once | SPEC-SIM | `test_back_to_back_min_cs`, `test_randomized_clock_phase` | Open Risk #15; TRPR-SPS-003/005 | ✅ done (job 3352) |
| 4 | Continuous burst write/read, increment, and modulo-128 wrap | SPEC-SIM | `test_continuous_burst`; `tb_trouper_spi.v` | TRPR-SPS-010 | ✅ done for ordinary addresses and 0x7E→0x7F→0x00 |
| 5 | Continuous CS-low read burst at 0x76 holds address and emits one read-side-effect event per byte | SPEC-SIM | extend `cocotb/spi_cdc` with PSRAM model | TRPR-SPS-010 | ✅ done (job 3865) — added `test_read_side_effect_continuous_burst` to `cocotb/spi_cdc/test_spi_cdc.py`: one CS-low frame, 16 consecutive data-byte reads of 0x76 (spanning the PSRAM debug engine's 8-byte `dbg_buf`/AUTO_INC refetch boundary), asserting `cur_addr` stays pinned at 0x76 and exactly one `reg_re` fires per byte throughout |
| 6 | Dedicated MISO drives low while CS is high | SPEC-SIM / INTERFACE | `tb_trouper_spi.v` idle and post-read checks | TRPR-SPS-008 | ✅ resolved (job 3863) — selected pinout dedicates MISO to Trouper; requirement now matches the deterministic-low RTL (tri-state/OE is not required) |
| 7 | Randomized SCK/core phase, CS timing, and supported-rate sweep | SPEC-SIM / CDC | `test_randomized_clock_phase`, `test_clock_limit_sweep` | TRPR-SPS-004/005 | ✅ RTL simulation (job 3352) — 100 kHz, 1/8/10 MHz required; 12 MHz diagnostic |
| 8 | Abort CS at every command/data bit and reset during frame/CDC/write extension | EDGE-SIM | `test_aborted_frame`, `test_reset_interruption` | TRPR-SPS-001/005 | ✅ done (job 3352) |
| 9 | Source-byte ↔ synchronized-event ↔ accepted-write conservation | EDGE-SIM + FORMAL | all `cocotb/spi_cdc` scoreboard tests; formal checker | CDC mailbox contract | ✅ simulation (job 3352); ⬜ formal proof |
| 10 | Grouper priority with preservation or defined rejection of overlapping SPI access | SPEC-SIM / INTERFACE | `tb_trouper_grp_arb.v` full-strobe write overlap and MISO-load read overlap | TRPR-SPS-007; Open Risk #16 | ✅ resolved (job 3863) — one-entry pending slot preserves a completed SPI write until the Grouper byte cycle releases; an overlapping SPI read is explicitly invalid and retried because pin-level SPI has no WAIT response |
| 11 | Read byte remains stable despite live-status or Grouper-address changes | EDGE-SIM | standalone suite plus top-level contention case | asynchronous peek/MISO contract | 🟨 partial (job 3868) — `test_byte_atomicity_live_status_change` in `cocotb/spi_slave/test_spi_slave.py` proves the standalone-DUT half: a live register value change injected at every bit position from the load instant (bit 8) through the last shifted bit (bit 16) never appears in the byte already in flight, and is visible on the very next independent read. The Grouper-address-change top-level contention case named by the row is not covered — still open |
| 12 | SCK while deselected, runt frames, and repeated command-only frames | EDGE-SIM | standalone suite | frame-reset robustness | ✅ done (job 3868) — `test_deselected_clock_no_effect` (64 SCK toggles at CS high produce no `reg_we`/`reg_re`, slave still works afterward) and `test_command_only_frame_recovery` (write-only and read-only command-only frames, plus 20 repeated command-only frames, produce no event and leave the slave clean for the next transaction) added to `cocotb/spi_slave/test_spi_slave.py`; partial-frame sweep from row #8 (`test_aborted_frame`) already covered the rest |
| 13 | All source events sufficiently separated at 10 MHz | FORMAL / ANALYSIS | formal assumptions plus CDC report | toggle-event distinguishability | ⬜ new — unchanged; this is a formal/CDC-report row, out of scope for the cocotb standalone suite added for #11/#12/#14, and deferred to row #15's formal effort |
| 14 | Standalone randomized protocol reference-model regression | EDGE-SIM | new `cocotb/spi_slave` | coverage gap | ✅ done (job 3868) — new `cocotb/spi_slave` instantiates `spi_slave.v` directly against an independent dict-backed register stub (not `reg_bank.v`); `spi_slave_model.py` is a from-spec Python oracle (command decode, 7-bit address progression incl. modulo-128 wrap and the 0x76 no-increment exception, and the read-vs-write event-timing asymmetry) cross-checked bit/byte-wise against the DUT over a deterministic wrap/no-inc case, 150 randomized legal frames, and 80 randomized constrained aborts; full existing regression (`spi_cdc` 9/9 job 3869, `psram_ops` 3/3 job 3869, `tb_trouper_spi.v`/`tb_trouper_grp_arb.v` job 3870) reran clean alongside it |
| 15 | Full SPI CDC property set, non-vacuous | FORMAL | new `formal/spi_slave_formal.sv` + `.sby` | TRPR-SPS-003/005 | ⬜ new — prove no loss/duplication, mailbox stability, partial-frame suppression, CS frame reset, and legal address progression |
| 16 | SPI CDC/RDC structural review | CDC/STA | signoff CDC/RDC tool | TRPR-SPS-005; Open Risk #38 | ⬜ planned — document intentional resets, two-FF toggle synchronizers, and bundled-data crossings |
| 17 | Explicit 10 MHz SCK constraints and all-corner timing | CDC/STA | production P&R/STA | TRPR-SPS-004/009; Open Risk #38 | ⬜ planned — constrain SCK, MOSI, MISO, clock groups, and mailbox settling; report half-cycle setup/hold and unconstrained endpoints |
| 18 | Post-synthesis/post-route minimum-CS and first-read-bit simulation | GATE-SIM | netlist/SDF harness | TRPR-SPS-004/005/009 | ⬜ planned |
| 19 | Raspberry Pi 10 MHz bench test with measured MISO margin | SYSTEM | silicon/board bring-up | TRPR-SPS-001/004/008/009 | ⬜ planned — verify normal CS timing needs no workaround and measure setup/release behavior |

### 2a. Directed closure order

1. ~~Add the continuous 0x76 burst test in #5 and refresh the legacy
   regression in #1.~~ Done (job 3865): #5's `test_read_side_effect_continuous_burst`
   passes, and #1's legacy `tb_trouper_spi.v` reran clean at 10 MHz — its
   `BW_CFG` mask expectation was already corrected to `0x07` by the reg-bank
   reserved-bit alignment (commit `78e8c6b`), so no test edit was needed there,
   only the rerun.
2. ~~Build the standalone protocol model for #11–#14.~~ Done (job 3868):
   `cocotb/spi_slave` + `spi_slave_model.py` close #14, close #12, and close
   the standalone-DUT half of #11 (MISO byte-atomicity under a live register
   change). #11's top-level Grouper-address-change contention case is not
   covered by this standalone suite and remains open. #13 is a formal/
   analysis row, untouched by this step, and stays open pending step 3.
3. Add the formal checker in #15 and verify non-vacuity, and prove #13's
   legal byte-spacing bound alongside it.
4. Merge code and functional coverage, then randomize until §1a closes.
5. Complete CDC/STA/gate/bench rows #16–#19.

---

## 3. Regression commands

Run inside the chipathon26 EDA container:

```bash
(cd cocotb/spi_cdc && make)
(cd cocotb/psram_ops && make)
(cd cocotb/spi_slave && make)   # standalone protocol-model regression; rows #11 (partial), #12, #14

# From rtl-test/:
iverilog -g2005 -o /tmp/tb_trouper_spi.vvp \
  tb/tb_trouper_spi.v \
  ../src/top/trouper_top.v ../src/decimator/sd_decimator_poly.v \
  ../src/frontend/dc_removal.v ../src/frontend/sc_detector.v \
  ../src/combiner/training_acc.v ../src/combiner/mrc_combiner.v \
  ../src/control/packet_ctrl_fsm.v ../src/control/psram_buf_ctrl.v \
  ../src/control/spi_slave.v ../src/control/reg_bank.v \
  ../src/remod/sd_remod.v
vvp /tmp/tb_trouper_spi.vvp

iverilog -g2005 -o /tmp/tb_trouper_grp_arb.vvp \
  tb/tb_trouper_grp_arb.v \
  ../src/top/trouper_top.v ../src/decimator/sd_decimator_poly.v \
  ../src/frontend/dc_removal.v ../src/frontend/sc_detector.v \
  ../src/combiner/training_acc.v ../src/combiner/mrc_combiner.v \
  ../src/control/packet_ctrl_fsm.v ../src/control/psram_buf_ctrl.v \
  ../src/control/spi_slave.v ../src/control/reg_bank.v \
  ../src/remod/sd_remod.v
vvp /tmp/tb_trouper_grp_arb.vvp
```

Add the standalone and formal commands when implemented. Run this regression
before merging changes to `spi_slave.v`, SPI protocol requirements,
`trouper_top.v`'s arbiter/read-side-effect wiring, or SPI timing constraints.

---

## 4. Explicit non-goals and interface boundaries

- Register values, permissions, W1P/W1C semantics, and IRQ behavior belong to
  `reg-bank-verification-plan.md`. This plan checks their transport only.
- Firmware-load/CPU-SRAM extended commands still described in
  `planning/blocks/SPI Slave.md` are obsolete. Current TRPR-SPS and
  `Register Map.md` define no extended protocol; 0x7F is only a reserved future
  escape.
- SPI reads use the asynchronous register-bank `peek_rdata` path, not an
  internal read-response handshake.
- Arbitration, CE write acceptance, and read-side-effect routing live in
  `trouper_top.v`; they remain integration tests because they determine whether
  SPI events reach their consumers.
- Board timing and pad electrical behavior require rows #16–#19 and cannot be
  proven by RTL simulation.
