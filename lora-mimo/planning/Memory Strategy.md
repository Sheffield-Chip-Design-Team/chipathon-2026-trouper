# Memory Strategy

Covers all on-chip SRAM in the design: macro selection, voltage domain, BIST, and fallback policy.

---

## Macro allocation

| Instance | Size | Macro | VDD | Block |
|---|---|---|---|---|
| SRAM0 (ch0/ch1) | 512 B | `gf180mcu_fd_ip_sram__sram512x8m8wm1` | 3.3 V | Frontend Buffer Controller |
| SRAM1 (ch2/ch3) | 512 B | `gf180mcu_fd_ip_sram__sram512x8m8wm1` | 3.3 V | Frontend Buffer Controller |
| CPU SRAM (unified) | 4 KB | `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` ×4 | 3.3 V | PicoRV32 Integration |

**Total on-chip SRAM: 5 KB**

A single unified SRAM holds PicoRV32 `.text`, `.data`, `.bss`, and stack, but it is partitioned logically into fixed `1 kB` banks for planning:

- `BANK0` `0x0000`–`0x03FF`: firmware-visible
- `BANK1` `0x0400`–`0x07FF`: firmware-visible
- `BANK2` `0x0800`–`0x0BFF`: firmware-visible
- `BANK3` `0x0C00`–`0x0FFF`: reserved `CPU_SRAM_BORROW_BANK`

No separate IMEM/DMEM split — one AHB-Lite port, one BIST instance.

Linker/runtime rule:

- PicoRV32 `.text`, `.data`, `.bss`, and stack must be linked only into `BANK0`–`BANK2`
- `BANK3` must be excluded from the linker memory map whenever borrow mode is supported
- C runtime startup must not clear, initialize, or use `BANK3`
- any allocator, scratch buffer, or stack growth must also remain inside `BANK0`–`BANK2`

**Area:** Frontend Buffer uses 2 × `gf180mcu_fd_ip_sram__sram512x8m8wm1` = **~0.42 mm²** total based on the GF PDK physical dimensions (431.86 µm × 484.88 µm = 209400.2768 µm² each). CPU unified SRAM uses 4 × `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` = **~0.62 mm²** based on the experimental library dimensions currently referenced for the CPU memory plan. Total SRAM area under this mixed-library assumption is **~1.04 mm²**.

### Post-extraction timing verification

**Post-layout extraction simulations are required for both SRAM types before RTL sign-off.**

- **`gf180mcu_fd_ip_sram__sram512x8m8wm1` (DSP SRAMs, "5V Green" macro operated at 3.3 V):** The 55.6 ns minimum cycle time figure is from the datasheet characterisation at 3.3 V. Post-extraction sim must confirm actual access time and cycle time at 3.3 V, 32 MHz, worst-case process corner (slow-slow) and temperature (+85 °C). If extracted propagation delay shows tCYC > 62.5 ns (i.e. the 2-cycle budget is violated), the Frontend Buffer Controller access protocol must move to 3 cycles per byte, which halves the R=32 slack to zero.

- **`gf180mcu_ocd_ip_sram__sram1024x8m8wm1` (CPU unified SRAM, experimental macro):** No datasheet characterisation exists for this macro. Post-extraction sim is the only basis for a confirmed cycle time at 3.3 V. The 2-cycle multicycle path on the PicoRV32 AHB-Lite bus is assumed to be sufficient; if extracted delay shows tCYC > 62.5 ns, a 3-cycle path is needed and the firmware loop timing budget must be recalculated.

Both simulations must be run at slow-slow corner, 1.62 V (minimum supply), and +85 °C to establish worst-case timing.

---

### Core voltage decision — 3.3 V

**The core logic supply is 3.3 V.** The current memory plan intentionally uses a **mixed SRAM library strategy**: official GF `gf180mcu_fd_ip_sram` macros for the DSP/frontend buffer, and experimental `gf180mcu_ocd_ip_sram` macros for the CPU unified SRAM. All selected macros are intended to run at 3.3 V. Running the core at 3.3 V places all logic and all SRAMs on the same rail, eliminating any need for level shifters at SRAM interfaces. It also allows `VDD_CORE` and `VDD_IO` to share a supply (both 3.3 V), simplifying the board power tree.

