#!/usr/bin/env python3
"""End to end, offline: the REAL tgconfirm broker (in this process, on a real unix socket) with a FAKE popup (fake_popup.py) and a
FAKE telegram-mcp /x-send server, driven by the REAL clients as subprocesses: the on/off switch (.local/bin/mcp-telegram-send)
and the agents' MCP server (.config/mcp/telegram-send.py, through an MCP client session). Nothing is sent anywhere, no window opens.
Run with the python of the pinned MCP venv: test_send_e2e.py REPO. Prints `ok NAME` / `FAIL NAME`."""
import asyncio
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

repo = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import fake_session as fs  # noqa: E402

spec = importlib.util.spec_from_file_location("broker", os.path.join(repo, "infrastructure/mcp/confirm/broker.py"))
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)
results = []


def check(name, cond):
    results.append(bool(cond))
    print(("ok " if cond else "FAIL ") + name)


TMP = tempfile.mkdtemp(prefix="tgsend-e2e.")
SEND_TOKEN = "S" * 40
os.makedirs(f"{TMP}/cred")
with open(f"{TMP}/cred/send_token", "w") as f:
    f.write(SEND_TOKEN)
os.makedirs(f"{TMP}/wl")
os.makedirs(f"{TMP}/proc")
fs.logind(f"{TMP}/logind", os.getuid())
fs.login_chain(f"{TMP}/proc", os.getuid(), os.getpid())
COMPOSITOR = fs.Server(f"{TMP}/wl/wayland-1")
POPUP_LOG = f"{TMP}/popup.log"
os.makedirs(f"{TMP}/fakebin")
with open(f"{TMP}/fakebin/systemd-run", "w") as f:
    f.write(f'#!/bin/sh\necho "systemd-run $*" >>{TMP}/systemd-run.log\n')
with open(f"{TMP}/fakebin/systemctl", "w") as f:
    f.write(f'#!/bin/sh\necho "systemctl $*" >>{TMP}/systemd-run.log\n')
for n in ("systemd-run", "systemctl"):
    os.chmod(f"{TMP}/fakebin/{n}", 0o755)

# --- fake telegram-mcp ----------------------------------------------------------------------------------------------------
calls = []
ALLOWED = {"Work chat": -1001111, "Ann": 42}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        calls.append({"auth": self.headers.get("Authorization"), "body": body})
        out, code = {"ok": True}, 200
        if body["action"] == "resolve":
            cid = ALLOWED.get(str(body.get("chat")))
            if cid is None:
                out, code = {"error": "that chat is not in the send allowlist"}, 403
            else:
                out.update(chat_id=cid, name=str(body["chat"]), username="", kind="Group", reply_preview="")
        else:
            out.update(message_id=4242, chat_id=body["chat_id"])
        data = json.dumps(out).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = f"http://127.0.0.1:{srv.server_address[1]}"


def popups():
    try:
        return [json.loads(l) for l in open(POPUP_LOG)]
    except OSError:
        return []


def n_sends():
    return len([c for c in calls if c["body"]["action"] == "send"])


def reset(b):
    b.popup_rate = broker.RateLimit(*broker.RATE)
    b.enable_rate = broker.RateLimit(*broker.RATE)
    calls.clear()
    open(POPUP_LOG, "w").close()


