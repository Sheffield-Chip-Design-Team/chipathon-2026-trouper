# SPI Slave — Verification Plan

> **UPDATE 2026-09-01 — Grouper is not taping out.** The `GRP_*` byte bus, the
> AHB-Lite `H*` endpoint and `IRQ_GROUPER` were removed from
> `src/top/trouper_top.v`, and `rtl-test/tb/tb_trouper_grp_arb.v` was deleted.
> Every row below concerning Grouper access, priority or SPI-vs-Grouper
> arbitration is **VOID** — host SPI is the sole register master and there is
> nothing left to arbitrate. Rows are kept for traceability, not as open work.


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
and there is now a standalone protocol oracle plus a two-clock formal checker
(`formal/spi_slave_formal.sv`/`.sby`, SGE jobs 4854/4855) proving event
conservation, mailbox stability, partial-frame suppression, CS frame reset,
legal address progression, and the row #13 legal-byte-spacing bound. The
MISO-drive and Grouper-arbitration requirement conflicts are resolved.
Verification is not closed because 2 MHz physical timing remains unsigned off
(rows #16-#19) and code/functional coverage is not yet merged.

- **Full-top cocotb simulation** — `cocotb/spi_cdc` has eleven scenarios with a
  three-level scoreboard requiring completed SPI bytes, synchronized
  `reg_we`/`reg_re`, and CE-accepted writes to match one-for-one. It covers
  randomized SCK/core phase, 2 MHz operation, minimum CS spacing, continuous
  writes, reset interruption, aborted frames, read side effects (both
  separate-transaction and continuous CS-low burst at 0x76, the latter
  spanning the PSRAM debug engine's AUTO_INC refetch boundary), W1P
  exactly-once delivery, and (closing row #11's top-level half) a concurrent
  Grouper read/write pulse to a different address landing mid-MISO-shift of
  an in-flight SPI read byte, via the real `trouper_top.v` arbiter wiring
  (`cocotb/hdl/tb_trouper_cocotb.v` now exposes a drivable `GRP_*` handle for
  this, additive and tied-0 by default like before for every other suite).
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
- **Formal checker done** (rows #13/#15, SGE jobs 4854/4855) — event
  conservation, bundled-mailbox stability, partial-frame suppression, CS frame
  reset, legal address progression, and the legal-10-MHz-byte-spacing bound are
  now proved (bounded, reset-anchored BMC; see rows #13/#15 for detail).
- **No merged code or functional coverage** — closure remains scenario-based.
- **Physical timing remains open** — Open Risk #38 records that production SDC
  used to false-path `SPI_SCK`; the new 2 MHz baseline SDC removes that error,
  but zero board-delay constraints do not prove MOSI
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
3. ~~Add formal event-conservation and mailbox properties, and row #13's legal
   byte-spacing proof.~~ Done (SGE jobs 4854/4855): `formal/spi_slave_formal.sv`/
   `.sby` closes both #13 and #15 — see their status cells.
4. Instrument and close code/functional coverage.
5. Complete CDC/RDC, STA, gate-level, and bench signoff.

### 1a. Coverage model

At minimum, collect:

- `{read, write} × {single, burst} × {address 0x00, ordinary, 0x76, 0x7E,
  0x7F}` including modulo-128 wrap;
- command and data bytes with zero, ones, walking-one, walking-zero, and
  non-symmetric values;
- SCK frequency buckets through exactly 2 MHz crossed with the full
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
| 1 | Mode-0, MSB-first single write/read and 2-byte first-data-byte timing | SPEC-SIM | `tb_trouper_spi.v`; `cocotb/spi_cdc` | TRPR-SPS-001/002/003/006/009 | ✅ done — 10 MHz historical run (job 3865) is retained as over-spec stress evidence; 2 MHz remains the supported limit. |
| 2 | First transaction after reset, without warm-up | EDGE-SIM | cocotb bring-up; `test_reset_interruption` | Open Risk #26; TRPR-SPS-005 | ✅ done |
| 3 | Completed write survives immediate legal CS deassertion exactly once | SPEC-SIM | `test_back_to_back_min_cs`, `test_randomized_clock_phase` | Open Risk #15; TRPR-SPS-003/005 | ✅ done (job 3352) |
| 4 | Continuous burst write/read, increment, and modulo-128 wrap | SPEC-SIM | `test_continuous_burst`; `tb_trouper_spi.v` | TRPR-SPS-010 | ✅ done for ordinary addresses and 0x7E→0x7F→0x00 |
| 5 | Continuous CS-low read burst at 0x76 holds address and emits one read-side-effect event per byte | SPEC-SIM | extend `cocotb/spi_cdc` with PSRAM model | TRPR-SPS-010 | ✅ done (job 3865) — added `test_read_side_effect_continuous_burst` to `cocotb/spi_cdc/test_spi_cdc.py`: one CS-low frame, 16 consecutive data-byte reads of 0x76 (spanning the PSRAM debug engine's 8-byte `dbg_buf`/AUTO_INC refetch boundary), asserting `cur_addr` stays pinned at 0x76 and exactly one `reg_re` fires per byte throughout |
| 6 | Dedicated MISO drives low while CS is high | SPEC-SIM / INTERFACE | `tb_trouper_spi.v` idle and post-read checks | TRPR-SPS-008 | ✅ resolved (job 3863) — selected pinout dedicates MISO to Trouper; requirement now matches the deterministic-low RTL (tri-state/OE is not required) |
| 7 | Randomized SCK/core phase, CS timing, and supported-rate sweep | SPEC-SIM / CDC | `test_randomized_clock_phase`, `test_clock_limit_sweep` | TRPR-SPS-004/005 | 🟨 100 kHz and 1 MHz passed historically; 2 MHz is now required and awaits rerun. 8/10 MHz are over-spec stress and 12 MHz diagnostic. |
| 8 | Abort CS at every command/data bit and reset during frame/CDC/write extension | EDGE-SIM | `test_aborted_frame`, `test_reset_interruption` | TRPR-SPS-001/005 | ✅ done (job 3352) |
| 9 | Source-byte ↔ synchronized-event ↔ accepted-write conservation | EDGE-SIM + FORMAL | all `cocotb/spi_cdc` scoreboard tests; formal checker | CDC mailbox contract | ✅ simulation (job 3352); ✅ formal proof (SGE job 4854) — closed by row #15's `formal/spi_slave_formal.sv` (`a_we/re_no_new_flip_while_pending`, `a_we/re_credit_bounded`, `a_we/re_edge_has_credit`, `a_mailbox_addr/wdata_correct`) |
| 10 | ⛔ VOID 2026-09-01 — ~~Grouper priority with preservation or defined rejection of overlapping SPI access~~ | SPEC-SIM / INTERFACE | `tb_trouper_grp_arb.v` full-strobe write overlap and MISO-load read overlap | TRPR-SPS-007; Open Risk #16 | ✅ resolved (job 3863) — one-entry pending slot preserves a completed SPI write until the Grouper byte cycle releases; an overlapping SPI read is explicitly invalid and retried because pin-level SPI has no WAIT response |
| 11 | Read byte remains stable despite live-status changes (the Grouper-address-change half is ⛔ VOID 2026-09-01) | EDGE-SIM | standalone suite plus top-level contention case | asynchronous peek/MISO contract | ✅ done (job 3879, full regression job 3883) — standalone half unchanged from job 3868 (`test_byte_atomicity_live_status_change`). Top-level half closed by two new `cocotb/spi_cdc/test_spi_cdc.py` tests exercising the real `trouper_top.v` arbiter wiring (`rb_raddr = grp_active ? GRP_ADDR : spi_reg_rd_addr`, `grp_active = GRP_WE \| GRP_RE` — a single shared combinational peek port): `test_grp_re_addr_change_during_miso_shift` and `test_grp_we_addr_change_during_miso_shift` inject a Grouper read or write pulse to a *different* address (0x30, vs. the in-flight SPI read's 0x0B) at every bit position from the load instant (bit 8) through the last shifted bit (bit 16) of an in-flight SPI read data byte; both prove the byte already latched into `spi_slave`'s `miso_shreg` is never corrupted (it only samples `reg_rdata` once, at load), and that the very next independent SPI read of the SPI-requested address recovers correctly. The write variant additionally proves the Grouper write itself lands and is visible on the next independent SPI read of the Grouper-touched address — the address change is not silently dropped by the arbiter. `cocotb/hdl/tb_trouper_cocotb.v` was extended (additively; GRP_* default to the same tied-0 state every other suite already relied on) to give cocotb a drivable handle onto the previously-tied-off `GRP_*` bus. The load-instant collision itself (bit 8 raced *before* settling) is the different, already-resolved row #10 case and is not what these tests probe — `spi_frame`'s new `mid_bit_hook` fires only after that bit's negedge has fully settled, matching the standalone suite's methodology. Full block regression (`spi_cdc` 11/11, `psram_ops` 3/3, `spi_slave` 6/6, `tb_trouper_spi.v` PASS, `tb_trouper_grp_arb.v` PASS) reran clean alongside it (job 3883) |
| 12 | SCK while deselected, runt frames, and repeated command-only frames | EDGE-SIM | standalone suite | frame-reset robustness | ✅ done (job 3868) — `test_deselected_clock_no_effect` (64 SCK toggles at CS high produce no `reg_we`/`reg_re`, slave still works afterward) and `test_command_only_frame_recovery` (write-only and read-only command-only frames, plus 20 repeated command-only frames, produce no event and leave the slave clean for the next transaction) added to `cocotb/spi_slave/test_spi_slave.py`; partial-frame sweep from row #8 (`test_aborted_frame`) already covered the rest |
| 13 | All source events sufficiently separated at 2 MHz | FORMAL / ANALYSIS | formal assumptions plus CDC report | toggle-event distinguishability | ✅ done (SGE job 4854) — the proof assumes only ≥25 `clk_32m` cycles between events, a conservative over-spec bound versus the ≥128 cycles implied by 2 MHz. A signoff-grade CDC/RDC structural report remains row #16. |
| 14 | Standalone randomized protocol reference-model regression | EDGE-SIM | new `cocotb/spi_slave` | coverage gap | ✅ done (job 3868) — new `cocotb/spi_slave` instantiates `spi_slave.v` directly against an independent dict-backed register stub (not `reg_bank.v`); `spi_slave_model.py` is a from-spec Python oracle (command decode, 7-bit address progression incl. modulo-128 wrap and the 0x76 no-increment exception, and the read-vs-write event-timing asymmetry) cross-checked bit/byte-wise against the DUT over a deterministic wrap/no-inc case, 150 randomized legal frames, and 80 randomized constrained aborts; full existing regression (`spi_cdc` 9/9 job 3869, `psram_ops` 3/3 job 3869, `tb_trouper_spi.v`/`tb_trouper_grp_arb.v` job 3870) reran clean alongside it |
| 15 | Full SPI CDC property set, non-vacuous | FORMAL | new `formal/spi_slave_formal.sv` + `.sby` | TRPR-SPS-003/005 | ✅ done (SGE jobs 4854 `bmc` PASS, 4855 `cover` PASS) — new two-clock checker (`multiclock on`, SPI_SCK and clk_32m as independent free clocks) instantiated directly in `spi_slave.v` under `ifdef FORMAL, mirroring the psram_buf_ctrl/packet_ctrl_fsm convention. Proves: (A) legal 7-bit address progression (command capture / +1 mod-128 wrap / 0x76 no-increment hold); (B) CS frame reset clears only transaction-local frame state (`spi_shreg`/`spi_bit_cnt`/`have_cmd`/`fp_rw`/`cur_addr`) and never the persistent toggle/mailbox event storage across any HOST_CS-only deassertion (`a_mailbox_persists_we/re`); (C) partial-frame suppression — a toggle can only flip for a genuinely completed byte in the correct role (`a_we/re_toggle_cause`), never a partial byte or wrong direction; (D) row #13's legal-10MHz-byte-spacing assumption plus event conservation under it — no duplication (`a_we/re_no_new_flip_while_pending`), no loss (bounded delivery within 6 clk_32m cycles, `a_we/re_credit_bounded`), no spurious pulses (`a_we/re_edge_has_credit`), and end-to-end mailbox-address/data stability from source latch through the DUT's own `reg_we`/`reg_re`/`reg_wr_addr`/`reg_wdata`/`reg_re_addr` outputs (`a_mailbox_addr/wdata_correct`, `a_re_mailbox_addr_correct`). Non-vacuity: the `u_spi_slave_formal` instance survives through `design_smt2.smt2` (confirmed by grep — not optimized away), and all 6 `cover` points are reachable within depth 100 (job 4855): a completed write delivered (step 58), a completed read delivered (step 58), 0x7E→0x7F→0x00 address wrap (step 34), 0x76 no-increment hold (step 34), mailbox/toggle survives a post-write CS deassert (step 34), and concurrent outstanding write+read credits (step 71) — ruling out a vacuous all-assumptions-unreachable pass. Proved with `mode bmc` (bounded, `initial assume(!rst_n)`-anchored, depth 45), not `mode prove` (BMC+k-induction): an earlier `mode prove` attempt (job 4852) hit a genuine k-induction limitation for this checker's cross-clock "delayed compare" trackers (e.g. `we_tog_sck_q` vs `spi_we_toggle`) — induction's unconstrained hypothesis window can start from an arbitrary, not-reachable-from-reset state where such a tracker already disagrees with its source register with no real transition history (confirmed via the k=1 counterexample trace, SPI_SCK frozen the whole window with `we_tog_sck_q` picked inconsistently at the free starting state) — a well-known limitation for this class of multiclock CDC property, not a real RTL bug; reset-anchored BMC does not have this false-counterexample class. Two real formal-model bugs were found and fixed en route (not RTL bugs): the checker's own frame-domain address/MOSI trackers needed one extra cycle of delay to correctly reconstruct nonblocking-assignment simultaneity, and `have_cmd`/`fp_rw`/`spi_bit_cnt` needed a separate tracker sharing the persistent-event block's `negedge rst_n`-only reset domain (not `spi_frame_arst`), since the real DUT correctly still fires a read-side-effect toggle on an edge where HOST_CS rises coincident with that same completing SCK edge — the checker's first attempt incorrectly zeroed its cause-tracking copy on exactly that legal case. Full block regression (`spi_cdc` 12/12, `psram_ops` 3/3, `spi_slave` 6/6, `tb_trouper_spi.v` PASS, `tb_trouper_grp_arb.v` PASS) reran clean afterward (job 4858), confirming the added `ifdef FORMAL` instantiation in `spi_slave.v`/`rtl-test/rtl/spi_slave.v` changes no synthesizable behavior. |
| 16 | SPI CDC/RDC structural review | CDC/STA | signoff CDC/RDC tool | TRPR-SPS-005; Open Risk #38 | ⬜ planned — document intentional resets, two-FF toggle synchronizers, and bundled-data crossings |
| 17 | Explicit 2 MHz SCK constraints and all-corner timing | CDC/STA | production P&R/STA | TRPR-SPS-004/009; Open Risk #38 | 🟨 baseline added — P&R/signoff SDC now declares SCK and clock groups; replace zero board delays with RPi/PCB values, then report all-corner setup/hold and unconstrained endpoints. |
| 18 | Post-synthesis/post-route minimum-CS and first-read-bit simulation | GATE-SIM | `rtl-test/tb/tb_trouper_spi_gl.v` + post-route SDF | TRPR-SPS-004/005/009; Open Risk #54 | 🟨 first pass done (SGE job 5647, 2026-09-05) — black-box (port-only) Icarus harness, `$sdf_annotate` of the job-5630 tapeout-candidate routed netlist (`final/nl/trouper_top.nl.v` md5 `831b33bb92608fcaeba92d6f2db253f4`) with `final/sdf/nom_tt_025C_3v30` (md5 `972cd78511d282bf33e73582f3dc6309`), iverilog 14.0 `-g2005 -gspecify -ginterconnect`, corner nom_tt_025C_3v30. **PASS**, `$finish` at 162.98 µs, EXIT 0, 0 unmatched SDF arcs. Directed cases: reset release; MISO deselected-low; first read-data bit (CHIP_ID `0xA7` / CHIP_REV `0x01` returned in byte 1); MISO-low after a read frame; minimum-CS-hold single write + readback (`SF_CFG` `0x07`→`0x0A`); minimum CS-high gap between two frames (`TACC_WINDOW` readback `0x0C`); 8-byte burst write + auto-increment burst readback (`0xC0..0xC7`); read-byte snapshot stability (`CHIP_ID` stable through the full shift-out). One benign annotation gap: a single tri-state `Z`→`SPI_MISO_OE` intermodpath iverilog cannot model — `SPI_MISO_OE` is a static tie on a dedicated-output pad, no functional effect. **Not closed:** (a) iverilog does not enforce `$setup`/`$hold` — pure hold-margin is covered by standalone min_ff STA (job 5634: worst hold slack +0.12 ns, hold TNS 0.00 on the same routed DB + min-RC SPEF + `ff_n40C_3v60` lib); (b) re-run against the actual tapeout netlist/SDF once #58 (KLayout DRC) and any remod/SS-waiver re-run settle it. Scripts: `rtl-test/gl_spi_sdf_item54.sh` (nom_tt), `rtl-test/gl_spi_sdf_item54_minff.sh` (min_ff SDF gen + STA); staged inputs `rtl-test/gl_item54_inputs/`; run dir `/srv/eda/runs/timothyn-dev/lora-mimo/5647/`. |
| 19 | Raspberry Pi 2 MHz bench test with measured MISO margin | SYSTEM | silicon/board bring-up | TRPR-SPS-001/004/008/009 | ⬜ planned — verify normal CS timing needs no workaround and measure setup/release behavior |

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
   change). ~~#11's top-level Grouper-address-change contention case.~~ Done
   (job 3879, full regression job 3883): two new `cocotb/spi_cdc` tests drive
   a concurrent Grouper read/write pulse to a different address during an
   in-flight SPI read's MISO shift-out via the real `trouper_top.v` arbiter
   wiring, closing #11 in full. #13 is a formal/analysis row, untouched by
   this step, and stays open pending step 3.
3. ~~Add the formal checker in #15 and verify non-vacuity, and prove #13's
   legal byte-spacing bound alongside it.~~ Done (SGE jobs 4854 `bmc` PASS,
   4855 `cover` PASS, full regression job 4858): `formal/spi_slave_formal.sv`/
   `.sby` proves event conservation, mailbox stability, partial-frame
   suppression, CS frame reset, legal address progression, and #13's
   legal-byte-spacing bound; all 6 cover points reachable, closing both #13
   and #15 in full.
4. Merge code and functional coverage, then randomize until §1a closes.
5. Complete CDC/STA/gate/bench rows #16–#19. Row #18 has a first pass
   (SGE job 5647, 2026-09-05: gate-level harness PASS on the job-5630
   routed netlist at nom_tt); it needs one re-run against the final
   tapeout netlist/SDF once #58 and any remod/SS-waiver re-run settle
   it, and a fast-corner STA hook (min_ff, currently standalone only —
   Open Risk #41).

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
```

Formal (rows #13/#15), from `formal/`:

```bash
sby -f spi_slave.sby bmc     # event conservation, mailbox stability, partial-frame
                             # suppression, CS frame reset, address progression,
                             # legal byte-spacing bound (mode bmc, not prove -- see
                             # row #15's status for why)
sby -f spi_slave.sby cover   # non-vacuity: all 6 cover points must be reachable
```

Run this regression before merging changes to `spi_slave.v`, SPI protocol
requirements, `trouper_top.v`'s arbiter/read-side-effect wiring, or SPI timing
constraints.

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
