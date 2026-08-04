"""Independent protocol reference model for ``spi_slave.v``.

This model is derived directly from the frame-format description in
``spi_slave.v``'s header comment and TRPR-SPS-002/009/010/011 (see
``planning/Trouper Chip Specification.md`` sec 4.11 and
``planning/verification-plan/spi-slave-verification-plan.md``), not from the
RTL's internal always-block structure -- it tracks only the byte-level
protocol contract (command decode, address progression, first-data-byte
timing, and read/write side effects), so it is not a transliteration of the
DUT's shift-register/CDC implementation.

Used by ``cocotb/spi_slave/test_spi_slave.py`` (verification-plan rows
#11, #12, #14) to check completed legal frames and constrained aborts
bit/byte-wise against the DUT.
"""

from dataclasses import dataclass, field

NO_INC_ADDR = 0x76  # PSRAM_DBG_DATA: burst-exempt, does not auto-increment


@dataclass
class SpiSlaveModel:
    """Byte-level oracle for one or more independent HOST_CS-framed
    transactions against a backing register file.

    ``regfile`` is the model's own view of register contents -- entirely
    independent storage from the DUT/reg_bank, seeded by the test and kept
    in sync only through the write events this model itself records.
    """

    regfile: dict = field(default_factory=dict)
    write_events: list = field(default_factory=list)   # (addr, data), completed writes only
    read_events: list = field(default_factory=list)    # addr, one per completed read data byte

    def peek(self, addr: int) -> int:
        return self.regfile.get(addr & 0x7F, 0) & 0xFF

    def run_frame(self, tx_bytes, total_bits=None, read_snapshot_fn=None):
        """Predict one HOST_CS-low frame's MISO bytes and side effects.

        ``tx_bytes``: the command byte followed by zero or more data bytes.

        ``total_bits``: how many SCK bits actually completed before CS rose
        (for a genuine abort); defaults to a fully-completed frame
        (``8 * len(tx_bytes)``).

        Per spi_slave.v's documented contract, a WRITE data byte only ever
        produces an event (and only ever updates ``regfile``) once all 8 of
        its own bits have completed. A READ data byte's event fires earlier
        -- "at the START of each read data byte" -- i.e. as soon as the
        byte before it (command or previous data byte) is fully done, which
        needs only that read byte's own first bit, not all 8. So an
        in-flight data byte that never finishes can still contribute a read
        event (with no corresponding MISO byte, since the byte was never
        fully shifted out) even though the identical situation on a write
        produces nothing at all. Constrained-abort callers rely on this
        asymmetry being modeled explicitly, not incidentally.

        ``read_snapshot_fn(addr) -> int``, if given, is called exactly once
        per completed read data byte, at the moment that byte's value would
        be latched (i.e. before any later byte in this frame is processed)
        -- this lets a test inject a live register value that differs from
        what ``run_frame`` would otherwise read from ``self.regfile``,
        modeling the byte-atomicity contract under test in row #11: the
        returned byte must reflect a single snapshot taken at that instant,
        not a value that can change bit-by-bit while it is shifted out.

        Returns the list of MISO data bytes for every data byte that
        completed all 8 bits (the command byte itself returns no meaningful
        bits under TRPR-SPS-009 and is never included).
        """
        if not tx_bytes:
            return []
        if total_bits is None:
            total_bits = 8 * len(tx_bytes)

        cmd = tx_bytes[0] & 0xFF
        is_read = bool(cmd & 0x80)
        addr = cmd & 0x7F

        full_bytes = total_bits // 8   # bytes (incl. command) that saw all 8 SCK edges
        partial_bits = total_bits % 8  # bits into the next (incomplete) byte, if any
        data_bytes = tx_bytes[1:]
        n_full_data_bytes = max(0, full_bytes - 1)

        rx_bytes = []
        for data_byte in data_bytes[:n_full_data_bytes]:
            if is_read:
                val = (
                    read_snapshot_fn(addr)
                    if read_snapshot_fn is not None
                    else self.peek(addr)
                )
                val &= 0xFF
                self.read_events.append(addr)
                rx_bytes.append(val)
            else:
                data_byte &= 0xFF
                self.regfile[addr] = data_byte
                self.write_events.append((addr, data_byte))
                rx_bytes.append(0x00)  # MISO is driven from reg_rdata only on reads

            # Burst auto-increment (7-bit wrap); 0x76 (PSRAM_DBG_DATA) holds.
            if addr != NO_INC_ADDR:
                addr = (addr + 1) & 0x7F

        # A read byte that started (>=1 bit) but never finished still fires
        # its event; a write byte in the same situation fires nothing.
        if full_bytes >= 1 and partial_bits >= 1 and n_full_data_bytes < len(data_bytes):
            if is_read:
                self.read_events.append(addr)

        return rx_bytes
