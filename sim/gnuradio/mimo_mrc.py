#!/usr/bin/env python3
"""
MIMO MRC LoRa receiver flowgraph — 4-branch receive diversity.

Architecture mirrors the ASIC pipeline in planning/blocks/:
  TX  : message_strobe → whitening (msg port) → lora_sdr TX chain → modulate
  CH  : NR independent channel_model blocks (flat Rayleigh fading + AWGN)
  DCR : DC Removal × NR  (IIR running-mean, DC_ALPHA_SHIFT=8)
  SAT : 8-bit saturation × NR  (Frontend Buffer SRAM path)
  MRC : per-branch weight application → MRCCombiner
  DEC : lora_sdr frame_sync → demodulate → decode → crc_verif

Weight modes
------------
  oracle   — ideal CSI: w_j = conj(h_j)/Σ|h_k|²  (upper-bound, default)
  training — estimate weights from preamble via training_accumulate_allpairs()
  bypass   — branch 0 only, no combining

Run:
    python3 mimo_mrc.py [--sf SF] [--snr SNR_dB] [--nr NR] [--weights oracle|training|bypass]

Requires:
    PYTHONPATH=/usr/lib/python3.12/site-packages
"""

import sys
import argparse
import threading
import time
import os
import numpy as np
import signal

import pmt
from gnuradio import gr, blocks, channels
import gnuradio.lora_sdr as lora_sdr

_SIM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _SIM_DIR)
from models.training_accumulator import training_accumulate_allpairs
from models.weight_generation import WeightGenerator
from models.channel import rician_coefficients
from models.dc_removal import DCRemoval


# ---------------------------------------------------------------------------
# DC Removal block  (mirrors ASIC Stage 3 — planning/blocks/DC Removal.md)
# ---------------------------------------------------------------------------

class DCRemovalBlock(gr.sync_block):
    """
    Per-branch IIR running-mean DC removal.

    Wraps models.dc_removal.DCRemoval for use in a GNU Radio streaming graph.
    Processes one branch at a time (one complex64 stream in, one out).
    DC state is maintained across work() calls to model the continuous IIR.

    Mirrors the ASIC hardware equation:
        dc_est += (x[n] - dc_est) >> DC_ALPHA_SHIFT
        out[n]  = x[n] - dc_est
    """

    def __init__(self, alpha_shift: int = 8):
        gr.sync_block.__init__(
            self,
            name="DC Removal",
            in_sig=[np.complex64],
            out_sig=[np.complex64],
        )
        self._dcr = DCRemoval(nr=1, alpha_shift=alpha_shift)

    def work(self, input_items, output_items):
        n = len(input_items[0])
        # DCRemoval expects (NR, N); wrap single branch as (1, N)
        samples = input_items[0][:n].astype(np.complex128).reshape(1, n)
        out = self._dcr.process(samples)   # (1, N)
        output_items[0][:n] = out[0].astype(np.complex64)
        return n


# ---------------------------------------------------------------------------
# 8-bit saturation block  (mirrors ASIC Frontend Buffer — 8-bit saturated path)
# ---------------------------------------------------------------------------

class Saturate8BitBlock(gr.sync_block):
    """
    Saturate complex64 samples to 8-bit signed range (−127 to +127) per I/Q.

    Models the Frontend Buffer Controller's 8-bit saturated SRAM storage
    described in planning/blocks/Frontend Buffer Controller.md.

    Per the spec, saturation is applied AFTER DC removal and is used for
    training accumulator input (not the full-precision combiner path).
    Scale factor maps the expected signal amplitude to ~half the 8-bit range
    so headroom is preserved before saturation clips.
    """

    def __init__(self, scale: float = 64.0):
        gr.sync_block.__init__(
            self,
            name="Saturate 8-bit",
            in_sig=[np.complex64],
            out_sig=[np.complex64],
        )
        self.scale = scale

    def work(self, input_items, output_items):
        n = len(input_items[0])
        x = input_items[0][:n] * self.scale
        re = np.clip(np.round(x.real), -127, 127).astype(np.float32)
        im = np.clip(np.round(x.imag), -127, 127).astype(np.float32)
        output_items[0][:n] = (re + 1j * im).astype(np.complex64)
        return n


# ---------------------------------------------------------------------------
# MRC weight block — training-accumulator path
# ---------------------------------------------------------------------------