3.3 V standard cells have shorter propagation delay than 1.8 V equivalents (higher overdrive current), so timing closure at 32 MHz is expected to be straightforward for the combinational logic. The SRAM macros have a minimum cycle time of **55.6 ns** (~18 MHz) at 3.3 V — this is an intrinsic macro limit, not a voltage issue. AHB-Lite accesses to IMEM/DMEM therefore require a 2-cycle multi-cycle path constraint in the timing flow; PicoRV32's `mem_valid`/`mem_ready` handshake handles this naturally without a separate divided clock.

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

The Frontend Buffer SRAMs (SRAM0, SRAM1) are in the real-time acquisition critical path. A single stuck bit causes a corrupt delayed-sample read, which degrades the SC autocorrelation statistic and can prevent preamble detection entirely. There is no runtime recovery path short of resetting the block.

The `gf180mcu_fd_ip_sram__sram512x8m8wm1` macro size exactly matches the required 2-channel × 128-sample rolling window at 8-bit storage. No level shifters are required — core logic and SRAM share the 3.3 V rail.

The 55.6 ns SRAM cycle time requires **2 clock cycles per byte access** at 32 MHz (2 × 31.25 ns = 62.5 ns > 55.6 ns). No divided clock is needed — the Frontend Buffer Controller FSM holds each address stable for 2 cycles before advancing, exactly as the CPU SRAM multicycle path does. Each sample time requires 4 reads + 4 writes = 16 cycles total (was previously documented as 8 cycles — that was incorrect). At the primary sample rates (R=256/128/64) the SRAM utilisation is 6–25%; at R=32 (1 MS/s debug mode) it is 50%, leaving 16 idle cycles per sample for control logic.

### CPU SRAMs — experimental macros at 3.3 V

IMEM and DMEM are not in any sample-rate path. Their only hard timing requirement is AHB-Lite read latency (≤ 2 cycles at 32 MHz). Both macros are reloaded or re-initialised on every power cycle: IMEM is written by the host over SPI before CPU reset is released; DMEM is initialised by the C runtime at boot. A partial fault is therefore recoverable without hardware modification (see Fallback strategy below).

The 55.6 ns SRAM cycle time requires a **2-cycle multi-cycle path** on all IMEM/DMEM accesses at 32 MHz. PicoRV32's `mem_valid`/`mem_ready` handshake already supports variable-latency memory — the SRAM controller holds `mem_ready` low for one extra cycle on every access. No divided clock is needed. This must be captured as a multicycle path exception in the SDC constraints file.

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

### Optional CPU SRAM borrow extension

Dedicated frontend SRAM remains the primary acquisition buffer in all modes.

An optional architecture extension may allow the Frontend Buffer Controller to extend its logical depth into a reserved upper CPU SRAM window.

The borrow model is **fixed-bank**, not dynamic:

- CPU SRAM is partitioned into four fixed `1 kB` banks
- the uppermost `1 kB` bank is reserved as `CPU_SRAM_BORROW_BANK`
- firmware and linker placement must never use `CPU_SRAM_BORROW_BANK`
- the frontend buffer may use only that reserved bank; it must not scatter or remap across arbitrary bad locations

If `CPU_RESET=0`, the reserved-bank rule is what preserves borrowed sample data. Releasing the CPU from reset does not erase SRAM, but firmware execution will eventually overwrite any region that remains visible to the linker or C runtime.

- `CPU_SRAM_BORROW_EN=0`: baseline mode; only the dedicated frontend SRAMs are used
- `CPU_SRAM_BORROW_EN=1`: hardware may spill delayed-sample storage into `CPU_SRAM_BORROW_BANK`

This extension is only valid under strict ownership rules:

- valid when `CPU_RESET=1`, or
- valid when firmware is explicitly excluded from the borrowed CPU SRAM bank by memory-map partitioning

It is **not** valid for firmware-managed sample copying. If the frontend cannot access the borrowed CPU SRAM as deterministic hardware memory, the feature is disallowed.

### Shared-borrow arbitration rule

If borrow mode is allowed while `CPU_RESET=0`, arbitration is not symmetric:

- the Frontend Buffer Controller has absolute priority on `CPU_SRAM_BORROW_BANK`
- PicoRV32 must never delay or block a frontend access to the borrowed bank
- if PicoRV32 would contend for the borrowed bank, Pico stalls; the frontend does not
- PicoRV32 must not legally access `CPU_SRAM_BORROW_BANK` through normal firmware allocation; linker/runtime exclusion is the primary protection
- any direct or erroneous Pico access into `CPU_SRAM_BORROW_BANK` is a blocked/illegal access for planning purposes and must not disturb borrowed sample storage

### Borrow-bank integrity rule

The borrowed sample-memory bank must be **fully clean**.

- If `CPU_SRAM_BORROW_BANK` passes BIST with no failing cells, borrow mode may be enabled
- If `CPU_SRAM_BORROW_BANK` has any failing cells, borrow mode is unavailable
- No blanking, no overlay CAM, and no partial use of a faulty borrowed bank are allowed

This differs from firmware SRAM recovery. Overlay/relink is acceptable for code/data because software can tolerate sparse remapping. It is **not** acceptable for live circular sample buffering, where deterministic contiguous addressing matters more than salvaging a few bad words.

#### SF7 fallback policy

If the CPU SRAM borrow path is unavailable, unsupported, or `CPU_SRAM_BORROW_BANK` fails BIST, `SF7` must degrade to `NR=2` acquisition rather than attempting a four-branch configuration that exceeds the available trusted sample memory for the selected storage mode. The surviving pair for this fallback is fixed to branches `1` and `3`.

Open note:

- if branch `1` or `3` is disabled or failed, the exact degraded-mode response is still TBD; do not infer an automatic remap in the current spec

The intended priority is:

1. Dedicated frontend SRAM only: baseline `SF6`
2. Dedicated frontend SRAM + CPU SRAM borrow: optional extended `SF7`
3. If borrow is not available: allow `SF7` only with `NR=2` on branches `1` and `3`

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
- `BANK3` reserved `CPU_SRAM_BORROW_BANK`

March C- runs over the full 4 KB array, and the implementation must attribute failures to the corresponding bank so policy can be decided per bank. The reserved upper bank is reported separately so the frontend knows whether borrow mode is legal.

| Register | Width | Description |
|---|---|---|
| `SRAM_BIST_PASS` | 1 | 1 = March C- found no faults |
| `SRAM_BIST_FAIL_ADDR` | 10 | Word address of first failing word (in units of 4 bytes) |
| `SRAM_BIST_FAIL_BITS` | 32 | Bit mask of failing bits at `SRAM_BIST_FAIL_ADDR` |
| `CPU_SRAM_BANK0_PASS` | 1 | Lower 1 kB firmware bank clean |
| `CPU_SRAM_BANK1_PASS` | 1 | Second 1 kB firmware bank clean |
| `CPU_SRAM_BANK2_PASS` | 1 | Third 1 kB firmware bank clean |
| `CPU_SRAM_BORROW_BANK_PASS` | 1 | Reserved upper 1 kB borrow bank clean and therefore eligible for live sample buffering |

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

Borrow enable rule:

- `CPU_SRAM_BORROW_EN` may assert only if `CPU_SRAM_BORROW_BANK_PASS=1`
- if `CPU_SRAM_BORROW_BANK_PASS=0`, borrow mode is disabled regardless of the status of the lower firmware banks

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

This recovery mechanism applies only to firmware-visible CPU SRAM banks. It does **not** apply to `CPU_SRAM_BORROW_BANK` when that bank is used as live sample memory.

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

Borrow-bank rule:

| Borrow bank status | Outcome |
|---|---|
| `CPU_SRAM_BORROW_BANK_PASS = 1` | Borrow mode may be enabled |
| `CPU_SRAM_BORROW_BANK_PASS = 0` | Borrow mode forbidden; `SF7` falls back to `NR=2` on branches `1` and `3` |

Because the CPU SRAM macros are experimental, the design must not rely on low defect probability assumptions for any specific address range, including the reset vector or the reserved borrow bank. Reset-vector faults, clustered failures, and bank-local defects must all be treated as normal planning cases. Any bad reset vector remains unrecoverable for normal boot, and any faulty borrow bank remains ineligible for live sample buffering.

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
