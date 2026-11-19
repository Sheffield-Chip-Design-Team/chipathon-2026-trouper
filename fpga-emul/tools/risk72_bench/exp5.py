# Offset-aware PSRAM link test: 32 bytes known region (zeros + 16 pattern bytes + zeros),
# each 8-byte read is matched against the known nibble stream at offsets -6..+6 nibbles.
import sys, collections
from psr import *
h=lambda l:' '.join('%02X'%x if x is not None else '??' for x in l)
wr(0x70,0x00)  # freeze capture ring
PATS={
 'distinct': [0x01,0x23,0x45,0x67,0x89,0xAB,0xCD,0xEF,0xFE,0xDC,0xBA,0x98,0x76,0x54,0x32,0x10],
 'wvp'     : [0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27,0xC3,0x3C,0x5A,0xA5,0x96,0x69,0x0F,0xF1],
 'toggle'  : [0x0F]*15+[0x0E],
 'sparse'  : [0x00,0x00,0x00,0x01,0x00,0x00,0x80,0x00,0xFF,0xFF,0xFF,0xFE,0x00,0x00,0x00,0x10],
}
def nib(bs): return [n for b in bs for n in (b>>4,b&0xF)]
def match(r,stream,x0):
    if None in r: return None
    rn=nib(r); hits=[]
    for o in range(-6,7):
        s=2*x0+o
        if s>=0 and s+16<=len(stream) and stream[s:s+16]==rn: hits.append(o)
    return hits
rounds=int(sys.argv[1]) if len(sys.argv)>1 else 3
tally=collections.Counter(); addr=int(sys.argv[2],16) if len(sys.argv)>2 else 0x200000; bad=0
for rnd in range(rounds):
  for name,P in PATS.items():
    region=[0]*8+P+[0]*8          # region starts at addr-8
    for k in range(0,32,8): pwrite(addr-8+k, region[k:k+8])
    stream=nib(region)
    for x in (6,7,8,9,12,16):   # read addresses relative to region start
        r=pread(addr-8+x); m=match(r,stream,x)
        key=tuple(m) if m else 'NONE'; tally[key]+=1
        if not m: bad+=1; print(f'  {name:8s} x={x:2d} NONE  got {h(r)}  exp {h(region[x:x+8])}')
    addr+=0x1000
print('offset tally (nibbles, + = read runs ahead):', dict(tally)); print('NONE reads:',bad)
