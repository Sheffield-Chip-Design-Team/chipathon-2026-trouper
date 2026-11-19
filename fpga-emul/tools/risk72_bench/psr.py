import socket,serial,time,re
ser=serial.Serial('/dev/serial/by-id/usb-Digilent_Digilent_USB_Device_210319BE7543-if01-port0',115200,timeout=0.3)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
def send(c,body): s.sendto(b"CTLR"+bytes([c])+body,("192.168.10.2",5008))
def rd(a):
    ser.reset_input_buffer(); send(13,bytes([a]))
    t=time.time()
    while time.time()-t<1:
        l=ser.readline().decode(errors='ignore')
        m=re.search(r'REGR: 0x%02X => 0x([0-9A-F]{2})'%a,l)
        if m: return int(m.group(1),16)
    return None
def wr(a,v):
    ser.reset_input_buffer(); send(12,bytes([a,v]))
    t=time.time()
    while time.time()-t<1:
        if 'REGW' in ser.readline().decode(errors='ignore'): return
    print('no ack',hex(a))
def setaddr(b): wr(0x72,b&0xFF); wr(0x73,(b>>8)&0xFF); wr(0x74,(b>>16)&0x7F)
def pwrite(b,data):
    setaddr(b)
    for x in data: wr(0x79,x)
    wr(0x75,0x04)
    while rd(0x75)&0x80: pass
def pread(b):
    setaddr(b); wr(0x75,0x01)
    while rd(0x75)&0x80: pass
    return [rd(0x76) for _ in range(8)]
