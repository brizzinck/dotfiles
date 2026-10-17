#!/usr/bin/env python3
"""vault-who: which Linux user is the password prompt of a window for? (read-only, never touches a secret)

Used by `vault.sh user-pass` (SUPER+CTRL+U). Prints one JSON object:
  {"address", "class", "pid", "kind", "user", "rule", "detail"}
kind is `terminal` (type is allowed), `polkit` (type is allowed) or `other` (copy only) and `none` (no window).
user is empty when it cannot be determined (the caller then opens a picker).

  vault-who.py [--address 0x...]                window from `hyprctl clients -j` (default: the focused one)
  vault-who.py --pid PID --class CLASS          offline: analyse a process tree (tests)
  --no-tmux-query                               skip `tmux list-clients` (tests the /proc fallback)

Terminal windows: the terminal emulator's pty -> the foreground process group of that pty. When a tmux client runs
there, the client -> its session -> the active pane -> the foreground group of the pane's pty. A tmux server of another
user (the `tdterm` window) cannot be queried, so its panes are read from /proc: one pane or all panes agreeing, else
the panes that wait at sudo/su/doas, else undetermined.
Prompt rules: sudo / doas -> the invoking (real) uid, never root; `su [-] NAME` -> NAME, plain su -> root; anything else
(ssh, passwd, a shell, ...) -> the real uid of the foreground process. sudo/doas that already run a command are
followed into that command.
"""
import json
import os
import pwd
import subprocess
import sys

TERMINAL_CLASSES = {
    "com.mitchellh.ghostty", "ghostty", "alacritty", "kitty", "foot", "footclient", "xterm", "st", "st-256color",
    "konsole", "org.kde.konsole", "gnome-terminal-server", "org.gnome.terminal", "terminator", "tilix",
    "xfce4-terminal", "org.wezfurlong.wezterm", "wezterm", "urxvt", "lxterminal", "org.codeberg.dnkl.foot",
    "contour", "rio", "terminology",
}
TERMINAL_COMMS = {
    "ghostty", "alacritty", "kitty", "foot", "footclient", "wezterm-gui", "xterm", "st", "konsole",
    "gnome-terminal-", "terminator", "tilix", "xfce4-terminal", "urxvt", "lxterminal", "contour", "rio",
}
MENU_CLASSES = {"float.tui"}          # fzf-menu / hub terminals: never a target
POLKIT_CLASSES = {"hyprpolkitagent"}
SUDO_LIKE = {"sudo", "sudoedit", "doas"}
PROMPT_COMMS = SUDO_LIKE | {"su"}


class Proc:
    __slots__ = ("pid", "ppid", "pgrp", "sid", "tty", "tpgid", "comm", "_uid")

    def __init__(self, pid, comm, ppid, pgrp, sid, tty, tpgid):
        self.pid, self.comm, self.ppid, self.pgrp, self.sid, self.tty, self.tpgid = pid, comm, ppid, pgrp, sid, tty, tpgid
        self._uid = None

    @property
    def uid(self):
        """Real uid (the invoking user for the setuid sudo / su)."""
        if self._uid is None:
            self._uid = -1
            try:
                with open(f"/proc/{self.pid}/status") as fh:
                    for line in fh:
                        if line.startswith("Uid:"):
                            self._uid = int(line.split()[1])
                            break
            except OSError:
                pass
        return self._uid

    def cmdline(self):
        try:
            with open(f"/proc/{self.pid}/cmdline", "rb") as fh:
                return [a.decode("utf-8", "replace") for a in fh.read().split(b"\0") if a]
        except OSError:
            return []


def read_procs():
    procs = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat") as fh:
                data = fh.read()
        except OSError:
            continue
        left, right = data.find("("), data.rfind(")")
        if left < 0 or right < 0:
            continue
        rest = data[right + 2:].split()
        try:
            procs[int(name)] = Proc(int(name), data[left + 1:right], int(rest[1]), int(rest[2]), int(rest[3]),
                                    int(rest[4]), int(rest[5]))
        except (IndexError, ValueError):
            continue
    return procs


def uid_name(uid):
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def children(procs, pid):
    return sorted((p for p in procs.values() if p.ppid == pid), key=lambda p: p.pid)


def descendants(procs, pid):
    out, todo = [], [pid]
    while todo:
        cur = todo.pop()
        for kid in children(procs, cur):
            out.append(kid)
            todo.append(kid.pid)
    return out


