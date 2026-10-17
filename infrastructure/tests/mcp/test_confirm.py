#!/usr/bin/env python3
"""Tests of infrastructure/mcp/confirm/broker.py (the tgconfirm broker) over its real unix socket, with a fake popup
(fake_popup.py) and a fake telegram-mcp /x-send server. Nothing is sent anywhere and no window opens. Prints `ok NAME` / `FAIL NAME`.
Usage: test_confirm.py REPO"""
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


TMP = tempfile.mkdtemp(prefix="tgconfirm-test.")
SEND_TOKEN = "T" * 40
os.makedirs(f"{TMP}/cred")
with open(f"{TMP}/cred/send_token", "w") as f:
    f.write(SEND_TOKEN + "\n")
# a fake desktop: this process is the "compositor" (it listens on wayland-1), /proc and logind are fake trees describing the login chain
os.makedirs(f"{TMP}/wl")
os.makedirs(f"{TMP}/proc")
fs.logind(f"{TMP}/logind", os.getuid())
fs.login_chain(f"{TMP}/proc", os.getuid(), os.getpid())
COMPOSITOR = fs.Server(f"{TMP}/wl/wayland-1")
POPUP_LOG = f"{TMP}/popup.log"

# --- fake telegram-mcp: records every /x-send call -------------------------------------------------------------------------
calls = []
xmode = {"resolve": "ok", "send": "ok"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        calls.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        out, code = {"ok": True}, 200
        if body["action"] == "resolve":
            if xmode["resolve"] == "denied":
                out, code = {"error": "that chat is not in the send allowlist"}, 403
            else:
                out.update(chat_id=-1001111, name="Work chat", username="work", kind="Supergroup", reply_preview="old msg" if body.get("reply_to") else "")
        else:
            if xmode["send"] == "fail":
                out, code = {"error": "Telegram refused the message (FloodWaitError)"}, 502
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


def make_env(**extra):
    env = {"TGCONFIRM_OWNER_UID": str(os.getuid()), "TGCONFIRM_RUNTIME": f"{TMP}/run", "TGCONFIRM_LIB": f"{TMP}/lib",
           "CREDENTIALS_DIRECTORY": f"{TMP}/cred", "TGCONFIRM_ACCOUNTS": "main=8765,work=8766", "TGCONFIRM_URL": URL,
           "TGCONFIRM_WAYLAND_DIR": f"{TMP}/wl", "TGCONFIRM_PROC": f"{TMP}/proc", "TGCONFIRM_LOGIND": f"{TMP}/logind", "TGCONFIRM_NO_LOCK_CHECK": "1",
           "TGCONFIRM_POPUP_CMD": f"{sys.executable} {here}/fake_popup.py --req {{req}}", "TGCONFIRM_FAKE": "confirm",
           "TGCONFIRM_FAKE_LOG": POPUP_LOG, "TGCONFIRM_HOME": f"{TMP}/home"}
    env.update(extra)
    return env


async def ask(b, msg):
    r, w = await asyncio.open_unix_connection(f"{b.runtime}/req.sock")
    w.write(json.dumps(msg).encode() + b"\n")
    await w.drain()
    line = await asyncio.wait_for(r.readline(), 30)
    w.close()
    return json.loads(line)


def popups():
    try:
        return [json.loads(l) for l in open(POPUP_LOG)]
    except OSError:
        return []


def n_sends():
    return len([c for c in calls if c["body"]["action"] == "send"])


def reset():
    if CURRENT:
        CURRENT[0].popup_rate = broker.RateLimit(*broker.RATE)
        CURRENT[0].request_rate = broker.RateLimit(*broker.REQUEST_RATE)
        CURRENT[0].enable_rate = broker.RateLimit(*broker.RATE)
    calls.clear()
    open(POPUP_LOG, "w").close()
    xmode.update(resolve="ok", send="ok")


CURRENT = []
SEND = {"op": "send", "account": "main", "chat": "Work chat", "text": "Hello from the agent\nsecond line"}


async def main():
    b = broker.Broker(make_env())
    CURRENT.append(b)
    server_task = asyncio.create_task(b.serve())
    await asyncio.sleep(0.3)
    check("the broker starts with a send token", b.token == SEND_TOKEN)
    check("the socket exists, mode 0666 (the peer uid is what is checked)", oct(os.stat(f"{b.runtime}/req.sock").st_mode & 0o777) == "0o666")
    st = json.load(open(f"{b.runtime}/state.json"))
    check("state.json: disabled at start, no secret in it, world readable",
          st["enabled"] is False and st["until"] == 0 and SEND_TOKEN not in open(f"{b.runtime}/state.json").read()
          and oct(os.stat(f"{b.runtime}/state.json").st_mode & 0o777) == "0o644")

    # --- disabled = stub, nothing happens ---
    reset()
    r = await ask(b, SEND)
    check("disabled: the answer is 'disabled' with the way to enable it", r["status"] == "disabled" and "Telegram" in r["reason"])
    check("disabled: no popup and no call to telegram-mcp", not popups() and not calls)
    r = await ask(b, {"op": "status"})
    check("status: disabled, accounts listed", r["enabled"] is False and r["accounts"] == ["main", "work"] and r["configured"])

    # --- enabling needs a popup ---
    reset()
    b.env["TGCONFIRM_FAKE"] = "cancel"
    r = await ask(b, {"op": "enable", "minutes": 60})
    check("enable: a cancelled popup leaves sending off", r["status"] == "cancelled" and not b.enabled() and len(popups()) == 1)
    check("enable: the popup says what is being enabled", popups()[0]["req"]["kind"] == "enable" and "60 minutes" in popups()[0]["req"]["text"])
    b.env["TGCONFIRM_FAKE"] = "none"
    r = await ask(b, {"op": "enable"})
    check("enable: a closed popup window (no answer) is a cancel", r["status"] == "cancelled" and not b.enabled())
    b.env["TGCONFIRM_FAKE"] = "stale"
    r = await ask(b, {"op": "enable"})
    check("enable: an answer with the wrong nonce is a cancel", r["status"] == "cancelled" and not b.enabled())
    b.env["TGCONFIRM_FAKE"] = "confirm"
    t0 = time.time()
    r = await ask(b, {"op": "enable", "minutes": 60})
    st = json.load(open(f"{b.runtime}/state.json"))
    check("enable: a confirmed popup enables for 60 minutes and writes state.json", r["status"] == "enabled" and b.enabled() and 3590 < st["until"] - t0 < 3610 and st["enabled"])
    r = await ask(b, {"op": "disable"})
    r = await ask(b, {"op": "enable", "minutes": 100000})
    check("enable: an agent cannot raise the limit (minutes capped at 120)", r["status"] == "enabled" and b.until - time.time() <= 120 * 60 + 5)

    # --- send: the popup shows everything, nothing is sent before the confirmation ---
    reset()
    b.env["TGCONFIRM_FAKE"] = "cancel"
    r = await ask(b, SEND)
    check("send: cancelled in the popup = nothing sent", r["status"] == "cancelled" and n_sends() == 0 and len(calls) == 1 and calls[0]["body"]["action"] == "resolve")
    pop = popups()[0]
    check("send: the popup got the account, the resolved recipient, the chat id and the FULL text",
          pop["req"]["account"] == "main" and pop["req"]["name"] == "Work chat" and pop["req"]["chat_id"] == -1001111
          and pop["req"]["username"] == "work" and pop["req"]["text"] == SEND["text"] and pop["req"]["kind"] == "send")
    check("send: the broker never puts a code in the request (the popup draws it itself)", "code" not in json.dumps(pop["req"]).lower().replace("chat_id", ""))
    check("send: the request file is 0600 and the popup env is minimal and private",
          pop["req_mode"] == "0o600" and pop["env"]["WAYLAND_DISPLAY"] is None and pop["env"]["WAYLAND_SOCKET"] and pop["wl_fd"] == "socket" and pop["env"]["XDG_RUNTIME_DIR"] == f"{b.runtime}/rt"
          and pop["env"]["DBUS_SESSION_BUS_ADDRESS"] is None and pop["env"]["HOME"] == f"{TMP}/home")
    check("send: the request and result files are removed afterwards", not [f for f in os.listdir(f"{b.runtime}/rt")])
    check("send: resolve used the send token (not an MCP token) and the account's route", calls[0]["auth"] == f"Bearer {SEND_TOKEN}" and calls[0]["path"] == "/x-send")

    reset()
    for mode, want in (("none", "cancelled"), ("stale", "cancelled"), ("timeout", "timeout")):
        b.env["TGCONFIRM_FAKE"] = mode
        r = await ask(b, SEND)
        check(f"send: popup result '{mode}' sends nothing", r["status"] == want and n_sends() == 0)

    reset()
    b.env["TGCONFIRM_FAKE"] = "confirm"
    with contextlib.redirect_stderr(io.StringIO()) as err:
        r = await ask(b, {**SEND, "reply_to": 7})
    check("send: a confirmed popup sends exactly the text it showed, once", r["status"] == "sent" and r["message_id"] == 4242 and n_sends() == 1
          and [c for c in calls if c["body"]["action"] == "send"][0]["body"]["text"] == SEND["text"])
    sendcall = [c for c in calls if c["body"]["action"] == "send"][0]["body"]
    check("send: the send call carries the numeric chat id from resolve, the reply id and a fresh request_id",
          sendcall["chat_id"] == -1001111 and sendcall["reply_to"] == 7 and len(sendcall["request_id"]) >= 16 and sendcall["account"] == "main")
    check("send: the popup of a reply shows the replied-to message", popups()[0]["req"]["reply_preview"] == "old msg")
    line = [l for l in err.getvalue().splitlines() if "result=sent" in l]
    h = hashlib.sha256(SEND["text"].encode()).hexdigest()[:16]
    check("audit: the journal line has account, chat id, length and the sha256 prefix", line and f"len={len(SEND['text'])} sha256={h}" in line[0] and "account=main" in line[0])
    check("audit: the text and the token never reach the log", "Hello from the agent" not in err.getvalue() and SEND_TOKEN not in err.getvalue())

    # --- refusals before any popup ---
    reset()
    xmode["resolve"] = "denied"
    r = await ask(b, SEND)
    check("send: a chat outside the server's send allowlist is rejected, with no popup", r["status"] == "rejected" and "allowlist" in r["reason"] and not popups())
    xmode["resolve"] = "ok"
    for bad, name in (({**SEND, "text": "  "}, "empty text"), ({**SEND, "text": "x" * 4097}, "text over 4096"), ({**SEND, "account": "nope"}, "unknown account"),
                      ({**SEND, "chat": ""}, "empty chat"), ({**SEND, "chat": ["a"]}, "chat that is a list"), ({**SEND, "reply_to": "x"}, "reply_to that is not an id")):
        reset()
        r = await ask(b, bad)
        check(f"send: {name} is rejected, no popup, no Telegram call", r["status"] == "rejected" and not popups() and not calls)
    r = await ask(b, {"op": "frobnicate"})
    check("an unknown op is rejected", r["status"] == "rejected")

    # --- telegram-mcp failures ---
    reset()
    xmode["send"] = "fail"
    r = await ask(b, SEND)
    check("send: a Telegram failure after a confirmed popup is reported, not hidden", r["status"] == "rejected" and "refused" in r["reason"])
    reset()
    b.env["TGCONFIRM_URL"] = "http://127.0.0.1:1"
    r = await ask(b, SEND)
    check("send: telegram-mcp down = rejected with a reason, no popup", r["status"] == "rejected" and "not reachable" in r["reason"] and not popups())
    b.env["TGCONFIRM_URL"] = URL

    # --- screen locked / no desktop ---
    reset()
    b.screen_locked = lambda: True
    r = await ask(b, SEND)
    check("send: a locked screen = rejected (no popup can be shown over hyprlock)", r["status"] == "rejected" and "locked" in r["reason"] and n_sends() == 0)
    b.screen_locked = lambda: False
    b.env["TGCONFIRM_WAYLAND_DIR"] = f"{TMP}/nonexistent"
    r = await ask(b, SEND)
    check("send: no reachable Wayland socket = rejected, nothing sent", r["status"] == "rejected" and "desktop" in r["reason"] and n_sends() == 0)
    b.env["TGCONFIRM_WAYLAND_DIR"] = f"{TMP}/wl"

    # --- timeout kills the popup process ---
    reset()
    old = (broker.POPUP_TIMEOUT, broker.EXEC_GRACE)
    broker.POPUP_TIMEOUT, broker.EXEC_GRACE = 0.5, 0.5
    b.env["TGCONFIRM_FAKE"] = "hang"
    t0 = time.time()
    r = await ask(b, SEND)
    broker.POPUP_TIMEOUT, broker.EXEC_GRACE = old
    check("timeout: a popup that never answers ends as 'timeout' and sends nothing", r["status"] == "timeout" and n_sends() == 0 and time.time() - t0 < 5)
    await asyncio.sleep(0.3)
    check("timeout: the hung popup process is gone and its files removed", not os.listdir(f"{b.runtime}/rt"))

    # --- one popup at a time ---
    reset()
    b.env["TGCONFIRM_FAKE"] = "confirm"
    b.env["TGCONFIRM_FAKE_DELAY"] = "0.6"
    t0 = time.time()
    r1, r2 = await asyncio.gather(ask(b, SEND), ask(b, {**SEND, "text": "second"}))
    check("two simultaneous requests get one popup at a time (serialised)", r1["status"] == "sent" and r2["status"] == "sent" and time.time() - t0 > 1.1 and n_sends() == 2)
    b.env["TGCONFIRM_FAKE_DELAY"] = "0"

    # --- rate limit: 5 popups per 10 minutes ---
    reset()
    b.popup_rate = broker.RateLimit(*broker.RATE)
    b.env["TGCONFIRM_FAKE"] = "cancel"
    out = [(await ask(b, SEND))["status"] for _ in range(7)]
    check("rate limit: the 6th popup within 10 minutes is rejected, and no 6th popup opens", out == ["cancelled"] * 5 + ["rejected"] * 2 and len(popups()) == 5)
    r = await ask(b, SEND)
    check("rate limit: the reason names the limit", "rate limit" in r["reason"])


    # --- the client hangs up: the popup is closed and nothing is sent ---
    def alive(pid):
        try:
            os.kill(pid, 0)
            with open(f"/proc/{pid}/stat") as f:
                return f.read().split(") ")[-1].split()[0] != "Z"
        except OSError:
            return False

    async def hang_up_after_popup(b, msg):
        r, w = await asyncio.open_unix_connection(f"{b.runtime}/req.sock")
        w.write(json.dumps(msg).encode() + b"\n")
        await w.drain()
        for _ in range(60):
            if popups():
                break
            await asyncio.sleep(0.1)
        pid = popups()[0]["pid"] if popups() else None
        w.close()
        return pid

    reset()
    b.env["TGCONFIRM_FAKE"] = "hang"
    pid = await hang_up_after_popup(b, SEND)
    await asyncio.sleep(1.0)
    check("hang-up: a send request whose client left while the popup was open closes the popup and sends nothing",
          pid is not None and not alive(pid) and n_sends() == 0 and not os.listdir(f"{b.runtime}/rt"))
    b.env["TGCONFIRM_FAKE"] = "confirm"
    r = await ask(b, SEND)
    check("hang-up: the popup lock is free again afterwards (the next request works)", r["status"] == "sent")

    reset()
    b.env["TGCONFIRM_FAKE"] = "hang"
    b.until = 0.0
    pid = await hang_up_after_popup(b, {"op": "enable", "minutes": 60})
    await asyncio.sleep(1.0)
    check("hang-up: an enable request whose client left closes its popup and does not enable", pid is not None and not alive(pid) and not b.enabled())
    b.until = time.time() + 600

    # --- bounded waits ---
    reset()
    b.env["TGCONFIRM_FAKE"] = "hang"
    old_lock = broker.LOCK_WAIT
    broker.LOCK_WAIT = 0.4
    first = asyncio.create_task(ask(b, SEND))            # holds the lock inside a popup that never answers
    for _ in range(60):
        if popups():
            break
        await asyncio.sleep(0.1)
    t0 = time.time()
    r = await ask(b, {"op": "send", "account": "main", "chat": "Work chat", "text": "second"})
    check("lock wait: a second send request gives up after LOCK_WAIT instead of waiting for ever", r["status"] == "rejected" and "another confirmation popup" in r["reason"] and time.time() - t0 < 3)
    b.until = time.time() + 600
    t0 = time.time()
    b.until = 0.0
    r = await ask(b, {"op": "enable", "minutes": 5})
    check("lock wait: an enable request is bounded the same way (it used to wait without limit)", r["status"] == "rejected" and "another confirmation popup" in r["reason"] and time.time() - t0 < 3)
    broker.LOCK_WAIT = old_lock
    b.until = time.time() + 600
    first.cancel()
    await asyncio.gather(first, return_exceptions=True)
    await asyncio.sleep(1.0)
    for line in popups():       # clean up the hanging popup of the first request
        try:
            os.kill(line["pid"], 9)
        except OSError:
            pass

    reset()
    b.env["TGCONFIRM_FAKE"] = "hang"
    old_budget = broker.REQUEST_BUDGET
    broker.REQUEST_BUDGET = 0.6
    t0 = time.time()
    r = await ask(b, SEND)
    broker.REQUEST_BUDGET = old_budget
    check("budget: a request that outlives REQUEST_BUDGET ends as 'outcome unknown', its popup is closed", r["status"] == "timeout" and "outcome unknown" in r["reason"] and time.time() - t0 < 4 and n_sends() == 0)
    await asyncio.sleep(0.5)
    pid = popups()[0]["pid"]
    check("budget: ... and the popup process of that request is gone", not alive(pid))
    b.env["TGCONFIRM_FAKE"] = "confirm"

    # --- request rate limit (every request, not only popups) ---
    reset()
    b.request_rate = broker.RateLimit(3, 600)
    b.env["TGCONFIRM_FAKE"] = "cancel"
    out = [(await ask(b, SEND))["status"] for _ in range(5)]
    n_resolve = len([c for c in calls if c["body"]["action"] == "resolve"])
    check("request rate: the 4th send request in the window is rejected before any resolve call", out == ["cancelled"] * 3 + ["rejected"] * 2 and n_resolve == 3)
    r = await ask(b, SEND)
    check("request rate: the reason says too many requests", "too many send requests" in r["reason"])
    reset()
    xmode["resolve"] = "denied"
    b.request_rate = broker.RateLimit(3, 600)
    out = [(await ask(b, SEND))["reason"] for _ in range(5)]
    check("request rate: requests for chats that do not resolve count too (no free probing)", sum("too many" in x for x in out) == 2 and len([c for c in calls]) == 3)
    xmode["resolve"] = "ok"
    b.env["TGCONFIRM_FAKE"] = "confirm"

    # --- the budget is a real ordering: parts < budget < what the clients wait ---
    parts = broker.LOCK_WAIT + broker.RESOLVE_WAIT + broker.POPUP_TIMEOUT + broker.EXEC_GRACE + broker.SEND_WAIT
    import re
    cl_wait = float(re.search(r'"TGSEND_WAIT", "([0-9.]+)"', open(os.path.join(repo, ".config/mcp/telegram-send.py")).read()).group(1))
    sw = float(re.search(r"^WAIT = ([0-9.]+)", open(os.path.join(repo, ".local/bin/mcp-telegram-send")).read(), re.M).group(1))
    gw = float(json.load(open(os.path.join(repo, ".config/mcp/gateway.json")))["mcpServers"]["telegram-send"]["timeout"].rstrip("s"))
    check("timeouts: all steps together < REQUEST_BUDGET < the telegram-send wait < the gateway timeout", parts < broker.REQUEST_BUDGET < cl_wait < gw)
    check("timeouts: the owner's enable switch waits longer than the broker's budget", sw > broker.REQUEST_BUDGET)
    check("timeouts: REPLY_WAIT (unused) is gone", not hasattr(broker, "REPLY_WAIT"))

    # --- expiry and disable ---
    reset()
    b.env["TGCONFIRM_FAKE"] = "confirm"
    b.popup_rate = broker.RateLimit(*broker.RATE)
    real = b.clock
    b.until = real() + 3600
    b.clock = lambda: real() + 3601
    check("expiry: after the 60 minutes sending is off again", not b.enabled())
    r = await ask(b, SEND)
    check("expiry: an expired switch answers 'disabled', no popup", r["status"] == "disabled" and not popups())
    b.clock = real
    b.until = real() + 600
    r = await ask(b, {"op": "disable"})
    check("disable: no popup needed to turn it off", r["status"] == "disabled" and not b.enabled() and json.load(open(f"{b.runtime}/state.json"))["enabled"] is False)

    # --- who may ask ---
    server_task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await server_task
    other = broker.Broker(make_env(TGCONFIRM_OWNER_UID=str(os.getuid() + 12345), TGCONFIRM_RUNTIME=f"{TMP}/run2"))
    t2 = asyncio.create_task(other.serve())
    await asyncio.sleep(0.3)
    r = await ask(other, {"op": "status"})
    check("peer check: a uid other than the owner's is refused", r["ok"] is False and "not allowed" in r["reason"])
    t2.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await t2

    # --- no token: nothing can be sent or enabled ---
    notok = broker.Broker(make_env(CREDENTIALS_DIRECTORY=f"{TMP}/nocred", TGCONFIRM_RUNTIME=f"{TMP}/run3"))
    t3 = asyncio.create_task(notok.serve())
    await asyncio.sleep(0.3)
    r = await ask(notok, {"op": "enable"})
    check("no send token: enabling is refused with the setup command", r["status"] == "rejected" and "send-chats" in r["reason"] and not notok.enabled())
    t3.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await t3


asyncio.run(main())

# --- the real popup command line (never executed here) ---------------------------------------------------------------------
rb = broker.Broker({"TGCONFIRM_OWNER_UID": "1000", "TGCONFIRM_RUNTIME": f"{TMP}/rr", "TGCONFIRM_LIB": "/usr/local/lib/tgconfirm"})
argv = rb.popup_argv("/run/tgconfirm/rt/x.req")
check("popup command: ghostty with the class the window rule matches, no user config, one process, popup.py inside",
      "--class=float.confirm" in argv and "--config-default-files=false" in argv and "--gtk-single-instance=false" in argv
      and argv[-4:] == ["/usr/bin/python3", "/usr/local/lib/tgconfirm/popup.py", "--req", "/run/tgconfirm/rt/x.req"] and "-e" in argv)
check("popup command: wrapped in dbus-run-session (GTK needs a bus for the application id, which is the window class)", argv[:2] == ["/usr/bin/dbus-run-session", "--"])
env = rb.popup_env(7)
check("popup env: the verified connection as WAYLAND_SOCKET (no WAYLAND_DISPLAY path), its own runtime dir, software GL, no session bus, nothing inherited",
      env["WAYLAND_SOCKET"] == "7" and "WAYLAND_DISPLAY" not in env and env["XDG_RUNTIME_DIR"] == f"{TMP}/rr/rt" and env["LIBGL_ALWAYS_SOFTWARE"] == "1"
      and "DBUS_SESSION_BUS_ADDRESS" not in env and "SUDO_USER" not in env and len(env) < 20)
check("broker source: the send token is never put in an environment variable, argv or the popup request",
      "send_token" in open(os.path.join(repo, "infrastructure/mcp/confirm/broker.py")).read() and "TELEGRAM_SEND_TOKEN" not in open(os.path.join(repo, "infrastructure/mcp/confirm/broker.py")).read())
sys.exit(0 if all(results) else 1)
