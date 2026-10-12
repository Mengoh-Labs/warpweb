#!/usr/bin/env python3
"""Own two PTYs: check process/graphics isolation and crash/closure cleanup."""
import base64,ctypes,errno,fcntl,http.server,io,json,os,pathlib,pty,select,signal,struct,subprocess,sys,termios,threading,time,uuid
from PIL import Image
root=pathlib.Path(__file__).resolve().parents[1]
binary=pathlib.Path(sys.argv[1]).resolve()
run=root/'run'/('sessions-'+uuid.uuid4().hex[:8]);run.mkdir(parents=True)
cookie='wwtest'+uuid.uuid4().hex;token=uuid.uuid4().hex
class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        name='Alpha' if self.path.startswith('/alpha') else 'Beta'
        color='#321020' if name=='Alpha' else '#102050'
        self.send_response(200);self.send_header('Content-Type','text/html')
        if name=='Alpha':self.send_header('Set-Cookie',f'{cookie}={token}; Path=/; Max-Age=3600; SameSite=Lax')
        if self.path=='/clear':self.send_header('Set-Cookie',f'{cookie}=; Path=/; Max-Age=0')
        self.end_headers()
        self.wfile.write(f'''<!doctype html><style>body{{margin:0;background:{color}}}div{{width:30px;height:30px;background:white;animation:a 1s infinite alternate}}@keyframes a{{to{{transform:translateX(100px)}}}}</style><div></div><button onclick="document.title='Clicked:{name}'">Click</button><script>setInterval(()=>{{const own=document.cookie.split('; ').find(c=>c.startsWith('{cookie}='));document.title='{name}:'+(own?own.split('=')[1]:'missing');}},250);</script>'''.encode())
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
threading.Thread(target=server.serve_forever,daemon=True).start()
base=f'http://127.0.0.1:{server.server_port}'
libc=ctypes.CDLL(None,use_errno=True);libc.shm_open.argtypes=[ctypes.c_char_p,ctypes.c_int,ctypes.c_uint]
clients=[];owners={}
class Client:
    def __init__(self,name,*,shared=False,pointer=False,diagnostic=None):
        self.name=name;self.shared=shared;self.hold=False;self.pending=bytearray();self.packet={};self.payload=[];self.ids=set();self.names=set();self.frames=0;self.last_png=None
        self.master,self.slave=pty.openpty();self.original=termios.tcgetattr(self.slave)
        fcntl.ioctl(self.slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,60,600,480))
        self.diagnostic=diagnostic or run/(name+'.json');self.log=(run/(name+'.log')).open('wb')
        self.process=subprocess.Popen([str(binary),base+('/alpha' if name in ['Alpha','Seed'] else '/beta'),'--capture',os.environ.get('WARPWEB_TEST_CAPTURE','stream'),'--diagnostics-file',str(self.diagnostic),*(['--pointer'] if pointer else [])],stdin=self.slave,stdout=self.slave,stderr=self.log,start_new_session=True)
        if diagnostic:self.diagnostic=diagnostic.with_name(diagnostic.stem+f'.{self.process.pid}'+diagnostic.suffix)
        clients.append(self)
    def state(self):
        try:return json.loads(self.diagnostic.read_text())
        except (OSError,ValueError):return {}
    def send(self,data):os.write(self.master,data)
    def pump(self):
        if self.master<0:return
        try:data=os.read(self.master,262144)
        except OSError:return
        self.pending.extend(data)
        while True:
            start=self.pending.find(b'\x1b_G')
            if start<0:
                self.pending[:]=self.pending[-3:];return
            end=self.pending.find(b'\x1b\\',start)
            if end<0:return
            packet=bytes(self.pending[start+3:end]);del self.pending[:end+2]
            header,_,payload=packet.partition(b';');p=dict(x.split('=',1) for x in header.decode().split(',') if '=' in x)
            if 'i' in p:
                identifier=int(p['i']);self.ids.add(identifier)
                assert owners.get(identifier,self.name)==self.name,('Cross-session image collision',identifier,owners.get(identifier),self.name)
                owners[identifier]=self.name
            if p.get('a')=='q':
                if p.get('t')=='s':self.names.add(base64.b64decode(payload));answer='OK' if self.shared else 'ENOTSUP'
                else:answer='OK'
                self.send(f'\x1b_Gi={p["i"]};{answer}\x1b\\'.encode())
            elif p.get('a')=='T' and p.get('t')=='s':
                self.names.add(base64.b64decode(payload));self.frames+=1
                if not self.hold:self.send(f'\x1b_Gi={p["i"]};OK\x1b\\'.encode())
            else:
                if p.get('a')=='T':self.packet=p;self.payload=[]
                if 'm' in p:
                    self.payload.append(payload)
                    if p['m']=='0':
                        self.last_png=base64.b64decode(b''.join(self.payload));self.frames+=1;self.payload=[]
                        if not self.hold:self.send(f'\x1b_Gi={self.packet["i"]};OK\x1b\\'.encode())
    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait()
        if self.master>=0:os.close(self.master);self.master=-1
        os.close(self.slave);self.log.close()
