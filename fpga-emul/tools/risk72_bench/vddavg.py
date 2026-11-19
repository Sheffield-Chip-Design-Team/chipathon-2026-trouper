# Averaged PSRAM VDD (CH1, AC) during debug reads, triggered on CE# falling (CH2 at PSRAM pin 1).
# For each stored line: TDS210 average of N reads, then window stats relative to CE# fall (t=0).
# Phases (from the 200 MHz ILA): cmd+addr ~0-150 ns (FPGA drives), wait ~150-440 ns, data ~440-1000 ns (PSRAM drives).
# Usage: python3 vddavg.py [navg]
import os, sys, time, json, statistics as S
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tds import *
import psr
NAV = int(sys.argv[1]) if len(sys.argv) > 1 else 64
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'caps', '2026-11-18')
LINES = {'00 (none rising)': [0x00]*8, '03 (2 lines toggle)': [0x03]*8, '07 (3 lines toggle)': [0x07]*8,
         '0F (4 lines rise)': [0x0F]*8, 'A5 reference': [0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27]}
for c in ['HEADER OFF', 'SEL:CH1 ON', 'SEL:CH2 ON', 'CH2:COUP DC', 'CH2:VOLTS 2', 'CH2:POS -2',
          'CH1:COUP AC', 'CH1:VOLTS 0.02', 'CH1:POS 2', 'HOR:MAI:SCA 250e-9', 'HOR:MAI:POS 1.0e-6',
          'TRIG:MAI:TYP EDGE', 'TRIG:MAI:EDGE:SOU CH2', 'TRIG:MAI:EDGE:SLO FALL', 'TRIG:MAI:LEV 1.65',
          'TRIG:MAI:MOD NORM', 'DATA:ENC RIB', 'DATA:WID 1', 'DATA:STAR 1', 'DATA:STOP 2500']: w(c)
psr.wr(0x70, 0)
win = lambda t, v, a, b: [x for x, tt in zip(v, t) if a <= tt < b]
res = {}
for k, (name, P) in enumerate(LINES.items()):
    a = 0x240000 + k * 0x100
    psr.pwrite(a, P); rb = psr.pread(a); psr.setaddr(a)
    w('ACQ:STATE STOP'); w('ACQ:MOD AVE'); w(f'ACQ:NUMAV {NAV}'); w('ACQ:STOPA SEQ'); w('ACQ:STATE RUN'); time.sleep(0.5)
    n = 0
    while n < 4 * NAV:
        psr.wr(0x75, 0x01); n += 1
        if n % 8 == 0 and q('ACQ:STATE?') == '0': break
    t, v = fetch(1); _, ce = fetch(2)
    base = S.mean(win(t, v, -0.25e-6, -0.02e-6))
    row = {'reads': n, 'readback_ok': rb == P}
    for ph, (lo, hi) in {'cmd/addr': (0, 150e-9), 'wait': (150e-9, 440e-9), 'data': (440e-9, 1000e-9), 'after': (1.1e-6, 2.2e-6)}.items():
        x = win(t, v, lo, hi)
        row[ph] = '%+4.0f/%+4.0f mV' % (1e3 * (min(x) - base), 1e3 * (max(x) - base))
    x = win(t, v, 0, 1e-6); i = x.index(min(x))
    row['deepest'] = '%+.0f mV at %.0f ns' % (1e3 * (min(x) - base), 1e9 * win(t, t, 0, 1e-6)[i])
    res[name] = row
    json.dump({'t': t, 'vdd': v, 'ce': ce, 'line': P, 'navg': NAV}, open(os.path.join(out, 'vddavg_%02d.json' % k), 'w'))
    print('%-20s %s' % (name, row), flush=True)
w('ACQ:MOD SAMPLE')
