#!/usr/bin/env python3
"""Tests of the Wayland socket discovery of infrastructure/mcp/confirm/broker.py: the broker only trusts a socket whose SERVER is the
owner's session compositor (SO_PEERCRED pid -> comm, uid, parent chain up to logind's session leader). Fake /proc and /run/systemd
trees (fake_session.py), real unix sockets, nothing of the real session is touched. Prints `ok NAME` / `FAIL NAME`.
Usage: test_wayland.py REPO"""
import importlib.util
import os
import shutil
import socket
import struct
import sys
import tempfile

repo = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import fake_session as fs  # noqa: E402

spec = importlib.util.spec_from_file_location("broker", os.path.join(repo, "infrastructure/mcp/confirm/broker.py"))
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
results = []


def check(name, cond):
    results.append(bool(cond))
    print(("ok " if cond else "FAIL ") + name)


OWNER = os.getuid()
ME = os.getpid()
children = []


def world(**kw):
    """A fresh scratch world: returns (broker, dirs). The real compositor is this process listening on wayland-1 when real=True."""
    t = tempfile.mkdtemp(prefix="tgwl-test.")
    wl, proc, lg = f"{t}/wl", f"{t}/proc", f"{t}/logind"
    for d in (wl, proc, lg):
        os.makedirs(d)
    fs.logind(lg, OWNER, **kw.get("logind", {}))
    servers = []
    if kw.get("real", True):
        fs.login_chain(proc, OWNER, ME, **kw.get("chain", {}))
        servers.append(fs.Server(f"{wl}/wayland-{kw.get('real_n', 1)}"))
    env = {"TGCONFIRM_OWNER_UID": str(OWNER), "TGCONFIRM_RUNTIME": f"{t}/run", "TGCONFIRM_WAYLAND_DIR": wl,
           "TGCONFIRM_PROC": proc, "TGCONFIRM_LOGIND": lg}
    return broker.Broker(env), t, wl, proc, servers


def done(t, servers):
    for s in servers:
        s.close()
    shutil.rmtree(t, ignore_errors=True)


def peer_pid(sock):
    return struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]


# --- the real compositor is found ------------------------------------------------------------------------------------------
b, t, wl, proc, sv = world()
s, why = b.open_wayland()
check("discovery: the real compositor socket is found through wayland-0..9 without listing the directory", s is not None and why == "" and peer_pid(s) == ME)
check("discovery: the returned socket is the connected socket itself (what ghostty gets as WAYLAND_SOCKET)", s.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) == socket.SOCK_STREAM)
s.close()
done(t, sv)

b, t, wl, proc, sv = world(real_n=7)
s, why = b.open_wayland()
check("discovery: wayland-7 works too (any of 0..9)", s is not None)
s and s.close()
done(t, sv)

b, t, wl, proc, sv = world(chain={"shell": "zsh"})
s, why = b.open_wayland()
check("discovery: the login shell between the session leader and start-hyprland is accepted", s is not None)
s and s.close()
done(t, sv)

# --- planted sockets -------------------------------------------------------------------------------------------------------
b, t, wl, proc, sv = world(real=False)
pl = fs.listener_child(f"{wl}/wayland-0")
children.append(pl)
fs.proc_entry(proc, pl.pid, "python3", 4000, OWNER)
fs.logind(f"{t}/logind", OWNER)
s, why = b.open_wayland()
check("planted: a wayland-0 served by a script of the owner is refused (no compositor at all = a clear error)", s is None and "no Wayland socket belongs" in why)
pl.kill()
done(t, sv)

b, t, wl, proc, sv = world()
pl = fs.listener_child(f"{wl}/wayland-0")
children.append(pl)
fs.proc_entry(proc, pl.pid, "python3", 4000, OWNER)
s, why = b.open_wayland()
check("planted: a fake wayland-0 next to the real wayland-1 is skipped, the real one is used", s is not None and peer_pid(s) == ME)
s and s.close()
pl.kill()
done(t, sv)

b, t, wl, proc, sv = world(real=False)
pl = fs.listener_child(f"{wl}/wayland-0")
children.append(pl)
fs.proc_entry(proc, pl.pid, "Hyprland", 4000, OWNER)       # lies about its name
fs.proc_entry(proc, 4000, "zsh", 3999, OWNER)
fs.proc_entry(proc, 3999, "ghostty", fs.SHELL_STARTER, OWNER)
fs.proc_entry(proc, fs.SHELL_STARTER, "start-hyprland", fs.LEADER, OWNER)
fs.proc_entry(proc, fs.LEADER, "greetd", 1118, 0)
s, why = b.open_wayland()
check("planted: a process named Hyprland started from a terminal inside the session (ancestry ghostty) is refused", s is None)
pl.kill()
done(t, sv)

