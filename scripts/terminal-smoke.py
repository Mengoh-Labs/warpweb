#!/usr/bin/env python3
"""Test real WebKit terminal output in an owned PTY; emulate Kitty replies, decode PNGs."""
import base64
import ctypes
import mmap
import io
from PIL import Image
import fcntl
import http.server
import json
import os
import pathlib
import pty
import re
import select
import signal
import struct
import statistics
import subprocess
import sys
import termios
import threading
import time

root = pathlib.Path(__file__).resolve().parents[1]
artifact = root / 'run'
artifact.mkdir(exist_ok=True)
video_path = artifact/'playback-fixture.mp4'
if not video_path.exists():
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=320x180:rate=24','-t','4','-an','-c:v','libx264','-pix_fmt','yuv420p','-movflags','+faststart',str(video_path)],check=True)
if len(sys.argv) > 1:
    binary = pathlib.Path(sys.argv[1]).resolve()
else:
    binary = pathlib.Path(subprocess.check_output(['swift','build','--show-bin-path'], cwd=root, text=True).strip()) / 'warpweb'

expected_transport=os.environ.get('WARPWEB_TEST_TRANSPORT','shared-memory')
render_scale=float(os.environ.get('WARPWEB_TEST_SCALE','1'))
assert 1 <= render_scale <= 3
select_state = {}
scroll_samples = []
slow_release = threading.Event()

