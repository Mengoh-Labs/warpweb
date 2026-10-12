#!/usr/bin/env python3
"""Parse and syntax-check every inline script shipped in the HTML browser shell."""
from html.parser import HTMLParser
from pathlib import Path
import subprocess

class Scripts(HTMLParser):
    def __init__(self): super().__init__(); self.inside=False; self.chunks=[]
    def handle_starttag(self, tag, attrs):
        if tag == 'script': self.inside=True
    def handle_endtag(self, tag):
        if tag == 'script': self.inside=False
    def handle_data(self, data):
        if self.inside: self.chunks.append(data)

root=Path(__file__).resolve().parents[1]
parser=Scripts();parser.feed((root/'Sources/warpweb/Resources/chrome.html').read_text())
assert parser.chunks, 'Missing browser shell scripts'
subprocess.run(['node','--check'], input='\n'.join(parser.chunks), text=True, check=True)
print('PASS: HTML shell scripts')
