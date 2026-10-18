#!/usr/bin/env python3
"""term-procs: what dies when a ghostty window closes (used by safe-close.sh, SUPER+W).

  term-procs.py PID          PID = the ghostty process of the window. Prints one tab separated line:
                             kind <TAB> session <TAB> destroys <TAB> attached <TAB> summary
                             kind     tmux (a tmux client runs in the window) or plain
                             session  the client's current tmux session (empty for plain)
                             destroys 1 when closing the window destroys the session (destroy-unattached on, last client)
                             summary  the foreground commands that are not an idle shell, e.g. "claude (2), nvim, go test"
  term-procs.py --label ARGV...   print the label of one command line (tests)
  term-procs.py --detached   one line per unattached term-* tmux session (a window that closed before destroy-unattached
                             worked): name <TAB> created (epoch) <TAB> windows <TAB> summary (empty = only idle shells).
                             kill-session.sh --detached and the hub row "Clean up detached terminal sessions" list them.

Foreground = the process group that owns the pane's terminal (tcgetpgrp), read from /proc: nested shells, a pager or a
`go test` run in the shell count, an idle zsh/bash does not. Background and stopped jobs of the same terminal count too. TERMPROCS_TMUX overrides the tmux command (tests use `tmux -L x`).
"""
import os
import re
import shlex
import subprocess
import sys
from collections import OrderedDict

IDLE_SHELLS = {"zsh", "bash", "fish", "sh", "dash", "nu", "elvish"}
RUNTIMES = {"node", "nodejs", "bun", "deno", "python", "python3", "ruby", "perl", "bash", "sh", "env"}
WITH_SUBCOMMAND = {"go", "cargo", "npm", "pnpm", "yarn", "make", "docker", "git", "uv", "pip", "pipx", "kubectl", "terraform", "gradle", "mvn", "ssh"}
KNOWN_AGENTS = ("claude", "codex", "gemini")
TMUX = shlex.split(os.environ.get("TERMPROCS_TMUX", "tmux"))


def label(argv):
    """Short name of a command line: claude, codex, nvim, go test, ..."""
    if not argv:
        return ""
    joined = " ".join(argv)
    base = os.path.basename(argv[0]).lstrip("-")
    for agent in KNOWN_AGENTS:
        if re.search(r"(^|[/\s_-])" + agent + r"($|[\s/._-])", joined):
            return agent
    if base in ("vim", "nvim", "vi", "view"):
        return "nvim" if base == "nvim" else "vim"
    if base == "env":
        # env [-i] KEY=VALUE... COMMAND ARGS: label the command
        rest = [a for a in argv[1:] if not a.startswith("-") and "=" not in a.split("/")[0]]
        return label(rest) if rest else base
    args = [a for a in argv[1:] if not a.startswith("-")]
    if base in RUNTIMES and args:
        script = os.path.basename(args[0])
        script = re.sub(r"\.(m?js|cjs|py|rb|pl|sh)$", "", script)
        return base if script in ("index", "cli", "main", "app", "server", "run") or not script else script
    if base in WITH_SUBCOMMAND and args:
        return base + " " + args[0]
    return base


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


def snapshot():
    """pid -> dict(ppid, pgrp, tty, tpgid, argv) for every readable process"""
    procs = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        raw = read(f"/proc/{name}/stat").decode(errors="replace")
        if not raw:
            continue
        # comm may contain spaces and parentheses: split after the last ')'
        tail = raw[raw.rfind(")") + 2:].split()
        try:
            ppid, pgrp, tty, tpgid = int(tail[1]), int(tail[2]), int(tail[4]), int(tail[5])
        except (IndexError, ValueError):
            continue
        argv = [a.decode(errors="replace") for a in read(f"/proc/{name}/cmdline").split(b"\0") if a]
        procs[int(name)] = {"ppid": ppid, "pgrp": pgrp, "sid": int(tail[3]), "tty": tty, "tpgid": tpgid, "argv": argv}
    return procs


def descendants(procs, root):
    kids = {}
    for pid, p in procs.items():
        kids.setdefault(p["ppid"], []).append(pid)
    out, todo = set(), [root]
    while todo:
        cur = todo.pop()
        for k in kids.get(cur, []):
            if k not in out:
                out.add(k)
                todo.append(k)
    return out


