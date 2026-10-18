#!/usr/bin/env python3
"""Broker tests (sections 4.x of run.sh): the real vault-share.py broker as a child process in a scratch directory, the fake rbw of
tests/vault-browse/bin, the peer identity replaced by VAULT_SHARE_TEST_PEER_FILE (honoured only in verified test mode)."""
import hashlib
import hmac
import json
import os
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "../../.."))
SCRIPT = os.path.join(REPO, ".config/hypr/scripts/vault-share.py")
VB = os.path.join(REPO, "infrastructure/tests/vault-browse/bin")
passed = failed = 0
ONLY = [x for x in os.environ.get("BROKER_ONLY", "").split(",") if x]
QUICK = os.environ.get("BROKER_QUICK") == "1"


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name}" + (f"  [{detail}]" if detail else ""))


class Lab:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="vshare.")
        self.run = os.path.join(self.root, "run")
        self.etc = os.path.join(self.root, "etc")
        self.rt = os.path.join(self.root, "rt")
        self.fake = os.path.join(self.root, "fake")
        for d in (self.run, self.etc, self.rt, self.fake):
            os.makedirs(d, mode=0o755, exist_ok=True)
        os.chmod(self.run, 0o755)
        os.chmod(self.etc, 0o755)
        os.chmod(self.rt, 0o700)
        self.sock = os.path.join(self.run, "sock")
        self.scopes = os.path.join(self.etc, "scopes.tsv")
        self.peer = os.path.join(self.root, "peer")
        self.err_path = os.path.join(self.root, "broker.err")
        self.proc = None
        self.reset()

    def reset(self):
        shutil.copy(os.path.join(HERE, "fixture.json"), os.path.join(self.fake, "vault.json"))
        for f in os.listdir(self.fake):
            if f not in ("vault.json",):
                path = os.path.join(self.fake, f)
                if os.path.isdir(path):
                    shutil.rmtree(path)
                else:
                    os.unlink(path)
        open(os.path.join(self.fake, "argv.log"), "w").close()
        shutil.copy(os.path.join(HERE, "scopes.tsv"), self.scopes)
        os.chmod(self.scopes, 0o644)
        shutil.rmtree(self.rt, ignore_errors=True)
        os.makedirs(self.rt, mode=0o700)
        with open(os.path.join(self.root, "rbw.json"), "w") as f:
            f.write('{"email":"test@example.com"}')

    def env(self, **extra):
        e = {
            "PATH": VB + ":/usr/bin:/bin", "HOME": os.environ.get("HOME", "/tmp"), "LANG": "C.UTF-8",
            "FAKE_DIR": self.fake, "RBW_BIN": os.path.join(VB, "rbw"), "VAULT_RBW_CONF": os.path.join(self.root, "rbw.json"),
            "VAULT_SHARE_TEST_DIR": HERE, "VAULT_SHARE_SCRATCH": self.root, "VAULT_SHARE_SOCK": self.sock,
            "VAULT_SHARE_SCOPES": self.scopes, "VAULT_SHARE_RUNTIME": self.rt, "VAULT_SHARE_TEST_PEER_FILE": self.peer,
            "XDG_RUNTIME_DIR": self.rt,
        }
        e.update(extra)
        return e

    def start(self, via_activate=False, **extra):
        self.stop()
        env = self.env(**extra)
        err = open(self.err_path, "ab")
        if via_activate:
            keys = [a for k in env for a in ("-E", k)]      # systemd-socket-activate clears the environment except the names given
            self.proc = subprocess.Popen(["systemd-socket-activate", "-l", self.sock, *keys, sys.executable, "-I", "-B", SCRIPT, "serve"],
                                         env=env, stderr=err, stdout=subprocess.DEVNULL)
            for _ in range(50):
                if os.path.exists(self.sock):
                    break
                time.sleep(0.1)
            return
        self.proc = subprocess.Popen([sys.executable, "-I", "-B", SCRIPT, "serve"], env=env, stderr=err, stdout=subprocess.DEVNULL)
        for _ in range(100):
            if os.path.exists(self.sock):
                break
            if self.proc.poll() is not None:
                return
            time.sleep(0.05)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None
        if os.path.exists(self.sock):
            os.unlink(self.sock)

    def as_user(self, name):
        with open(self.peer, "w") as f:
            f.write(name)

    def talk(self, payload, user="td", timeout=15, read=True):
        self.as_user(user)
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(timeout)
        s.connect(self.sock)
        s.sendall(payload)
        if not read:
            return s
        buf = b""
        try:
            while not buf.endswith(b"\n"):
                c = s.recv(65536)
                if not c:
                    break
                buf += c
        except socket.timeout:
            buf = b"TIMEOUT"
        s.close()
        return buf

    def ask(self, msg, user="td"):
        raw = self.talk(json.dumps(msg).encode() + b"\n", user)
        try:
            return json.loads(raw)
        except ValueError:
            return {"ok": False, "error": "unparsed", "raw": raw[:80]}

    def argv(self):
        return open(os.path.join(self.fake, "argv.log")).read()

    def err(self):
        return open(self.err_path, errors="replace").read()

    def notify_log(self):
        try:
            return open(os.path.join(self.fake, "notify.log")).read().splitlines()
        except OSError:
            return []

    def cleanup(self):
        self.stop()
        shutil.rmtree(self.root, ignore_errors=True)


