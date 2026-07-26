# Memory Strategy

Covers all on-chip SRAM in the **Grouper** project and the off-chip PSRAM strategy for the **Trouper** project.

> **⚠️ SUPERSEDED for Trouper (2026-07-04): Trouper uses NO on-chip SRAM.** All Trouper sample storage, SC delay-line buffering, and same-packet replay use the **off-chip APS6404L PSRAM** (see Macro Allocation below). The sections here describing an **on-chip Trouper "frontend buffer" SRAM** (`gf180mcu_fd_ip_sram__sram512x8m8wm1` — §"SRAM macro source", §"Rationale for the split — DSP SRAMs", and the SRAM-rail-sharing argument in §"Core voltage decision — 3.3 V") reflect an earlier plan and **no longer apply**; retained for history only. Still valid: **Grouper's** CPU unified SRAM (`gf180mcu_ocd_ip_sram`, separate project) and the off-chip PSRAM strategy. The 3.3 V Trouper core target stands, but for timing/board reasons — see `planning/Pinout.md` and `planning/Open Risks.md` #27 — not the SRAM-rail-sharing rationale below.

---

## Macro allocation

| Instance | Size | Macro | Project | Block |
|---|---|---|---|---|
| CPU SRAM (unified) | 4 KB | `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` ×4 | Grouper | PicoRV32 Integration |

**Total on-chip SRAM: 4 KB (Grouper only)**

Trouper contains **no internal SRAM macros**. All decimated sample storage, SC delay-line buffering, and same-packet replay are served by the **off-chip APS6404L PSRAM**. This eliminates the SRAM area and power penalty in the Trouper macro and allows the SC detector to use full-symbol integration across all SFs without depth constraints.

A single unified SRAM in **Grouper** holds PicoRV32 `.text`, `.data`, `.bss`, and stack. It is partitioned logically into fixed `1 kB` banks for planning:

- `BANK0` `0x0000`–`0x03FF`: firmware-visible
- `BANK1` `0x0400`–`0x07FF`: firmware-visible
- `BANK2` `0x0800`–`0x0BFF`: firmware-visible
- `BANK3` `0x0C00`–`0x1000`: firmware-visible / stack

No separate IMEM/DMEM split in Grouper — one AHB-Lite port, one BIST instance.

**Area:** Grouper CPU unified SRAM uses 4 × `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` = **~0.62 mm²**. This SRAM is part of the hardened Grouper macro and is not visible to the Trouper P&R run.

---

## Off-Chip PSRAM Strategy (Trouper)

The APS6404L (8 MB, QSPI, 32 MHz) serves as the primary data buffer for the MIMO datapath.

### Roles

1. **SC Delay Line:** Replaces the internal 512 B SRAM for the Schmidl-Cox detector. Allows storing a full symbol period (M samples) for SF7–SF12.
2. **Replay Buffer:** Stores decimated I/Q samples for the current packet. Allows the MRC combiner to re-process the preamble and payload with weights computed by the PicoRV32 after training is complete (same-packet MRC).
3. **Firmware Scratchpad:** Optionally available to the Grouper PicoRV32 for large data structures or logging via the Trouper PSRAM controller's AHB-Lite slave interface.

### Timing and Bandwidth

At 32 MHz with 8-bit complex samples (corrected 2026-07-26, audit item 21 — the previous
"~1 µs write / ~0.5 µs read / **~38%**" figures did not match the controller's actual
sub-cycle budget; TRPR-PSR-014 and `psram_buf_ctrl.v:184` are authoritative):

- Sample rate: 500 kS/s → `iq_valid` every **64 clocks** (2.0 µs)
- Capture write, 8 bytes covering all 4 antennas: **25 cycles** (0.78 µs)
- SC delay read, 1 branch, 2 bytes: **19 cycles** (0.59 µs)
- Replay read, 8 bytes: **31 cycles** (0.97 µs)
- **Capture + SC detection: 44 of 64 cycles → 69%**, 20 spare
- **Capture + replay: 56 of 64 cycles → 88%**, 8 spare

The replay phase is the binding case. Debug readback is serviced only from the S_WRITE
spare slot, at lower priority than capture writes.