def su_target(argv):
    """The NAME of `su [options] [-] [NAME [args]]`; root when absent. argv may start with an interpreter (scripts)."""
    for i, a in enumerate(argv):
        if os.path.basename(a) == "su":
            argv = argv[i + 1:]
            break
    with_arg_long = {"--command", "--shell", "--group", "--supp-group", "--whitelist-environment"}
    with_arg_short = set("cgGsw")
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if a == "-":
            i += 1
            continue
        if a.startswith("--"):
            i += 2 if a in with_arg_long else 1
            continue
        if a.startswith("-"):
            for pos, ch in enumerate(a[1:], start=1):
                if ch in with_arg_short:
                    i += 1 if pos < len(a) - 1 else 2   # value attached (-cfoo) or in the next word
                    break
            else:
                i += 1
            continue
        break
    return argv[i] if i < len(argv) else "root"


def decide(procs, proc, depth=0):
    """(user, rule, comm of the deciding process) for the prompt of `proc`."""
    comm = proc.comm
    if comm in SUDO_LIKE:
        kids = children(procs, proc.pid)
        if kids and depth < 8:   # authenticated: a command runs under it, follow it
            user, rule, c = decide(procs, kids[-1], depth + 1)
            return user, f"{comm} runs a command; {rule}", c
        return uid_name(proc.uid), f"{comm} asks the invoking user (real uid {proc.uid}), not root", comm
    if comm == "su":
        target = su_target(proc.cmdline())
        return target, f"su asks the target user ({target}; plain su is root)", comm
    return uid_name(proc.uid), f"foreground process {comm} (uid {proc.uid})", comm


def pick_fg(fg):
    for p in fg:
        if p.comm in PROMPT_COMMS:
            return p
    leaders = [p for p in fg if p.pid == p.pgrp]
    return (leaders or sorted(fg, key=lambda p: p.pid))[0]


def fg_of(procs, tty, tpgid):
    return [p for p in procs.values() if p.tty == tty and p.pgrp == tpgid]


def decide_tty(procs, tty, tpgid):
    fg = fg_of(procs, tty, tpgid)
    if not fg:
        return None
    proc = pick_fg(fg)
    user, rule, comm = decide(procs, proc)
    return {"user": user, "rule": rule, "comm": comm, "detail": f"foreground group {tpgid}: {proc.comm} ({proc.pid})"}


def tmux_socket_args(argv):
    out, i = [], 1
    while i < len(argv) and argv[i].startswith("-"):
        a = argv[i]
        if a in ("-L", "-S") and i + 1 < len(argv):
            out += [a, argv[i + 1]]
            i += 2
        elif a in ("-f", "-c") and i + 1 < len(argv):
            i += 2
        elif a[:2] in ("-L", "-S") and len(a) > 2:
            out += [a[:2], a[2:]]
            i += 1
        else:
            i += 1
    return out


def tmux_active_pane(client):
    """pane_pid of the active pane of the session the tmux client is attached to (own server only), or None."""
    argv0 = client.cmdline()
    env = dict(os.environ)
    env.pop("TMUX", None)
    try:
        with open(f"/proc/{client.pid}/environ", "rb") as fh:
            for item in fh.read().split(b"\0"):
                if item.startswith(b"TMUX_TMPDIR="):
                    env["TMUX_TMPDIR"] = item[12:].decode()
    except OSError:
        pass
    base = ["tmux"] + tmux_socket_args(argv0)

    def run(*args):
        try:
            res = subprocess.run(base + list(args), capture_output=True, text=True, timeout=3, env=env)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return res.stdout if res.returncode == 0 else None

    clients = run("list-clients", "-F", "#{client_pid}\t#{session_name}")
    if not clients:
        return None
    session = next((ln.split("\t", 1)[1] for ln in clients.splitlines()
                    if ln.split("\t", 1)[0] == str(client.pid) and "\t" in ln), None)
    if session is None:
        return None
    pane = run("display-message", "-p", "-t", f"={session}:", "#{pane_pid}")
    try:
        return int(pane.strip()) if pane else None
    except ValueError:
        return None


