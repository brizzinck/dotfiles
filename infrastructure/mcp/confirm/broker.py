#!/usr/bin/env python3
"""tgconfirm broker: the only place that can turn "an agent wants to send a Telegram message" into a sent message.

Runs as the system service tgconfirm.service under the user `tgconfirm` (stdlib only, /usr/bin/python3). It holds the send token
(a TPM2 credential nobody else can read), the "sending is enabled" state with its expiry, the popup rate limit and the audit
log. An agent never talks to telegram-mcp's send route: it can only ask this broker, and the broker sends nothing until the
owner has pressed the per-message random key code in a popup it shows itself.

  agent -> telegram-send MCP (stdio, owner uid, no secrets) -> /run/tgconfirm/req.sock (mode 0666, SO_PEERCRED uid must be the
  owner) -> enabled? -> request rate limit -> resolve the chat (POST /x-send action=resolve, answered from the send allowlist
  without a Telegram lookup for any other chat) -> popup rate limit -> popup (ghostty as tgconfirm on the VERIFIED Wayland socket of
  the owner's session compositor, class float.confirm, popup.py inside) -> confirmed -> POST /x-send action=send -> reply.

The Wayland socket is never trusted by name: tgconfirm may only traverse /run/user/UID (the owner, and so any agent, can plant a
wayland-N there or take the ACL off the real one), so the broker connects to wayland-0..9 and keeps a socket only when its server
(SO_PEERCRED pid) is the compositor of the ACTIVE seat0 session: uid = owner, comm Hyprland, parent chain
start-hyprland [login shell] -> the session leader that logind names in /run/systemd/sessions/ID. The connected socket itself is
handed to ghostty as WAYLAND_SOCKET, so nothing can be swapped between the check and the use.

A request is bounded: REQUEST_BUDGET seconds in all (lock + resolve + popup + send, every step has its own limit), always below
what the clients wait. When the client hangs up, a pending popup is closed and nothing is sent.

Protocol: one JSON line in, one JSON line out per connection.
  {"op":"status"}                                    -> {"ok":true,"enabled":bool,"until":epoch,"accounts":[...]}
  {"op":"enable","minutes":60}                       -> popup "Enable sending?" -> {"ok":true,"status":"enabled"|"cancelled"|...}
  {"op":"disable"}                                   -> {"ok":true,"status":"disabled"}
  {"op":"send","account","chat","text","reply_to"?}  -> {"ok":bool,"status":"sent"|"cancelled"|"timeout"|"disabled"|"rejected",
                                                         "message_id"?,"name"?,"reason"?}
  {"op":"send_file","account","chat","text","attachment","reply_to"?} -> same popup/response; attachment is a bounded byte snapshot
State for readers (waybar, hub, mcp-telegram-send status): /run/tgconfirm/state.json (0644, no secrets).
Audit (journald, stderr): action, account, chat id, length, sha256 prefix of the text, result. Never the text.

Env (unit and tests): TGCONFIRM_OWNER_UID (required: the only uid that may ask), TGCONFIRM_RUNTIME (default /run/tgconfirm),
TGCONFIRM_ACCOUNTS (default main=8765: account name -> telegram-mcp port), TGCONFIRM_LIB (default /usr/local/lib/tgconfirm),
CREDENTIALS_DIRECTORY (send_token), TGCONFIRM_TTL_MAX (minutes, default 120). Test hooks: TGCONFIRM_POPUP_CMD (replaces the
ghostty command; `{req}` is the request file), TGCONFIRM_WAYLAND_DIR (where wayland-N live, default /run/user/UID), TGCONFIRM_PROC
(default /proc), TGCONFIRM_LOGIND (default /run/systemd), TGCONFIRM_URL (base URL of the route instead of http://127.0.0.1:PORT),
TGCONFIRM_NO_LOCK_CHECK=1, TGCONFIRM_ALLOW_UID (extra accepted uid).
"""

from __future__ import annotations

import asyncio
import collections
import hashlib
import json
import os
import re
import secrets
import signal
import socket
import struct
import sys
import time
import urllib.error
import urllib.request

# Explicit local path also supports the doctor's isolated (-I) invocation.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from telegram_files import MAX_REQUEST_BYTES, MAX_CAPTION, validate_attachment, attachment_description