---

## Post-extraction timing verification (Grouper)

**Parasitic-extracted SPICE simulations are required for both SRAM types. No verified 3.3 V timing exists for either macro — do not treat the 2-cycle multicycle path as confirmed until extraction is complete.**

> **Action item:** Assign parasitic-extracted SPICE simulation of both SRAM macros at 3.3 V, SS corner, −40 °C (worst-case cold for CMOS Vth). This is a blocking prerequisite for sign-off on the SDC multicycle path constraints.

- **`gf180mcu_fd_ip_sram__sram512x8m8wm1` (Trouper DSP SRAMs):** Characterised at 4.5 V and 5.5 V only. Worst-case Tcyc is **11.89 ns at SS/4.5 V/−40 °C**. Operating at 3.3 V degrades timing; extraction must confirm tCYC ≤ 62.5 ns (2-cycle budget at 32 MHz).

- **`gf180mcu_ocd_ip_sram__sram1024x8m8wm1` (Grouper CPU SRAM):** Native 3.3 V design, but characterisation data is currently copied from FD 5V specs. Independent characterisation is required. The 2-cycle multicycle path on the Grouper AHB-Lite bus is assumed pending verification.

Both simulations must be run at slow-slow corner, 3.3 V supply, and −40 °C (cold Vth worst case for CMOS). Also run at +85 °C to bound the full operating envelope. Results determine whether 2-cycle or 3-cycle paths are needed, and whether the 32 MHz clock target can be held.

### OCD Liberty timing model is unverified — STA is signing off against FD numbers (2026-05-28 finding)

The investigation of the post-PnR STA reports for the PicoRV32 wrapper exposed a sharper problem than "spec sheets are identical." The Liberty (`.lib`) files themselves — the actual numerical tables OpenSTA reads during sign-off — share the same property:

**Direct `.lib` comparison (TT 025C 3v30 corner, both libs):**

| Field | `gf180mcu_fd_ip_sram__sram512x8m8wm1__tt_025C_3v30.lib` | `gf180mcu_ocd_ip_sram__sram1024x8m8wm1__tt_025C_3v30.lib` |
|---|---|---|
| `cell_rise(q_delay_template)` first row (Q[0] from CLK) | `6.9234, 6.95652, 7.03452, 7.17396, 7.3776, 7.65684, 8.0352` | **identical** |
| `cell_fall(q_delay_template)` first row | `7.17732, 7.20636, 7.2762, 7.3968, ...` | **identical** |
| `rise_transition(q_slew_template)` | `0.227676, 0.266148, 0.399252, 0.646284, 1.03256, ...` | **identical** |
| Reported `area` field | `209400.2768` | `209400.2768` ← **FD's area, not OCD's actual 155,415 µm²** |
| Header technology field | `GF 180nm 5V Green` | `GF 180nm 3.3V` |
| Library copyright | `GlobalFoundries PDK Authors` | `Open Circuit Design, LLC` — `3.3V SRAM based on the GlobalFoundries PDK Authors 5V SRAM` |
| Lines that differ from FD lib | (baseline) | **only 20 lines** — copyright header + address-bus width (10 vs 9) |

OCD took the FD `.lib`, changed only the copyright header, the `bit_width`/`bit_from` of the address bus, and a handful of identifiers, then shipped it. **All numerical timing arcs, setup/hold tables, slew tables, and the reported area are FD-512×8's values.** When OpenSTA reports +0.95 ns SS slack on a PicoRV32 path that touches the OCD memory, it is computing that slack using the FD-512×8 5 V cell model — not OCD's actual 3.3 V 1024-deep bit-cell.

**What this means for tapeout:**

