# Config-settle discipline for the quasi-static MCP groups

**Status:** §4a-4c IMPLEMENTED and verified (2026-08-14, SGE job 4353,
reg_bank suite 13/13). §4d and tests 2-6 outstanding.
**Closes:** Open Risks #43 settling-proof obligations for 6 of the 9 open MCP
groups, at ~2 flops, with no new logic in any 32 MHz timing-critical block.
**Evidence this is needed:** `cocotb/mcp_pcfsm_settle/` (SGE job 4351, 2 of 4
tests fail by design); honest-SDC STA (job 4349) showing these cones are the
−22.84 ns violators when the exceptions are withdrawn.

**Supersedes** the per-block `cfg_settled` history design (first revision of
this file). That version added enable terms to `acc_*`/`eval_*`/`sym_cnt` —
wide registers inside the block that already owns the worst SS cone — plus a
deferred window load in `training_acc`. With area and timing as the governing
priorities, that cost is not justified when a contract change buys the same
guarantee. The earlier reasoning about *why* the exceptions are unsound is
unchanged and is restated in §1.

---

## 1. The defect, stated once

Every scoped MCP=3 exception asserts that a quasi-static source cannot change
within 3 cycles of the edge that captures it. The SDC justifies this by *write
rate* ("host-writable, kHz-rate"). That is the wrong invariant: what matters is
the **distance between the last change and the capture edge**, and nothing in
the RTL enforces any distance.

With `cfg[t]` = the source value after edge `t`, a capture at edge `C` samples
`cfg[C-1]`. MCP=3 setup is sound iff

    cfg[C-1] == cfg[C-2] == cfg[C-3]

## 2. Why a firmware contract can carry this

"Firmware will not write near a capture edge" is **not** a usable discipline:
the capture is driven by an RF event (`sc_lock`) whose timing firmware cannot
know or predict.

"Firmware will not write while the receiver is able to lock" **is** usable,
because hardware can make the two mutually exclusive:

> **Config writes are accepted only while the detector is held disabled; the
> detector cannot lock while it is held.**

No capture edge can occur in any window where a config source can change, so
the settle requirement is satisfied vacuously rather than argued.

The load-bearing part is that hardware **rejects** the write rather than merely
documenting the rule. A documented-but-unenforced convention is not evidence
and does not satisfy item #43's demand for a demonstration that "the receiver
cannot consume the value before the claimed settling window". Rejection also
matches existing precedent: `SF_CFG`, `BW_CFG` and `SC_FORCE_LOCK` already
reject writes while `PACKET_ACTIVE`.

## 3. The handle already exists

`sc_clr` is **level-sensitive**, not a pulse. While it is high,
`sc_detector.v:492` forces `sc_lock <= 0`, `hit_count <= 0`, and clears
`acc_ci0/acc_cq0/acc_E0cur/acc_E0del/sym_cnt/tdm_*/eval_*` every cycle. Holding
`sc_clr` therefore *is* "receiver disabled, cannot lock" — including a
suppressed `SC_FORCE_LOCK`, since the forced `sc_lock` is re-cleared each cycle.

Today `sc_clr` is driven only by `packet_done_pulse`
(`trouper_top.v:286`). The design adds one firmware-writable level that ORs
into it.

## 4. The change

### 4a. New register `0x1A RX_HOLD` (slot currently reserved)

| Bit | Name | Access | Meaning |
|---|---|---|---|
| [0] | `RX_HOLD` | R/W | 1 = detector held disabled; config writes accepted (subject to `!packet_active`, see 4c) |
| [1] | `CFG_WR_REJECTED` | RO sticky, W1C | a gated config write was dropped |
| [7:2] | — | — | reserved |

`CFG_WR_REJECTED` follows the `WGT_CTRL[5] W_WR_REJECTED` precedent and exists
because the failure mode of this design is a **silently dropped write** — the
same class of bug as Open Risks #16 and the `W_MISSED_PACKET` readback bug.
Firmware must be able to detect that it got the sequence wrong.

**Reset value — decision required.** Recommend `RX_HOLD` take the value **1 out
of reset** — i.e. `rx_hold <= 1'b1;` in the `if (!rst_n)` branch, so the
receiver comes up disabled and firmware configures then releases. (Reset itself
is active-low, `RESETB` → `rst_n`, as everywhere else; this is the bit's reset
*value*, not a polarity. A non-zero reset value is already normal here —
`sf_cfg <= 4'h7`, `pkt_timeout_syms <= 8'h50`, `sc_hits_req <= 2'h2`.)

- Failure is loud rather than silent. With a reset value of 0, every existing
  flow that writes config after reset has its writes rejected and misbehaves
  subtly; with a reset value of 1, the receiver simply never locks until
  firmware releases it, which is immediately obvious.
