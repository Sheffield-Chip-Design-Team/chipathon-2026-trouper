"""Self-checks for the SX1302-input comparison harness
(sim/sims/remod_sx1302_compare.py): its LoRa modem must be error-free on a
clean signal through every receive path, or its SER curves mean nothing
(job 5824 ran with an inclusive-cumsum chirp that flipped half of every
BW250 symbol by pi)."""
import numpy as np
import pytest

import sim.sims.remod_sx1302_compare as c


@pytest.fixture(scope="module", autouse=True)
def _delays():
    c.calibrate_delays()


@pytest.mark.parametrize("bw", [125e3, 250e3])
@pytest.mark.parametrize("key", ["ideal", "hb/ciff3", "cic/legacy_ciff4", "hb/sx1257_ref"])
def test_clean_lora_decodes(bw, key):
    sf = 7
    syms = np.random.default_rng(3).integers(0, 1 << sf, 8)
    bb = np.r_[np.zeros(c.GUARD), c.lora_packet(syms, sf, bw), np.zeros(c.GUARD)] * 10 ** (-14 / 20)
    if key == "ideal":
        y = c.channel_filter(bb, bw)
    else:
        p, s = key.split("/")
        y = c.channel_filter(c.proxy(p, c.make_stream(s, bb)), bw)
    dec = c.lora_demod(y, len(syms), sf, bw, c.GUARD + c._DELAY[(key, bw)])
    assert np.array_equal(dec, syms)
