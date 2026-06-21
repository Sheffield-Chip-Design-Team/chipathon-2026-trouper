"""
Embedded Python Blocks:

Each time this file is saved, GRC will instantiate the first class it finds
to get ports and parameters of your block. The arguments to __init__  will
be the parameters. All of them are required to have default values!
"""

import numpy as np
from gnuradio import gr


class SD3(gr.sync_block):  # other base classes are basic_block, decim_block, interp_block
    """3rd-Order Sigma-Delta Modulator Block"""

    def __init__(self, a1=1.0, a2=1.0, a3=1.0, b1=1.0, b2=0.0, b3=0.0, b4=0.0, c1=1.0, c2=1.0, c3=1.0):
        """
        Args:
            a1: Gain for the 1st integrator.
            a2: Gain for the 2nd integrator.
            a3: Gain for the 3rd integrator.
            b1: Gain for the 1st input.
            b2: Gain for the 2nd input.
            b3: Gain for the 3rd input.
            b4: Gain for the 4th input.
            c1: Gain for the negative feedback.
            c2: Feedforward gain between integrator 1 and integrator 2.
            c3: Feedforward gain between integrator 2 and integrator 3.
        """
        gr.sync_block.__init__(
            self,
            name='Sigma-Delta Order 3',   # will show up in GRC
            in_sig=[np.float32],
            out_sig=[np.float32]
        )
        # if an attribute with the same name as a parameter is found,
        # a callback is registered (properties work, too).
        self.a1 = a1
        self.a2 = a2
        self.a3 = a3
        self.b1 = b1
        self.b2 = b2
        self.b3 = b3
        self.b4 = b4
        self.c1 = c1
        self.c2 = c2
        self.c3 = c3
        
        self.i1 = 0.0
        self.i1_prev = 0.0
        self.i2 = 0.0
        self.i2_prev = 0.0
        self.i3 = 0.0
        self.i3_prev = 0.0


    def work(self, input_items, output_items):
        """example: multiply with constant"""
        in_sig = input_items[0]
        out_sig = output_items[0]

        for i in range(len(in_sig)):
            x = in_sig[i - 1] if i > 0 else 0.0

            prev_out = out_sig[i-1] if i > 0 else 0.0

            # Update integrator variable
            int1_in = x * self.b1 - self.c1 * prev_out
            self.i1 = self.i1_prev + int1_in

            int2_in = x * self.b2 + self.c2 * self.i1
            self.i2 = self.i2_prev + int2_in

            int3_in = x * self.b3 + self.c3 * self.i2
            self.i3 = self.i3_prev + int3_in

            sigma = self.a1 * self.i1 + self.a2 * self.i2 + self.a3 * self.i3 + self.b4 * x

            out_sig[i] = 1.0 if sigma > 0 else -1.0

            self.i1_prev = self.i1
            self.i2_prev = self.i2
            self.i3_prev = self.i3

        return len(out_sig)
