# Repeated single-line writes at fresh addresses; classify the stored image by read-back at X-1.
import sys, collections
from psr import *
P=[0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27]
N=int(sys.argv[1]) if len(sys.argv)>1 else 10; base=int(sys.argv[2],16) if len(sys.argv)>2 else 0x400000
wr(0x70,0x00); c=collections.Counter()
for i in range(N):
    X=base+i*0x100
    pwrite(X-8,[0]*8); pwrite(X,P); pwrite(X+8,[0]*8)
    r=' '.join('%02X'%v for v in pread(X-1)); c[r]+=1
for k,v in c.most_common(): print(f'{v:3d}x  {k}')
