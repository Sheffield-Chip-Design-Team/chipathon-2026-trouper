"""Cycle-accurate reference model for ``packet_ctrl_fsm.v``.

The model deliberately follows Verilog nonblocking-assignment semantics.  Decisions
within a clock edge use the old state and old ``W_commit_pending`` value; writes made
by a higher-priority state branch override the default/decrement assignments made
earlier in the RTL always block.

It models the complete FSM so the remaining rows in the block verification plan can
reuse it.  The first users are rows #1 and #2: reset/IDLE behavior and the
IDLE -> ACQ_SETUP -> PREAMBLE_ACQ sequence.
"""

from dataclasses import dataclass


ST_IDLE = 0
ST_PREAMBLE_ACQ = 1
ST_W_PENDING = 2
ST_PAYLOAD_ACTIVE = 3
ST_ACQ_SETUP = 4

MASK20 = (1 << 20) - 1
MASK23 = (1 << 23) - 1
MASK25 = (1 << 25) - 1
MASK32 = (1 << 32) - 1


@dataclass
class PacketCtrlFsmModel:
    state: int = ST_IDLE
    sc_lock_prev: int = 0
    lat_timing_ref: int = 0
    acq_cnt: int = 0
    wpend_cnt: int = 0
    pkt_cnt: int = 0
    M_val: int = 256
    W_commit_pending: int = 0
    W_valid: int = 0
    W_valid_set: int = 0
    W_missed_packet: int = 0
    W_missed_q: int = 0
    packet_phase: int = 0
    packet_active: int = 0
    packet_active_ps: int = 0
    active_mode: int = 0
    active_antenna_en: int = 1

    def reset(self) -> None:
        """Apply the RTL's asynchronous active-low reset values."""
        fresh = type(self)()
        self.__dict__.update(fresh.__dict__)

    @staticmethod
    def _clamped_load(span: int, elapsed: int, iq_tick: int, width: int) -> int:
        """Reproduce the RTL's 25-bit subtract and bit-24 underflow clamp."""
        rem = (span + 1 - elapsed - iq_tick) & MASK25
        if rem & (1 << 24):
            return 0
        return rem & ((1 << width) - 1)

    def step(self, inputs: dict[str, int]) -> None:
        """Advance the model through one positive clock edge."""
        if not inputs["rst_n"]:
            self.reset()
            return

        # All branch decisions below see these pre-edge values.
        old_state = self.state
        old_sc_lock_prev = self.sc_lock_prev
        old_pending = self.W_commit_pending
        old_w_valid = self.W_valid
        old_acq_cnt = self.acq_cnt
        old_wpend_cnt = self.wpend_cnt
        old_pkt_cnt = self.pkt_cnt
        old_m = self.M_val

        # Separate M_val always block: its new value is not visible to the main
        # sequential block until after this edge.
        next_m = (1 << (inputs["sf"] + inputs["sample_shift"])) & 0x7FFF

        self.sc_lock_prev = inputs["sc_lock"]
        self.W_valid_set = 0
        self.W_missed_packet = 0

        if inputs["W_commit"]:
            self.W_commit_pending = 1

        armed = old_state in (ST_PREAMBLE_ACQ, ST_W_PENDING, ST_PAYLOAD_ACTIVE)
        if armed and inputs["iq_tick"]:
            if old_acq_cnt:
                self.acq_cnt = (old_acq_cnt - 1) & MASK20
            if old_wpend_cnt:
                self.wpend_cnt = (old_wpend_cnt - 1) & MASK20
            if old_pkt_cnt:
                self.pkt_cnt = (old_pkt_cnt - 1) & MASK23

        if old_state == ST_IDLE:
            self.packet_active = 0
            self.packet_active_ps = 0
            self.packet_phase = 0

            if old_pending:
                self.W_valid = 1
                self.W_valid_set = 1
                self.W_commit_pending = 0

            lock_edge = bool(inputs["sc_lock"] and not old_sc_lock_prev)
            if lock_edge:
                self.W_missed_q = 0
                self.lat_timing_ref = inputs["timing_ref"] & MASK32
                self.active_mode = inputs["mode_shadow"] & 0x3
                self.active_antenna_en = inputs["antenna_en_shadow"] & 0xF
                self.packet_active = 1
                self.packet_active_ps = 1
                self.packet_phase = 1
                self.state = ST_ACQ_SETUP

        elif old_state == ST_ACQ_SETUP:
            self.packet_phase = 1

            shift = inputs["sf"] + inputs["sample_shift"]
            tacc_eff = inputs["tacc_window_syms"] or 1
            tacc_span = tacc_eff << shift
            acq_span = tacc_span + 2 * old_m
            wpend_span = tacc_span + 5 * old_m
            pkt_span = (inputs["pkt_timeout_syms"] << shift) & ((1 << 22) - 1)
            elapsed = (
                (inputs["sample_count"] & MASK20)
                - (self.lat_timing_ref & MASK20)
            ) & MASK20

            self.acq_cnt = self._clamped_load(
                acq_span, elapsed, inputs["iq_tick"], 20
            )
            self.wpend_cnt = self._clamped_load(
                wpend_span, elapsed, inputs["iq_tick"], 20
            )
            self.pkt_cnt = self._clamped_load(
                pkt_span, elapsed, inputs["iq_tick"], 23
            )
            self.state = ST_PREAMBLE_ACQ

        elif old_state == ST_PREAMBLE_ACQ:
            self.packet_phase = 1
            if inputs["training_done"]:
                self.state = ST_W_PENDING
                self.packet_phase = 2
            elif old_acq_cnt == 0:
                self.W_missed_packet = 1
                self.W_missed_q = 1
                self.state = ST_PAYLOAD_ACTIVE
                self.packet_phase = 3

        elif old_state == ST_W_PENDING:
            self.packet_phase = 2
            if old_pending:
                self.W_valid = 1
                self.W_valid_set = 1
                self.W_commit_pending = 0
                self.state = ST_PAYLOAD_ACTIVE
                self.packet_phase = 3
            elif old_wpend_cnt == 0:
                if not old_w_valid:
                    self.W_missed_packet = 1
                    self.W_missed_q = 1
                self.state = ST_PAYLOAD_ACTIVE
                self.packet_phase = 3

        elif old_state == ST_PAYLOAD_ACTIVE:
            self.packet_phase = 3
            if old_pending:
                self.W_valid = 1
                self.W_valid_set = 1
                self.W_commit_pending = 0

            if old_pkt_cnt == 0:
                self.W_valid = 0
                self.packet_active = 0
                self.packet_active_ps = 0
                self.packet_phase = 0
                self.state = ST_IDLE

        else:
            # Matches the RTL default branch. Other outputs retain their value.
            self.state = ST_IDLE

        self.M_val = next_m

    def snapshot(self) -> dict[str, int]:
        """Return every modeled RTL register used by the standalone checker."""
        return {
            "state": self.state,
            "sc_lock_prev": self.sc_lock_prev,
            "lat_timing_ref": self.lat_timing_ref,
            "acq_cnt": self.acq_cnt,
            "wpend_cnt": self.wpend_cnt,
            "pkt_cnt": self.pkt_cnt,
            "M_val": self.M_val,
            "W_commit_pending": self.W_commit_pending,
            "W_valid": self.W_valid,
            "W_valid_set": self.W_valid_set,
            "W_missed_packet": self.W_missed_packet,
            "W_missed_q": self.W_missed_q,
            "packet_phase": self.packet_phase,
            "packet_active": self.packet_active,
            "packet_active_ps": self.packet_active_ps,
            "active_mode": self.active_mode,
            "active_antenna_en": self.active_antenna_en,
        }
