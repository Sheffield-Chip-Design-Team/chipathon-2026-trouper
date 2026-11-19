"""Non-circular padring connectivity + tie-off *realization* check (Phase 1).

`cocotb/tests/test_pad_tieoffs.py` checks the pad-control tie-offs against a
table transcribed from `planning/Pinout.md` -- it proves the RTL drives the
values the *document* intends.  Nothing there proves the A40 padring netlist
that ships actually exposes those pins, on the right cell, with the right
direction.  This test closes that gap by cross-checking four independent
sources against each other, with no simulator:

  1. `rtl-test/ol_trouper_top/a40_integrator/A40_ACV_padring.v`   (the netlist)
  2. `.../A40_ACV_pad_map.yaml`        (slot <-> pin <-> cell, 27 pins)
  3. `.../A40_ACV_interface.yaml`      (per-terminal integrator contract)
  4. `src/top/trouper_top.v`           (the 132 pad-facing ports + tie-offs)

It is deliberately *not* circular with `test_pad_tieoffs.py`:

  * assertions (a),(b),(d) are pure netlist/contract structure;
  * assertion (c) ("tie-off values are electrically legal for the cell")
    applies the legality rules to the values parsed straight out of
    `trouper_top.v` `assign` statements, keyed by the cell the pad_map
    assigns -- it does not re-parse the Pinout.md prose table (that table is
    already the source `test_pad_tieoffs.py` checks against in simulation, so
    re-reading it here would add nothing).  Checking RTL-value x cell-type is
    a genuinely new cross-check: it catches a `_PDRV*` driven onto a 24 mA
    pad, an `IE=OE=1` constant, or a pull enabled on the wrong cell,
    regardless of what any document says.
  * assertion (e) guards the sibling `test_pad_tieoff_ports.py` from drifting
    back to the stale `~PSRAM_SIO_OE[n]` expectation (Open Risk #69).

The `_ctrl_outputs` / `_assign_map` regex helpers are copied verbatim from
`sim/tests/test_pad_tieoff_ports.py` rather than imported, to keep this file a
standalone plain-pytest module with no sibling-import path assumptions.
"""

import re
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

REPO = Path(__file__).resolve().parents[2]
TOP = REPO / "src" / "top" / "trouper_top.v"
INFO = REPO / "info.yaml"
A40 = REPO / "rtl-test" / "ol_trouper_top" / "a40_integrator"
PADRING_V = A40 / "A40_ACV_padring.v"
PAD_MAP = A40 / "A40_ACV_pad_map.yaml"
INTERFACE = A40 / "A40_ACV_interface.yaml"
PORTS_TEST = Path(__file__).with_name("test_pad_tieoff_ports.py")

# gf180mcu_fd_io bidirectional-cell control-pin suffixes (from test_pad_tieoff_ports.py)
CTRL_SUFFIXES = ("_PU", "_PD", "_IE", "_OE", "_CS", "_SL", "_PDRV0", "_PDRV1")

# planning/Pinout.md "Pad cell type selection": info.yaml io_type -> (cell, core-side control pins)
IO_TYPE_CELL = {
    "input_cmos":         ("gf180mcu_fd_io__in_c",   frozenset({"PU", "PD"})),
    "input_schmitt":      ("gf180mcu_fd_io__in_s",   frozenset({"PU", "PD"})),
    "bidirectional":      ("gf180mcu_fd_io__bi_t",
                           frozenset({"CS", "SL", "IE", "OE", "PU", "PD", "PDRV0", "PDRV1"})),
    "bidirectional_24ma": ("gf180mcu_fd_io__bi_24t",
                           frozenset({"CS", "SL", "IE", "OE", "PU", "PD"})),
    "power":              ("gf180mcu_fd_io__dvdd",   frozenset()),
    "ground":             ("gf180mcu_fd_io__dvss",   frozenset()),
}

# Full set of cell_terminal names A40_ACV_interface.yaml lists per cell
# (control pins + A = driver data, + Y = receiver return).
CELL_TERMS = {
    "gf180mcu_fd_io__in_c":   frozenset({"PU", "PD", "Y"}),
    "gf180mcu_fd_io__in_s":   frozenset({"PU", "PD", "Y"}),
    "gf180mcu_fd_io__bi_t":   frozenset({"CS", "SL", "IE", "OE", "PU", "PD",
                                         "A", "PDRV0", "PDRV1", "Y"}),
    "gf180mcu_fd_io__bi_24t": frozenset({"CS", "SL", "IE", "OE", "PU", "PD", "A", "Y"}),
    "gf180mcu_fd_io__dvdd":   frozenset({"DVDD"}),
    "gf180mcu_fd_io__dvss":   frozenset({"DVSS"}),
}

