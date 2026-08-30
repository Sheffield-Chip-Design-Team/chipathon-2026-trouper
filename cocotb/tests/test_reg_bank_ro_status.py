"""test_reg_bank_ro_status.py -- exhaustive RO/hardware-status input decode
and multi-byte big-endian byte-lane mapping for the standalone reg_bank
harness (``cocotb/reg_bank``, direct-DUT: no SPI/CDC framing).

Closes verification-plan rows #5 and #6
(planning/verification-plan/reg-bank-verification-plan.md):

  #5 "Every RO/status input decode and reserved-bit zeroing" -- directly
     drives every packet, training, SC, Z-pair/Z-diagonal, and PSRAM
     hardware-status input with non-symmetric patterns (not just 0x00/0xFF)
     and confirms each RO register's bit/byte decode and reserved-bit
     zeroing.
  #6 "Multi-byte big-endian ordering and truncation" -- for every
     multi-byte field (the 18-bit N_ACC, 16-bit SC_STAT, two 32-bit SC debug
     snapshots, the six [31:8]-truncated 32-bit Z_kl pairs and four Z_kk
     diagonals), confirms big-endian byte order (byte 0 = MSB) and that
     bytes narrower than 8 bits truncate rather than alias into neighboring
     bytes.

Scope and layering (see the plan's Sec 4 "Explicit non-goals"): this suite
proves *decode*, not the arithmetic correctness of the values themselves --
that belongs to the source blocks (training_acc, sc_detector, psram_buf_ctrl,
packet_ctrl_fsm). It reuses ``reg_bank_map_oracle``'s ``peek``/``write_reg``
helpers and the ``_bring_up``/``_idle_inputs`` harness bring-up from
``test_reg_bank_rw_map`` for consistency with the rest of this standalone
suite. IRQ_STATUS (0x02) decode/precedence is explicitly left to rows
#13-#15; WGT_CTRL's RO status mirror (0x1E[4:1]) and PSRAM_DBG_CTRL's DBG_BUSY
mirror (0x75[7]) are already covered by row #4's dedicated field tests and
are not repeated here.
"""

import cocotb

from reg_bank_map_oracle import peek
from test_reg_bank_rw_map import _bring_up

# Distinctive non-symmetric byte pattern, striped across however many bytes
# a field needs: 0x1D (0001_1101), 0x62 (0110_0010), 0xB4 (1011_0100),
# 0xC7 (1100_0111) -- deliberately not a walking-one/all-same/palindromic
# byte, so a byte-swap or lane-alias bug cannot hide behind symmetry.
STRIPE_BYTES = [0x1D, 0x62, 0xB4, 0xC7]


def _stripe(nbytes):
    """First ``nbytes`` of STRIPE_BYTES, MSB-first."""
    return STRIPE_BYTES[:nbytes]


def _value_from_bytes(byte_list):
    v = 0
    for b in byte_list:
        v = (v << 8) | b
    return v


# ---------------------------------------------------------------------------
# 0x1C PACKET_STATUS -- {w_missed_rb, w_valid_rb, w_pending_rb,
#                          training_done_rb, packet_phase[2:0], packet_active}
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_packet_status_decode(dut):
    await _bring_up(dut)

    combos = [
        (0, 0, 0, 0, 0b000, 0),
        (1, 1, 1, 1, 0b111, 1),
        (1, 0, 1, 0, 0b101, 0),
        (0, 1, 0, 1, 0b010, 1),
        (1, 1, 0, 0, 0b011, 0),
    ]
    for w_missed, w_valid, w_pending, training_done, phase, active in combos:
        dut.w_missed_rb.value = w_missed
        dut.w_valid_rb.value = w_valid
        dut.w_pending_rb.value = w_pending
        dut.training_done_rb.value = training_done
        dut.packet_phase.value = phase
        dut.packet_active.value = active

        got = await peek(dut, 0x1C)
        expected = (
            (w_missed << 7) | (w_valid << 6) | (w_pending << 5)
            | (training_done << 4) | (phase << 1) | active
        )
        assert got == expected, (
            f"PACKET_STATUS: inputs missed={w_missed} valid={w_valid} "
            f"pending={w_pending} done={training_done} phase={phase:03b} "
            f"active={active} expected 0x{expected:02X} got 0x{got:02X}"
        )

    dut.w_missed_rb.value = 0
    dut.w_valid_rb.value = 0
    dut.w_pending_rb.value = 0
    dut.training_done_rb.value = 0
    dut.packet_phase.value = 0
    dut.packet_active.value = 0


    # DBG_STATUS (0x05) reads this back; the reg_bank bench drives the
    # module directly, so an undriven input would return X and break
    # any read of that address.
    dut.dbg_pad_value.value = 0
