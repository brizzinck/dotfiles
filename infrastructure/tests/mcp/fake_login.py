#!/usr/bin/env python3
"""Fake infrastructure/mcp/telegram/login.py: no network. `qr` returns a new session, `list` checks the one it was given,
`resolve` maps @name/id to a chat without joining, `join` pretends to join (new chats appear) and resolves."""
import json
import os
import sys

mode = sys.argv[1]
queries = sys.argv[2:]
log = open(os.path.join(os.environ["FAKE_DIR"], "login.log"), "a")
log.write(f"mode={mode} api_id={os.environ.get('TELEGRAM_API_ID')} has_session={'yes' if os.environ.get('TELEGRAM_SESSION_STRING') else 'no'}"
          + (f" queries={','.join(queries)}" if queries else "") + "\n")
if mode in ("list", "resolve", "join") and os.environ.get("TELEGRAM_SESSION_STRING", "").startswith("1STALE"):
    sys.exit(3)
chats = [{"id": 1, "title": "Test Owner", "kind": "user", "unread": 0},   # the owner's own chat = me.id: Saved Messages in the picker
         {"id": -1001111, "title": "Work chat", "kind": "group", "unread": 3},
         {"id": 42, "title": "Ann", "kind": "user", "unread": 0},
         {"id": -1002222, "title": "News", "kind": "channel", "unread": 9},
         {"id": 777, "title": "Secret person", "kind": "user", "unread": 1}]
if os.environ.get("FAKE_TITLE_EVIL") == "1":   # an attacker-chosen title: bidi override, zero-width space, a terminal escape
    chats.append({"id": 888, "title": "Evil‮gnp.exe​\x1b[31mred", "kind": "user", "unread": 0})
me = {"id": 1, "name": "Test Owner", "username": "owner"}

# @username -> id, for resolve/join of public chats
USERNAMES = {"work": -1001111, "ann": 42, "news": -1002222, "secret": 777, "owner": 1}
# chats that only exist after you JOIN them (public @newchan, or a private invite link)
JOINABLE = {"newchan": {"id": -1009999, "title": "New Channel", "kind": "channel"},
            "invite": {"id": -1003333, "title": "Private Group", "kind": "group"}}
BY_ID = {c["id"]: c for c in chats}


def clean(q):
    q = q.strip()
    for pre in ("https://", "http://", "t.me/", "telegram.me/", "@"):
        if q.startswith(pre):
            q = q[len(pre):]
    return q.strip("/")


def invite_key(q):
    s = q.strip()
    if "joinchat/" in s:
        return "invite"
    if "/+" in s or s.startswith("+"):
        return "invite"
    return None


def lookup(q):
    """(row, None) found, or (None, error). Does NOT join."""
    inv = invite_key(q)
    if inv:
        return None, "invite_needs_join"
    body = clean(q).lower()
    if body.lstrip("-").isdigit():
        c = BY_ID.get(int(body) if not q.strip().startswith("-") else int(q.strip()))
        if c:
            return {"id": c["id"], "title": c["title"], "kind": c["kind"]}, None
        return None, "ValueError"
    if body in USERNAMES:
        c = BY_ID[USERNAMES[body]]
        return {"id": c["id"], "title": c["title"], "kind": c["kind"]}, None
    return None, "UsernameNotOccupiedError"


if mode in ("resolve", "join"):
    out = {"me": me}
    rows = []
    for q in queries:
        if mode == "join":
            inv = invite_key(q)
            key = "invite" if inv else clean(q).lower()
            if key in JOINABLE:
                j = JOINABLE[key]
                rows.append({"query": q, "id": j["id"], "title": j["title"], "kind": j["kind"]})
                continue
        row, err = lookup(q)
        rows.append({"query": q, **(row if row else {"error": err})})
    out["joined" if mode == "join" else "resolved"] = rows
    json.dump(out, sys.stdout)
    sys.exit(0)

out = {"me": me, "chats": chats}
if mode == "qr":
    out["session"] = "1" + "FRESHSESSION" * 12
json.dump(out, sys.stdout)