MAX_TEXT = 4096
POPUP_TIMEOUT = 60            # seconds the owner has to press the code
EXEC_GRACE = 5                # seconds after the popup timeout before the process is killed
LOCK_WAIT = 10                # waiting for another popup to finish
RESOLVE_WAIT = 12             # the resolve call (local allowlist match, at most a few cached lookups)
SEND_WAIT = 25                # the send call itself
# worst case of one send request: 10 + 12 + (60 + 5) + 25 = 112 s. REQUEST_BUDGET is the hard cap; the clients wait longer
# (telegram-send.py 130 s, the gateway 150 s), so an agent never hears "timeout" for a message that is still on its way.
REQUEST_BUDGET = 115
RATE = (5, 600)               # popups per window
REQUEST_RATE = (20, 600)      # send requests per window (every one counts, with or without a popup)
SOCKET_CANDIDATES = range(10) # wayland-0 .. wayland-9
# processes that may sit between the session leader and the compositor (comm names): the wrapper, the login shell hypr-login execs
LOGIN_CHAIN = {"start-hyprland", "hypr-login", "sh", "bash", "zsh", "dash", "fish"}
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
        self.request_rate = RateLimit(*REQUEST_RATE, clock=mono)
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
    @property
    def proc(self) -> str:
        return self.env.get("TGCONFIRM_PROC", "/proc")

    def proc_status(self, pid: int) -> dict | None:
        """Name, parent pid and the four uids of a process from <proc>/PID/status; None when it is gone or unreadable."""
        try:
            with open(os.path.join(self.proc, str(pid), "status")) as f:
                text = f.read()
        except (OSError, ValueError):
            return None
        out: dict = {}
        for line in text.splitlines():
            k, _, v = line.partition(":")
            if k == "Name":
                out["name"] = v.strip()
            elif k == "PPid" and v.strip().isdigit():
                out["ppid"] = int(v)
            elif k == "Uid":
                try:
                    out["uids"] = [int(x) for x in v.split()]
                except ValueError:
                    return None
        return out if {"name", "ppid", "uids"} <= out.keys() else None

    def session_leader(self) -> tuple[int | None, str]:
        """(leader pid, why not) of the ACTIVE session on seat0, from logind's runtime files (root-owned: nobody else can edit them)."""
        logind = self.env.get("TGCONFIRM_LOGIND", "/run/systemd")

        def fields(path: str) -> dict:
            out = {}
            try:
                with open(path) as f:
                    for line in f:
                        k, sep, v = line.rstrip("\n").partition("=")
                        if sep:
                            out[k] = v
            except OSError:
                pass
            return out

        seat = fields(os.path.join(logind, "seats", "seat0"))
        sid = seat.get("ACTIVE", "")
        if not re.fullmatch(r"[A-Za-z0-9]{1,16}", sid):
            return None, "logind reports no active session on seat0"
        if seat.get("ACTIVE_UID", "") != str(self.owner_uid):
            return None, "the active session on seat0 is not the owner's"
        sess = fields(os.path.join(logind, "sessions", sid))
        if sess.get("UID") != str(self.owner_uid) or sess.get("SEAT") != "seat0" or sess.get("STATE") not in ("active", "online"):
            return None, "the active session on seat0 does not look like the owner's graphical session"
        if not sess.get("LEADER", "").isdigit() or int(sess["LEADER"]) <= 1:
            return None, "the active session has no leader process"
        return int(sess["LEADER"]), ""

    def check_compositor(self, pid: int, leader: int) -> str:
        """"" when pid is the owner's Hyprland started by the login chain of the session leader, else the reason it is not."""
        st = self.proc_status(pid)
        if st is None:
            return "its process is gone"
        if st["name"] != "Hyprland":
            return f"the server is {st['name']!r}, not Hyprland"
        if set(st["uids"]) != {self.owner_uid}:
            return "the server does not run as the owner"
        node, hops = st, 0
        while node["ppid"] != leader:
            hops += 1
            if hops > 4 or node["ppid"] <= 1:
                return "it is not a child of the login session's leader"
            parent = self.proc_status(node["ppid"])
            if parent is None:
                return "its parent is gone"
            if parent["name"] not in LOGIN_CHAIN:
                return f"it descends from {parent['name']!r}, not from the login chain"
            if set(parent["uids"]) != {self.owner_uid}:
                return "its parent does not run as the owner"
            node = parent
        return ""

    def open_wayland(self) -> tuple[socket.socket | None, str]:
        """(connected socket to the session compositor, "") or (None, reason).

        Connects to wayland-0..9 in the runtime directory (it cannot be listed: tgconfirm only has x on it) and keeps the socket whose
        server passes check_compositor. Two different compositors passing = refuse. The returned socket is the verified connection
        itself: ghostty gets it as WAYLAND_SOCKET, so the path is never used again."""
        leader, why = self.session_leader()
        if leader is None:
            return None, why
        base = self.env.get("TGCONFIRM_WAYLAND_DIR") or f"/run/user/{self.owner_uid}"
        good: dict[int, socket.socket] = {}
        seen = 0
        for n in SOCKET_CANDIDATES:
            path = os.path.join(base, f"wayland-{n}")
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.5)
            try:
                s.connect(path)
            except OSError:
                s.close()
                continue
            seen += 1
            try:
                pid, uid, _gid = struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            except OSError:
                s.close()
                continue
            bad = "" if uid == self.owner_uid else "the server does not run as the owner"
            bad = bad or self.check_compositor(pid, leader)
            if bad:
                log(f"wayland-{n}: refused ({bad}; peer pid {pid})")
                s.close()
            elif pid in good:       # a second path to the same compositor (a symlink): not a second candidate
                s.close()
            else:
                good[pid] = s
        if len(good) > 1:
            for s in good.values():
                s.close()
            log(f"{len(good)} different compositors claim to be the session: refusing")
            return None, "several Wayland servers claim to be the session compositor"
        if not good:
            return None, ("no Wayland socket belongs to the session compositor" + (f" ({seen} refused)" if seen else
                          " (none reachable: usr clipboard-acl gives tgconfirm the Wayland socket)"))
        sock = next(iter(good.values()))
        sock.setblocking(True)
        return sock, ""

    def screen_locked(self) -> bool:
        if self.env.get("TGCONFIRM_NO_LOCK_CHECK") == "1":
            return False
        try:
            names = os.listdir(self.proc)
        except OSError:
            return False
        for name in names:
            if not name.isdigit():
                continue
            try:
                with open(os.path.join(self.proc, name, "comm")) as f:
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

    def popup_env(self, wayland_fd: int) -> dict:
        rt = os.path.join(self.runtime, "rt")
        env = {"PATH": "/usr/local/bin:/usr/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "HOME": self.env.get("TGCONFIRM_HOME", "/var/lib/tgconfirm"), "XDG_RUNTIME_DIR": rt,
               "WAYLAND_SOCKET": str(wayland_fd), "GDK_BACKEND": "wayland", "LIBGL_ALWAYS_SOFTWARE": "1", "GSK_RENDERER": "cairo",
               "GSETTINGS_BACKEND": "memory", "GTK_A11Y": "none", "NO_AT_BRIDGE": "1", "TGCONFIRM_LIB": self.lib}
        for k, v in self.env.items():      # test hooks only (the unit never sets them): the keymap and the fake popup's switches
            if k == "TGCONFIRM_KEYMAP" or k.startswith("TGCONFIRM_FAKE"):
                env[k] = v
        return env

    async def popup(self, req: dict) -> str:
        """Show one popup and return "confirmed" | "cancelled" | "timeout" | "error: <why>". The broker never learns the code."""
        if self.screen_locked():
            return "error: the screen is locked"
        wl, why = self.open_wayland()
        if wl is None:
            return f"error: no desktop session reachable ({why})"
        rt = os.path.join(self.runtime, "rt")
        os.makedirs(rt, mode=0o700, exist_ok=True)
        os.chmod(rt, 0o700)
        nonce = secrets.token_hex(16)
        req_file = os.path.join(rt, f"{nonce}.req")
        res_file = os.path.join(rt, f"{nonce}.res")
        payload = {**req, "nonce": nonce, "timeout": POPUP_TIMEOUT, "result_file": res_file}
        proc = None
        try:
            fd = os.open(req_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(payload, f)
            argv = self.popup_argv(req_file)
            proc = await asyncio.create_subprocess_exec(*argv, env=self.popup_env(wl.fileno()), stdin=asyncio.subprocess.DEVNULL,
                                                        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
                                                        start_new_session=True, pass_fds=(wl.fileno(),))
            wl.close()      # the child has its own copy of the verified connection
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
            wl.close()
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

    async def x_send(self, account: str, body: dict, timeout: float) -> tuple[int, dict]:
        return await asyncio.get_running_loop().run_in_executor(None, self.x_send_sync, account, body, timeout)

    # --- operations -----------------------------------------------------------------------------------------------------
    def status(self) -> dict:
        return {"ok": True, "enabled": self.enabled(), "until": int(self.until) if self.enabled() else 0,
                "accounts": sorted(self.accounts), "configured": bool(self.token)}

    async def acquire(self) -> bool:
        """The popup lock, waited for at most LOCK_WAIT seconds (a cancelled request never keeps it)."""
        try:
            await asyncio.wait_for(self.lock.acquire(), LOCK_WAIT)
            return True
        except asyncio.TimeoutError:
            return False

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
        if not await self.acquire():
            return {"ok": False, "status": "rejected", "reason": "another confirmation popup is open, try again"}
        try:
            res = await self.popup({"kind": "enable", "title": "Allow AI agents to send Telegram messages?",
                                    "text": f"For {minutes} minutes. Every single message will still ask you again, with its full "
                                            f"text and recipient. Turning it off later needs no confirmation.", "minutes": minutes})
        finally:
            self.lock.release()
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
        is_file = msg.get('op') == 'send_file'
        text, chat, reply_to = msg.get("text", '' if is_file else None), msg.get("chat"), msg.get("reply_to")
        attachment = msg.get('attachment') if is_file else None
        if not isinstance(account, str) or account not in self.accounts:
            return {"ok": False, "status": "rejected", "reason": f"unknown account (known: {', '.join(sorted(self.accounts))})"}
        if is_file:
            try:
                validate_attachment(attachment)
            except ValueError as e:
                return {'ok': False, 'status': 'rejected', 'reason': str(e)}
        if not isinstance(text, str) or (not is_file and not text.strip()):
            return {"ok": False, "status": "rejected", "reason": "the text is empty"}
        max_text = MAX_CAPTION if is_file else MAX_TEXT
        if len(text.encode('utf-16-le')) // 2 > max_text:
            return {"ok": False, "status": "rejected", "reason": f"the text is longer than {max_text} characters"}
        if isinstance(chat, bool) or not isinstance(chat, (str, int)) or not str(chat).strip() or len(str(chat)) > 128:
            return {"ok": False, "status": "rejected", "reason": "chat must be a numeric id, an @username or the title of an allowed chat"}
        if reply_to in ("", 0):
            reply_to = None
        if reply_to is not None and (isinstance(reply_to, bool) or not isinstance(reply_to, int) or reply_to < 0):
            return {"ok": False, "status": "rejected", "reason": "reply_to must be a message id"}
        n, h = digest(text)
        if not self.request_rate.take():     # every request counts, popup or not
            log(f"send account={account} len={n} sha256={h} result=rejected(request rate)")
            return {"ok": False, "status": "rejected",
                    "reason": f"too many send requests ({REQUEST_RATE[0]} per {REQUEST_RATE[1] // 60} minutes), try later"}
        if not await self.acquire():
            return {"ok": False, "status": "rejected", "reason": "another confirmation popup is open, try again"}
        try:
            code, info = await self.x_send(account, {"action": "resolve", "chat": chat, "reply_to": reply_to}, RESOLVE_WAIT)
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
            popup_text = attachment_description(attachment) + '\n\nCaption:\n' + text if is_file else text
            res = await self.popup({"kind": "send", "title": "Send this Telegram file?" if is_file else "Send this Telegram message?", "account": account, "name": info.get("name", "?"),
                                    "username": info.get("username", ""), "chat_id": chat_id, "chat_kind": info.get("kind", ""),
                                    "reply_preview": info.get("reply_preview", ""), "reply_to": reply_to, "text": popup_text})
            if res != "confirmed":
                log(f"send account={account} chat={chat_id} len={n} sha256={h} result={clean_line(res)}")
                if res.startswith("error"):
                    return {"ok": False, "status": "rejected", "reason": clean_line(res[7:])}
                return {"ok": False, "status": res, "name": name}
            if not self.enabled():
                return {"ok": False, "status": "disabled", "reason": "sending was switched off"}
            # shielded: once the owner confirmed, a hang-up of the client must not tear the call down half way; the log line
            # below is written either way. (A client that left DURING the popup never gets here: the popup is cancelled.)
            payload = {"action": "send_file" if is_file else "send", "chat_id": chat_id, "text": text,
                       "reply_to": reply_to, "request_id": secrets.token_hex(12)}
            if is_file:
                payload['attachment'] = attachment
                log(f"file account={account} chat={chat_id} size={attachment['size']} sha256={attachment['sha256']} result=confirmed")
            code, out = await asyncio.shield(self.x_send(account, payload, SEND_WAIT))
            if code == 200 and out.get("ok"):
                log(f"send account={account} chat={chat_id} len={n} sha256={h} result=sent id={out.get('message_id')}")
                return {"ok": True, "status": "sent", "message_id": out.get("message_id"), "name": name, "chat_id": chat_id}
            why = clean_line(out.get("error") or f"telegram-mcp answered {code}")
            log(f"send account={account} chat={chat_id} len={n} sha256={h} result=failed({why})")
            if code == 0 or 'outcome unknown' in why or code >= 500:
                return {'ok': False, 'status': 'unknown', 'reason': why, 'name': name}
            return {"ok": False, "status": "rejected", "reason": why, "name": name}
        finally:
            self.lock.release()

    # --- socket server ----------------------------------------------------------------------------------------------------
    @staticmethod
    def peer_uid(writer) -> int:
        sock = writer.get_extra_info("socket")
        pid, uid, gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        return uid

    async def dispatch(self, msg: dict) -> dict:
        op = msg.get("op")
        if op == "status":
            return self.status()
        if op == "disable":
            return self.op_disable()
        if op in ("enable", "send", "send_file"):
            try:
                return await asyncio.wait_for(self.op_enable(msg) if op == "enable" else self.op_send(msg), REQUEST_BUDGET)
            except asyncio.TimeoutError:
                log(f"{op} result=budget exceeded")
                return {"ok": False, "status": "timeout", "reason": "the broker gave up (outcome unknown, check the chat before retrying)"}
        return {"ok": False, "status": "rejected", "reason": "unknown op"}

    async def run_op(self, msg: dict, reader) -> dict | None:
        """Run one operation; when the client closes its end first, cancel it (this closes an open popup) and return None."""
        task = asyncio.ensure_future(self.dispatch(msg))
        watch = asyncio.ensure_future(reader.read(1))
        try:
            while True:
                done, _ = await asyncio.wait({task, watch}, return_when=asyncio.FIRST_COMPLETED)
                if task in done:
                    return task.result()
                if watch.result():                       # stray byte: a client sends nothing after its request line
                    watch = asyncio.ensure_future(reader.read(1))
                    continue
                log(f"{msg.get('op')} client hung up: request cancelled")
                return None
        finally:
            for t in (task, watch):
                if not t.done():
                    t.cancel()
            await asyncio.gather(task, watch, return_exceptions=True)

    async def handle(self, reader, writer) -> None:
        try:
            uid = self.peer_uid(writer)
            if uid not in (self.owner_uid, 0, self.extra_uid):
                resp = {"ok": False, "status": "rejected", "reason": "not allowed for this user"}
            else:
                try:
                    line = await asyncio.wait_for(reader.readline(), 5)
                    if len(line) > MAX_REQUEST_BYTES:
                        raise ValueError
                    msg = json.loads(line)
                    if not isinstance(msg, dict):
                        raise ValueError
                except (ValueError, asyncio.TimeoutError):
                    msg = None
                if msg is None:
                    resp = {"ok": False, "status": "rejected", "reason": "bad request"}
                else:
                    resp = await self.run_op(msg, reader)
                    if resp is None:         # the client hung up while we worked: nobody to answer
                        return
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
            server = await asyncio.start_unix_server(self.handle, path=path, limit=MAX_REQUEST_BYTES)
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
    if "--check-wayland" in sys.argv[1:]:
        # read-only self test for doctor.sh (run as the owner): does the discovery accept the live session's compositor?
        b = Broker({**os.environ, "TGCONFIRM_OWNER_UID": os.environ.get("TGCONFIRM_OWNER_UID", str(os.getuid()))})
        sock, why = b.open_wayland()
        if sock is None:
            print(f"no verified compositor socket: {why}")
            return 1
        pid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]
        sock.close()
        print(f"verified: the session compositor is pid {pid}")
        return 0
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
