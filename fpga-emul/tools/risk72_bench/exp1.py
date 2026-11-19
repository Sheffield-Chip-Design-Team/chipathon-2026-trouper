from psr import *
P=[0xA5,0x5A,0xDE,0xAD,0xBE,0xEF,0x10,0x27]
h=lambda l:' '.join('%02X'%x for x in l)
for base in (0x00F800,0x010000,0x020000):
    print('base %06X before:'%base, h(pread(base)))
    pwrite(base,P)
    for i in range(6): print('  rd%d'%i, h(pread(base)))
