#!/usr/bin/env python3
"""
MIMO MRC LoRa flowgraph using real hardware IQ captures.

Replaces the simulated lora_sdr TX chain with a real SDR capture from
sim/examples/*.iq. The single-antenna capture is replicated across NR
branches, each with an independent Rayleigh channel coefficient + AWGN,
simulating a 4-antenna receive array all seeing the same transmission.

Pipeline:
  FILE : uint8 offset-binary .iq at 1 MS/s → complex64 vector_source
  CH   : NR independent channel_model blocks (Rayleigh h_j + AWGN)
  DCR  : DC Removal × NR  (IIR, DC_ALPHA_SHIFT=8)
  SAT  : 8-bit saturation × NR  (Frontend Buffer SRAM path)
  MRC  : MRCWeightBlock (training accumulator) | oracle weights → MRCCombiner
  DEC  : lora_sdr frame_sync (os_factor=8) → decode → crc_verif

Sample rate: 1 MS/s  BW: 125 kHz  os_factor: 8  SF: 7

Run:
    python3 mimo_mrc_capture.py sim/examples/1_packet_mingain.iq
    python3 mimo_mrc_capture.py sim/examples/5_packets_mingain.iq --weights oracle
    python3 mimo_mrc_capture.py sim/examples/1_packet_mingain.iq --weights training --snr 20

Requires:
    PYTHONPATH=/usr/lib/python3.12/site-packages
"""

import sys
import os
import argparse
import numpy as np
import signal

import pmt
from gnuradio import gr, blocks, channels
import gnuradio.lora_sdr as lora_sdr

_SIM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SIM_DIR)
from models.channel import rician_coefficients

# Import shared blocks from mimo_mrc
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mimo_mrc import DCRemovalBlock, Saturate8BitBlock, MRCWeightBlock, MRCCombiner


# ---------------------------------------------------------------------------
# IQ file loading
# ---------------------------------------------------------------------------

def load_iq_capture(path: str) -> np.ndarray:
    """
    Load uint8 offset-binary IQ capture.

    Format: interleaved I Q bytes, 1 MS/s.
    Conversion: z = ((I - 127.5) + j*(Q - 127.5)) / 127.5
    """
    raw = np.fromfile(path, dtype=np.uint8)
    I = (raw[0::2].astype(np.float32) - 127.5) / 127.5
    Q = (raw[1::2].astype(np.float32) - 127.5) / 127.5
    return (I + 1j * Q).astype(np.complex64)


# ---------------------------------------------------------------------------
# Top-level flowgraph
# ---------------------------------------------------------------------------

