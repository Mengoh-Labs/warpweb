#!/usr/bin/env python3
"""Verify Kitty fallback and shared-memory cleanup in an owned PTY."""
import base64
import ctypes
import errno
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

root=Path(__file__).resolve().parents[1]
binary=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else Path(subprocess.check_output(['swift','build','--show-bin-path'],cwd=root,text=True).strip())/'warpweb'
libc=ctypes.CDLL(None,use_errno=True)
libc.shm_open.argtypes=[ctypes.c_char_p,ctypes.c_int,ctypes.c_uint]
libc.shm_open.restype=ctypes.c_int
class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
        self.wfile.write(b'<!doctype html><title>Transport</title><p>Frame transport</p>')
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    for mode in ['reject-probe','reject-frame','quit-frame','delay-png','resize-png','quit-png']:
        master,slave=pty.openpty();original=termios.tcgetattr(slave)
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,800,480))
        diagnostic=root/'run'/f'transport-{mode}.json'
        diagnostic.parent.mkdir(exist_ok=True);diagnostic.unlink(missing_ok=True)
        process=subprocess.Popen([str(binary),'--diagnostics-file',str(diagnostic),f'http://127.0.0.1:{server.server_port}','--scale','1','--capture',os.environ.get('WARPWEB_TEST_CAPTURE','snapshot')],stdin=slave,stdout=slave,stderr=subprocess.PIPE,start_new_session=True)
        pending=bytearray();names=[];fallback=False;stopped=False
        png_count=0;png_id=None;held=None;ack_at=0;saw_delay=False
        def send(data):os.write(master,data)
        try:
            deadline=time.monotonic()+float(os.environ.get("WARPWEB_TEST_TIMEOUT","15"))
            while process.poll() is None and time.monotonic()<deadline:
                if held is not None and time.monotonic()>=ack_at:
                    send(f'\x1b_Gi={held};OK\x1b\\'.encode());held=None
                if not select.select([master],[],[],.05)[0]:continue
                try:pending.extend(os.read(master,262144))
                except OSError:break
                while True:
                    begin=pending.find(b'\x1b_G')
                    if begin<0:
                        if len(pending)>3:del pending[:-3]
                        break
                    end=pending.find(b'\x1b\\',begin)
                    if end<0:break
                    packet=bytes(pending[begin+3:end]);del pending[:end+2]
                    header,_,chunk=packet.partition(b';')
                    params=dict(item.split('=',1) for item in header.decode().split(',') if '=' in item)
                    if params.get('t')=='s':names.append(base64.b64decode(chunk))
                    if params.get('a')=='q':
                        answer='ENOTSUP' if params.get('t')=='s' and mode in ['reject-probe','delay-png','resize-png','quit-png'] else 'OK'
                        send(f'\x1b_Gi={params["i"]};{answer}\x1b\\'.encode())
                        send(b'\x1b[<35;10;10M')
                    elif params.get('a')=='T' and params.get('t')=='s':
                        if mode=='quit-frame':send(b'\x11');stopped=True
                        else:send(f'\x1b_Gi={params["i"]};ENOTSUP\x1b\\'.encode())
                    elif params.get('a')=='T' and params.get('f')=='100':
                        assert held is None, 'More than one image in flight before acknowledgment'
                        previous_png_id=png_id if png_count else None;fallback=True;png_id=int(params['i']);png_count+=1
                        if mode=='resize-png' and png_count>=3:
                            assert params['c']=='100' and params['r']=='30', ('Stale frame after resize',params)
                        if mode=='delay-png': assert params.get('q')=='0', 'PNG must request acknowledgment'
                    elif params.get('a')=='d' and mode=='delay-png' and held is not None:
                        assert int(params.get('i',0)) != previous_png_id, 'Deleted previous image before PNG acknowledgment'
                    if fallback and params.get('m')=='0' and not stopped:
                        if mode in ['delay-png','resize-png','quit-png'] and png_count==1:
                            send(f'\x1b_Gi={png_id};OK\x1b\\'.encode())
                        elif mode in ['delay-png','resize-png'] and png_count==2:
                            held=png_id;ack_at=time.monotonic()+.25;saw_delay=True
                            if mode=='resize-png':
                                fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,1000,600))
                                os.kill(process.pid,signal.SIGWINCH)
                        else:send(b'\x11');stopped=True
            assert stopped and process.poll()==0,(mode,process.poll(),{'stopped':stopped,'png_count':png_count,'fallback':fallback},json.loads(diagnostic.read_text()) if diagnostic.exists() else {})
            assert mode=='quit-frame' or fallback,mode
            if mode in ['delay-png','resize-png']: assert saw_delay and png_count>=3
            assert termios.tcgetattr(slave)==original,(mode,'terminal settings not restored')
            for name in names:
                fd=libc.shm_open(name,os.O_RDONLY,0)
                if fd>=0:os.close(fd)
                assert fd<0 and ctypes.get_errno()==errno.ENOENT,(mode,'leaked shared frame')
            print('PASS:',mode,'with shared-memory cleanup and terminal restoration')
        finally:
            if process.poll() is None:process.kill();process.wait()
            os.close(master);os.close(slave)
finally:server.shutdown()