def analyse_terminal(procs, pid, no_tmux):
    me = procs.get(pid)
    own_tty = me.tty if me else 0
    desc = descendants(procs, pid)
    ptys = {p.tty for p in desc if p.tty and p.tty != own_tty}
    if not ptys:
        return {"user": "", "rule": "no pty below the terminal process", "detail": ""}
    if len(ptys) > 1:
        return {"user": "", "rule": "several ptys (tabs) in one terminal process", "detail": ""}
    tty = ptys.pop()
    on_tty = [p for p in desc if p.tty == tty]
    client = next((p for p in on_tty if p.comm in ("tmux", "tmux: client")), None)
    if client is None:
        res = decide_tty(procs, tty, on_tty[0].tpgid)
        return res or {"user": "", "rule": "no foreground process on the pty", "detail": ""}
    # tmux client: ask the server when it is ours, else read the panes from /proc
    if client.uid == os.getuid() and not no_tmux:
        pane_pid = tmux_active_pane(client)
        pane = procs.get(pane_pid) if pane_pid else None
        if pane:
            res = decide_tty(procs, pane.tty, pane.tpgid)
            if res:
                res["rule"] = "tmux active pane: " + res["rule"]
                res["detail"] = f"tmux client {client.pid}, pane pid {pane.pid}; " + res["detail"]
                return res
    servers = {p.pid for p in procs.values() if p.comm.startswith("tmux: server") and p.uid == client.uid}
    panes = [p for p in procs.values() if p.ppid in servers and p.tty]
    results = [r for r in (decide_tty(procs, p.tty, p.tpgid) for p in panes) if r]
    who = uid_name(client.uid)
    if not results:
        return {"user": "", "rule": f"tmux server of {who} has no readable pane", "detail": f"tmux client {client.pid}"}
    users = {r["user"] for r in results}
    if len(users) == 1:
        res = results[0]
        res["rule"] = (f"tmux server of {who} not queried, {'only pane' if len(results) == 1 else 'all panes agree'}: "
                       + res["rule"])
        res["detail"] = f"tmux client {client.pid}, {len(results)} pane(s) read from /proc"
        return res
    waiting = [r for r in results if r["comm"] in PROMPT_COMMS]
    if waiting and len({r["user"] for r in waiting}) == 1:
        res = waiting[0]
        res["rule"] = f"tmux server of {who} not queried, the pane at {res['comm']}: " + res["rule"]
        res["detail"] = f"tmux client {client.pid}, {len(results)} pane(s) read from /proc"
        return res
    return {"user": "", "rule": f"tmux server of {who} not queryable and its panes disagree",
            "detail": f"tmux client {client.pid}, {len(results)} pane(s)"}


def window_info(address):
    try:
        out = subprocess.run(["hyprctl", "-j", "activewindow" if not address else "clients"], capture_output=True,
                             text=True, timeout=3).stdout
        data = json.loads(out or "{}")
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None
    if address:
        want = address.removeprefix("address:")
        data = next((c for c in data if c.get("address") == want), None)
    return data or None


def analyse(win_class, pid, no_tmux):
    cls = (win_class or "").lower()
    res = {"class": win_class or "", "pid": pid, "kind": "other", "user": "", "rule": "", "detail": ""}
    owner = uid_name(os.getuid())
    if cls in POLKIT_CLASSES:
        res.update(kind="polkit", user=owner, rule="polkit agent dialog: the session owner")
        return res
    procs = read_procs()
    proc = procs.get(pid)
    is_terminal = cls not in MENU_CLASSES and (cls in TERMINAL_CLASSES or (proc is not None and proc.comm in TERMINAL_COMMS))
    if is_terminal:
        res["kind"] = "terminal"
        res.update(analyse_terminal(procs, pid, no_tmux))
        return res
    if proc is not None:
        res.update(user=uid_name(proc.uid), rule=f"not a terminal: owner of the window process ({proc.comm})")
    else:
        res.update(user=owner, rule="not a terminal: the session owner")
    return res


def main(argv):
    address = pid = cls = None
    no_tmux = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--address" and i + 1 < len(argv):
            address = argv[i + 1]
            i += 1
        elif a == "--pid" and i + 1 < len(argv):
            pid = int(argv[i + 1])
            i += 1
        elif a == "--class" and i + 1 < len(argv):
            cls = argv[i + 1]
            i += 1
        elif a == "--no-tmux-query":
            no_tmux = True
        else:
            print(__doc__, file=sys.stderr)
            return 2
        i += 1
    if pid is None:
        win = window_info(address)
        if not win:
            print(json.dumps({"address": address or "", "class": "", "pid": 0, "kind": "none", "user": "",
                              "rule": "no window", "detail": ""}))
            return 0
        pid, cls, address = int(win.get("pid") or 0), win.get("class", ""), win.get("address", "")
    res = analyse(cls, pid, no_tmux)
    res["address"] = address or ""
    print(json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