class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/slow':
            slow_release.wait(90)
            self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
            try:self.wfile.write(b'<title>Slow loaded</title>Loaded')
            except (BrokenPipeError,ConnectionResetError):pass
            return
        if self.path == '/clip.mp4':
            data = video_path.read_bytes();start=0;end=len(data)-1
            match=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
            if match:
                start=int(match[1]);end=min(end,int(match[2])) if match[2] else end
            self.send_response(206 if match else 200)
            self.send_header('Content-Type','video/mp4');self.send_header('Accept-Ranges','bytes')
            if match:self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
            self.send_header('Content-Length',str(end-start+1));self.end_headers();self.wfile.write(data[start:end+1]);return
        if self.path.startswith('/scroll-state?y='):
            scroll_samples.append(int(self.path.split('=')[-1]))
            self.send_response(204);self.end_headers();return
        if self.path == '/auth':
            if self.headers.get('Authorization') != 'Basic '+base64.b64encode(b'test-user:test-pass').decode():
                self.send_response(401);self.send_header('WWW-Authenticate','Basic realm="warpweb fixture"');self.end_headers();return
            self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(b'<title>Authenticated</title>Signed in');return
        if self.path == '/download':
            self.send_response(200);self.send_header('Content-Type','application/octet-stream');self.send_header('Content-Disposition','attachment; filename="warpweb-test.txt"');self.end_headers();self.wfile.write(b'warpweb download verified');return
        if self.path in ['/untyped-page', '/html-attachment', '/unsupported-file']:
            body = b'<!doctype html><title>Untyped page</title>Navigation stays in WebKit'
            self.send_response(200)
            if self.path == '/html-attachment':
                self.send_header('Content-Type','text/html')
                self.send_header('Content-Disposition','attachment; filename="intentional-page.html"')
            elif self.path == '/unsupported-file':
                self.send_header('Content-Type','application/octet-stream')
                body = b'\x00\x01warpweb unsupported file verified'
            self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
        if self.path.startswith('/select-state?size='):
            select_state['size'] = int(self.path.split('=')[-1])
            self.send_response(204);self.end_headers();return
        second = self.path.startswith('/second')
        body = ('''<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Loading</title></head>
<body style="margin:0;background:#10251c;color:#fff;height:2200px;font:18px sans-serif">
<h1 style="padding:10px">warpweb terminal test</h1>
<button style="position:absolute;left:40px;top:100px;width:120px;height:40px" onclick="document.title='Clicked'">Click me</button>
<input style="position:absolute;left:200px;top:100px;width:180px;height:40px" oninput="document.title='Typed:'+this.value">
<script>document.title='SECOND';addEventListener('scroll',()=>{document.title='Scroll:'+Math.round(scrollY);fetch('/scroll-state?y='+Math.round(scrollY))});</script></body></html>'''
                .replace("'SECOND'", "'Second'" if second else "'Ready:'+innerWidth+':'+innerHeight")).encode()
        if self.path.startswith('/scroll-benchmark'):
            body = b'''<!doctype html><title>Scroll benchmark</title><style>body{margin:0;height:100000px;background:repeating-linear-gradient(#10251c 0px,#10251c 23px,#f2b84b 23px,#f2b84b 47px)}</style>'''
        elif self.path.startswith('/interaction'):
            body = ('''<!doctype html><title>Interaction</title><body style="margin:0;height:2000px">
<button style="position:absolute;left:20px;top:10px;width:150px;height:35px" onpointerenter="document.title='Hover:'+event.isTrusted" onpointerdown="this.dataset.down=event.isTrusted" onpointerup="this.dataset.up=event.isTrusted" onclick="document.title='Pointer:'+this.dataset.down+':'+this.dataset.up+':'+event.isTrusted">Pointer</button>
<form style="position:absolute;left:20px;top:65px" onsubmit="event.preventDefault();document.title='Submitted:'+this.elements.name.value">
<input name="name" style="width:150px" oninput="document.title='Form:'+this.value"><button>Submit</button></form>
<input type="range" style="position:absolute;left:20px;top:140px;width:180px" value="0" oninput="document.title='Range:'+this.value">
<select style="position:absolute;left:250px;top:140px;width:150px" onchange="document.title='Choice:'+this.value"><option>First</option><option>Second</option></select>
<div style="position:absolute;left:20px;top:210px;width:150px;height:100px;overflow:auto" onscroll="document.title='Nested:'+this.scrollTop+':'+scrollY"><div style="height:1000px">Scroll here</div></div>
<iframe style="position:absolute;left:250px;top:210px;width:220px;height:110px" src="http://localhost:PORT/frame"></iframe>
<script>const select=document.querySelector('select');new MutationObserver(()=>fetch('/select-state?size='+select.size)).observe(select,{attributes:true,attributeFilter:['size']});addEventListener('message',e=>document.title=e.data);addEventListener('keydown',e=>{if(e.key==='Escape')document.title='Escape:'+e.isTrusted});</script>'''.replace('PORT',str(self.server.server_port))).encode()
        elif self.path.startswith('/animation'):
            body=b'''<!doctype html><title>Animation</title><style>body{margin:0;background:#10251c}div{width:180px;height:180px;background:#fe6348;animation:move .7s linear infinite alternate}@keyframes move{to{transform:translateX(700px) rotate(180deg)}}</style><div></div>'''
        elif self.path.startswith('/embedded-video'):
            body = ('''<!doctype html><title>Embedded ready</title><body style="margin:0"><iframe style="border:0;width:500px;height:350px" src="http://localhost:PORT/video"></iframe><script>addEventListener('message',e=>document.title='Embedded:'+e.data)</script>'''.replace('PORT',str(self.server.server_port))).encode()
        elif self.path.startswith('/video'):
            body = ('''<!doctype html><title>Video ready</title><body style="margin:0">
<video id="v" controls muted loop playsinline style="position:absolute;left:20px;top:20px;width:320px;height:180px" src="http://localhost:PORT/clip.mp4" onplaying="document.title='Video:playing';parent.postMessage(document.title,'*')" onpause="document.title='Video:paused';parent.postMessage(document.title,'*')" onseeked="document.title='Video:seeked'"></video>
<button style="position:absolute;left:20px;top:250px;width:100px;height:40px" onclick="v.play()">Play</button>
<button style="position:absolute;left:150px;top:250px;width:100px;height:40px" onclick="v.pause()">Pause</button>
<button style="position:absolute;left:280px;top:250px;width:100px;height:40px" onclick="v.currentTime=.5;document.title='Video:seek'">Seek</button>
</body>'''.replace('PORT',str(self.server.server_port))).encode()
        elif self.path.startswith('/selection'):
            body = b'''<!doctype html><title>Selection</title><body style="margin:0"><p style="position:absolute;left:20px;top:0;font:20px/30px monospace">alpha beta gamma</p><script>document.addEventListener('selectionchange',()=>document.title='Selected:'+getSelection().toString())</script>'''
        elif self.path.startswith('/features'):
            body = b'''<!doctype html><title>Features</title><body style="margin:0;font:16px sans-serif">
<button style="position:absolute;left:20px;top:20px;width:120px;height:35px" onclick="const value=prompt('Your name','');document.title='Prompt:'+value">Prompt</button>
<button style="position:absolute;left:160px;top:20px;width:120px;height:35px" onclick="document.title='Confirm:'+confirm('Continue?')">Confirm</button>
<button style="position:absolute;left:300px;top:20px;width:120px;height:35px" onclick="alert('Hello from the page');document.title='Alert:done'">Alert</button>
<input type="file" style="position:absolute;left:20px;top:85px" onchange="document.title='Upload:'+this.files[0].name">
<a download href="/download" style="position:absolute;left:20px;top:145px">Download file</a>
<textarea style="position:absolute;left:20px;top:210px;width:300px;height:70px" oninput="document.title='Paste:'+JSON.stringify(this.value)"></textarea>
<a target="_blank" href="/second" style="position:absolute;left:200px;top:145px">Open tab</a>
<button style="position:absolute;left:400px;top:140px;width:160px;height:35px" onclick="const handler=window.webkit?.messageHandlers?.pageContext;handler?.postMessage({link:location.origin+'/second'});document.querySelector('a[target]').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));document.title='Context exposed:'+!!handler">Synthetic context</button>
</body>'''
        elif self.path.startswith('/frame'):
            body = b'''<!doctype html><body style="margin:0"><button style="position:absolute;left:10px;top:20px;width:160px;height:40px" onclick="parent.postMessage('Iframe:'+event.isTrusted,'*')">Frame button</button>'''
        self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)

