# UART Backup Interface

Control block. See [System Architecture](../System%20Architecture.md) for context.

**Owner:** TBD
**Status:** Planned

---

## Function

Provides a lightweight off-chip backup/control link for weight handoff when the on-chip control plane is unavailable or intentionally bypassed.

Primary uses:

- host-to-ASIC transfer of precomputed combining weights
- host readback of packet status and `Z_j`-related data for off-chip weight calculation
- debug / bring-up control when PicoRV32 is not trusted or is held in reset

This block is not a firmware-image loader and does not replace the existing SPI host interface for general register access.

The intended operating model is:

- the ASIC exposes `Z_j` and status through the normal register map
- an external host computes weights off chip
- the host transmits the weights over UART into the ASIC shadow bank
- the ASIC pulses `W_COMMIT` through the existing packet-control path

Important timing rule:

- without PSRAM replay, UART-provided weights can only affect the current payload if they arrive before the live payload boundary
- to apply UART-provided weights to the full packet, including the preamble, the optional PSRAM replay path must be enabled so the captured packet can be replayed from the start under the final weights

---

## Interface

The final pad assignment is still open. The planned logical signals are:

| Signal | Direction | Width | Description |
| --- | --- | --- | --- |
| `UART_RX` | in | 1 | Serial data from host |
| `UART_TX` | out | 1 | Serial data to host |
| `clk_16m` | in | 1 | Core/system clock |
| `rst_n` | in | 1 | Active-low reset |
| `rx_ready` | in | 1 | UART receiver can accept a byte |
| `rx_data` | out | 8 | Received byte to packet/control logic |
| `rx_valid` | out | 1 | Byte strobe from receiver |
| `tx_data` | in | 8 | Byte to transmit |
| `tx_valid` | in | 1 | Transmit request |
| `tx_ready` | out | 1 | Transmitter can accept a byte |

The physical pad pair is expected to come from the GPIO bank reservation noted in [Pinout](../Pinout.md).

---

## Protocol

The UART protocol should stay byte-oriented and deliberately simple.

Recommended framing:

- start byte
- opcode
- length
- payload
- CRC or checksum

Suggested opcodes:

- read packet status
- read `Z_j` snapshot
- write `W_SHADOW`
- pulse `W_COMMIT`
- read back `W_ACTIVE` or `W_VALID`
- abort / resync

Implementation rule:

- a malformed frame must not change `W_ACTIVE`
- a short or corrupted frame must be ignored or NACKed
- the host must be able to recover without resetting the whole ASIC

---

## Timing Model

UART is not a live-path weight generator by itself. It is a transport for off-chip weights, so its usability depends on the buffering architecture around it.

| Mode | Requirement | Outcome |
| --- | --- | --- |
| Live path, no PSRAM | UART must beat the payload boundary | Payload-only or next-packet use at best |
| Live path, with PSRAM disabled | No replay buffer exists | Same-packet full-packet use is not guaranteed |
| PSRAM replay enabled | Packet is captured, weights arrive later, replay starts from stored packet start | Full-packet same-packet use is supported |

The architectural meaning is simple: UART can deliver the weights; PSRAM decides whether the packet can still be replayed from the beginning.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Framing | Send valid and invalid frames | Valid frames accepted; invalid frames ignored |
| Weight write | Send a `W_SHADOW` payload | Shadow bank updates and `W_COMMIT` is pulsed only on complete frame |
| Status readback | Query packet and weight status | Host receives consistent `Z_j` / `W` metadata |
| Live-path timing | Send weights late without PSRAM | Current packet falls back to bypass or prior weights; no corruption |
| Replay timing | Send weights after capture with `PSRAM_EN=1` | Replay starts from the stored packet start under the final weights |
| Recovery | Switch back to CPU-managed mode | UART path stops driving new weights; register ownership remains coherent |
