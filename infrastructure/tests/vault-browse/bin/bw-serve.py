#!/usr/bin/env python3
"""fake `bw serve --hostname unix://PATH`: the REST shapes of the real server (checked against bw 2026.10.0: {success, data},
400 + message on errors, Host must be localhost:8087, an Origin header is refused) over the same state files as the fake `bw`
(vault.json, bw-unlocked, session key SESSION-KEY-abc in BW_SESSION). Every request is logged as `bw-serve METHOD PATH?QUERY`
(never the body) in $FAKE_DIR/argv.log; FAKE_BW_REQ_DELAY (seconds, default 0.02) is the time one request takes."""
import base64
import json
import os
import socketserver
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler

FAKE = os.environ["FAKE_DIR"]
KEY = "SESSION-KEY-abc"
DELAY = float(os.environ.get("FAKE_BW_REQ_DELAY", "0.02"))
START_KEY = os.environ.get("BW_SESSION", "")


def vault():
    with open(f"{FAKE}/vault.json") as f:
        return json.load(f)


def save(v):
    with open(f"{FAKE}/vault.json.tmp", "w") as f:
        json.dump(v, f)
    os.replace(f"{FAKE}/vault.json.tmp", f"{FAKE}/vault.json")


def unlocked():
    return os.path.exists(f"{FAKE}/bw-unlocked") and START_KEY == KEY


def next_id(prefix):
    try:
        n = int(open(f"{FAKE}/seq").read())
    except (OSError, ValueError):
        n = 0
    n += 1
    open(f"{FAKE}/seq", "w").write(str(n))
    return f"{prefix}-{n}"


TEMPLATES = {
    "item": {"organizationId": None, "collectionIds": None, "folderId": None, "type": 1, "name": "Item name",
             "notes": "Some notes about this item.", "favorite": False, "fields": [], "login": None, "secureNote": None,
             "card": None, "identity": None, "reprompt": 0},
    "item.login": {"uris": [], "username": "jdoe", "password": "myp@ssword123", "totp": None},
    "item.card": {"cardholderName": "John Doe", "brand": "visa", "number": "", "expMonth": "", "expYear": "", "code": ""},
    "item.identity": {"title": "Mr", "firstName": "John", "middleName": "William", "lastName": "Doe", "address1": "",
                      "city": "", "state": "", "postalCode": "", "country": "", "company": "", "email": "", "phone": "",
                      "ssn": "", "username": "", "passportNumber": "", "licenseNumber": ""},
    "item.securenote": {"type": 0},
}


