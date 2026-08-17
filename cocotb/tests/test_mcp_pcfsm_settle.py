"""
test_mcp_pcfsm_settle.py -- Open Risks item 43 settling proof for the
`pcfsm_quasi_static` and `pcfsm_mval` MCP groups.

What the SDC claims
-------------------
`src/config/pnr_32m_scoped_v25_b6.sdc` grants MCP=3 setup / 2 hold on:

  pcfsm_quasi_static: -through {rb_sf_cfg* rb_sample_shift* rb_bw_sel*
                                rb_pkt_timeout_syms* rb_tacc_window_syms*}
                      -to {u_pcfsm.acq_cnt[*] wpend_cnt[*] pkt_cnt[*]}
  pcfsm_mval:         -through {u_pcfsm.M_val[*]} -to (same registers)

justified as "host-writable, kHz-rate, long-settled by the time any hit/lock
event samples it".

What the RTL actually does
--------------------------
`packet_ctrl_fsm.v` consumes all of these in ONE combinational cone
(`acq_span`/`wpend_span`/`pkt_span` -> `acq_load`/`wpend_load`/`pkt_load`,
lines 80-108) that is captured at exactly ONE instant per packet: the
`ST_ACQ_SETUP` edge (line 190-199). The sequence is

    edge u   : ST_IDLE sees sc_lock rising -> packet_active<=1, state<=ST_ACQ_SETUP,
               setup_cnt<=0
    edge u+1..u+3 : ST_ACQ_SETUP dwell, setup_cnt counts 1,2,3; the counters HOLD
    edge u+4 : setup_cnt==3 -> acq_cnt/wpend_cnt/pkt_cnt <= *_load

So the MCP=3 exception is sound if and only if every source in the cone has
been stable for >= 3 cycles before the capture edge.

BEFORE the §4d fix the capture was at u+1, giving lat_timing_ref (latched at u)
and M_val (one stage behind sf, so settling at u+1) only ONE settled cycle.
That is what tests 2 and 3 below measured, and why the dwell exists.

That is the property asserted here. It is NOT assumed: the monitor watches
every load edge and checks the recorded history of the source signals.

  test_pcfsm_load_settle_normal      -- config written well before the packet
      (the intended firmware flow). Establishes the property holds in normal
      operation, and asserts a load was actually observed so the pass cannot
      be vacuous.
  test_pcfsm_config_change_before_lock -- the adversarial case the SDC's
      "kHz-rate" argument waves at: a config write landing in the handful of
      cycles immediately before sc_lock rises. `sf_cfg`/`bw_sel` are write-
      locked on `!packet_active`, but packet_active only rises AT edge u, so a
      write is still accepted at u-1 and even at u. Before §4d this failed
      (M_val settled at u+1, captured at u+1); with the dwell the capture moves
      to u+4 and the same stimulus must now pass.
  test_pcfsm_midpacket_change_is_safe -- the converse, worth pinning: changes
      to the ungated sources DURING a packet are harmless, because the cone is
      only ever captured at ST_ACQ_SETUP. This bounds the hazard to the
      pre-lock window rather than the whole packet.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

CLK_NS = 31.25
ST_ACQ_SETUP = 4
SETTLE = 3          # cycles the MCP=3 setup exception claims
DWELL_LAST = 3      # packet_ctrl_fsm captures when setup_cnt == 3 (4th cycle)

SF = 7
SHIFT = 1
PKT_TIMEOUT = 0x50
TACC_WINDOW = 8


def _sources(dut):
    """The quasi-static operands feeding the ST_ACQ_SETUP load cone."""
    return {
        "sf": int(dut.sf.value),
        "sample_shift": int(dut.sample_shift.value),
        "pkt_timeout_syms": int(dut.pkt_timeout_syms.value),
        "tacc_window_syms": int(dut.tacc_window_syms.value),
        "M_val": int(dut.M_val.value),
    }


class SettleMonitor:
    """Records source history and checks stability at every load edge.

    After `RisingEdge` + `ReadOnly`, `state` and `setup_cnt` hold the values
    the FSM entered at that edge. The load executes on the edge FOLLOWING the
    last dwell cycle, i.e. one edge after we observe
    `state == ST_ACQ_SETUP && setup_cnt == DWELL_LAST`; it captures the source
    values as they stand at that observation. So the load is honest iff the
    samples taken after that edge and the SETTLE-1 before it are all identical.

    The monitor also checks the dwell genuinely holds the counters, so the
    capture predicate is validated against the RTL rather than assumed.
    """

    def __init__(self, dut):
        self.dut = dut
        self.history = []       # newest last
        self.loads = 0
        self.violations = []
        self.dwell_holds = 0

    def _counters(self):
        return (int(self.dut.acq_cnt.value),
                int(self.dut.wpend_cnt.value),
                int(self.dut.pkt_cnt.value))

    async def run(self):
        prev_counters = None
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.rst_n.value) == 0:
                self.history.clear()
                prev_counters = None
                continue
            self.history.append(_sources(self.dut))
            in_setup = int(self.dut.state.value) == ST_ACQ_SETUP
            dwell = int(self.dut.setup_cnt.value)
            counters = self._counters()

            # The dwell must actually HOLD the counters: if they moved on a
            # non-capture ST_ACQ_SETUP cycle, the capture predicate below is
            # wrong and every settle check would be measuring the wrong edge.
            # Verified rather than assumed, so the test cannot silently drift
            # from the RTL.
            if in_setup and dwell < DWELL_LAST and prev_counters is not None:
                self.dwell_holds += 1
                if counters != prev_counters:
                    self.violations.append(
                        f"counters moved during the ST_ACQ_SETUP dwell at "
                        f"setup_cnt={dwell}: {prev_counters} -> {counters}"
                    )
            prev_counters = counters

            # Capture edge: the load executes on the NEXT edge after the last
            # dwell cycle (RTL: `if (setup_cnt == 2'd3)` inside ST_ACQ_SETUP).
            if in_setup and dwell == DWELL_LAST:
                self.loads += 1
                window = self.history[-SETTLE:]
                if len(window) < SETTLE:
                    # Too close to reset to judge; record rather than pass.
                    self.violations.append(
                        f"load #{self.loads}: only {len(window)} cycles of "
                        f"history since reset, cannot prove {SETTLE}"
                    )
                elif any(s != window[-1] for s in window):
                    changed = {
                        k for k in window[-1]
                        if any(s[k] != window[-1][k] for s in window)
                    }
                    self.violations.append(
                        f"load #{self.loads}: {sorted(changed)} changed within "
                        f"{SETTLE} cycles of the ST_ACQ_SETUP capture; "
                        f"history(oldest->newest)={window}"
                    )


async def _reset(dut):
    dut.rst_n.value = 0
    dut.sample_count.value = 0
    dut.iq_tick.value = 0
    dut.sf.value = SF
    dut.sample_shift.value = SHIFT
    dut.sc_lock.value = 0
    dut.timing_ref.value = 0
    dut.training_done.value = 0
    dut.W_commit.value = 0
    dut.mode_shadow.value = 0
    dut.antenna_en_shadow.value = 0xF
    dut.pkt_timeout_syms.value = PKT_TIMEOUT
    dut.tacc_window_syms.value = TACC_WINDOW
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


async def _start(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    await _reset(dut)
    mon = SettleMonitor(dut)
    cocotb.start_soon(mon.run())
    return mon


async def _pulse_lock(dut, sample_count=1000, timing_ref=900):
    """Raise sc_lock so ST_IDLE takes the acquisition branch."""
    dut.sample_count.value = sample_count
    dut.timing_ref.value = timing_ref
    dut.sc_lock.value = 1
    await ClockCycles(dut.clk, 4)


@cocotb.test()
async def test_pcfsm_load_settle_normal(dut):
    """Config settled long before lock -- the intended firmware flow."""
    mon = await _start(dut)
    await ClockCycles(dut.clk, 20)          # config stable for many cycles
    await _pulse_lock(dut)
    await ClockCycles(dut.clk, 10)

    assert mon.loads >= 1, "no ST_ACQ_SETUP load observed -- test is vacuous"
    assert mon.dwell_holds >= 1, (
        "no ST_ACQ_SETUP dwell cycles observed -- the §4d hold is not present, "
        "so the capture predicate is untested"
    )
    assert not mon.violations, (
        "settle property violated in the NORMAL flow:\n  "
        + "\n  ".join(mon.violations)
    )
    dut._log.info(f"normal flow: {mon.loads} load(s), {mon.dwell_holds} dwell "
                  f"cycle(s), settle property holds")


@cocotb.test()
async def test_pcfsm_config_change_before_lock(dut):
    """Config write landing in the cycles immediately before sc_lock rises.

    This is the case the SDC's "kHz-rate" justification does not cover: the
    write rate is irrelevant, only the distance between the last change and
    the single capture edge matters.
    """
    mon = await _start(dut)
    await ClockCycles(dut.clk, 20)

    # Change a quasi-static operand exactly one cycle before sc_lock rises,
    # which reg_bank permits because packet_active is still 0 at this edge.
    dut.sf.value = SF + 1
    dut.pkt_timeout_syms.value = PKT_TIMEOUT + 1
    await ClockCycles(dut.clk, 1)
    await _pulse_lock(dut)
    await ClockCycles(dut.clk, 10)

    assert mon.loads >= 1, "no ST_ACQ_SETUP load observed -- test is vacuous"
    assert not mon.violations, (
        "settle property violated by a pre-lock config change:\n  "
        + "\n  ".join(mon.violations)
        + "\n\nThe MCP=3 exception on this cone is therefore not justified by "
          "the RTL as it stands -- see the module docstring."
    )


@cocotb.test()
async def test_pcfsm_direct_source_change_at_lock(dut):
    """Separate the two groups: does the DIRECT cone violate, or only M_val?

    test_pcfsm_config_change_before_lock changes sf one cycle before lock, so
    the direct sources (sf/pkt_timeout_syms, the `pcfsm_quasi_static` group)
    have already settled by the capture and only the derived `M_val` register
    -- one pipeline stage behind sf -- is still moving. Changing them AT the
    lock edge instead, which reg_bank also permits (packet_active is still 0
    when that write is sampled), tests the direct cone itself.
    """
    mon = await _start(dut)
    await ClockCycles(dut.clk, 20)

    # Land the config change on the same edge that sc_lock rises.
    dut.sc_lock.value = 1
    dut.sample_count.value = 1000
    dut.timing_ref.value = 900
    dut.sf.value = SF + 1
    dut.pkt_timeout_syms.value = PKT_TIMEOUT + 1
    dut.tacc_window_syms.value = TACC_WINDOW + 1
    await ClockCycles(dut.clk, 10)

    assert mon.loads >= 1, "no ST_ACQ_SETUP load observed -- test is vacuous"
    assert not mon.violations, (
        "settle property violated by a config change at the lock edge:\n  "
        + "\n  ".join(mon.violations)
    )


@cocotb.test()
async def test_pcfsm_midpacket_change_is_safe(dut):
    """Ungated sources changing mid-packet must not reach the counters.

    Bounds the hazard: pkt_timeout_syms/tacc_window_syms have no
    packet_active write-lock, but the load cone is captured only at
    ST_ACQ_SETUP, so a mid-packet change cannot be captured at all.
    """
    mon = await _start(dut)
    await ClockCycles(dut.clk, 20)
    await _pulse_lock(dut)
    await ClockCycles(dut.clk, 6)

    loads_before = mon.loads
    pkt_cnt_before = int(dut.pkt_cnt.value)

    # Well inside the packet now: change the ungated operands.
    dut.pkt_timeout_syms.value = 0xFF
    dut.tacc_window_syms.value = 0xF
    await ClockCycles(dut.clk, 10)

    assert mon.loads == loads_before, (
        "a second ST_ACQ_SETUP load occurred mid-packet -- the cone is not "
        "single-capture as assumed"
    )
    # pkt_cnt only decrements from here (iq_tick is low, so it should be
    # unchanged); what matters is that it did not RELOAD from the new value.
    assert int(dut.pkt_cnt.value) <= pkt_cnt_before, (
        "pkt_cnt increased mid-packet -- it reloaded from the changed "
        "pkt_timeout_syms, contradicting the single-capture argument"
    )
    assert not mon.violations, (
        "unexpected settle violation in the mid-packet case:\n  "
        + "\n  ".join(mon.violations)
    )
