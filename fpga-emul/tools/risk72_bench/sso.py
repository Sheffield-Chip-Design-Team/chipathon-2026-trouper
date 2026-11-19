# Simultaneous-switching test: how many SIO lines flip together vs pass rate.
import sys
from psr import *
h=lambda l:' '.join('%02X'%x for x in l)
wr(0x70,0)
pats={
 '1 line  0<->1': [0x01]*8, '1 line  0<->8': [0x08]*8,
 '2 lines 0<->3': [0x03]*8, '2 lines 0<->C': [0x0C]*8,
 '3 lines 0<->7': [0x07]*8, '3 lines 0<->E': [0x0E]*8,
 '4 lines 0<->F': [0x0F]*8, '4 lines 5<->A': [0x5A]*8,
 'static  FF'   : [0xFF]*8, 'static  00'   : [0x00]*8,
}
N=int(sys.argv[1]) if len(sys.argv)>1 else 6; X=0x300000
for name,P in pats.items():
    ok=0; ex=''
    for i in range(N):
        pwrite(X,P); r=pread(X); X+=0x40
        if r==P: ok+=1
        elif not ex: ex=h(r)
    print(f'{name:14s} {ok}/{N} pass   {ex}')
