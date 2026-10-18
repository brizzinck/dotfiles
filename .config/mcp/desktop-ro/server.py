#!/usr/bin/env python3
"""desktop-ro: a small, read-only MCP server for the desktop session (stdio).

Started by the MCP gateway (mcp-proxy, `.config/mcp/gateway.json`) from the pinned venv in
~/.local/share/mcp/venv. Every tool is read-only and has a fixed argv (no shell, no free-form command):

  hypr_clients, hypr_activewindow, hypr_monitors, hypr_workspaces   hyprctl -j
  media_status                                                       playerctl
  notifications_history                                              dunstctl history (content of messaging, mail and
                                                                     password-manager apps hidden, one-time codes masked)
  journal_user, user_units_failed                                    journalctl --user / systemctl --user (secrets masked)
  clipboard_text                                                     wl-paste, text only, size cap; entries marked
                                                                     sensitive (wl-copy --sensitive, password managers) refused

What is deliberately NOT here: hyprctl dispatch/keyword/exec, dunstctl close/action, notify-send, playerctl control,
systemctl mutations, `cliphist list` (300 past entries), screenshots, any generic "run". Hyprland, Wayland and the session bus
are found at call time because the gateway starts at boot (linger), before the graphical session exists.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
CMD_TIMEOUT = 6.0
MAX_OUTPUT_BYTES = 24_000
CLIP_MAX_CHARS = 8_000
SENSITIVE_MIMES = ("x-kde-passwordmanagerhint", "x-kde-passwordmanager")
# content of these apps is never returned by notifications_history (only that a notification came from them); `terminal` is the
# long-command toast of ~/.config/hypr/scripts/cmd-notify.sh, whose body is a typed command line (it can hold a secret no filter knows)
NOTIF_HIDE_APPS = os.environ.get(
    "DESKTOP_RO_NOTIF_HIDE_APPS",
    r"telegram|signal|whatsapp|discord|slack|element|matrix|thunderbird|mail|bitwarden|rbw|vault|keepass|2fa|otp|sms|kdeconnect|terminal",
)

mcp = FastMCP("desktop-ro")


# --- environment of the graphical session, resolved per call -------------------------------------------------------------
def _runtime_dir() -> Path:
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")


def _session_env() -> dict[str, str]:
    env = dict(os.environ)
    rt = _runtime_dir()
    env.setdefault("XDG_RUNTIME_DIR", str(rt))
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path={rt}/bus")
    if not env.get("WAYLAND_DISPLAY"):
        socks = sorted(p for p in rt.glob("wayland-*") if not p.name.endswith(".lock"))
        if socks:
            env["WAYLAND_DISPLAY"] = socks[0].name
    if not env.get("HYPRLAND_INSTANCE_SIGNATURE"):
        live = [d for d in (rt / "hypr").glob("*") if (d / ".socket.sock").exists()]
        if live:
            env["HYPRLAND_INSTANCE_SIGNATURE"] = max(live, key=lambda d: d.stat().st_mtime).name
    return env


def _run(argv: list[str], *, session: bool = True, timeout: float = CMD_TIMEOUT) -> tuple[int, str, str]:
    try:
        cp = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            env=_session_env() if session else None,
            stdin=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        return 127, "", f"{argv[0]}: not installed"
    except subprocess.TimeoutExpired:
        return 124, "", f"{argv[0]}: timed out after {timeout:.0f}s"
    return cp.returncode, cp.stdout, cp.stderr.strip()


def _cap(text: str, limit: int = MAX_OUTPUT_BYTES) -> str:
    raw = text.encode("utf-8", "replace")
    if len(raw) <= limit:
        return text
    return raw[:limit].decode("utf-8", "ignore") + f"\n[... truncated, {len(raw) - limit} more bytes]"


# --- redaction -----------------------------------------------------------------------------------------------------------
_KV_SECRET = re.compile(
    r"(?i)\b(pass(?:word|wd|phrase)?|secret|token|api[_-]?key|apikey|authorization|bearer|credential|session[_-]?string)\b(\s*[:=]\s*|\s+)(\"?)((?:(?:Bearer|Basic|Token)\s+)?[^\s\"',;]+)"
)
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")
_PREFIXED = re.compile(r"\b(?:sk|pk|ghp|gho|ghs|github_pat|xox[abprs]|glpat|AKIA)[-_A-Za-z0-9]{12,}\b")
_BLOB = re.compile(r"\b(?:[A-Fa-f0-9]{40,}|[A-Za-z0-9+/_-]{48,}={0,2})\b")
_CODE = re.compile(r"(?<![\w.])\d{4,8}(?![\w.])")


def redact_text(text: str) -> str:
    """Mask the obvious secret shapes in log lines and notification text (best effort, not a boundary)."""
    text = _JWT.sub("[jwt]", text)
    text = _PREFIXED.sub("[key]", text)
    text = _KV_SECRET.sub(lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)}[hidden]", text)
    return _BLOB.sub("[blob]", text)


def mask_codes(text: str) -> str:
    """One-time-code shapes (4-8 digit runs) in notification text."""
    return _CODE.sub("[code]", text)


# --- Hyprland ------------------------------------------------------------------------------------------------------------
def _hyprctl(*args: str) -> Any:
    rc, out, err = _run(["hyprctl", "-j", *args])
    if rc != 0:
        raise RuntimeError(err or f"hyprctl exited with {rc} (is a Hyprland session running?)")
    return json.loads(out)


def _pick(obj: dict[str, Any], keys: tuple[str, ...]) -> dict[str, Any]:
    return {k: obj[k] for k in keys if k in obj}


_WINDOW_KEYS = (
    "address", "class", "initialClass", "title", "pid", "floating", "fullscreen", "pinned", "xwayland",
    "at", "size", "monitor", "focusHistoryID", "tags", "grouped",
)


def _window(w: dict[str, Any]) -> dict[str, Any]:
    d = _pick(w, _WINDOW_KEYS)
    ws = w.get("workspace") or {}
    d["workspace"] = ws.get("name", ws.get("id"))
    return d


@mcp.tool(annotations=READ_ONLY)
def hypr_clients() -> list[dict[str, Any]]:
    """All open windows (Hyprland): address, class, title, workspace, monitor, geometry, floating/fullscreen, pid."""
    return [_window(w) for w in _hyprctl("clients")]


@mcp.tool(annotations=READ_ONLY)
def hypr_activewindow() -> dict[str, Any]:
    """The focused window (Hyprland); an empty object when nothing is focused."""
    w = _hyprctl("activewindow")
    return _window(w) if w else {}


@mcp.tool(annotations=READ_ONLY)
def hypr_monitors() -> list[dict[str, Any]]:
    """Monitors: name, description, resolution, refresh rate, scale, position, active workspace, focused, dpms."""
    keys = ("id", "name", "description", "width", "height", "refreshRate", "x", "y", "scale", "focused", "dpmsStatus", "transform")
    out = []
    for m in _hyprctl("monitors"):
        d = _pick(m, keys)
        d["activeWorkspace"] = (m.get("activeWorkspace") or {}).get("name")
        d["specialWorkspace"] = (m.get("specialWorkspace") or {}).get("name") or None
        out.append(d)
    return out


@mcp.tool(annotations=READ_ONLY)
def hypr_workspaces() -> list[dict[str, Any]]:
    """Workspaces: id, name, monitor, window count, last window title."""
    keys = ("id", "name", "monitor", "windows", "hasfullscreen", "lastwindowtitle")
    return [_pick(w, keys) for w in _hyprctl("workspaces")]


# --- media ---------------------------------------------------------------------------------------------------------------
@mcp.tool(annotations=READ_ONLY)
def media_status() -> list[dict[str, str]]:
    """Media players (MPRIS): player, status (Playing/Paused/Stopped), artist, title, album. Read-only: no play/pause."""
    fmt = "{{playerName}}\t{{status}}\t{{artist}}\t{{title}}\t{{album}}"
    rc, out, err = _run(["playerctl", "-a", "metadata", "--format", fmt])
    if rc != 0 and not out.strip():
        if "No players found" in err or not err:
            return []
        raise RuntimeError(err)
    rows = []
    for line in out.splitlines():
        parts = (line.split("\t") + [""] * 5)[:5]
        rows.append(dict(zip(("player", "status", "artist", "title", "album"), parts)))
    return rows


# --- notifications ---------------------------------------------------------------------------------------------------------
def _dunst_value(v: Any) -> Any:
    # dunstctl history prints {"type": "aa{sv}", "data": [[{"body": {"type": "s", "data": "..."}, ...}]]}
    return v.get("data") if isinstance(v, dict) and "data" in v else v


@mcp.tool(annotations=READ_ONLY)
def notifications_history(limit: int = 20) -> list[dict[str, Any]]:
    """Recent notifications from dunst, newest first (limit 1-50). Text of messaging, mail and password-manager apps is
    hidden (only the app name and time are returned), other apps get their text with one-time codes masked."""
    limit = max(1, min(int(limit), 50))
    rc, out, err = _run(["dunstctl", "history"])
    if rc != 0:
        raise RuntimeError(err or f"dunstctl exited with {rc}")
    data = json.loads(out).get("data", [[]])
    items = data[0] if data else []
    hide = re.compile(NOTIF_HIDE_APPS, re.IGNORECASE)
    rows: list[dict[str, Any]] = []
    for it in items[:limit]:
        f = {k: _dunst_value(v) for k, v in it.items()}
        app = str(f.get("appname") or "")
        row: dict[str, Any] = {"app": app, "urgency": f.get("urgency"), "timestamp": f.get("timestamp")}
        if hide.search(app) or hide.search(str(f.get("desktop_entry") or "")):
            row["summary"] = "[hidden: this app's notification text is not shared]"
        else:
            row["summary"] = mask_codes(redact_text(str(f.get("summary") or "")))[:200]
            row["body"] = mask_codes(redact_text(str(f.get("body") or "")))[:400]
        rows.append(row)
    return rows


# --- journal ---------------------------------------------------------------------------------------------------------------
_UNIT = re.compile(r"^[A-Za-z0-9@._:\\-]{1,120}\.(service|timer|socket|target|path|mount|scope)$")
_PRIORITIES = {"emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"}


@mcp.tool(annotations=READ_ONLY)
def journal_user(unit: str, lines: int = 50, priority: str = "", since: str = "") -> str:
    """Last log lines of one systemd USER unit (for example `mcp-gateway.service`), at most 200, secrets masked.
    priority: optional minimum level (err, warning, ...). since: optional journalctl time like `-1h` or `today`."""
    if not _UNIT.match(unit):
        raise ValueError("unit must look like name.service (user units only)")
    argv = ["journalctl", "--user", "-u", unit, "-n", str(max(1, min(int(lines), 200))), "--no-pager", "-o", "short-iso"]
    if priority:
        if priority not in _PRIORITIES:
            raise ValueError(f"priority must be one of {sorted(_PRIORITIES)}")
        argv += ["-p", priority]
    if since:
        if not re.fullmatch(r"[A-Za-z0-9 :+._-]{1,40}", since):
            raise ValueError("since: use a plain journalctl time such as -1h, today or 2026-10-17")
        argv += ["--since", since]
    rc, out, err = _run(argv)
    if rc != 0:
        raise RuntimeError(err or f"journalctl exited with {rc}")
    return _cap(redact_text(out)) or "(no log lines)"


@mcp.tool(annotations=READ_ONLY)
def user_units_failed() -> str:
    """Failed systemd user units (`systemctl --user --failed`)."""
    rc, out, err = _run(["systemctl", "--user", "--failed", "--no-legend", "--no-pager", "--plain"])
    if rc != 0:
        raise RuntimeError(err or f"systemctl exited with {rc}")
    return out.strip() or "(no failed user units)"


# --- clipboard ---------------------------------------------------------------------------------------------------------------
@mcp.tool(annotations=READ_ONLY)
def clipboard_text(source: str = "clipboard", max_chars: int = 4000) -> str:
    """Current text of the clipboard or the primary selection (source = clipboard | primary), at most 8000 characters. Text
    only; refuses entries marked sensitive (wl-copy --sensitive, password managers) and never reads the clipboard history."""
    if source not in ("clipboard", "primary"):
        raise ValueError("source must be clipboard or primary")
    base = ["wl-paste", *(["--primary"] if source == "primary" else [])]
    rc, types, err = _run([*base, "--list-types"])
    if rc != 0:
        return f"(no {source} content: {err or 'empty'})"
    mimes = [t.strip().lower() for t in types.splitlines() if t.strip()]
    if any(m in SENSITIVE_MIMES for m in mimes):
        return f"(the {source} entry is marked sensitive and is not shared)"
    if not any(m.startswith("text/") or m in ("string", "utf8_string", "text") for m in mimes):
        return f"(the {source} holds no text: {', '.join(mimes[:4]) or 'empty'})"
    rc, out, err = _run([*base, "--no-newline", "--type", "text/plain"])
    if rc != 0:
        return f"(no {source} text: {err or 'empty'})"
    limit = max(1, min(int(max_chars), CLIP_MAX_CHARS))
    text = out[:limit]
    return text + (f"\n[... truncated, {len(out) - limit} more characters]" if len(out) > limit else "")


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    sys.exit(main())
