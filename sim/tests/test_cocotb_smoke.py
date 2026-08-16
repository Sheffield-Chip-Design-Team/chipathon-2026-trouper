"""
test_cocotb_smoke.py -- static smoke check over the cocotb suites.

Runs with the existing `pytest sim/tests/` entry point, needs no simulator and
no cocotb install (the repo's own cocotb/ directory shadows the real package
locally anyway), and takes well under a second.

Why this exists: on 2026-08-16 cocotb/tests/test_capture_playback.py carried

    from test_trouper_top import (, release_rx_hold
        CLK_NS, spi_read, spi_write, spi_burst_write,
    )

-- a SyntaxError, so the canonical full-chain suite could not even be imported.
It did not show up as a failing test; it showed up as no test at all, and went
unnoticed because nothing executed that suite. Four more suites were in the same
state (present, referenced by the docs, run by nothing). The checks below are
the cheap backstop for that class of defect: they fail loudly at `pytest` time
instead of silently at "nobody ran it" time.

Deliberately static rather than import-based. Importing the modules for real
would also catch these, but only inside the container, which is exactly where
the feedback loop is slowest. AST parsing resolves cross-module names without
executing anything.

Covers:
  1. every cocotb/tests/*.py parses (SyntaxError)
  2. every `from <sibling test module> import name` resolves to a name that
     module actually defines (ImportError, e.g. a helper that was renamed or
     never added)
  3. every cocotb/<suite>/Makefile names a COCOTB_TEST_MODULES that exists
  4. every VERILOG_SOURCES entry in those Makefiles points at a real file
"""

import ast
import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
TESTS_DIR = REPO / "cocotb" / "tests"
COCOTB_DIR = REPO / "cocotb"

TEST_MODULES = sorted(TESTS_DIR.glob("*.py"))
SUITE_MAKEFILES = sorted(COCOTB_DIR.glob("*/Makefile"))


def _parse(path):
    """Parse a module, surfacing SyntaxError as a readable pytest failure."""
    src = path.read_text()
    try:
        return ast.parse(src, filename=str(path))
    except SyntaxError as e:
        pytest.fail(
            f"{path.relative_to(REPO)}:{e.lineno}: {e.msg}\n"
            f"    {(e.text or '').rstrip()}\n"
            f"This module cannot be imported, so its suite runs zero tests."
        )


def _toplevel_names(tree):
    """Names a module binds at top level: defs, classes, assignments, imports."""
    names = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, ast.Assign):
            for tgt in node.targets:
                if isinstance(tgt, ast.Name):
                    names.add(tgt.id)
                elif isinstance(tgt, (ast.Tuple, ast.List)):
                    names.update(el.id for el in tgt.elts if isinstance(el, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for alias in node.names:
                names.add(alias.asname or alias.name.split(".")[0])
    return names


@pytest.mark.parametrize("path", TEST_MODULES, ids=lambda p: p.name)
def test_module_parses(path):
    """Every cocotb test module must be syntactically valid."""
    _parse(path)


@pytest.mark.parametrize("path", TEST_MODULES, ids=lambda p: p.name)
def test_sibling_imports_resolve(path):
    """`from <sibling> import name` must name something the sibling defines.

    Catches the renamed/never-added helper case -- e.g. importing
    release_rx_hold from a test_trouper_top that does not define it -- which is
    an ImportError at run time and therefore a suite that runs zero tests.
    """
    tree = _parse(path)
    problems = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.ImportFrom) or node.module is None:
            continue
        sibling = TESTS_DIR / f"{node.module}.py"
        if not sibling.exists():
            continue                      # third-party or stdlib -- not ours
        available = _toplevel_names(_parse(sibling))
        for alias in node.names:
            if alias.name == "*":
                continue
            if alias.name not in available:
                problems.append(
                    f"  line {node.lineno}: `from {node.module} import "
                    f"{alias.name}` -- {node.module}.py defines no such name"
                )
    assert not problems, (
        f"{path.relative_to(REPO)} has unresolvable sibling imports:\n"
        + "\n".join(problems)
    )


def _makefile_var(text, name):
    """Read a simple `NAME = value` assignment (first match, one line)."""
    m = re.search(rf"^{name}\s*[:?]?=\s*(.+)$", text, re.MULTILINE)
    return m.group(1).strip() if m else None


@pytest.mark.parametrize("mk", SUITE_MAKEFILES, ids=lambda p: p.parent.name)
def test_suite_names_a_real_module(mk):
    """Each suite's COCOTB_TEST_MODULES must exist in cocotb/tests/.

    A Makefile pointing at a renamed or missing module produces a suite that
    collects nothing -- green by vacuity.
    """
    modules = _makefile_var(mk.read_text(), "COCOTB_TEST_MODULES")
    assert modules, f"{mk.relative_to(REPO)}: no COCOTB_TEST_MODULES set"
    # cocotb accepts both comma- and whitespace-separated module lists, and
    # this repo uses both (cocotb/trouper_top and cocotb/reg_bank are comma-
    # separated), so split on either.
    names = [m for m in re.split(r"[,\s]+", modules) if m]
    missing = [m for m in names if not (TESTS_DIR / f"{m}.py").exists()]
    assert not missing, (
        f"{mk.relative_to(REPO)}: COCOTB_TEST_MODULES names "
        f"{missing}, absent from cocotb/tests/"
    )


@pytest.mark.parametrize("mk", SUITE_MAKEFILES, ids=lambda p: p.parent.name)
def test_verilog_sources_exist(mk):
    """Each VERILOG_SOURCES entry must resolve to a real file.

    DESIGN_ROOT is a container path (/foss/designs/...), so resolve the three
    make variables against the repo instead.
    """
    text = mk.read_text()
    m = re.search(r"^VERILOG_SOURCES\s*[:?]?=\s*((?:.*\\\n)*.*)$", text, re.MULTILINE)
    assert m, f"{mk.relative_to(REPO)}: no VERILOG_SOURCES block"

    subs = {"$(SRC)": "src", "$(HDL)": "cocotb/hdl", "$(TESTS)": "cocotb/tests"}
    missing = []
    for raw in m.group(1).replace("\\\n", " ").split():
        entry = raw.strip()
        if not entry:
            continue
        for var, rel in subs.items():
            entry = entry.replace(var, rel)
        if "$(" in entry:
            continue                      # unresolved var -- out of scope here
        if not (REPO / entry).exists():
            missing.append(entry)
    assert not missing, (
        f"{mk.relative_to(REPO)}: VERILOG_SOURCES references missing files: {missing}"
    )
