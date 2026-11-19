# Capture PSRAM VDD (CH1, AC-coupled) during a single debug write burst; trigger on a VDD droop.
import os, sys, time, json, statistics as S
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tds import *
import psr
h = lambda l: ' '.join('%02X' % x for x in l)
lvl = float(sys.argv[1]) if len(sys.argv) > 1 else -0.03
vdiv = float(sys.argv[2]) if len(sys.argv) > 2 else 0.02
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'caps', '2026-11-18') + '/'
for c in ['HEADER OFF', 'CH1:COUP AC', f'CH1:VOLTS {vdiv}', 'CH1:POS 0', 'SEL:CH2 OFF',
          'HOR:MAI:SCA 250e-9', 'HOR:MAI:POS 1.0e-6', 'TRIG:MAI:TYP EDGE', 'TRIG:MAI:EDGE:SOU CH1',
          'TRIG:MAI:EDGE:SLO FALL', f'TRIG:MAI:LEV {lvl}', 'TRIG:MAI:MOD NORM', 'ACQ:MOD SAMPLE',
          'ACQ:STOPA SEQ', 'DATA:ENC RIB', 'DATA:WID 1', 'DATA:STAR 1', 'DATA:STOP 2500']: w(c)
psr.wr(0x70, 0x00)
PATS = {'pass_A5': [0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27], 'fail_0F': [0x0F]*8, 'fail_FF': [0xFF]*8}
res = {}
for rep in range(3):
    for name, P in PATS.items():
        a = 0x200000 + rep * 0x1000 + list(PATS).index(name) * 0x100
        psr.setaddr(a)
        for x in P: psr.wr(0x79, x)
        arm(); psr.wr(0x75, 0x04); time.sleep(1.0)
        trig = done()
        rb = psr.pread(a)
        line = f'{name:8s} rep{rep}  stored={"OK " if rb == P else "BAD"} {h(rb)}  triggered={trig}'
        if trig:
            t, v = fetch(1)
            base = S.mean(v[:300])  # pre-trigger baseline
            vmin = min(v); imin = v.index(vmin)
            line += '  droop=%.0f mV at t=%+.0f ns' % (1e3 * (vmin - base), 1e9 * t[imin])
            json.dump({'t': t, 'v': v, 'P': P, 'stored': rb}, open(out + f'vdd_{name}_{rep}.json', 'w'))
        print(line, flush=True)
