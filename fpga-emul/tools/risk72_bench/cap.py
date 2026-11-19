import sys,json,time
from tds import *; import psr
addr=int(sys.argv[1],16); tag=sys.argv[2]
psr.wr(0x70,0x00)
psr.setaddr(addr)
arm(); psr.wr(0x75,0x01)          # RD_TRIG -> only SCK activity
time.sleep(0.5)
st=q('ACQ:STATE?'); print('acq state',st)
while psr.rd(0x75)&0x80: pass
data=[psr.rd(0x76) for _ in range(8)]
print('read', ' '.join('%02X'%x for x in data))
t,c1=fetch(1); _,c2=fetch(2)
json.dump({'addr':addr,'data':data,'t':t,'sck':c1,'sio1':c2},open(f'cap_{tag}.json','w'))
print('saved',len(t))
