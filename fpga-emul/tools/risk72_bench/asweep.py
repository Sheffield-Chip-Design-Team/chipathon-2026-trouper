# Same data, sweep one address nibble; report stored image read back at X-1.
import sys
from psr import *
P=[0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27]
shift=int(sys.argv[1]); base=int(sys.argv[2],16)
wr(0x70,0x00)
for n in range(16):
    X=base|(n<<shift)
    pwrite(X-8,[0]*8); pwrite(X,P); pwrite(X+8,[0]*8)
    print('%X  X=0x%06X  %s'%(n,X,' '.join('%02X'%v for v in pread(X-1))))
