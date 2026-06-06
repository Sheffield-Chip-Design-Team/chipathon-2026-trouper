# Energy Measurement

RX path stage 3 support function inside the Schmidl-Cox / correlator path. See [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Computes per-antenna received power `Σ|x|²` over a sliding window of one symbol period.

This is still required, but it is no longer treated as a separate top-level detector block. Its outputs are used for:

- Schmidl-Cox normalization support
- AGC energy snapshot at correlator lock
- diagnostic/status readback

So the architectural role is:

- **energy measurement:** yes
- **standalone detector block:** no

---

## Interface

| Port | Direction | Width | Rate | Description |
| --- | --- | --- | --- | --- |
| `iq_i[3:0]` | in | 4×(12–16) signed | f_s | I samples from all 4 decimators (full precision; width TBD) |
| `iq_q[3:0]` | in | 4×(12–16) signed | f_s | Q samples from all 4 decimators |
| `iq_valid` | in | 1 | f_s | Sample strobe from decimators |
| `clk_16m` | in | — | 16 MHz | Master clock |
| `rst_n` | in | — | — | Active-low reset |
| `energy[3:0]` | out | 4×16 unsigned | per symbol | Σ\|x\|² per antenna, latched at end of symbol window |
| `energy_valid` | out | 1 | per symbol | Pulses high when `energy` outputs updated |
| `energy_snapshot_valid` | out | 1 | at lock / per symbol | Pulses when the exported energy values are updated or latched |

---

## Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| Window length | 2^SF samples (per symbol) | Runtime-configurable via `SF_CFG` register |
| Accumulator width | 28-bit internal, 32-bit output port | 8-bit inputs: max acc at SF12 = 4096×2×127² = 132M < 2^27. 28-bit unsigned (max 268M) gives 1 guard bit. Output `energy_sum` is zero-extended to 32-bit; `energy` is saturated to 16-bit. |
| Output width | 16-bit unsigned | Saturated `acc[27:12]` — top 16 bits of the 28-bit accumulator |

---

## Implementation notes

**No square root required.** `|x|² = I² + Q²` uses int8 multipliers (2 per antenna per sample = 8 total). These are the most expensive elements; share a single multiplier if gate budget is tight.

**Window alignment.** Symbol window derived from `iq_valid` count — reset accumulator every 2^SF valid samples. Must be synchronised with the correlator bank symbol clock.

**Integration location.** Implement this logic inside the Schmidl-Cox / correlator block or as a tightly coupled submodule. Do not treat it as a separate packet detector in the top-level RTL partition.

**Lock snapshot.** At `CORR_LOCK`, latch the current per-antenna energy values into the status registers so PicoRV32 AGC reads one packet-consistent snapshot.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Known amplitude sine | cocotb | `energy` matches Python `np.sum(np.abs(x)**2)` to ±2 LSB |
| Symbol-rate energy update | Count `energy_snapshot_valid` pulses | One per symbol period or correct lock-latched update behavior |
| Lock snapshot | Assert `CORR_LOCK` on known packet | Exported energy matches the expected symbol-window energy at lock |
| All 4 antennas independent | Different gains per channel | Each `energy[n]` matches per-channel Python reference |

---

## Related blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides int8 input
- [Correlator Bank](Correlator%20Bank.md) — owns the main acquisition path and should host this logic
- [AGC](AGC.md) — consumes the lock-latched per-antenna energy values
- [Register Map](../Register%20Map.md) — `ENERGY[0..3]` at `0x40`–`0x47`
