# Fast A/B for bench SI changes (probe load, series resistor): only the informative lines, one per
# key transition, N reps each at random aligned addresses. Prints pass counts per line and appends
# caps/2026-11-18/quick_<tag>.jsonl.  Usage: python3 quick_load.py <tag> [reps]
import os, sys, json, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from psr import *
tag = sys.argv[1]; reps = int(sys.argv[2]) if len(sys.argv) > 2 else 20
rng = random.Random(5)
L = {'0F(4-rise)': 0x0F, '1F(3-rise->F)': 0x1F, '8F(3-rise->F)': 0x8F, '07(3-rise,slip)': 0x07,
     '0E(3-rise)': 0x0E, '03(2-rise)': 0x03}
REF = [0xA5, 0x5A, 0xDE, 0xAD, 0xBE, 0xEF, 0x10, 0x27]
wr(0x70, 0); res = {}
f = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'caps', '2026-11-18', f'quick_{tag}.jsonl'), 'a')
for r in range(reps):
    for name, b in list(L.items()) + ([('ref', None)] if r % 5 == 0 else []):
        a = rng.randrange(1, 0x800000 // 8 - 1) * 8; P = REF if b is None else [b] * 8
        pwrite(a, P); rb = pread(a); ok = rb == P
        res.setdefault(name, []).append(ok)
        f.write(json.dumps(dict(tag=tag, line=name, addr=a, read=rb, ok=ok)) + '\n')
print(tag, ' | '.join('%s %d/%d' % (n, sum(v), len(v)) for n, v in res.items()))
