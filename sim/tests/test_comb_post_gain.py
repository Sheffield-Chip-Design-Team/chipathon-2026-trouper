import numpy as np

from sim.models.receiver import nonfft_combine_rtl_int8, choose_comb_post_gain


def test_post_gain_left_shift_until_saturation():
    rx = np.array([[10 + 0j]], dtype=complex)
    w = np.array([1 / 32768 + 0j], dtype=complex)  # Q1.15 integer weight = 1

    assert nonfft_combine_rtl_int8(rx, w, post_gain_shift=0)[0] == 5 + 0j
    assert nonfft_combine_rtl_int8(rx, w, post_gain_shift=3)[0] == 40 + 0j
    assert nonfft_combine_rtl_int8(rx, w, post_gain_shift=7)[0] == 127 + 0j


def test_post_gain_applies_to_i_and_q():
    rx = np.array([[10 + 12j]], dtype=complex)
    w = np.array([1 / 32768 + 0j], dtype=complex)
    y = nonfft_combine_rtl_int8(rx, w, post_gain_shift=2)
    assert y[0] == 20 + 24j


def test_post_gain_preserves_bypass():
    rx = np.array([
        [1 + 2j],
        [30 - 40j],
    ], dtype=complex)
    w = np.array([0 + 0j, 0 + 0j], dtype=complex)
    y = nonfft_combine_rtl_int8(rx, w, post_gain_shift=7, mode="bypass", bypass_ant=1)
    assert y[0] == 30 - 40j


def test_choose_comb_post_gain_targets_headroom():
    y = np.array([5 + 3j, -8 + 4j], dtype=complex)
    assert choose_comb_post_gain(y, target_peak=90) == 3  # 8 << 3 = 64, 8 << 4 = 128


def test_choose_comb_post_gain_backs_off_near_saturation():
    y = np.array([121 + 0j, -4 + 0j], dtype=complex)
    assert choose_comb_post_gain(y, target_peak=90) == 0
