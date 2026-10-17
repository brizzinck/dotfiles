#!/usr/bin/env python3
"""Fake popup for the broker tests: popup.py's contract without a screen. Usage: fake_popup.py --req FILE.
TGCONFIRM_FAKE = confirm | cancel | timeout | none (no result file, like a closed window) | stale (wrong nonce) | hang (never exits)
TGCONFIRM_FAKE_LOG = file that gets one JSON line per call: the request as the popup saw it and the environment keys that matter."""
import json
import os
import socket
import stat
import sys
import time

req = json.load(open(sys.argv[2]))
log = os.environ.get("TGCONFIRM_FAKE_LOG")
if log:
    with open(log, "a") as f:
        fd = os.environ.get("WAYLAND_SOCKET")
        kind = "none"
        try:
            if fd and stat.S_ISSOCK(os.fstat(int(fd)).st_mode):
                kind = "socket"
                socket.socket(fileno=os.dup(int(fd))).getpeername()
        except (OSError, ValueError):
            kind = "broken"
        f.write(json.dumps({"req": req, "wl_fd": kind, "pid": os.getpid(),
                            "env": {k: os.environ.get(k) for k in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "XDG_RUNTIME_DIR", "HOME", "DBUS_SESSION_BUS_ADDRESS")},
                            "req_mode": oct(os.stat(sys.argv[2]).st_mode & 0o777)}) + "\n")
mode = os.environ.get("TGCONFIRM_FAKE", "confirm")
delay = float(os.environ.get("TGCONFIRM_FAKE_DELAY", "0"))
time.sleep(delay)
if mode == "hang":
    time.sleep(3600)
if mode == "none":
    sys.exit(0)
result = {"confirm": "confirmed", "cancel": "cancelled", "timeout": "timeout", "stale": "confirmed"}.get(mode, "cancelled")
nonce = "WRONG" if mode == "stale" else req["nonce"]
fd = os.open(req["result_file"], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"nonce": nonce, "result": result}, f)
