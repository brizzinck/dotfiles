#!/usr/bin/env python3
"""tgconfirm broker: the only place that can turn "an agent wants to send a Telegram message" into a sent message.

Runs as the system service tgconfirm.service under the user `tgconfirm` (stdlib only, /usr/bin/python3). It holds the send token
(a TPM2 credential nobody else can read), the "sending is enabled" state with its expiry, the popup rate limit and the audit
log. An agent never talks to telegram-mcp's send route: it can only ask this broker, and the broker sends nothing until the
owner has pressed the per-message random key code in a popup it shows itself.

  agent -> telegram-send MCP (stdio, owner uid, no secrets) -> /run/tgconfirm/req.sock (mode 0666, SO_PEERCRED uid must be the
  owner) -> enabled? -> resolve the chat (POST /x-send action=resolve) -> rate limit -> popup (ghostty as tgconfirm on the owner's
  Wayland socket, class float.confirm, popup.py inside) -> confirmed -> POST /x-send action=send -> reply.

Protocol: one JSON line in, one JSON line out per connection.
  {"op":"status"}                                    -> {"ok":true,"enabled":bool,"until":epoch,"accounts":[...]}
  {"op":"enable","minutes":60}                       -> popup "Enable sending?" -> {"ok":true,"status":"enabled"|"cancelled"|...}
  {"op":"disable"}                                   -> {"ok":true,"status":"disabled"}
  {"op":"send","account","chat","text","reply_to"?}  -> {"ok":bool,"status":"sent"|"cancelled"|"timeout"|"disabled"|"rejected",
                                                         "message_id"?,"name"?,"reason"?}
State for readers (waybar, hub, mcp-telegram-send status): /run/tgconfirm/state.json (0644, no secrets).
Audit (journald, stderr): action, account, chat id, length, sha256 prefix of the text, result. Never the text.

Env (unit and tests): TGCONFIRM_OWNER_UID (required: the only uid that may ask), TGCONFIRM_RUNTIME (default /run/tgconfirm),
TGCONFIRM_ACCOUNTS (default main=8765: account name -> telegram-mcp port), TGCONFIRM_LIB (default /usr/local/lib/tgconfirm),
CREDENTIALS_DIRECTORY (send_token), TGCONFIRM_TTL_MAX (minutes, default 120). Test hooks: TGCONFIRM_POPUP_CMD (replaces the
ghostty command; `{req}` is the request file), TGCONFIRM_WAYLAND (socket path instead of the search), TGCONFIRM_URL (base URL of
the route instead of http://127.0.0.1:PORT), TGCONFIRM_NO_LOCK_CHECK=1, TGCONFIRM_ALLOW_UID (extra accepted uid).
"""

from __future__ import annotations

import asyncio
import collections
import glob
import hashlib
import json
import os
import re
import secrets
import signal
import socket
import stat
import struct
import sys
import time
import urllib.error
import urllib.request

MAX_TEXT = 4096
POPUP_TIMEOUT = 60            # seconds the owner has to press the code
REPLY_WAIT = 65               # seconds an agent call may block (popup + the send itself)
RATE = (5, 600)               # popups per window
EXEC_GRACE = 8                # seconds after the popup timeout before the process is killed
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


def log(msg: str) -> None:
    print(f"tgconfirm: {msg}", file=sys.stderr, flush=True)


def digest(text: str | None) -> tuple[int, str]:
    if text is None:
        return 0, "-"
    return len(text), hashlib.sha256(text.encode()).hexdigest()[:16]


class RateLimit:
    def __init__(self, n: int, window: float, clock=time.monotonic):
        self.n, self.window, self.clock = n, window, clock
        self.hits: collections.deque = collections.deque()

    def take(self) -> bool:
        now = self.clock()
        while self.hits and now - self.hits[0] > self.window:
            self.hits.popleft()
        if len(self.hits) >= self.n:
            return False
        self.hits.append(now)
        return True


def clean_line(s: object, limit: int = 300) -> str:
    """One printable line from an untrusted reason string (server errors, Telegram text)."""
    return re.sub(r"[^\x20-\x7e -￿]", " ", str(s))[:limit].strip()


