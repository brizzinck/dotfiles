#!/usr/bin/env python3
"""Tests of infrastructure/mcp/telegram/serve.py: the fail-closed environment check, the bearer middleware and (when the
telegram-mcp venv + source exist: TELEGRAM_MCP_PY / TELEGRAM_MCP_SRC) the real server surface. Prints `ok NAME` / `FAIL NAME`.
Usage: test_telegram_serve.py REPO"""
import asyncio
import importlib.util
import json
import os
import sys

repo = sys.argv[1]
spec = importlib.util.spec_from_file_location("serve", os.path.join(repo, "infrastructure/mcp/telegram/serve.py"))
serve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(serve)
results = []


def check(name, cond):
    results.append(bool(cond))
    print(("ok " if cond else "FAIL ") + name)


good = {"TELEGRAM_EXPOSED_TOOLS": "read-only", "TELEGRAM_ALLOWED_CHAT_IDS": "-100123,42", "TELEGRAM_MCP_TOKEN": "t" * 40,
        "MCP_TRANSPORT": "http", "MCP_HOST": "127.0.0.1"}
check("a complete read-only environment is accepted", serve.check_env(good) == [])
check("write tools mode refused", serve.check_env({**good, "TELEGRAM_EXPOSED_TOOLS": "all"}))
check("read-only plus a write tool refused", serve.check_env({**good, "TELEGRAM_EXPOSED_TOOLS": "read-only+send_message"}))
check("unset mode refused", serve.check_env({k: v for k, v in good.items() if k != "TELEGRAM_EXPOSED_TOOLS"}))
check("an empty allowlist is refused (upstream would allow every chat)", serve.check_env({**good, "TELEGRAM_ALLOWED_CHAT_IDS": ""}))
check("a blank-only allowlist is refused", serve.check_env({**good, "TELEGRAM_ALLOWED_CHAT_IDS": " , ,"}))
check("a missing token is refused", serve.check_env({**good, "TELEGRAM_MCP_TOKEN": ""}))
check("a non-loopback host is refused", serve.check_env({**good, "MCP_HOST": "0.0.0.0"}))
check("stdio transport refused", serve.check_env({**good, "MCP_TRANSPORT": "stdio"}))


async def asgi(app, headers):
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(msg):
        sent.append(msg)

    await app({"type": "http", "headers": headers, "path": "/mcp", "method": "POST"}, receive, send)
    return sent


async def inner(scope, receive, send):
    await send({"type": "http.response.start", "status": 200, "headers": []})
    await send({"type": "http.response.body", "body": b"inner"})


def status(sent):
    return sent[0]["status"]


async def middleware_tests():
    app = serve.BearerAuth(inner, "secret-token-value")
    check("no Authorization header -> 401", status(await asgi(app, [])) == 401)
    check("wrong token -> 401", status(await asgi(app, [(b"authorization", b"Bearer nope")])) == 401)
    check("right token -> passes through", status(await asgi(app, [(b"authorization", b"Bearer secret-token-value")])) == 200)
    check("token without the Bearer word also works (mcp-proxy forwards what it is given)", status(await asgi(app, [(b"authorization", b"secret-token-value")])) == 200)
    body = b"".join(m.get("body", b"") for m in await asgi(app, []))
    check("401 body does not leak the token", b"secret-token-value" not in body)
    lifespan = []

    async def life_inner(scope, receive, send):
        lifespan.append(scope["type"])

    await serve.BearerAuth(life_inner, "x")({"type": "lifespan"}, None, None)
    check("lifespan events are not blocked", lifespan == ["lifespan"])


asyncio.run(middleware_tests())


# --- the /x-send route (fake Telethon backend: nothing is ever sent) -----------------------------------------------------------
SEND_TOKEN = "S" * 40
MCP_TOKEN = "M" * 40
send_env = {"TELEGRAM_SEND_TOKEN": SEND_TOKEN, "TELEGRAM_SEND_ALLOWLIST": "-1001111,42",
            "TELEGRAM_ALLOWED_CHAT_IDS": "-1001111,42,777"}
