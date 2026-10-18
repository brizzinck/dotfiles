#!/usr/bin/python3 -I
# codex-limits.py OUT: ask the Codex CLI for the account's current rate limits and write them to OUT (0600, atomic).
# Runs `codex app-server` on stdio and sends `initialize` + `account/rateLimits/read` (JSON-RPC): the same request the Codex
# TUI makes for /status. It spends no tokens and starts no model turn; the CLI uses its own login (~/.codex/auth.json).
# The codex-hud cache only learns limits while Codex runs, so a reset (window or reset credit) stays invisible until the
# next Codex session; ai-usage.sh starts this in the background at most every 15 minutes.
# OUT: {"observed": epoch, "plan": str, "windows": [{"p": used %, "w": window minutes, "r": reset epoch}], "reset_credits": n}
# Exit 0 = written, 1 = no answer (OUT unchanged).
import json
import os
import select
import subprocess
import sys
import tempfile
import time

TIMEOUT = 20


def main():
    if len(sys.argv) != 2:
        print("usage: codex-limits.py OUT", file=sys.stderr)
        return 2
    out = sys.argv[1]
    try:
        p = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, cwd="/")
    except OSError:
        return 1

    def send(obj):
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

    answer = None
    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"clientInfo": {"name": "ai-usage", "version": "1"}}})
        end = time.monotonic() + TIMEOUT
        while time.monotonic() < end:
            ready, _, _ = select.select([p.stdout], [], [], 1)
            if not ready:
                continue
            line = p.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == 1:
                send({"jsonrpc": "2.0", "method": "initialized"})
                send({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": None})
            elif msg.get("id") == 2:
                answer = msg.get("result")
                break
    except (OSError, ValueError):
        pass
    finally:
        p.kill()
        p.wait()
    rl = (answer or {}).get("rateLimits") or {}
    wins = []
    for key in ("primary", "secondary"):
        w = rl.get(key)
        if isinstance(w, dict) and isinstance(w.get("usedPercent"), (int, float)):
            wins.append({"p": w["usedPercent"], "w": w.get("windowDurationMins"), "r": w.get("resetsAt") or 0})
    if not wins:
        return 1
    credits = ((answer or {}).get("rateLimitResetCredits") or {}).get("availableCount")
    data = {"observed": int(time.time()), "plan": rl.get("planType") or "", "windows": wins,
            "reset_credits": credits if isinstance(credits, int) else None}
    d = os.path.dirname(out) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".codex-limits.")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
