#!/usr/bin/env python3
"""QR login to Telegram, chat listing, chat resolving and joining for mcp-telegram-setup. Runs in /opt/telegram-mcp/venv
(Telethon), as the OWNER, in the owner's terminal; it never writes a file.

  login.py qr              log in by QR code (shown in this terminal; scan it in Telegram: Settings > Devices > Link Desktop
                           Device), ask for the 2FA password when the account has one, then list the chats
  login.py list            same chat listing with an existing session (TELEGRAM_SESSION_STRING in the environment)
  login.py resolve Q [...]  resolve each @username / id / t.me link to its id, title and kind WITHOUT joining (read-only). A
                           private invite link (t.me/+hash, t.me/joinchat/hash) can only be resolved when you are already a
                           member, otherwise it is reported as an error (joining is login.py join).
  login.py join Q [...]     JOIN each channel/group and resolve it (a Telegram WRITE: it changes the account's memberships).
                           A public @username / id uses JoinChannelRequest; a private invite link uses ImportChatInviteRequest;
                           a user/bot chat needs no join and is only resolved. This is the ONLY write login.py does.

Input: TELEGRAM_API_ID, TELEGRAM_API_HASH (environment of this child only), TELEGRAM_SESSION_STRING (for list/resolve/join).
Output on stdout: ONE JSON object.
  qr/list:  {"session": "<string session, only for qr>", "me": {...}, "chats": [{"id", "title", "kind", "unread"}...]}
  resolve:  {"me": {...}, "resolved": [{"query","id","title","kind"} | {"query","error":"<type>"}...]}
  join:     {"me": {...}, "joined":   [{"query","id","title","kind"} | {"query","error":"<type>"}...]}
Everything human goes to stderr. The session is registered as the device "telegram-mcp (AI, read-only)" so it is recognisable in
Telegram > Settings > Devices, where terminating it is the kill switch. Exit codes: 0 ok, 2 bad input, 3 session not authorised,
4 login failed.
"""
import asyncio
import getpass
import json
import os
import re
import shutil
import subprocess
import sys

from telethon import TelegramClient, errors, utils
from telethon.sessions import StringSession
from telethon.tl.functions.channels import JoinChannelRequest
from telethon.tl.functions.messages import CheckChatInviteRequest, ImportChatInviteRequest
from telethon.tl.types import ChatInviteAlready

DEVICE = "telegram-mcp (AI, read-only)"
MODES = ("qr", "list", "resolve", "join")
INVITE_RE = re.compile(r"(?:t\.me/|telegram\.me/)(?:joinchat/|\+)([A-Za-z0-9_-]+)|^\+([A-Za-z0-9_-]{10,})$")


def eprint(*a):
    print(*a, file=sys.stderr, flush=True)


def show_qr(url: str) -> None:
    if shutil.which("qrencode"):
        subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "2", url], stdout=sys.stderr, check=False)
        return
    import qrcode

    q = qrcode.QRCode(border=2)
    q.add_data(url)
    q.make(fit=True)
    q.print_ascii(out=sys.stderr, invert=True)


async def qr_login(client: TelegramClient) -> None:
    qr = await client.qr_login()
    eprint("\nScan this QR code in Telegram on your phone:\n  Settings > Devices > Link Desktop Device\n")
    while True:
        show_qr(qr.url)
        try:
            await qr.wait(timeout=30)
            return
        except asyncio.TimeoutError:
            eprint("\n(the code expired, here is a new one)\n")
            await qr.recreate()
        except errors.SessionPasswordNeededError:
            for _ in range(3):
                pw = getpass.getpass("Telegram two-step password (hidden): ", stream=sys.stderr)
                try:
                    await client.sign_in(password=pw)
                    return
                except errors.PasswordHashInvalidError:
                    eprint("Wrong password.")
            raise SystemExit(4)


def kind_of(d) -> str:
    e = d.entity
    if d.is_user:
        return "bot" if getattr(e, "bot", False) else "user"
    if d.is_channel and not d.is_group:
        return "channel"
    return "group"


def kind_of_entity(e) -> str:
    """kind for an entity that did not come from a dialog (resolve / join)."""
    cls = type(e).__name__
    if cls in ("User",):
        return "bot" if getattr(e, "bot", False) else "user"
    if cls in ("Channel",):
        return "channel" if not getattr(e, "megagroup", False) else "group"
    return "group"   # Chat (basic group), ChatForbidden, ...


def invite_hash(query: str) -> str | None:
    m = INVITE_RE.search(query.strip())
    return (m.group(1) or m.group(2)) if m else None


