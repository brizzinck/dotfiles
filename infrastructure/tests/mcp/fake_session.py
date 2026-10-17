"""Helpers for the tgconfirm tests: a fake /proc, a fake /run/systemd (logind) and real unix sockets that play Wayland servers.

The broker reads processes from TGCONFIRM_PROC and sessions from TGCONFIRM_LOGIND, so a test can describe any process tree
without starting it. A "compositor" is a real listening unix socket; SO_PEERCRED reports the pid of whoever called listen(), so a
socket listened on by this very process is the server with pid os.getpid(), and a socket listened on by a child process
(listener_child) is the server with that child's pid. Nothing here touches the real /proc, /run/user or a Wayland session."""
import os
import socket
import subprocess
import sys
import threading

LEADER = 1999
SHELL_STARTER = 2000


def proc_entry(proc, pid, name, ppid, uid):
    d = os.path.join(proc, str(pid))
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "status"), "w") as f:
        f.write(f"Name:\t{name}\nUmask:\t0022\nPPid:\t{ppid}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\nGid:\t{uid}\t{uid}\t{uid}\t{uid}\n")
    with open(os.path.join(d, "comm"), "w") as f:
        f.write(name + "\n")


def logind(root, owner_uid, leader=LEADER, session="10", active_uid=None, state="active", seat="seat0", with_active=True):
    os.makedirs(os.path.join(root, "seats"), exist_ok=True)
    os.makedirs(os.path.join(root, "sessions"), exist_ok=True)
    with open(os.path.join(root, "seats", "seat0"), "w") as f:
        f.write("# This is private data. Do not parse.\nIS_SEAT0=1\n")
        if with_active:
            f.write(f"ACTIVE={session}\nACTIVE_UID={owner_uid if active_uid is None else active_uid}\nSESSIONS={session}\n")
    with open(os.path.join(root, "sessions", session), "w") as f:
        f.write(f"UID={owner_uid}\nACTIVE=1\nSTATE={state}\nSEAT={seat}\nLEADER={leader}\nSERVICE=greetd\n")


def login_chain(proc, owner_uid, compositor_pid, comm="Hyprland", starter="start-hyprland", shell=None, leader=LEADER):
    """leader (greetd worker, root) -> [login shell] -> start-hyprland -> compositor."""
    proc_entry(proc, leader, "greetd", 1118, 0)
    parent = leader
    if shell:
        proc_entry(proc, 1998, shell, leader, owner_uid)
        parent = 1998
    proc_entry(proc, SHELL_STARTER, starter, parent, owner_uid)
    proc_entry(proc, compositor_pid, comm, SHELL_STARTER, owner_uid)


class Server:
    """A listening unix socket in this process that accepts and holds connections (a stand-in for a compositor)."""

    def __init__(self, path):
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX)
        if os.path.exists(path):
            os.unlink(path)
        self.sock.bind(path)
        self.sock.listen(16)
        self.conns = []
        self.alive = True
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while self.alive:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            self.conns.append(c)

    def close(self):
        self.alive = False
        self.sock.close()
        for c in self.conns:
            c.close()


def listener_child(path):
    """A separate process that listens on `path` (so its pid is the server pid). Returns the Popen; .pid is the server."""
    code = ("import socket,sys,os,time\n"
            "p=sys.argv[1]\n"
            "s=socket.socket(socket.AF_UNIX)\n"
            "os.path.exists(p) and os.unlink(p)\n"
            "s.bind(p); s.listen(8); os.chmod(p,0o666)\n"
            "print('ready',flush=True)\n"
            "time.sleep(600)\n")
    pr = subprocess.Popen([sys.executable, "-c", code, path], stdout=subprocess.PIPE, text=True)
    pr.stdout.readline()
    return pr
