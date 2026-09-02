# Register Bank — Verification Plan

> **UPDATE 2026-09-01 — Grouper is not taping out.** The `GRP_*` byte bus, the
> AHB-Lite `H*` endpoint and `IRQ_GROUPER` were removed from
> `src/top/trouper_top.v`, and `rtl-test/tb/tb_trouper_grp_arb.v` was deleted.
> Every row below concerning Grouper access, priority or SPI-vs-Grouper
> arbitration is **VOID** — host SPI is the sole register master and there is
> nothing left to arbitrate. Rows are kept for traceability, not as open work.


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
covers RW field storage, reserved-bit masking, packed output mapping (row #4),
every RO/status input's decode and reserved-bit zeroing (row #5), multi-byte
big-endian ordering and truncation (row #6), the TACC_WINDOW_SYMS clamp
(row #7), the packet_active write-lock gate matrix (row #8), the W-shadow
reject/W1C-clear precedence (row #10), and cycle-exact assert/self-clear
timing for all four TRPR-REG-006 W1P fields (row #11). There is still no
formal checker; read/CE timing, IRQ set/clear precedence, and the Grouper
bus's exact request/acknowledge timing are inferred through top-level tests
rather than checked directly (rows #12–#18).

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
  hardware control-output mapping (row #4); `cocotb/tests/test_reg_bank_ro_status.py`
  drives every RO/status input and every multi-byte field's byte lanes
  (rows #5/#6); `cocotb/tests/test_reg_bank_clamp_and_gates.py` exhaustively
  sweeps the TACC_WINDOW_SYMS clamp and the packet_active write-lock gate
  matrix (rows #7/#8); `cocotb/tests/test_reg_bank_rx_hold.py` covers the
  RX_HOLD/CFG_WR_REJECTED MCP-settle interlock (Open Risks #43);
  `cocotb/tests/test_reg_bank_w1p_precedence.py` covers the W-shadow
  reject/W1C-clear sequential precedence and cycle-exact assert/self-clear
  timing for all four TRPR-REG-006 W1P fields (rows #10/#11). It does not
  yet check IRQ set/clear precedence or the registered read handshake --
  those remain open per rows #12–#18.
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
2b. ✅ Resolved: exhaustive RO/status decode, byte-lane/truncation, the
   TACC_WINDOW_SYMS clamp, and the packet_active gate matrix added (rows
   #5–#8, job 4672); also corrected a stale-NFS-sync-masked test bug in
   rows #2/#3's 0x1A modeling in the same pass (see row #3).
2c. ✅ Resolved: W-shadow reject/W1C-clear precedence and cycle-exact W1P
   assert/self-clear timing for all four TRPR-REG-006 fields added (rows
   #10–#11, job 4843/4845), via
   `cocotb/tests/test_reg_bank_w1p_precedence.py`.
3. Close remaining side-effect precedence and CE/read-timing gaps (rows
   #12–#18).
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
| 2 | Exhaustive address/access-permission/mask sweep | SPEC-SIM | standalone `cocotb/reg_bank` with checked-in map oracle | TRPR-REG-001/004/005 | ✅ done (job 4659, `test_exhaustive_address_permission_mask_sweep` in `cocotb/tests/test_reg_bank_rw_map.py`; **corrected 2026-08-22, job 4670/4672** — see the correction note under row #3) — exhaustively maps all 128 addresses with their access modes and reserved-bit masks; verifies writes respect masks/permissions and that a write to one address does not perturb others. Three of the four original "test-model" mismatches this row recorded (WGT_CTRL/PSRAM_DBG_CTRL hardcoded-`1'b0` read arms, TACC_WINDOW_SYMS clamp) still stand and are correct. The fourth — "0x1A has no RX_HOLD field in this RTL revision" — was itself wrong (see row #3); 0x1A is modeled `('RW', 0x01)` now. Full block regression (`reg_reset_sweep`, `w_shadow_lock`, `sc_force_lock`, `noise_trig`, `psram_ops`, `w_missed`, `bypass_e2e`, `spi_cdc`, `reg_bank` [30/30 tests], `tb_trouper_spi.v`, `tb_trouper_grp_arb.v`) is green after the correction (job 4674, 4678). |
| 3 | Fixed IDs and all reserved addresses read zero/write ignored | SPEC-SIM | standalone `cocotb/reg_bank` sweep | TRPR-REG-004 | ✅ done (`test_reserved_addresses_zero_and_ignored` + `test_fixed_chip_ids` in `cocotb/tests/test_reg_bank_rw_map.py`; **corrected 2026-08-22, job 4670/4672**) — exhaustively verifies all 21 genuinely-reserved slots (0x04–07, 0x10–18, 0x1B, 0x79–7E, 0x7F) read 0x00 and ignore writes under six patterns each, plus CHIP_ID/CHIP_REV fixed-value checks. **Correction:** the row's prior evidence (job 4659) rested on a false premise — it modeled 0x1A as reserved with "no RX_HOLD field in this RTL revision," but `src/control/reg_bank.v` has carried RX_HOLD/CFG_WR_REJECTED at 0x1A since commit f1aa262 (Open Risks #43, `planning/mcp-config-settle-gate-design.md`), which predates job 4659. Reproduced the failure against a correctly-synced DUT (job 4670: `test_reserved_addresses_zero_and_ignored` FAILs, since `rx_hold` reads back 1 out of reset, not 0) before fixing it — job 4659's earlier green run was against a stale NFS sync, not this RTL. Fixed by removing 0x1A from the reserved list (21 entries, not 22) and remodeling it `('RW', 0x01)` in row #2's `addr_map`; 0x1A's real RW/W1C behavior is unaffected and already exhaustively covered by `cocotb/tests/test_reg_bank_rx_hold.py` (job 4353). Re-ran green: job 4672 (standalone suite, 30/30) and job 4674/4678 (full block regression + legacy TBs). RTL unchanged — this was a test/closure-evidence bug, not an RTL bug. |
| 4 | All RW field storage, reserved-bit masking, and packed output mapping | SPEC-SIM | standalone `cocotb/reg_bank` | TRPR-REG-001 | ✅ done — new standalone direct-DUT harness (`cocotb/reg_bank`, table-driven oracle in `cocotb/tests/reg_bank_map_oracle.py`, tests in `cocotb/tests/test_reg_bank_rw_map.py`) sweeps reset/all-ones/two non-symmetric patterns plus a full walking-one/walking-zero set across every plain RW field (MIMO_CTRL, SF_CFG, BW_CFG, PKT_TIMEOUT_SYMS, SC_THR_HI/LO, SC_HITS_REQ, COMB_CFG, the 16-byte W-shadow bank, PSRAM_DBG_ADDR_{LO,MID,HI}, REPLAY_DELAY_{LO,HI}) plus dedicated checks for WGT_CTRL, PSRAM_CTRL (incl. `PSRAM_CTRL[2]` reserved/inert), PSRAM_DBG_CTRL, the TACC_WINDOW_SYMS clamp, SC_FORCE_LOCK/TACC_NOISE_TRIG W1P pulses, and a packet_active-gate smoke check; storage, reserved-bit masking, and the corresponding hardware control-output port are asserted for every field. 7/7 new tests pass and the full block regression (`reg_reset_sweep`, `w_shadow_lock`, `sc_force_lock`, `noise_trig`, `psram_ops`, `w_missed`, `bypass_e2e`, `spi_cdc`, `reg_bank`, `tb_trouper_spi.v`, `tb_trouper_grp_arb.v`) is green (job 3889). RTL unchanged — no bug found. Remaining exhaustive RO-status decode, byte-lane, and gate-matrix depth are explicitly deferred to rows #5/#6/#8. |
| 5 | Every RO/status input decode and reserved-bit zeroing | SPEC-SIM | standalone `cocotb/reg_bank` | TRPR-REG-001 | ✅ done (job 4672, `cocotb/tests/test_reg_bank_ro_status.py`, 8 new tests) — directly drives every packet (PACKET_STATUS 0x1C, ACTIVE_STATUS 0x1D), training (TRAINING_STATUS 0x20, N_ACC 0x21–23), SC (SC_STAT 0x24–25, SC_DBG_FLAGS 0x26, SC_FIRST_HIT 0x28–2B, SC_LOCK_SNAP 0x2C–2F), Z-pair/Z-diagonal (all 6 Z_kl pairs I/Q at 0x40–63, all 4 Z_kk diagonals at 0x64–6F), and PSRAM (PSRAM_STATUS 0x71, PSRAM_DBG_DATA 0x76 incl. the `psram_dbg_busy` gate) hardware-status input with a non-symmetric byte stripe (0x1D/0x62/0xB4/0xC7) plus 0x00/0xFF/other non-symmetric 32-bit values, and asserts every reserved-bit position (PACKET_STATUS has none; ACTIVE_STATUS[3:2], N_ACC_HI[7:2], SC_DBG_FLAGS[7:4]) reads zero regardless of the driven pattern. IRQ_STATUS (0x02) decode/precedence is explicitly left to rows #13–#15 per this row's original scope note; WGT_CTRL's RO mirror and PSRAM_DBG_CTRL's DBG_BUSY mirror were already closed by row #4 and are not repeated. RTL unchanged — no bug found (one test-authoring arithmetic bug in an early draft, caught by job 4671 and fixed before job 4672). |
| 6 | Multi-byte big-endian ordering and truncation | SPEC-SIM | standalone suite; retain weight/training/SC integration tests | TRPR-REG-003 | ✅ done (job 4672, `cocotb/tests/test_reg_bank_ro_status.py`) — the same row #5 tests double as the byte-lane oracle: N_ACC (18-bit, `test_training_status_and_n_acc_decode`), SC_STAT (16-bit) and the two 32-bit SC debug snapshots SC_FIRST_HIT/SC_LOCK_SNAP (full-width, no truncation) confirm big-endian byte order (byte 0 = MSB) across a spread of values including `0x00000000`/`0xFFFFFFFF`/asymmetric patterns; the six Z_kl pairs and four Z_kk diagonals (`test_zpair_decode`/`test_zdiag_decode`) confirm the `[31:8]` top-24-of-32 truncation specifically with low-byte values (`0x...FF`/`0x...00`/`0x...FE`) chosen so a truncation-vs-alias bug could not hide behind a coincidentally-zero low byte. The 23-bit PSRAM_DBG_ADDR, 16-bit SC_THR/REPLAY_DELAY (RW), and 128-bit W-shadow bank byte-lane independence were already exercised per-byte by row #4's `GENERIC_RW_FIELDS` sweep and the packet_active-gate table in row #8's `test_ungated_fields_unaffected_by_packet_active` (cross-byte reconstruction of PSRAM_DBG_ADDR from 3 independently-written bytes). RTL unchanged — no bug found. |
| 7 | `TACC_WINDOW_SYMS` clamp for all inputs | SPEC-SIM | standalone suite; `tb_trouper_spi.v` | Register Map 0x27 | ✅ done (job 4672, `cocotb/tests/test_reg_bank_clamp_and_gates.py::test_tacc_window_syms_full_clamp_sweep`) — sweeps every possible write byte 0x00–0xFF (not a sample): confirms the floor-clamp of `wdata[3:0]` to a minimum of 8 for all 256 inputs, and that reserved bits[7:4] never leak into storage, the `tacc_window_syms` output port, or readback. RTL unchanged — no bug found. |
| 8 | Packet-active write locks | SPEC-SIM | `cocotb/sc_force_lock`, `bypass_e2e`, `replay_delay`; direct sweep | Register Map 0x09/0x0A/0x19/0x70/0x77/0x78 | ✅ done (job 4672, `cocotb/tests/test_reg_bank_clamp_and_gates.py`, 5 new tests) — table-driven direct check of every packet_active-gated register (SF_CFG 0x09, PKT_TIMEOUT_SYMS 0x0B, SC_HITS_REQ 0x0E, TACC_WINDOW_SYMS 0x27, REPLAY_DELAY_LO/HI 0x77/0x78 via a shared table; BW_CFG 0x0A and PSRAM_CTRL.PSRAM_EN 0x70[0] individually, since they pack a gated bit alongside ungated bits in the same register; SC_FORCE_LOCK 0x19 individually as a W1P) and confirms each is blocked while `packet_active=1` and lands once `packet_active=0`. A companion test confirms every ungated register (MIMO_CTRL, SC_THR, COMB_CFG, RX_HOLD, WGT_CTRL.W_COMMIT, TACC_NOISE_TRIG, the W-shadow bank, and the PSRAM_DBG window) is NOT blocked by `packet_active=1`, so the gate has not over-reached. Since commit f1aa262 (Open Risks #43) added a second interlock (`cfg_wr_ok = rx_hold && !packet_active`) covering SF_CFG/BW_CFG/PKT_TIMEOUT_SYMS/SC_HITS_REQ/TACC_WINDOW_SYMS, this suite isolates the packet_active half by holding `rx_hold` at its permissive reset value throughout; the rx_hold half is exhaustively covered separately by `cocotb/tests/test_reg_bank_rx_hold.py` (job 4353). RTL unchanged — no bug found. |
| 9 | W-shadow accept/reject lock, sticky rejection, W1C clear, and re-arm | SPEC-SIM | `cocotb/w_shadow_lock` | Register Map 0x1E/0x30–0x3F | ✅ done |
| 10 | W-shadow reject and W1C clear on the same CE edge | EDGE-SIM | standalone suite | RTL precedence | ✅ done (job 4843/4845, `cocotb/tests/test_reg_bank_w1p_precedence.py`) — the set (`we && addr[7:4]==4'h3 && w_valid_rb`) and clear (`we && addr==8'h1E && wdata[5]`) conditions are keyed off mutually exclusive addresses, so they cannot literally collide on the register bus's single address/data port in one cycle; this suite instead pins the sequential precedence the "if/else if" ordering promises: a dropped shadow write sets `W_WR_REJECTED`, a 0x1E W1C clears it, and a further dropped write with `W_VALID` still high re-asserts it (the clear does not starve the set branch) — `test_w_wr_rejected_set_then_clear_then_new_rejection_wins`. Confirms `wdata[5]=1`/`wdata[0]=0` clears the flag without ever pulsing `W_COMMIT`, and that a single write with both bits set (`wdata=0x21`) clears the flag AND pulses `W_COMMIT` in the same cycle (`test_w_wr_rejected_clear_and_commit_same_write`), plus that a WGT_CTRL-only write never perturbs the W shadow bank or spuriously sets `W_WR_REJECTED` (`test_w1c_bit_alone_does_not_reject_or_land_shadow_write`). RTL unchanged — no bug found. |
| 11 | All four W1P fields assert for one CE period and self-clear | SPEC-SIM | standalone suite; `spi_cdc`, `noise_trig`, `psram_ops` | TRPR-REG-006 | ✅ done (job 4843/4845, `cocotb/tests/test_reg_bank_w1p_precedence.py`) — cycle-exact port checks for all four bits named by TRPR-REG-006 (`TACC_NOISE_TRIG` 0x1F[0], `WGT_CTRL.W_COMMIT` 0x1E[0], `PSRAM_CTRL.PSRAM_CLR_ERR` 0x70[1], `PSRAM_DBG_CTRL.RD_TRIG` 0x75[0]): each output is confirmed idle-low before its triggering write, asserts high exactly on the triggering write's clk edge, self-clears on the very next clk edge, and stays low for several further idle cycles (no re-assertion/no multi-cycle stretch) — one test per field plus a cross-trigger isolation test confirming no field's write spuriously pulses any of the other three. (`SC_FORCE_LOCK` 0x19[0] is also W1P in the RTL but is not one of the four bits TRPR-REG-006 names; its pulse shape remains covered functionally by `cocotb/sc_force_lock` and row #8.) Full block regression (`reg_reset_sweep`, `w_shadow_lock`, `sc_force_lock`, `noise_trig`, `psram_ops`, `w_missed`, `bypass_e2e`, `spi_cdc`, standalone `reg_bank` [38/38], `tb_trouper_spi.v`, `tb_trouper_grp_arb.v`) is green (job 4845). RTL unchanged — no bug found. |
| 12 | A two-core-cycle `we` causes exactly one CE write/W1P event | EDGE-SIM + FORMAL | `cocotb/spi_cdc`; formal checker | CE integration contract | ✅ simulation (job 3352); ⬜ formal |
| 13 | IRQ sticky set/hold/selective-W1C and aggregated output | SPEC-SIM | block-specific IRQ tests; standalone suite | TRPR-REG-007, TRPR-IRQ-001..006 | 🟨 partial — add independent bits 0..4, level-held source/clear behavior, reserved bits, and no-spontaneous-clear checks |
| 14 | Simultaneous `irq_set` and `IRQ_CLEAR` precedence | EDGE-SIM | standalone suite | RTL expression `(status \| set) & ~clear` | ⬜ new — define whether clear wins for the same bit on one CE edge, then pin it |
| 15 | `irq_out` and both top-level IRQ outputs | SPEC-SIM / INTERFACE | standalone suite plus top-level IRQ test | TRPR-IRQ-003/004 | ⬜ direct check — require `irq_out==OR(IRQ_STATUS)` and top-level `IRQ_OUT==IRQ_GROUPER` until all bits clear |
| 16 | Combinational `peek_rdata` and registered one-wait-state read protocol | SPEC-SIM + FORMAL | standalone suite | register-bus interface | ⬜ new — check address changes, stable `rdata`, exact `ready` behavior, and held/back-to-back reads |
| 17 | `clk_en` phase and reset interruption | EDGE-SIM | standalone suite | 16 MHz CE contract | ⬜ new — sweep writes, reads, and events around enabled/disabled edges |
| 18 | ⛔ VOID 2026-09-01 — ~~Grouper byte-bus reachability and ready timing~~ | SPEC-SIM / INTERFACE | `tb_trouper_grp_arb.v`; extend with cycle assertions | TRPR-REG-002 | 🟨 partial — functional reachability is done; add exact request/acknowledge and held-request timing |
| 19 | Full property set, non-vacuous | FORMAL | new `formal/reg_bank_formal.sv` + `.sby` | TRPR-REG-001/004/006/007 | ⬜ new — prove reset, legal writes/masks, W1P duration, IRQ causality, write locks, and reserved-address immutability |

### 2a. Directed closure order

1. ✅ Resolved: row #4 (standalone `cocotb/reg_bank` harness + checked-in
   table-driven map oracle in `cocotb/tests/reg_bank_map_oracle.py`; job 3889).
2. ✅ Resolved: rows #5–#8 (RO/status decode, byte-lane/truncation, the
   TACC_WINDOW_SYMS clamp, and the packet_active gate matrix) closed via
   `cocotb/tests/test_reg_bank_ro_status.py` and
   `cocotb/tests/test_reg_bank_clamp_and_gates.py` (job 4672); rows #2/#3's
   0x1A modeling corrected in the same pass (job 4670/4672).
3. ✅ Resolved: rows #10–#11 (W-shadow reject/W1C-clear precedence, and
   cycle-exact assert/self-clear timing for all four TRPR-REG-006 W1P
   fields) closed via `cocotb/tests/test_reg_bank_w1p_precedence.py`
   (job 4843/4845).
4. Extend the standalone harness and map oracle for #13–#17.
5. ~~Strengthen Grouper bus timing coverage in #18.~~ Dropped 2026-09-01 — bus removed.
6. Add and prove the formal checker in #19.
7. Merge code and functional coverage, then randomize until §1a is closed or
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
```

The `cocotb/reg_bank` suite above is the standalone direct-DUT harness (rows
#2–#8); note it instantiates `reg_bank.v` alone (no SPI/CDC framing) and
holds `clk_en` asserted every cycle — see the module docstring in
`cocotb/tests/test_reg_bank_rw_map.py` for why that is a safe simplification
for the checks it runs. Its `COCOTB_TEST_MODULES` now covers
`test_reg_bank_rw_map`, `test_reg_bank_rx_hold`, `test_reg_bank_ro_status`,
`test_reg_bank_clamp_and_gates`, and `test_reg_bank_w1p_precedence`
(38 tests total as of job 4843/4845). Add the formal command when
implemented. On the homelab SGE cluster, `/foss/designs`
is read-only under the default project — point `SIM_BUILD` /
`COCOTB_RESULTS_FILE` at a writable path (e.g. `/foss/runs/...`) as job 3889
does, or use `--project lora-mimo-reg_bank` per `cocotb/reg_bank/run_sge.sh`.
Note that `--project lora-mimo-reg_bank` snapshots
`/srv/eda/designs/<user>/lora-mimo-reg_bank/`, a **separate** directory from
the plain `/srv/eda/designs/<user>/lora-mimo/` used without `--project` —
sync to the one matching the `--project` value actually passed to `hqsub`,
or the job runs against a stale/absent tree.
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