cfg, why = serve.send_config(send_env, MCP_TOKEN)
check("send_config: a complete setup is accepted", cfg is not None and cfg["ids"] == [-1001111, 42])
check("send_config: no credentials = not set up", serve.send_config({"TELEGRAM_ALLOWED_CHAT_IDS": "1"}, MCP_TOKEN)[0] is None)
check("send_config: a token without an allowlist is refused", serve.send_config({**send_env, "TELEGRAM_SEND_ALLOWLIST": ""}, MCP_TOKEN)[0] is None)
check("send_config: an allowlist without a token is refused", serve.send_config({**send_env, "TELEGRAM_SEND_TOKEN": ""}, MCP_TOKEN)[0] is None)
check("send_config: the send allowlist must be a subset of the read allowlist", serve.send_config({**send_env, "TELEGRAM_SEND_ALLOWLIST": "-1001111,999"}, MCP_TOKEN)[0] is None)
check("send_config: the send token must differ from the MCP token", serve.send_config({**send_env, "TELEGRAM_SEND_TOKEN": MCP_TOKEN}, MCP_TOKEN)[0] is None)
check("send_config: a short token is refused", serve.send_config({**send_env, "TELEGRAM_SEND_TOKEN": "short"}, MCP_TOKEN)[0] is None)
check("send_config: a non-numeric allowlist is refused", serve.send_config({**send_env, "TELEGRAM_SEND_ALLOWLIST": "@mychat"}, MCP_TOKEN)[0] is None)
check("check_env still demands exactly read-only (the send route does not change it)",
      serve.check_env({**good, "TELEGRAM_EXPOSED_TOOLS": "all"}) and serve.check_env({**good, **send_env}) == [])


class FakeBackend:
    def __init__(self):
        self.calls = []

    async def resolve(self, account, chat, ids, allowed, reply_to=None):
        self.calls.append(("resolve", account, chat))
        if chat in ("999", 999):
            raise serve.SendError(403, "that chat is not in the send allowlist")
        return {"chat_id": -1001111, "name": "Work chat", "username": "work", "kind": "Supergroup", "reply_preview": "hi" if reply_to else ""}

    async def send(self, account, chat_id, text, reply_to, allowed):
        self.calls.append(("send", account, chat_id, text, reply_to))
        return {"message_id": 100 + len([c for c in self.calls if c[0] == "send"]), "chat_id": chat_id}


async def post(app, token, body, path="/x-send", method="POST", raw=None):
    sent, payload = [], raw if raw is not None else json.dumps(body).encode()

    async def receive():
        return {"type": "http.request", "body": payload, "more_body": False}

    async def send(msg):
        sent.append(msg)

    hdr = [(b"authorization", b"Bearer " + token.encode())] if token else []
    await app({"type": "http", "headers": hdr, "path": path, "method": method}, receive, send)
    b = b"".join(m.get("body", b"") for m in sent)
    try:
        js = json.loads(b) if b else {}
    except ValueError:
        js = {}
    return sent[0]["status"], js, b


def audit_lines(fn):
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        out = asyncio.run(fn())
    return out, buf.getvalue()


