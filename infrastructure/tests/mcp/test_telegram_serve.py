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
