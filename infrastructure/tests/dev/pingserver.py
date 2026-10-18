"""Tiny ClickHouse-HTTP look-alike for run.sh: GET /ping -> `Ok.`; writes its port to the file given as argument and serves until killed."""
import http.server
import sys


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"Ok.\n" if self.path == "/ping" else b"nope"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
