#!/usr/bin/env python3
"""Entry point of the telegram-mcp service (runs as the service user aimcp, started by `run`).

It wraps chigwell/telegram-mcp (source checkout in /opt/telegram-mcp/src, deps in /opt/telegram-mcp/venv) with four guards the
upstream HTTP mode does not have:

  1. fail closed before anything connects: the server must be in read-only mode and the chat allowlist must be non-empty
     (upstream treats an EMPTY allowlist as "every chat is allowed");
  2. a bearer token on every HTTP request (TELEGRAM_MCP_TOKEN, a credential shared only with the gateway user), so another
     local user or a browser page cannot talk to 127.0.0.1:8765 directly;
  3. a startup report on stderr: which tools are exposed, how many chats are allowed (never their ids or any secret);
  4. the owner-confirmed SEND route POST /x-send, NOT an MCP tool: it has its own token (TELEGRAM_SEND_TOKEN, a credential that
     only the tgconfirm broker holds, so no agent can call it), its own chat allowlist (TELEGRAM_SEND_ALLOWLIST, a subset of the
     read allowlist), a rate limit (sends and lookups), a length cap and an audit line per call (hash and length of the text, never the text). It
     resolves a chat only against that send allowlist (no Telegram lookup, and the same 403, for any other id, title or @username).
     It runs inside this process because Telegram allows one live Telethon process per session. Without both credentials it
     answers 503 "sending not set up". The MCP surface stays exactly read-only: check_env() is unchanged and no send tool is
     ever registered.

Everything else (session string, api id/hash, allowlist, read-only mode, transcription engine) comes from the environment that
`run` built from the systemd credentials. Test hooks: TELEGRAM_MCP_SRC.
"""

from __future__ import annotations

import asyncio
import collections
import hashlib
import hmac
import json
import os
import sys
import time
import io

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from telegram_files import MAX_REQUEST_BYTES, MAX_CAPTION, validate_attachment

SRC = os.environ.get("TELEGRAM_MCP_SRC", "/opt/telegram-mcp/src")


def check_env(env=os.environ) -> list[str]:
    """Problems that must stop the service from starting (empty list = fine)."""
    problems = []
    mode = env.get("TELEGRAM_EXPOSED_TOOLS", "").strip().lower()
    if mode != "read-only":
        problems.append(f"TELEGRAM_EXPOSED_TOOLS must be exactly 'read-only' (got {mode!r}): no write tool may be registered")
    allow = [t for t in env.get("TELEGRAM_ALLOWED_CHAT_IDS", "").replace(" ", "").split(",") if t]
    if not allow:
        problems.append("TELEGRAM_ALLOWED_CHAT_IDS is empty: upstream would allow every chat, refusing to start")
    if not env.get("TELEGRAM_MCP_TOKEN"):
        problems.append("TELEGRAM_MCP_TOKEN is empty: the HTTP endpoint would be unauthenticated")
    if env.get("MCP_TRANSPORT", "").lower() != "http":
        problems.append("MCP_TRANSPORT must be http")
    if env.get("MCP_HOST", "127.0.0.1") not in ("127.0.0.1", "localhost", "::1"):
        problems.append("MCP_HOST must be a loopback address")
    return problems


class BearerAuth:
    """Pure ASGI middleware: 401 unless `Authorization: Bearer <token>` matches (constant-time compare)."""

    def __init__(self, app, token: str):
        self.app = app
        self.token = token.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            supplied = b""
            for k, v in scope.get("headers", []):
                if k == b"authorization":
                    supplied = v[7:] if v[:7].lower() == b"bearer " else v
                    break
            if not hmac.compare_digest(supplied.strip(), self.token):
                body = b'{"error":"unauthorized"}'
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode()),
                                        (b"www-authenticate", b"Bearer")]})
                await send({"type": "http.response.body", "body": body})
                return
        await self.app(scope, receive, send)


# --- the owner-confirmed send route (/x-send) ------------------------------------------------------------------------------
SEND_PATH = "/x-send"
SEND_MAX_TEXT = 4096           # Telegram's own limit for one message
SEND_RATE = (5, 600)           # at most 5 send attempts per 600 s (all accounts together)
RESOLVE_RATE = (30, 600)       # at most 30 resolve calls per 600 s: the broker limits requests too, this is the second wall
SEND_BODY_MAX = MAX_REQUEST_BYTES
SEND_ID_RE = None              # set below (re is only needed here)

