#!/usr/bin/env python3
"""ws-ipc-proxy: lets waybar's hyprland/workspaces buttons work on a Lua Hyprland config.

Under hyprland.lua the IPC command `dispatch X` is run as `hl.dispatch(X)`, i.e. X must be a Lua expression. waybar
(0.15) still sends the legacy text (`dispatch workspace 3`, `dispatch togglespecialworkspace term`) when a workspace
button is clicked, which is a Lua syntax error, so the click did nothing. waybar has no setting for the command, so this
proxy sits on the request socket (.socket.sock) in a private instance directory:

  $XDG_RUNTIME_DIR/hypr/<SIG>-wb/.socket.sock    this proxy
  $XDG_RUNTIME_DIR/hypr/<SIG>-wb/.socket2.sock   symlink to the real event socket (events need no translation)

waybar-run.sh starts the proxy and then waybar with HYPRLAND_INSTANCE_SIGNATURE=<SIG>-wb. Every request is forwarded
untouched except `dispatch <legacy dispatcher> <args>`, which goes through `hyprd -n` (legacy name -> Lua expression)
first. Requests that already carry Lua (`dispatch hl.`...) and everything else (j/clients, monitors, ...) pass through.

  ws-ipc-proxy.py          serve until the real Hyprland socket is gone (a second copy exits at once)
  ws-ipc-proxy.py --dir    print the private instance directory name (SIG-wb) and exit
  ws-ipc-proxy.py --ping   exit 0 when a running proxy answers a `version` request
"""
import asyncio
import fcntl
import os
import re
import shutil
import sys

SIG = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
RT = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
HYPR = os.path.join(RT, "hypr")
REAL = os.path.join(HYPR, SIG)
FAKE = os.path.join(HYPR, SIG + "-wb")
LEGACY = re.compile(r"^dispatch\s+(?!hl\.)(\S+)\s*(.*)$", re.S)


def hyprd():
    return shutil.which("hyprd") or os.path.expanduser("~/.local/bin/hyprd")


async def translate(msg):
    """'dispatch workspace 3' -> 'dispatch hl.dsp.focus({ workspace = 3 })'; other requests unchanged."""
    m = LEGACY.match(msg)
    if not m:
        return msg, None
    argv = [m.group(1)] + ([m.group(2).strip()] if m.group(2).strip() else [])
    proc = await asyncio.create_subprocess_exec(
        hyprd(), "-n", *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    out, err = await proc.communicate()
    if proc.returncode != 0:
        return None, "error: " + (err.decode(errors="replace").strip() or "hyprd failed")
    return "dispatch " + out.decode().strip(), None


async def handle(reader, writer):
    try:
        data = await asyncio.wait_for(reader.read(65536), 5)
        if not data:
            return
        msg, err = await translate(data.decode(errors="replace"))
        if err:
            writer.write(err.encode())
            await writer.drain()
            return
        up_r, up_w = await asyncio.open_unix_connection(os.path.join(REAL, ".socket.sock"))
        up_w.write(msg.encode())
        await up_w.drain()
        while chunk := await up_r.read(65536):
            writer.write(chunk)
        await writer.drain()
        up_w.close()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def watchdog(server):
    while os.path.exists(os.path.join(REAL, ".socket.sock")):
        await asyncio.sleep(15)
    server.close()


async def serve():
    sock = os.path.join(FAKE, ".socket.sock")
    if os.path.lexists(sock):
        os.unlink(sock)
    server = await asyncio.start_unix_server(handle, sock)
    os.chmod(sock, 0o700)
    await watchdog(server)


def main():
    if not SIG or not os.path.isdir(REAL):
        sys.exit("ws-ipc-proxy: no running Hyprland (HYPRLAND_INSTANCE_SIGNATURE)")
    if sys.argv[1:] == ["--dir"]:
        print(SIG + "-wb")
        return
    if sys.argv[1:] == ["--ping"]:
        import socket

        try:
            with socket.socket(socket.AF_UNIX) as c:
                c.settimeout(2)
                c.connect(os.path.join(FAKE, ".socket.sock"))
                c.sendall(b"version")
                sys.exit(0 if c.recv(64) else 1)
        except OSError:
            sys.exit(1)
    os.makedirs(FAKE, mode=0o700, exist_ok=True)
    lock = open(os.path.join(FAKE, "proxy.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return  # already running
    link = os.path.join(FAKE, ".socket2.sock")
    if os.path.lexists(link):
        os.unlink(link)
    os.symlink(os.path.join(REAL, ".socket2.sock"), link)
    asyncio.run(serve())
    shutil.rmtree(FAKE, ignore_errors=True)


main()
