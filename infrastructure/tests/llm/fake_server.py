#!/usr/bin/python3 -I
"""Fake llama-server for the llm tests: an OpenAI-compatible subset over a UNIX socket (stdlib only).

Used two ways: directly (`fake_server.py --host SOCK [--api-key-file F] [--log F] [--ctl F]`) and as LLM_SERVER_BIN, so `llm _serve`
really execs it with the real llama-server flags (everything it does not know is ignored; `--list-devices` prints a device list).

  GET  /health               200 {"status":"ok"}, no auth (like llama-server)
  GET  /v1/models            200, needs the bearer token
  POST /v1/chat/completions  needs the bearer token (else 401); every body is appended to --log (one JSON per line);
                             stream (SSE) or not, with a llama.cpp-style `timings` block; the answer is `reply` of the control file,
                             "pick" (default "0") when the body carries a grammar, else "fake reply"

Control file (JSON, read on every request; --ctl): {"status": 503, "sleep": 2.5, "close": true, "reply": "text",
"pick": "2", "reasoning": "thinking text", "fence": true}
"""
import json
import os
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler


def parse(argv):
    o = {"host": None, "key": None, "log": None, "ctl": None, "list": False}
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--host":
            o["host"] = argv[i + 1]; i += 1
        elif a == "--api-key-file":
            o["key"] = argv[i + 1]; i += 1
        elif a == "--log":
            o["log"] = argv[i + 1]; i += 1
        elif a == "--ctl":
            o["ctl"] = argv[i + 1]; i += 1
        elif a == "--list-devices":
            o["list"] = True
        i += 1
    return o


OPTS = parse(sys.argv)
OPTS["log"] = OPTS["log"] or os.environ.get("FAKE_LLM_LOG")
OPTS["ctl"] = OPTS["ctl"] or os.environ.get("FAKE_LLM_CTL")


def ctl():
    try:
        return json.load(open(OPTS["ctl"])) if OPTS["ctl"] else {}
    except (OSError, ValueError):
        return {}


def token():
    if not OPTS["key"]:
        return None
    try:
        return open(OPTS["key"]).read().strip()
    except OSError:
        return "\0unreadable-key-file"  # fail closed


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authed(self):
        t = token()
        return t is None or self.headers.get("Authorization") == "Bearer " + t

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"status": "ok"})
        if not self._authed():
            return self._send(401, {"error": {"message": "Invalid API Key", "type": "authentication_error"}})
        if self.path == "/v1/models":
            return self._send(200, {"data": [{"id": "fake"}]})
        self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        if not self._authed():
            return self._send(401, {"error": {"message": "Invalid API Key", "type": "authentication_error"}})
        if self.path != "/v1/chat/completions":
            return self._send(404, {"error": {"message": "not found"}})
        body = json.loads(raw)
        if OPTS["log"]:
            with open(OPTS["log"], "a") as f:
                f.write(json.dumps(body) + "\n")
        c = ctl()
        if c.get("sleep"):
            time.sleep(float(c["sleep"]))
        if c.get("close"):
            self.close_connection = True
            self.connection.shutdown(2)
            return
        if c.get("status"):
            return self._send(int(c["status"]), {"error": {"message": "overloaded", "type": "server_error"}})
        if "grammar" in body:
            text = str(c.get("pick", "0"))
        else:
            text = c.get("reply", "fake reply")
        if c.get("fence"):
            text = "```\n" + text + "\n```"
        timings = {"prompt_n": 12, "prompt_ms": 20.0, "prompt_per_second": 600.0, "predicted_n": max(1, len(text) // 4),
                   "predicted_ms": 40.0, "predicted_per_second": 40.0}
        msg = {"role": "assistant", "content": text}
        if c.get("reasoning"):
            msg["reasoning_content"] = c["reasoning"]
        if not body.get("stream"):
            return self._send(200, {"id": "x", "model": body.get("model"), "choices": [{"index": 0, "message": msg,
                                                                                         "finish_reason": "stop"}],
                                    "timings": timings})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(obj):
            d = ("data: " + (obj if isinstance(obj, str) else json.dumps(obj)) + "\n\n").encode()
            self.wfile.write(b"%x\r\n" % len(d) + d + b"\r\n")
            self.wfile.flush()

        words = text.split(" ")
        for i, w in enumerate(words):
            delta = {"content": w + (" " if i < len(words) - 1 else "")}
            if i == 0 and c.get("reasoning"):
                delta["reasoning_content"] = c["reasoning"]
            chunk({"choices": [{"index": 0, "delta": delta}]})
        chunk({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "timings": timings})
        chunk("[DONE]")
        self.wfile.write(b"0\r\n\r\n")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def get_request(self):
        sock, _ = super().get_request()
        return sock, ("unix", 0)


def main():
    if OPTS["list"]:
        print("Available devices:\n  Vulkan0: AMD Radeon 860M Graphics (RADV KRACKAN1) (10798 MiB, 9400 MiB free)")
        return 0
    path = OPTS["host"]
    if not path or not path.endswith(".sock"):
        print("fake_server: --host must be a .sock path", file=sys.stderr)
        return 2
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    srv = Server(path, H)
    os.chmod(path, 0o600)
    print("fake llama-server listening on", path, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
