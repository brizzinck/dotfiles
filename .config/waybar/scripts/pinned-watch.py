#!/usr/bin/env python3
"""pinned-watch: state of the pinned apps on the waybar (pinned.tsv). One small daemon for all apps and both bars.

It follows two things, both event driven (no polling):
  - the Hyprland event socket (.socket2.sock): windows opened, closed, moved and focused -> which pinned app is running,
    how many windows it has, which one is focused; focusing an app clears its "new" flag
  - the session bus: a monitor connection (BecomeMonitor, read only) sees every org.freedesktop.Notifications.Notify
    call. A notification whose app_name or desktop-entry matches the `notify` column of a row sets that app's "new"
    flag. This works while do-not-disturb is on (dunst paused: the call is still made, only the display is held back),
    for notifications dunst drops or stacks, and needs no rule in the dunst config.

Per app it writes $XDG_RUNTIME_DIR/pinned/<id>.json, the exact output of the waybar module custom/pin#<id>
(scripts/pinned.sh module just cats it), and pokes waybar with RTMIN+14 when any of them changed. The flag of an app is
the file new/<id> (its first line = the notification summary for the tooltip).

  pinned-watch.py            run until the Hyprland socket is gone (a second copy exits at once)
  pinned-watch.py --once     render the module files once from the current windows and flags, then exit (tests)
  pinned-watch.py --refresh  tell the running daemon to re-render now (SIGUSR1; pinned.sh calls it after a click)
  pinned-watch.py --ping     exit 0 when the daemon runs
Test hooks: PINNED_DIR (state dir), PINNED_TSV (app list), PINNED_NO_POKE=1 (do not signal waybar).
"""
import fcntl
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

try:  # GLib.unix_signal_add is deprecated in newer PyGObject
    gi.require_version("GLibUnix", "2.0")
    from gi.repository import GLibUnix  # noqa: E402

    def on_signal(signum, fn):
        GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signum, fn)

except (ValueError, ImportError):

    def on_signal(signum, fn):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, fn)


RT = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
DIR = os.environ.get("PINNED_DIR") or os.path.join(RT, "pinned")
NEW = os.path.join(DIR, "new")
TSV = os.environ.get("PINNED_TSV") or os.path.expanduser("~/.config/waybar/pinned.tsv")
# waybar runs on the private proxy instance <SIG>-wb (waybar-run.sh); Hyprland itself is <SIG>
SIG = re.sub(r"-wb$", "", os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""))
HYPR = os.path.join(RT, "hypr", SIG)
WAYBAR_SIGNAL = "RTMIN+14"
HINT = "L: {} · M: mark read · R: menu"
EVENTS = ("openwindow", "closewindow", "activewindowv2", "movewindowv2", "windowtitlev2")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def esc(text):  # waybar tooltips are pango markup
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def short(text, n=60):
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


# ───────────────────────────── the app list ─────────────────────────────

_apps = {"mtime": None, "rows": []}