def wait(predicate,label,timeout=60):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        if predicate():return
        readable,_,_=select.select([c.master for c in clients if c.master>=0],[],[],.02)
        for c in clients:
            if c.master in readable:c.pump()
    raise AssertionError((label,{c.name:c.state() for c in clients}))
def alive(pid):
    if not pid:return False
    try:os.kill(pid,0);return True
    except ProcessLookupError:return False
def no_shared(c):
    for name in c.names:
        fd=libc.shm_open(name,os.O_RDONLY,0)
        if fd>=0:os.close(fd);return False
        assert ctypes.get_errno()==errno.ENOENT
    return True
try:
    seed=Client('Seed');wait(lambda:seed.frames>15 and seed.state().get('title')=='Alpha:'+token,'saved cookie fixture')
    seed.send(b'\x11');wait(lambda:seed.process.poll()==0,'cookie fixture quit',10)
    a=Client('Alpha');wait(lambda:a.frames>2 and a.state().get('title')=='Alpha:'+token,'first session')
    b=Client('Beta',diagnostic=a.diagnostic);wait(lambda:b.frames>2 and b.state().get('title')=='Beta:'+token,'second session and shared cookie')
    assert a.process.pid!=b.process.pid and a.ids.isdisjoint(b.ids)
    assert a.state()['processPID']==a.process.pid and b.state()['processPID']==b.process.pid
    assert b.state()['diagnosticsFile']==str(b.diagnostic)
    for c,color in [(a,(50,16,32)),(b,(16,32,80))]:
        expected=os.environ.get('WARPWEB_TEST_CAPTURE','stream')
        wait(lambda:c.state().get('captureBackend')==expected,'capture backend')
        assert c.state().get('helperPagePixelsOnDisplay') is False
        wait(lambda:c.last_png is not None,'PNG')
        image=Image.open(io.BytesIO(c.last_png)).convert('RGB');pixel=image.getpixel((450,350))
        assert max(abs(x-y) for x,y in zip(pixel,color))<10,(c.name,pixel)
        assert c.state().get('pointerEnabled') is False,'Pointer must default off'
    print('PASS: concurrent processes, disjoint graphics IDs, independent page pixels, shared saved cookie, pointer off',flush=True)
    before=b.frames;watchdog=a.state().get('watchdogPID');assert watchdog,'Missing crash watchdog'
    a.process.kill();a.process.wait()
    wait(lambda:not alive(watchdog),'watchdog exit after crash',15)
    assert termios.tcgetattr(a.slave)==a.original,('crash termios',a.original,termios.tcgetattr(a.slave))
    wait(lambda:b.frames>before+2 and b.state().get('title')=='Beta:'+token,'survivor after peer crash')
    print('PASS: renderer crash restores its PTY and leaves peer session running',flush=True)
    c=Client('Shared',shared=True,pointer=True);c.hold=True
    wait(lambda:c.frames>0,'held shared frame');watchdog=c.state().get('watchdogPID');assert watchdog
    assert c.state().get('pointerEnabled') is True
    c.process.kill();c.process.wait();wait(lambda:no_shared(c) and not alive(watchdog),'crashed shared-memory cleanup',15)
    assert termios.tcgetattr(c.slave)==c.original
    print('PASS: SIGKILL cleans unacknowledged shared memory and opt-in pointer',flush=True)
    d=Client('Closed');wait(lambda:d.frames>0,'closure session ready');watchdog=d.state().get('watchdogPID');assert watchdog
    # SIGSTOP simulates a renderer stuck outside the Swift run loop.
    d.process.send_signal(signal.SIGSTOP);os.close(d.master);d.master=-1
    wait(lambda:d.process.poll() is not None and not alive(watchdog),'closed pane kills even a hung renderer',15)
    before=b.frames;wait(lambda:b.frames>before+2,'peer survives pane closure')
    b.send(b'\x0c'+(base+'/clear').encode()+b'\r');wait(lambda:b.state().get('url')==base+'/clear' and not b.state().get('loading',True),'cookie fixture cleanup')
    b.send(b'\x11');wait(lambda:b.process.poll()==0,'normal quit',10)
    assert termios.tcgetattr(b.slave)==b.original
    wait(lambda:all(not alive(c.state().get('watchdogPID')) for c in clients),'all session watchdogs exit',15)
    print('PASS: terminal closure terminates hung session; survivor quits cleanly',flush=True)
finally:
    for c in clients:c.close()
    server.shutdown()
