# Register Bank — Verification Plan

**DUT:** `src/control/reg_bank.v` (mirrored to `rtl-test/rtl/reg_bank.v`)

**Scope:** the complete 7-bit register map, reset/read/write/side-effect policy,
the CE-gated byte-bus interface, packed control/status mappings, write locks,
W1P/W1C behavior, and sticky IRQ aggregation.

**Inputs reviewed:** `planning/Register Map.md`, `planning/Trouper Chip
Specification.md` (§4.13 TRPR-REG-001..007 and §4.14 TRPR-IRQ-001..006),
`planning/Traceability.md`, `planning/Open Risks.md` (#16),
`src/top/trouper_top.v`, the current RTL, `cocotb/reg_reset_sweep`, the
register-focused full-top cocotb suites, and
`rtl-test/tb/tb_trouper_spi.v`, `tb_trouper_grp_arb.v`, and
`tb_trouper_two_packet.v`.

This is the block-level closure tracker for `reg_bank`. It does not supersede
the functional verification plans for blocks whose controls and status happen
to be exposed through the register map.

---

## 1. Current methodology, and the path to constrained random

**Today:** reset values and common register policies have substantial directed
integration coverage, and a standalone block-level harness now exhaustively
covers RW field storage, reserved-bit masking, and packed output mapping
(row #4). Hardware-status decode beyond that has not yet been driven
exhaustively, byte-lane/clamp/gate depth remain partial, and there is still
no formal checker; read/CE timing is inferred through top-level tests rather
than checked directly.

- **Full-top cocotb simulation** — `cocotb/reg_reset_sweep` reads all 128
  addresses at power-on and after dirtying safely writable registers. Other
  suites verify packet-active write locks, W-shadow locking, IRQ use, PSRAM
  debug behavior, and block-specific W1P actions through SPI.
- **Legacy directed simulation** — `tb_trouper_spi.v` checks representative
  masks, RO/WO behavior, reserved addresses, clamps, and self-clearing controls.
  `tb_trouper_grp_arb.v` verifies Grouper access and priority at the top-level
  bus mux. `tb_trouper_two_packet.v` exercises sticky IRQ behavior.
- **Standalone block-level harness** — `cocotb/reg_bank` instantiates
  `reg_bank.v` directly (no SPI/CDC framing) and, via the checked-in
  table-driven oracle in `cocotb/tests/reg_bank_map_oracle.py`, exhaustively
  sweeps every plain RW field's storage, reserved-bit masking, and packed
  hardware control-output mapping (row #4). It does not yet drive every
  RO/status input, or check pulse-cycle-exact timing, precedence rules, or
  the registered read handshake — those remain open per rows #5, #11–#17.
- **No formal checker** — no property proof yet for legal writes, W1P width,
  write locks, reserved addresses, or IRQ stickiness.
- **No merged code or functional coverage** — closure is scenario-based rather
  than measured.

The active order is:

1. ✅ Resolved 2026-07-31: `PSRAM_CTRL[2]` is reserved, ignores writes, and
   reads zero; the register map remains authoritative and the legacy SPI test
   pins the behavior.
2. ✅ Resolved: standalone harness and checked-in table-driven register-map
   oracle added (row #4, job 3889); extend it for the remaining rows below.
3. Close exhaustive decode, permission, side-effect, and CE/read-timing gaps.
4. Add formal properties for legal writes, W1P width, write locks, reserved
   addresses, and IRQ stickiness.
5. Instrument line/toggle/branch coverage, measure the directed baseline, and
   add constrained-random stimulus for sparse crosses.

### 1a. Coverage model

At minimum, collect:

- all 128 addresses crossed with `{read, write}` and access class
  `{RO, WO, RW, W1P, W1C, reserved}`;
- each writable field crossed with reset, zero, ones, walking-one,
  walking-zero, and a non-symmetric pattern;
- every hardware-status input bit toggled independently and in meaningful
  combinations at its decoded address;
- all multi-byte fields crossed with first/middle/last byte and positive,
  negative, and non-symmetric values;
- `{write-gated register} × {packet_active 0/1}` for `SF_CFG`, `BW_CFG`,
  `SC_FORCE_LOCK`, `PSRAM_EN`, and both replay-delay bytes;
- `{W-shadow address 0x30..0x3F} × {W_VALID 0/1}` and
  `{rejected-write, W1C-clear, simultaneous reject+clear}`;
- `{IRQ bit 0..4} × {set only, clear only, set+clear same CE edge}` and
  `irq_out` transitions; confirm top-level reserved bits 7:5 remain tied low;
- read and write behavior at both `clk_en` phases, including held and
  back-to-back requests;
- every W1P crossed with single-cycle `we`, two-core-cycle SPI `we`, and held
  `we`.

---

## 2. List of tests

`Type`: **SPEC-SIM** = directed test of a numbered requirement;
**EDGE-SIM** = robustness/precedence test found by RTL review;
**FORMAL** = assertion/property proof; **INTERFACE** = behavior partly owned by
`trouper_top.v`.

| # | Test | Type | Testbench | Spec / gap | Status |
|---|---|---|---|---|---|
| 1 | Full 0x00–0x7F reset-value sweep at power-on and after dirty/reset | SPEC-SIM | `cocotb/reg_reset_sweep` | TRPR-REG-001 | ✅ done (job 3319); intentionally excludes resetless training accumulators 0x40–0x6F |
| 2 | Exhaustive address/access-permission/mask sweep | SPEC-SIM | standalone `cocotb/reg_bank` with checked-in map oracle | TRPR-REG-001/004/005 | ✅ done (job 4659, `test_exhaustive_address_permission_mask_sweep` in `cocotb/tests/test_reg_bank_rw_map.py`) — exhaustively maps all 128 addresses with their access modes and reserved-bit masks; verifies writes respect masks/permissions and that a write to one address does not perturb others. PASS on this checkout's RTL after four rounds of test-authoring fixes exposed by real SGE runs (see below); RTL unchanged — no bug found. Four **test-model** mismatches were caught and corrected, all against `src/control/reg_bank.v` as currently checked into this worktree/branch: (1) 0x1A was modeled as an `RX_HOLD` R/W register per `planning/Register Map.md`'s per-address table, but this RTL revision has no RX_HOLD field at 0x1A at all (no case arm in either the write or read decode — falls to `default`) — the doc's RX_HOLD content appears to belong to a different/later RTL revision than this branch; corrected to model 0x1A as reserved, matching the actual DUT (see row 3). (2) WGT_CTRL (0x1E) bit 0 (`W_COMMIT`, W1P) has its read-decode arm hardcoded to the literal `1'b0` (same convention as the pure-WO `SC_FORCE_LOCK`/`TACC_NOISE_TRIG` registers) — it never reads back the just-written value; corrected to expect 0x00 always. (3) PSRAM_DBG_CTRL (0x75) bit 0 (`RD_TRIG`, W1P) has the same hardcoded-`1'b0` read-decode pattern; corrected to expect only bit 1 (`AUTO_INC`) to track writes. (4) TACC_WINDOW_SYMS (0x27) clamps writes below 8 up to 8; the sweep's generic mask model didn't account for the clamp; corrected to expect the clamped value. All four are exhaustive-sweep modeling gaps only — the corresponding dedicated per-field tests (`test_wgt_ctrl_field`, `test_psram_dbg_ctrl_field`, `test_tacc_window_syms_field`) already modeled these correctly and passed throughout. Full block regression (`reg_reset_sweep`, `w_shadow_lock`, `sc_force_lock`, `noise_trig`, `psram_ops`, `w_missed`, `bypass_e2e`, `spi_cdc`, `reg_bank` [10/10 tests], `tb_trouper_spi.v`, `tb_trouper_grp_arb.v`) re-ran green after these rows closed (jobs 4659, 4662) — no other test regressed. |
| 3 | Fixed IDs and all reserved addresses read zero/write ignored | SPEC-SIM | standalone `cocotb/reg_bank` sweep | TRPR-REG-004 | ✅ done (job 4659, `test_reserved_addresses_zero_and_ignored` + `test_fixed_chip_ids` in `cocotb/tests/test_reg_bank_rw_map.py`) — exhaustively verifies all 22 reserved slots (0x04–07, 0x10–18, 0x1A–1B, 0x79–7E, 0x7F) read 0x00 and ignore writes under six patterns each, plus CHIP_ID/CHIP_REV fixed-value checks. PASS; RTL unchanged — no bug found. One **test-authoring** bug was caught and corrected: the initial reserved-address list omitted 0x1A (21 entries) while asserting a count of 22, because it was written against `planning/Register Map.md`'s per-address table describing an `RX_HOLD` register at 0x1A that does not exist in this RTL revision (see row 2) — corrected to include 0x1A, restoring the list to the genuinely-correct 22. `planning/Register Map.md`'s RX_HOLD/0x1A content should be reconciled against this branch's RTL separately (tracked as a doc-vs-RTL gap, not a verification-plan action). |
| 4 | All RW field storage, reserved-bit masking, and packed output mapping | SPEC-SIM | standalone `cocotb/reg_bank` | TRPR-REG-001 | ✅ done — new standalone direct-DUT harness (`cocotb/reg_bank`, table-driven oracle in `cocotb/tests/reg_bank_map_oracle.py`, tests in `cocotb/tests/test_reg_bank_rw_map.py`) sweeps reset/all-ones/two non-symmetric patterns plus a full walking-one/walking-zero set across every plain RW field (MIMO_CTRL, SF_CFG, BW_CFG, PKT_TIMEOUT_SYMS, SC_THR_HI/LO, SC_HITS_REQ, COMB_CFG, the 16-byte W-shadow bank, PSRAM_DBG_ADDR_{LO,MID,HI}, REPLAY_DELAY_{LO,HI}) plus dedicated checks for WGT_CTRL, PSRAM_CTRL (incl. `PSRAM_CTRL[2]` reserved/inert), PSRAM_DBG_CTRL, the TACC_WINDOW_SYMS clamp, SC_FORCE_LOCK/TACC_NOISE_TRIG W1P pulses, and a packet_active-gate smoke check; storage, reserved-bit masking, and the corresponding hardware control-output port are asserted for every field. 7/7 new tests pass and the full block regression (`reg_reset_sweep`, `w_shadow_lock`, `sc_force_lock`, `noise_trig`, `psram_ops`, `w_missed`, `bypass_e2e`, `spi_cdc`, `reg_bank`, `tb_trouper_spi.v`, `tb_trouper_grp_arb.v`) is green (job 3889). RTL unchanged — no bug found. Remaining exhaustive RO-status decode, byte-lane, and gate-matrix depth are explicitly deferred to rows #5/#6/#8. |
| 5 | Every RO/status input decode and reserved-bit zeroing | SPEC-SIM | standalone `cocotb/reg_bank` | TRPR-REG-001 | ⬜ new — directly drive packet, training, SC, Z-pair/Z-diagonal, and PSRAM inputs with non-symmetric patterns |
| 6 | Multi-byte big-endian ordering and truncation | SPEC-SIM | standalone suite; retain weight/training/SC integration tests | TRPR-REG-003 | 🟨 partial — functional flows cover the main fields; add an exhaustive byte-lane oracle for `[31:8]`, 23-bit, 18-bit, 16-bit, and 128-bit mappings |
| 7 | `TACC_WINDOW_SYMS` clamp for all inputs | SPEC-SIM | standalone suite; `tb_trouper_spi.v` | Register Map 0x27 | 🟨 partial — 0→8 and normal 12 covered; sweep 0..15 and reserved high bits |
| 8 | Packet-active write locks | SPEC-SIM | `cocotb/sc_force_lock`, `bypass_e2e`, `replay_delay`; direct sweep | Register Map 0x09/0x0A/0x19/0x70/0x77/0x78 | 🟨 partial — integration paths exist; add a table-driven direct check of blocked and ungated fields |
| 9 | W-shadow accept/reject lock, sticky rejection, W1C clear, and re-arm | SPEC-SIM | `cocotb/w_shadow_lock` | Register Map 0x1E/0x30–0x3F | ✅ done |
| 10 | W-shadow reject and W1C clear on the same CE edge | EDGE-SIM | standalone suite | RTL precedence | ⬜ new — confirm a new rejection wins and bit0=0 causes no W_COMMIT |
| 11 | All four W1P fields assert for one CE period and self-clear | SPEC-SIM | standalone suite; `spi_cdc`, `noise_trig`, `psram_ops` | TRPR-REG-006 | 🟨 partial — all actions are functionally exercised; add cycle-exact port checks |
| 12 | A two-core-cycle `we` causes exactly one CE write/W1P event | EDGE-SIM + FORMAL | `cocotb/spi_cdc`; formal checker | CE integration contract | ✅ simulation (job 3352); ⬜ formal |
| 13 | IRQ sticky set/hold/selective-W1C and aggregated output | SPEC-SIM | block-specific IRQ tests; standalone suite | TRPR-REG-007, TRPR-IRQ-001..006 | 🟨 partial — add independent bits 0..4, level-held source/clear behavior, reserved bits, and no-spontaneous-clear checks |
| 14 | Simultaneous `irq_set` and `IRQ_CLEAR` precedence | EDGE-SIM | standalone suite | RTL expression `(status \| set) & ~clear` | ⬜ new — define whether clear wins for the same bit on one CE edge, then pin it |
| 15 | `irq_out` and both top-level IRQ outputs | SPEC-SIM / INTERFACE | standalone suite plus top-level IRQ test | TRPR-IRQ-003/004 | ⬜ direct check — require `irq_out==OR(IRQ_STATUS)` and top-level `IRQ_OUT==IRQ_GROUPER` until all bits clear |
| 16 | Combinational `peek_rdata` and registered one-wait-state read protocol | SPEC-SIM + FORMAL | standalone suite | register-bus interface | ⬜ new — check address changes, stable `rdata`, exact `ready` behavior, and held/back-to-back reads |
| 17 | `clk_en` phase and reset interruption | EDGE-SIM | standalone suite | 16 MHz CE contract | ⬜ new — sweep writes, reads, and events around enabled/disabled edges |
| 18 | Grouper byte-bus reachability and ready timing | SPEC-SIM / INTERFACE | `tb_trouper_grp_arb.v`; extend with cycle assertions | TRPR-REG-002 | 🟨 partial — functional reachability is done; add exact request/acknowledge and held-request timing |
| 19 | Full property set, non-vacuous | FORMAL | new `formal/reg_bank_formal.sv` + `.sby` | TRPR-REG-001/004/006/007 | ⬜ new — prove reset, legal writes/masks, W1P duration, IRQ causality, write locks, and reserved-address immutability |

### 2a. Directed closure order

1. ✅ Resolved: row #4 (standalone `cocotb/reg_bank` harness + checked-in
   table-driven map oracle in `cocotb/tests/reg_bank_map_oracle.py`; job 3889).
2. Extend the standalone harness and map oracle built for #4; reuse for
   #2–#3, #5–#8, #10–#11, and #13–#17.
3. Strengthen Grouper bus timing coverage in #18.
4. Add and prove the formal checker in #19.
5. Merge code and functional coverage, then randomize until §1a is closed or
   waived.

---

## 3. Regression commands

Run inside the chipathon26 EDA container:

```bash
for d in reg_reset_sweep w_shadow_lock sc_force_lock noise_trig psram_ops \
         w_missed bypass_e2e spi_cdc reg_bank; do
  (cd cocotb/$d && make) || echo "FAILED: $d"
done

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

The `cocotb/reg_bank` suite above is the new standalone direct-DUT harness
(row #4); note it instantiates `reg_bank.v` alone (no SPI/CDC framing) and
holds `clk_en` asserted every cycle — see the module docstring in
`cocotb/tests/test_reg_bank_rw_map.py` for why that is a safe simplification
for the RW-storage/masking/output-mapping checks it runs. Add the formal
command when implemented. On the homelab SGE cluster, `/foss/designs` is
read-only under the default project — point `SIM_BUILD` /
`COCOTB_RESULTS_FILE` at a writable path (e.g. `/foss/runs/...`) as job 3889
does, or use `--project lora-mimo-reg_bank` per `cocotb/reg_bank/run_sge.sh`.
Run this regression before merging changes to `reg_bank.v`,
`Register Map.md`, or `trouper_top.v`'s CE latch, register arbiter, or IRQ
wiring.

---

## 4. Explicit non-goals and interface boundaries

- Arithmetic correctness of status producers belongs to their source blocks;
  this plan verifies byte mapping, access policy, and control outputs.
- Training results at 0x40–0x6F intentionally have unspecified power-on values.
  Test their decode with driven inputs or after an arm event, not as reset zero.
- Firmware sequencing and legal operating ranges are outside this block except
  for masks, clamps, and write locks implemented in RTL.
- SPI framing and CDC belong to `spi-slave-verification-plan.md`; the SPI CDC
  suite remains here only because it verifies CE-accepted bank writes.
- Arbitration, CE write-bus latching, IRQ source edge conversion/pulse
  stretching, and the second IRQ output live in `trouper_top.v`. They are
  interface checks, not internal `reg_bank` logic.