class MIMOMRCCaptureFlowgraph(gr.top_block):

    def __init__(
        self,
        iq_data: np.ndarray,
        samp_rate: int = 1_000_000,
        bw: int = 125_000,
        sf: int = 7,
        snr_db: float = 20.0,
        NR: int = 4,
        center_freq: int = 868_100_000,
        weight_mode: str = "oracle",
        ref_sel: int = 0,
        combining_mode: str = "mrc",
        preamble_len: int = 8,
    ):
        gr.top_block.__init__(self, "MIMO MRC Capture", catch_exceptions=True)

        M = 2 ** sf
        os_factor = samp_rate // bw
        # Training accumulator window at 1 MS/s: one symbol = M * os_factor samples
        M_eff = M * os_factor
        sat_scale = 64.0

        # Rayleigh channel coefficients
        h = rician_coefficients(NR, K=0.0, pll_phase_random=True)
        h_norm = h / np.sqrt(np.mean(np.abs(h) ** 2))
        print(f"Channel  |h_j| = {np.abs(h_norm).round(3)}")

        S = float(np.sum(np.abs(h_norm) ** 2))
        w_oracle = np.conj(h_norm) / S
        print(f"Oracle   |w_j| = {np.abs(w_oracle).round(3)}")

        noise_voltage = 10 ** (-snr_db / 20.0)

        # ------------------------------------------------------------------
        # Source: real IQ capture as vector_source (plays once then stops)
        # ------------------------------------------------------------------
        self.src     = blocks.vector_source_c(iq_data.tolist(), repeat=False)
        self.throttle = blocks.throttle(gr.sizeof_gr_complex, float(samp_rate), True)
        self.connect(self.src, self.throttle)

        # ------------------------------------------------------------------
        # Channel: NR independent channel_model blocks
        # ------------------------------------------------------------------
        self.ch = []
        for j in range(NR):
            cm = channels.channel_model(
                noise_voltage=noise_voltage,
                frequency_offset=0.0,
                epsilon=1.0,
                taps=[complex(h_norm[j])],
                noise_seed=j,
                block_tags=True,
            )
            self.ch.append(cm)
            self.connect(self.throttle, cm)

        # ------------------------------------------------------------------
        # Stage 3+4: DC Removal + 8-bit saturation per branch
        # ------------------------------------------------------------------
        self.dc_removal = [DCRemovalBlock(alpha_shift=8) for _ in range(NR)]
        self.saturate   = [Saturate8BitBlock(scale=sat_scale) for _ in range(NR)]

        for j in range(NR):
            self.connect(self.ch[j], self.dc_removal[j], self.saturate[j])

        sat = self.saturate

        # ------------------------------------------------------------------
        # MRC combining
        # ------------------------------------------------------------------
        if weight_mode == "oracle":
            w_scaled = w_oracle / sat_scale
            self.weighted = []
            for j in range(NR):
                mul = blocks.multiply_const_cc(complex(np.conj(w_scaled[j])))
                self.weighted.append(mul)
                self.connect(sat[j], mul)
            self.combiner = MRCCombiner(NR)
            for j in range(NR):
                self.connect(self.weighted[j], (self.combiner, j))

        elif weight_mode == "training":
            # MRCWeightBlock operates at 1 MS/s; use M_eff = M * os_factor
            self.mrc_weights = MRCWeightBlock(
                NR=NR, M=M_eff, preamble_len=preamble_len,
                ref_sel=ref_sel, mode=combining_mode, sat_scale=sat_scale,
            )
            self.combiner = MRCCombiner(NR)
            for j in range(NR):
                self.connect(sat[j],                (self.mrc_weights, j))
                self.connect((self.mrc_weights, j), (self.combiner, j))

        else:  # bypass — branch 0 only
            null_src = [blocks.null_source(gr.sizeof_gr_complex) for _ in range(NR - 1)]
            self.combiner = MRCCombiner(NR)
            self.connect(sat[0], (self.combiner, 0))
            for j in range(1, NR):
                self.connect(null_src[j - 1], (self.combiner, j))
            for j in range(1, NR):
                self.connect(sat[j], blocks.null_sink(gr.sizeof_gr_complex))

        # ------------------------------------------------------------------
        # RX chain (1 MS/s, os_factor=8)
        # ------------------------------------------------------------------
        soft_decoding = False
        sync_word     = 0x12
        impl_head     = False
        has_crc       = True
        ldro          = 0
        cr            = 1
        pay_len       = 255   # unknown — use max; header_decoder reads from header

        self.rx_frame_sync    = lora_sdr.frame_sync(center_freq, bw, sf, impl_head,
                                                     [sync_word], os_factor, preamble_len)
        self.rx_fft_demod     = lora_sdr.fft_demod(soft_decoding, True)
        self.rx_gray_mapping  = lora_sdr.gray_mapping(soft_decoding)
        self.rx_deinterleaver = lora_sdr.deinterleaver(soft_decoding)
        self.rx_hamming_dec   = lora_sdr.hamming_dec(soft_decoding)
        self.rx_header_dec    = lora_sdr.header_decoder(impl_head, cr, pay_len,
                                                         has_crc, ldro, True)
        self.rx_dewhitening   = lora_sdr.dewhitening()
        self.rx_crc_verif     = lora_sdr.crc_verif(1, False)

        self.connect(self.combiner,         self.rx_frame_sync)
        self.connect(self.rx_frame_sync,    self.rx_fft_demod)
        self.connect(self.rx_fft_demod,     self.rx_gray_mapping)
        self.connect(self.rx_gray_mapping,  self.rx_deinterleaver)
        self.connect(self.rx_deinterleaver, self.rx_hamming_dec)
        self.connect(self.rx_hamming_dec,   self.rx_header_dec)
        self.connect((self.rx_header_dec, 0), self.rx_dewhitening)
        self.connect(self.rx_dewhitening,   self.rx_crc_verif)

        self.msg_connect((self.rx_header_dec, "frame_info"),
                         (self.rx_frame_sync,  "frame_info"))

        self.rx_sink = blocks.vector_sink_b()
        self.connect(self.rx_crc_verif, self.rx_sink)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="MIMO MRC LoRa flowgraph using real IQ captures"
    )
    parser.add_argument("capture",
                        help="Path to uint8 offset-binary .iq file (1 MS/s)")
    parser.add_argument("--snr",     type=float, default=20.0,
                        help="Per-branch SNR added on top of real capture (dB, default 20)")
    parser.add_argument("--nr",      type=int,   default=4,
                        help="Number of RX branches (default 4)")
    parser.add_argument("--weights", type=str,   default="oracle",
                        choices=["oracle", "training", "bypass"])
    parser.add_argument("--mode",    type=str,   default="mrc",
                        choices=["mrc", "egc", "sc"])
    parser.add_argument("--preamble",type=int,   default=8)
    args = parser.parse_args()

    print(f"\nMIMO MRC Capture  file={os.path.basename(args.capture)}  "
          f"NR={args.nr}  SNR={args.snr} dB  weights={args.weights}\n")

    print(f"Loading {args.capture} ...")
    iq = load_iq_capture(args.capture)
    print(f"  {len(iq):,} samples  ({len(iq)/1e6*1e3:.1f} ms @ 1 MS/s)\n")

    tb = MIMOMRCCaptureFlowgraph(
        iq_data      = iq,
        snr_db       = args.snr,
        NR           = args.nr,
        weight_mode  = args.weights,
        combining_mode = args.mode,
        preamble_len = args.preamble,
    )

    def _stop(sig=None, frame=None):
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    tb.start()
    tb.wait()   # vector_source terminates naturally at end of file

    decoded = bytes(tb.rx_sink.data())
    print(f"\nDecoded ({len(decoded)} bytes): {decoded!r}")
    if not decoded:
        print("Nothing decoded — try --snr 30 or check sync word / preamble length")


if __name__ == "__main__":
    main()