# Output-only bidirectional pads: the core drives them and never reads the pin,
# so the pad receiver (IE) must be tied off.  ARRAY_ACQ_N is excluded (it does
# sense the shared peer wire, IE=1); PSRAM_SIO_n are excluded (true bidir,
# dynamic IE).
OUTPUT_ONLY_BIDIR = {
    "PSRAM_CE_N", "REMOD_A_I", "REMOD_A_Q", "SPI_MISO", "IRQ_OUT", "DBG0", "PSRAM_SCK",
}

EXPECTED_PIN_COUNT = 27


# --------------------------------------------------------------------------- #
# parsing helpers
# --------------------------------------------------------------------------- #
def _ctrl_outputs(portlist):
    outs = re.findall(r"output\s+wire\s+(?:\[[^\]]+\]\s+)?(\w+)", portlist)
    return [p for p in outs if p.endswith(CTRL_SUFFIXES)]


def _assign_map(body):
    return dict(re.findall(r"assign\s+(\w+)\s*=\s*([^;]+);", body))


def _const(assigns, port):
    """Return 0/1 for a `1'b0`/`1'b1` tie-off, else None (dynamic / absent)."""
    v = assigns.get(port, "").strip()
    return int(v[3]) if re.fullmatch(r"1'b[01]", v) else None


@pytest.fixture(scope="module")
def pad_map():
    return yaml.safe_load(PAD_MAP.read_text())


@pytest.fixture(scope="module")
def interface():
    return yaml.safe_load(INTERFACE.read_text())


@pytest.fixture(scope="module")
def top():
    src = TOP.read_text()
    m = re.search(r"module trouper_top \((.*?)\n\);", src, re.S)
    assert m, "could not locate the trouper_top port list"
    portlist, body = m.group(1), src[m.end():]
    inputs = set(re.findall(r"input\s+wire\s+(?:\[[^\]]+\]\s+)?(\w+)", portlist))
    outputs = set(re.findall(r"output\s+wire\s+(?:\[[^\]]+\]\s+)?(\w+)", portlist))
    return {
        "inputs": inputs,
        "outputs": outputs,
        "ctrl_outputs": set(_ctrl_outputs(portlist)),
        "assigns": _assign_map(body),
    }


