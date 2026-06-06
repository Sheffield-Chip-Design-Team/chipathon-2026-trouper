#!/usr/bin/env python3
"""
MIMO MRC LoRa live RX flowgraph — RTL-SDR V4 input, Heltec V3 TX.

Receives live LoRa transmissions from the Heltec V3 (868.1 MHz, SF7,
BW 125 kHz) via the RTL-SDR V4 and decodes through the MIMO MRC pipeline.

Since we only have one physical antenna (RTL-SDR), NR>1 is simulated by
replicating the single live stream across NR branches with independent
Rayleigh channel coefficients + AWGN — same model as mimo_mrc_capture.py.
Set --nr 1 --weights bypass for single-antenna passthrough (real hardware only).

Pipeline:
  RX  : soapy.source (RTL-SDR via SoapySDR, 868.1 MHz, 1 MS/s)
  DCR : DC Removal  (IIR, DC_ALPHA_SHIFT=8)
  SAT : 8-bit saturation
  CH  : NR-1 simulated branches (channel_model × NR-1) + branch 0 = live
  MRC : MRCWeightBlock | oracle | bypass → MRCCombiner
  DEC : lora_sdr frame_sync → decode → crc_verif

Run:
    python3 mimo_mrc_rtlsdr.py
    python3 mimo_mrc_rtlsdr.py --nr 1 --weights bypass
    python3 mimo_mrc_rtlsdr.py --nr 4 --weights oracle --snr 20

Requires:
    PYTHONPATH=/usr/lib/python3.12/site-packages
    SoapySDR RTL-SDR driver (SoapyRTLSDR) installed
    Note: uses gnuradio.soapy (not gr-osmosdr) to avoid GR ABI version mismatch
"""

import sys
import os
import argparse
import signal
import numpy as np

import pmt
from gnuradio import gr, blocks, channels, soapy
import gnuradio.lora_sdr as lora_sdr

_SIM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SIM_DIR)
from models.channel import rician_coefficients

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mimo_mrc import DCRemovalBlock, Saturate8BitBlock, MRCWeightBlock, MRCCombiner


# ---------------------------------------------------------------------------
# Flowgraph
# ---------------------------------------------------------------------------

