# PSRAM link scorecard: aligned write->read exactness (write path) + unaligned read offset sweep (read path).
import os, sys, collections, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from psr import *
nib = lambda bs: [n for b in bs for n in (b >> 4, b & 0xF)]
h = lambda l: ' '.join('%02X' % x for x in l)
random.seed(1)
wr(0x70, 0x00); wr(0x7A, 0x00)
pats = [[0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27], [0x0F]*8, [0xFF]*8, [0x00]*7+[0x01],
        [0x01,0x23,0x45,0x67,0x89,0xAB,0xCD,0xEF], [0x96,0x69,0x0F,0xF1,0xC3,0x3C,0x5A,0xA5]]
pats += [[random.randrange(256) for _ in range(8)] for _ in range(14)]
# 1) write path: aligned line write, aligned read x2 (aligned reads are the trusted path)
wok = 0; wfail = collections.Counter()
for i, P in enumerate(pats):
    a = 0x600000 + i * 0x40
    pwrite(a, P); r1 = pread(a); r2 = pread(a)
    if r1 == P and r2 == P: wok += 1
    else: wfail['%s -> %s / %s' % (h(P), h(r1), h(r2))] += 1
print('WRITE aligned exact: %d/%d' % (wok, len(pats)))
for k in wfail: print('   ', k)
# 2) read path: known 32-byte region, read at every start offset 0..16
region = [0]*8 + pats[0] + pats[5] + [0]*8; st = nib(region); tally = collections.Counter()
for base in (0x700000, 0x7A5A50):
    R = base - 8
    for k in range(0, 32, 8): pwrite(R + k, region[k:k+8])
    for x in range(0, 17):
        for _ in range(2):
            rn = nib(pread(R + x))
            o = [d for d in range(-6, 7) if 0 <= 2*x+d and 2*x+d+16 <= len(st) and st[2*x+d:2*x+d+16] == rn]
            tally[('exact' if o == [0] else ('slip%+d' % o[0]) if o else 'NONE')] += 1
print('READ offset sweep (68 reads):', dict(tally))