1. **STA results for OCD memory paths are not silicon-predictive.** The +22.8 ns (DELAY 0) and +0.95 ns (AREA 0) slack figures quoted across the PD experiments are based on FD timing applied to an OCD layout. Actual OCD silicon could be faster (smaller bit-cell parasitic) or slower (1024 depth → longer bit-line, taller cell → longer wordline), but the `.lib` cannot tell us which.
2. **Power estimates are also wrong.** OCD's true switched capacitance differs from FD's. Dynamic-power numbers from the `.lib` underestimate or overestimate by an unknown factor.
3. **Floorplan area accounting is internally inconsistent.** The LEF gives OCD's real outline (155 k µm²), but the `.lib` says 209 k µm². OpenROAD uses the LEF for placement bounds but tools that consume `.lib` area (some power flows, some macro reports) see the FD number.
4. **This is in addition to the 3.3 V derating gap for the FD macro itself.** Even FD is only characterised at 4.5/5.5 V — the FD-512×8 numbers OCD is borrowing are not 3.3 V numbers either. So the OCD memory in the PicoRV32 critical path is timed using **FD numbers extrapolated from 5 V silicon, applied to a different layout, simulated at the wrong voltage**.

### Mandatory characterisation plan

Before tapeout we must produce honest characterisation data for both macros at the actual operating point (3.3 V, full corner sweep). Two paths in parallel:

**Path A — Parasitic-extracted SPICE simulation (in-flow, fast)**

Owner: TBD. Blocking for SDC sign-off.

Scaffolding lives at [`characterization/`](../characterization/README.md) (added 2026-05-28) with parallel flows for both macro families:

- [`characterization/sram_ocd/`](../characterization/sram_ocd/README.md) — OCD 1024×8 (PicoRV32 RAM)
- [`characterization/sram_fd/`](../characterization/sram_fd/README.md) — FD 512×8 (Frontend Buffer; also fallback candidate for PicoRV32)

Both flows have identical staging:

- **S0** — schematic-level SPICE on the existing `gf180mcu_ocd_ip_sram__sram1024x8m8wm1.spice` netlist at TT 3.3 V, compare measured `CLK ↑ → Q[0]` delay to the value in the shipped `.lib`. If they don't match, the `.lib` is fictional and we know it immediately. Run: `characterization/sram_ocd/run_schematic_sim.sh tt_025C_3v30`.
- **S1** — same testbench, full PVT corner sweep (5 shipped-lib corners + 4 lab-boost / uncharacterised corners from `corners.csv`).
- **S2** — parasitic extraction via `magic ext2spice -p` + rerun SPICE. This is the heavy step; expected hours per extraction and several GB on disk for `extfiles_parasitic/`. Script: `characterization/sram_ocd/extract_parasitics.sh`.
- **S3** — full corner sweep on the extracted netlist; regenerate `.lib`.

Each `S*` stage produces JSON measurement files in `characterization/sram_ocd/results/`. `compare_to_lib.py` produces the diff table for the planning doc.

For each macro variant in use (`fd_ip_sram__sram512x8m8wm1`, `ocd_ip_sram__sram1024x8m8wm1`):
1. Extract layout parasitics from the macro GDS using Magic/ngspice (`magic -dnull -noconsole < extract.tcl`).
2. Run SPICE simulation on the key timing arcs:
   - `CLK ↑ → Q[0]` clock-to-output delay (rise/fall), with output load swept 10–100 fF
   - `A[*]/D[*]/WEN[*]` setup time relative to `CLK ↑`
   - `A[*]/D[*]/WEN[*]` hold time relative to `CLK ↑`
   - Minimum pulse widths on `CLK`
3. Sweep PVT corners (see `characterization/sram_ocd/corners.csv`):
   - **TT 25 °C 3.30 V** (typical, target operating point)
   - **SS 125 °C 3.00 V** (slowest — hot Vth + voltage droop)
   - **SS −40 °C 3.30 V** (cold Vth, additional check — CMOS Vth rises at cold)
   - **FF −40 °C 3.60 V** (fastest — for hold timing closure)
   - **TT 25 °C 3.60 V / 4.00 V** (lab-boost envelope, uncharacterised but needed for MPW testing)
4. Output corrected Liberty tables; replace the existing `.lib` numerical entries with measured values. Re-run full LibreLane PnR with the corrected libs.

**Path B — Silicon characterisation post-tapeout (validation, slow)**

Owner: bench-test team. Validates Path A on actual silicon.

