"""AGC board-controller model: deep fade followed by beacon return."""

import numpy as np
import pytest

from sim.models.agc import PacketAgc, SX1257Gain, remod_ingress


REMOD_SAFE_COMPONENT = 90  # -3 dBFS guard: 0.707 * signed int8 full scale


def test_gain_is_not_changed_during_the_packet():
    agc = PacketAgc(SX1257Gain())
    packet = np.full(64, 127 + 0j)

    with pytest.raises(ValueError, match="packet_active"):
        agc.update_after_packet(packet, packet_active=True)

    assert agc.gain == SX1257Gain(lna=3, bb=7)


def test_deep_fade_then_beacon_return_recovers_at_next_packet_boundary():
    """A 30 dB obstruction makes AGC raise BB gain; its removal clips once.

    The clipped packet is not repairable.  The saturation guard must reduce
    gain only after that packet, leaving the following packet below the remod
    stability limit.  The values are at maximum SX1257 gain; the model's
    absolute thresholds remain silicon-calibration parameters.
    """
    agc = PacketAgc(SX1257Gain(lna=3, bb=7))
    beacon_at_max_gain = np.full(256, 2000 + 0j)
    obstructed = beacon_at_max_gain / (10 ** (30 / 20))

    # Three weak packets make the controller raise only BB gain: no mid-packet
    # changes, and no hidden analogue gain path inside Trouper.
    for _ in range(3):
        weak_packet = agc.frontend_samples(obstructed)
        assert agc.component_peak(weak_packet) < REMOD_SAFE_COMPONENT
        assert agc.update_after_packet(weak_packet, packet_active=False)
    assert agc.gain == SX1257Gain(lna=3, bb=10)

    # Obstruction clears: the first returning packet clips at the frontend.
    # This establishes the fault case AGC cannot correct in-flight.
    hot_packet = agc.frontend_samples(beacon_at_max_gain)
    assert agc.component_peak(hot_packet) == 127

    # MRC has the reset REMOD_BACKOFF_SHIFT=1 protection, so its ingress is
    # below -3 dBFS even for this clipped packet.
    assert PacketAgc.component_peak(remod_ingress(hot_packet, use_mrc=True)) <= REMOD_SAFE_COMPONENT

    # The controller's saturation action is deferred until packet completion.
    assert agc.update_after_packet(hot_packet, packet_active=False)
    assert agc.gain == SX1257Gain(lna=4, bb=7)

    recovered_packet = agc.frontend_samples(beacon_at_max_gain)
    assert PacketAgc.component_peak(recovered_packet) <= REMOD_SAFE_COMPONENT
    assert PacketAgc.component_peak(remod_ingress(recovered_packet, use_mrc=True)) <= REMOD_SAFE_COMPONENT


def test_deep_fade_return_exposes_unprotected_bypass_remod_input():
    """Current RTL has no bypass backoff, so a clipped return is unsafe.

    This is an intentional failing-condition assertion, not a waiver: it pins
    the current architecture's vulnerability for the follow-on RTL mitigation.
    """
    agc = PacketAgc(SX1257Gain(lna=3, bb=10))
    hot_packet = agc.frontend_samples(np.full(256, 2000 + 0j))

    assert PacketAgc.component_peak(hot_packet) == 127
    assert PacketAgc.component_peak(remod_ingress(hot_packet, use_mrc=False)) > REMOD_SAFE_COMPONENT
