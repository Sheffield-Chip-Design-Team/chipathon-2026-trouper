"""reg_bank_map_oracle.py -- checked-in table-driven register-map oracle for
the standalone ``cocotb/reg_bank`` harness.

Traceability: planning/verification-plan/reg-bank-verification-plan.md,
Sec 2a step 2 ("Build the standalone harness and map oracle; use it for
#2-#8, #10-#11, and #13-#17"). This module currently backs row #4 (RW field
storage, reserved-bit masking, packed output mapping) via
``test_reg_bank_rw_map.py``; later rows should extend ``GENERIC_RW_FIELDS``
and the helpers below rather than build a second table/harness.

Field formulas are transcribed directly from ``src/control/reg_bank.v``'s
write-case and read-decode blocks, cross-checked against
``planning/Register Map.md``.
"""

from cocotb.triggers import RisingEdge, Timer

CLK_NS = 31.25  # 32 MHz core clock

# Bit-pattern set applied to every writable field, per the plan's Sec 1a
# coverage model: reset (0x00), all-ones (0xFF), two non-symmetric patterns,
# and a full walking-one / walking-zero sweep across all 8 bit positions.
PATTERNS = (
    [0x00, 0xFF, 0xA5, 0x5A, 0x3C, 0xC3]
    + [1 << b for b in range(8)]
    + [(~(1 << b)) & 0xFF for b in range(8)]
)


async def write_reg(dut, addr, data):
    """Drive one register-bus write.

    This harness holds ``clk_en`` asserted every cycle (see
    ``test_reg_bank_rw_map.py`` module docstring for why that is a safe
    simplification for this row), so a write only needs to be valid for one
    rising edge of ``clk``.
    """
    dut.addr.value = addr
    dut.wdata.value = data
    dut.we.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    dut.we.value = 0


async def peek(dut, addr):
    """Combinational read via ``peek_rdata`` -- no clock or wait-state
    involved (``peek_rdata`` is a pure ``always @*`` decode of ``raddr``)."""
    dut.raddr.value = addr
    await Timer(1, unit="ns")
    return int(dut.peek_rdata.value)


class RegField:
    """One generic (plain-storage) RW register.

    ``read_transform(p)`` maps a written byte to the expected readback byte
    (masking any reserved bits to zero, per ``planning/Register Map.md``).
    ``check_outputs(dut, p)`` asserts the corresponding hardware control
    output port(s) reflect the same write.
    """

    def __init__(self, addr, name, read_transform, check_outputs):
        self.addr = addr
        self.name = name
        self.read_transform = read_transform
        self.check_outputs = check_outputs


def _eq(dut, sig_name, expected, addr, pattern, extra=""):
    got = int(getattr(dut, sig_name).value)
    assert got == expected, (
        f"0x{addr:02X} ({sig_name}){extra}: wrote 0x{pattern:02X} "
        f"expected {sig_name}=0x{expected:X} got 0x{got:X}"
    )


def _mimo_ctrl_outputs(dut, p):
    _eq(dut, "antenna_en", (p >> 4) & 0xF, 0x08, p)
    # mimo_mode is a 2-bit register but only bit[0] (MODE) is ever written;
    # bit[1] has no write path in the RTL and stays 0 from reset.
    _eq(dut, "mimo_mode", p & 0x1, 0x08, p)


def _sf_cfg_outputs(dut, p):
    _eq(dut, "sf_cfg", p & 0x0F, 0x09, p)


def _bw_cfg_outputs(dut, p):
    _eq(dut, "bw_sel", p & 0x1, 0x0A, p)


def _sc_ant_sel_outputs(dut, p):
    _eq(dut, "sc_ant_sel", p & 0x3, 0x1B, p)


def _dbg_ctrl_outputs(dut, p):
    _eq(dut, "dbg_ctrl", p, 0x04, p)


def _array_sync_ctrl_outputs(dut, p):
    _eq(dut, "array_sync_en", p & 0x1, 0x18, p)


def _pkt_timeout_outputs(dut, p):
    _eq(dut, "pkt_timeout_syms", p, 0x0B, p)


def _sc_thr_hi_outputs(dut, p):
    got = (int(dut.sc_thr.value) >> 8) & 0xFF
    assert got == p, f"0x0C (sc_thr[15:8]): wrote 0x{p:02X} got 0x{got:02X}"


def _sc_thr_lo_outputs(dut, p):
    got = int(dut.sc_thr.value) & 0xFF
    assert got == p, f"0x0D (sc_thr[7:0]): wrote 0x{p:02X} got 0x{got:02X}"


def _sc_hits_req_outputs(dut, p):
    _eq(dut, "sc_hits_req", p & 0x3, 0x0E, p)


def _comb_cfg_outputs(dut, p):
    _eq(dut, "comb_post_gain_shift", p & 0x7, 0x0F, p)
    _eq(dut, "remod_backoff_shift", (p >> 4) & 0x3, 0x0F, p)


