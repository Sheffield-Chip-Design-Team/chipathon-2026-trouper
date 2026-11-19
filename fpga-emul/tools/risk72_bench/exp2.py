from psr import *
import time
h=lambda l:' '.join('%02X'%x if x is not None else '??' for x in l)
wr(0x70,0x00)   # PSRAM_EN=0: stop capture ring (keeps qe_init_done?)
print('status71=%02X'%rd(0x71))
A=[0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88]
B=[0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xF1,0x27]
base=0x030000
pwrite(base,A); pwrite(base+8,B)
print('rd base   ',h(pread(base)))
print('rd base+8 ',h(pread(base+8)))
print('rd base+4 ',h(pread(base+4)))
print('rd base+12',h(pread(base+12)))
print('rd base+9 ',h(pread(base+9)))
time.sleep(5)
print('after 5s base+8',h(pread(base+8)))
