# SCK at the PSRAM pin (CH1, PSRAM pin 6) during debug reads, triggered on CE# falling (CH2, pin 1).
# Single-shot (no averaging, so glitches survive), 1 ns/sample. Per capture: SCK rising-edge count
# inside CE# low (hysteresis thresholds), extra/runt crossings, overshoot/undershoot, and each
# edge's time so a glitch can be placed against the nibble timeline.
# Usage: python3 sckcap.py [shots_per_line]
import os, sys, time, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tds import *
import psr
SHOTS = int(sys.argv[1]) if len(sys.argv) > 1 else 5
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'caps', '2026-11-18')
LINES = {'03': [0x03]*8, '0F': [0x0F]*8, '07': [0x07]*8, 'A5': [0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27]}
VH, VL = 2.0, 1.3   # hysteresis: a rising edge = goes above VH after being below VL
for c in ['HEADER OFF', 'SEL:CH1 ON', 'SEL:CH2 ON', 'CH1:COUP DC', 'CH1:VOLTS 1', 'CH1:POS -1',
          'CH2:COUP DC', 'CH2:VOLTS 2', 'CH2:POS -3', 'HOR:MAI:SCA 250e-9', 'HOR:MAI:POS 1.0e-6',
          'TRIG:MAI:TYP EDGE', 'TRIG:MAI:EDGE:SOU CH2', 'TRIG:MAI:EDGE:SLO FALL', 'TRIG:MAI:LEV 1.65',
          'TRIG:MAI:MOD NORM', 'ACQ:MOD SAMPLE', 'ACQ:STOPA SEQ',
          'DATA:ENC RIB', 'DATA:WID 1', 'DATA:STAR 1', 'DATA:STOP 2500']: w(c)
psr.wr(0x70, 0)
h = lambda l: ' '.join('%02X' % x for x in l)
def edges(t, v, t0, t1):
    st, up, runts = None, [], 0
    for tt, x in zip(t, v):
        if not (t0 <= tt <= t1): continue
        if x < VL:
            st = 'lo'
        elif x > VH:
            if st == 'lo': up.append(tt)
            st = 'hi'
    # runt = a dip below VH that does not reach VL, or a rise above VL that does not reach VH, between edges
    return up
for k, (name, P) in enumerate(LINES.items()):
    a = 0x250000 + k * 0x100
    psr.pwrite(a, P); psr.setaddr(a)
    for s in range(SHOTS):
        arm(); psr.wr(0x75, 0x01); time.sleep(0.6)
        if not done(): print(name, s, 'no trigger'); continue
        t, sck = fetch(1); _, ce = fetch(2)
        rb = [psr.rd(0x76) for _ in range(8)]
        lo = [tt for tt, x in zip(t, ce) if x < 1.65]
        t0, t1 = lo[0], lo[-1]
        up = edges(t, sck, t0, t1)
        inwin = [x for tt, x in zip(t, sck) if t0 <= tt <= t1]
        per = [b - a_ for a_, b in zip(up, up[1:])]
        odd = [(round((up[i] - t0) * 1e9), round(p * 1e9)) for i, p in enumerate(per) if abs(p - 31.25e-9) > 6e-9]
        print('%s shot%d  read %s  CE# %4.0f ns  SCK edges %2d  max %.2f V min %+.2f V  odd intervals (t_ns, dt_ns): %s'
              % (name, s, h(rb), (t1 - t0) * 1e9, len(up), max(inwin), min(inwin), odd), flush=True)
        json.dump({'t': t, 'sck': sck, 'ce': ce, 'line': P, 'read': rb},
                  open(os.path.join(out, 'sck_%s_%d.json' % (name, s)), 'w'))
