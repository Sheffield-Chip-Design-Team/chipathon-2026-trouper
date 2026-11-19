from psr import *
h=lambda l:' '.join('%02X'%x if x is not None else '??' for x in l)
wr(0x70,0x00)   # freeze capture ring
CAN=[0xC3,0x3C,0x5A,0xA5,0x96,0x69,0x0F,0xF0]; CA=0x7F0000
pwrite(CA,CAN); print('canary', h(pread(CA)))
pats={
 'low_toggle': [0,0,0,0,0xFF,0xFF,0xFF,0xFF],
 'one_line'  : [0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x11],
 'all_toggle': [0x0F]*7+[0x0E],
 'distinct'  : [0x01,0x23,0x45,0x67,0x89,0xAB,0xCD,0xEF],
}
addr=0x100000; n=0
for rnd in range(4):
  for name,P in pats.items():
    pwrite(addr,P); r1=pread(addr); r2=pread(addr); c=pread(CA); n+=1
    tag='OK ' if r1==P and r2==P else 'BAD'
    print(f'{n:2d} {name:10s} {tag} r1={h(r1)} r2={h(r2)} canary={"ok" if c==CAN else h(c)}')
    addr+=0x1000
    if c!=CAN: raise SystemExit('canary lost')