b, t, wl, proc, sv = world(real=False)
pl = fs.listener_child(f"{wl}/wayland-0")
children.append(pl)
fs.proc_entry(proc, pl.pid, "Hyprland", 4000, OWNER)       # lies about name and parent, but the chain never reaches the leader
fs.proc_entry(proc, 4000, "start-hyprland", 1, OWNER)
fs.proc_entry(proc, fs.LEADER, "greetd", 1118, 0)
s, why = b.open_wayland()
check("planted: a Hyprland whose parents do not lead to logind's session leader is refused", s is None)
pl.kill()
done(t, sv)

b, t, wl, proc, sv = world(real=False)
pl = fs.listener_child(f"{wl}/wayland-0")
children.append(pl)
fs.login_chain(proc, OWNER, pl.pid)
fs.proc_entry(proc, pl.pid, "Hyprland", fs.SHELL_STARTER, 0)    # same chain but as root
s, why = b.open_wayland()
check("planted: the right chain with another uid than the owner is refused", s is None)
fs.login_chain(proc, OWNER, pl.pid)
s, why = b.open_wayland()
check("sanity: the same child with the right chain and uid IS accepted (a separate server process is a valid compositor)", s is not None and peer_pid(s) == pl.pid)
s and s.close()
pl.kill()
done(t, sv)

# --- more than one candidate -----------------------------------------------------------------------------------------------
b, t, wl, proc, sv = world(real=False)
p1 = fs.listener_child(f"{wl}/wayland-0")
p2 = fs.listener_child(f"{wl}/wayland-3")
children += [p1, p2]
fs.login_chain(proc, OWNER, p1.pid)
fs.proc_entry(proc, p2.pid, "Hyprland", fs.SHELL_STARTER, OWNER)
s, why = b.open_wayland()
check("two different compositors that both pass: refused, nothing is guessed", s is None and "several" in why)
p1.kill(); p2.kill()
done(t, sv)

b, t, wl, proc, sv = world()
os.symlink(f"{wl}/wayland-1", f"{wl}/wayland-0")
s, why = b.open_wayland()
check("a symlink to the real socket is the same compositor, not a second candidate", s is not None and peer_pid(s) == ME)
s and s.close()
done(t, sv)

# --- logind ----------------------------------------------------------------------------------------------------------------
for name, kw, expect in (
        ("no ACTIVE session on seat0", {"logind": {"with_active": False}}, "no active session"),
        ("an active session of another user", {"logind": {"active_uid": OWNER + 1}}, "not the owner's"),
        ("a session that is not active", {"logind": {"state": "closing"}}, "does not look like"),
        ("a session on another seat", {"logind": {"seat": "seat1"}}, "does not look like"),
        ("a session leader of 1 (init)", {"logind": {"leader": 1}}, "no leader")):
    b, t, wl, proc, sv = world(**kw)
    s, why = b.open_wayland()
    check(f"logind: {name} = no socket is trusted", s is None and expect in why)
    done(t, sv)

b, t, wl, proc, sv = world(logind={"leader": 4321})
s, why = b.open_wayland()
check("logind: a leader that is not the compositor's ancestor = refused", s is None)
done(t, sv)

b, t, wl, proc, sv = world()
shutil.rmtree(f"{t}/logind")
s, why = b.open_wayland()
check("logind: unreadable runtime files = refused, with a reason", s is None and why)
done(t, sv)

b, t, wl, proc, sv = world(real=False)
s, why = b.open_wayland()
check("no socket at all = a clear error that names usr clipboard-acl", s is None and "clipboard-acl" in why)
done(t, sv)

# --- the screen lock check follows the same proc dir -----------------------------------------------------------------------
b, t, wl, proc, sv = world()
check("lock check: no hyprlock in the process list", b.screen_locked() is False)
fs.proc_entry(proc, 5555, "hyprlock", 1, OWNER)
check("lock check: hyprlock running = locked", b.screen_locked() is True)
done(t, sv)

for c in children:
    c.kill()
sys.exit(0 if all(results) else 1)
