# Software Energy Measurement via PSRAM Readback

**Date:** 2026-06-03  
**Status:** Design proposal — not yet implemented  
**Related:** [area-cut-contingency.md](area-cut-contingency.md), [Energy Measurement Reuse Feasibility Study.md](Energy%20Measurement%20Reuse%20Feasibility%20Study.md)

---

## Motivation

`energy_meas_coarse` (70k µm²) computes per-branch Σ(i² + q²) in hardware. It serves two purposes:

1. **AGC:** `energy_snap[0..3]` → `packet_ctrl_fsm` and reg_bank 0x40–0x47 for firmware gain control
2. **NW-MRC noise estimate:** `noise_metric[0..3]` → `sigma2_hw` → reg_bank for firmware weight computation

The PSRAM continuously buffers all decimated IQ samples. PicoRV32 can read them back after the fact and compute energy in software — replacing both functions with zero hardware arithmetic.

---

## Approach

PSRAM stores 8-bit decimated IQ samples at 8 bytes per `iq_valid` (all branches interleaved). After `training_done`, PicoRV32 reads a pre-preamble noise window from PSRAM and computes:

```
σ²_j = Σ(i_j[n]² + q_j[n]²) / M    for each branch j, over M noise samples
```

This gives **per-branch noise power** for NW-MRC weighting. The same computation on the signal window gives per-branch signal+noise energy for AGC.

### Data layout in PSRAM

At each `iq_valid`, `psram_buf_ctrl` writes 8 bytes at `wr_ptr`:

```
Byte 0: i_ant0   Byte 1: q_ant0
Byte 2: i_ant1   Byte 3: q_ant1
Byte 4: i_ant2   Byte 5: q_ant2   (zero for NR=2)
Byte 6: i_ant3   Byte 7: q_ant3   (zero for NR=2)
```

For NR=2, only bytes 0–3 are meaningful per sample.

### Window selection

At `sc_lock`, PSRAM `buf_base` is computed as `wr_ptr − (iq_sample_cnt − timing_ref) × 8`. Samples before `buf_base` are the **pre-preamble noise window**. Firmware selects:

```
noise_end   = buf_base              (last noise sample)
noise_start = buf_base − M × 8     (M samples of noise before preamble)
```

A typical M = 128 (SF7 symbol length) gives a clean noise estimate over one pre-preamble symbol.

---

## Timing budget

| SF | M (samples) | PSRAM reads (NR=2, 4 B/sample) | Cycles @ 16 MHz | Symbol period | Budget used |
|----|------------|-------------------------------|-----------------|---------------|-------------|
| 7  | 128        | 512 B                         | ~4,480          | 8.0 ms        | **3.5%**    |
| 9  | 512        | 2,048 B                       | ~17,920         | 32.8 ms       | **3.5%**    |
| 12 | 4,096      | 16,384 B                      | ~143,360        | 131.1 ms      | **7.0%**    |

Cycle estimate: 512 B × 15 cycles/byte (AHB + QPI burst) + 256 multiply-accumulates × 5 cycles.

Firmware runs this computation between `training_done` and writing the W shadow — already a busy window, but the budget is ample.

---

## RTL changes required

### 1. Expose full PSRAM write pointer to reg_bank (~2k µm²)

`psram_buf_ctrl` has a 23-bit internal `wr_ptr` but only 7 bits reach reg_bank (register 0x15). Add a 3-byte read-only register:

```
0x15 [6:0]  = wr_ptr[6:0]    (existing — low byte)
NEW 0xBC    = wr_ptr[14:7]   (mid byte)
NEW 0xBD    = wr_ptr[22:15]  (high byte, only 1 bit used for 8 MB PSRAM)
```

Alternatively, expose all 23 bits via the existing `psram_status_rb` interface or dedicated registers.

### 2. Firmware-triggered diagnostic read mode in psram_buf_ctrl (~5–8k µm²)

Current psram_buf_ctrl read mode: replay only, triggered at W_commit, reads from `buf_base` until packet end.

Add a **diagnostic read** mode: firmware writes a start address and byte count to reg_bank, psram_buf_ctrl reads that window and presents bytes via a single AHB-readable data register (byte-at-a-time, with a `drdy` strobe).