class MIMOMRCRTLSDRFlowgraph(gr.top_block):

    def __init__(
        self,
        freq_hz:      int   = 868_100_000,
        samp_rate:    int   = 1_000_000,
        bw:           int   = 125_000,
        sf:           int   = 7,
        gain:         float = 40.0,
        NR:           int   = 4,
        snr_db:       float = 20.0,
        weight_mode:  str   = "oracle",
        combining_mode: str = "mrc",
        preamble_len: int   = 8,
        ref_sel:      int   = 0,
    ):
        gr.top_block.__init__(self, "MIMO MRC RTL-SDR", catch_exceptions=True)

        M         = 2 ** sf
        os_factor = samp_rate // bw
        M_eff     = M * os_factor   # samples per symbol at samp_rate
        sat_scale = 64.0
        sync_word = 0x12
        impl_head = False
        has_crc   = True
        ldro      = 0
        cr        = 1
        pay_len   = 255

        # ------------------------------------------------------------------
        # RTL-SDR source via SoapySDR (avoids GR ABI version mismatch with gr-osmosdr)
        # ------------------------------------------------------------------
        self.rtlsdr = soapy.source("driver=rtlsdr", "fc32", 1, "", "", [""], [""])
        self.rtlsdr.set_sample_rate(0, samp_rate)
        self.rtlsdr.set_frequency(0, freq_hz)
        self.rtlsdr.set_gain(0, "TUNER", gain)
        print(f"RTL-SDR: {freq_hz/1e6:.3f} MHz  {samp_rate/1e6:.1f} MS/s  gain={gain} dB")

        # ------------------------------------------------------------------
        # Stage 3+4: DC Removal + 8-bit saturation on live branch
        # ------------------------------------------------------------------
        # ------------------------------------------------------------------
        # Simulated NR branches via channel_model — ALL branches go through
        # channel_model (including branch 0) so group delay is identical and
        # coherent MRC combining is aligned. Branch 0 uses h=1+0j (unity).
        # ------------------------------------------------------------------
        if NR > 1:
            h_all = rician_coefficients(NR - 1, K=0.0, pll_phase_random=True)
            h_all = h_all / np.sqrt(np.mean(np.abs(h_all) ** 2))
            h_all = np.concatenate([[1.0 + 0j], h_all])  # branch 0 = unity
        else:
            h_all = np.array([1.0 + 0j])

        noise_v = 10 ** (-snr_db / 20.0)
        print(f"Channel  |h_j| = {np.abs(h_all).round(3)}")

        self.ch  = []
        self.dc  = []
        self.sat = []
        for j in range(NR):
            cm = channels.channel_model(
                noise_voltage=noise_v if j > 0 else 0.0,  # no extra noise on live branch
                frequency_offset=0.0,
                epsilon=1.0,
                taps=[complex(h_all[j])],
                noise_seed=j,
                block_tags=True,
            )
            dc  = DCRemovalBlock(alpha_shift=8)
            sat = Saturate8BitBlock(scale=sat_scale)
            self.ch.append(cm)
            self.dc.append(dc)
            self.sat.append(sat)
            self.connect(self.rtlsdr, cm, dc, sat)

        # Bypass mode: skip channel_model entirely for single live branch
        if weight_mode == "bypass" or NR == 1:
            self.dc0  = DCRemovalBlock(alpha_shift=8)
            self.sat0 = Saturate8BitBlock(scale=sat_scale)
            self.connect(self.rtlsdr, self.dc0, self.sat0)

        sat_branches = self.sat

        # ------------------------------------------------------------------
        # MRC combining
        # ------------------------------------------------------------------
        if weight_mode == "bypass" or NR == 1:
            # Single live branch — bypass channel_model, pass straight through
            self.combiner = MRCCombiner(1)
            self.connect(self.sat0, (self.combiner, 0))
            # Discard all channel_model branches
            for j in range(NR):
                self.connect(sat_branches[j],
                             blocks.null_sink(gr.sizeof_gr_complex))

        elif weight_mode == "oracle":
            S = float(np.sum(np.abs(h_all) ** 2))
            w_oracle = np.conj(h_all) / S
            w_scaled = w_oracle / sat_scale
            print(f"Oracle   |w_j| = {np.abs(w_oracle).round(3)}")

            self.weighted = []
            for j in range(NR):
                mul = blocks.multiply_const_cc(complex(np.conj(w_scaled[j])))
                self.weighted.append(mul)
                self.connect(sat_branches[j], mul)
            self.combiner = MRCCombiner(NR)
            for j in range(NR):
                self.connect(self.weighted[j], (self.combiner, j))

        else:  # training — all branches through channel_model, timing aligned
            self.mrc_weights = MRCWeightBlock(
                NR=NR, M=M_eff, preamble_len=preamble_len,
                ref_sel=ref_sel, mode=combining_mode, sat_scale=sat_scale,
            )
            self.combiner = MRCCombiner(NR)
            for j in range(NR):
                self.connect(sat_branches[j],       (self.mrc_weights, j))
                self.connect((self.mrc_weights, j), (self.combiner, j))

        # ------------------------------------------------------------------
        # RX chain
        # ------------------------------------------------------------------
        self.rx_frame_sync    = lora_sdr.frame_sync(freq_hz, bw, sf, impl_head,
                                                     [sync_word], os_factor, preamble_len)
        self.rx_fft_demod     = lora_sdr.fft_demod(False, True)
        self.rx_gray_mapping  = lora_sdr.gray_mapping(False)
        self.rx_deinterleaver = lora_sdr.deinterleaver(False)
        self.rx_hamming_dec   = lora_sdr.hamming_dec(False)
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

        # Sink decoded bytes to terminal (crc_verif already prints rx msg)
        self.rx_sink = blocks.vector_sink_b()
        self.connect(self.rx_crc_verif, self.rx_sink)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="MIMO MRC live RX — RTL-SDR V4 + Heltec V3 TX"
    )
    parser.add_argument("--freq",    type=float, default=868.1,
                        help="Centre frequency MHz (default 868.1)")
    parser.add_argument("--gain",    type=float, default=40.0,
                        help="RTL-SDR gain dB (default 40)")
    parser.add_argument("--nr",      type=int,   default=1,
                        help="RX branches: 1=live only, >1=live+simulated (default 1)")
    parser.add_argument("--weights", type=str,   default="bypass",
                        choices=["bypass", "oracle", "training"])
    parser.add_argument("--mode",    type=str,   default="mrc",
                        choices=["mrc", "egc", "sc"])
    parser.add_argument("--snr",     type=float, default=20.0,
                        help="SNR for simulated extra branches dB (default 20)")
    parser.add_argument("--preamble",type=int,   default=8)
    args = parser.parse_args()

    print(f"\nMIMO MRC RTL-SDR  {args.freq} MHz  NR={args.nr}  "
          f"weights={args.weights}  gain={args.gain} dB\n")
    print("Waiting for Heltec V3 transmissions... (Ctrl-C to stop)\n")

    tb = MIMOMRCRTLSDRFlowgraph(
        freq_hz      = int(args.freq * 1e6),
        gain         = args.gain,
        NR           = args.nr,
        snr_db       = args.snr,
        weight_mode  = args.weights,
        combining_mode = args.mode,
        preamble_len = args.preamble,
    )

    def _stop(sig=None, frame=None):
        print(f"\nStopping — {len(tb.rx_sink.data())//7} packet(s) decoded total")
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    tb.start()
    tb.wait()


if __name__ == "__main__":
    main()