class MRCWeightBlock(gr.sync_block):
    """
    Per-branch weight application via preamble training accumulation.

    Buffers NR IQ streams, detects the preamble via SC energy metric,
    runs training_accumulate_allpairs() at preamble end, then applies the
    already-conjugated weights directly per branch.

    Inputs  : NR complex64 streams
    Outputs : NR complex64 streams (weighted)
    """

    def __init__(self, NR: int, M: int, preamble_len: int, ref_sel: int, mode: str,
                 sc_hits_req: int = 2, sat_scale: float = 1.0):
        gr.sync_block.__init__(
            self,
            name="MRC Weights (training)",
            in_sig=[np.complex64] * NR,
            out_sig=[np.complex64] * NR,
        )
        self.NR = NR
        self.M = M
        self.sf = int(round(np.log2(M)))
        self.preamble_len = preamble_len
        self.ref_sel = ref_sel
        self.mode = mode
        self.sc_hits_req = sc_hits_req
        self.sat_scale   = sat_scale

        self._buf = [[] for _ in range(NR)]
        # Initial bypass weights: equal across branches, normalised by sat_scale
        # so combiner output amplitude matches oracle path (≈ unit amplitude signal)
        self._w = np.ones(NR, dtype=np.complex64) / (NR * sat_scale)
        self._trained = False
        self._sc_lock_sample = None
        self._timing_ref = None
        self._train_done_at = None
        self._sc_search_start = 0   # resume scan from here on next work() call
        self._noise_floor = None    # estimated once from first 2*M samples

    def _sc_detect(self, ref: np.ndarray):
        """
        Schmidl-Cox energy detector with sc_hits_req consecutive-match requirement
        and an adaptive energy threshold to reject noise-floor false locks.

        Uses cumsum for O(N) sliding-window energy — avoids O(N×M) inner loop.
        Scans only new samples (from self._sc_search_start) each work() call.
        Lock fires after sc_hits_req+1 consecutive ratio-passing windows.
        timing_ref is back-calculated to symbol 0.
        """
        M = self.M
        hits_needed = self.sc_hits_req + 1
        start = self._sc_search_start

        if len(ref) < start + (hits_needed + 2) * M:
            return None

        # Estimate noise floor once from first 2*M samples (pre-signal silence)
        if self._noise_floor is None and len(ref) >= 2 * M:
            self._noise_floor = float(np.mean(np.abs(ref[:2 * M]) ** 2))
        if self._noise_floor is None:
            return None

        # Absolute minimum energy per sample: 1% of expected full-scale power.
        # Prevents false locks when noise_floor ≈ 0 (e.g. real captures at
        # minimum gain where the pre-packet region is near-digital-zero).
        abs_min = (self.sat_scale * 0.1) ** 2
        energy_thresh = max(self._noise_floor, abs_min) * 10.0

        # O(N) sliding-window energy via cumsum
        power = np.abs(ref[start:]) ** 2
        cs    = np.concatenate(([0.0], np.cumsum(power)))
        n_pos = len(power) - 2 * M

        if n_pos <= 0:
            return None

        consecutive    = 0
        first_match_i  = None

        for k in range(n_pos):
            i  = start + k          # absolute index in ref
            e1 = float(cs[k + M]     - cs[k])
            e2 = float(cs[k + 2 * M] - cs[k + M])

            # Energy gate: reject windows below noise threshold
            if e1 < energy_thresh * M:
                consecutive   = 0
                first_match_i = None
                continue

            if e1 > 0 and abs(e2 / e1 - 1.0) < 0.25:
                if consecutive == 0:
                    first_match_i = i
                consecutive += 1
                if consecutive >= hits_needed:
                    sc_lock    = i + 2 * M
                    timing_ref = max(0, first_match_i - M)
                    return sc_lock, timing_ref
            else:
                consecutive   = 0
                first_match_i = None

        # Advance search start so next call doesn't re-scan processed samples
        self._sc_search_start = max(start, len(ref) - 2 * M)
        return None
        return None

    def work(self, input_items, output_items):
        n = len(input_items[0])
        for j in range(self.NR):
            self._buf[j].extend(input_items[j][:n].tolist())

        if not self._trained and self._sc_lock_sample is None:
            result = self._sc_detect(np.array(self._buf[self.ref_sel]))
            if result is not None:
                self._sc_lock_sample, self._timing_ref = result
                self._train_done_at = self._timing_ref + self.preamble_len * self.M

        if (not self._trained
                and self._train_done_at is not None
                and len(self._buf[self.ref_sel]) > self._train_done_at):
            raw_j = np.array([np.array(b) for b in self._buf])
            W_k, n_acc = training_accumulate_allpairs(
                raw_j,
                sc_lock_sample=self._sc_lock_sample,
                timing_ref=self._timing_ref,
                M=self.M,
                preamble_len=self.preamble_len,
            )
            wgen = WeightGenerator(mode=self.mode)
            w, _ = wgen.process(W_k, sf=self.sf)
            # Divide by sat_scale to match oracle weight normalisation
            self._w = (w / self.sat_scale).astype(np.complex64)
            self._trained = True
            print(f"[MRCWeightBlock] trained n_acc={n_acc}  "
                  f"|w_j|={np.abs(self._w * self.sat_scale).round(3)}")

        for j in range(self.NR):
            output_items[j][:n] = input_items[j][:n] * self._w[j]
        return n