def _w_shadow_field(byte_index):
    addr = 0x30 + byte_index
    shift = 120 - 8 * byte_index

    def check_outputs(dut, p):
        got = (int(dut.w_shadow.value) >> shift) & 0xFF
        assert got == p, (
            f"0x{addr:02X} (w_shadow byte {byte_index}): wrote 0x{p:02X} "
            f"got 0x{got:02X}"
        )

    return RegField(addr, f"W_SHADOW[{byte_index}]", lambda p: p, check_outputs)


def _psram_dbg_addr_lo_outputs(dut, p):
    got = int(dut.psram_dbg_addr.value) & 0xFF
    assert got == p, f"0x72 (psram_dbg_addr[7:0]): wrote 0x{p:02X} got 0x{got:02X}"


def _psram_dbg_addr_mid_outputs(dut, p):
    got = (int(dut.psram_dbg_addr.value) >> 8) & 0xFF
    assert got == p, f"0x73 (psram_dbg_addr[15:8]): wrote 0x{p:02X} got 0x{got:02X}"


def _psram_dbg_addr_hi_outputs(dut, p):
    got = (int(dut.psram_dbg_addr.value) >> 16) & 0x7F
    assert got == (p & 0x7F), (
        f"0x74 (psram_dbg_addr[22:16]): wrote 0x{p:02X} got 0x{got:02X}"
    )


def _replay_delay_lo_outputs(dut, p):
    got = int(dut.replay_delay_samples.value) & 0xFF
    assert got == p, f"0x77 (replay_delay_samples[7:0]): wrote 0x{p:02X} got 0x{got:02X}"


def _replay_delay_hi_outputs(dut, p):
    got = (int(dut.replay_delay_samples.value) >> 8) & 0xFF
    assert got == p, (
        f"0x78 (replay_delay_samples[15:8]): wrote 0x{p:02X} got 0x{got:02X}"
    )


# Plain (non-W1P, non-gated-in-this-sweep) RW fields. Gated fields (0x09,
# 0x0A, 0x1B, 0x77, 0x78) are included here with packet_active held low -- the
# {gate x packet_active 0/1} matrix itself belongs to row #8; a light
# gate-blocked smoke check lives in test_reg_bank_rw_map.py.
GENERIC_RW_FIELDS = (
    [
        RegField(0x08, "MIMO_CTRL", lambda p: (p & 0xF0) | (p & 0x01), _mimo_ctrl_outputs),
        RegField(0x09, "SF_CFG", lambda p: p & 0x0F, _sf_cfg_outputs),
        RegField(0x0A, "BW_CFG", lambda p: p & 0x01, _bw_cfg_outputs),
        RegField(0x04, "DBG_CTRL", lambda p: p, _dbg_ctrl_outputs),
        RegField(0x18, "ARRAY_SYNC_CTRL", lambda p: p & 0x01, _array_sync_ctrl_outputs),
        RegField(0x0B, "PKT_TIMEOUT_SYMS", lambda p: p, _pkt_timeout_outputs),
        RegField(0x0C, "SC_THR_HI", lambda p: p, _sc_thr_hi_outputs),
        RegField(0x0D, "SC_THR_LO", lambda p: p, _sc_thr_lo_outputs),
        RegField(0x0E, "SC_HITS_REQ", lambda p: p & 0x3, _sc_hits_req_outputs),
        RegField(0x0F, "COMB_CFG", lambda p: p & 0x37, _comb_cfg_outputs),
        RegField(0x1B, "SC_ANT_SEL", lambda p: p & 0x03, _sc_ant_sel_outputs),
    ]
    + [_w_shadow_field(i) for i in range(16)]
    + [
        RegField(0x72, "PSRAM_DBG_ADDR_LO", lambda p: p, _psram_dbg_addr_lo_outputs),
        RegField(0x73, "PSRAM_DBG_ADDR_MID", lambda p: p, _psram_dbg_addr_mid_outputs),
        RegField(0x74, "PSRAM_DBG_ADDR_HI", lambda p: p & 0x7F, _psram_dbg_addr_hi_outputs),
        RegField(0x77, "REPLAY_DELAY_LO", lambda p: p, _replay_delay_lo_outputs),
        RegField(0x78, "REPLAY_DELAY_HI", lambda p: p, _replay_delay_hi_outputs),
    ]
)


async def run_field_sweep(dut, field, patterns=PATTERNS):
    for p in patterns:
        await write_reg(dut, field.addr, p)
        got = await peek(dut, field.addr)
        expected = field.read_transform(p)
        assert got == expected, (
            f"{field.name} (0x{field.addr:02X}): wrote 0x{p:02X} "
            f"expected read 0x{expected:02X} got 0x{got:02X}"
        )
        if field.check_outputs:
            field.check_outputs(dut, p)
