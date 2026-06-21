from __future__ import division
from deltasigma import *

import numpy as np
from matplotlib.pyplot import *

order = 5
OSR = 32

# Synthesize!
H0 = synthesizeNTF(order, OSR, opt=0)
# 1. Plot the singularities.
subplot(121)
plotPZ(H0, markersize=5)
title('NTF Poles and Zeros')
f = np.concatenate((np.linspace(0, 0.75/OSR, 100), np.linspace(0.75/OSR, 0.5, 100)))
z = np.exp(2j*np.pi*f)
magH0 = dbv(evalTF(H0, z))
# 2. Plot the magnitude responses.
subplot(222)
plot(f, magH0)
figureMagic([0, 0.5], 0.05, None, [-100, 10], 10, None, (16, 8))
xlabel('Normalized frequency ($1\\rightarrow f_s)$')
ylabel('dB')
title('NTF Magnitude Response')
# 3. Plot the magnitude responses in the signal band.
subplot(224)
fstart = 0.01
f = np.linspace(fstart, 1.2, 200)/(2*OSR)
z = np.exp(2j*np.pi*f)
magH0 = dbv(evalTF(H0, z))
semilogx(f*2*OSR, magH0)
axis([fstart, 1.2, -100,- 30])
grid(True)
sigma_H0 = dbv(rmsGain(H0, 0, 0.5/OSR))
#semilogx([fstart, 1], sigma_H0*np.array([1, 1]))
semilogx([fstart, 1], sigma_H0*np.array([1, 1]),'-o')
text(0.15, sigma_H0 + 5, 'rms gain = %5.0fdB' % sigma_H0)
xlabel('Normalized frequency ($1\\rightarrow f_B$)')
ylabel('dB')
tight_layout()
show()