1. Add CLK-stress test mode to PicoRV32 firmware: sustained pseudo-random read/write loops on a fixed address range with deterministic data patterns.
2. Lab sweep: VDD = 3.0 / 3.3 / 3.6 / 4.0 V × temperature = 25 °C / 85 °C (chamber if available).
3. For each (V, T) point, sweep input clock frequency from 16 MHz upward until first read mismatch. Report shmoo plot.
4. Compare measured frequency-margin to Path A's predicted margin. Any silicon point worse than Path A says corrected `.lib` is still optimistic — apply additional derate before any subsequent tapeout.

**Path C — Conservative interim sign-off (the now-decision)**

Until Path A produces corrected libs:
- Apply a **2× derate margin** to all timing arcs touching the OCD memory in PnR sign-off (i.e., require +2× the nominal slack on any path that crosses an OCD SRAM pin). Concretely: for the current `area_t1` config showing +0.95 ns slack at SS, that path is **not** signed off — we need at least the OCD-untouched paths to dominate the slack budget.
- Or: switch the PicoRV32 unified RAM to FD-only (8 × `sram512x8` for 4 kB) — the FD `.lib` is still 5 V-derived but at least it matches the FD layout, and we have an explicit derate plan from 5 V to 3.3 V via Path A.

**Decision pending:** weigh OCD area savings (0.62 mm²) vs FD area cost (1.67 mm²) and the **risk** of taping out 4 macros on uncharacterised timing.

---

### Core voltage decision — 3.3 V

**The core logic supply is 3.3 V.** The current memory plan intentionally uses a **mixed SRAM library strategy**: official GF `gf180mcu_fd_ip_sram` macros for the DSP/frontend buffer, and experimental `gf180mcu_ocd_ip_sram` macros for the CPU unified SRAM. All selected macros are intended to run at 3.3 V. Running the core at 3.3 V places all logic and all SRAMs on the same rail, eliminating any need for level shifters at SRAM interfaces. It also allows `VDD_CORE` and `VDD_IO` to share a supply (both 3.3 V), simplifying the board power tree.

3.3 V standard cells have shorter propagation delay than 1.8 V equivalents (higher overdrive current), so timing closure at 32 MHz is expected to be straightforward for the combinational logic. **SRAM cycle time at 3.3 V has not been characterised for either macro** — see the post-extraction timing verification section above. AHB-Lite accesses to IMEM/DMEM are provisioned with a 2-cycle multi-cycle path constraint in the timing flow pending extraction results; PicoRV32's `mem_valid`/`mem_ready` handshake handles variable-latency memory naturally, so extending to 3 cycles requires only an SDC change and a firmware timing re-check.

### SRAM macro source

This plan currently mixes two SRAM sources by design:

| Use | Library | Macro | Width | Height | Area |
|---|---|---|---|---|---|
| Frontend buffer | GF-provided SRAM | `gf180mcu_fd_ip_sram__sram512x8m8wm1` | 431.86 µm | 484.88 µm | ~0.209 mm² |
| CPU unified SRAM | Experimental SRAM | `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` | 301.3 µm | 515.8 µm | ~0.156 mm² |

The frontend-buffer estimate above uses the official GF PDK dimensions from the `gf180mcu_fd_ip_sram__sram512x8m8wm1` documentation. The CPU estimate uses the `gf180mcu_ocd_ip_sram` experimental library dimensions because the CPU memory plan is intentionally based on the experimental 3.3 V `1024x8` macros rather than the official GF SRAM family.

Under that assumption:

- Frontend Buffer uses 2 × `gf180mcu_fd_ip_sram__sram512x8m8wm1` = **~0.419 mm²**
- CPU unified SRAM uses 4 × `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` = **~0.625 mm²**

---

## Rationale for the split

### DSP SRAMs — GF-provided 512x8 macros at 3.3 V

*(Historical — see the banner at the top of this document; these macros are not instantiated.)* The Frontend Buffer SRAMs (SRAM0, SRAM1) were in the real-time acquisition critical path. A single stuck bit causes a corrupt delayed-sample read, which degrades the SC autocorrelation statistic and can prevent preamble detection entirely. There is no runtime recovery path short of resetting the block.

The `gf180mcu_fd_ip_sram__sram512x8m8wm1` macro size exactly matches the required 2-channel × 128-sample rolling window at 8-bit storage. No level shifters are required — core logic and SRAM share the 3.3 V rail.