@pytest.fixture(scope="module")
def padring():
    text = PADRING_V.read_text()
    inst_re = re.compile(r"gf180mcu_fd_io__(\w+)\s+(\w+)\s*\(([^;]*)\)\s*;")
    insts = {}
    for cell_short, name, conns in inst_re.findall(text):
        ports = dict(re.findall(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", conns))
        insts[name] = {"cell": f"gf180mcu_fd_io__{cell_short}", "ports": ports}
    port_decls = {
        name: direction
        for direction, name in re.findall(r"^\s*(input|output|inout)\s+(\w+)\s*;", text, re.M)
    }
    return {"insts": insts, "port_decls": port_decls, "text": text}


# --------------------------------------------------------------------------- #
# (d) pad count / no stale 28-slot or DBG1 drift
# --------------------------------------------------------------------------- #
def test_pad_map_is_27_pins(pad_map):
    assert pad_map["pin_count"] == EXPECTED_PIN_COUNT
    assert pad_map["user_slot_count"] == EXPECTED_PIN_COUNT
    assert len(pad_map["pads"]) == EXPECTED_PIN_COUNT
    idx = sorted(p["pin_index"] for p in pad_map["pads"])
    assert idx == list(range(EXPECTED_PIN_COUNT)), f"pin_index not 0..26: {idx}"


def test_interface_is_27_user_pins(interface):
    assert interface["participant_pin_count"] == EXPECTED_PIN_COUNT
    assert len({p["user_pin_name"] for p in interface["pins"]}) == EXPECTED_PIN_COUNT


def test_no_stale_28slot_or_dbg1(pad_map, interface):
    names = {p["pin_name"] for p in pad_map["pads"]}
    names |= {p["user_pin_name"] for p in interface["pins"]}
    assert "DBG1" not in names, (
        "DBG1 reappeared as a pad -- it was merged onto the IRQ_OUT pad "
        "(planning/two-pin-digital-debug-plan.md, 2026-09-03)"
    )
    slots = {p["slot"] for p in pad_map["pads"]}
    # Trouper owns W12..W22 and N01..N16 only -- an N17+ slot here means a
    # 28th pad crept back in.
    bad = {s for s in slots if re.fullmatch(r"N(1[7-9]|2[0-9])", s)}
    assert not bad, f"pad_map has out-of-range Trouper slots (stale 28-pad?): {bad}"


def test_info_yaml_is_27_pins():
    info = INFO.read_text()
    pins = re.findall(r"^\s*-\s*name:\s*(\S+)", info, re.M)
    assert len(pins) == EXPECTED_PIN_COUNT, f"info.yaml has {len(pins)} pins: {pins}"
    assert "DBG1" not in pins


# --------------------------------------------------------------------------- #
# (b) io_type -> cell -> legal terminal set; and the netlist agrees
# --------------------------------------------------------------------------- #
def test_pad_map_io_type_matches_cell(pad_map):
    for pad in pad_map["pads"]:
        io_type, cell = pad["io_type"], pad["cell"]
        assert io_type in IO_TYPE_CELL, f"{pad['pin_name']}: unknown io_type {io_type}"
        assert cell == IO_TYPE_CELL[io_type][0], (
            f"{pad['pin_name']} (slot {pad['slot']}): io_type {io_type} wants "
            f"{IO_TYPE_CELL[io_type][0]}, pad_map says {cell}"
        )


def test_padring_netlist_instantiates_the_mapped_cell(pad_map, padring):
    for pad in pad_map["pads"]:
        slot, cell = pad["slot"], pad["cell"]
        assert slot in padring["insts"], f"slot {slot} has no cell instance in A40_ACV_padring.v"
        got = padring["insts"][slot]["cell"]
        assert got == cell, (
            f"slot {slot} ({pad['pin_name']}): pad_map cell {cell}, netlist instantiates {got}"
        )


def test_interface_terminal_set_matches_cell(interface):
    by_pad = {}
    for p in interface["pins"]:
        by_pad.setdefault((p["user_pin_name"], p["cell"]), set()).add(p["cell_terminal"])
    for (pin, cell), terms in by_pad.items():
        assert cell in CELL_TERMS, f"{pin}: unknown cell {cell}"
        assert terms == CELL_TERMS[cell], (
            f"{pin} ({cell}): interface terminals {sorted(terms)} != "
            f"expected {sorted(CELL_TERMS[cell])}"
        )


def test_no_pdrv_on_non_bi_t_pads(pad_map, top):
    """PDRV select exists only on the plain bi_t cell."""
    for pad in pad_map["pads"]:
        if pad["cell"] == "gf180mcu_fd_io__bi_t":
            continue
        for suf in ("_PDRV0", "_PDRV1"):
            port = f"{pad['pin_name']}{suf}"
            assert port not in top["outputs"], (
                f"{port} exists but {pad['pin_name']} sits on {pad['cell']} "
                f"(no drive-strength select)"
            )


def test_input_pads_expose_only_pu_pd(pad_map, top):
    """in_c / in_s pads: the core may drive PU and PD, nothing else."""
    for pad in pad_map["pads"]:
        if pad["cell"] not in ("gf180mcu_fd_io__in_c", "gf180mcu_fd_io__in_s"):
            continue
        for suf in ("_IE", "_OE", "_CS", "_SL", "_PDRV0", "_PDRV1"):
            port = f"{pad['pin_name']}{suf}"
            assert port not in top["outputs"], (
                f"{port} exists but {pad['pin_name']} is an input-only "
                f"{pad['cell']} (only PU/PD are wired)"
            )


# --------------------------------------------------------------------------- #
# (a) one-to-one, matching direction, between trouper_top and the contract
# --------------------------------------------------------------------------- #
def test_trouper_top_ports_match_interface_contract(interface, top):
    iface_out = {p["project_pin"] for p in interface["pins"] if p["direction"] == "OUTPUT"}
    iface_in = {p["project_pin"] for p in interface["pins"] if p["direction"] == "INPUT"}

    missing_out = iface_out - top["outputs"]
    assert not missing_out, (
        "A40_ACV_interface.yaml OUTPUT terminals with no matching trouper_top "
        f"output port: {sorted(missing_out)}"
    )
    orphan_out = top["outputs"] - iface_out
    assert not orphan_out, (
        "trouper_top output ports the padring contract does not consume "
        f"(would be unbonded): {sorted(orphan_out)}"
    )
    missing_in = iface_in - top["inputs"]
    assert not missing_in, (
        "A40_ACV_interface.yaml receiver (Y) terminals with no matching "
        f"trouper_top input port: {sorted(missing_in)}"
    )
    orphan_in = top["inputs"] - iface_in
    assert not orphan_in, (
        f"trouper_top input ports not fed by any padring terminal: {sorted(orphan_in)}"
    )


def test_padring_module_breaks_out_every_contract_terminal(interface, padring):
    """Each interface terminal maps to a `<slot>_<TERM>` port + `.TERM(<slot>_<TERM>)`
    connection on the slot's cell instance in A40_ACV_padring.v."""
    for p in interface["pins"]:
        if p["use"] != "SIGNAL":
            continue
        slot, term = p["padring_instance"], p["cell_terminal"]
        inst = padring["insts"].get(slot)
        assert inst, f"{p['project_pin']}: slot {slot} not instantiated"
        assert term in inst["ports"], (
            f"{p['project_pin']}: cell instance {slot} has no .{term}() connection"
        )
        expect_net = f"{slot}_{term}"
        assert inst["ports"][term] == expect_net, (
            f"{p['project_pin']}: {slot} .{term}() connects '{inst['ports'][term]}', "
            f"expected '{expect_net}'"
        )
        decl = padring["port_decls"].get(expect_net)
        assert decl is not None, f"{expect_net} is not a port of A40_ACV_padring"
        want_dir = "output" if term == "Y" else "input"
        assert decl == want_dir, (
            f"{expect_net} declared '{decl}', expected '{want_dir}' "
            f"(term {term}, contract direction {p['direction']})"
        )


# --------------------------------------------------------------------------- #
# (c) the RTL tie-off values are electrically legal for the assigned cell
# --------------------------------------------------------------------------- #
def test_tieoff_values_are_legal_for_the_cell(pad_map, top):
    assigns = top["assigns"]
    bad = []
    for pad in pad_map["pads"]:
        name, cell = pad["pin_name"], pad["cell"]
        ie = _const(assigns, f"{name}_IE")
        oe = _const(assigns, f"{name}_OE")
        pu = _const(assigns, f"{name}_PU")
        pd = _const(assigns, f"{name}_PD")

        if cell in ("gf180mcu_fd_io__bi_t", "gf180mcu_fd_io__bi_24t"):
            if ie == 1 and oe == 1:
                bad.append(f"{name}: IE=OE=1 (uncharacterized for {cell})")
            if name in OUTPUT_ONLY_BIDIR and ie != 0:
                bad.append(f"{name}: output-only pad but IE={ie} (receiver must be off)")
        if pu == 1 and pd == 1:
            bad.append(f"{name}: PU=PD=1 (pull fight)")
        if cell in ("gf180mcu_fd_io__in_c", "gf180mcu_fd_io__in_s"):
            if pu not in (0, None) or pd not in (0, None):
                bad.append(f"{name}: input pad with PU={pu} PD={pd} (board supplies pulls)")

    assert not bad, "electrically-illegal pad tie-offs: " + "; ".join(bad)


# --------------------------------------------------------------------------- #
# (e) keep the sibling static test off the stale ~PSRAM_SIO_OE[n] expectation
# --------------------------------------------------------------------------- #
def test_psram_sio_ie_inverts_the_relaunched_oe(top):
    for n in range(4):
        got = top["assigns"].get(f"PSRAM_SIO_{n}_IE", "").strip()
        assert got == f"~psram_sio_oe_q[{n}]", (
            f"PSRAM_SIO_{n}_IE drives '{got}', expected '~psram_sio_oe_q[{n}]' "
            "(negedge-relaunched OE, Open Risk #69)"
        )


def test_sibling_ports_test_expects_the_same_token():
    src = PORTS_TEST.read_text()
    assert "~psram_sio_oe_q[" in src, (
        "test_pad_tieoff_ports.py no longer expects ~psram_sio_oe_q[n] for the SIO _IE lanes"
    )
    assert "~PSRAM_SIO_OE[" not in src, (
        "test_pad_tieoff_ports.py has drifted back to the stale ~PSRAM_SIO_OE[n] "
        "expectation (Open Risk #69: IE inverts the psram_sio_oe_q register, not the port)"
    )
