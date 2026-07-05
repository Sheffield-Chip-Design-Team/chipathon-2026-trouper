# io_placement_v2.cfg — pin-order rationale

Consumed by LibreLane `IO_PIN_ORDER_CFG` (the `.cfg` itself must contain **no
comments** — the `ioplace_parser` grammar only accepts `#N/#S/#E/#W` direction
markers, `$N` virtual-pin spacers, and anchored-regex pin names; any other `#`
line errors with *"identifier/regex '#' requires a direction to be set first"*).
Hence this rationale lives here, not inline.

## Grammar (from `librelane/scripts/odbpy/ioplace_parser/parse.py`)
- Direction: `#N`, `#S`, `#E`, `#W` (append `R` e.g. `#NR` to reverse order).
- Spacer / virtual pins: `$N` (regex `^\$\s*([0-9]+)`).
- Pin: a regex, anchored `^…$`; bus bits must escape the brackets: `IQ_DATA_Q\[0\]`.
- Sort: `@bus_major` (default) / `@bit_major`; `@min_distance <v>`.
- **No comment lines.**

## FIRM (functional intent — keep across any edge re-assignment)
- Groups stay contiguous; intra-group order avoids PCB criss-cross.
- **SX1257 baseband (`#S`)**: `IQ_CLK` then per-antenna **Q then I**, matching
  SX1257 `DS_SX1257_V1.2` pin14=Q_OUT → pin15=I_OUT (prevents the Q/I swap).
- **PSRAM QSPI (`#E`)**: all APS6404L signals together; per-bit OUT/IN/OE triplet
  kept contiguous.
- **REMOD + host SPI + control (`#W`)**: REMOD_A_I/Q → SX1302; HOST_CS/SPI_* → RPi;
  RESETB/IRQ_OUT/IRQ_GROUPER chip control.
- **Grouper parallel bus (`#N`)**: whole bus contiguous — ADDR[7:0], WDATA[7:0],
  RDATA[7:0], WE/RE/READY.

## PROVISIONAL (re-assign once PCB floorplan is locked)
- Which compass edge each group sits on. Core-only, no padframe yet. The edge
  assignment here is a routability sanity test, not the final pin map.

Covers all 59 core ports of `trouper_top`.
