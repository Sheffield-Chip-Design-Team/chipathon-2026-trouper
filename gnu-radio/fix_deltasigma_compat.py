"""
Patch deltasigma 0.2.2 for compatibility with Python >= 3.9,
NumPy >= 1.24, SciPy >= 1.7, and matplotlib >= 3.0.

Run once after installing requirements:
    pip install -r requirements.txt
    python fix_deltasigma_compat.py
"""

import importlib.util
import os
import re
import sys


def find_package_dir():
    spec = importlib.util.find_spec("deltasigma")
    if spec is None:
        sys.exit("deltasigma is not installed. Run: pip install -r requirements.txt")
    return os.path.dirname(spec.origin)


def patch(path, replacements):
    """Apply a list of (old, new) string replacements to a file, idempotently."""
    with open(path) as f:
        src = f.read()
    changed = False
    for old, new in replacements:
        # Skip if old is absent (already replaced) or new is already present
        if old not in src or new in src:
            continue
        src = src.replace(old, new)
        changed = True
    if changed:
        with open(path, "w") as f:
            f.write(src)
        print(f"  patched {os.path.basename(path)}")
    else:
        print(f"  ok      {os.path.basename(path)}")


def remove_hold_lines(path):
    """Drop plt.hold() / plt.ishold() calls and orphaned empty if-blocks."""
    with open(path) as f:
        src = f.read()

    if "plt.hold(" not in src and "plt.ishold()" not in src:
        print(f"  ok      {os.path.basename(path)}")
        return

    lines = src.split("\n")
    out = []
    for line in lines:
        stripped = line.lstrip()
        if "plt.ishold()" in line and not stripped.startswith("plt.ishold()"):
            line = re.sub(r"plt\.ishold\(\)", "True", line)
        if stripped.startswith("plt.hold(") or stripped == "plt.ishold()":
            continue
        out.append(line)

    src2 = "\n".join(out)
    # Remove orphaned `if not hold_status:` blocks left empty after dropping hold()
    src2 = re.sub(r"\n(\s*)if not hold_status:\s*\n", "\n", src2)

    with open(path, "w") as f:
        f.write(src2)
    print(f"  patched {os.path.basename(path)}")