def hotp_ref(secret_b32, t, period=30, digits=6):
    import base64
    key = base64.b32decode(secret_b32)
    mac = hmac.new(key, struct.pack(">Q", int(t // period)), hashlib.sha1).digest()
    o = mac[-1] & 15
    return str((struct.unpack(">I", mac[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits).zfill(digits)


def sect(n):
    return not ONLY or str(n) in ONLY


def main():
    lab = Lab()
    try:
        run(lab)
    finally:
        lab.cleanup()
    print(f"\nbroker: passed {passed}, failed {failed}")
    return 1 if failed else 0


def run(lab):
    ids = lambda r: sorted(i["id"] for i in r.get("items", []))
    lab.start()
    check("4.0 the broker starts and listens (direct bind, test mode)", lab.proc.poll() is None and os.path.exists(lab.sock))

    guard = subprocess.run([sys.executable, "-I", "-B", SCRIPT, "check-rbw"], env=lab.env(), capture_output=True, text=True)
    check("4.0 doctor check-rbw accepts the supported wrapper without any vault read", guard.returncode == 0 and "wrapper" in guard.stdout
          and "rbw get" not in lab.argv() and "rbw list" not in lab.argv())

    # 4.1 whoami
    td = lab.ask({"v": 1, "op": "whoami"}, "td")
    yc = lab.ask({"v": 1, "op": "whoami"}, "yc")
    check("4.1 whoami td: its rules, vault unlocked", td.get("ok") and td["user"] == "td" and td["vault"] == "unlocked"
          and td["rules"] == ["Shared/**", "Users/td/**", "Work/Acme/**"], str(td))
    check("4.1 whoami yc: its own rules", yc.get("ok") and yc["rules"] == ["Shared/**", "Users/yc/**", "Work/Globex/**"], str(yc))

    # 4.2 list
    r = lab.ask({"v": 1, "op": "list"}, "td")
    check("4.2 td list: exactly the in-scope ids (Shared, Users/td, Work/Acme); no Linux/td, no Users/yc, no Globex, no folderless",
          ids(r) == sorted(["s-wifi", "s-note", "dup1", "dup2", "td-env", "acme-host", "acme-plain", "ssh-ok", "ssh-no", "card"]), str(ids(r)))
    r2 = lab.ask({"v": 1, "op": "list"}, "yc")
    check("4.2 yc list: its own scope (never Work/Acme)", "acme-host" not in ids(r2) and "yc-env" in ids(r2) and "globex" in ids(r2))
    r3 = lab.ask({"v": 1, "op": "list", "folder": "Shared/Net"}, "td")
    check("4.2 list --folder: that folder and below, inside the scope", ids(r3) == ["card", "dup1", "dup2", "s-note", "s-wifi"], str(ids(r3)))
    r4 = lab.ask({"v": 1, "op": "list", "folder": "Users/yc"}, "td")
    check("4.2 list --folder outside the scope: empty", r4.get("count") == 0)
    w = next(i for i in lab.ask({"v": 1, "op": "list"}, "td")["items"] if i["id"] == "s-wifi")
    check("4.2 list rows: id, folder, name, type, user, hosts - no password", set(w) == {"id", "folder", "name", "type", "user", "hosts"}
          and w["hosts"] == ["router.example.test"] and w["type"] == "login")

    # 4.3 uniform not_found
    a = lab.talk(json.dumps({"v": 1, "op": "get", "id": "yc-env", "fields": ["password"]}).encode() + b"\n")
    b = lab.talk(json.dumps({"v": 1, "op": "get", "id": "no-such-id", "fields": ["password"]}).encode() + b"\n")
    c = lab.talk(json.dumps({"v": 1, "op": "get", "folder": "Users/yc/Env/demo", "name": "dev", "fields": ["password"]}).encode() + b"\n")
    d = lab.talk(json.dumps({"v": 1, "op": "get", "folder": "Nowhere", "name": "x", "fields": ["password"]}).encode() + b"\n")
    check("4.3 an out-of-scope id, a nonexistent id and out-of-scope / nonexistent folder+name give the same bytes", a == b == c == d and b'"not_found"' in a, str((a, b, c, d)))
    e = lab.ask({"v": 1, "op": "get", "id": "lx-td", "fields": ["password"]}, "td")
    check("4.3 Linux/td is NOT served to td (owner decision: the Linux passwords stay the owner's)", e.get("error") == "not_found")
    e = lab.ask({"v": 1, "op": "get", "id": "nofolder", "fields": ["password"]}, "td")
    check("4.3 an item without a folder is never served", e.get("error") == "not_found")
    e = lab.ask({"v": 1, "op": "get", "id": "work-top", "fields": ["password"]}, "td")
    check("4.3 Work/Acme/** does not include items stored directly in Work", e.get("error") == "not_found")
    e = lab.ask({"v": 1, "op": "describe", "id": "yc-env"}, "td")
    check("4.3 describe of an out-of-scope item is the same not_found", e.get("error") == "not_found")

    # 4.4 get
    r = lab.ask({"v": 1, "op": "get", "id": "td-env", "fields": ["field:API_KEY", "notes", "field:NOPE", "field:PLAIN"]}, "td")
    check("4.4 get: hidden and plain custom fields, missing lists the unset ones", r.get("ok") and r["values"] == {"field:API_KEY": "TDKEY-777", "field:PLAIN": "plain-1"}
          and r["missing"] == ["notes", "field:NOPE"], str(r))
    r = lab.ask({"v": 1, "op": "get", "folder": "Shared/Net", "name": "Office Wi-Fi", "field": "password"}, "td")
    check("4.4 get by folder+name with the 'field' shorthand", r.get("ok") and r["values"] == {"password": "WIFIPASS-1"}, str(r))
    r = lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["username", "uris", "number"]}, "td")
    check("4.4 get: username, uris; a card field on a login is missing", r.get("ok") and r["values"] == {"username": "guest", "uris": "https://router.example.test"} and r["missing"] == ["number"], str(r))
    r = lab.ask({"v": 1, "op": "get", "id": "card", "fields": ["number", "code", "cardholder_name"]}, "td")
    check("4.4 get: card fields", r.get("ok") and r["values"]["number"] == "4111111111111111" and r["values"]["cardholder_name"] == "T Team", str(r))
    r = lab.ask({"v": 1, "op": "describe", "id": "td-env"}, "td")
    names = {f["name"]: f for f in r["item"]["fields"]}
    check("4.4 describe: field names with set / hidden flags, no value", r.get("ok") and names["field:API_KEY"]["hidden"] and names["field:API_KEY"]["set"]
          and "TDKEY" not in json.dumps(r) and r["item"]["type"] == "note", str(r)[:200])

    # 4.5 totp
    r = lab.ask({"v": 1, "op": "totp", "id": "acme-host"}, "td")
    now = time.time()
    ok = r.get("ok") and r["code"] in (hotp_ref("JBSWY3DPEHPK3PXP", now), hotp_ref("JBSWY3DPEHPK3PXP", now - 1), hotp_ref("JBSWY3DPEHPK3PXP", now + 1))
    check("4.5 totp on a marked item: the RFC 6238 reference code", ok and r["period"] == 30 and 0 < r["left"] <= 30, str(r))
    r = lab.ask({"v": 1, "op": "totp", "id": "acme-plain"}, "td")
    check("4.5 totp on an unmarked item: policy", r.get("error") == "policy")
    r = lab.ask({"v": 1, "op": "get", "id": "acme-host", "fields": ["totp"]}, "td")
    check("4.5 get 'totp' (the seed): policy, even on a marked item", r.get("error") == "policy" and "JBSWY" not in json.dumps(r))
    r = lab.ask({"v": 1, "op": "get", "id": "acme-host", "fields": ["history"]}, "td")
    check("4.5 get 'history': policy", r.get("error") == "policy")
    r = lab.ask({"v": 1, "op": "describe", "id": "acme-host"}, "td")
    r2 = lab.ask({"v": 1, "op": "describe", "id": "acme-plain"}, "td")
    check("4.5 describe tells shared / refused for the seed", r["item"]["totp"] == "shared" and r2["item"]["totp"] == "refused")

    # 4.6 ssh
    r = lab.ask({"v": 1, "op": "get", "id": "ssh-no", "fields": ["private_key"]}, "td")
    check("4.6 an SSH private key without the marker: policy", r.get("error") == "policy" and "SSHPRIV" not in json.dumps(r))
    r = lab.ask({"v": 1, "op": "get", "id": "ssh-ok", "fields": ["private_key", "public_key", "fingerprint"]}, "td")
    check("4.6 ...with the marker it is served, public key and fingerprint too", r.get("ok") and r["values"]["private_key"] == "SSHPRIV-OK"
          and r["values"]["public_key"].startswith("ssh-ed25519") and r["values"]["fingerprint"] == "SHA256:fp-ok", str(r))
    r = lab.ask({"v": 1, "op": "get", "id": "ssh-no", "fields": ["public_key"]}, "td")
    check("4.6 the public key is always served", r.get("ok") and "pub-no" in r["values"]["public_key"])

    # 4.8 / 4.14 / 4.15
    r = lab.ask({"v": 1, "op": "get", "folder": "Shared/Net", "name": "Printer", "fields": ["password"]}, "td")
    check("4.15 two items with one name: ambiguous, the message says how many", r.get("error") == "ambiguous" and "2 items called Printer" in r["message"], str(r))
    vault = json.load(open(os.path.join(lab.fake, "vault.json")))
    for it in vault["items"]:
        if it["id"] == "acme-plain":
            it["folderId"] = "f-globex"
    json.dump(vault, open(os.path.join(lab.fake, "vault.json"), "w"))
    subprocess.run([os.path.join(VB, "rbw"), "sync"], env=lab.env(), check=False)
    r = lab.ask({"v": 1, "op": "get", "id": "acme-plain", "fields": ["password"]}, "td")
    check("4.8 an item moved out of the scope is not_found at the next request (no broker cache)", r.get("error") == "not_found", str(r))
    lab.reset()
    lab.start()

    # 4.7 locked
    open(os.path.join(lab.fake, "rbw-locked"), "w").close()
    mark = len(lab.argv())
    rs = [lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["password"]}, "td") for _ in range(5)]
    seen = lab.argv()[mark:]
    check("4.7 a locked vault: 'locked' every time", all(x.get("error") == "locked" for x in rs), str(rs[0]))
    check("4.7 ...only `rbw unlocked` ran: no get, no list, no unlock/pinentry", "rbw unlocked" in seen and "rbw get" not in seen and "rbw list" not in seen
          and "rbw unlock " not in seen and "rbw login" not in seen, seen)
    check("4.7 ...and the owner got one notification across 5 requests", len(lab.notify_log()) == 1 and "td is waiting" in lab.notify_log()[0], str(lab.notify_log()))
    w = lab.ask({"v": 1, "op": "whoami"}, "td")
    check("4.7 whoami still answers while locked and says so", w.get("ok") and w["vault"] == "locked")
    os.unlink(os.path.join(lab.fake, "rbw-locked"))

    # 4.7b command-boundary races: no replacement agent or actual pinentry can start.
    for mode in ("get-disappear", "get-lock", "list-lock", "get-reprompt", "list-reprompt"):
        lab.stop(); lab.reset()
        probe = os.path.join(lab.fake, "probe-bin")
        os.makedirs(probe, exist_ok=True)
        for binary, body in (("ldd", "echo 'inert library => not found'\n"),
                             ("pinentry", 'touch "$FAKE_DIR/prompt-invoked"\nexit 1\n')):
            path = os.path.join(probe, binary)
            with open(path, "w") as f:
                f.write("#!/usr/bin/env bash\n" + body)
            os.chmod(path, 0o755)
        with open(os.path.join(lab.fake, "race-mode"), "w") as f:
            f.write(mode)
        lab.start(RBW_BIN=os.path.join(HERE, "bin/rbw-race"))
        op = "list" if mode.startswith("list") else "get"
        msg = {"v": 1, "op": op, "id": "s-wifi", "fields": ["password"]}
        r = lab.ask(msg)
        expected = "not_found" if mode.endswith("reprompt") else "locked"
        check(f"4.7b {mode}: {expected} response", r.get("error") == expected, str(r))
        records = [json.loads(line) for line in open(os.path.join(lab.fake, "boundary.jsonl"))]
        check(f"4.7b {mode}: startup veto and no-prompt marker reach every child",
              bool(records) and all(x["agent"] == "/usr/bin/false" and x["prompt"] == "vault-share:no-prompt" for x in records))
        check(f"4.7b {mode}: no agent startup and no pinentry binary ran",
              not os.path.exists(os.path.join(lab.fake, "would-start-agent")) and not os.path.exists(os.path.join(lab.fake, "prompt-invoked")))
    lab.stop(); lab.reset()
    open(os.path.join(lab.fake, "unsupported-wrapper"), "w").close()
    lab.start(RBW_BIN=os.path.join(HERE, "bin/rbw-race"))
    r = lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["password"]})
    guard = subprocess.run([sys.executable, "-I", "-B", SCRIPT, "check-rbw"],
                           env=lab.env(RBW_BIN=os.path.join(HERE, "bin/rbw-race")), capture_output=True, text=True)
    check("4.7b doctor check-rbw refuses unsupported wrapper", guard.returncode == 1 and "bw-setup" in guard.stderr)
    check("4.7b unsupported pinentry configuration: unavailable before sync/list/get", r.get("error") == "unavailable"
          and "rbw get" not in lab.argv() and "rbw list" not in lab.argv() and "rbw sync" not in lab.argv(), str(r))
    lab.stop(); lab.reset(); lab.start()

    # 4.9 refused identities
    for who, word in (("owner", "owner"), ("root", "uid 0"), ("aimcp", "no vault scope"), ("nobody-here", "no vault scope")):
        mark = len(lab.argv())
        r = lab.ask({"v": 1, "op": "list"}, who)
        check(f"4.9 peer {who}: refused ({word}) and no rbw call", r.get("error") == "refused" and word in r["message"] and len(lab.argv()) == mark, str(r))

    # 4.12 bad requests
    big = lab.talk(b'{"v":1,"op":"list","pad":"' + b"a" * 5000 + b'"}\n')
    check("4.12 more than 4096 bytes: bad_request", b"bad_request" in big, str(big[:80]))
    check("4.12 not JSON: bad_request", b"bad_request" in lab.talk(b"hello\n"))
    check("4.12 JSON but not an object: bad_request", b"bad_request" in lab.talk(b"[1,2]\n"))
    check("4.12 v missing: bad_request", lab.ask({"op": "list"}).get("error") == "bad_request")
    check("4.12 unknown op: bad_request", lab.ask({"v": 1, "op": "delete"}).get("error") == "bad_request")
    check("4.12 v 2: bad_request", lab.ask({"v": 2, "op": "list"}).get("error") == "bad_request")
    check("4.12 65 fields: bad_request", lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": [f"field:f{i}" for i in range(65)]}).get("error") == "bad_request")
    check("4.12 no fields: bad_request", lab.ask({"v": 1, "op": "get", "id": "s-wifi"}).get("error") == "bad_request")
    check("4.12 a field name with a space or a slash: bad_request", lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["pass word"]}).get("error") == "bad_request")
    check("4.12 an id with shell characters: bad_request", lab.ask({"v": 1, "op": "get", "id": "x;rm -rf", "fields": ["password"]}).get("error") == "bad_request")
    check("4.12 an unknown builtin field: bad_request", lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["bogus"]}).get("error") == "bad_request")
    if not QUICK:
        t0 = time.time()
        raw = lab.talk(b"", read=True, timeout=12)
        check("4.12 a client that sends nothing is cut off after about 5 s", b"bad_request" in raw and 4 < time.time() - t0 < 8, f"{time.time() - t0:.1f}s {raw[:40]}")
    check("4.12 the broker survived all of it", lab.proc.poll() is None and lab.ask({"v": 1, "op": "whoami"}).get("ok"))

    # 4.11 rate limits
    lab.reset()
    lab.start()
    ok = True
    for chunk in range(3):
        r = lab.ask({"v": 1, "op": "get", "id": "td-env", "fields": [f"field:F{chunk}_{i}" for i in range(40)]}, "td")
        ok = ok and r.get("ok")
    check("4.11 120 fields in a minute are allowed", ok)
    r = lab.ask({"v": 1, "op": "get", "id": "td-env", "fields": ["field:API_KEY"]}, "td")
    check("4.11 the 121st field: rate_limited with retry_after", r.get("error") == "rate_limited" and r.get("retry_after", 0) > 0, str(r))
    lab.start()
    r = lab.ask({"v": 1, "op": "get", "id": "td-env", "fields": ["field:API_KEY"]}, "td")
    check("4.11 the limit survives a broker restart (state in the runtime dir)", r.get("error") == "rate_limited")
    check("4.11 rate.json is 600 in a 700 directory", oct(os.stat(os.path.join(lab.rt, "rate.json")).st_mode & 0o777) == "0o600"
          and oct(os.stat(lab.rt).st_mode & 0o777) == "0o700")
    r = lab.ask({"v": 1, "op": "get", "id": "yc-env", "fields": ["field:API_KEY"]}, "yc")
    check("4.11 the limit is per user (yc is unaffected)", r.get("ok"))
    marks = len(lab.notify_log())
    res = [lab.ask({"v": 1, "op": "get", "id": f"nothing-{i}", "fields": ["password"]}, "yc") for i in range(21)]
    check("4.11 21 misses are 21 not_found", all(x.get("error") == "not_found" for x in res))
    r = lab.ask({"v": 1, "op": "whoami"}, "yc")
    check("4.11 then yc is paused for 15 minutes on every op", r.get("error") == "rate_limited" and 800 < r.get("retry_after", 0) <= 901, str(r))
    n = lab.notify_log()[marks:]
    check("4.11 ...with exactly one notification to the owner", len(n) == 1 and "yc made 20 refused" in n[0], str(n))
    lab.reset()
    lab.start()
    res = [lab.ask({"v": 1, "op": "totp", "id": "acme-host"}, "td") for _ in range(11)]
    check("4.11 totp codes: 10 a minute, the 11th is rate_limited", all(x.get("ok") for x in res[:10]) and res[10].get("error") == "rate_limited", str(res[10]))

    # 4.13 scope file trust
    lab.reset()
    lab.start()
    os.chmod(lab.scopes, 0o664)
    r = lab.ask({"v": 1, "op": "list"}, "td")
    check("4.13 a group-writable scope file: unavailable for every request", r.get("error") == "unavailable", str(r))
    os.chmod(lab.scopes, 0o644)
    r = lab.ask({"v": 1, "op": "list"}, "td")
    check("4.13 ...and works again when fixed", r.get("ok"))
    real = lab.scopes + ".real"
    os.rename(lab.scopes, real)
    os.symlink(real, lab.scopes)
    check("4.13 a symlinked scope file: unavailable", lab.ask({"v": 1, "op": "list"}, "td").get("error") == "unavailable")
    os.unlink(lab.scopes)
    os.rename(real, lab.scopes)
    with open(lab.scopes, "a") as f:
        f.write("td\t**\n")
    check("4.13 an invalid rule: unavailable (fails closed)", lab.ask({"v": 1, "op": "list"}, "td").get("error") == "unavailable")
    os.chmod(lab.etc, 0o775)
    shutil.copy(os.path.join(HERE, "scopes.tsv"), lab.scopes)
    os.chmod(lab.scopes, 0o644)
    check("4.13 a group-writable scope directory: unavailable", lab.ask({"v": 1, "op": "list"}, "td").get("error") == "unavailable")
    os.chmod(lab.etc, 0o755)
    os.unlink(lab.scopes)
    check("4.13 a missing scope file: unavailable", lab.ask({"v": 1, "op": "list"}, "td").get("error") == "unavailable")
    check("4.13 ...but the owner is still refused first, not told 'unavailable'", lab.ask({"v": 1, "op": "list"}, "owner").get("error") == "refused")

    # 4.14 reload
    lab.reset()
    lab.start()
    check("4.14 before: acme-plain is in td's scope", lab.ask({"v": 1, "op": "get", "id": "acme-plain", "fields": ["password"]}).get("ok"))
    time.sleep(0.05)
    txt = open(lab.scopes).read().replace("td\tWork/Acme/**\n", "")
    open(lab.scopes, "w").write(txt)
    os.utime(lab.scopes, (time.time() + 5, time.time() + 5))
    check("4.14 the scope file is reloaded on change: the rule is gone, not_found", lab.ask({"v": 1, "op": "get", "id": "acme-plain", "fields": ["password"]}).get("error") == "not_found")

    # 4.16 journal
    log = lab.err()
    lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["password", "field:Region"]}, "td")
    log = lab.err()
    check("4.16 audit lines carry op, user, uid, id, fields and result", "op=get user=td" in log and "id=s-wifi" in log and "fields=password,field:Region" in log and "result=ok" in log, log[-300:])
    secrets = ["WIFIPASS-1", "TDKEY-777", "YCKEY-888", "ACMEPASS", "SSHPRIV", "JBSWY", "Office", "Shared note", "Hosting", "Billing", "deploy key", "Globex panel"]
    check("4.16 ...and no value and no item name anywhere in the broker's journal output", not any(s in log for s in secrets), next((s for s in secrets if s in log), ""))

    # 4.17 client checks
    sys.path.insert(0, os.path.dirname(SCRIPT))
    import importlib.util
    os.environ.update({"VAULT_SHARE_TEST_DIR": HERE, "VAULT_SHARE_SCRATCH": lab.root})
    spec = importlib.util.spec_from_file_location("vs_client", SCRIPT)
    vs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vs)
    try:
        vs.Client(lab.sock).request({"v": 1, "op": "whoami"})
        own = "answered"
    except vs.Unavailable as e:
        own = "refused"
    check("4.17 the client refuses a broker directory owned by the caller itself", own == "refused")
    os.chmod(lab.run, 0o775)
    try:
        vs.Client(lab.sock, allow_self=True).request({"v": 1, "op": "whoami"})
        gw = "answered"
    except vs.Unavailable:
        gw = "refused"
    os.chmod(lab.run, 0o755)
    check("4.17 the client refuses a group-writable broker directory", gw == "refused")
    try:
        vs.Client(os.path.join(lab.root, "nodir/sock"), allow_self=True).request({"v": 1, "op": "whoami"})
        nd = "answered"
    except vs.Unavailable:
        nd = "refused"
    check("4.17 ...and a directory that does not exist is 'unavailable'", nd == "refused")
    lab.as_user("td")
    try:
        r = vs.Client(lab.sock, allow_self=True).request({"v": 1, "op": "whoami"})
        good = r["user"] == "td"
    except vs.ShareError:
        good = False
    check("4.17 a proper client works with the same directory", good)


    # 4.18 / 4.19 the command line client
    lab.reset()
    lab.start()
    import threading
    ps_samples = []
    stop_ps = threading.Event()

    def sampler():
        while not stop_ps.is_set():
            ps_samples.append(subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout)
            time.sleep(0.05)

    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    wl = os.path.join(lab.root, "wayland-test")
    open(wl, "w").close()
    state = os.path.join(lab.root, "state")
    os.makedirs(state, exist_ok=True)

    def cli_env(user="td", wayland=True, **kw):
        e = lab.env(VAULT_SHARE_TEST_AS=user, ENVS_TOOL_PATH=VB, ENVS_TEST_ROOT_PID=str(os.getpid()), XDG_STATE_HOME=state,
                    VAULT_CLEAR_AFTER="1", **kw)
        if wayland:
            e["WAYLAND_DISPLAY"] = wl
        return e

    def vsh(*args, user="td", wayland=True, env=None, shell_wrap=None):
        e = cli_env(user, wayland)
        if env:
            e.update(env)
        lab.as_user(user)
        if shell_wrap:
            return subprocess.run(["bash", "-c", shell_wrap], env=e, capture_output=True, text=True, timeout=30)
        return subprocess.run([sys.executable, "-I", "-B", SCRIPT, *args], env=e, capture_output=True, text=True, timeout=30)

    outs = []

    def rec(p):
        outs.append(p.stdout + p.stderr)
        return p

    p = rec(vsh("status"))
    check("4.18 status (as td): user, vault state, rules", p.returncode == 0 and "user td" in p.stdout and "Work/Acme/**" in p.stdout, p.stdout + p.stderr)
    p = rec(vsh("list", "--json"))
    check("4.18 list --json: ids of the scope, no password", p.returncode == 0 and "s-wifi" in p.stdout and "WIFIPASS" not in p.stdout)
    p = vsh("get", "s-wifi", "--field", "password")
    check("4.18 get into a pipe prints the value (the harness asked for it)", p.returncode == 0 and p.stdout == "WIFIPASS-1", p.stdout + p.stderr)
    p = vsh("get", "Shared/Net/Office Wi-Fi", "--field", "password")
    check("4.18 get by FOLDER/NAME", p.returncode == 0 and p.stdout == "WIFIPASS-1", p.stdout + p.stderr)
    p = rec(vsh("get", "x", "--field", "password", shell_wrap=f"script -qec '{sys.executable} -I -B {SCRIPT} get s-wifi --field password' /dev/null"))
    check("4.18 get to a terminal: exit 4 and no value on the screen", "WIFIPASS" not in p.stdout and ("never to a terminal" in p.stdout or p.returncode == 4), p.stdout[:200])
    os.symlink(shutil.which("bash"), os.path.join(lab.root, "claude")) if not os.path.exists(os.path.join(lab.root, "claude")) else None
    e = cli_env()
    lab.as_user("td")
    p = subprocess.run([os.path.join(lab.root, "claude"), "-c", f"{sys.executable} -I -B {SCRIPT} get s-wifi --field password | cat; exit ${{PIPESTATUS[0]}}"],
                       env=e, capture_output=True, text=True)
    outs.append(p.stderr)
    check("4.18 get under a fake claude ancestor: exit 4, nothing on stdout", p.returncode == 4 and "WIFIPASS" not in p.stdout, f"{p.returncode} {p.stdout!r} {p.stderr[:100]}")
    p = vsh("copy", "s-wifi")
    clip = open(os.path.join(lab.fake, "clip.last")).read() if os.path.exists(os.path.join(lab.fake, "clip.last")) else ""
    check("4.18 copy (td has the clipboard): sensitive wl-copy holds the value", p.returncode == 0 and clip == "WIFIPASS-1" and "--sensitive" in open(os.path.join(lab.fake, "argv.log")).read(), p.stderr)
    outs.append(p.stdout + p.stderr)
    p = rec(vsh("copy", "s-wifi", user="yc", wayland=False))
    check("4.18 copy for yc (no clipboard): exit 4, use envs run", p.returncode == 4 and "no clipboard" in p.stderr)
    p = vsh("code", "acme-host", "--print")
    now = time.time()
    check("4.18 code --print into a pipe prints the code", p.returncode == 0 and p.stdout.strip() in (hotp_ref("JBSWY3DPEHPK3PXP", now), hotp_ref("JBSWY3DPEHPK3PXP", now - 1), hotp_ref("JBSWY3DPEHPK3PXP", now + 1)), p.stdout)
    p = vsh("code", "acme-host")
    clip = open(os.path.join(lab.fake, "clip.last")).read()
    check("4.18 code copies by default", p.returncode == 0 and len(clip) == 6 and clip.isdigit(), clip)
    outs.append(p.stdout + p.stderr)
    p = rec(vsh("code", "acme-plain"))
    check("4.18 code on an unmarked item: exit 4 (policy)", p.returncode == 4)
    p = rec(vsh("get", "ssh-no", "--field", "private_key"))
    check("4.18 a private key without the marker: exit 4", p.returncode == 4 and "SSHPRIV" not in p.stdout + p.stderr)
    p = rec(vsh("get", "no-such", "--field", "password"))
    check("4.18 not found: exit 1 and the uniform message", p.returncode == 1 and "no such item in your scope" in p.stderr)
    p = rec(vsh("copy"))
    check("4.18 usage error: exit 2", p.returncode == 2)
    open(os.path.join(lab.fake, "rbw-locked"), "w").close()
    p = rec(vsh("list"))
    check("4.18 a locked vault: exit 3 and the message names the fix", p.returncode == 3 and "owner's vault is locked" in p.stderr)
    os.unlink(os.path.join(lab.fake, "rbw-locked"))
    lab.stop()
    p = rec(vsh("list"))
    check("4.18 no broker: exit 6", p.returncode == 6, p.stderr)
    lab.start()
    lab.as_user("owner")
    p = subprocess.run([sys.executable, "-I", "-B", SCRIPT, "selftest"], env=cli_env("owner"), capture_output=True, text=True)
    check("4.18 selftest as the owner: 'refused' with the real uid", p.returncode == 0 and f"uid {os.getuid()}" in p.stdout, p.stdout + p.stderr)
    p = rec(vsh("report", user="td", env={"VAULT_SHARE_TEST_AS": ""}))
    check("4.18 report: counts per user (owner side)", p.returncode == 0 and "td: 10 items in scope" in p.stdout and "yc: " in p.stdout, p.stdout + p.stderr)
    check("4.18 report without --names prints no item name", "Office" not in p.stdout)
    # rate limited exit code
    for _ in range(3):
        lab.ask({"v": 1, "op": "get", "id": "td-env", "fields": [f"field:G{_}_{i}" for i in range(40)]}, "td")
    for _ in range(130):
        if lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["username"]}, "td").get("error") == "rate_limited":
            break
    p = rec(vsh("get", "s-wifi", "--field", "password"))
    check("4.18 rate limited: exit 5", p.returncode == 5, f"{p.returncode} {p.stderr}")
    stop_ps.set()
    th.join(2)
    argv = lab.argv()
    values = ["WIFIPASS-1", "TDKEY-777", "ACMEPASS", "SSHPRIV", "JBSWY3DPEHPK3PXP", "LINUXPASS", "4111111111111111", "CVV-123"]
    check("4.19 sentinels: not in the argv log of rbw / wl-copy", not any(v in argv for v in values), next((v for v in values if v in argv), ""))
    hit = next((ln for smp in ps_samples for ln in smp.splitlines() if any(v in ln for v in values)), "")
    check("4.19 sentinels: not in any ps sample taken during the runs", not hit, hit[:200])
    leak = next((f"#{n}: {o}" for n, o in enumerate(outs) if any(v in o for v in values)), "")
    check("4.19 sentinels: not in stdout/stderr of the calls that were not asked for a value", not leak, leak[:200])
    check("4.19 sentinels: not in the broker's own output", not any(v in lab.err() for v in values))

    # 4.20 units and userns
    unit = open(os.path.join(REPO, ".config/systemd/user/vault-share.service")).read()
    sock_unit = open(os.path.join(REPO, ".config/systemd/user/vault-share.socket")).read()
    live = [ln.strip() for ln in (unit + sock_unit).splitlines() if ln.strip() and not ln.strip().startswith("#")]
    bad = [ln for ln in live if ln.split("=")[0] in ("ProtectSystem", "ProtectHome", "PrivateTmp", "PrivateDevices", "PrivateNetwork", "PrivateUsers",
           "ProtectKernelTunables", "ProtectKernelModules", "ProtectKernelLogs", "ProtectControlGroups", "ProtectHostname", "ProtectClock",
           "ProtectProc", "ProcSubset", "ReadWritePaths", "ReadOnlyPaths", "InaccessiblePaths", "TemporaryFileSystem", "BindPaths", "RestrictNamespaces",
           "MemoryDenyWriteExecute", "PrivateMounts")]
    check("4.20 the units use none of the options that imply PrivateUsers in a user manager", not bad, str(bad))
    check("4.20 the unit keeps the hardening that does not (NoNewPrivileges, LimitCORE, AF_UNIX only, UMask)", all(x in live for x in (
        "NoNewPrivileges=yes", "LimitCORE=0", "RestrictAddressFamilies=AF_UNIX", "UMask=0077")))
    check("4.20 the socket is 0666 on /run/vault-share/sock and the service has no TCP", "SocketMode=0666" in live and "ListenStream=/run/vault-share/sock" in live)
    um = os.path.join(lab.root, "uid_map")
    open(um, "w").write("         0       1000          1\n")
    p = subprocess.run([sys.executable, "-I", "-B", SCRIPT, "serve"], env=lab.env(VAULT_SHARE_TEST_UIDMAP=um), capture_output=True, text=True, timeout=10)
    check("4.20 a user-namespace uid_map: the broker refuses to serve", p.returncode != 0 and "user namespace" in p.stderr, p.stderr[:200])
    open(um, "w").write("         0          0 4294967295\n")
    lab.start(VAULT_SHARE_TEST_UIDMAP=um)
    check("4.20 the identity map is accepted", lab.proc.poll() is None and lab.ask({"v": 1, "op": "whoami"}).get("ok"))

    # socket activation and idle exit
    lab.start(via_activate=True)
    r = lab.ask({"v": 1, "op": "whoami"}, "td")
    check("4.22 socket activation: the broker takes fd 3 from systemd", r.get("ok") and r["user"] == "td", str(r))
    if not QUICK:
        lab.start(VAULT_SHARE_IDLE="1.5")
        lab.ask({"v": 1, "op": "whoami"})
        time.sleep(3.2)
        check("4.22 idle exit: the broker exits 0 after the idle time (the socket would stay with systemd)", lab.proc.poll() == 0, str(lab.proc.poll()))

    # non-test mode ignores the hooks
    lab.start(via_activate=True, VAULT_SHARE_TEST_DIR="/tmp", VAULT_SHARE_SCRATCH="/tmp")
    r = lab.ask({"v": 1, "op": "whoami"}, "td")
    check("4.10 hooks outside verified test mode are ignored: the peer is the real caller, i.e. the owner, who is refused",
          r.get("error") == "refused" and "owner" in r.get("message", ""), str(r))

    # 4.21 timing
    lab.reset()
    lab.start()
    lab.ask({"v": 1, "op": "whoami"})
    ts = []
    for _ in range(20):
        t0 = time.perf_counter()
        r = lab.ask({"v": 1, "op": "get", "id": "s-wifi", "fields": ["password"]}, "td")
        ts.append((time.perf_counter() - t0) * 1000)
        assert r.get("ok"), r
    p50 = statistics.median(ts)
    print(f"      timing: get p50 {p50:.0f} ms, max {max(ts):.0f} ms (bash fake rbw: three processes per get)")
    check("4.21 p50 of 20 get round trips with the bash fake is under 300 ms (target 150)", p50 < 300, f"{p50:.0f} ms")


sys.exit(main())