# ---------------------------------------------------------------------------
# 0x1D ACTIVE_STATUS -- {active_antenna_en_rb[3:0], 2'h0, active_mode_rb[1:0]}
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_active_status_decode(dut):
    await _bring_up(dut)

    for ant, mode in [(0x0, 0), (0xF, 3), (0xA, 1), (0x5, 2), (0x9, 0)]:
        dut.active_antenna_en_rb.value = ant
        dut.active_mode_rb.value = mode
        got = await peek(dut, 0x1D)
        expected = (ant << 4) | mode
        assert got == expected, (
            f"ACTIVE_STATUS: ant=0x{ant:X} mode={mode:02b} "
            f"expected 0x{expected:02X} got 0x{got:02X}"
        )

    # Reserved bits [3:2] must read 0 regardless of anything driven -- there
    # is no input port wired to them, so this is really confirming the
    # constant 2'h0 splice never gets corrupted by adjacent field placement.
    dut.active_antenna_en_rb.value = 0xF
    dut.active_mode_rb.value = 3
    got = await peek(dut, 0x1D)
    assert (got & 0x0C) == 0, f"ACTIVE_STATUS reserved bits[3:2] not zero: got 0x{got:02X}"

    dut.active_antenna_en_rb.value = 0
    dut.active_mode_rb.value = 0


# ---------------------------------------------------------------------------
# 0x20 TRAINING_STATUS -- {6'h0, training_armed, training_done_rb}
# 0x21-0x23 N_ACC[17:0] big-endian, byte 0 = {6'h0, n_acc[17:16]}
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_training_status_and_n_acc_decode(dut):
    await _bring_up(dut)

    for armed, done in [(0, 0), (1, 0), (0, 1), (1, 1)]:
        dut.training_armed.value = armed
        dut.training_done_rb.value = done
        got = await peek(dut, 0x20)
        expected = (armed << 1) | done
        assert got == expected, (
            f"TRAINING_STATUS: armed={armed} done={done} "
            f"expected 0x{expected:02X} got 0x{got:02X}"
        )
    dut.training_armed.value = 0
    dut.training_done_rb.value = 0

    # N_ACC is 18 bits: byte0=[17:16] (reserved bits[7:2] must be zero),
    # byte1=[15:8], byte2=[7:0]. Row #6: big-endian order + truncation.
    for n_acc in (0x00000, 0x3FFFF, 0x2A5C7, 0x15A38, 0x30001, 0x00001):
        dut.n_acc.value = n_acc & 0x3FFFF
        hi = await peek(dut, 0x21)
        mid = await peek(dut, 0x22)
        lo = await peek(dut, 0x23)
        assert hi == ((n_acc >> 16) & 0x3), (
            f"N_ACC_HI: n_acc=0x{n_acc:05X} expected 0x{(n_acc>>16)&0x3:02X} got 0x{hi:02X}"
        )
        assert (hi & 0xFC) == 0, f"N_ACC_HI reserved bits[7:2] not zero: got 0x{hi:02X}"
        assert mid == ((n_acc >> 8) & 0xFF), (
            f"N_ACC_MID: n_acc=0x{n_acc:05X} expected 0x{(n_acc>>8)&0xFF:02X} got 0x{mid:02X}"
        )
        assert lo == (n_acc & 0xFF), (
            f"N_ACC_LO: n_acc=0x{n_acc:05X} expected 0x{n_acc&0xFF:02X} got 0x{lo:02X}"
        )
    dut.n_acc.value = 0