> **Historical only (audit item 21, annotated 2026-07-26).** The paragraph below sized a
> `gf180mcu_fd_ip_sram__sram512x8m8wm1` frontend-buffer SRAM against decimation ratios
> R=256/128/64/32. None of that is live: the block and all Trouper on-chip SRAM were
> removed (TRPR-PHY-006), the chain is a fixed R=64 half-band chain, and R=32 / 1 MS/s is
> out of scope. The equivalent live budget is the PSRAM sub-cycle table above. Retained
> because the 2-cycles-per-access extraction question still informs the Grouper CPU SRAM
> discussion that follows.

*(superseded)* **2 clock cycles per byte access** at 32 MHz (budget = 62.5 ns) was the working assumption, pending parasitic-extracted SPICE confirmation. No divided clock was needed — the Frontend Buffer Controller FSM held each address stable for 2 cycles before advancing. Each sample time required 4 reads + 4 writes = 16 cycles. At the then-primary sample rates (R=256/128/64) SRAM utilisation was 6–25%; at R=32 (1 MS/s debug mode) 50%.

### CPU SRAMs — experimental macros at 3.3 V

IMEM and DMEM are not in any sample-rate path. Their only hard timing requirement is AHB-Lite read latency (≤ 2 cycles at 32 MHz). Both macros are reloaded or re-initialised on every power cycle: IMEM is written by the host over SPI before CPU reset is released; DMEM is initialised by the C runtime at boot. A partial fault is therefore recoverable without hardware modification (see Fallback strategy below).

A **2-cycle multi-cycle path** on all IMEM/DMEM accesses at 32 MHz is provisioned pending extraction — see post-extraction timing verification above. PicoRV32's `mem_valid`/`mem_ready` handshake already supports variable-latency memory; the SRAM controller holds `mem_ready` low for one extra cycle on every access. No divided clock is needed. This must be captured as a multicycle path exception in the SDC constraints file, and the cycle count must be updated once extraction results are available.

**Firmware footprint target: ≤4 KB total (text + data + stack).** PicoRV32 firmware handles: W vector computation from Z_j (MRC weights), TDD antenna switching, AGC loop, SX1257 init via SPI master. These tasks are simple fixed-point loops with no OS, no floating point, and minimal data structures. The unified 4 KB SRAM provides comfortable headroom for both code and data.

---

## Spreading factor support

The DSP SRAM depth (512 B per macro, 4 bytes per sample time) determines the maximum SF the Frontend Buffer can serve. SC only needs M samples of delayed storage — the current sample arrives live from the decimator. Using a **D=M read-before-write** access pattern (read the M-old byte, then immediately overwrite it with the current byte at the same address) eliminates the need for a 2M-deep buffer:

| Config | D | Bytes/macro | Max SF | Notes |
|---|---|---|---|---|
| 2 × 512 B, 8-bit storage, D=M | M | M×4 | **SF7** (M=128, 512 B exactly) | Baseline hardware |
| 2 × 512 B, 16-bit storage, D=M | M | M×8 | SF6 (M=64, 512 B exactly) | No margin |
| 4 × 512 B, 8-bit storage, D=M | M | M×4 | **SF8** (M=256, 1024 B) | Add 2 macros |
| 8 × 512 B, 8-bit storage, D=M | M | M×4 | **SF9** (M=512, 2048 B) | Add 6 macros |

SF8 support costs 2 additional proven macros (total 4 DSP SRAMs, 2 kB). The access pattern, address controller, and BIST architecture are unchanged — only the address counter width and macro count increase.

---

## BIST

BIST runs at power-on, before the host releases `CPU_RESET` for the CPU SRAM banks and before acquisition mode is entered for the DSP SRAMs. All results are readable via SPI.

### DSP SRAMs (proven macros) — address-reporting with zero-substitution

March-5N write/read pattern on each 512 B macro independently. Faults are reported at **sample-time granularity** (4-byte groups): if any byte in a group fails, the entire sample-time address is marked bad. The host programs bad addresses into a per-macro zero-substitution CAM in the Frontend Buffer Controller after BIST.