def disposition_filename(head):
    """The file name the way busboy (multer, behind the real bw serve) reads it: `filename*` (RFC 5987, charset''pct) wins,
    else the plain parameter, a quoted string with backslash escapes, decoded as latin1 (busboy's defParamCharset)."""
    line = next((l for l in head.split(b"\r\n") if l.lower().startswith(b"content-disposition:")), b"")
    params, i, n = {}, line.find(b";"), len(line)
    while 0 <= i < n:
        i += 1
        while i < n and line[i:i + 1] in (b" ", b";"):
            i += 1
        j = line.find(b"=", i)
        if j < 0:
            break
        key = line[i:j].strip().lower().decode("latin1")
        i = j + 1
        val = bytearray()
        if line[i:i + 1] == b'"':
            i += 1
            while i < n and line[i:i + 1] != b'"':
                if line[i:i + 1] == b"\\" and i + 1 < n:
                    i += 1
                val += line[i:i + 1]
                i += 1
            i += 1
        else:
            k = line.find(b";", i)
            k = n if k < 0 else k
            val += line[i:k].strip()
            i = k
        params[key] = bytes(val)
    if "filename*" in params:
        charset, _, rest = params["filename*"].partition(b"'")
        _lang, _, enc = rest.partition(b"'")
        return urllib.parse.unquote_to_bytes(enc.decode("ascii")).decode(charset.decode() or "utf-8", "replace")
    return params.get("filename", b"").decode("latin1")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, doc=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else json.dumps(doc).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def ok(self, data=None):
        self.send(200, {"success": True, **({"data": data} if data is not None else {})})

    def fail(self, msg):
        self.send(400, {"success": False, "message": msg})

    def handle_any(self, method):
        with open(f"{FAKE}/argv.log", "a") as f:
            f.write(f"bw-serve {method} {self.path}\n")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        time.sleep(DELAY)
        if self.headers.get("Host", "").lower() not in ("localhost:8087", "127.0.0.1:8087"):
            return self.send(403, {"success": False, "message": "bad host"})
        if self.headers.get("Origin") is not None:
            return self.send(403, {"success": False, "message": "origin"})
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        parts = [x for x in u.path.split("/") if x]
        if parts == ["status"] and method == "GET":
            return self.ok({"object": "template", "template": {"serverUrl": None, "lastSync": None, "userEmail": "t@example.invalid",
                                                              "userId": "u1", "status": "unlocked" if unlocked() else "locked"}})
        if not unlocked():
            return self.fail("Vault is locked.")
        v = vault()
        if parts == ["sync"] and method == "POST":
            return self.ok({"object": "message", "title": None, "message": "Syncing complete."})
        if parts == ["lock"] and method == "POST":
            try:
                os.unlink(f"{FAKE}/bw-unlocked")
            except OSError:
                pass
            return self.ok({"object": "message", "title": "Your vault is locked.", "message": None})
        if parts[:2] == ["list", "object"] and method == "GET":
            if parts[2] == "items":
                trash = q.get("trash") == "true"
                items = [i for i in v["items"] if bool(i.get("deletedDate")) == trash]
                if "folderid" in q:
                    items = [i for i in items if i.get("folderId") == q["folderid"]]
                if "search" in q:
                    items = [i for i in items if q["search"].lower() in (i.get("name") or "").lower()]
                return self.ok({"object": "list", "data": items})
            if parts[2] == "folders":
                return self.ok({"object": "list", "data": v["folders"]})
        if parts[:2] == ["object", "item"] and len(parts) == 3:
            if method == "GET":
                it = next((i for i in v["items"] if i["id"] == parts[2]), None)
                return self.ok(it) if it else self.fail("Not found.")
            if method == "PUT":
                new = json.loads(body)
                with open(f"{FAKE}/last-edit.json", "w") as f:
                    json.dump(new, f)
                v["items"] = [new if i["id"] == parts[2] else i for i in v["items"]]
                save(v)
                return self.ok(new)
            if method == "DELETE":
                if q.get("permanent") == "true":
                    v["items"] = [i for i in v["items"] if i["id"] != parts[2]]
                else:
                    for i in v["items"]:
                        if i["id"] == parts[2]:
                            i["deletedDate"] = "2026-10-17T00:00:00.000Z"
                save(v)
                return self.send(200, {"success": True})
        if parts[:2] == ["object", "folder"] and len(parts) == 3:
            if method == "PUT":
                name = json.loads(body).get("name")
                with open(f"{FAKE}/last-folder-edit.json", "w") as f:
                    json.dump({"name": name}, f)
                hit = [f for f in v["folders"] if f["id"] == parts[2]]
                if not hit:
                    return self.fail("Not found.")
                hit[0]["name"] = name
                save(v)
                return self.ok(hit[0])
            if method == "DELETE":
                v["folders"] = [f for f in v["folders"] if f["id"] != parts[2]]
                for i in v["items"]:
                    if i.get("folderId") == parts[2]:
                        i["folderId"] = None
                save(v)
                return self.send(200, {"success": True})
        if parts[:2] == ["object", "template"] and method == "GET" and len(parts) == 3:
            t = TEMPLATES.get(parts[2])
            return self.ok({"object": "template", "template": t}) if t is not None else self.fail("Unknown template.")
        if parts == ["object", "item"] and method == "POST":
            new = json.loads(body)
            new.update(id=next_id("new"), attachments=[], passwordHistory=[], deletedDate=None)
            with open(f"{FAKE}/last-create.json", "w") as f:
                json.dump(new, f)
            v["items"].append(new)
            save(v)
            return self.ok(new)
        if parts == ["object", "folder"] and method == "POST":
            new = {"id": next_id("f-new"), "name": json.loads(body).get("name")}
            with open(f"{FAKE}/last-folder.json", "w") as f:
                json.dump(new, f)
            v["folders"].append(new)
            save(v)
            return self.ok(new)
        if parts[:2] == ["restore", "item"] and method == "POST":
            for i in v["items"]:
                if i["id"] == parts[2]:
                    i["deletedDate"] = None
            save(v)
            return self.ok({"object": "item", "id": parts[2]})
        if parts == ["attachment"] and method == "POST":
            ctype = self.headers.get("Content-Type", "")
            boundary = ctype.split("boundary=")[1].encode()
            part = body.split(b"--" + boundary)[1]
            head, _, content = part.partition(b"\r\n\r\n")
            content = content[:-2] if content.endswith(b"\r\n") else content
            name = disposition_filename(head)
            with open(f"{FAKE}/last-upload", "wb") as f:
                f.write(content)
            for i in v["items"]:
                if i["id"] == q.get("itemid"):
                    i.setdefault("attachments", []).append({"id": next_id("att"), "fileName": name, "size": "5",
                                                            "sizeName": "5 Bytes"})
            save(v)
            return self.ok({"object": "item"})
        if parts[:2] == ["object", "attachment"] and method == "GET":
            return self.send(200, raw=b"ATTACHMENT-CONTENT", ctype="application/octet-stream")
        return self.fail(f"fake bw serve: unsupported {method} {u.path}")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main(argv):
    host = argv[argv.index("--hostname") + 1]
    if not host.startswith("unix://"):
        print("fake bw serve: only unix:// is implemented", file=sys.stderr)
        return 2
    path = host[len("unix://"):]
    if os.environ.get("FAKE_BW_DELAY"):
        time.sleep(float(os.environ["FAKE_BW_DELAY"]))   # node start-up, like the CLI
    srv = Server(path, Handler)     # bind: the socket gets the umask of the process (0600 under the supervisor)
    print("Listening on " + host, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
