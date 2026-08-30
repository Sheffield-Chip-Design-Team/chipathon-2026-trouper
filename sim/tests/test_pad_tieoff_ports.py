"""Structural check on the A40 pad-control tie-offs in src/top/trouper_top.v.

The simulation-level contract lives in `cocotb/tests/test_pad_tieoffs.py`.
This is the cheap static companion: it runs in plain pytest with no simulator
and catches the failure mode the cocotb test structurally cannot -- a pad
whose control port was added to the module header but never driven, or driven
by something other than a constant.  An undriven output is `z` in silicon and
would leave a pad's pull/slew/drive configuration floating.
"""

import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
TOP = REPO / "src" / "top" / "trouper_top.v"

# Suffixes of the gf180mcu_fd_io bidirectional-cell control interface.
CTRL_SUFFIXES = ("_PU", "_PD", "_IE", "_OE", "_CS", "_SL", "_PDRV0", "_PDRV1")

# planning/Pinout.md, "A40 pad-control tie-offs": 106 added ports =
# 100 pad-control outputs (96 constant + 4 dynamic PSRAM_SIO_n_IE) + 6 unused
# _IN inputs.  The 4 PSRAM_SIO_n_OE ports pre-date the A40 work and are driven
# functionally by psram_buf_ctrl, giving 104 control outputs in total.
EXPECTED_CTRL_OUTPUTS = 104
EXPECTED_CONSTANT = 96
EXPECTED_DYNAMIC = 4          # PSRAM_SIO_n_IE = ~PSRAM_SIO_OE[n]
EXPECTED_FUNCTIONAL = 4       # PSRAM_SIO_n_OE, driven by a concatenation


@pytest.fixture(scope="module")
def top_src():
    return TOP.read_text()


@pytest.fixture(scope="module")
def ports(top_src):
    m = re.search(r"module trouper_top \((.*?)\n\);", top_src, re.S)
    assert m, "could not locate the trouper_top port list"
    return m.group(1), top_src[m.end():]


def _ctrl_outputs(portlist):
    outs = re.findall(r"output\s+wire\s+(?:\[[^\]]+\]\s+)?(\w+)", portlist)
    return [p for p in outs if p.endswith(CTRL_SUFFIXES)]


def _assign_map(body):
    return dict(re.findall(r"assign\s+(\w+)\s*=\s*([^;]+);", body))


def test_every_pad_control_output_is_driven(ports):
    """No pad-control output may be left floating."""
    portlist, body = ports
    ctrl = _ctrl_outputs(portlist)
    drivers = _assign_map(body)

    # PSRAM_SIO_n_OE is driven by a concatenation assign, not a scalar one.
    concat_driven = set()
    for lhs in re.findall(r"assign\s+\{([^}]+)\}\s*=", body):
        concat_driven.update(n.strip() for n in lhs.split(","))

    undriven = [p for p in ctrl if p not in drivers and p not in concat_driven]
    assert not undriven, (
        "pad-control outputs with no driver (would float in silicon): "
        + ", ".join(undriven)
    )


def test_pad_control_port_count_matches_pinout(ports):
    """Guard the documented port budget against silent drift."""
    portlist, _ = ports
    ctrl = _ctrl_outputs(portlist)
    assert len(ctrl) == EXPECTED_CTRL_OUTPUTS, (
        f"{len(ctrl)} pad-control outputs, expected {EXPECTED_CTRL_OUTPUTS}. "
        "If a pad was added or removed, update planning/Pinout.md, this test, "
        "and the expected table in cocotb/tests/test_pad_tieoffs.py together."
    )


def test_tieoff_drivers_are_constants(ports):
    """Tie-offs must be literal constants; only the 4 SIO _IE are dynamic."""
    portlist, body = ports
    ctrl = set(_ctrl_outputs(portlist))
    drivers = {p: v.strip() for p, v in _assign_map(body).items() if p in ctrl}

    const = {p for p, v in drivers.items() if re.fullmatch(r"1'b[01]", v)}
    dynamic = {p: v for p, v in drivers.items() if p not in const}

    assert len(const) == EXPECTED_CONSTANT, (
        f"{len(const)} constant tie-offs, expected {EXPECTED_CONSTANT}"
    )
    assert set(dynamic) == {f"PSRAM_SIO_{n}_IE" for n in range(4)}, (
        "unexpected non-constant pad-control driver(s): "
        + ", ".join(f"{p} = {v}" for p, v in sorted(dynamic.items()))
    )
    # The IE=OE=1 state is uncharacterized for gf180mcu_fd_io__bi_t, so each
    # lane's IE must be exactly the inversion of its own OE.
    for n in range(4):
        assert dynamic[f"PSRAM_SIO_{n}_IE"] == f"~PSRAM_SIO_OE[{n}]", (
            f"PSRAM_SIO_{n}_IE is '{dynamic[f'PSRAM_SIO_{n}_IE']}', "
            f"expected '~PSRAM_SIO_OE[{n}]'"
        )


def test_unused_pad_inputs_are_sunk(ports):
    """The 6 output-only pads' _IN paths must be explicitly sunk, not dangling."""
    portlist, body = ports
    ins = re.findall(r"input\s+wire\s+(?:\[[^\]]+\]\s+)?(\w+)", portlist)
    pad_ins = [p for p in ins if p.endswith("_IN")]
    # 4 PSRAM_SIO_n_IN are functional read-data; the other 6 are unused.
    unused = [p for p in pad_ins if not re.fullmatch(r"PSRAM_SIO_\d_IN", p)]
    assert len(unused) == 6, f"expected 6 unused pad inputs, found {unused}"

    m = re.search(r"wire\s+_unused_pad_in\s*=\s*&\{([^}]*)\}", body)
    assert m, "no _unused_pad_in sink found in trouper_top.v"
    sunk = {n.strip() for n in m.group(1).split(",")}
    missing = [p for p in unused if p not in sunk]
    assert not missing, f"unused pad inputs not sunk: {missing}"
