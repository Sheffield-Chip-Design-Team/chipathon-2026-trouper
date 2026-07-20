"""Verify the pinned GNU Radio runtime used by the Trouper flowgraphs.

Run from the repository root:
    python3 sim/gnuradio/check_environment.py
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


LOCK = Path(__file__).with_name("versions.lock")


def read_lock() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in LOCK.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            values[key] = value
    return values


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    lock = read_lock()
    from gnuradio import gr  # Imported here so a missing runtime is actionable.
    import gnuradio.lora_sdr as lora_sdr

    failures = []
    if gr.version() != lock["gnuradio_apt"].split("-", 1)[0]:
        failures.append(f"GNU Radio is {gr.version()}, expected {lock['gnuradio_apt']}")

    module_dir = Path(lora_sdr.__file__).parent
    artifacts = {
        "lora_sdr_python.cpython-312-x86_64-linux-gnu.so": lock["gr_lora_sdr_python_sha256"],
        "lora_sdr_lora_rx.py": lock["gr_lora_sdr_rx_wrapper_sha256"],
        "lora_sdr_lora_tx.py": lock["gr_lora_sdr_tx_wrapper_sha256"],
    }
    for name, expected in artifacts.items():
        path = module_dir / name
        actual = sha256(path) if path.is_file() else "missing"
        if actual != expected:
            failures.append(f"{name}: {actual}, expected {expected}")

    if failures:
        print("GNU Radio environment does not match sim/gnuradio/versions.lock:")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1
    print(f"GNU Radio environment pinned and verified: {gr.version()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
