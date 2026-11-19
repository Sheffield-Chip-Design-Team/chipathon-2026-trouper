import json,sys
d=json.load(open(sys.argv[1])); t=d['t']; a=d['sck']; b=d['sio1']
print('sck min/max %.2f/%.2f  sio1 min/max %.2f/%.2f'%(min(a),max(a),min(b),max(b)))
th=1.5; hi=[x>th for x in a]
ris=[i for i in range(1,len(a)) if hi[i] and not hi[i-1]]
fal=[i for i in range(1,len(a)) if not hi[i] and hi[i-1]]
print('rising edges:',len(ris),' falling:',len(fal))
if ris: print('first rise %.0f ns, last rise %.0f ns'%(t[ris[0]]*1e9,t[ris[-1]]*1e9))
per=[ (t[ris[i+1]]-t[ris[i]])*1e9 for i in range(len(ris)-1)]
print('periods ns:', ' '.join('%.0f'%p for p in per))
hw=[(t[f]-t[r])*1e9 for r in ris for f in fal if f>r][:0]
# sio1 level at each rising edge (and mid-low before it)
print('SIO1 @rise:', ''.join('1' if b[i]>th else '0' for i in ris))
print('SIO1 @fall+60ns:', ''.join('1' if b[min(i+15,len(b)-1)]>th else '0' for i in fal))
# SIO1 analog around edges for levels
print('SIO1 V @rise:', ' '.join('%.1f'%b[i] for i in ris))
