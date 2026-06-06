# Frontend Buffer Controller

RX path block. See [DSP Flow](../DSP%20Flow.md) and [Non-FFT LoRa Frontend Proposal](../Non-FFT%20LoRa%20Frontend%20Proposal.md) for context.

**Owner:** TBD
**Status:** RTL complete (`frontend_buf_ctrl.v`)

---

## Role

Provides the SC detector with a delayed copy of channel 0 IQ (one symbol period behind). Uses a **block-based fixed-L buffer** — stores the first L = min(M, 256) samples of each symbol block in SRAM0, then ignores the rest of the symbol. On `sc_lock`, the block pointer is used by `psram_buf_ctrl` to back-calculate `buf_base` for the PSRAM same-packet replay path.

This block owns:

- block counter (`blk_cnt`, 0..M-1)
- SRAM0 read/write sequencing for channel 0 only
- `delayed_valid` gating
- pass-through of current samples (all 4 channels) to downstream blocks

Training accumulation receives live decimator samples independently; it does not read from this SRAM.

---

## Block-Based Design

### L = min(M, 256)

| SF | M | L (stored) | SRAM used | Integration loss vs full symbol |
|---|---|---|---|---|
| SF6 | 64 | 64 | 128 B | 0 dB (full symbol) |
| SF7 | 128 | 128 | 256 B | 0 dB (full symbol) |
| SF8 | 256 | 256 | 512 B | 0 dB (full symbol) |
| SF9 | 512 | 256 | 512 B | −3 dB |
| SF10 | 1024 | 256 | 512 B | −6 dB |
| SF11 | 2048 | 256 | 512 B | −9 dB |
| SF12 | 4096 | 256 | 512 B | −12 dB |

**One 512×8 SRAM macro (SRAM0) supports all SFs.** SRAM1 is not used.

The integration loss at SF9–SF12 is acceptable: the preamble has 8+ repeated upchirps, so the SC detector gets multiple consecutive correlation opportunities per packet. The downstream timing refiner resolves coarse timing.

### Memory layout (channel 0 only)

```
SRAM0 address 2k+0 : ch0_I[k]   (i0 of block sample k)
SRAM0 address 2k+1 : ch0_Q[k]   (q0 of block sample k)

k = 0..L-1, max L = 256, max address = 511
```

### Access protocol

Per `iq_valid` during store phase (`blk_cnt < L`):

```
Sub-cycle 0-1 : Read ch0_I from SRAM0 at addr 2*blk_cnt       (del_i0)
Sub-cycle 2-3 : Read ch0_Q from SRAM0 at addr 2*blk_cnt+1     (del_q0)
Sub-cycle 4   : Latch del_i0, del_q0; assert delayed_valid if block_ready
Sub-cycle 5-6 : Write cur_i0 to SRAM0 at addr 2*blk_cnt
Sub-cycle 7-8 : Write cur_q0 to SRAM0 at addr 2*blk_cnt+1
```

During ignore phase (`blk_cnt >= L`): SRAM idle, `delayed_valid` deasserted.

**8 sub-cycles per sample** (was 16 in the old 4-channel design).

### Timing

| R | f_s | Cycles/iq_valid | SRAM active | Margin |
|---|---|---|---|---|
| 256 | 125 kHz | 256 | 9 | 247 |
| 128 | 250 kHz | 128 | 9 | 119 |
| 64 | 500 kHz | 64 | 9 | 55 |
| 32 | 1 MS/s | 32 | 9 | 23 |

---

## Interface

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | 32 MHz system clock |
| `rst_n` | in | 1 | Active-low reset |
| `iq_valid` | in | 1 | Decimator sample strobe |
| `in_i0..in_i3` | in | 4×8 | DC-removed I samples, all 4 branches |
| `in_q0..in_q3` | in | 4×8 | DC-removed Q samples, all 4 branches |
| `sf` | in | 4 | Spreading factor (sets M = 2^sf) |
| `sc_lock` | in | 1 | From SC detector; gates delayed_valid |
| `buf_freeze` | in | 1 | Freeze write pointer (from packet_ctrl_fsm) |
| `sram0_*` | — | — | SRAM0 A/D/Q/CEN/GWEN (512×8) |
| `sram1_*` | — | — | SRAM1 interface (deasserted, unused) |
| `cur_i0..cur_i3` | out | 4×8 | Current samples pass-through (all branches) |
| `cur_q0..cur_q3` | out | 4×8 | Current Q pass-through |
| `del_i0` | out | 8 | Delayed I, channel 0 (from SRAM, L samples ago) |
| `del_q0` | out | 8 | Delayed Q, channel 0 |
| `del_i1..del_i3` | out | 4×8 | Unused (tied 0); sc_detector uses ch0 only |
| `del_q1..del_q3` | out | 4×8 | Unused (tied 0) |
| `delayed_valid` | out | 1 | Delayed sample valid (store phase AND block_ready) |
| `buf_mode` | out | 2 | 0=idle, 1=acquiring, 2=locked, 3=post-lock |
| `buf_valid` | out | 1 | `block_ready` — one full symbol period has elapsed |
| `wr_ptr` | out | 7 | `blk_cnt[6:0]` for status readback |

---

## Parameters

| Parameter | Value | Notes |
|---|---|---|
| `L_max` | 256 | Fixed maximum block size; L = min(M, 256) |
| `STORE_W` | 8 | Bits per I or Q component; matches decimator output |
| Channels stored | 1 (ch0) | Only i0, q0 in SRAM. SC detector uses ch0 only. |
| SRAM macros | 1 (SRAM0) | SRAM1 interface present but always disabled |
| `SF` range | SF6–SF12 | All supported with one 512×8 macro |

---

## Deprecated Content

### Optional CPU SRAM borrow mode

> **DEPRECATED — DO NOT IMPLEMENT**
>
> The block-based fixed-L=256 buffer fits in one 512×8 SRAM macro for all SFs.
> CPU memory sharing is not needed. `CPU_SRAM_BORROW_EN` and all borrow-path
> logic are removed. See [Memory Strategy](../Memory%20Strategy.md) for rationale.

---

## Related Blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides `iq_valid` and input samples
- [SC Detector](SC%20Detector.md) — consumes `cur_i0/q0`, `del_i0/q0`, `delayed_valid`
- [PSRAM Buffer Controller](PSRAM%20Buffer%20Controller.md) — uses `iq_sample_cnt` and `timing_ref` at `sc_lock` to compute `buf_base` for same-packet replay
- [Memory Strategy](../Memory%20Strategy.md) — SRAM macro selection and BIST policy