async def send_tests():
    be, clock = FakeBackend(), [0.0]
    mcp_reached = []

    async def mcp_inner(scope, receive, send):
        mcp_reached.append(scope["path"])
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"mcp"})

    app = serve.SendRoute(serve.BearerAuth(mcp_inner, MCP_TOKEN), cfg, "", be, clock=lambda: clock[0])
    good_send = {"action": "send", "account": "main", "chat_id": -1001111, "text": "hello there", "request_id": "req-0000001"}
    st, _, _ = await post(app, MCP_TOKEN, good_send)
    check("/x-send: the MCP token is refused (401)", st == 401 and not be.calls)
    st, _, _ = await post(app, "", good_send)
    check("/x-send: no token is refused (401)", st == 401)
    st, _, _ = await post(app, "wrong" * 8, good_send)
    check("/x-send: a wrong token is refused (401)", st == 401 and not be.calls)
    st, _, _ = await post(app, SEND_TOKEN, good_send, method="GET")
    check("/x-send: GET is refused (405)", st == 405)
    st, js, _ = await post(app, SEND_TOKEN, good_send)
    check("/x-send: the send token sends", st == 200 and js["ok"] and js["message_id"] == 101 and be.calls[-1][:3] == ("send", "main", -1001111))
    st, js, _ = await post(app, SEND_TOKEN, good_send)
    check("/x-send: a retried request_id does not send twice", st == 200 and js.get("replayed") and len([c for c in be.calls if c[0] == "send"]) == 1)
    st, _, _ = await post(app, SEND_TOKEN, {**good_send, "request_id": "req-0000002", "chat_id": 555})
    check("/x-send: a chat outside the send allowlist is refused before any Telegram call (403)", st == 403 and len([c for c in be.calls if c[0] == "send"]) == 1)
    st, _, _ = await post(app, SEND_TOKEN, {**good_send, "request_id": "req-0000003", "text": "   "})
    check("/x-send: an empty text is refused (400)", st == 400)
    st, _, _ = await post(app, SEND_TOKEN, {**good_send, "request_id": "req-0000004", "text": "x" * 4097})
    check("/x-send: a text over 4096 characters is refused (413)", st == 413)
    st, _, _ = await post(app, SEND_TOKEN, {**good_send, "request_id": "short"})
    check("/x-send: a missing or short request_id is refused (400)", st == 400)
    st, _, _ = await post(app, SEND_TOKEN, {**good_send, "request_id": "req-0000005", "chat_id": "-1001111"})
    check("/x-send: send needs the numeric id from resolve (400)", st == 400)
    st, _, _ = await post(app, SEND_TOKEN, None, raw=b"not json")
    check("/x-send: bad JSON is refused (400)", st == 400)
    st, _, _ = await post(app, SEND_TOKEN, None, raw=b"x" * 70000)
    check("/x-send: an oversized body is refused (413)", st == 413)
    st, js, _ = await post(app, SEND_TOKEN, {"action": "resolve", "account": "main", "chat": "Work chat", "reply_to": 5})
    check("/x-send: resolve returns the name, id and the reply preview", st == 200 and js["name"] == "Work chat" and js["chat_id"] == -1001111 and js["reply_preview"] == "hi")
    st, _, _ = await post(app, SEND_TOKEN, {"action": "resolve", "account": "main", "chat": "999"})
    check("/x-send: resolve of a chat outside the send allowlist is refused (403)", st == 403)
    st, _, _ = await post(app, SEND_TOKEN, {"action": "frobnicate"})
    check("/x-send: an unknown action is refused (400)", st == 400)
    st, _, _ = await post(app, MCP_TOKEN, {}, path="/mcp")
    check("/mcp still goes through its own bearer check and reaches the MCP app", st == 200 and mcp_reached == ["/mcp"])
    st, _, _ = await post(app, SEND_TOKEN, {}, path="/mcp")
    check("/mcp: the send token does not open the MCP endpoint (401)", st == 401 and mcp_reached == ["/mcp"])
    # rate limit: 5 attempts per 600 s
    n_ok = 1   # the first send above already counted
    codes = []
    for i in range(7):
        st, _, _ = await post(app, SEND_TOKEN, {**good_send, "request_id": f"req-rate-{i:04d}"})
        codes.append(st)
    check("/x-send: the 6th send within 10 minutes is refused (429)", codes[:4] == [200] * 4 and codes[4:] == [429] * 3)
    clock[0] += 601
    st, _, _ = await post(app, SEND_TOKEN, {**good_send, "request_id": "req-after-rate"})
    check("/x-send: the rate window slides (a send is possible again after 10 minutes)", st == 200)


async def audit_tests():
    be = FakeBackend()
    app = serve.SendRoute(serve.BearerAuth(inner, MCP_TOKEN), cfg, "", be)
    secret = "TOP-SECRET-WORDS-123"
    await post(app, SEND_TOKEN, {"action": "send", "account": "main", "chat_id": -1001111, "text": secret, "request_id": "req-audit-01"})


import contextlib
import hashlib
import io

buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    asyncio.run(audit_tests())
line = buf.getvalue()
check("audit: one journal line with account, chat, length and a sha256 prefix", "telegram-send: send account=main chat=-1001111 len=20 sha256=" + hashlib.sha256(b"TOP-SECRET-WORDS-123").hexdigest()[:16] in line)
check("audit: the text itself is never logged", "TOP-SECRET" not in line)
with contextlib.redirect_stderr(io.StringIO()):
    asyncio.run(send_tests())


async def unconfigured_tests():
    app = serve.SendRoute(serve.BearerAuth(inner, MCP_TOKEN), None, "not set up")
    st, js, _ = await post(app, SEND_TOKEN, {"action": "send"})
    check("/x-send without send credentials answers 503 'sending not set up'", st == 503 and js["error"] == "sending not set up")
    st, js, _ = await post(app, "", {"action": "send"})
    check("/x-send: 503 even without a token (nothing to authenticate against)", st == 503)


asyncio.run(unconfigured_tests())

py_ok = os.environ.get("TELEGRAM_MCP_PY") and os.path.exists(os.environ["TELEGRAM_MCP_PY"])
if os.environ.get("RUN_REAL_SERVER") == "1":
    # inside the telegram-mcp venv: the real tool surface in read-only mode
    sys.path.insert(0, os.environ["TELEGRAM_MCP_SRC"])
    import telegram_mcp.runner  # noqa: F401  (registers the tools)
    from telegram_mcp import runtime

    runtime._apply_exposed_tools_mode()
    tools = {t.name: t for t in runtime.mcp._tool_manager.list_tools()}
    check("read-only mode exposes only readOnlyHint tools", tools and all(getattr(t.annotations, "readOnlyHint", False) for t in tools.values()))
    check("no send/edit/delete/forward/mark/draft tool is registered",
          not [n for n in tools if n.startswith(("send_", "reply_", "edit_", "delete_", "forward_", "mark_", "save_draft", "clear_draft", "upload_", "ban_", "join_", "leave_"))])
    gateway = json.load(open(os.path.join(repo, ".config/mcp/gateway.json")))
    allow = gateway["mcpServers"]["telegram"]["options"]["toolFilter"]["list"]
    check("every gateway-allowed telegram tool really exists upstream", set(allow) <= set(tools))
    # the send route's Telethon glue against the real runtime helpers, with a fake client: nothing connects, nothing is sent
    import datetime

    from telethon.tl import types

    chan = types.Channel(id=1111, title="Work chat", photo=types.ChatPhotoEmpty(), date=datetime.datetime.now(), megagroup=True)
    user = types.User(id=42, first_name="Ann", last_name="Lee", username="ann")
    other = types.User(id=555, first_name="Stranger")
    ents = {-1000000001111: chan, 42: user, 555: other, "@ann": user, "@stranger": other}

    class FakeMsg:
        id = 900
        message = "replied-to text"

    class FakeClient:
        sent = []

        async def get_messages(self, entity, ids=None):
            return FakeMsg()

        async def send_message(self, entity, text, reply_to=None, parse_mode="unset"):
            FakeClient.sent.append((entity, text, reply_to, parse_mode))
            return FakeMsg()

    async def fake_resolve(ident, client=None):
        if ident in ents:
            return ents[ident]
        raise ValueError("unknown")

    runtime.clients.clear()
    runtime.clients["default"] = FakeClient()
    runtime.resolve_entity = fake_resolve
    scfg, _ = serve.send_config({"TELEGRAM_SEND_TOKEN": "S" * 40, "TELEGRAM_SEND_ALLOWLIST": "-1000000001111,42", "TELEGRAM_ALLOWED_CHAT_IDS": "-1000000001111,42,555"}, "M" * 40)
    be = serve.TelethonBackend()

    async def glue():
        r = await be.resolve("main", "work chat", scfg["ids"], scfg["allowed"])
        check("glue: a title resolves among the allowed chats only", r["chat_id"] == -1000000001111 and r["name"] == "Work chat" and r["kind"] == "Supergroup")
        r = await be.resolve("main", "@ann", scfg["ids"], scfg["allowed"], reply_to=7)
        check("glue: @username resolves, the reply preview is read", r["chat_id"] == 42 and r["name"] == "Ann Lee" and r["username"] == "ann" and r["reply_preview"] == "replied-to text")
        refused = []
        for chat in ("@stranger", 555, "Stranger"):
            try:
                await be.resolve("main", chat, scfg["ids"], scfg["allowed"])
            except serve.SendError as e:
                refused.append(e.status)
        check("glue: a chat that is readable but not sendable is refused", refused == [403, 403, 404])
        out = await be.send("main", -1000000001111, "plain **text**", None, scfg["allowed"])
        check("glue: send goes through the same client, plain text (parse_mode=None), same entity", out["chat_id"] == -1000000001111 and FakeClient.sent == [(chan, "plain **text**", None, None)])
        try:
            await be.send("main", 555, "x", None, scfg["allowed"])
            check("glue: send to a non-allowlisted chat is refused", False)
        except serve.SendError as e:
            check("glue: send to a non-allowlisted chat is refused", e.status == 403 and len(FakeClient.sent) == 1)
        try:
            be.client("nope-account")
            check("glue: an unknown account is refused", False)
        except serve.SendError as e:
            check("glue: an unknown account is refused", e.status == 400)

    asyncio.run(glue())
    serve.install_auth(runtime.mcp, "tok-" + "z" * 40)
    from starlette.testclient import TestClient

    app = runtime.mcp.streamable_http_app()
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}}
    hdr = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
    with TestClient(app, base_url="http://127.0.0.1:8765") as c:
        check("real app: no token -> 401", c.post("/mcp", json=init, headers=hdr).status_code == 401)
        check("real app: wrong token -> 401", c.post("/mcp", json=init, headers={**hdr, "Authorization": "Bearer x"}).status_code == 401)
        r = c.post("/mcp", json=init, headers={**hdr, "Authorization": "Bearer tok-" + "z" * 40})
        check("real app: right token initialises", r.status_code == 200 and "serverInfo" in r.text)
        r = c.post("/x-send", json={"action": "send"}, headers={"Authorization": "Bearer tok-" + "z" * 40})
        check("real app: /x-send without send credentials answers 503, the MCP token does not open it", r.status_code == 503)