**Zero-substitution principle.** For SC correlation, returning zero for a bad delayed sample is safe — the term drops from the accumulation rather than corrupting it. At SF7 (M=128), one bad sample time reduces effective integration to 127/128 (~0.03 dB loss). Both numerator and denominator of the SC lock condition lose the same term, so the ratio is preserved and no threshold adjustment is needed.

**SF-range awareness.** Only faults within sample-time addresses `[0, M)` are counted against the CAM budget. Faults at addresses ≥ M are never accessed at the current SF and are ignored.

| Register | Description |
|---|---|
| `SRAM0_BIST_PASS` | 1 = SRAM0 passed with no faults |
| `SRAM0_BAD_SAMPLE_COUNT` | Number of bad sample-time addresses found in SRAM0 |
| `SRAM0_ZERO_SUB_n_ADDR` (n=0..15) | Bad sample-time address for CAM entry n |
| `SRAM0_ZERO_SUB_n_VALID` (n=0..15) | Enable for CAM entry n |
| `SRAM1_BIST_PASS` | 1 = SRAM1 passed with no faults |
| `SRAM1_BAD_SAMPLE_COUNT` | Number of bad sample-time addresses found in SRAM1 |
| `SRAM1_ZERO_SUB_n_ADDR` (n=0..15) | Bad sample-time address for CAM entry n |
| `SRAM1_ZERO_SUB_n_VALID` (n=0..15) | Enable for CAM entry n |

Degraded-mode policy:

| SRAM status | Acquisition mode |
|---|---|
| Both pass (count = 0) | Full NR=4, no substitution |
| Either macro: count ≤ 16 within `[0, M)` | NR=4 with zero-substitution; slight integration loss |
| SRAM0: count > 16 within `[0, M)` | NR=2 using ch2/ch3 (SRAM1) |
| SRAM1: count > 16 within `[0, M)` | NR=2 using ch0/ch1 (SRAM0) |
| Both macros: count > 16 within `[0, M)` | Bypass only; SC acquisition disabled |

### CPU SRAM (banked qualification on unified physical SRAM)

The physical CPU memory is still one unified 4 KB SRAM, but qualification and policy are evaluated per fixed `1 kB` bank:

- `BANK0` firmware-visible
- `BANK1` firmware-visible
- `BANK2` firmware-visible
- `BANK3` reserved

March C- runs over the full 4 KB array, and the implementation must attribute failures to the corresponding bank so policy can be decided per bank.

| Register | Width | Description |
|---|---|---|
| `SRAM_BIST_PASS` | 1 | 1 = March C- found no faults |
| `SRAM_BIST_FAIL_ADDR` | 10 | Word address of first failing word (in units of 4 bytes) |
| `SRAM_BIST_FAIL_BITS` | 32 | Bit mask of failing bits at `SRAM_BIST_FAIL_ADDR` |
| `CPU_SRAM_BANK0_PASS` | 1 | Lower 1 kB firmware bank clean |
| `CPU_SRAM_BANK1_PASS` | 1 | Second 1 kB firmware bank clean |
| `CPU_SRAM_BANK2_PASS` | 1 | Third 1 kB firmware bank clean |

**March C- timing at 32 MHz:** 1 K words × 11 passes × ~4 cycles/word ≈ 44 K cycles ≈ 1.4 ms. Negligible at boot.

**BIST controller sequencing:**

```
Power-on
  ↓
DSP SRAM BIST (SRAM0, SRAM1 — parallel or sequential)
  ↓
CPU SRAM BIST (full 4 KB array, results reported per 1 kB bank — CPU held in reset)
  ↓
All BIST_PASS registers valid and readable via SPI
  ↓
Host reads results, programs overlay if needed (see below)
  ↓
Host releases CPU_RESET → PicoRV32 boots
```

---

## JTAG recovery — total CPU SRAM failure

If the CPU SRAM is completely unusable (BIST shows pervasive faults, overlay exhausted), normal firmware execution is impossible. However JTAG provides a partial recovery path that does not require any working SRAM:

**What works without SRAM:**

