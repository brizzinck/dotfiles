#!/usr/bin/env python3
"""Protocol-level test of desktop-ro against fake hyprctl/playerctl/dunstctl/journalctl/wl-paste (./bin).
Run with the python of the pinned MCP venv: test_desktop_ro.py SERVER_PY FAKE_BIN FAKE_DIR. Prints `ok NAME` / `FAIL NAME`."""
import asyncio
import contextlib
import json
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

server, fakebin, fakedir = sys.argv[1:4]
results = []


def check(name: str, cond: bool) -> None:
    results.append(cond)
    print(("ok " if cond else "FAIL ") + name)


def env(**extra):
    e = {k: v for k, v in os.environ.items() if k not in ("WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE")}
    e["PATH"] = fakebin + ":" + e["PATH"]
    e["FAKE_DIR"] = fakedir
    e["XDG_RUNTIME_DIR"] = fakedir  # no wayland socket, no hypr dir: nothing real can be reached
    e.update(extra)
    return e


@contextlib.asynccontextmanager
async def session(**extra):
    params = StdioServerParameters(command=sys.executable, args=[server], env=env(**extra))
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            yield s


async def call(s, name, args=None):
    res = await s.call_tool(name, args or {})
    text = "\n".join(c.text for c in res.content if hasattr(c, "text"))
    return res.isError, text


async def main():
    async with session() as s:
        await main_default(s)
    async with session(FAKE_CLIP_TYPES="text/plain\\nUTF8_STRING", FAKE_CLIP_TEXT="hello clipboard") as s:
        err, text = await call(s, "clipboard_text")
        check("clipboard returns text", not err and text == "hello clipboard")
        err, text = await call(s, "clipboard_text", {"source": "primary"})
        argv = open(os.path.join(fakedir, "argv.log")).read()
        check("primary selection uses --primary", "wl-paste --primary" in argv)
        err, text = await call(s, "clipboard_text", {"source": "history"})
        check("clipboard refuses another source", err)
    async with session(FAKE_CLIP_TYPES="text/plain\\nx-kde-passwordManagerHint", FAKE_CLIP_TEXT="s3cret-pass") as s:
        err, text = await call(s, "clipboard_text")
        check("clipboard: sensitive entry refused", "s3cret-pass" not in text and "sensitive" in text)
    async with session(FAKE_CLIP_TYPES="image/png", FAKE_CLIP_TEXT="PNGDATA") as s:
        err, text = await call(s, "clipboard_text")
        check("clipboard: image is not text", "PNGDATA" not in text and "no text" in text)
    async with session(FAKE_CLIP_TYPES="text/plain", FAKE_CLIP_TEXT="x" * 20000) as s:
        err, text = await call(s, "clipboard_text", {"max_chars": 999999})
        check("clipboard: size cap", len(text) < 8200 and "truncated" in text)
    argv = open(os.path.join(fakedir, "argv.log")).read().splitlines()
    bad = [l for l in argv if any(w in l for w in ("dispatch", "keyword", "cliphist", "notify-send", "play-pause", "close"))]
    check("no mutating command was ever run", not bad)


async def main_default(s):
    tools = {t.name: t for t in (await s.list_tools()).tools}
    expected = {"hypr_clients", "hypr_activewindow", "hypr_monitors", "hypr_workspaces", "media_status", "notifications_history",
                "journal_user", "user_units_failed", "clipboard_text"}
    check("exactly the nine read-only tools", set(tools) == expected)
    check("every tool is annotated readOnlyHint", all(t.annotations and t.annotations.readOnlyHint for t in tools.values()))
    check("no write-ish tool names", not any(w in n for n in tools for w in ("dispatch", "exec", "run", "send", "notify", "close", "set_", "kill")))

    err, text = await call(s, "hypr_clients")
    check("hypr_clients lists both windows", not err and "org.telegram.desktop" in text and "com.mitchellh.ghostty" in text)
    check("hypr_clients drops unknown fields", "secretfield" not in text)
    err, text = await call(s, "hypr_activewindow")
    check("hypr_activewindow", not err and "ghostty" in text)
    err, text = await call(s, "hypr_monitors")
    check("hypr_monitors", not err and "HDMI-A-1" in text and "2560" in text)
    err, text = await call(s, "hypr_workspaces")
    check("hypr_workspaces", not err and "lastwindowtitle" in text)

    err, text = await call(s, "media_status")
    check("media_status parses playerctl", not err and "Some Title" in text and "Playing" in text)

    err, text = await call(s, "notifications_history", {"limit": 10})
    check("notifications: telegram text hidden", "private chat text" not in text and "hidden" in text)
    check("notifications: bitwarden text hidden", "TOTP" not in text and "123456" not in text)
    check("notifications: one-time code masked", "482913" not in text and "[code]" in text)
    check("notifications: password/token masked", "hunter2" not in text and "abcdef0123456789" not in text)

    err, text = await call(s, "journal_user", {"unit": "mcp-gateway.service", "lines": 500})
    argv = open(os.path.join(fakedir, "argv.log")).read()
    check("journal uses --user, the unit and the 200 cap", "journalctl --user -u mcp-gateway.service -n 200" in argv)
    check("journal: secrets masked", "SuperSecretValue123" not in text and "abc.def.ghi-long-value" not in text and "sk-abcdefghijklmnop1234" not in text)
    check("journal: normal lines kept", "started" in text)
    for bad in ("sshd.service; rm -rf /", "../../etc/passwd", "foo", "--user", ""):
        err, text = await call(s, "journal_user", {"unit": bad})
        check(f"journal refuses unit {bad!r}", err)
    err, text = await call(s, "journal_user", {"unit": "x.service", "priority": "bogus"})
    check("journal refuses a bad priority", err)

    err, text = await call(s, "user_units_failed")
    check("user_units_failed", not err and "telegram-fake" in text)


asyncio.run(main())
sys.exit(0 if all(results) else 1)
