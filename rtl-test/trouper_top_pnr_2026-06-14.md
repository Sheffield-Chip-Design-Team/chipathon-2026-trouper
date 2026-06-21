# Trouper top P&R characterization — 2026-06-14

## Summary

This note records the TDM8-based `ol_trouper_top` physical-design experiment and the floorplan comparison work done on 2026-06-14.

The active RTL was changed from four `sd_decimator_cic_only` instances to the shared TDM path:

- `rtl-test/rtl/trouper_top.v`
- `rtl-test/rtl/sd_decimator_cic_tdm8.v`

The functional sanity check passed in `iverilog` before any PD work continued. The short RTL compile issue that appeared during elaboration in `trouper_top.v` was a local wire-declaration ordering problem, not a TDM8 logic bug.

## Key PD results

### Completed rectangle proxy

Run:

- SGE job `1778`
- `trouper-top-pnr-tdm8-1375x1100`

Setup:

- `DIE_AREA: 0 0 1375 1100`
- `PL_TARGET_DENSITY_PCT: 55`

Result:

- `DONE`
- exit code `0`
- final utilization: `62.79%`
- route wirelength: `1,694,610 um`
- setup WNS: `0`
- hold WNS: `0`
- antenna: `1 net / 1 pin`

Interpretation:

- The wider rectangle is physically viable.
- It is the cleanest result for timing among the TDM8 floorplan experiments recorded here.

### Completed L-shape proxy

Run:

- SGE job `1785`
- `trouper-top-pnr-tdm8-lshape`

Proxy geometry:

- rectangular die: `1650 x 1100 um`
- blocked corner: `550 x 550 um`
- equivalent usable area to `1.1 x 1.1 + 0.55 x 0.55`

Setup:

- `DIE_AREA: 0 0 1650 1100`
- `FP_OBSTRUCTIONS: [[1100, 550, 1650, 1100]]`
- `PL_TARGET_DENSITY_PCT: 55`

Result:

- `DONE`
- exit code `0`
- final utilization: `51.96%`
- route wirelength: `1,725,817 um`
- setup WNS: `-3.23 ns`
- hold WNS: `0`
- antenna: `1 net / 1 pin`

Interpretation:

- The L-shape proxy is physically routable and does not trigger the earlier `IQ_CLK` pin-access failure.
- Compared with the plain rectangle, it is worse on setup timing and slightly longer on wirelength.
- It is a valid floorplan experiment, but not the preferred baseline.

## Density / size notes

Two smaller-area experiments were used to bracket floorplan feasibility:

- `1100 x 1100 um` with `65%` target density
- `1375 x 1100 um` as a rectangular proxy for the same total area as the `1.1 + 0.55` area-extension idea

The `1100 x 1100 um` case was placeable, but the placer auto-adjusted density upward to about `80%`, which made it a much tighter PD problem. The `1375 x 1100 um` proxy stayed in the low-60% utilization range and was much more practical.

## Practical conclusion

For the current TDM8 branch:

- `1375 x 1100 um` is the better PD baseline.
- The L-shape proxy is feasible, but it does not improve timing.
- The TDM8 RTL itself is not the blocker; the remaining risk is physical implementation detail, especially `IQ_CLK` routing sensitivity under tighter floorplans.

## Related files

- [rtl-test/README.md](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/README.md)
- [rtl-test/ol_trouper_top/config_current.json](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/ol_trouper_top/config_current.json)
- [rtl-test/rtl/trouper_top.v](/home/timothyjabez/Documents/chipathon-2026/chipathon-2026-trouper/rtl-test/rtl/trouper_top.v)
