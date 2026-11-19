import sys,json,time
from tds import *; import psr
addr=int(sys.argv[1],16); tag=sys.argv[2]
P=[0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27]
psr.wr(0x70,0x00); psr.setaddr(addr)
for x in P: psr.wr(0x79,x)
arm(); psr.wr(0x75,0x04); time.sleep(0.5)       # WR_TRIG
print('acq state',q('ACQ:STATE?'))
t,c1=fetch(1); _,c2=fetch(2)
json.dump({'addr':addr,'data':P,'t':t,'sck':c1,'sio1':c2},open(f'cap_{tag}.json','w'))
r=psr.pread(addr-1); print('readback(addr-1)',' '.join('%02X'%x for x in r))