else:
    if py_ok:
        env = dict(os.environ, RUN_REAL_SERVER="1")
        # a syntactically valid but fake session string: nothing connects, the tool surface is only inspected
        gen = "from telethon.sessions import StringSession; from telethon.crypto import AuthKey; import os; s=StringSession(); s.set_dc(2,'149.154.167.51',443); s.auth_key=AuthKey(os.urandom(256)); print(s.save())"
        import subprocess

        fake = subprocess.run([os.environ["TELEGRAM_MCP_PY"], "-c", gen], capture_output=True, text=True).stdout.strip()
        env.update(TELEGRAM_API_ID="1", TELEGRAM_API_HASH="0" * 32, TELEGRAM_SESSION_STRING=fake, TELEGRAM_EXPOSED_TOOLS="read-only",
                   TELEGRAM_ALLOWED_CHAT_IDS="1", TELEGRAM_MCP_TOKEN="x", MCP_TRANSPORT="http")
        p = subprocess.run([os.environ["TELEGRAM_MCP_PY"], __file__, repo], env=env, capture_output=True, text=True)
        for line in p.stdout.splitlines():
            if line.startswith(("ok ", "FAIL ")):
                results.append(line.startswith("ok "))
                print(line)
        if not any(l.startswith("ok real app") for l in p.stdout.splitlines()):
            results.append(False)
            print("FAIL real server test produced no result: " + p.stderr.strip().splitlines()[-1][:200] if p.stderr.strip() else "FAIL real server test produced no result")
    else:
        print("SKIP real telegram-mcp surface (no venv: set TELEGRAM_MCP_PY and TELEGRAM_MCP_SRC, or run apply-system.sh --only mcp)")
sys.exit(0 if all(results) else 1)
