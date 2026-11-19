import socket,sys,time
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
def cmd(c,body=b''): s.sendto(b"CTLR"+bytes([c])+body,("192.168.10.2",5008)); time.sleep(0.05)
for a in sys.argv[1:]:
    if '=' in a:
        k,v=a.split('='); cmd(12,bytes([int(k,16),int(v,16)]))
    elif a.startswith('wvp'): cmd(15,bytes([0,0xF8,0])); time.sleep(0.1)
    else: cmd(13,bytes([int(a,16)]))
