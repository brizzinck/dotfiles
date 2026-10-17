#!/usr/bin/env python3
"""QR login to Telegram and chat listing for mcp-telegram-setup. Runs in /opt/telegram-mcp/venv (Telethon), as the OWNER, in the
owner's terminal; it never writes a file.

  login.py qr     log in by QR code (shown in this terminal; scan it in Telegram: Settings > Devices > Link Desktop Device),
                  ask for the 2FA password when the account has one, then list the chats
  login.py list   same chat listing with an existing session (TELEGRAM_SESSION_STRING in the environment)

Input: TELEGRAM_API_ID, TELEGRAM_API_HASH (environment of this child only). Output on stdout: ONE JSON object
{"session": "<string session, only for qr>", "me": {...}, "chats": [{"id", "title", "kind", "unread"}...]}; everything human goes
to stderr. The session is registered as the device "telegram-mcp (AI, read-only)" so it is recognisable in Telegram > Settings >
Devices, where terminating it is the kill switch. Exit codes: 0 ok, 2 bad input, 3 session not authorised, 4 login failed.
"""
import asyncio
import getpass
import json
import os
import shutil
import subprocess
import sys

from telethon import TelegramClient, errors, utils
from telethon.sessions import StringSession

DEVICE = "telegram-mcp (AI, read-only)"


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


async def main(mode: str) -> int:
    try:
        api_id = int(os.environ["TELEGRAM_API_ID"])
        api_hash = os.environ["TELEGRAM_API_HASH"]
    except (KeyError, ValueError):
        eprint("TELEGRAM_API_ID / TELEGRAM_API_HASH missing or invalid")
        return 2
    session = os.environ.get("TELEGRAM_SESSION_STRING") if mode == "list" else None
    client = TelegramClient(StringSession(session or None), api_id, api_hash, device_model=DEVICE, system_version="Linux",
                            app_version="1.0")
    await client.connect()
    try:
        if mode == "list":
            if not await client.is_user_authorized():
                eprint("the stored session is not authorised any more (it was terminated in Telegram > Devices?)")
                return 3
        else:
            await qr_login(client)
        me = await client.get_me()
        chats = []
        async for d in client.iter_dialogs(limit=300):
            chats.append({"id": utils.get_peer_id(d.entity), "title": d.name or "(no name)", "kind": kind_of(d),
                          "unread": d.unread_count or 0})
        out = {"me": {"id": me.id, "name": utils.get_display_name(me), "username": me.username}, "chats": chats}
        if mode == "qr":
            out["session"] = client.session.save()
        json.dump(out, sys.stdout)
        return 0
    except errors.RPCError as e:
        eprint(f"Telegram refused: {type(e).__name__}")
        return 4
    finally:
        await client.disconnect()


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("qr", "list"):
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    sys.exit(asyncio.run(main(sys.argv[1])))
