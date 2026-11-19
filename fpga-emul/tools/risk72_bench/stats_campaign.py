# Statistical PSRAM link campaign (Open Risks #72, 2026-11-18).
# Each trial: write an 8-byte line at a random 8-byte-aligned address, read it back twice.
# Trial set: every nibble pair a->b as a line of byte (a<<4|b) repeated (x reps), then random lines,
# with the known-good reference line every REF_EVERY trials. Appends JSON lines to the output file.
# Usage: python3 stats_campaign.py <out.jsonl> [n_random] [pair_reps] [seed]
import os, sys, json, time, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from psr import *
out = sys.argv[1]
n_random = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
pair_reps = int(sys.argv[3]) if len(sys.argv) > 3 else 3
rng = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else 11)
REF = [0xA5, 0x5A, 0xDE, 0xAD, 0xBE, 0xEF, 0x10, 0x27]
REF_EVERY = 50
DIAG = os.environ.get('DIAG', '1') != '0'   # on a failing read, also read from a-1 / a+1
wr(0x70, 0x00); wr(0x7A, 0x00)
trials = [('pair', [(a << 4) | b] * 8) for a in range(16) for b in range(16) for _ in range(pair_reps)]
rng.shuffle(trials)
trials += [('random', [rng.randrange(256) for _ in range(8)]) for _ in range(n_random)]
t0 = time.time()
with open(out, 'a') as f:
    for i, (kind, P) in enumerate(trials):
        if i % REF_EVERY == 0:
            kind_, P_ = 'ref', REF
            a = rng.randrange(0, 0x800000 // 8) * 8
            pwrite(a, P_); r1 = pread(a); r2 = pread(a)
            f.write(json.dumps(dict(i=i, t=round(time.time() - t0, 2), kind=kind_, addr=a, exp=P_, r1=r1, r2=r2)) + '\n')
        a = rng.randrange(1, 0x800000 // 8 - 1) * 8
        pwrite(a, P); r1 = pread(a); r2 = pread(a)
        rec = dict(i=i, t=round(time.time() - t0, 2), kind=kind, addr=a, exp=P, r1=r1, r2=r2)
        if DIAG and r1 != P:
            # Write-vs-read discriminator: zero lines either side, then re-read from a-1 and a+1.
            # Expected if the stored line is correct: [00]+P[:7] and P[1:]+[00].
            pwrite(a - 8, [0] * 8); pwrite(a + 8, [0] * 8)
            rec['rm1'] = pread(a - 1); rec['rp1'] = pread(a + 1)
        f.write(json.dumps(rec) + '\n')
        f.flush()
        if i % 100 == 0:
            print('%5d/%d  %.0f s' % (i, len(trials), time.time() - t0), flush=True)
print('done', len(trials), 'trials in %.0f s' % (time.time() - t0))
