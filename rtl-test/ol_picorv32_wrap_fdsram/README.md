# PicoRV32 + FD-512×8 SRAM P&R variant (exploratory)

Alternative PicoRV32 wrapper that builds the 4 kB unified CPU SRAM from **8×
`gf180mcu_fd_ip_sram__sram512x8m8wm1`** instead of 4× OCD `sram1024x8`. This is
the *FD-only fallback*: the OCD `.lib` is a byte-identical copy of the FD-512×8
5 V data (see `characterization/sram_ocd/`), so until the OCD macro is
characterised, an all-FD build is the only one whose SRAM timing rests on
vendor-supplied data.

## Banking

Each byte lane needs 2 FD macros (512 words each) banked on `sram_addr[9]`:

- `wire bank = sram_addr[9];` selects low (0) / high (1) 512-word bank.
- `cen_lo`/`cen_hi` gate the active bank (CEN active-low); reset forces access.
- `bank_r` is registered alongside `sram_req_r`; it muxes the read data one
  cycle later (`lane_q = bank_r ? hi_q : lo_q`), matching the FD read latency.

RTL: `rtl-test/picorv32_wrap_fdsram.v` (same top module name `picorv32_wrap`,
Yosys-elaborates clean with 8 FD macros). Floorplan: 8 macros in a 4×2 grid
(`macro_placement.cfg`), die 2300×1750 µm.

## Status: P&R FAILS at detailed routing (job 1042)

The flow runs through synthesis, floorplan, placement and CTS, then dies in
DetailedRouting:

```
[DRT-0073] No access point for clkbuf_3_7_0_clk_32m_regs/I (…__clkbuf_8)
[DRT-0073] No access point for clkbuf_3_6_0_clk_32m_regs/I (…__clkbuf_8)
```

This is the **documented GF180MCU DRT density wall** (see memory
`drt-density-wall.md`): clock buffers in congested regions get no routing
access point. Contributing factors seen in the log:

- `clk_32m` fanout = 2472 terminals (whole-CPU register clock).
- PDN warnings: PSM-0038/0039 unconnected VDD shapes + unconnected macro VDD
  pins (`PDN_MACRO_CONNECTIONS` / pin alignment needs work).

8 FD macros occupy ~1.67 mm² of macro area (FD is physically *larger* per bit
than OCD: 8 FD ≈ 2.7× the macro area of 4 OCD), so this variant is both harder
to route and larger than the OCD build.

### To unblock (not yet attempted)

1. More whitespace — enlarge the die and/or lower `PL_TARGET_DENSITY_PCT`
   (currently 40) to clear the DRT density wall.
2. Fix the PDN macro connections so the macro VDD/VSS pins actually tie into
   the grid (resolve PSM-0038/0039).
3. Consider CTS clustering / lower max fanout on the clock to ease congestion
   around the macros.

Left as exploratory; revisit only if the OCD macro is deemed un-trustworthy
after characterisation and the all-FD area cost is accepted.
