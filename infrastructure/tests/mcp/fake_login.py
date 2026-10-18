#!/usr/bin/env python3
"""Fake infrastructure/mcp/telegram/login.py: no network. `qr` returns a new session, `list` checks the one it was given."""
import json
import os
import sys

mode = sys.argv[1]
log = open(os.path.join(os.environ["FAKE_DIR"], "login.log"), "a")
log.write(f"mode={mode} api_id={os.environ.get('TELEGRAM_API_ID')} has_session={'yes' if os.environ.get('TELEGRAM_SESSION_STRING') else 'no'}\n")
if mode == "list" and os.environ.get("TELEGRAM_SESSION_STRING", "").startswith("1STALE"):
    sys.exit(3)
chats = [{"id": 1, "title": "Test Owner", "kind": "user", "unread": 0},   # the owner's own chat = me.id: Saved Messages in the picker
         {"id": -1001111, "title": "Work chat", "kind": "group", "unread": 3},
         {"id": 42, "title": "Ann", "kind": "user", "unread": 0},
         {"id": -1002222, "title": "News", "kind": "channel", "unread": 9},
         {"id": 777, "title": "Secret person", "kind": "user", "unread": 1}]
if os.environ.get("FAKE_TITLE_EVIL") == "1":   # an attacker-chosen title: bidi override, zero-width space, a terminal escape
    chats.append({"id": 888, "title": "Evil\u202egnp.exe\u200b\x1b[31mred", "kind": "user", "unread": 0})
out = {"me": {"id": 1, "name": "Test Owner", "username": "owner"}, "chats": chats}
if mode == "qr":
    out["session"] = "1" + "FRESHSESSION" * 12
json.dump(out, sys.stdout)
