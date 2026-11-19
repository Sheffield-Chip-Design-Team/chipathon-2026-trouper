# Write-burst capture at 32 MHz: SIO (CH2) voltage at each SCK (CH1) rising edge vs VIH.
import sys,json,time
from tds import *; import psr
addr=int(sys.argv[1],16); tag=sys.argv[2]; P=[int(x,16) for x in sys.argv[3].split(',')]; bit=int(sys.argv[4])
setup(tdiv=250e-9,pos=1.0e-6,lvl=1.65)
psr.wr(0x70,0x00); psr.setaddr(addr)
for x in P: psr.wr(0x79,x)
arm(); psr.wr(0x75,0x04); time.sleep(0.5)
t,s=fetch(1); _,v=fetch(2)
json.dump({'t':t,'sck':s,'sio':v,'P':P,'addr':addr},open(f'caps/{tag}.json','w'))
hi=[x>1.65 for x in s]; ris=[i for i in range(1,len(s)) if hi[i] and not hi[i-1]]
n=[0,2]+[(addr>>k)&0xF for k in (20,16,12,8,4,0)]+[x for b in P for x in (b>>4,b&15)]
print('edges',len(ris),' step %.1f ns'%((t[1]-t[0])*1e9))
for k,i in enumerate(ris[:24]):
    e=(n[k]>>bit)&1
    flag='' if (e and v[i]>=2.9) or (not e and v[i]<=0.4) else '  <-- outside VIH/VIL'
    print('edge %2d expect %d  SIO=%.2f V%s'%(k+1,e,v[i],flag))
print('readback', ' '.join('%02X'%x for x in psr.pread(addr)))