def main():
    base = find_package_dir()
    print(f"Patching deltasigma at: {base}\n")

    # 1. np.float removed in NumPy 1.24
    patch(os.path.join(base, "_constants.py"), [
        ("np.finfo(np.float).eps", "np.finfo(float).eps"),
    ])

    # 2. fractions.gcd removed in Python 3.9; collections.Iterable in 3.10
    patch(os.path.join(base, "_utils.py"), [
        ("import collections\n", "import collections\nimport collections.abc\nimport math\n"),
        ("import fractions\n", "import fractions\n"),  # keep fractions for Fraction
        ("gcd = fractions.gcd", "gcd = math.gcd"),
        ("collections.Iterable", "collections.abc.Iterable"),
    ])

    # 3. diagonal_indices crashes on empty off-diagonal for 1st-order systems
    patch(os.path.join(base, "_utils.py"), [
        (
            "    di, dj = np.diag_indices_from(a[:min(a.shape), :min(a.shape)])\n"
            "    if offset > 0:\n"
            "        di, dj = zip(*[(i, j)\n"
            "                     for i, j in zip(di, dj + offset) if 0 <= j < a.shape[1]])\n"
            "    elif offset == 0:\n"
            "        pass\n"
            "    else:\n"
            "        di, dj = zip(*[(i, j)\n"
            "                     for i, j in zip(di - offset, dj) if 0 <= i < a.shape[0]])\n"
            "    return di, dj",
            "    di, dj = np.diag_indices_from(a[:min(a.shape), :min(a.shape)])\n"
            "    empty = (np.array([], dtype=int), np.array([], dtype=int))\n"
            "    if offset > 0:\n"
            "        result = [(i, j) for i, j in zip(di, dj + offset) if 0 <= j < a.shape[1]]\n"
            "        if not result:\n"
            "            return empty\n"
            "        di, dj = zip(*result)\n"
            "    elif offset == 0:\n"
            "        pass\n"
            "    else:\n"
            "        result = [(i, j) for i, j in zip(di - offset, dj) if 0 <= i < a.shape[0]]\n"
            "        if not result:\n"
            "            return empty\n"
            "        di, dj = zip(*result)\n"
            "    return di, dj",
        ),
    ])

    # 4. stuffABCD CIFF form crashes for 1st-order (no resonators, empty g)
    patch(os.path.join(base, "_stuffABCD.py"), [
        (
            "        subdiag = diagonal_indices(ABCD[:order, :order], -1)\n"
            "        ABCD[subdiag] = c[0, 1:]\n"
            "        # C = (a_1 a_2... a_n)\n"
            "        ABCD[order, :order] = a[0, :order]\n"
            "        # supdiag = diagonal[odd + 1:order:2] - 1\n"
            "        supdiag = [i[odd:order+odd:2] for i in  \n"
            "                   diagonal_indices(ABCD[:order, :order], +1)]\n"
            "        ABCD[supdiag] = -g.reshape((-1,))",
            "        subdiag = diagonal_indices(ABCD[:order, :order], -1)\n"
            "        if np.asarray(subdiag[0]).size > 0:\n"
            "            ABCD[subdiag] = c[0, 1:]\n"
            "        # C = (a_1 a_2... a_n)\n"
            "        ABCD[order, :order] = a[0, :order]\n"
            "        # supdiag = diagonal[odd + 1:order:2] - 1\n"
            "        if g.size > 0:\n"
            "            supdiag = [i[odd:order+odd:2] for i in\n"
            "                       diagonal_indices(ABCD[:order, :order], +1)]\n"
            "            ABCD[supdiag] = -g.reshape((-1,))",
        ),
    ])

    # 5. numpy.distutils removed in NumPy 2.0
    patch(os.path.join(base, "_config.py"), [
        (
            "from numpy.distutils.system_info import get_info",
            "def get_info(name):\n    return {}",
        ),
    ])

    # 6. np.Inf / np.NaN removed in NumPy 2.0
    for fn in ("_dbp.py", "_dbm.py", "_predictSNR.py", "_calculateSNR.py", "_evalTFP.py"):
        patch(os.path.join(base, fn), [
            ("np.Inf", "np.inf"),
            ("np.NaN", "np.nan"),
            ("np.NAN", "np.nan"),
        ])

    # 7b. predictSNR powerGain: Nimp passed as float to np.linspace count (NumPy 2.0)
    patch(os.path.join(base, "_predictSNR.py"), [
        (
            "    unstable = False\n"
            "    _, (imp, ) = dimpulse((num, den, 1), t=np.linspace(0, Nimp, Nimp))\n"
            "    if np.sum(abs(imp[Nimp - 11:Nimp])) < 1e-08 and Nimp > 50:\n"
            "        Nimp = np.round(Nimp/1.3)",
            "    unstable = False\n"
            "    Nimp = int(Nimp)\n"
            "    _, (imp, ) = dimpulse((num, den, 1), t=np.linspace(0, Nimp, Nimp))\n"
            "    if np.sum(abs(imp[Nimp - 11:Nimp])) < 1e-08 and Nimp > 50:\n"
            "        Nimp = int(np.round(Nimp/1.3))",
        ),
    ])

    # 8b. stuffABCD: list-based index used as row selector instead of element pairs (NumPy 2.0)
    patch(os.path.join(base, "_stuffABCD.py"), [
        # CRFB supdiag
        (
            "        supdiag = [i[odd:order:2] for i in diagonal_indices(ABCD[:order, :order], +1)]",
            "        supdiag = tuple(i[odd:order:2] for i in diagonal_indices(ABCD[:order, :order], +1))",
        ),
        # CRFB subdiag
        (
            "        subdiag = [i[even:order:2] for i in diagonal_indices(ABCD, -1)]",
            "        subdiag = tuple(i[even:order:2] for i in diagonal_indices(ABCD, -1))",
        ),
        # CRFF subdiag
        (
            "        subdiag = [i[:order - 1:2] for i in diagonal_indices(ABCD, -1)]",
            "        subdiag = tuple(i[:order - 1:2] for i in diagonal_indices(ABCD, -1))",
        ),
        # CIFB supdiag
        (
            "        supdiag = [i[odd:order+odd:2] for i in diagonal_indices(ABCD[:order, :order], +1)]\n"
            "        ABCD[supdiag] = -g.reshape((-1,))\n"
            "    elif form == 'CIFF':",
            "        supdiag = tuple(i[odd:order+odd:2] for i in diagonal_indices(ABCD[:order, :order], +1))\n"
            "        ABCD[supdiag] = -g.reshape((-1,))\n"
            "    elif form == 'CIFF':",
        ),
    ])

    # 8c. peakSNR: truth value of empty array ambiguous (NumPy 2.0)
    patch(os.path.join(base, "_peakSNR.py"), [
        ("    if j:\n", "    if j.size > 0:\n"),
    ])

    # 8d. simulateSNR: float slice index (NumPy 2.0)
    patch(os.path.join(base, "_simulateSNR.py"), [
        (
            "    soft_start = 0.5*(1 - np.cos(2*np.pi/Ntransient * \\\n"
            "                                 np.arange(Ntransient/2)))\n"
            "    if not quadrature:\n"
            "        tone = M*np.sin(2*np.pi*F/N*np.arange(N + Ntransient))\n"
            "        tone[:Ntransient/2] = tone[:Ntransient/2] * soft_start\n"
            "    else:\n"
            "        tone = M*np.exp(2j*np.pi*F/N * np.arange(N + Ntransient))\n"
            "        tone[:Ntransient/2] = tone[:Ntransient/2] * soft_start",
            "    soft_start = 0.5*(1 - np.cos(2*np.pi/Ntransient * \\\n"
            "                                 np.arange(Ntransient//2)))\n"
            "    if not quadrature:\n"
            "        tone = M*np.sin(2*np.pi*F/N*np.arange(N + Ntransient))\n"
            "        tone[:Ntransient//2] = tone[:Ntransient//2] * soft_start\n"
            "    else:\n"
            "        tone = M*np.exp(2j*np.pi*F/N * np.arange(N + Ntransient))\n"
            "        tone[:Ntransient//2] = tone[:Ntransient//2] * soft_start",
        ),
    ])

    # 7. scipy.signal.step2 renamed to step in SciPy 1.7
    patch(os.path.join(base, "_pulse.py"), [
        ("from scipy.signal import lti, step2", "from scipy.signal import lti, step as step2"),
        ("import collections\n", "import collections\nimport collections.abc\n"),
        ("collections.Iterable", "collections.abc.Iterable"),
    ])

    # 8. collections.Iterable in remaining files
    for fn in ("_simulateDSM_python.py", "_axisLabels.py", "_simulateSNR.py"):
        patch(os.path.join(base, fn), [
            ("import collections\n", "import collections\nimport collections.abc\n"),
            ("collections.Iterable", "collections.abc.Iterable"),
        ])

    # 9. plt.hold() / plt.ishold() removed in matplotlib 3.0
    print()
    for fn in (
        "_simulateDSM.py", "_circ_smooth.py", "_simulateSNR.py",
        "_logsmooth.py", "_simulateDSM_python.py", "_plotSpectrum.py",
        "_plotPZ.py", "_peakSNR.py", "_synthesizeQNTF.py",
        "_DocumentNTF.py", "_PlotExampleSpectrum.py", "_synthesizeChebyshevNTF.py",
    ):
        remove_hold_lines(os.path.join(base, fn))

    print("\nDone. You can now run calc_sigma_delta_coefficients.py")


if __name__ == "__main__":
    main()