server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
threading.Thread(target=server.serve_forever,daemon=True).start()
url = f'http://127.0.0.1:{server.server_port}'
master, slave = pty.openpty()
original = termios.tcgetattr(slave)
fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,120,1200,800))
diagnostics = artifact / f'terminal-state-{server.server_port}.json'
downloads = artifact / f'downloads-{server.server_port}'
scale_args=['--scale',str(render_scale)] if 'WARPWEB_TEST_SCALE' in os.environ else []
capture_mode=os.environ.get('WARPWEB_TEST_CAPTURE','snapshot')
capture_args=[] if capture_mode=='default' else ['--capture',capture_mode]
process = subprocess.Popen([str(binary),url,"--pointer",*scale_args,'--diagnostics-file',str(diagnostics),'--download-dir',str(downloads),*capture_args],stdin=slave,stdout=slave,stderr=subprocess.PIPE,start_new_session=True)
wire = bytearray(); pending = bytearray(); frames=[]; payload=[]; controls=''; query=False

libc = ctypes.CDLL(None,use_errno=True)
libc.shm_open.argtypes=[ctypes.c_char_p,ctypes.c_int,ctypes.c_uint]
libc.shm_open.restype=ctypes.c_int
libc.shm_unlink.argtypes=[ctypes.c_char_p]
def shared_bytes(chunk, size):
    name=base64.b64decode(chunk)
    fd=libc.shm_open(name,os.O_RDONLY,0)
    assert fd>=0, ('Cannot open shared frame',ctypes.get_errno())
    try:
        assert os.fstat(fd).st_size>=size
        with mmap.mmap(fd,size,access=mmap.ACCESS_READ) as mapped:return mapped[:]
    finally:os.close(fd);libc.shm_unlink(name)

def pump(timeout=.1):
    global payload, controls, query
    if not select.select([master],[],[],timeout)[0]: return
    try: data=os.read(master,262144)
    except OSError: return
    wire.extend(data); pending.extend(data)
    if len(wire)>1048576: del wire[:-1048576]
    while True:
        begin=pending.find(b'\x1b_G')
        if begin < 0:
            if len(pending)>3: del pending[:-3]
            break
        end=pending.find(b'\x1b\\',begin)
        if end < 0:
            if begin: del pending[:begin]
            break
        packet=bytes(pending[begin+3:end]); del pending[:end+2]
        header,_,chunk=packet.partition(b';')
        params=dict(item.split('=',1) for item in header.decode().split(',') if '=' in item)
        if params.get('a')=='q':
            if params.get('t')=='s':
                if expected_transport=='png':
                    send(f'\x1b_Gi={params["i"]};ENOTSUP\x1b\\'.encode())
                else:
                    assert shared_bytes(chunk,4)==bytes([255,255,255,255])
                    send(f'\x1b_Gi={params["i"]};OK\x1b\\'.encode())
            else:
                query=True; os.write(master,('\x1b_Gi='+params['i']+';OK\x1b\\\x1b[4;800;1200t').encode())
        elif params.get('a')=='T' and params.get('t')=='s':
            width=int(params['s']);height=int(params['v']);data=shared_bytes(chunk,width*height*4)
            assert len(data)==width*height*4
            send(f'\x1b_Gi={params["i"]};OK\x1b\\'.encode())
            image=Image.frombytes('RGBA',(width,height),data)
            encoded=io.BytesIO();image.save(encoded,format='PNG',compress_level=1)
            frames.append((width,height,encoded.getvalue(),params))
            if len(frames)>90:
                old=frames[-91];frames[-91]=(old[0],old[1],b'',old[3])
        elif params.get('a')=='T' or 'm' in params:
            if params.get('a')=='T': payload=[]; controls=params
            payload.append(chunk)
            if params.get('m')=='0':
                png=base64.b64decode(b''.join(payload)); assert png.startswith(b'\x89PNG\r\n\x1a\n')
                width,height=struct.unpack('>II',png[16:24]); frames.append((width,height,png,controls));payload=[]
                if len(frames)>90:
                    old=frames[-91];frames[-91]=(old[0],old[1],b'',old[3])
                if controls.get('q')=='0':
                    time.sleep(float(os.environ.get('WARPWEB_TEST_ACK_DELAY','0')))
                    send(f'\x1b_Gi={controls["i"]};OK\x1b\\'.encode())

def drain_exit(timeout=.1):
    # Quit unlinks any outstanding shared frame immediately. Drain terminal
    # restoration bytes without trying to decode already-retired images.
    if select.select([master],[],[],timeout)[0]:
        try: wire.extend(os.read(master,262144))
        except OSError: pass

def wait(predicate,description):
    deadline=time.monotonic()+float(os.environ.get("WARPWEB_TEST_TIMEOUT","12"))
    while time.monotonic()<deadline:
        if predicate(): return
        if process.poll() is not None: raise AssertionError(('CLI exited',process.returncode,process.stderr.read().decode()))
        pump()
    if frames: (artifact/'terminal-failure.png').write_bytes(frames[-1][2])
    raise AssertionError(('Timeout',description,bytes(wire[-300:])))

def state():
    try:
        value=json.loads(diagnostics.read_text())
        if 'helperPagePixelsOnDisplay' in value:
            assert value['helperPagePixelsOnDisplay'] == False, 'Helper page pixels overlap a display'
        if os.environ.get('WARPWEB_EXPECT_CAPTURE')=='stream' and os.environ.get('WARPWEB_TEST_CAPTURE_RECOVERY')!='1':
            assert not value.get('captureFallback'), (value.get('title'),value.get('captureFallback'))
        return value
    except (OSError,ValueError): return {}
