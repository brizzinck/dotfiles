"""Tiny HTTP echo for the api tests (G4/G5): every request's method, path and the Authorization / X-Env headers are appended to the
file given as argument 2 (tests compare hashes, nothing is printed); answers 200 {"ok": true}. Port goes to the file of argument 1."""
import http.server
import sys


class H(http.server.BaseHTTPRequestHandler):
    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        with open(sys.argv[2], "a") as f:
            f.write(f"{self.command} {self.path} auth={self.headers.get('Authorization', '')} x-env={self.headers.get('X-Env', '')}\n")
        body = b'{"ok": true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = _go

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