New reg_bank registers:
```
0xBE [7:0]  = psram_diag_addr[7:0]
0xBF [7:0]  = psram_diag_addr[15:8]
0xC0 [6:0]  = psram_diag_addr[22:16]
0xC1 [7:0]  = psram_diag_len[7:0]
0xC2 [7:0]  = psram_diag_len[15:8]
0xC3 [0]    = psram_diag_start (W1P)
0xC4 [7:0]  = psram_diag_rdata (read: next byte; auto-advances pointer)
0xC5 [0]    = psram_diag_busy
```

psram_buf_ctrl reuses the existing QPI read state machine with `rd_ptr = psram_diag_addr`. The diagnostic read interleaves with normal write traffic using the existing arbitration (writes take priority).

---

## Firmware flow

```
// After training_done:
uint32_t noise_end   = psram_read_wr_ptr();          // read 3-byte wr_ptr
uint32_t noise_start = buf_base - M * 8;             // buf_base known from reg_bank

// Trigger diagnostic read
psram_diag_read(noise_start, M * 4);                 // NR=2: 4 bytes/sample × M samples

// Accumulate energy per branch
int32_t e0 = 0, e1 = 0;
for (int n = 0; n < M; n++) {
    int8_t i0 = psram_diag_getbyte();
    int8_t q0 = psram_diag_getbyte();
    int8_t i1 = psram_diag_getbyte();
    int8_t q1 = psram_diag_getbyte();
    e0 += (int32_t)i0*i0 + (int32_t)q0*q0;
    e1 += (int32_t)i1*i1 + (int32_t)q1*q1;
}
sigma2[0] = e0 / M;
sigma2[1] = e1 / M;

// NW-MRC weights
for (int j = 0; j < NR; j++) {
    W_re[j] = (int16_t)( Z_i[j] / sigma2[j] );
    W_im[j] = (int16_t)(-Z_q[j] / sigma2[j] );
}
// write W shadow, commit
```

The division `Z_j / σ²_j` can be implemented as a shift if σ²_j is rounded to a power of two, or as a reciprocal multiply if more precision is needed.

---

## Net area impact

| Change | ∆ stdcell |
|---|---|
| Remove `energy_meas_coarse` | −70k µm² |
| Add wr_ptr registers (reg_bank) | +~2k µm² |
| Add diagnostic read mode (psram_buf_ctrl) | +~6k µm² |
| **Net** | **~−62k µm²** |

---

## Interaction with existing features

| Feature | Impact |
|---|---|
| AGC firmware loop | Replace `energy_snap` readback (reg 0x40–0x47) with firmware-computed energy from PSRAM. Same latency class — both are post-symbol. |
| Energy gating (`energy_gate_en`) | Remove or disable permanently. Energy gating is off by default and rarely used. |
| `sigma2_hw` in reg_bank | Replace with firmware-written values via `sigma2_sw` path (already exists in reg_bank). |
| Packet replay path | Diagnostic read is a separate mode — does not conflict with replay. Both use same QPI read state machine; arbitration needed if both active simultaneously (unlikely: diagnostic runs pre-replay, replay runs post-W_commit). |
| `noise_floor_est` | Already removed from design. Not affected. |

---

## Open items

1. **Confirm `buf_base` is readable by firmware** before attempting noise_start calculation. Currently `buf_base` is internal to `psram_buf_ctrl` — may need to be exposed via reg_bank or computed from `timing_ref` + `wr_ptr` in firmware.

2. **Arbitration between diagnostic read and live PSRAM write.** During the noise readback, the decimator continues writing. If both try to access PSRAM simultaneously, the write should win (to avoid dropping live samples). The existing state machine must gate the diagnostic read on write-idle cycles.

3. **NR=2 byte layout confirmation.** Verify that bytes 0–3 per sample are consistently `i_ant0, q_ant0, i_ant1, q_ant1` in `psram_buf_ctrl` for NR=2 build.

4. **Division for NW-MRC weights.** PicoRV32IM has hardware multiply but no divide. Use `__udivsi3` from libgcc (available for RV32IM), or round σ²_j to nearest power of two and use arithmetic right-shift.
