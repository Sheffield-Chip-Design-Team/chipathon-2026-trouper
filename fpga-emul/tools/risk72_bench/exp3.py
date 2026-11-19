from psr import *
h=lambda l:' '.join('%02X'%x if x is not None else '??' for x in l)
wr(0x70,0x00)
pats={
 'low_toggle 00..FF': [0,0,0,0,0xFF,0xFF,0xFF,0xFF],
 'one_line 11 01..' : [0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x11],
 'all_toggle 0F..'  : [0x0F]*7+[0x0E],
 'distinct 01..EF'  : [0x01,0x23,0x45,0x67,0x89,0xAB,0xCD,0xEF],
}
N=12
addr=0x100000
for name,P in pats.items():
    wbad=rbad=0; ex=[]
    for t in range(N):
        pwrite(addr,P)
        r1=pread(addr); r2=pread(addr)
        if r1!=r2: rbad+=1
        if r1!=P and r2!=P: wbad+=1
        if r1!=P and len(ex)<3: ex.append(h(r1))
        addr+=0x1000
    print(f'{name:20s} both-reads-wrong {wbad}/{N}  reads-disagree {rbad}/{N}  eg: {ex}')
