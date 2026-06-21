"""
Embedded Python Blocks:

Each time this file is saved, GRC will instantiate the first class it finds
to get ports and parameters of your block. The arguments to __init__  will
be the parameters. All of them are required to have default values!
"""

import numpy as np
from gnuradio import gr


class SD1(gr.sync_block):  # other base classes are basic_block, decim_block, interp_block
    """1st-Order Sigma-Delta Modulator Block"""

    def __init__(self, a=1.0, b=1.0, c=1.0):  # only default arguments here
        """
        Args:
            a: Feedforward gain for the integrator
            b: Feedback gain for the integrator
            c: Gain for the previous output
        """
        gr.sync_block.__init__(
            self,
            name='Sigma-Delta Order 1',   # will show up in GRC
            in_sig=[np.float32],
            out_sig=[np.float32]
        )
        # if an attribute with the same name as a parameter is found,
        # a callback is registered (properties work, too).
        self.a = a
        self.b = b
        self.c = c

        self.i = 0.0
        self.i_prev = 0.0

    def work(self, input_items, output_items):
        """example: multiply with constant"""
        in_sig = input_items[0]
        out_sig = output_items[0]

        for i in range(len(in_sig)):
            x = in_sig[i - 1] if i > 0 else 0.0

            prev_out = out_sig[i-1] if i > 0 else 0.0

            int_in = x * self.b - self.c * prev_out
            # Update integrator variable
            self.i = self.i_prev + int_in

            sigma = self.a * self.i

            out_sig[i] = 1.0 if sigma > 0 else -1.0

            self.i_prev = self.i

        return len(out_sig)
