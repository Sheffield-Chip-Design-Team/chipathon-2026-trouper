# Arty A7-100T Clock-Capable PMOD Pins

Only **JB** and **JD** have clock-capable pins. JA and JC have none.
**Bold** pins are clock-capable.

| Pin | JA — Standard (200Ω) | JB — High-Speed (0Ω, 100Ω diff trace) | JC — High-Speed (0Ω, 100Ω diff trace) | JD — Standard (200Ω) |
|-----|----------------------|---------------------------------------|---------------------------------------|----------------------|
| 1   | G13                  | **E15 (SRCC)**                        | U12                                   | **D4 (SRCC)**        |
| 2   | B11                  | **E16 (SRCC)**                        | V12                                   | **D3 (MRCC)**        |
| 3   | A11                  | **D15 (MRCC)**                        | V10                                   | **F4 (MRCC)**        |
| 4   | D12                  | **C15 (MRCC)**                        | V11                                   | **F3 (MRCC)**        |
| 7   | D13                  | J17                                   | U14                                   | **E2 (SRCC)**        |
| 8   | B18                  | J18                                   | V14                                   | **D2 (SRCC)**        |
| 9   | A18                  | K15                                   | T13                                   | H2                   |
| 10  | K16                  | J15                                   | U13                                   | G2                   |

## Notes

### MRCC — Master Regional Clock
- One per clock region, connected to the primary clock spine
- Can drive **BUFG** (global clock buffer) — routes the clock across the entire device with low skew
- Can drive **BUFR** (regional clock buffer) — clock limited to one clock region
- Can drive **BUFIO** — clock used only for I/O logic (not fabric)
- **Preferred for external clock inputs** — maximum routing flexibility

### SRCC — Secondary Regional Clock
- One per clock region, paired with the MRCC
- Can drive **BUFR** and **BUFIO** — same as MRCC for regional/IO clocking
- **Cannot drive BUFG directly** — cannot reach the global clock network without going through additional logic, which adds jitter
- Suitable for regional clocks or source-synchronous interfaces where the clock stays local

### Clocking logic gates
- **MRCC + BUFG** — clock distributed globally across the entire device with minimal skew. Safe default; works regardless of where Vivado places logic.
- **SRCC + BUFR** — clock limited to one clock region. Works if all logic fits within a single region, but risks a DRC error if logic is placed outside it.

For most designs, use MRCC + BUFG.

### Recommendation
For an external clock input (e.g. SX1302/SX1257), use **D15 or C15 (JB pins 3–4, MRCC)** for maximum flexibility.

## Vivado Tcl to verify

```tcl
link_design -part xc7a100tcsg324-1
foreach {pmod pin} {
    ja0 G13  ja1 B11  ja2 A11  ja3 D12  ja4 D13  ja5 B18  ja6 A18  ja7 K16
    jb0 E15  jb1 E16  jb2 D15  jb3 C15  jb4 J17  jb5 J18  jb6 K15  jb7 J15
    jc0 U12  jc1 V12  jc2 V10  jc3 V11  jc4 U14  jc5 V14  jc6 T13  jc7 U13
    jd0 D4   jd1 D3   jd2 F4   jd3 F3   jd4 E2   jd5 D2   jd6 H2   jd7 G2
} {
    set cc [get_property IS_CLK_CAPABLE [get_package_pins $pin]]
    if {$cc} { puts "CLOCK-CAPABLE: $pmod ($pin)" }
}
```

Source: `Arty-A7-100-Master.xdc` (Digilent), verified in Vivado.
