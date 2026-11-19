import serial,time
s=serial.Serial('/dev/serial/by-id/usb-1a86_USB_Serial-if00-port0',9600,timeout=3)
def w(c): s.write((c+'\n').encode()); time.sleep(0.15)
def q(c):
    s.reset_input_buffer(); w(c); return s.readline().decode(errors='ignore').strip()
def setup(tdiv=1e-6,pos=4e-6,lvl=1.5):
    for c in ['HEADER OFF','CH1:VOLTS 2','CH2:VOLTS 2','CH1:POS 0','CH2:POS -3','SEL:CH1 ON','SEL:CH2 ON',
              f'HOR:MAI:SCA {tdiv}',f'HOR:MAI:POS {pos}','TRIG:MAI:TYP EDGE','TRIG:MAI:EDGE:SOU CH1',
              'TRIG:MAI:EDGE:SLO RIS',f'TRIG:MAI:LEV {lvl}','TRIG:MAI:MOD NORM','ACQ:MOD SAMPLE',
              'ACQ:STOPA SEQ','DATA:ENC RIB','DATA:WID 1','DATA:STAR 1','DATA:STOP 2500']: w(c)
def arm():
    # Re-arm and CONFIRM armed (state 1) -- a silent failed re-arm returns the
    # previous waveform (happened 2026-09-28: a 'read' capture was a stale write).
    for _ in range(5):
        w('ACQ:STATE STOP'); w('ACQ:STOPA SEQ'); w('ACQ:STATE RUN'); time.sleep(0.6)
        if q('ACQ:STATE?')=='1': return
    raise RuntimeError('scope did not arm')
def done(): return q('ACQ:STATE?') in ('0',)
def fetch(ch):
    w(f'DATA:SOU CH{ch}')
    pre=q('WFMPRE?').split(';')
    s.reset_input_buffer(); w('CURVE?')
    hdr=s.read(2); n=int(s.read(int(chr(hdr[1]))).decode()); raw=s.read(n); s.readline()
    import struct
    xinc=float(q('WFMPRE:XIN?')); xzero=float(q('WFMPRE:XZE?'))
    ym=float(q('WFMPRE:YMU?')); yo=float(q('WFMPRE:YOF?')); yz=float(q('WFMPRE:YZE?'))
    v=[(b-yo)*ym+yz for b in struct.unpack(f'{n}b',raw)]
    return [xzero+i*xinc for i in range(n)],v
