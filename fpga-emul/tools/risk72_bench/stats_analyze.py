# Analyse stats_campaign.py output: classify each read, then estimate the per-transition abort hazard.
# Usage: python3 stats_analyze.py <run.jsonl> [more.jsonl ...] [--json summary.json]
import sys, json, collections
args = [a for a in sys.argv[1:] if not a.startswith('--')]
jout = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
if jout in args: args.remove(jout)
recs = [json.loads(l) for p in args for l in open(p) if l.strip()]
nib = lambda bs: [n for b in bs for n in (b >> 4, b & 0xF)]
pc = lambda x: bin(x).count('1')
WAIT = 0x0  # bus state before data nibble 0 (ILA: 0000 during the wait cycles)

def classify(exp, rx):
    e, r = nib(exp), nib(rx)
    if e == r: return 'pass', 16
    k = next(i for i in range(16) if e[i] != r[i])
    if k < 15 and len(set(r[k + 1:])) == 1: return 'abort_high' if r[-1] == 0xF else 'abort_const', k
    if k == 15: return 'last_nibble', k
    if r[:15] == e[1:] or r[1:] == e[:15]: return 'slip', k
    return 'other', k

kinds = collections.Counter(); bykind = collections.defaultdict(collections.Counter)
rep = collections.Counter(); tails = collections.Counter()
expo = collections.Counter(); ev = collections.Counter()           # keyed by (rise, fall)
pexpo = collections.Counter(); pev = collections.Counter()          # keyed by (from, to)
posexpo = collections.Counter(); posev = collections.Counter()      # keyed by nibble position
refs = []
for R in recs:
    c1, k1 = classify(R['exp'], R['r1']); c2, k2 = classify(R['exp'], R['r2'])
    rep['same' if R['r1'] == R['r2'] else 'differ'] += 1
    kinds[c1] += 1; bykind[R['kind']][c1] += 1
    if R['kind'] == 'ref': refs.append((R['t'], c1 == 'pass'))
    if c1 in ('abort_high', 'abort_const'): tails['%X' % nib(R['r1'])[-1]] += 1
    if c1 not in ('pass', 'abort_high', 'abort_const'): continue   # hazard model only for clean abort/pass reads
    e = nib(R['exp']); prev = [WAIT] + e[:-1]
    for i in range(min(k1, 15) + 1):
        a, b = prev[i], e[i]; key = (pc(~a & b & 0xF), pc(a & ~b & 0xF))
        hit = (i == k1)
        expo[key] += 1; ev[key] += hit
        pexpo[(a, b)] += 1; pev[(a, b)] += hit
        posexpo[i] += 1; posev[i] += hit

N = len(recs)
print(f'{N} reads (first read of each trial classified; second read used for repeatability)')
print('classes:', dict(kinds))
for k, c in bykind.items(): print(f'  {k:6s}', dict(c), ' pass %.1f%%' % (100 * c['pass'] / sum(c.values())))
print('r1 vs r2:', dict(rep))
print('abort tail value:', dict(tails))
print('\nabort hazard by transition into the nibble (lines rising, lines falling):')
print(' rise\\fall' + ''.join('%14d' % f for f in range(5)))
for r in range(5):
    row = ''
    for f in range(5):
        n = expo[(r, f)]
        row += '%14s' % (('%5.1f%% /%5d' % (100 * ev[(r, f)] / n, n)) if n else '-')
    print('%9d' % r + row)
byrise = {r: (sum(ev[(r, f)] for f in range(5)), sum(expo[(r, f)] for f in range(5))) for r in range(5)}
print('\nby lines rising:', {r: '%.1f%% (%d/%d)' % (100 * e_ / n, e_, n) for r, (e_, n) in byrise.items() if n})
print('by nibble position:', {i: '%.1f%%' % (100 * posev[i] / posexpo[i]) for i in range(16) if posexpo[i]})
worst = sorted(((pev[k] / pexpo[k], k) for k in pexpo if pexpo[k] >= 5), reverse=True)[:12]
print('worst nibble transitions (from->to, hazard, n):', ['%X->%X %.0f%% n=%d' % (k[0], k[1], 100 * h, pexpo[k]) for h, k in worst])
diag = collections.defaultdict(collections.Counter)
for R in recs:
    if 'rm1' not in R: continue
    c1, _ = classify(R['exp'], R['r1']); P = R['exp']
    ok = R['rm1'] == [0] + P[:7] or R['rp1'] == P[1:] + [0]
    diag[c1]['stored OK (read-side fault)' if ok else 'no shifted read exact'] += 1
if diag: print('write-vs-read discriminator on failing trials:', {k: dict(v) for k, v in diag.items()})
if refs: print('reference line: %d/%d pass; fails at t=' % (sum(p for _, p in refs), len(refs)), [t for t, p in refs if not p][:10])
if jout:
    json.dump(dict(N=N, classes=kinds, rep=rep,
                   hazard={f'{r},{f}': [ev[(r, f)], expo[(r, f)]] for r in range(5) for f in range(5) if expo[(r, f)]},
                   pairs={f'{a:X}{b:X}': [pev[(a, b)], pexpo[(a, b)]] for (a, b) in pexpo},
                   pos={i: [posev[i], posexpo[i]] for i in posexpo}), open(jout, 'w'))