def tmux(*args):
    try:
        r = subprocess.run([*TMUX, *args], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout if r.returncode == 0 else ""


def tty_nr(path):
    try:
        return os.stat(path).st_rdev
    except OSError:
        return None


def under(procs, pid, roots):
    """True when PID is one of ROOTS or has one as an ancestor (a daemon that forked away was reparented, it is not)"""
    for _ in range(64):
        if pid in roots:
            return True
        pid = procs.get(pid, {}).get("ppid", 0)
        if pid <= 1:
            return False
    return False


def foreground_labels(procs, ttys):
    """labels of the non-idle commands of each terminal (tty device numbers in ttys): the foreground job, and the
    background (`cmd &`) and stopped (Ctrl+Z) jobs of the same terminal, which die with it just the same. A process that
    forked away from the shell (wl-copy keeping the clipboard, an agent) is not a job of the terminal."""
    labels = []
    for tty in ttys:
        on_tty = {pid: p for pid, p in procs.items() if p["tty"] == tty}
        if not on_tty:
            continue
        tpgid = next(iter(on_tty.values()))["tpgid"]
        leaders = {pid for pid, p in on_tty.items() if p["sid"] == pid}     # the shell of the pane owns the session
        groups = {}
        for pid, p in on_tty.items():
            if p["pgrp"] == tpgid or under(procs, pid, leaders):
                groups.setdefault(p["pgrp"], []).append(pid)
        # the foreground group first, then the others by group id
        for pg in sorted(groups, key=lambda g: (g != tpgid, g)):
            leader = pg if pg in on_tty else min(groups[pg])
            lab = label(on_tty[leader]["argv"])
            if not lab or lab in IDLE_SHELLS:
                # a forked shell (`(sleep 9) &`, a function in the background) leads a group of its own: its children count
                lab = next((l for l in (label(on_tty[m]["argv"]) for m in sorted(groups[pg])) if l and l not in IDLE_SHELLS), "")
            if lab and lab not in IDLE_SHELLS:
                labels.append(lab)
    return labels


def summarize(labels):
    counts = OrderedDict()
    for lab in labels:
        counts[lab] = counts.get(lab, 0) + 1
    return ", ".join(f"{k} ({v})" if v > 1 else k for k, v in counts.items())


def detached():
    """unattached term-* sessions: name, created, windows, summary of their foreground commands"""
    procs = snapshot()
    fmt = "#{session_name}\t#{session_attached}\t#{session_created}\t#{session_windows}"
    for line in tmux("list-sessions", "-F", fmt).splitlines():
        name, attached, created, windows = (line.split("\t") + ["", "", "", ""])[:4]
        if not name.startswith("term-") or attached != "0":
            continue
        panes = tmux("list-panes", "-s", "-t", "=" + name, "-F", "#{pane_tty}").split()
        ttys = {tty_nr(p) for p in panes} - {None}
        print(f"{name}\t{created}\t{windows}\t{summarize(foreground_labels(procs, ttys))}")


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--label":
        print(label(sys.argv[2:]))
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == "--detached":
        detached()
        return 0
    try:
        win = int(sys.argv[1])
    except (IndexError, ValueError):
        print("usage: term-procs.py PID | --label ARGV... | --detached", file=sys.stderr)
        return 2
    procs = snapshot()
    below = descendants(procs, win)
    clients = {}
    for line in tmux("list-clients", "-F", "#{client_pid}\t#{session_name}").splitlines():
        pid, _, session = line.partition("\t")
        if pid.isdigit():
            clients[int(pid)] = session
    mine = [pid for pid in below if pid in clients]
    if mine:
        session = clients[mine[0]]
        panes = tmux("list-panes", "-s", "-t", session, "-F", "#{pane_tty}").split()
        ttys = {tty_nr(p) for p in panes} - {None}
        destroy = tmux("show-options", "-A", "-v", "-t", session, "destroy-unattached").strip() == "on"
        attached = tmux("display-message", "-p", "-t", session, "#{session_attached}").strip() or "1"
        summary = summarize(foreground_labels(procs, ttys))
        destroys = destroy and attached == "1"
        print(f"tmux\t{session}\t{int(destroys)}\t{attached}\t{summary}")
        return 0
    ttys = {procs[p]["tty"] for p in below if procs[p]["tty"]}
    print(f"plain\t\t1\t1\t{summarize(foreground_labels(procs, ttys))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