def apps():
    """Rows of pinned.tsv: dicts with id label glyph cls launch notify (regexes compiled); re-read when the file changes."""
    try:
        mtime = os.stat(TSV).st_mtime_ns
    except OSError:
        return []
    if mtime == _apps["mtime"]:
        return _apps["rows"]
    rows, seen = [], set()
    with open(TSV, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            f = line.split("\t")
            try:
                if len(f) != 6 or not re.fullmatch(r"[a-z0-9]+", f[0]) or f[0] in seen:
                    raise ValueError("need 6 tab separated fields and a unique [a-z0-9]+ id")
                rows.append(
                    {
                        "id": f[0],
                        "label": f[1],
                        "glyph": f[2],
                        "cls": re.compile(f[3], re.I),
                        "launch": f[4],
                        "notify": None if f[5] == "-" else re.compile(f[5], re.I),
                    }
                )
                seen.add(f[0])
            except (ValueError, re.error) as e:
                log(f"{TSV}:{n}: {e}")
    _apps.update(mtime=mtime, rows=rows)
    return rows


# ───────────────────────────── Hyprland ─────────────────────────────


def request(cmd):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(3)
        s.connect(os.path.join(HYPR, ".socket.sock"))
        s.sendall(cmd.encode())
        chunks = []
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
    return b"".join(chunks).decode(errors="replace")


def snapshot():
    """(clients, address of the focused window)."""
    clients = json.loads(request("j/clients"))
    try:
        active = json.loads(request("j/activewindow") or "{}").get("address", "")
    except ValueError:
        active = ""
    return clients, active


def windows_of(app, clients):
    """Mapped windows of the app, most recently focused first (the hidden fzf-menu terminal is not a window of any app)."""
    w = [
        c
        for c in clients
        if c.get("mapped", True) and app["cls"].search(c.get("class", "")) and c.get("workspace", {}).get("name") != "special:menu"
    ]
    return sorted(w, key=lambda c: c.get("focusHistoryID", 99))


# ───────────────────────────── flags and rendering ─────────────────────────────


def flag_path(app_id):
    return os.path.join(NEW, app_id)


def flag_text(app_id):
    try:
        with open(flag_path(app_id), encoding="utf-8") as fh:
            return fh.readline().strip()
    except OSError:
        return None


def clear_flag(app_id):
    try:
        os.unlink(flag_path(app_id))
    except FileNotFoundError:
        pass


def set_flag(app_id, text):
    tmp = flag_path(app_id) + f".tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(short(text, 80) + "\n")
    os.replace(tmp, flag_path(app_id))


def render_app(app, wins, active):
    focused = any(w["address"] == active for w in wins)
    if focused:
        clear_flag(app["id"])
    new = flag_text(app["id"])
    cls = ["normal" if wins else "dim"]
    if focused:
        cls.append("focused")
    if new is not None:
        cls.append("new")
    state = "not running" if not wins else f"{len(wins)} window" + ("" if len(wins) == 1 else "s")
    lines = [f"<b>{esc(app['label'])}</b> · {state}" + (" · new" if new is not None else "")]
    if new:
        lines.append("New: " + esc(new))
    for w in wins[:6]:
        lines.append("  " + esc(short(w.get("title") or w.get("class", ""), 48)) + f"  (ws {esc(str(w['workspace']['name']))})")
    if len(wins) > 6:
        lines.append(f"  … {len(wins) - 6} more")
    lines += ["", HINT.format("focus (again: next window)" if len(wins) > 1 else "focus" if wins else "launch")]
    return json.dumps({"text": app["glyph"], "class": cls, "tooltip": "\n".join(lines)}, ensure_ascii=False)


def write_if_changed(path, content):
    try:
        with open(path, encoding="utf-8") as fh:
            if fh.read() == content:
                return False
    except OSError:
        pass
    tmp = path + f".tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.replace(tmp, path)
    return True


def poke_waybar():
    if os.environ.get("PINNED_NO_POKE"):
        return
    subprocess.run(["pkill", "-o", "-u", str(os.getuid()), "-" + WAYBAR_SIGNAL, "-x", "waybar"], check=False, stderr=subprocess.DEVNULL)


def render_all():
    """Re-render every module file; poke waybar when something changed. Returns the id of the focused app (or '')."""
    clients, active = snapshot()
    rows = apps()
    changed, focused = False, ""
    for app in rows:
        wins = windows_of(app, clients)
        if any(w["address"] == active for w in wins):
            focused = app["id"]
        changed |= write_if_changed(os.path.join(DIR, app["id"] + ".json"), render_app(app, wins, active) + "\n")
    if changed:
        poke_waybar()
    return focused


# ───────────────────────────── daemon ─────────────────────────────

_timer = {"pending": False}


def refresh_now():
    _timer["pending"] = False
    try:
        render_all()
    except (OSError, ValueError) as e:
        log(f"render: {e}")
    return False


def schedule():  # debounce: a window open fires several events within a few ms
    if not _timer["pending"]:
        _timer["pending"] = True
        GLib.timeout_add(60, refresh_now)
    return False


def hypr_events(loop):
    """Thread: read socket2 lines; any relevant event schedules a refresh; the end of the socket ends the daemon."""
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(os.path.join(HYPR, ".socket2.sock"))
            buf = b""
            while True:
                data = s.recv(65536)
                if not data:
                    break
                buf += data
                *lines, buf = buf.split(b"\n")
                if any(l.split(b">>", 1)[0].decode(errors="replace") in EVENTS for l in lines):
                    GLib.idle_add(schedule)
    except OSError as e:
        log(f"socket2: {e}")
    GLib.idle_add(loop.quit)


def on_notify(app_name, summary, desktop_entry):
    try:
        clients, active = snapshot()
    except (OSError, ValueError):
        return False
    for app in apps():
        if app["notify"] is None:
            continue
        if not (app["notify"].search(app_name) or (desktop_entry and app["notify"].search(desktop_entry))):
            continue
        if any(w["address"] == active for w in windows_of(app, clients)):
            continue  # the app is in front: nothing new for the owner
        set_flag(app["id"], summary or "new notification")
    schedule()
    return False


def bus_filter(_conn, msg, incoming):
    """Runs in a GDBus worker thread: pick org.freedesktop.Notifications.Notify out of the monitored traffic.
    Monitored method calls are dropped here: GDBus would answer them with an error, a monitor must never send, and the
    broker would disconnect it after the first notification."""
    try:
        if msg.get_member() == "Notify" and msg.get_interface() == "org.freedesktop.Notifications":
            body = msg.get_body().unpack()
            hints = body[6] if len(body) > 6 else {}
            GLib.idle_add(on_notify, str(body[0]), str(body[3]), str(hints.get("desktop-entry", "")))
    except Exception as e:  # noqa: BLE001  a malformed message must not stop the monitor
        log(f"filter: {e}")
    return None if incoming and msg.get_message_type() == Gio.DBusMessageType.METHOD_CALL else msg


def watch_bus():
    addr = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None)
    conn = Gio.DBusConnection.new_for_address_sync(
        addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None
    )
    conn.add_filter(bus_filter)
    conn.call_sync(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus.Monitoring",
        "BecomeMonitor",
        GLib.Variant("(asu)", (["type='method_call',interface='org.freedesktop.Notifications',member='Notify'"], 0)),
        None,
        Gio.DBusCallFlags.NONE,
        -1,
        None,
    )
    return conn  # keep the reference: the connection closes with it