def as_target(query: str):
    """What get_entity should receive: an int for a numeric id, else the cleaned string (get_entity handles @name and t.me/<name>)."""
    q = query.strip()
    body = q.lstrip("-")
    if body.isdigit():
        return int(q)
    return q


async def resolve_one(client: TelegramClient, query: str) -> dict:
    h = invite_hash(query)
    if h:
        # a private invite link: only resolvable (no stable peer id) when already a member; otherwise joining is required
        try:
            info = await client(CheckChatInviteRequest(h))
        except errors.RPCError as e:
            return {"query": query, "error": type(e).__name__}
        if isinstance(info, ChatInviteAlready):
            chat = info.chat
            return {"query": query, "id": utils.get_peer_id(chat), "title": utils.get_display_name(chat) or "(no name)",
                    "kind": kind_of_entity(chat)}
        return {"query": query, "error": "invite_needs_join"}
    try:
        e = await client.get_entity(as_target(query))
    except (errors.RPCError, ValueError, TypeError) as exc:
        return {"query": query, "error": type(exc).__name__}
    return {"query": query, "id": utils.get_peer_id(e), "title": utils.get_display_name(e) or "(no name)",
            "kind": kind_of_entity(e)}


async def join_one(client: TelegramClient, query: str) -> dict:
    h = invite_hash(query)
    if h:
        try:
            await client(ImportChatInviteRequest(h))
        except errors.UserAlreadyParticipantError:
            pass
        except errors.RPCError as exc:
            return {"query": query, "error": type(exc).__name__}
        # resolve the chat after joining (CheckChatInvite now reports membership)
        try:
            info = await client(CheckChatInviteRequest(h))
            chat = info.chat if isinstance(info, ChatInviteAlready) else None
        except errors.RPCError:
            chat = None
        if chat is None:
            return {"query": query, "error": "joined_but_unresolved"}
        return {"query": query, "id": utils.get_peer_id(chat), "title": utils.get_display_name(chat) or "(no name)",
                "kind": kind_of_entity(chat)}
    try:
        e = await client.get_entity(as_target(query))
    except (errors.RPCError, ValueError, TypeError) as exc:
        return {"query": query, "error": type(exc).__name__}
    # users/bots are not joined, only resolved; channels/groups get JoinChannelRequest (idempotent)
    if kind_of_entity(e) in ("channel", "group") and type(e).__name__ == "Channel":
        try:
            await client(JoinChannelRequest(e))
        except errors.UserAlreadyParticipantError:
            pass
        except errors.RPCError as exc:
            return {"query": query, "error": type(exc).__name__}
    return {"query": query, "id": utils.get_peer_id(e), "title": utils.get_display_name(e) or "(no name)",
            "kind": kind_of_entity(e)}


async def main(mode: str, queries: list[str]) -> int:
    try:
        api_id = int(os.environ["TELEGRAM_API_ID"])
        api_hash = os.environ["TELEGRAM_API_HASH"]
    except (KeyError, ValueError):
        eprint("TELEGRAM_API_ID / TELEGRAM_API_HASH missing or invalid")
        return 2
    session = os.environ.get("TELEGRAM_SESSION_STRING") if mode != "qr" else None
    client = TelegramClient(StringSession(session or None), api_id, api_hash, device_model=DEVICE, system_version="Linux",
                            app_version="1.0")
    await client.connect()
    try:
        if mode == "qr":
            await qr_login(client)
        elif not await client.is_user_authorized():
            eprint("the stored session is not authorised any more (it was terminated in Telegram > Devices?)")
            return 3
        me = await client.get_me()
        head = {"me": {"id": me.id, "name": utils.get_display_name(me), "username": me.username}}
        if mode == "resolve":
            head["resolved"] = [await resolve_one(client, q) for q in queries]
        elif mode == "join":
            head["joined"] = [await join_one(client, q) for q in queries]
        else:
            chats = []
            async for d in client.iter_dialogs(limit=300):
                chats.append({"id": utils.get_peer_id(d.entity), "title": d.name or "(no name)", "kind": kind_of(d),
                              "unread": d.unread_count or 0})
            head["chats"] = chats
            if mode == "qr":
                head["session"] = client.session.save()
        json.dump(head, sys.stdout)
        return 0
    except errors.RPCError as e:
        eprint(f"Telegram refused: {type(e).__name__}")
        return 4
    finally:
        await client.disconnect()


if __name__ == "__main__":
    argv = sys.argv[1:]
    mode = argv[0] if argv else ""
    rest = argv[1:]
    bad = (mode not in MODES
           or (mode in ("qr", "list") and rest)
           or (mode in ("resolve", "join") and not rest))
    if bad:
        print((__doc__ or "").strip(), file=sys.stderr)
        sys.exit(2)
    sys.exit(asyncio.run(main(mode, rest)))