- It matches the configure-then-enable contract the rest of this design assumes.
- Cost: a real power-on behaviour change. Every cocotb suite that resets and
  expects a lock needs an explicit `RX_HOLD` release added. That is a broad but
  mechanical test update, and it is the main disruption in this design.

### 4b. `trouper_top.v` — one OR

```verilog
.sc_clr (packet_done_pulse | rb_rx_hold),   // was: packet_done_pulse
```

### 4c. `reg_bank.v` — gate the five MCP'd config registers

Writes accepted only while the gate below holds; otherwise dropped and
`cfg_wr_rejected` set:

| Addr | Register | Feeds MCP group |
|---|---|---|
| `0x09` | `SF_CFG` | pcfsm_quasi_static, pcfsm_mval, training_window, timing_ref_config, sc_quasi_static |
| `0x0A` | `BW_CFG` (`bw_sel`) | same set (`rb_sample_shift` is derived from it) |
| `0x0B` | `PKT_TIMEOUT_SYMS` | pcfsm_quasi_static |
| `0x0E` | `SC_HITS_REQ` | timing_ref_hits |
| `0x27` | `TACC_WINDOW_SYMS` | pcfsm_quasi_static, training_window |

The gate is `cfg_wr_ok = rx_hold && !packet_active` — **both** terms. It
*extends* the existing `!packet_active` gate on 0x09/0x0A and *adds* gating to
0x0B/0x0E/0x27, which have none today.

**`rx_hold` does NOT imply `!packet_active`**, and an earlier revision of this
design wrongly assumed it did. Firmware may assert `RX_HOLD` mid-packet: that
holds `sc_clr` and clears the detector, but `packet_ctrl_fsm` keeps
`packet_active` high until its own timeout. Gating on `rx_hold` alone would
therefore accept config writes during a live packet — reintroducing the
mid-packet desync closed by Open Risks #31/#32, since `sc_detector` and
`training_acc` consume `sf`/`sample_shift` live. Caught by the existing
`test_packet_active_gate_smoke`, and now pinned by
`test_hold_does_not_override_packet_active`.

`SC_THR` (`0x0C`/`0x0D`) is deliberately **not** gated: it appears in no MCP
group and times honestly single-cycle into the comparator.

### 4d. `packet_ctrl_fsm.v` — still needed, ~4 flops

Firmware discipline cannot cover `pcfsm_latched_timing_ref`: `lat_timing_ref`
is latched from `timing_ref` at the lock edge u and captured at u+1, entirely
inside the FSM, no matter what firmware does. Hold `ST_ACQ_SETUP` for four
cycles so the capture lands at u+4:

```verilog
reg [1:0] setup_cnt;          // reset to 0; cleared in the ST_IDLE sc_lock branch

ST_ACQ_SETUP: begin
    packet_phase <= 3'd1;
    if (setup_cnt == 2'd3) begin
        acq_cnt   <= acq_load;
        wpend_cnt <= wpend_load;
        pkt_cnt   <= pkt_load;
        state     <= ST_PREAMBLE_ACQ;
    end else begin
        setup_cnt <= setup_cnt + 2'd1;
    end
end
```

Arithmetically free: the counters hold *remaining* ticks recomputed at the load
edge from live `sample_count` (`packet_ctrl_fsm.v:88-108`), so a later load
yields a proportionally smaller remainder and the absolute fire instant is
unchanged. The decrement block already excludes `ST_ACQ_SETUP`, and
`packet_phase` is 1 in both states. Cost: 3 extra cycles (~94 ns) against a
≥8 µs symbol.

## 5. The release-ordering argument

The one real timing obligation this design creates: after the last config
write, `RX_HOLD` must not be released for ≥3 cycles.

`rb_we` is asserted only on `ce_16m` slots (`trouper_top.v:684-701`), so any two
register writes land **at least 2 cycles apart**, and the config write and the
`RX_HOLD` release are necessarily separate transactions to different addresses.
Worst case, via the Grouper bus at its maximum rate:

| edge | event |
|---|---|
| t | last config write lands; source changes |
| t+2 | `RX_HOLD` release lands; `sc_clr` deasserts |
| t+3 | first edge on which a config-derived value can be captured |

The capture at `C = t+3` requires `cfg[t+2] == cfg[t+1] == cfg[t]`, all of which
are the new value. **Satisfied with no margin to spare.** Over SPI it is not
close: one frame is ≥1.6 µs ≈ 51 cycles at 32 MHz.

