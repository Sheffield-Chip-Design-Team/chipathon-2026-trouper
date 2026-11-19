# Write-vs-read discriminator: write a line between zero lines, then read it from shifted start
# addresses. A bad stored image reads the same from every start; a read-side fault follows the read.
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from psr import *
h = lambda l: ' '.join('%02X' % x for x in l)
wr(0x70, 0)
for P, a in (([0x0F]*8, 0x210000), ([0x00, 0x00, 0x00, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F], 0x210100)):
    pwrite(a-8, [0]*8); pwrite(a, P); pwrite(a+8, [0]*8)
    print('wrote', h(P), 'at %06X' % a)
    for d in (-3, -1, 0, 1, 2, 3, 4, 5):
        print('   read @%+d: %s' % (d, h(pread(a+d))))