# ---------------------------------------------------------------------------
# Combiner
# ---------------------------------------------------------------------------

class MRCCombiner(gr.sync_block):
    """Sum NR complex streams: y[n] = Σ_j weighted_j[n]."""

    def __init__(self, NR: int):
        gr.sync_block.__init__(
            self,
            name="MRC Combiner",
            in_sig=[np.complex64] * NR,
            out_sig=[np.complex64],
        )
        self.NR = NR

    def work(self, input_items, output_items):
        n = len(input_items[0])
        out = np.zeros(n, dtype=np.complex64)
        for j in range(self.NR):
            out += input_items[j][:n]
        output_items[0][:n] = out
        return n


# ---------------------------------------------------------------------------
# Top-level flowgraph
# ---------------------------------------------------------------------------

class MIMOMRCFlowgraph(gr.top_block):

    def __init__(
        self,
        sf: int = 7,
        bw: int = 125000,
        snr_db: float = 10.0,
        NR: int = 4,
        cr: int = 1,
        preamble_len: int = 8,
        impl_head: bool = False,
        has_crc: bool = True,
        ldro: int = 0,
        center_freq: int = 868100000,
        pay_len: int = 16,
        payload: str = "Hello MIMO MRC!",
        weight_mode: str = "oracle",
        ref_sel: int = 0,
        combining_mode: str = "mrc",
    ):
        gr.top_block.__init__(self, "MIMO MRC LoRa", catch_exceptions=True)

        M = 2 ** sf
        samp_rate = bw * 4
        os_factor = samp_rate // bw
        soft_decoding = False
        sync_word = 0x12

        # Random Rayleigh channel coefficients
        h = rician_coefficients(NR, K=0.0, pll_phase_random=True)
        h_norm = h / np.sqrt(np.mean(np.abs(h) ** 2))
        print(f"Channel  |h_j| = {np.abs(h_norm).round(3)}")

        S = float(np.sum(np.abs(h_norm) ** 2))
        w_oracle = np.conj(h_norm) / S
        print(f"Oracle   |w_j| = {np.abs(w_oracle).round(3)}")

        noise_voltage = 10 ** (-snr_db / 20.0)

        # ------------------------------------------------------------------
        # TX chain — message_strobe drives whitening via msg port
        # ------------------------------------------------------------------
        inter_frame_pad = int(20 * M * samp_rate / bw)

        self.msg_strobe    = blocks.message_strobe(pmt.intern(payload), 500)
        self.tx_whitening  = lora_sdr.whitening(False, True, ",", "packet_len")
        self.tx_header     = lora_sdr.header(impl_head, has_crc, cr)
        self.tx_crc        = lora_sdr.add_crc(has_crc)
        self.tx_hamming    = lora_sdr.hamming_enc(cr, sf)
        self.tx_interleaver= lora_sdr.interleaver(cr, sf, ldro, bw)
        self.tx_gray_demap = lora_sdr.gray_demap(sf)
        self.tx_modulate   = lora_sdr.modulate(sf, int(samp_rate), bw,
                                                [sync_word], inter_frame_pad, preamble_len)
        self.tx_modulate.set_min_output_buffer(10_000_000)
        self.tx_delay      = blocks.delay(gr.sizeof_gr_complex, int(M * samp_rate / bw * 10.1))
        self.tx_throttle   = blocks.throttle(gr.sizeof_gr_complex, float(samp_rate), True)

        # msg_strobe → whitening msg port (message connection)
        self.msg_connect((self.msg_strobe, "strobe"), (self.tx_whitening, "msg"))

        # TX stream chain
        self.connect(self.tx_whitening,   self.tx_header)
        self.connect(self.tx_header,      self.tx_crc)
        self.connect(self.tx_crc,         self.tx_hamming)
        self.connect(self.tx_hamming,     self.tx_interleaver)
        self.connect(self.tx_interleaver, self.tx_gray_demap)
        self.connect(self.tx_gray_demap,  self.tx_modulate)
        self.connect(self.tx_modulate,    self.tx_delay)
        self.connect(self.tx_delay,       self.tx_throttle)

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
            cm.set_min_output_buffer(int((M + 2) * samp_rate / bw))
            self.ch.append(cm)
            self.connect(self.tx_throttle, cm)

        # ------------------------------------------------------------------
        # Stage 3: DC Removal × NR  (ASIC: IIR running-mean, DC_ALPHA_SHIFT=8)
        # Stage 4: 8-bit saturation × NR  (ASIC: Frontend Buffer 8-bit SRAM path)
        #
        # DC removal runs on the full-precision channel output.
        # Saturation is applied after DC removal, matching the ASIC pipeline
        # where the Frontend Buffer stores 8-bit saturated samples.
        # The combiner uses the saturated stream; oracle weights are rescaled
        # by 1/scale so the combined amplitude stays in the original range.
        # ------------------------------------------------------------------
        sat_scale = 64.0   # maps unit-amplitude signal to ~64 counts (half 8-bit range)

        self.dc_removal  = [DCRemovalBlock(alpha_shift=8) for _ in range(NR)]
        self.saturate    = [Saturate8BitBlock(scale=sat_scale) for _ in range(NR)]

        for j in range(NR):
            self.connect(self.ch[j], self.dc_removal[j], self.saturate[j])

        # Convenience: saturated output per branch
        sat = self.saturate   # sat[j] is the block whose output feeds MRC

        # ------------------------------------------------------------------
        # MRC combining
        # ------------------------------------------------------------------
        if weight_mode == "oracle":
            # Rescale oracle weights to account for sat_scale applied to signal
            w_scaled = w_oracle / sat_scale
            self.weighted = []
            for j in range(NR):
                mul = blocks.multiply_const_cc(complex(w_scaled[j]))
                self.weighted.append(mul)
                self.connect(sat[j], mul)
            self.combiner = MRCCombiner(NR)
            for j in range(NR):
                self.connect(self.weighted[j], (self.combiner, j))

        elif weight_mode == "training":
            self.mrc_weights = MRCWeightBlock(
                NR=NR, M=M, preamble_len=preamble_len,
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
        # RX chain
        # ------------------------------------------------------------------
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

        # Critical feedback path: header_decoder → frame_sync
        self.msg_connect((self.rx_header_dec, "frame_info"),
                         (self.rx_frame_sync,  "frame_info"))

        self.rx_sink = blocks.vector_sink_b()
        self.connect(self.rx_crc_verif, self.rx_sink)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="MIMO MRC LoRa flowgraph")
    parser.add_argument("--sf",      type=int,   default=7)
    parser.add_argument("--bw",      type=int,   default=125000)
    parser.add_argument("--snr",     type=float, default=10.0)
    parser.add_argument("--nr",      type=int,   default=4)
    parser.add_argument("--cr",      type=int,   default=1)
    parser.add_argument("--payload", type=str,   default="Hello MIMO MRC!")
    parser.add_argument("--preamble",type=int,   default=8)
    parser.add_argument("--weights", type=str,   default="oracle",
                        choices=["oracle", "training", "bypass"])
    parser.add_argument("--mode",    type=str,   default="mrc",
                        choices=["mrc", "egc", "sc"])
    parser.add_argument("--runtime", type=float, default=5.0,
                        help="Seconds to run before stopping (default 5)")
    args = parser.parse_args()

    print(f"\nMIMO MRC LoRa  SF={args.sf}  BW={args.bw}  "
          f"SNR={args.snr} dB  NR={args.nr}  weights={args.weights}\n")

    tb = MIMOMRCFlowgraph(
        sf=args.sf,
        bw=args.bw,
        snr_db=args.snr,
        NR=args.nr,
        cr=args.cr,
        preamble_len=args.preamble,
        pay_len=len(args.payload.encode()),
        payload=args.payload,
        weight_mode=args.weights,
        combining_mode=args.mode,
    )

    def _stop(sig=None, frame=None):
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    tb.start()

    # Auto-stop after runtime seconds
    def _auto_stop():
        time.sleep(args.runtime)
        tb.stop()

    t = threading.Thread(target=_auto_stop, daemon=True)
    t.start()
    tb.wait()

    decoded = bytes(tb.rx_sink.data())
    print(f"\nDecoded  ({len(decoded)} bytes): {decoded!r}")
    expected = args.payload.encode()
    if decoded and decoded[-len(expected):] == expected:
        print("PASS — payload matches")
    elif decoded:
        print(f"RECEIVED (may be partial/multi-frame): {decoded!r}")
        print(f"Expected: {expected!r}")
    else:
        print("FAIL — nothing decoded (try higher --snr or longer --runtime)")


if __name__ == "__main__":
    main()