The Grouper path is the tight one and must be tested explicitly rather than
assumed — it is a same-clock parallel bus with no CDC (Open Risk #29), so its
write cadence is set by the Grouper master, not by a serial frame.

`pcfsm` and `training_acc` captures are far looser: they occur at `sc_lock`,
which needs `sc_hits_req+1` correlator hits of ≥1 symbol each (≥64 cycles) after
release, so their sources are thousands of cycles settled.

## 6. Coverage

| Group | Closed by | RTL cost |
|---|---|---|
| `sc_quasi_static` | firmware contract | 0 |
| `timing_ref_hits` | firmware contract | 0 |
| `timing_ref_config` | firmware contract | 0 |
| `training_window` | firmware contract | 0 |
| `pcfsm_quasi_static` | firmware contract | 0 |
| `pcfsm_mval` | firmware contract (`M_val` constant while `sf` is) | 0 |
| `pcfsm_latched_timing_ref` | §4d counter | ~4 flops |
| `psram_barrel_shift` | already sound (`psram_buf_ctrl.v:314`) | 0, bench only |
| `sc_clear` | **not addressed** — see §7 | — |

Total new logic: `RX_HOLD` + `CFG_WR_REJECTED` + `setup_cnt` ≈ 4–6 flops and a
handful of gates, all either in `reg_bank` (the `ce_16m` CE-gated domain, off
the 32 MHz critical path) or in the `packet_ctrl_fsm` setup state. **No enable
terms added to any wide register in `sc_detector` or `training_acc`.**

## 7. Out of scope

- **`sc_clear`** is unsound for an unrelated reason: its source is a 1-cycle
  `packet_done_pulse` (`trouper_top.v:581-585`) into synchronous-clear registers
  that sample every cycle, so no 3-cycle window can exist. Fix is to stretch the
  pulse to ≥3 cycles or withdraw the exception. Needs its own analysis.
- **Retiring the exceptions entirely** (registered spans, or moving the span
  arithmetic into the `ce_16m` domain) is a separate, larger decision — see
  Open Risks #43. This design makes the existing exceptions *true*; it does not
  remove them, and it does not change SS timing.
- The honest-SDC gap (job 4349, −22.84 ns with exceptions withdrawn) is
  untouched and remains Open Risks #1.

## 8. Verification

| # | Test | Where | Proves | Status |
|---|---|---|---|---|
| 1 | writes to 0x09/0x0A/0x0B/0x0E/0x27 rejected while `!RX_HOLD`, accepted while `RX_HOLD`, sticky bit sets and W1C clears, and `RX_HOLD` does not override `packet_active` | `cocotb/reg_bank` | the gate is enforced, not documented | ✅ **done** — `cocotb/tests/test_reg_bank_rx_hold.py`, 6 tests, full suite 13/13 PASS (SGE job 4353) |
| 2 | `sc_lock` cannot assert while `RX_HOLD`, including via `SC_FORCE_LOCK` | `cocotb/sc_force_lock` | the mutual exclusion holds | — |
| 3 | background monitor: no MCP'd config net changes on any cycle where the detector can lock | `cocotb/mcp_cfg_hold_settle` (new) | the settling property itself, for 5 groups | — |
| 4 | Grouper back-to-back config-write → `RX_HOLD` release at minimum cadence; first capture ≥3 cycles after the change | `cocotb/spi_cdc` (has the GRP handle already) | §5's tight case | — |
| 5 | existing `test_mcp_pcfsm_settle` flips both FAILs to PASS | `cocotb/mcp_pcfsm_settle` | §4d | — |
| 6 | `psram_barrel_shift` settle bench | new, mirrors #5 | the one already-sound group | — |

Manifest `proof` fields in `rtl-test/ol_trouper_top/mcp_audit_manifest.json` are
updated **only** after the corresponding bench passes — a group is never marked
proven on a design intention.

**Regression exposure:** if `RX_HOLD` has a reset value of 1, every suite that resets and
expects a lock needs an explicit release. Mechanical, but it touches most of the
cocotb tree. Budget for it, and do not blanket-rebaseline: a suite that fails
for any reason other than the missing release is a real finding.

## 9. Contract changes this creates

- `planning/Register Map.md` — new `0x1A`, and 0x0B/0x0E/0x27 change from
  freely-writable to gated.
- `planning/Firmware Spec.md` + `firmware/picorv32/asic_regs.h` — the
  disable → configure → release sequence, and the `CFG_WR_REJECTED` check.
- Reconfiguration now costs two extra register transactions and cannot be done
  mid-reception. Acceptable given SF/BW changes are already prohibited during a
  packet, but it **is** a transfer of risk from silicon to firmware: a driver
  that ignores the sequence gets silently dropped writes, detectable only via
  `CFG_WR_REJECTED`.