| Capability | Mechanism | Requires SRAM? |
|---|---|---|
| Halt CPU | DM asserts debug interrupt; CPU enters debug mode | No |
| Read/write x0–x31 | Abstract `Access Register` command | No — operates entirely within the register file |
| Single-step | DM resumes for one instruction, re-halts | Only if PC points to valid memory; useless if SRAM dead |
| Execute from program buffer | DM loads instructions into its own scratchpad; CPU fetches from DM, not SRAM | No — program buffer is inside the DM |
| Access ASIC SPI registers | Write an SPI transaction sequence into program buffer; execute it | No |
| Read ASIC register state | Halt, execute `lw` from peripheral address via program buffer | No |

**Program buffer execution** is the key capability: with 8–16 instruction slots in the DM, you can inject a small diagnostic loop — e.g. read `IRQ_STATUS`, read `SC_DBG_FLAGS`, or issue an SX1257 SPI transaction — and execute it with the CPU fetching entirely from the DM scratchpad. This allows diagnostic data collection and limited chip control even with a dead SRAM.

**What does not work without SRAM:** the full firmware loop (W computation, AGC, TDD switching) cannot run from the program buffer — it is too large. The DSP datapath (ΣΔ decimators, SC correlator, MRC combiner) continues to run autonomously in hardware regardless of CPU state; only the software control loop is lost.

**Implication for JTAG TAP implementation:** the DM should implement at least an 8-instruction program buffer and full abstract `Access Register` support (all 32 GPRs + CSRs). See [JTAG TAP](blocks/JTAG%20TAP.md).

---

## Fallback strategy — bad-word overlay for firmware banks only

Writing a correct value to a stuck SRAM cell does not fix it: the cell overrides the write driver and the bad data reappears on every subsequent read. The overlay approach bypasses the macro read entirely for known-bad addresses.

### Architecture

The unified CPU SRAM has a single 16-entry content-addressable overlay:

```
CAM entry: { valid[1], addr[9:0], data[31:0] }   (total: 16 × 43 bits)
```

On every IMEM or DMEM read:

```
if any valid CAM entry matches read_addr:
    return CAM_data      ← ignores SRAM output
else:
    return SRAM_data
```

The CAM lookup adds at most 1 pipeline stage (combinational priority encoder). At 32 MHz with a simple 16-entry CAM this is well within timing.

### Programming the overlay

1. Host reads `SRAM_BIST_FAIL_ADDR` and `SRAM_BIST_FAIL_BITS` via SPI.
2. Host relinks the firmware image with a linker memory map that excludes the bad word address (the linker assigns code and data to all other addresses, leaving the bad address as a gap).
3. Host writes the correct word for the bad address into the overlay CAM via SPI registers (`SRAM_OVERLAY_n_ADDR`, `SRAM_OVERLAY_n_DATA`, `SRAM_OVERLAY_n_VALID` for n = 0..15).
4. Host writes the firmware image to the SRAM via SPI burst-write. The correct word is also written to the SRAM at the bad address — it may not stick, but the CAM overrides on read.
5. Host releases `CPU_RESET`. PicoRV32 boots; reads to bad addresses return CAM data.

### Coverage and limits

| Scenario | Outcome |
|---|---|
| ≤ 16 isolated bad words, none at reset vector | Fully recoverable via overlay + firmware relink |
| Bad word at reset vector (0x00000–0x00003) | Unrecoverable for normal boot; JTAG program buffer can still execute diagnostics |
| > 16 bad words or large contiguous fault | Overlay exhausted; normal firmware execution impossible; JTAG program buffer remains available for chip diagnostics and register inspection |
| `SRAM_BIST_PASS = 1` | Normal boot; no overlay needed |

Because the CPU SRAM macros are experimental, the design must not rely on low defect probability assumptions for any specific address range, including the reset vector. Reset-vector faults, clustered failures, and bank-local defects must all be treated as normal planning cases. Any bad reset vector remains unrecoverable for normal boot.

### JTAG as a diagnostic complement

The JTAG TAP provides direct AHB-Lite access to IMEM and DMEM. JTAG is useful for:

- Reading back IMEM contents after firmware load to verify the overlay is working correctly
- Single-stepping the CPU through the boot sequence to observe the first fetch from a patched address
- Diagnosing DMEM faults at runtime by reading stack/data addresses while the CPU is halted

JTAG does not fix stuck cells (same limitation as SPI writes), but it provides a debug path that does not require any additional test infrastructure.

---

## Boot sequence summary

```
Power-on
    │
    ├─ DSP SRAM BIST (SRAM0, SRAM1)
    │      ├─ Both pass  → NR=4 acquisition ready
    │      ├─ One fails  → NR=2 degraded mode
    │      └─ Both fail  → bypass mode only
    │
    ├─ CPU SRAM BIST (March C-) → SRAM_BIST_PASS, SRAM_BIST_FAIL_ADDR/BITS, per-bank PASS flags
    │
    └─ Host reads BIST results via SPI
           │
           ├─ All pass  ──────────────────────────── load firmware → release CPU_RESET
           │
           └─ CPU SRAM fault found
                  │
                  ├─ ≤ 16 isolated bad words, not at reset vector
                  │      relink firmware → program overlay CAM → load firmware → release CPU_RESET
                  │
                  └─ Bad reset vector or > 16 contiguous bad words
                         → chip cannot boot; report failure
```

---

## Register map additions

These registers live in the main register map at `0x10000` (AHB-Lite peripheral region).

| Register | Offset | R/W | Description |
|---|---|---|---|
| `SRAM_DUMP_ADDR` | TBD | R/W | Bits [8:0] = byte address (0–511); bit [9] = macro select (0=SRAM0, 1=SRAM1) |
| `SRAM_DUMP_DATA` | TBD | R | Byte at SRAM_DUMP_ADDR; valid one SPI transaction after address write |
| `SRAM_DUMP_START` | TBD | W | Write 1 to enter dump mode; only accepted in Locked (post-sc_lock) state |
| `SRAM_DUMP_DONE` | TBD | R | 1 = dump controller idle; SRAM_DUMP_DATA valid |
| `SRAM0_BIST_PASS` | TBD | R | DSP SRAM0 BIST result (1=pass, no faults) |
| `SRAM0_BAD_SAMPLE_COUNT` | TBD | R | Number of bad sample-time addresses in SRAM0 |
| `SRAM0_ZERO_SUB_n_ADDR` (n=0..15) | TBD | R/W | SRAM0 zero-sub CAM entry n: sample-time address (7-bit) |
| `SRAM0_ZERO_SUB_n_VALID` (n=0..15) | TBD | R/W | SRAM0 zero-sub CAM entry n enable |
| `SRAM1_BIST_PASS` | TBD | R | DSP SRAM1 BIST result (1=pass, no faults) |
| `SRAM1_BAD_SAMPLE_COUNT` | TBD | R | Number of bad sample-time addresses in SRAM1 |
| `SRAM1_ZERO_SUB_n_ADDR` (n=0..15) | TBD | R/W | SRAM1 zero-sub CAM entry n: sample-time address (7-bit) |
| `SRAM1_ZERO_SUB_n_VALID` (n=0..15) | TBD | R/W | SRAM1 zero-sub CAM entry n enable |
| `SRAM_OVERLAY_n_ADDR` (n=0..15) | TBD | R/W | CPU SRAM overlay CAM entry n word address |
| `SRAM_OVERLAY_n_DATA` (n=0..15) | TBD | R/W | CPU SRAM overlay CAM entry n data word |
| `SRAM_OVERLAY_n_VALID` (n=0..15) | TBD | R/W | CPU SRAM overlay CAM entry n enable |
| `BIST_CTRL` | TBD | R/W | Bit 0: re-run BIST; Bit 1: BIST in progress (R) |

---

## Related documents

- [Frontend Buffer Controller](blocks/Frontend%20Buffer%20Controller.md) — DSP SRAM BIST and degraded-mode policy
- [PicoRV32 Integration](blocks/PicoRV32%20Integration.md) — CPU SRAM BIST, overlay, boot sequence
- [Register Map](Register%20Map.md) — BIST and overlay register addresses (TBD)
- [JTAG TAP](blocks/JTAG%20TAP.md) — diagnostic complement to overlay
