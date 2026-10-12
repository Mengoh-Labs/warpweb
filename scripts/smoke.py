#!/usr/bin/env python3
"""Exercise a running warpweb bridge without external sites or dependencies."""
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

base = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'run/session.url').read_text().strip()

def request(route, payload=None, headers=None, expected=200):
    headers = headers or {}
    if payload is not None:
        headers.setdefault('Content-Type', 'application/json')
    req = urllib.request.Request(base + route, data=json.dumps(payload).encode() if payload is not None else None, headers=headers)
    try:
        result = urllib.request.urlopen(req, timeout=6)
    except urllib.error.HTTPError as error:
        result = error
    assert result.status == expected, (route, result.status, expected)
    return result.read()

def command(action, **values):
    request('command', {'action': action, **values})

def state():
    return json.loads(request('state'))

def wait(predicate):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        value = state()
        if predicate(value):
            return value
        time.sleep(.1)
    raise AssertionError(('Timed out', state()))

command('navigate', url=base+'fixture.html')
wait(lambda s: s['title'] == 'warpweb test page' and not s['loading'])
command('resize', width=1100, height=720)
wait(lambda s: s['width'] == 1100)
frame = request('frame')
assert frame.startswith(b'\xff\xd8') and len(frame) > 1000
command('click', x=60, y=164)
wait(lambda s: s['title'] == 'Clicks: 1')
command('click', x=220, y=164)
for key in 'Swift':
    command('key', key=key)
wait(lambda s: s['title'] == 'Typed: Swift')
command('key', key='Backspace')
wait(lambda s: s['title'] == 'Typed: Swif')
command('scroll', dy=200)
wait(lambda s: s['title'] == 'Scrolled: 200')
command('navigate', url=base+'fixture.html?second')
wait(lambda s: s['title'] == 'Second test page')
command('back')
wait(lambda s: s['url'].endswith('fixture.html') and not s['loading'])
command('forward')
wait(lambda s: s['title'] == 'Second test page')
command('reload')
wait(lambda s: s['title'] == 'Second test page' and not s['loading'])
request('state', headers={'Origin': 'https://untrusted.example'}, expected=403)
request('state', headers={'Host': 'untrusted.example'}, expected=403)
request('command', {'action':'navigate','url':'file:///etc/passwd'}, expected=400)
request('command', {'action':'not-an-action'}, expected=400)
request('command', {'action':'reload'}, headers={'Content-Type':'text/plain'}, expected=415)
request('../wrong-session/state', expected=404)
print('PASS: JPEG frames, click, typing, deletion, resize, scrolling, navigation, back/forward/reload, origin/host/session checks, command validation')