class Broker:
    def __init__(self, env=os.environ, clock=time.time, mono=time.monotonic):
        self.env = env
        self.clock = clock
        self.owner_uid = int(env["TGCONFIRM_OWNER_UID"])
        self.extra_uid = int(env["TGCONFIRM_ALLOW_UID"]) if env.get("TGCONFIRM_ALLOW_UID") else None
        self.runtime = env.get("TGCONFIRM_RUNTIME", "/run/tgconfirm")
        self.lib = env.get("TGCONFIRM_LIB", "/usr/local/lib/tgconfirm")
        self.accounts = {}
        for part in env.get("TGCONFIRM_ACCOUNTS", "main=8765").split(","):
            if "=" in part:
                k, v = part.split("=", 1)
                if ACCOUNT_RE.match(k.strip()) and v.strip().isdigit():
                    self.accounts[k.strip()] = int(v)
        cred = env.get("CREDENTIALS_DIRECTORY", "")
        try:
            with open(os.path.join(cred, "send_token")) as f:
                self.token = f.read().strip()
        except OSError:
            self.token = ""
        self.until = 0.0
        self.popup_rate = RateLimit(*RATE, clock=mono)
        self.enable_rate = RateLimit(*RATE, clock=mono)
        self.lock = asyncio.Lock()          # one popup at a time
        self.last_state = None

    # --- state file read by waybar / hub / mcp-telegram-send status -----------------------------------------------------
    def enabled(self) -> bool:
        return self.until > self.clock()

    def write_state(self) -> None:
        state = {"enabled": self.enabled(), "until": int(self.until) if self.enabled() else 0,
                 "accounts": sorted(self.accounts), "token": bool(self.token)}
        if state == self.last_state:
            return
        self.last_state = state
        os.makedirs(self.runtime, exist_ok=True)
        tmp = os.path.join(self.runtime, f".state.{os.getpid()}")
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(self.runtime, "state.json"))

    async def ticker(self) -> None:
        while True:
            self.write_state()
            await asyncio.sleep(5)

    # --- Wayland / popup --------------------------------------------------------------------------------------------------
    def wayland_socket(self) -> str | None:
        forced = self.env.get("TGCONFIRM_WAYLAND")
        if forced:
            return forced if os.path.exists(forced) else None
        for p in sorted(glob.glob(f"/run/user/{self.owner_uid}/wayland-[0-9]*")):
            if p.endswith(".lock"):
                continue
            try:
                if stat.S_ISSOCK(os.stat(p).st_mode) and os.access(p, os.R_OK | os.W_OK):
                    return p
            except OSError:
                continue
        return None

    def screen_locked(self) -> bool:
        if self.env.get("TGCONFIRM_NO_LOCK_CHECK") == "1":
            return False
        for comm in glob.glob("/proc/[0-9]*/comm"):
            try:
                with open(comm) as f:
                    if f.read().strip() == "hyprlock":
                        return True
            except OSError:
                continue
        return False

    def popup_argv(self, req_file: str) -> list[str]:
        custom = self.env.get("TGCONFIRM_POPUP_CMD")
        if custom:
            return [a.replace("{req}", req_file) for a in custom.split()]
        # dbus-run-session: GTK only honours the application id (= the Wayland class float.confirm that the window rule matches) when
        # a session bus exists; the tgconfirm user has none, so the window would be a plain "GTK Application"
        return ["/usr/bin/dbus-run-session", "--", "/usr/bin/ghostty", "--config-default-files=false", f"--config-file={self.lib}/ghostty.conf",
                "--class=float.confirm", "--gtk-single-instance=false", "--title=Telegram: confirm",
                "-e", "/usr/bin/python3", f"{self.lib}/popup.py", "--req", req_file]

    def popup_env(self, wayland: str) -> dict:
        rt = os.path.join(self.runtime, "rt")
        env = {"PATH": "/usr/local/bin:/usr/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "HOME": self.env.get("TGCONFIRM_HOME", "/var/lib/tgconfirm"), "XDG_RUNTIME_DIR": rt,
               "WAYLAND_DISPLAY": wayland, "GDK_BACKEND": "wayland", "LIBGL_ALWAYS_SOFTWARE": "1", "GSK_RENDERER": "cairo",
               "GSETTINGS_BACKEND": "memory", "GTK_A11Y": "none", "NO_AT_BRIDGE": "1", "TGCONFIRM_LIB": self.lib}
        for k, v in self.env.items():      # test hooks only (the unit never sets them): the keymap and the fake popup's switches
            if k == "TGCONFIRM_KEYMAP" or k.startswith("TGCONFIRM_FAKE"):
                env[k] = v
        return env

    async def popup(self, req: dict) -> str:
        """Show one popup and return "confirmed" | "cancelled" | "timeout" | "error: <why>". The broker never learns the code."""
        wl = self.wayland_socket()
        if wl is None:
            return "error: no desktop session reachable (the Wayland socket is not accessible: usr clipboard-acl)"
        if self.screen_locked():
            return "error: the screen is locked"
        rt = os.path.join(self.runtime, "rt")
        os.makedirs(rt, mode=0o700, exist_ok=True)
        os.chmod(rt, 0o700)
        nonce = secrets.token_hex(16)
        req_file = os.path.join(rt, f"{nonce}.req")
        res_file = os.path.join(rt, f"{nonce}.res")
        payload = {**req, "nonce": nonce, "timeout": POPUP_TIMEOUT, "result_file": res_file}
        fd = os.open(req_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        proc = None
        try:
            argv = self.popup_argv(req_file)
            proc = await asyncio.create_subprocess_exec(*argv, env=self.popup_env(wl), stdin=asyncio.subprocess.DEVNULL,
                                                        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                                                        start_new_session=True)
            try:
                await asyncio.wait_for(proc.wait(), POPUP_TIMEOUT + EXEC_GRACE)
            except asyncio.TimeoutError:
                return "timeout"
            try:
                with open(res_file) as f:
                    res = json.load(f)
            except (OSError, ValueError):
                return "cancelled"      # window closed or killed without an answer
            if res.get("nonce") != nonce:
                return "cancelled"
            r = res.get("result")
            return r if r in ("confirmed", "cancelled", "timeout") else "cancelled"
        except OSError as e:
            return f"error: cannot start the popup ({e.strerror})"
        finally:
            if proc is not None and proc.returncode is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
                await proc.wait()
            for p in (req_file, res_file):
                try:
                    os.unlink(p)
                except OSError:
                    pass

    # --- telegram-mcp's /x-send -----------------------------------------------------------------------------------------
    def x_send_sync(self, account: str, body: dict, timeout: float) -> tuple[int, dict]:
        base = self.env.get("TGCONFIRM_URL") or f"http://127.0.0.1:{self.accounts[account]}"
        data = json.dumps({**body, "account": account}).encode()
        r = urllib.request.Request(base + "/x-send", data=data, method="POST",
                                   headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                return e.code, json.loads(e.read() or b"{}")
            except ValueError:
                return e.code, {}
        except (urllib.error.URLError, OSError, ValueError, TimeoutError) as e:
            return 0, {"error": f"telegram-mcp is not reachable ({type(e).__name__})"}

    async def x_send(self, account: str, body: dict, timeout: float = 25) -> tuple[int, dict]:
        return await asyncio.get_running_loop().run_in_executor(None, self.x_send_sync, account, body, timeout)

    # --- operations -----------------------------------------------------------------------------------------------------
    def status(self) -> dict:
        return {"ok": True, "enabled": self.enabled(), "until": int(self.until) if self.enabled() else 0,
                "accounts": sorted(self.accounts), "configured": bool(self.token)}

    async def op_enable(self, msg: dict) -> dict:
        if self.enabled():
            return {**self.status(), "status": "enabled"}
        try:
            minutes = int(msg.get("minutes", 60))
        except (TypeError, ValueError):
            minutes = 60
        minutes = max(1, min(minutes, int(self.env.get("TGCONFIRM_TTL_MAX", "120"))))
        if not self.token:
            return {"ok": False, "status": "rejected", "reason": "sending is not set up (mcp-telegram-setup send-chats)"}
        if not self.enable_rate.take():
            log("enable result=refused(rate)")
            return {"ok": False, "status": "rejected", "reason": "too many confirmation popups, try again later"}
        async with self.lock:
            res = await self.popup({"kind": "enable", "title": "Allow AI agents to send Telegram messages?",
                                    "text": f"For {minutes} minutes. Every single message will still ask you again, with its full "
                                            f"text and recipient. Turning it off later needs no confirmation.", "minutes": minutes})
        log(f"enable result={res}")
        if res == "confirmed":
            self.until = self.clock() + minutes * 60
            self.write_state()
            return {**self.status(), "status": "enabled"}
        if res.startswith("error"):
            return {"ok": False, "status": "rejected", "reason": clean_line(res[7:])}
        return {"ok": False, "status": res}

    def op_disable(self) -> dict:
        self.until = 0.0
        self.write_state()
        log("disable result=off")
        return {"ok": True, "status": "disabled", "enabled": False}

    async def op_send(self, msg: dict) -> dict:
        if not self.enabled():
            return {"ok": False, "status": "disabled", "reason": "sending is disabled (owner: hub > Telegram: allow sending)"}
        account = msg.get("account", "main")
        text, chat, reply_to = msg.get("text"), msg.get("chat"), msg.get("reply_to")
        if not isinstance(account, str) or account not in self.accounts:
            return {"ok": False, "status": "rejected", "reason": f"unknown account (known: {', '.join(sorted(self.accounts))})"}
        if not isinstance(text, str) or not text.strip():
            return {"ok": False, "status": "rejected", "reason": "the text is empty"}
        if len(text) > MAX_TEXT:
            return {"ok": False, "status": "rejected", "reason": f"the text is longer than {MAX_TEXT} characters"}
        if isinstance(chat, bool) or not isinstance(chat, (str, int)) or not str(chat).strip() or len(str(chat)) > 128:
            return {"ok": False, "status": "rejected", "reason": "chat must be a numeric id, an @username or the title of an allowed chat"}
        if reply_to in ("", 0):
            reply_to = None
        if reply_to is not None and (isinstance(reply_to, bool) or not isinstance(reply_to, int) or reply_to < 0):
            return {"ok": False, "status": "rejected", "reason": "reply_to must be a message id"}
        n, h = digest(text)
        try:
            await asyncio.wait_for(self.lock.acquire(), 20)
        except asyncio.TimeoutError:
            return {"ok": False, "status": "rejected", "reason": "another confirmation popup is open, try again"}
        try:
            code, info = await self.x_send(account, {"action": "resolve", "chat": chat, "reply_to": reply_to})
            if code != 200 or not info.get("ok"):
                why = clean_line(info.get("error") or f"telegram-mcp answered {code}")
                log(f"send account={account} chat={clean_line(chat, 40)} len={n} sha256={h} result=rejected({why})")
                return {"ok": False, "status": "rejected", "reason": why}
            chat_id, name = info["chat_id"], clean_line(info.get("name", "?"), 120)
            if not self.enabled():
                return {"ok": False, "status": "disabled", "reason": "sending was switched off"}
            if not self.popup_rate.take():   # popups, not requests: a typo in a chat name costs nothing
                log(f"send account={account} chat={chat_id} len={n} sha256={h} result=rejected(rate)")
                return {"ok": False, "status": "rejected",
                        "reason": f"rate limit ({RATE[0]} confirmation popups per {RATE[1] // 60} minutes), try later"}
            res = await self.popup({"kind": "send", "title": "Send this Telegram message?", "account": account, "name": info.get("name", "?"),
                                    "username": info.get("username", ""), "chat_id": chat_id, "chat_kind": info.get("kind", ""),
                                    "reply_preview": info.get("reply_preview", ""), "reply_to": reply_to, "text": text})
            if res != "confirmed":
                log(f"send account={account} chat={chat_id} len={n} sha256={h} result={clean_line(res)}")
                if res.startswith("error"):
                    return {"ok": False, "status": "rejected", "reason": clean_line(res[7:])}
                return {"ok": False, "status": res, "name": name}
            if not self.enabled():
                return {"ok": False, "status": "disabled", "reason": "sending was switched off"}
            code, out = await self.x_send(account, {"action": "send", "chat_id": chat_id, "text": text, "reply_to": reply_to,
                                                    "request_id": secrets.token_hex(12)}, 40)
            if code == 200 and out.get("ok"):
                log(f"send account={account} chat={chat_id} len={n} sha256={h} result=sent id={out.get('message_id')}")
                return {"ok": True, "status": "sent", "message_id": out.get("message_id"), "name": name, "chat_id": chat_id}
            why = clean_line(out.get("error") or f"telegram-mcp answered {code}")
            log(f"send account={account} chat={chat_id} len={n} sha256={h} result=failed({why})")
            return {"ok": False, "status": "rejected", "reason": why, "name": name}
        finally:
            self.lock.release()

    # --- socket server ----------------------------------------------------------------------------------------------------
    @staticmethod
    def peer_uid(writer) -> int:
        sock = writer.get_extra_info("socket")
        pid, uid, gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        return uid

    async def handle(self, reader, writer) -> None:
        try:
            uid = self.peer_uid(writer)
            if uid not in (self.owner_uid, 0, self.extra_uid):
                resp = {"ok": False, "status": "rejected", "reason": "not allowed for this user"}
            else:
                try:
                    line = await asyncio.wait_for(reader.readline(), 5)
                    if len(line) > 70000:
                        raise ValueError
                    msg = json.loads(line)
                    if not isinstance(msg, dict):
                        raise ValueError
                except (ValueError, asyncio.TimeoutError):
                    msg = None
                if msg is None:
                    resp = {"ok": False, "status": "rejected", "reason": "bad request"}
                else:
                    op = msg.get("op")
                    if op == "status":
                        resp = self.status()
                    elif op == "disable":
                        resp = self.op_disable()
                    elif op == "enable":
                        resp = await self.op_enable(msg)
                    elif op == "send":
                        resp = await self.op_send(msg)
                    else:
                        resp = {"ok": False, "status": "rejected", "reason": "unknown op"}
            writer.write(json.dumps(resp).encode() + b"\n")
            await writer.drain()
        except (ConnectionError, OSError):
            pass
        except Exception as e:     # never crash the service on one request, never leak details
            log(f"internal error {type(e).__name__}")
            try:
                writer.write(b'{"ok":false,"status":"rejected","reason":"internal error"}\n')
                await writer.drain()
            except OSError:
                pass
        finally:
            writer.close()

    async def serve(self) -> None:
        os.makedirs(self.runtime, exist_ok=True)
        path = os.path.join(self.runtime, "req.sock")
        if os.path.exists(path):
            os.unlink(path)
        old = os.umask(0o111)       # socket rw for everyone; the peer uid is checked on every connection
        try:
            server = await asyncio.start_unix_server(self.handle, path=path, limit=70000)
        finally:
            os.umask(old)
        os.chmod(path, 0o666)
        self.write_state()
        log(f"ready: socket {path}, owner uid {self.owner_uid}, accounts {','.join(sorted(self.accounts))}, "
            f"send token {'present' if self.token else 'MISSING'}")
        ticker = asyncio.create_task(self.ticker())
        async with server:
            try:
                await server.serve_forever()
            finally:
                ticker.cancel()


def main() -> int:
    if "TGCONFIRM_OWNER_UID" not in os.environ:
        print("tgconfirm: TGCONFIRM_OWNER_UID is not set (the unit drop-in 10-owner.conf is rendered by apply-system.sh)", file=sys.stderr)
        return 78
    b = Broker()
    if not b.token:
        log("no send token credential: every send is refused until mcp-telegram-setup send-chats ran")
    try:
        asyncio.run(b.serve())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