import re  # noqa: E402

SEND_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
SEND_ACCOUNT_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


class SendError(Exception):
    """A refusal with an HTTP status; the message is safe to show to the caller (never contains the text)."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def _bare(n: int) -> int:
    """Chat id without the marked-id decoration (-100... supergroups, - basic groups) for subset comparisons."""
    s = str(abs(n))
    return int(s[3:]) if s.startswith("100") and len(s) >= 13 else abs(n)


def send_config(env=os.environ, mcp_token: str = "") -> tuple[dict | None, str]:
    """(config, reason). config is None when sending is not set up or the setup is invalid; reason says why."""
    token = env.get("TELEGRAM_SEND_TOKEN", "").strip()
    raw = env.get("TELEGRAM_SEND_ALLOWLIST", "").replace(" ", "")
    if not token and not raw:
        return None, "not set up (no send credentials)"
    if not token or not raw:
        return None, "needs BOTH credentials send_token and send_allowlist"
    if len(token) < 32:
        return None, "send token is too short"
    if mcp_token and hmac.compare_digest(token.encode(), mcp_token.encode()):
        return None, "send token must differ from the MCP token"
    toks = [t for t in raw.split(",") if t]
    if not toks or not all(re.fullmatch(r"-?[0-9]+", t) for t in toks):
        return None, "send allowlist must be comma separated numeric chat ids"
    read = {_bare(int(t)) for t in env.get("TELEGRAM_ALLOWED_CHAT_IDS", "").replace(" ", "").split(",") if re.fullmatch(r"-?[0-9]+", t)}
    extra = [t for t in toks if _bare(int(t)) not in read]
    if extra:
        return None, f"send allowlist is not a subset of the read allowlist ({len(extra)} chat(s) outside it)"
    ids = [int(t) for t in toks]
    allowed = set()
    for i in ids:   # the same variants upstream's allowlist parser indexes: bare, basic-group and supergroup spellings
        allowed |= {i, _bare(i), -_bare(i), -1000000000000 - _bare(i)}
    return {"token": token, "ids": ids, "allowed": allowed}, ""


def audit(action: str, account: str, chat, text: str | None, result: str) -> None:
    """One journal line per call: when (journald), what, who, how long, a hash of the text. Never the text."""
    h = hashlib.sha256(text.encode()).hexdigest()[:16] if text is not None else "-"
    n = len(text) if text is not None else 0
    print(f"telegram-send: {action} account={account} chat={chat} len={n} sha256={h} result={result}", file=sys.stderr, flush=True)


def _display_name(entity) -> str:
    title = getattr(entity, "title", None)
    if title:
        return str(title)
    return " ".join(p for p in (getattr(entity, "first_name", None), getattr(entity, "last_name", None)) if p) or str(getattr(entity, "id", "?"))


NOT_ALLOWED = "that chat is not in the send allowlist"
ENTITY_TTL = 600               # seconds a fetched allowlist entity (name, username, kind) is reused
ENTITY_RETRY = 60              # seconds before a failed fetch of the allowlist is tried again


def _variants(marked: int) -> set[int]:
    """The spellings of one chat id that the send allowlist indexes (same set send_config builds)."""
    return {marked, _bare(marked), -_bare(marked), -1000000000000 - _bare(marked)}


class TelethonBackend:
    """Resolves chats and sends through the telegram-mcp client of this process (imported lazily: the tests use a fake).

    resolve() never asks Telegram about a chat the owner has not put on the send allowlist: a numeric id is checked against the
    allowlist first, and a title or @username is matched against the cached name / username of the allowlisted chats only (those
    are fetched once per ENTITY_TTL). Everything else is refused with the same 403, so the answer neither costs a Telegram
    lookup (FLOOD_WAIT on the owner's account) nor tells whether a username exists."""

    def __init__(self, clock=time.monotonic):
        self._rt = None
        self.clock = clock
        self.cache: dict[str, dict] = {}

    def rt(self):
        if self._rt is None:
            from telegram_mcp import runtime
            self._rt = runtime
        return self._rt

    def client(self, account: str):
        rt = self.rt()
        label = account
        try:
            return rt.get_client(label)
        except ValueError:
            # the broker's account "main" is the sole client of a single-account instance (label "default" upstream)
            if len(rt.clients) == 1 and account in ("main", "default"):
                return next(iter(rt.clients.values()))
            raise SendError(400, f"unknown account {account!r}")

    async def _entity(self, cl, ident):
        try:
            return await self.rt().resolve_entity(ident, cl)
        except SendError:
            raise
        except Exception as e:   # unresolvable, flood wait, network: a short reason, never a stack trace
            raise SendError(404, f"cannot resolve that chat ({type(e).__name__})")

    async def allowlisted(self, account: str, cl, ids: list[int]) -> list[dict]:
        """Info of the chats on the send allowlist (and only those): entity, marked id, name, username, kind."""
        now = self.clock()
        hit = self.cache.get(account)
        if hit and now - hit["at"] < (ENTITY_TTL if hit["items"] else ENTITY_RETRY):
            return hit["items"]
        rt, items = self.rt(), []
        for i in ids:
            try:
                e = await self._entity(cl, i)
            except SendError:
                continue
            m = rt.get_marked_id(e)
            items.append({"entity": e, "marked": m, "variants": _variants(m), "name": _display_name(e),
                          "username": (getattr(e, "username", None) or "").lower(), "kind": rt.get_entity_type(e)})
        self.cache[account] = {"at": now, "items": items}
        return items

    async def resolve(self, account: str, chat, ids: list[int], allowed: set[int], reply_to=None) -> dict:
        cl = self.client(account)
        if isinstance(chat, bool) or not isinstance(chat, (int, str)) or not str(chat).strip():
            raise SendError(400, "chat must be a numeric id, an @username or the title of an allowed chat")
        numeric = isinstance(chat, int) or bool(re.fullmatch(r"-?[0-9]+", chat.strip()))
        if numeric and int(chat) not in allowed:
            raise SendError(403, NOT_ALLOWED)          # decided locally: no Telegram call
        items = await self.allowlisted(account, cl, ids)
        if numeric:
            found = [it for it in items if int(chat) in it["variants"]]
            if not found:
                raise SendError(404, "cannot resolve that chat")
        elif chat.strip().startswith("@"):
            want = chat.strip().lstrip("@").lower()
            found = [it for it in items if want and it["username"] == want]
        else:
            want = chat.strip().casefold()
            found = [it for it in items if it["name"].casefold() == want] or [it for it in items if want in it["name"].casefold()]
        if not found:
            raise SendError(403, NOT_ALLOWED)          # same answer as for a numeric id: no oracle for names
        if len(found) != 1:
            raise SendError(409, "several allowed chats match that name")
        it = found[0]
        if it["marked"] not in allowed:
            raise SendError(403, NOT_ALLOWED)
        entity = it["entity"]
        out = {"chat_id": it["marked"], "name": it["name"], "username": getattr(entity, "username", None) or "",
               "kind": it["kind"], "reply_preview": ""}
        if reply_to:
            try:
                m = await cl.get_messages(entity, ids=int(reply_to))
                if m is not None and not isinstance(m, list):
                    out["reply_preview"] = ((m.message or "[no text]")[:300]).replace("\x00", "")
                else:
                    raise SendError(404, "the message to reply to was not found")
            except SendError:
                raise
            except Exception:
                raise SendError(404, "the message to reply to could not be read")
        return out

    async def send(self, account: str, chat_id: int, text: str, reply_to, allowed: set[int]) -> dict:
        rt, cl = self.rt(), self.client(account)
        entity = await self._entity(cl, chat_id)
        if rt.get_marked_id(entity) not in allowed:
            raise SendError(403, NOT_ALLOWED)
        try:
            # parse_mode=None: the text goes out exactly as the owner saw it in the popup (Telethon's default would parse markdown)
            msg = await cl.send_message(entity, text, reply_to=reply_to, parse_mode=None)
        except Exception as e:
            raise SendError(502, f"Telegram refused the message ({type(e).__name__})")
        return {"message_id": getattr(msg, "id", None), "chat_id": rt.get_marked_id(entity)}

    async def send_file(self, account, chat_id, text, reply_to, allowed, attachment):
        content = validate_attachment(attachment)
        rt, cl = self.rt(), self.client(account)
        entity = await self._entity(cl, chat_id)
        if rt.get_marked_id(entity) not in allowed:
            raise SendError(403, NOT_ALLOWED)
        stream = io.BytesIO(content)
        stream.name = attachment['name']
        try:
            msg = await cl.send_file(entity, stream, caption=text, reply_to=reply_to,
                                     force_document=True, parse_mode=None)
        except Exception as e:
            raise SendError(502, f"Telegram upload failed ({type(e).__name__}); outcome unknown, check the chat")
        return {"message_id": getattr(msg, 'id', None), "chat_id": rt.get_marked_id(entity)}


async def _json(send, status: int, payload: dict) -> None:
    body = json.dumps(payload).encode()
    await send({"type": "http.response.start", "status": status,
                "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})


class SendRoute:
    """Pure ASGI wrapper: POST /x-send is handled here, every other path goes to the (bearer-protected) MCP app.

    The route is a different door than /mcp: its token is the send token, the MCP token does not open it (401), and the send
    token does not open /mcp (BearerAuth). POST JSON, one of:
      {"action": "resolve", "account", "chat", "reply_to"?}   -> {chat_id, name, username, kind, reply_preview}
      {"action": "send", "account", "chat_id", "text", "reply_to"?, "request_id"}  -> {message_id, chat_id}
    """

    def __init__(self, app, cfg: dict | None, reason: str = "", backend=None, clock=time.monotonic):
        self.app, self.cfg, self.reason = app, cfg, reason
        self.backend = backend or TelethonBackend()
        self.clock = clock
        self.sent_at: collections.deque = collections.deque()
        self.resolved_at: collections.deque = collections.deque()
        self.done: collections.OrderedDict = collections.OrderedDict()   # request_id -> result (idempotent retries)
        self.lock = asyncio.Lock()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path") != SEND_PATH:
            return await self.app(scope, receive, send)
        if self.cfg is None:
            return await _json(send, 503, {"error": "sending not set up"})
        if scope.get("method") != "POST":
            return await _json(send, 405, {"error": "POST only"})
        supplied = b""
        for k, v in scope.get("headers", []):
            if k == b"authorization":
                supplied = v[7:] if v[:7].lower() == b"bearer " else v
                break
        if not hmac.compare_digest(supplied.strip(), self.cfg["token"].encode()):
            return await _json(send, 401, {"error": "unauthorized"})
        body = b""
        while True:
            msg = await receive()
            body += msg.get("body", b"")
            if len(body) > SEND_BODY_MAX:
                return await _json(send, 413, {"error": "request too large"})
            if not msg.get("more_body"):
                break
        try:
            data = json.loads(body)
            if not isinstance(data, dict):
                raise ValueError
        except ValueError:
            return await _json(send, 400, {"error": "body must be a JSON object"})
        try:
            result = await self.dispatch(data)
        except SendError as e:
            return await _json(send, e.status, {"error": e.message})
        except Exception as e:   # never a stack trace or the text in the response
            audit("error", str(data.get("account", "?")), data.get("chat_id", data.get("chat", "?")), None, type(e).__name__)
            return await _json(send, 500, {"error": "internal error"})
        await _json(send, 200, {"ok": True, **result})

    @staticmethod
    def _account(data: dict) -> str:
        account = data.get("account", "main")
        if not isinstance(account, str) or not SEND_ACCOUNT_RE.match(account):
            raise SendError(400, "bad account")
        return account

    @staticmethod
    def _reply_to(data: dict):
        r = data.get("reply_to")
        if r in (None, "", 0):
            return None
        if isinstance(r, bool) or not isinstance(r, int) or r < 0:
            raise SendError(400, "reply_to must be a message id")
        return r

    async def dispatch(self, data: dict) -> dict:
        action = data.get("action", "send")
        account, reply_to = self._account(data), self._reply_to(data)
        if action == "resolve":
            chat = data.get("chat", data.get("chat_id"))
            now = self.clock()
            while self.resolved_at and now - self.resolved_at[0] > RESOLVE_RATE[1]:
                self.resolved_at.popleft()
            if len(self.resolved_at) >= RESOLVE_RATE[0]:
                audit("resolve", account, "-", None, "refused(rate)")
                raise SendError(429, f"rate limit: {RESOLVE_RATE[0]} lookups per {RESOLVE_RATE[1] // 60} minutes")
            self.resolved_at.append(now)
            try:
                out = await self.backend.resolve(account, chat, self.cfg["ids"], self.cfg["allowed"], reply_to)
            except SendError as e:
                audit("resolve", account, str(chat)[:40], None, f"refused({e.status})")
                raise
            audit("resolve", account, out["chat_id"], None, "ok")
            return out
        if action not in ("send", "send_file"):
            raise SendError(400, "unknown action")
        chat_id, text, rid = data.get("chat_id"), data.get("text"), data.get("request_id")
        if isinstance(chat_id, bool) or not isinstance(chat_id, int):
            raise SendError(400, "chat_id must be the numeric id returned by resolve")
        attachment = None
        if action == 'send_file':
            attachment = data.get('attachment')
            try:
                validate_attachment(attachment)
            except ValueError as e:
                raise SendError(400, str(e))
        if not isinstance(text, str) or (action == 'send' and not text.strip()):
            raise SendError(400, "text is empty")
        max_text = MAX_CAPTION if attachment is not None else SEND_MAX_TEXT
        if len(text.encode('utf-16-le')) // 2 > max_text:
            raise SendError(413, f"text is longer than {max_text} characters")
        if not isinstance(rid, str) or not SEND_ID_RE.match(rid):
            raise SendError(400, "request_id is required (8-64 characters of A-Za-z0-9_-)")
        if chat_id not in self.cfg["allowed"]:   # cheap check before any Telegram call
            audit("send", account, chat_id, text, "refused(allowlist)")
            raise SendError(403, "that chat is not in the send allowlist")
        async with self.lock:
            if rid in self.done:
                return {**self.done[rid], "replayed": True}
            now = self.clock()
            while self.sent_at and now - self.sent_at[0] > SEND_RATE[1]:
                self.sent_at.popleft()
            if len(self.sent_at) >= SEND_RATE[0]:
                audit("send", account, chat_id, text, "refused(rate)")
                raise SendError(429, f"rate limit: {SEND_RATE[0]} messages per {SEND_RATE[1] // 60} minutes")
            self.sent_at.append(now)
            try:
                if attachment is not None:
                    audit('file', account, chat_id, None,
                          f"size={attachment['size']} sha256={attachment['sha256']}")
                    out = await self.backend.send_file(account, chat_id, text, reply_to, self.cfg['allowed'], attachment)
                else:
                    out = await self.backend.send(account, chat_id, text, reply_to, self.cfg["allowed"])
            except SendError as e:
                audit("send", account, chat_id, text, f"refused({e.status})")
                raise
            audit("send", account, chat_id, text, f"sent id={out.get('message_id')}")
            self.done[rid] = out
            while len(self.done) > 200:
                self.done.popitem(last=False)
            return out


def install_auth(server, token: str, send_cfg: dict | None = None, send_reason: str = "", backend=None) -> None:
    """Make every ASGI app the FastMCP server builds go through BearerAuth, with the /x-send route in front of it."""
    original = server.streamable_http_app

    def with_auth(*args, **kwargs):
        # a plain ASGI wrapper: the app FastMCP returns is not always a Starlette instance (mcp 1.30 wraps it in a protocol
        # negotiation middleware), so add_middleware is not available; uvicorn and TestClient take any ASGI callable
        return SendRoute(BearerAuth(original(*args, **kwargs), token), send_cfg, send_reason, backend)

    server.streamable_http_app = with_auth


def main() -> None:
    problems = check_env()
    if problems:
        for p in problems:
            print(f"telegram-mcp: {p}", file=sys.stderr)
        sys.exit(78)  # EX_CONFIG
    token = os.environ.pop("TELEGRAM_MCP_TOKEN")
    send_cfg, send_reason = send_config(os.environ, token)
    os.environ.pop("TELEGRAM_SEND_TOKEN", None)
    os.environ.pop("TELEGRAM_SEND_ALLOWLIST", None)
    sys.path.insert(0, SRC)
    os.chdir(os.environ.get("TELEGRAM_MCP_WORKDIR", "/var/lib/telegram-mcp"))
    import telegram_mcp.runner as runner  # builds the Telethon clients from the environment, registers the tools
    from telegram_mcp import runtime

    import call_metadata
    call_metadata.install()

    install_auth(runtime.mcp, token, send_cfg, send_reason)
    print("telegram-mcp: read-only, allowlist of "
          f"{len([t for t in os.environ['TELEGRAM_ALLOWED_CHAT_IDS'].split(',') if t.strip()])} chat(s), bearer auth on; "
          + (f"/x-send on for {len(send_cfg['ids'])} chat(s)" if send_cfg else f"/x-send off: {send_reason}"), file=sys.stderr)
    runner.main()


if __name__ == "__main__":
    main()
