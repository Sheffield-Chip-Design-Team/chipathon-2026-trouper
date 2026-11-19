# Zoomed single-edge capture of SCK (CH1) + CH2; 20-80% / 10-90% rise & fall times.
import sys,time,json
from tds import *; import psr
setup(tdiv=float(sys.argv[1]) if len(sys.argv)>1 else 10e-9, pos=float(sys.argv[2]) if len(sys.argv)>2 else 20e-9, lvl=1.65)
psr.wr(0x70,0x00); psr.setaddr(0x6000FF); arm(); psr.wr(0x75,0x01); time.sleep(0.5)
print('acq',q('ACQ:STATE?'))
t,c1=fetch(1); _,c2=fetch(2)
json.dump({'t':t,'sck':c1,'ch2':c2},open('caps/edge.json','w'))
def tx(v,lo,hi,rising=True):
    out=[]
    for i in range(1,len(v)):
        if rising and v[i-1]<lo<=v[i] or (not rising and v[i-1]>hi>=v[i]):
            j=i
            while j<len(v) and (v[j]<hi if rising else v[j]>lo): j+=1
            if j<len(v): out.append((t[j]-t[i])*1e9)
    return out
for name,v in (('SCK',c1),('CH2',c2)):
    vmax=max(v); vmin=min(v)
    print(f'{name}: min {vmin:.2f} max {vmax:.2f} V | rise 20-80% (0.66-2.64V) ns: {[round(x,1) for x in tx(v,0.66,2.64)]} | fall 80-20% ns: {[round(x,1) for x in tx(v,0.66,2.64,False)]}')
dt=(t[1]-t[0])*1e9; print('sample step %.2f ns'%dt)