# ---------------------------------------------------------------------------
# 0x24-0x25 SC_STAT[15:0] big-endian
# 0x26 SC_DBG_FLAGS -- {4'h0, sc_lock_dbg, sc_hit_count_dbg[1:0], sc_hit_dbg}
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sc_stat_and_dbg_flags_decode(dut):
    await _bring_up(dut)

    for sc_stat in (0x0000, 0xFFFF, 0x1D62, 0xB4C7, 0x8001, 0x00FF, 0xFF00):
        dut.sc_stat.value = sc_stat
        hi = await peek(dut, 0x24)
        lo = await peek(dut, 0x25)
        assert hi == ((sc_stat >> 8) & 0xFF), (
            f"SC_STAT_HI: sc_stat=0x{sc_stat:04X} expected 0x{(sc_stat>>8)&0xFF:02X} got 0x{hi:02X}"
        )
        assert lo == (sc_stat & 0xFF), (
            f"SC_STAT_LO: sc_stat=0x{sc_stat:04X} expected 0x{sc_stat&0xFF:02X} got 0x{lo:02X}"
        )
    dut.sc_stat.value = 0

    for lock, cnt, hit in [(0, 0, 0), (1, 3, 1), (0, 2, 1), (1, 1, 0), (0, 0, 1)]:
        dut.sc_lock_dbg.value = lock
        dut.sc_hit_count_dbg.value = cnt
        dut.sc_hit_dbg.value = hit
        got = await peek(dut, 0x26)
        expected = (lock << 3) | (cnt << 1) | hit
        assert got == expected, (
            f"SC_DBG_FLAGS: lock={lock} cnt={cnt:02b} hit={hit} "
            f"expected 0x{expected:02X} got 0x{got:02X}"
        )
        assert (got & 0xF0) == 0, f"SC_DBG_FLAGS reserved bits[7:4] not zero: got 0x{got:02X}"
    dut.sc_lock_dbg.value = 0
    dut.sc_hit_count_dbg.value = 0
    dut.sc_hit_dbg.value = 0


# ---------------------------------------------------------------------------
# 0x28-0x2B SC_FIRST_HIT[31:0] big-endian (full 32-bit, no truncation)
# 0x2C-0x2F SC_LOCK_SNAP[31:0] big-endian (full 32-bit, no truncation)
# ---------------------------------------------------------------------------

async def _check_32b_field(dut, port_name, base_addr, values):
    for v in values:
        getattr(dut, port_name).value = v & 0xFFFFFFFF
        for i in range(4):
            got = await peek(dut, base_addr + i)
            shift = 24 - 8 * i
            expected = (v >> shift) & 0xFF
            assert got == expected, (
                f"{port_name} byte{i} @0x{base_addr+i:02X}: value=0x{v:08X} "
                f"expected 0x{expected:02X} got 0x{got:02X}"
            )
    getattr(dut, port_name).value = 0


@cocotb.test()
async def test_sc_first_hit_and_lock_snap_decode(dut):
    await _bring_up(dut)

    values = [0x00000000, 0xFFFFFFFF, 0x1D62B4C7, 0x80000001, 0x00FF00FF, 0xA5A5A5A5]
    await _check_32b_field(dut, "sc_first_hit_dbg", 0x28, values)
    await _check_32b_field(dut, "sc_lock_snap_dbg", 0x2C, values)


# ---------------------------------------------------------------------------
# 0x40-0x63 Z_kl pairs -- top 24 bits [31:8] of each int32, big-endian,
# 3 bytes per component (I then Q), 6 bytes per pair. Truncation: the low 8
# bits of each 32-bit accumulator are dropped, not aliased into neighbors.
# ---------------------------------------------------------------------------