async def run(argv, **env):
    e = {"PATH": f"{TMP}/fakebin:" + os.environ["PATH"], "HOME": TMP, "MCP_TGSEND_SOCK": f"{TMP}/run/req.sock", "MCP_TGSEND_STATE": f"{TMP}/run/state.json",
         "MCP_TGSEND_NO_NOTIFY": "1", "MCP_TGSEND_NO_POKE": "1", **env}
    p = await asyncio.create_subprocess_exec(*argv, env=e, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    out, _ = await asyncio.wait_for(p.communicate(), 30)
    return p.returncode, out.decode()


SWITCH = [sys.executable, os.path.join(repo, ".local/bin/mcp-telegram-send")]


async def main():
    env = {"TGCONFIRM_OWNER_UID": str(os.getuid()), "TGCONFIRM_RUNTIME": f"{TMP}/run", "TGCONFIRM_LIB": f"{TMP}/lib", "CREDENTIALS_DIRECTORY": f"{TMP}/cred",
           "TGCONFIRM_ACCOUNTS": "main=8765", "TGCONFIRM_URL": URL, "TGCONFIRM_WAYLAND_DIR": f"{TMP}/wl", "TGCONFIRM_PROC": f"{TMP}/proc", "TGCONFIRM_LOGIND": f"{TMP}/logind",
           "TGCONFIRM_NO_LOCK_CHECK": "1",
           "TGCONFIRM_POPUP_CMD": f"{sys.executable} {here}/fake_popup.py --req {{req}}", "TGCONFIRM_FAKE": "confirm", "TGCONFIRM_FAKE_LOG": POPUP_LOG,
           "TGCONFIRM_HOME": f"{TMP}/home"}

    # --- the switch without a broker ---
    rc, out = await run(SWITCH + ["status"])
    check("switch: no broker = 'not set up', exit 1", rc == 1 and "not set up" in out)
    rc, out = await run(SWITCH + ["on"])
    check("switch: on without a broker explains the setup and fails", rc == 1 and "not running" in out and "Traceback" not in out)
    rc, out = await run(SWITCH + ["off"])
    check("switch: off without a broker is harmless (sending is off anyway)", rc == 0)
    rc, out = await run(SWITCH + ["bogus"])
    check("switch: an unknown action is a usage error", rc == 2)
    rc, out = await run(SWITCH + ["on", "--ttl", "x"])
    check("switch: a bad --ttl is refused", rc == 2)

    b = broker.Broker(env)
    server_task = asyncio.create_task(b.serve())
    await asyncio.sleep(0.4)

    rc, out = await run(SWITCH + ["status"])
    check("switch: status OFF (exit 1) at the start", rc == 1 and out.startswith("OFF"))

    # enabling needs the owner's popup
    reset(b)
    b.env["TGCONFIRM_FAKE"] = "cancel"
    rc, out = await run(SWITCH + ["on"])
    check("enable: a cancelled popup leaves sending OFF and the switch fails", rc == 1 and "still OFF" in out and not b.enabled())
    check("enable: the popup was shown (kind enable) - the switch cannot enable anything by itself", [p["req"]["kind"] for p in popups()] == ["enable"])
    reset(b)
    b.env["TGCONFIRM_FAKE"] = "none"
    rc, out = await run(SWITCH + ["on"])
    check("enable: a popup closed without an answer leaves sending OFF", rc == 1 and not b.enabled())
    reset(b)
    b.env["TGCONFIRM_FAKE"] = "confirm"
    open(f"{TMP}/systemd-run.log", "w").close()
    rc, out = await run(SWITCH + ["on"])
    check("enable: a confirmed popup turns it ON for 60 minutes", rc == 0 and "ON (60 min" in out and b.enabled() and 3540 < b.until - time.time() <= 3600)
    check("enable: the popup said 60 minutes and that every message still asks again", "60 minutes" in popups()[0]["req"]["text"] and "again" in popups()[0]["req"]["text"])
    rc, out = await run(SWITCH + ["status"])
    check("switch: status ON (exit 0) with the minutes left", rc == 0 and out.startswith("ON (") and "min left" in out)
    log = open(f"{TMP}/systemd-run.log").read()
    check("enable: an expiry timer is scheduled (systemd-run --user --on-active=60m ... expired)", "--on-active=60m" in log and "--unit=mcp-telegram-send-off" in log and log.strip().endswith("expired"))
    rc, out = await run(SWITCH + ["off"])
    check("off: needs no popup, sending is OFF again", rc == 0 and not b.enabled() and len(popups()) == 1 and "systemctl --user stop mcp-telegram-send-off.timer" in open(f"{TMP}/systemd-run.log").read())
    rc, out = await run(SWITCH + ["status"])
    check("switch: status OFF after off", rc == 1)
    reset(b)
    rc, out = await run(SWITCH + ["toggle"])
    check("toggle: OFF -> ON goes through the popup", rc == 0 and b.enabled() and len(popups()) == 1)
    rc, out = await run(SWITCH + ["toggle"])
    check("toggle: ON -> OFF with no popup", rc == 0 and not b.enabled() and len(popups()) == 1)
    reset(b)
    rc, out = await run(SWITCH + ["on", "--ttl", "5"])
    check("--ttl 5: the popup and the broker use 5 minutes", rc == 0 and "5 minutes" in popups()[0]["req"]["text"] and b.until - time.time() <= 300)
    rc, out = await run(SWITCH + ["expired"], MCP_TGSEND_NO_TIMER="1")
    check("expired (the timer's job): sending is switched off", rc == 0 and not b.enabled())

    # --- the agents' path: MCP client -> telegram-send.py -> broker -> fake popup -> fake /x-send ---
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    @contextlib.asynccontextmanager
    async def agent():
        params = StdioServerParameters(command=sys.executable, args=[os.path.join(repo, ".config/mcp/telegram-send.py")],
                                       env={"PATH": os.environ["PATH"], "TGSEND_SOCK": f"{TMP}/run/req.sock", "TGSEND_WAIT": "20", "TGSEND_NO_NOTIFY": "1"})
        async with stdio_client(params, errlog=open(os.devnull, "w")) as (r, w):
            async with ClientSession(r, w) as s:
                await s.initialize()
                yield s

    async def send(s, **args):
        res = await s.call_tool("send_message", {"chat": "Work chat", "text": "Hello from the agent\nsecond line", **args})
        return "\n".join(c.text for c in res.content if hasattr(c, "text"))

    async with agent() as s:
        reset(b)
        b.until = 0.0
        b.env["TGCONFIRM_FAKE"] = "confirm"
        t0 = time.time()
        text = await send(s)
        check("agent, sending OFF: an immediate 'disabled', no popup, nothing sent", text.startswith("disabled") and not popups() and not calls and time.time() - t0 < 5)
        b.until = time.time() + 3600
        b.env["TGCONFIRM_FAKE"] = "cancel"
        text = await send(s)
        check("agent: the owner cancels (wrong key / Esc) -> 'cancelled', nothing sent", text.startswith("cancelled") and n_sends() == 0 and len(popups()) == 1)
        check("agent: the popup got the resolved recipient and the FULL text", popups()[0]["req"]["name"] == "Work chat" and popups()[0]["req"]["text"] == "Hello from the agent\nsecond line")
        b.env["TGCONFIRM_FAKE"] = "confirm"
        reset(b)
        text = await send(s)
        check("agent: confirmed -> 'sent (id 4242)', exactly one send with exactly that text", text.startswith("sent (id 4242)") and n_sends() == 1
              and [c for c in calls if c["body"]["action"] == "send"][0]["body"]["text"] == "Hello from the agent\nsecond line")
        check("agent: the send used the broker's token, never anything from the agent side", all(c["auth"] == f"Bearer {SEND_TOKEN}" for c in calls))
        reset(b)
        text = await send(s, chat="Secret person")
        check("agent: a chat outside the send allowlist is rejected by the server, no popup", text.startswith("rejected") and "allowlist" in text and not popups() and n_sends() == 0)
        b.env["TGCONFIRM_FAKE"] = "hang"
        reset(b)
        old = (broker.POPUP_TIMEOUT, broker.EXEC_GRACE)
        broker.POPUP_TIMEOUT, broker.EXEC_GRACE = 0.5, 0.5
        t0 = time.time()
        text = await send(s)
        broker.POPUP_TIMEOUT, broker.EXEC_GRACE = old
        check("agent: nobody answers the popup -> 'timeout', nothing sent", text.startswith("timeout") and n_sends() == 0 and time.time() - t0 < 8)
        b.env["TGCONFIRM_FAKE"] = "cancel"
        reset(b)
        outs = [await send(s) for _ in range(6)]
        check("agent: the 6th popup within 10 minutes is a rate-limit rejection", [o.split(":")[0] for o in outs] == ["cancelled"] * 5 + ["rejected"] and "rate limit" in outs[5] and len(popups()) == 5)
        b.until = 0.0
        res = await s.call_tool("status", {})
        check("agent: status works and says OFF", "OFF" in res.content[0].text)

    server_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await server_task


# audit: the journal line (stderr of the broker) has the hash and never the text. The broker logs to stderr of this process.
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    asyncio.run(main())
err = buf.getvalue()
h = hashlib.sha256(b"Hello from the agent\nsecond line").hexdigest()[:16]
line = [l for l in err.splitlines() if "result=sent" in l]
check("audit: the journal line of the confirmed send has the sha256 prefix and the length", line and f"sha256={h}" in line[0] and "len=32" in line[0])
check("audit: neither the text nor the token is ever logged", "Hello from the agent" not in err and "second line" not in err and SEND_TOKEN not in err)
sys.exit(0 if all(results) else 1)