def marker(): wire.clear()
def send(data): os.write(master,data)
def title(text): wait(lambda:text in state().get('title',''),text)

try:
    wait(lambda:query and frames and state().get('title','').startswith('Ready:'),'initial PNG')
    width,height=state()['screenWidth'],state()['screenHeight']
    header=state()['header']
    assert frames[-1][0:2]==(int(1200*render_scale),int(800*render_scale)),frames[-1][0:2]
    assert frames[-1][3]['c']=='120' and frames[-1][3]['r']=='40'
    assert state()['transport']==expected_transport
    expected_capture=os.environ.get('WARPWEB_EXPECT_CAPTURE','snapshot')
    wait(lambda:state().get('captureBackend')==expected_capture,'initial capture backend settled')
    assert state()['captureBackend']==expected_capture, (state()['captureBackend'],state()['captureFallback'])
    print('Capture backend:',state()['captureBackend'],'Fallback:',state()['captureFallback'],flush=True)
    assert frames[-1][3]['z']=='-1', 'Foreground image layers swallow mouse clicks in Warp'
    (artifact/'terminal-initial.png').write_bytes(frames[-1][2])
    # The source window must not leak its near-zero desktop alpha into capture.
    def page_color_ready():
        initial=Image.open(io.BytesIO(frames[-1][2])).convert('RGB')
        sample=initial.getpixel((initial.width//2,int((header+350)/height*initial.height)))
        return max(abs(a-b) for a,b in zip(sample,(16,37,28))) < 12
    # A navigation title can arrive before the corresponding captured pixels.
    wait(page_color_ready,'initial page color/opacity')
    def mouse(x,y,button=0,released=False):
        column=int(x/width*120)+1; row=int((y+header)/height*40)+1
        send(f'\x1b[<{button};{column};{row}{"m" if released else "M"}'.encode())
    def click(x,y):
        column=int(x/width*120)+1; row=int((y+header)/height*40)+1
        send(f'\x1b[<0;{column};{row}M'.encode())
        deadline=time.monotonic()+.25
        while time.monotonic()<deadline: pump(.02)
        send(f'\x1b[<0;{column};{row}m'.encode())
    def stop_loading_test():
        send(b'\x0c'+(url+'/slow').encode()+b'\r')
        wait(lambda:state().get('loading') and state().get('url')==url+'/slow','loading feedback')
        assert 'progress' in state()
        count=len(frames);wait(lambda:len(frames)>=count+2,'loading frame')
        (artifact/'terminal-loading.png').write_bytes(frames[-1][2])
        click(245,72-header)  # HTML reload button now stops this navigation.
        wait(lambda:not state().get('loading') and state().get('error')=='Loading stopped','HTML stop loading')
        slow_release.set()
    if os.environ.get('WARPWEB_TEST_STOP_ONLY') == '1':
        stop_loading_test()
        send(b'\x11');deadline=time.monotonic()+5
        while process.poll() is None and time.monotonic()<deadline:drain_exit()
        assert process.wait(timeout=1)==0 and termios.tcgetattr(slave)==original
        print('PASS: HTML Stop survives focus update between press/release and cancels pending navigation')
        sys.exit(0)
    if os.environ.get('WARPWEB_TEST_CAPTURE_RECOVERY') == '1':
        wait(lambda:state().get('captureRecoveryPending') and state().get('captureBackend')=='snapshot','transient capture fallback')
        assert state()['captureLastFailure']
        wait(lambda:state().get('captureBackend')=='stream' and not state().get('captureRecoveryPending') and state().get('captureRecoveryAttempts')==1,'capture connection recovered')
        assert not state()['captureFallback']
        wait(page_color_ready,'recovered page pixels')
        send(b'\x11');deadline=time.monotonic()+5
        while process.poll() is None and time.monotonic()<deadline:drain_exit()
        assert process.wait(timeout=1)==0 and termios.tcgetattr(slave)==original
        print('PASS: interrupted capture falls back, restarts once, restores streamed pixels and exits cleanly')
        sys.exit(0)
    if os.environ.get('WARPWEB_TEST_SCROLL') == '1':
        send(b'\x0c'+(url+'/scroll-benchmark').encode()+b'\r');title('Scroll benchmark')
        def page_signature():
            image=Image.open(io.BytesIO(frames[-1][2])).convert('RGB')
            # Page pixels only: exclude chrome, cursor, scrollbars and text.
            return image.crop((image.width//2,400,image.width//2+1,700)).tobytes()
        latencies=[]
        for trial in range(10):
            deadline=time.monotonic()+2.4+(trial%3)*.023
            while time.monotonic()<deadline:pump(.005)
            before=page_signature();count=len(frames);start=time.monotonic()
            mouse(200,250,65)
            deadline=start+2
            while time.monotonic()<deadline:
                pump(.002)
                if len(frames)>count:
                    count=len(frames)
                    if page_signature()!=before:break
            else:raise AssertionError('No visible response to scroll')
            latencies.append((time.monotonic()-start)*1000)
        times=[];last=page_signature();start=time.monotonic();next_input=start
        while time.monotonic()-start<3:
            now=time.monotonic()
            if now>=next_input:
                mouse(200,250,65);next_input=now+1/60
            count=len(frames);pump(.002)
            if len(frames)>count:
                current=page_signature()
                if current!=last:times.append(time.monotonic());last=current
        gaps=[(b-a)*1000 for a,b in zip(times,times[1:])]
        result={'renderScale':render_scale,'idleToChangedPixelsMedianMs':statistics.median(latencies),
                'idleToChangedPixelsMaxMs':max(latencies),'idleSamplesMs':latencies,
                'changedFramesPerSecond':len(times)/3,
                'changedFrameGapP95Ms':sorted(gaps)[min(len(gaps)-1,int(len(gaps)*.95))] if gaps else None,
                'inputWakeups':state().get('inputWakeups'),
                'staleScrollFramesDiscarded':state().get('staleScrollFramesDiscarded')}
        assert len(times)>2, 'Scrolling did not produce changing page frames'
        print('SCROLL BENCHMARK:',json.dumps(result),flush=True)
        send(b'\x11');deadline=time.monotonic()+5
        while process.poll() is None and time.monotonic()<deadline:drain_exit()
        assert process.wait(timeout=1)==0 and termios.tcgetattr(slave)==original
        sys.exit(0)
    if os.environ.get('WARPWEB_TEST_ANIMATION') == '1':
        send(b'\x0c'+(url+'/animation').encode()+b'\r');title('Animation')
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:pump(.02)
        assert state()['mediaPlaying']==False
        count=len(frames);start=time.monotonic();deadline=start+3
        while time.monotonic()<deadline:pump(.02)
        rate=(len(frames)-count)/(time.monotonic()-start)
        print('ANIMATION FPS:',rate,flush=True)
        assert rate>15, ('Non-media animation was throttled as idle',rate)
        send(b'\x11');deadline=time.monotonic()+5
        while process.poll() is None and time.monotonic()<deadline:drain_exit()
        assert process.wait(timeout=1)==0 and termios.tcgetattr(slave)==original
        sys.exit(0)
    if os.environ.get('WARPWEB_TEST_STREAM_VIDEO') == '1':
        assert expected_capture == 'stream'
        send(b'\x0c'+(url+'/video').encode()+b'\r');title('Video ready')
        click(65,270);title('Video:playing')
        wait(lambda:state().get('mediaPlaying')==True,'stream playback')
        start_count=state()['captureFrames']
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:pump(.02)
        def streamed_video_pixels():
            image=Image.open(io.BytesIO(frames[-1][2])).convert('RGB')
            sx=image.width/width;sy=image.height/height
            return image.crop((int(25*sx),int((header+25)*sy),int(330*sx),int((header+145)*sy)))
        before=streamed_video_pixels()
        sample_start=time.monotonic();sample_count=len(frames);samples=[]
        deadline=time.monotonic()+8.3
        while time.monotonic()<deadline:
            count=len(frames)
            pump(.02)
            if len(frames)>count:
                sample=state();assert sample['captureBackend']=='stream'
                samples.append(sample)
        sample_elapsed=time.monotonic()-sample_start
        result={'frames':len(frames)-sample_count,'seconds':sample_elapsed,'fps':(len(frames)-sample_count)/sample_elapsed,'imageEncoder':state().get('imageEncoder','platform-png')}
        if expected_encoder:=os.environ.get('WARPWEB_EXPECT_ENCODER'):
            assert all(s.get('imageEncoder')==expected_encoder for s in samples), 'Unexpected encoder fallback'
        if expected_conversion:=os.environ.get('WARPWEB_EXPECT_CONVERSION'):
            assert all(s.get('captureConversion')==expected_conversion for s in samples), 'Unexpected capture conversion'
        result['captureConversion']=state().get('captureConversion','core-image')
        for key in ['captureMilliseconds','encodeMilliseconds','transferMilliseconds','deliveryIntervalMedianMilliseconds','deliveryIntervalP95Milliseconds','frameAgeMilliseconds']:
            values=[s[key] for s in samples if key in s]
            if values:result[key]=statistics.median(values)
        print('BENCHMARK:',json.dumps(result),flush=True)
        if destination:=os.environ.get('WARPWEB_TEST_BENCHMARK_FILE'):
            pathlib.Path(destination).write_text(json.dumps(result,indent=2))
        after=streamed_video_pixels()
        assert len(after.getcolors(after.width*after.height) or [])>20, 'Missing streamed video pixels'
        assert before.tobytes()!=after.tobytes(), 'Streamed video is frozen'
        assert state()['captureFrames']>start_count+20, 'Source frames did not advance'
        (artifact/'stream-video.png').write_bytes(frames[-1][2])
        click(190,270);title('Video:paused')
        wait(lambda:state().get('mediaPlaying')==False,'stream pause')
        click(320,270);title('Video:seeked')
        send(b'\x11')
        deadline=time.monotonic()+5
        while process.poll() is None and time.monotonic()<deadline:drain_exit()
        process.wait(timeout=1)
        assert process.returncode==0 and termios.tcgetattr(slave)==original
        print('PASS: continuous stream video pixels, source frame advancement, opacity, play/pause/seek and clean shutdown')
        sys.exit(0)
    marker();click(80,120);title('Clicked')
    assert state()['pointerPresses'] == 1 and state()['pointerReleases'] == 1
    marker();mouse(80,120,35)
    wait(lambda:state().get('lastPointer',{}).get('phase')=='move','pointer movement')
    assert [event['phase'] for event in state()['recentClicks']] == ['down','up']
    assert [event['released'] for event in state()['mouseReports']] == [False,True]
    assert state()['lastMouseReport']['button'] == 35
    marker();click(260,120);send(b'Swift');title('Typed:Swift')
    wait(lambda:state().get('focusArea')=='Text field','focused field feedback')
    marker();send(b'\x7f');title('Typed:Swif')
    marker();mouse(200,350,65);title('Scroll:40')
    assert any(0 < sample < 40 for sample in scroll_samples), scroll_samples
    marker();mouse(200,350,65);mouse(200,350,64)
    wait(lambda:state().get('title','').startswith('Scroll:'),'scroll reversal')
    # Let the gesture settle, then verify the opposite wheel reaches the top.
    deadline=time.monotonic()+.3
    while time.monotonic()<deadline:pump(.01)
    mouse(200,350,64);title('Scroll:0')
    marker();send(b'\x0c'+(url+'/second').encode()+b'\r');title('Second')
    marker();send(b'\x02');wait(lambda:state().get('url','').rstrip('/')==url and not state().get('loading',True),'back')
    marker();send(b'\x1b[1;3C');title('Second')
    marker();send(b'\x12');title('Second')
    marker();send(b'\x0c'+(url+'/selection').encode()+b'\r');title('Selection')
    def multi_click(count):
        for _ in range(count):
            mouse(40,30);mouse(40,30,0,True)
            deadline=time.monotonic()+.08
            while time.monotonic()<deadline: pump(.01)
    multi_click(2);title('Selected:alpha')
    deadline=time.monotonic()+.65
    while time.monotonic()<deadline: pump(.02)
    multi_click(3);title('Selected:alpha beta gamma')
    count=len(frames);wait(lambda:len(frames)>count,'selection image')
    (artifact/'terminal-selection.png').write_bytes(frames[-1][2])
    marker();send(b'\x0c'+(url+'/interaction').encode()+b'\r');title('Interaction')
    marker();mouse(70,25,35);title('Hover:true')
    marker();click(70,25);title('Pointer:true:true:true')
    marker();click(80,75);send(b'hello');title('Form:hello')
    marker();send(b'\x01replacement');title('Form:replacement')
    marker();send(b'\t\r');title('Submitted:replacement')
    marker();send(b'\x1b');title('Escape:true')
    marker();mouse(30,150);mouse(175,150,32);mouse(175,150,0,True)
    wait(lambda:any(int(v)>=80 for v in re.findall(r'Range:(\d+)',state().get('title',''))),'range dragging')
    marker();click(300,150)
    wait(lambda:select_state.get('size') == 2, 'expanded dropdown DOM state')
    count=len(frames);wait(lambda:len(frames)>=count+2,'visible dropdown frame')
    assert select_state.get('size') == 2, ('Dropdown did not stay expanded',select_state)
    (artifact/'terminal-dropdown.png').write_bytes(frames[-1][2])
    send(b'\x1b[B\r');title('Choice:Second')
    marker();mouse(60,250,65);title('Nested:40:0')
    marker();click(300,250);title('Iframe:true')
    # Browser toolbar and dialog flows travel through the same native input path.
    marker();send(b'\x14');wait(lambda:len(state().get('tabs',[]))==2,'new tab')
    send((url+'/features').encode()+b'\r');title('Features')
    click(70,35);wait(lambda:(state().get('dialog')=='prompt' and state().get('dialogReady')),'page prompt')
    count=len(frames);wait(lambda:len(frames)>=count+2,'prompt frame')
    (artifact/'terminal-prompt.png').write_bytes(frames[-1][2])
    send(b'Kairo\r');title('Prompt:Kairo')
    click(210,35);wait(lambda:(state().get('dialog')=='confirm' and state().get('dialogReady')),'page confirm');send(b'\x1b');title('Confirm:false')
    click(350,35);wait(lambda:(state().get('dialog')=='alert' and state().get('dialogReady')),'page alert');send(b'\r');title('Alert:done')
    upload=artifact/'upload-fixture.txt';upload.write_text('warpweb upload verified')
    click(65,95);wait(lambda:(state().get('dialog')=='upload' and state().get('dialogReady')),'file picker')
    send(str(upload).encode()+b'\r');title('Upload:upload-fixture.txt')
    click(70,155);wait(lambda:(downloads/'warpweb-test.txt').exists(),'download')
    wait(lambda:(downloads/'warpweb-test.txt').read_bytes()==b'warpweb download verified','download bytes')
    click(455,155);title('Context exposed:false')
    count=len(frames);wait(lambda:len(frames)>=count+2,'synthetic context processed')
    assert not state().get('menu'), 'Synthetic context event opened trusted menu'
    click(70,230);send(b'\x1b[200~line one\nline two\x1b[201~');title('Paste:"line one\\nline two"')
    # Select the last character with Shift-Left and replace it.
    send(b'\x1b[1;2DZ');title('Paste:"line one\\nline twZ"')
    before_menu=Image.open(io.BytesIO(frames[-1][2])).convert('RGB')
    mouse(235,155,2);mouse(235,155,2,True);wait(lambda:state().get('menu')==True,'right-click menu')
    count=len(frames);wait(lambda:len(frames)>=count+2,'context menu frame')
    (artifact/'terminal-context.png').write_bytes(frames[-1][2])
    menu_image=Image.open(io.BytesIO(frames[-1][2])).convert('RGB')
    sx=menu_image.width/width;sy=menu_image.height/height
    box=(int((width-180)*sx),int(110*sy),int((width-25)*sx),int(250*sy))
    from PIL import ImageChops
    difference=ImageChops.difference(menu_image.crop(box),before_menu.crop(box))
    changed=sum(count for count,color in difference.getcolors(difference.width*difference.height) if max(color)>20)
    assert changed>1000, ('Context menu has input state but no visible overlay pixels',changed)
    # First menu entry: open link in new tab.
    click(width-100,120-header);title('Second');wait(lambda:len(state().get('tabs',[]))==3,'context link tab')
    send(b'\x17');wait(lambda:len(state().get('tabs',[]))==2,'close context tab')
    click(235,155);title('Second');wait(lambda:len(state().get('tabs',[]))==3,'popup tab')
    send(b'\x17');wait(lambda:len(state().get('tabs',[]))==2,'close popup');title('Paste:')
    send(b'\x17');wait(lambda:len(state().get('tabs',[]))==1,'close tab');title('Iframe:true')
    # Click the rendered address field, then navigate without using Ctrl-L.
    click(width/2,72-header);send(b'\x01'+(url+'/features').encode()+b'\r');title('Features')
    # Find in page from the rendered browser menu.
    click(width-25,72-header);wait(lambda:state().get('menu')==True,'toolbar menu')
    click(width-100,155-header);wait(lambda:(state().get('dialog')=='prompt' and state().get('dialogReady')),'find dialog')
    send(b'Open tab\r');wait(lambda:state().get('error')=='Found: Open tab','find result')
    send(b'\x06');wait(lambda:state().get('dialog')=='prompt' and state().get('dialogReady'),'Ctrl-F find')
    send(b'Download\r');wait(lambda:state().get('error')=='Found: Download','hotkey find result')
    send(b'\x1bOR');send(b'\x1b[1;2R');send(b'\x07')
    wait(lambda:state().get('error')=='Found: Download','find next/previous')
    send(b'\x1bOP');wait(lambda:state().get('dialog')=='help' and state().get('dialogReady'),'shortcut help')
    count=len(frames);wait(lambda:len(frames)>=count+2,'help frame')
    (artifact/'terminal-help.png').write_bytes(frames[-1][2])
    send(b'\x1b');wait(lambda:state().get('dialog')=='','dismiss help')
    send(b'\x1b+');wait(lambda:state().get('zoom')==110,'zoom in')
    send(b'\x1b0');wait(lambda:state().get('zoom')==100,'zoom reset')
    mouse(235,155,35);wait(lambda:state().get('hoverURL')==url+'/second','hover destination')
    wait(lambda:state().get('cursorKind')=='pointer','link cursor')
    mouse(600,400,35);wait(lambda:state().get('pointerVisible')==True and state().get('hoverURL')=='','visible pointer')
    count=len(frames);wait(lambda:len(frames)>=count+3,'pointer frame')
    with_pointer=Image.open(io.BytesIO(frames[-1][2])).convert('RGB')
    send(b'\x1b[19~');wait(lambda:state().get('pointerEnabled')==False,'hide pointer')
    count=len(frames);wait(lambda:len(frames)>=count+3,'hidden pointer frame')
    without_pointer=Image.open(io.BytesIO(frames[-1][2])).convert('RGB')
    sx=with_pointer.width/width;sy=with_pointer.height/height
    box=(int(596*sx),int((header+396)*sy),int(622*sx),int((header+427)*sy))
    assert ImageChops.difference(with_pointer.crop(box),without_pointer.crop(box)).getbbox(), 'Pointer has no visible pixels'
    send(b'\x1b[19~');wait(lambda:state().get('pointerEnabled')==True,'show pointer')
    send(b'\x14');wait(lambda:len(state().get('tabs',[]))==2,'shortcut tab')
    send((url+'/second').encode()+b'\r');title('Second')
    send(b'\x1b[5;5~');title('Features')
    send(b'\x1b[6;5~');title('Second')
    send(b'\x17');wait(lambda:len(state().get('tabs',[]))==1,'close shortcut tab')
    stop_loading_test()


    send(b'\x0c'+(url+'/video').encode()+b'\r');title('Video ready')
    click(65,270);title('Video:playing')
    wait(lambda:state().get('mediaPlaying')==True,'playing media detected')
    deadline=time.monotonic()+(8 if expected_capture=="stream" else 2.2)
    while time.monotonic()<deadline:pump(.02)
    video_start=len(frames)
    deadline=time.monotonic()+2
    while time.monotonic()<deadline:pump(.02)
    video_frames=frames[video_start:]
    assert len(video_frames)>=3, ('Video frames stalled',len(video_frames))
    def video_crop(frame):
        image=Image.open(io.BytesIO(frame[2])).convert('RGB')
        sx=image.width/width;sy=image.height/height
        return image.crop((int(25*sx),int((header+25)*sy),int(330*sx),int((header+145)*sy)))
    # Inspect representative frames without starving the terminal ACK reader.
    # A 60 fps stream otherwise makes full PNG analysis exceed its ACK deadline.
    available=[frame for frame in video_frames if frame[2]]
    crops=[video_crop(available[index]) for index in (0,len(available)//2,len(available)-1)]
    assert any(len(image.getcolors(image.width*image.height) or [])>20 for image in crops), 'Missing video pixels'
    assert len({image.tobytes() for image in crops})>1, 'Video image is frozen'
    (artifact/'terminal-video.png').write_bytes(video_frames[-1][2])
    print('Video frames captured in 2 seconds:',len(video_frames))
    click(190,270);title('Video:paused')
    wait(lambda:state().get('mediaPlaying')==False,'paused media detected')
    click(320,270);title('Video:seeked')
    send(b'\x0c'+(url+'/embedded-video').encode()+b'\r');title('Embedded ready')
    click(65,270);title('Embedded:Video:playing')
    wait(lambda:state().get('mediaPlaying')==True,'cross-origin media detected')
    count=len(frames);wait(lambda:len(frames)>count+2,'embedded video frames')
    embedded=video_crop(frames[-1])
    assert len(embedded.getcolors(embedded.width*embedded.height) or [])>20, 'Embedded video pixels missing'
    click(190,270);title('Embedded:Video:paused')
    wait(lambda:state().get('mediaPlaying')==False,'cross-origin media paused')

    send(b'\x0c'+(url+'/auth').encode()+b'\r');wait(lambda:(state().get('dialog')=='prompt' and state().get('dialogReady')),'HTTP username')
    send(b'test-user\r');wait(lambda:(state().get('dialog')=='password' and state().get('dialogReady')),'HTTP password')
    send(b'test-pass\r');title('Authenticated')
    before_downloads = set(downloads.iterdir())
    send(b'\x0c'+(url+'/untyped-page').encode()+b'\r');title('Untyped page')
    wait(lambda:not state().get('loading'),'untyped page finished')
    assert set(downloads.iterdir()) == before_downloads, 'Page navigation created a download'
    send(b'\x0c'+(url+'/html-attachment').encode()+b'\r')
    attachment=downloads/'intentional-page.html'
    wait(lambda:attachment.exists() and attachment.read_bytes()==b'<!doctype html><title>Untyped page</title>Navigation stays in WebKit','explicit HTML attachment')
    before_binary = set(downloads.iterdir())
    send(b'\x0c'+(url+'/unsupported-file').encode()+b'\r')
    wait(lambda:any(p.read_bytes()==b'\x00\x01warpweb unsupported file verified' for p in set(downloads.iterdir())-before_binary),'unsupported file response download')
    print('PASS: untyped HTML stays in WebKit; explicit HTML attachments and unsupported file downloads retain exact bytes')
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,1000,600))
    os.kill(process.pid,signal.SIGWINCH)
    # Lookahead can be restarting capture while the preceding resized image
    # is acknowledged. Wait for both delivery and the live backend to settle.
    wait(lambda:frames[-1][0:2]==(int(1000*render_scale),int(600*render_scale)) and state().get('captureBackend')==expected_capture,'resize PNG and capture restart')
    (artifact/'terminal-resized.png').write_bytes(frames[-1][2])
    assert state()['captureBackend']==expected_capture, state()['captureFallback']
    send(b'\x11')
    deadline=time.monotonic()+5
    while process.poll() is None and time.monotonic()<deadline: drain_exit()
    process.wait(timeout=1)
    assert process.returncode==0
    assert termios.tcgetattr(slave)==original,'Terminal attributes not restored'
    print('PASS:',expected_transport,f'Kitty handshake, {int(1200*render_scale)}x{int(800*render_scale)} frames, HTML chrome, trusted pointer events, double/triple-click selection, eased scrolling, forms, dropdowns, iframes, tabs, context menus, paste/selection, find, dialogs, upload/download, HTTP auth, live/cross-origin video and playback controls, history, {int(1000*render_scale)}x{int(600*render_scale)} resize, clean exit and terminal restoration')
finally:
    slow_release.set()
    if process.poll() is None:
        process.terminate()
        deadline=time.monotonic()+3
        while process.poll() is None and time.monotonic()<deadline: drain_exit(.05)
        if process.poll() is None: process.kill()
        process.wait(timeout=2)
    if sys.exc_info()[0] is not None:
        print(process.stderr.read().decode(errors="replace"),file=sys.stderr)
    os.close(master);os.close(slave);server.shutdown()
