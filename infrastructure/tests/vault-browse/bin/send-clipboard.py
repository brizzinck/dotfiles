#!/usr/bin/python3 -IB
"""Fake foreground Wayland selection: replacement exits without clearing it."""
import os
from pathlib import Path
import signal
import sys
import time

root = Path(os.environ['FAKE_DIR'])
if os.environ.get('FAKE_SEND_COPY_FAIL') == '1':
    print('invented-poison-clipboard-error', file=sys.stderr)
    sys.exit(1)
value = sys.stdin.buffer.read()
clip = root / 'clip.txt'
(root / 'clip.args').write_text(' '.join(sys.argv[1:]))
clip.write_bytes(value)
(root / 'clip.last').write_bytes(value)
(root / 'copy.pid').write_text(str(os.getpid()))
stop = False
def terminate(sig, frame):
    global stop
    stop = True
signal.signal(signal.SIGTERM, terminate)
while not stop:
    if not clip.exists() or clip.read_bytes() != value:
        sys.exit(0)
    time.sleep(0.01)
if clip.exists() and clip.read_bytes() == value:
    clip.write_bytes(b'')
