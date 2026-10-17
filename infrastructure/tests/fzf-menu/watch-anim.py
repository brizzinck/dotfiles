#!/usr/bin/env python3
"""watch-anim.py SECONDS: read-only diagnostic for the fzf-menu close animation (run it in a terminal while you open a menu and press Esc).

It connects to the Hyprland event socket (.socket2.sock of $HYPRLAND_INSTANCE_SIGNATURE), prints ms-stamped
openwindow / closewindow / movewindowv2 / activespecialv2 / windowtitlev2 / changefloatingmode events and, every 16 ms, any change of
position, size or workspace of the float.tui windows (hyprctl -j clients).

Expected for one menu + Esc with the one-shot server terminals:
  activespecialv2>>-9x,special:menu-a,eDP-1        the menu opens (instant)
  openwindow ... fzf-menu-server-b                 the standby, about 0.25 s later, workspace special:menu-b
  closewindow>>ADDR_A and activespecialv2>>,,eDP-1  on Esc (the window closes like any window)
and NO at/size change of ADDR_A between open and close. Anything else on ADDR_A (a move, a size change) is the jerk.
Nothing is sent to Hyprland; it only listens and runs `hyprctl -j clients`."""
import json
import os
import select
import socket
import subprocess
import sys
import time

EVENTS = ("openwindow", "closewindow", "movewindowv2", "activespecialv2", "windowtitlev2", "changefloatingmode")


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 10.0
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    rt = os.environ.get("XDG_RUNTIME_DIR")
    if not sig or not rt:
        sys.exit("watch-anim: HYPRLAND_INSTANCE_SIGNATURE / XDG_RUNTIME_DIR not set (run it inside the Hyprland session)")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(f"{rt}/hypr/{sig}/.socket2.sock")
    t0 = time.time()
    state = {}
    buf = b""

    def stamp():
        return f"{(time.time() - t0) * 1000:8.0f} ms"

    def poll():
        try:
            out = subprocess.run(["hyprctl", "-j", "clients"], capture_output=True, text=True, timeout=2).stdout
            clients = json.loads(out)
        except (OSError, ValueError, subprocess.SubprocessError):
            return
        now = {c["address"]: (tuple(c["at"]), tuple(c["size"]), c["workspace"]["name"], c.get("title", "")) for c in clients if c.get("class") == "float.tui"}
        for addr, v in now.items():
            if state.get(addr) != v:
                print(f"{stamp()}  float.tui {addr} at={v[0]} size={v[1]} ws={v[2]} title={v[3]!r}", flush=True)
        for addr in set(state) - set(now):
            print(f"{stamp()}  float.tui {addr} gone", flush=True)
        state.clear()
        state.update(now)

    poll()
    next_poll = time.time() + 0.016
    while time.time() - t0 < secs:
        r, _, _ = select.select([sock], [], [], max(0.0, next_poll - time.time()))
        if r:
            data = sock.recv(65536)
            if not data:
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode(errors="replace")
                if text.split(">>", 1)[0] in EVENTS:
                    print(f"{stamp()}  {text}", flush=True)
        if time.time() >= next_poll:
            poll()
            next_poll = time.time() + 0.016


if __name__ == "__main__":
    main()