def lock_file():
    os.makedirs(NEW, mode=0o700, exist_ok=True)
    fh = open(os.path.join(DIR, "lock"), "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return fh


def pid_of_daemon():
    try:
        return int(open(os.path.join(DIR, "pid")).read())
    except (OSError, ValueError):
        return 0


def daemon_running():
    fh = lock_file()
    if fh is None:
        return True
    fh.close()
    return False


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--ping":
        sys.exit(0 if daemon_running() else 1)
    if arg == "--refresh":
        pid = pid_of_daemon()
        if pid and daemon_running():
            os.kill(pid, signal.SIGUSR1)
            return
        sys.exit(1)
    if arg == "--once":
        os.makedirs(NEW, mode=0o700, exist_ok=True)
        render_all()
        return
    if arg:
        sys.exit("usage: pinned-watch.py [--once | --refresh | --ping]")
    if not SIG or not os.path.exists(os.path.join(HYPR, ".socket2.sock")):
        sys.exit("pinned-watch: no Hyprland instance")
    held = lock_file()
    if held is None:
        return  # already running
    with open(os.path.join(DIR, "pid"), "w") as fh:
        fh.write(str(os.getpid()))
    loop = GLib.MainLoop()
    keep = watch_bus()
    on_signal(signal.SIGUSR1, lambda: schedule() or True)
    on_signal(signal.SIGTERM, loop.quit)
    on_signal(signal.SIGINT, loop.quit)
    threading.Thread(target=hypr_events, args=(loop,), daemon=True).start()
    refresh_now()
    loop.run()
    del keep, held


if __name__ == "__main__":
    main()
