# Decode a RISK72_OVERSAMPLE ILA CSV (200 MHz, 5 ns/sample) of one QPI debug read.
# Prints a run-length view of ce_n / sck / sio_out / sio_in from CE# low to CE# high,
# then the sio_in nibble the FPGA would see at every SCK rising edge.
# risk72_trace bits: [31] ce_n, [30] sck, [29:26] sio_out, [25:22] sio_in,
#                    [2] dbg_mode, [1] dbg_wr_mode, [0] qpi_busy.
import csv, sys
rows = list(csv.reader(open(sys.argv[1])))
hdr = rows[0]
col = next(i for i, h in enumerate(hdr) if 'risk72_trace' in h)
data = [r for r in rows[1:] if r and r[0].strip().isdigit()]
v = [int(r[col], 16) for r in data]
f = lambda x: dict(ce=(x >> 31) & 1, sck=(x >> 30) & 1, out=(x >> 26) & 0xF, inp=(x >> 22) & 0xF)
s = [f(x) for x in v]
lo = [i for i, d in enumerate(s) if d['ce'] == 0]
if not lo: sys.exit('CE# never low in capture')
a, b = lo[0], lo[-1]
print(f'CE# low samples {a}..{b} ({(b - a + 1) * 5} ns)')
print(' smp   ns  ce sck out  in(3210)  run')
i = a - 2
while i <= b + 2:
    j = i
    while j + 1 <= b + 2 and s[j + 1] == s[i]: j += 1
    d = s[i]
    print('%4d %5d  %d   %d   %X   %s  x%d' % (i, (i - a) * 5, d['ce'], d['sck'], d['out'], format(d['inp'], '04b'), j - i + 1))
    i = j + 1
edges = [i for i in range(a + 1, b + 1) if s[i]['sck'] and not s[i - 1]['sck']]
print(f'\n{len(edges)} SCK rising edges; sio_in at the edge sample (and 1 sample before):')
print(' '.join('%X' % s[e]['inp'] for e in edges))
print(' '.join('%X' % s[e - 1]['inp'] for e in edges))
