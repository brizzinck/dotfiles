#!/usr/bin/env python3
"""Protocol test of .config/mcp/telegram-send.py (the agents' send-request MCP server) against a FAKE broker on a unix socket.
Run with the python of the pinned MCP venv: test_telegram_send.py SERVER_PY. Prints `ok NAME` / `FAIL NAME`.
The server holds no secret and has no Telegram code: the test checks the tool surface, the request it puts on the socket, how
every broker answer is shown to the agent, and that a missing/dead broker is a clear refusal, never a hang or a traceback."""
import asyncio
import contextlib
import json
import os
import sys
import tempfile

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

server = sys.argv[1]
results = []


def check(name, cond):
    results.append(bool(cond))
    print(("ok " if cond else "FAIL ") + name)


TMP = tempfile.mkdtemp(prefix="tgsend-test.")
SOCK = f"{TMP}/req.sock"
seen = []
answer = {}


async def handle(reader, writer):
    line = await reader.readline()
    msg = json.loads(line)
    seen.append(msg)
    if answer.get("hang"):
        await asyncio.sleep(30)
    writer.write(json.dumps(answer["resp"]).encode() + b"\n")
    await writer.drain()
    writer.close()


@contextlib.asynccontextmanager
async def session(sock=SOCK, **extra):
    env = {"PATH": os.environ["PATH"], "TGSEND_SOCK": sock, **extra}
    params = StdioServerParameters(command=sys.executable, args=[server], env=env)
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            yield s


async def call(s, name, args=None):
    res = await s.call_tool(name, args or {})
    return res.isError, "\n".join(c.text for c in res.content if hasattr(c, "text"))


async def main():
    srv = await asyncio.start_unix_server(handle, path=SOCK)
    async with session() as s:
        tools = {t.name: t for t in (await s.list_tools()).tools}
        check("exactly two tools: send_message and status", sorted(tools) == ["send_message", "status"])
        check("send_message is not marked read-only, status is", not tools["send_message"].annotations.readOnlyHint and tools["status"].annotations.readOnlyHint)
        props = tools["send_message"].inputSchema["properties"]
        check("send_message takes chat, text, reply_to, account (no code, no token, no confirm flag)", sorted(props) == ["account", "chat", "reply_to", "text"])
        check("the description tells the agent that the owner confirms every message", "popup" in tools["send_message"].description and "NOTHING is sent" in tools["send_message"].description)

        answer["resp"] = {"ok": True, "status": "sent", "message_id": 4242, "name": "Work chat", "chat_id": -1001}
        err, text = await call(s, "send_message", {"chat": "Work chat", "text": "hi\nthere"})
        check("sent: the agent sees the id and the recipient", not err and "sent (id 4242)" in text and "Work chat" in text)
        check("the request on the socket is op send with account main and exactly the given fields",
              seen[-1] == {"op": "send", "account": "main", "chat": "Work chat", "text": "hi\nthere", "reply_to": None})
        err, text = await call(s, "send_message", {"chat": -1001, "text": "x", "reply_to": 7, "account": "work"})
        check("numeric chat, reply_to and account are passed through", seen[-1] == {"op": "send", "account": "work", "chat": -1001, "text": "x", "reply_to": 7})

        for st, word, extra in (("cancelled", "cancelled", {}), ("timeout", "timeout", {}), ("disabled", "disabled", {"reason": "sending is disabled (owner: hub)"}),
                                ("rejected", "rejected: that chat is not in the send allowlist", {"reason": "that chat is not in the send allowlist"})):
            answer["resp"] = {"ok": False, "status": st, **extra}
            err, text = await call(s, "send_message", {"chat": "x", "text": "y"})
            check(f"{st}: shown as '{word}' and says nothing was sent", word in text and "Nothing was sent" in text)
        answer["resp"] = {"ok": False, "status": "cancelled", "name": "Ann"}
        err, text = await call(s, "send_message", {"chat": "x", "text": "y"})
        check("cancelled tells the agent not to retry on its own", "Do not retry" in text and "Ann" in text)
        answer["resp"] = {"ok": False, "status": "rejected", "reason": "line1\nline2\x1b[31m" + "z" * 600}
        err, text = await call(s, "send_message", {"chat": "x", "text": "y"})
        check("a reason from the broker is one short line", "\n" not in text and len(text) < 420)
        answer["resp"] = {"ok": False, "status": "sent-ish"}
        err, text = await call(s, "send_message", {"chat": "x", "text": "y"})
        check("an unknown status is never reported as sent", text.startswith("rejected") and "sent (id" not in text)

        answer["resp"] = {"ok": True, "enabled": False, "until": 0, "accounts": ["main"], "configured": True}
        err, text = await call(s, "status")
        check("status: OFF is explained and says every message still needs confirmation", "OFF" in text and "confirmation" in text and seen[-1] == {"op": "status"})
        answer["resp"] = {"ok": True, "enabled": True, "until": 4102444800, "accounts": ["main", "work"], "configured": True}
        err, text = await call(s, "status")
        check("status: ON lists the accounts", "ON" in text and "main, work" in text)
        answer["resp"] = {"ok": True, "enabled": False, "until": 0, "accounts": [], "configured": False}
        err, text = await call(s, "status")
        check("status: not configured points to the setup", "not set up" in text)

    async with session(sock=f"{TMP}/missing.sock") as s:
        err, text = await call(s, "send_message", {"chat": "x", "text": "y"})
        check("no broker socket: a clear 'not set up' refusal, no traceback", not err and text.startswith("rejected") and "not set up" in text and "Traceback" not in text)
        err, text = await call(s, "status")
        check("no broker socket: status says not set up", "not set up" in text)

    answer.update(hang=True, resp={})
    async with session(TGSEND_WAIT="0.5") as s:
        err, text = await call(s, "send_message", {"chat": "x", "text": "y"})
        check("a broker that never answers ends as a timeout, not a hang", text.startswith("timeout") and "Nothing was sent" in text)
    srv.close()


asyncio.run(main())
sys.exit(0 if all(results) else 1)