ZPAIR_PORTS = [
    ("zpair_i0", "zpair_q0", 0x40), ("zpair_i1", "zpair_q1", 0x46),
    ("zpair_i2", "zpair_q2", 0x4C), ("zpair_i3", "zpair_q3", 0x52),
    ("zpair_i4", "zpair_q4", 0x58), ("zpair_i5", "zpair_q5", 0x5E),
]

ZDIAG_PORTS = [
    ("zdiag_0", 0x64), ("zdiag_1", 0x67), ("zdiag_2", 0x6A), ("zdiag_3", 0x6D),
]

# Non-symmetric 32-bit values whose low byte differs from what would appear
# in [31:8] if truncation were broken (e.g. an off-by-one shift), to make a
# lane bug visible rather than accidentally matching.
Z_VALUES = [0x00000000, 0xFFFFFFFF, 0x1D62B4C7, 0x800000FF, 0x7FFFFF00, 0x123456FE]


async def _check_top24_field(dut, port_name, base_addr, values):
    for v in values:
        v32 = v & 0xFFFFFFFF
        getattr(dut, port_name).value = v32
        for i in range(3):
            got = await peek(dut, base_addr + i)
            shift = 24 - 8 * i  # bits [31:24], [23:16], [15:8] -- bits[7:0] dropped
            expected = (v32 >> shift) & 0xFF
            assert got == expected, (
                f"{port_name} byte{i} @0x{base_addr+i:02X}: value=0x{v32:08X} "
                f"expected 0x{expected:02X} got 0x{got:02X} (bits[7:0]=0x{v32&0xFF:02X} "
                f"must be truncated, not leak into byte{i})"
            )
    getattr(dut, port_name).value = 0


@cocotb.test()
async def test_zpair_decode(dut):
    """All 6 Z_kl pairs (I and Q each), non-symmetric values, truncation."""
    await _bring_up(dut)
    for i_port, q_port, base in ZPAIR_PORTS:
        await _check_top24_field(dut, i_port, base, Z_VALUES)
        await _check_top24_field(dut, q_port, base + 3, Z_VALUES)


@cocotb.test()
async def test_zdiag_decode(dut):
    """All 4 Z_kk diagonal accumulators, non-symmetric values, truncation."""
    await _bring_up(dut)
    for port, base in ZDIAG_PORTS:
        await _check_top24_field(dut, port, base, Z_VALUES)


# ---------------------------------------------------------------------------
# 0x71 PSRAM_STATUS -- direct 8-bit passthrough
# 0x76 PSRAM_DBG_DATA -- psram_dbg_busy ? 0 : psram_dbg_data
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_psram_status_and_dbg_data_decode(dut):
    await _bring_up(dut)

    for v in (0x00, 0xFF, 0x1D, 0xB4, 0xA5, 0x5A):
        dut.psram_status_rb.value = v
        got = await peek(dut, 0x71)
        assert got == v, f"PSRAM_STATUS: drove 0x{v:02X} got 0x{got:02X}"
    dut.psram_status_rb.value = 0

    # PSRAM_DBG_DATA passes through psram_dbg_data while not busy...
    dut.psram_dbg_busy.value = 0
    for v in (0x00, 0xFF, 0x62, 0xC7):
        dut.psram_dbg_data.value = v
        got = await peek(dut, 0x76)
        assert got == v, f"PSRAM_DBG_DATA (idle): drove 0x{v:02X} got 0x{got:02X}"

    # ...and reads 0x00 while busy, regardless of the data value underneath.
    dut.psram_dbg_busy.value = 1
    for v in (0x00, 0xFF, 0x62, 0xC7):
        dut.psram_dbg_data.value = v
        got = await peek(dut, 0x76)
        assert got == 0x00, (
            f"PSRAM_DBG_DATA (busy): expected 0x00 while busy, got 0x{got:02X} "
            f"(underlying data 0x{v:02X} leaked through)"
        )
    dut.psram_dbg_busy.value = 0
    dut.psram_dbg_data.value = 0
