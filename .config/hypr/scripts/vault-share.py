#!/usr/bin/env python3
"""vault-share: the scopes of the Bitwarden vault that td and yc may read, and the broker that serves
them, plus root-authorized td self Env writes. Python 3 stdlib only, runs under `python3 -I`; `vault-share` (.local/bin/vault-share) is the command.

SCOPES. /etc/vault-share/scopes.tsv (root-owned, rendered by `sudo ./apply-system.sh --only users`) holds one rule per line,
`user<TAB>rule`, `#` starts a comment:

  P/**        every item whose folder is P or below P   (`Shared/**`, `Users/td/**`, `Work/Acme/**`)
  P/NAME      exactly one item: folder P, item name NAME (the split is at the LAST `/`, so an item name that contains `/` cannot
              be written: use a folder rule)

Comparison is exact and case-sensitive after NFC. An item without a folder is never in scope. `Work/Acme/**` does not include
items stored directly in `Work`; a folder that only exists as the parent of another one holds no items of its own.
Refused when the file is checked: `**`, `/**`, empty or `.` / `..` segments, control characters, any other `*`, a leading or
trailing `/` (other than the `/**` suffix), more than 512 characters, the user root, the owner, or a name that is not a
Linux login name. The repo file infrastructure/vault-share/scopes.tsv has only generic rows (user `*` = every interactive
managed user, `{user}` = that user's name); company rows live in the owner's ~/.config/vault-share/scopes.local.tsv (0600, never
in the repo). `Linux/<user>` is in no scope: the Linux passwords stay the owner's.

  vault-share.py check-scopes FILE [--owner NAME]
  vault-share.py render-scopes --repo FILE [--local FILE] --managed "td yc" --owner NAME

BROKER. `serve` is the owner's user unit vault-share.service (socket-activated by vault-share.socket on
/run/vault-share/sock, mode 0666). It answers td and yc (SO_PEERCRED uid -> user name -> rules above) with values from the OWNER's
unlocked rbw, only for items inside their scope; the owner, root and every other user get `refused` before anything is read. It
never starts the rbw agent and never asks for a password: a locked vault is the answer `locked`. Reads use
`rbw list --raw` or `rbw get --raw ID`, checking scope on the folder and name of that same response.
Native env-put writes require the separate fresh root-owned /etc/vault-share/env-write.tsv td UID capability.
The exact project/env/values/overwrite/request_id schema writes only machine-marked personal notes in
Users/<peer>/Env/<project>, through the owner UNIX server without CLI/unlock fallback. An existing unlocked
owner session is required. Avoid concurrent external edits of that same note: this is not server CAS.
Pending/spent IDs and keyed request fingerprints persist in the owner private state directory; capacity
refuses new work without evicting recovery. apply-system --only users installs policy; restart vault-share.service afterward.

Protocol v1: one JSON line in, one JSON line out per connection (reads 4096 bytes, 5 s to send it).
A freshly authorized write peer may submit env-put frames up to 256 KiB, max 64 hidden fields; receipts contain metadata only.
  {"v":1,"op":"whoami"}                        {"v":1,"op":"list"[,"folder":"Shared/Net"]}
  {"v":1,"op":"describe",ITEM}                 {"v":1,"op":"get",ITEM,"fields":["password","field:API_KEY"]}
  {"v":1,"op":"totp",ITEM}                     ITEM = "id":"<id>"  or  "folder":"F","name":"N"
Field names: username password notes uris; card: cardholder_name brand number exp_month exp_year code; identity: rbw's snake_case
keys; ssh: public_key fingerprint, private_key only for items marked ssh; custom fields as field:<name>. Never served: the TOTP
seed and the password history. The marker is a custom field named `vault-share` whose value lists `totp` and/or `ssh`; only the
owner can set it. A code (op totp) needs the marker `totp`. Errors: locked not_found ambiguous policy refused rate_limited
bad_request unavailable internal conflict pending. not_found is the same answer for an item outside the scope and one that does not exist.
Every request is one journald line (op, user, uid, pid, comm, id, field names, result, ms), never a value or an item name.

CLIENT (td, yc):  vault-share status | list [--folder F] [--json] | copy ITEM [--field F] | code ITEM [--print] | get ITEM --field F
OWNER:            vault-share status | report [--names] | selftest | check-rbw | check-scopes | render-scopes | serve
Exit codes: 0 ok, 1 error, 2 usage, 3 locked, 4 refused / policy / agent / no clipboard, 5 rate limited, 6 broker unavailable.
Test mode (every VAULT_SHARE_* hook is ignored outside it): VAULT_SHARE_TEST_DIR below <repo>/infrastructure/tests/, VAULT_SHARE_SOCK /
_SCOPES / _RUNTIME below one VAULT_SHARE_SCRATCH that is not a real location, RBW_BIN below <repo>/infrastructure/tests/.
"""
import asyncio
import base64
import hashlib
import hmac
import importlib.machinery
import importlib.util
import json
import os
import pwd
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import time
import unicodedata
import urllib.parse
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,30}$")
MAX_RULE = 512


# ───────────────────────────── scope grammar ─────────────────────────────

def nfc(s):
    return unicodedata.normalize("NFC", s)


def valid_path(p):
    """Problem text for a folder path (no wildcard), or None."""
    if not p:
        return "empty path"
    if p.startswith("/") or p.endswith("/"):
        return "leading or trailing /"
    for seg in p.split("/"):
        if seg in ("", ".", ".."):
            return "empty, . or .. segment"
    return None


def parse_rule(rule):
    """-> ((kind, folder, name), None) or (None, problem). kind is prefix (P/**) or item (P/NAME)."""
    rule = nfc(rule)
    if len(rule) > MAX_RULE:
        return None, "rule longer than 512 characters"
    if any(ord(c) < 32 or ord(c) == 127 for c in rule):
        return None, "control character"
    if rule in ("**", "/**"):
        return None, f"{rule!r} would match everything"
    if rule.endswith("/**"):
        p = rule[:-3]
        if "*" in p:
            return None, "wildcard other than the /** suffix"
        bad = valid_path(p)
        return ((("prefix", p, None), None) if bad is None else (None, bad))
    if "*" in rule:
        return None, "wildcard other than the /** suffix"
    if "/" not in rule:
        return None, "an item rule needs a folder (FOLDER/NAME)"
    folder, name = rule.rsplit("/", 1)
    bad = valid_path(folder) or (None if name not in ("", ".", "..") else "empty, . or .. item name")
    return ((("item", folder, name), None) if bad is None else (None, bad))


def parse_rules(text, *, owner=None):
    """-> ({user: [rule tuples]}, [problem lines]). A bad line is a problem and is skipped."""
    rules, problems = {}, []
    for n, line in enumerate(text.splitlines(), 1):
        raw = line.strip()
        if not raw or raw.startswith("#"):
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 2:
            problems.append(f"line {n}: expected user<TAB>rule")
            continue
        user, rule = parts[0].strip(), parts[1].strip()
        if not USER_RE.match(user):
            problems.append(f"line {n}: {user!r} is not a login name")
            continue
        if user == "root" or (owner and user == owner):
            problems.append(f"line {n}: no scope for {user} (root and the owner read the vault directly)")
            continue
        r, bad = parse_rule(rule)
        if bad:
            problems.append(f"line {n}: {bad}")
            continue
        rules.setdefault(user, []).append(r)
    return rules, problems


def in_scope(user_rules, folder, name):
    """True when the item (folder, name) is inside one of the rules. No folder = never."""
    if not folder:
        return False
    folder, name = nfc(folder), nfc(name or "")
    for kind, f, n in user_rules or ():
        if kind == "prefix" and (folder == f or folder.startswith(f + "/")):
            return True
        if kind == "item" and folder == f and name == n:
            return True
    return False


def rule_text(r):
    return f"{r[1]}/**" if r[0] == "prefix" else f"{r[1]}/{r[2]}"


def render_scopes(repo_text, local_text, managed_interactive, owner):
    """The /etc/vault-share/scopes.tsv text for the interactive managed users -> (text, warnings, problems).
    Repo rows may use user `*` and `{user}`; a row for a user that is not an interactive managed user is dropped with a
    warning (the company rows of the local file name td and yc, and a machine without yc must still work)."""
    managed = [u for u in managed_interactive if u and u != owner and u != "root"]
    warnings, problems, out = [], [], {}

    def feed(text, label, expand):
        for n, line in enumerate(text.splitlines(), 1):
            raw = line.strip()
            if not raw or raw.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2:
                problems.append(f"{label} line {n}: expected user<TAB>rule")
                continue
            user, rule = parts[0].strip(), parts[1].strip()
            targets = managed if (user == "*" and expand) else [user]
            if user == "*" and not expand:
                problems.append(f"{label} line {n}: user * is only allowed in the repo file")
                continue
            for u in targets:
                if u not in managed:
                    if user != "*":
                        warnings.append(f"{label} line {n}: {user} is not an interactive managed user here, row dropped")
                    continue
                r = rule.replace("{user}", u) if expand else rule
                parsed, bad = parse_rule(r)
                if bad:
                    problems.append(f"{label} line {n}: {bad}")
                    continue
                out.setdefault(u, [])
                if rule_text(parsed) not in out[u]:
                    out[u].append(rule_text(parsed))

    feed(repo_text, "repo scopes", True)
    feed(local_text or "", "local scopes", False)
    lines = ["# /etc/vault-share/scopes.tsv: rendered by apply-system.sh (--only users) from infrastructure/vault-share/scopes.tsv",
             "# and the owner's ~/.config/vault-share/scopes.local.tsv. Do not edit; one rule per line, user<TAB>rule."]
    for u in sorted(out):
        for r in out[u]:
            lines.append(f"{u}\t{r}")
    return "\n".join(lines) + "\n", warnings, problems


def trusted_local_file(path, owner_uid):
    """The owner's overlay counts only when it is a regular file of the owner that nobody else can write."""
    try:
        st = os.lstat(path)
    except OSError:
        return False, "missing"
    if not stat.S_ISREG(st.st_mode):
        return False, "not a regular file (symlink?)"
    if st.st_uid != owner_uid:
        return False, "not owned by the owner"
    if st.st_mode & 0o022:
        return False, "group- or other-writable"
    return True, ""


# ───────────────────────────── paths and test mode ─────────────────────────────

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]                                  # ~/dotfiles for the owner, /srv/dotfiles for managed users
SOCK_DIR = Path("/run/vault-share")
SOCK_PATH = SOCK_DIR / "sock"
SCOPES_PATH = Path("/etc/vault-share/scopes.tsv")
MAX_REQUEST = 4096
MAX_WRITE_REQUEST = 256 * 1024
WRITE_STAGES = frozenset(('request', 'policy', 'storage', 'backend-prepare', 'backend-sync', 'folder-list',
                         'item-resolve', 'preflight', 'recovery', 'folder-create', 'folder-receipt', 'folder-visible',
                         'item-create', 'item-edit', 'item-verify', 'read-visibility', 'complete', 'capacity'))
WRITE_CODES = frozenset(('locked', 'unavailable', 'policy', 'bad_request', 'rate_limited', 'conflict', 'pending', 'internal', 'refused'))
MARKER = "vault-share"


def _under(path, root):
    rp, rr = os.path.realpath(path), os.path.realpath(root)
    return rp == rr or rp.startswith(rr + os.sep)


def _verified_test_mode():
    """The VAULT_SHARE_* hooks count only when the test directory is below <repo>/infrastructure/tests, the socket, the scope file
    and the runtime directory are below one scratch directory that is none of the real locations, and RBW_BIN (when set) is in
    the test directory. Anything else: no hooks, the constants above (a td process cannot reach the owner's broker environment,
    and an agent that sets the variables in a test gets nothing real)."""
    td = os.environ.get("VAULT_SHARE_TEST_DIR")
    scratch = os.environ.get("VAULT_SHARE_SCRATCH")
    if not td or not scratch or not _under(td, REPO / "infrastructure/tests"):
        return None
    real = [str(SOCK_DIR), "/etc", f"/run/user/{os.getuid()}", str(Path.home() / ".local/state")]
    if any(_under(scratch, r) for r in real):
        return None
    for var in ("VAULT_SHARE_SOCK", "VAULT_SHARE_SCOPES", "VAULT_SHARE_RUNTIME", "VAULT_SHARE_WRITE_POLICY"):
        v = os.environ.get(var)
        if v and not _under(v, scratch):
            return None
    rb = os.environ.get("RBW_BIN")
    if rb and not _under(rb if os.sep in rb else (shutil.which(rb) or "/nonexistent"), REPO / "infrastructure/tests"):
        return None
    return {"dir": os.path.realpath(td), "scratch": os.path.realpath(scratch)}


TEST = _verified_test_mode()


def cfg_path(var, default):
    return Path(os.environ[var]) if TEST and os.environ.get(var) else Path(default)


def sock_path():
    return cfg_path("VAULT_SHARE_SOCK", SOCK_PATH)


def scopes_path():
    return cfg_path("VAULT_SHARE_SCOPES", SCOPES_PATH)


def runtime_dir():
    if TEST and os.environ.get("VAULT_SHARE_RUNTIME"):
        return Path(os.environ["VAULT_SHARE_RUNTIME"])
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "vault-share"


def rbw_bin():
    if TEST and os.environ.get("RBW_BIN"):
        return os.environ["RBW_BIN"]
    return "/usr/bin/rbw"


def tune(var, default):
    if TEST and os.environ.get(var):
        try:
            return float(os.environ[var])
        except ValueError:
            pass
    return default


def log(msg):
    print("vault-share: " + msg, file=sys.stderr, flush=True)


def clean_line(s, limit=200):
    return re.sub(r"[^\x21-\x7e]", "_", str(s))[:limit]


# ───────────────────────────── scope file ─────────────────────────────

class ScopeFile:
    """/etc/vault-share/scopes.tsv, re-read when its (mtime, size, inode) changes. Trusted only when root owns it, nobody else can
    write it, it is no symlink and its directory is root-owned and not group/other-writable; anything else fails closed."""

    def __init__(self):
        self.key, self.rules, self.problem, self.warned = None, {}, "", None

    def load(self):
        path = scopes_path()
        try:
            st = os.lstat(path)
            dst = os.lstat(path.parent)
        except OSError as e:
            return self._bad(f"scope file unreadable ({e.strerror})")
        want_uid = os.getuid() if TEST else 0
        if not stat.S_ISREG(st.st_mode):
            return self._bad("scope file is not a regular file")
        if st.st_uid != want_uid or st.st_mode & 0o022:
            return self._bad("scope file is not owned by root or is group/other-writable")
        if not stat.S_ISDIR(dst.st_mode) or dst.st_uid != want_uid or dst.st_mode & 0o022:
            return self._bad("scope directory is not root-owned or is group/other-writable")
        key = (st.st_mtime_ns, st.st_size, st.st_ino)
        if key == self.key:
            return not self.problem
        self.key = key
        try:
            rules, problems = parse_rules(path.read_text())
        except OSError as e:
            return self._bad(f"scope file unreadable ({e.strerror})")
        if problems:
            return self._bad("scope file invalid: " + problems[0])
        self.rules, self.problem = rules, ""
        return True

    def _bad(self, why):
        self.rules, self.key = {}, None
        self.problem = why
        if self.warned != why:
            log("unavailable: " + why)
            self.warned = why
        return False


# ───────────────────────────── TOTP (RFC 6238) ─────────────────────────────

def totp_now(seed, now=None):
    """-> (code, period, seconds left) from an otpauth:// URI or a bare base32 secret; ValueError for anything else (steam://...)."""
    seed = (seed or "").strip()
    digits, period, algo = 6, 30, "sha1"
    if seed.lower().startswith("otpauth://"):
        u = urllib.parse.urlparse(seed)
        if u.hostname and u.hostname.lower() != "totp":
            raise ValueError("not a TOTP URI")
        q = {k.lower(): v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        secret = q.get("secret", "")
        try:
            digits = int(q.get("digits", 6))
            period = int(q.get("period", 30))
        except ValueError:
            raise ValueError("bad digits or period")
        algo = q.get("algorithm", "sha1").lower().replace("-", "")
    elif "://" in seed:
        raise ValueError("unsupported seed format")
    else:
        secret = seed
    if algo not in ("sha1", "sha256", "sha512") or digits not in (6, 7, 8) or not 1 <= period <= 300:
        raise ValueError("unsupported TOTP parameters")
    secret = re.sub(r"[\s-]", "", secret).upper()
    try:
        key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    except Exception:
        raise ValueError("bad secret")
    if not key:
        raise ValueError("empty secret")
    now = time.time() if now is None else now
    counter = int(now // period)
    mac = hmac.new(key, struct.pack(">Q", counter), getattr(hashlib, algo)).digest()
    off = mac[-1] & 15
    num = (struct.unpack(">I", mac[off:off + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
    return str(num).zfill(digits), period, int(period - now % period)


# ───────────────────────────── rate limits ─────────────────────────────

WINDOWS = {"meta": ((60, 60), (1200, 3600)), "read": ((120, 60), (1200, 3600)), "totp": ((10, 60),),
           "write": ((6, 60), (60, 3600))}
MISS_LIMIT, PAUSE = 20, 900.0


class Rates:
    """Sliding windows per uid in $XDG_RUNTIME_DIR/vault-share/rate.json (600 in a 700 directory), so a restart of the broker
    resets nothing. kinds: meta, read, totp (extra) and miss (not_found, policy, ambiguous: 20 per hour, then a 15 minute pause
    for every op)."""

    def __init__(self, clock=time.time):
        self.clock = clock
        self.path = runtime_dir() / "rate.json"
        self.data = {}
        try:
            self.data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.data = {}

    def save(self):
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(self.path.parent, 0o700)
            tmp = self.path.with_name(f"rate.json.tmp{os.getpid()}")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(self.data, f)
            os.replace(tmp, self.path)
        except OSError:
            pass

    def entry(self, uid):
        row = self.data.setdefault(str(uid), {"meta": [], "read": [], "totp": [], "miss": [], "paused": 0})
        row.setdefault("write", [])
        return row

    def prune(self, e, now):
        for k in ("meta", "read", "totp", "write", "miss"):
            e[k] = [t for t in e[k] if now - t < 3600]

    def paused(self, uid):
        e = self.entry(uid)
        left = e["paused"] - self.clock()
        return left if left > 0 else 0

    def take(self, uid, kind, cost=1):
        """None when allowed (and counted), else the seconds to wait."""
        now = self.clock()
        e = self.entry(uid)
        self.prune(e, now)
        if e["paused"] > now:
            return e["paused"] - now
        for lim, span in WINDOWS[kind]:
            recent = [t for t in e[kind] if now - t < span]
            if len(recent) + cost > lim:
                return max(1.0, span - (now - recent[0])) if recent else float(span)
        e[kind] += [now] * cost
        self.save()
        return None

    def take_totp(self, uid):
        now = self.clock()
        e = self.entry(uid)
        self.prune(e, now)
        lim, span = WINDOWS["totp"][0]
        recent = [t for t in e["totp"] if now - t < span]
        if len(recent) + 1 > lim:
            return max(1.0, span - (now - recent[0]))
        e["totp"].append(now)
        self.save()
        return None

    def miss(self, uid):
        """Count a miss; True when this one starts the pause."""
        now = self.clock()
        e = self.entry(uid)
        self.prune(e, now)
        e["miss"].append(now)
        started = len(e["miss"]) > MISS_LIMIT and e["paused"] <= now
        if started:
            e["paused"] = now + PAUSE
            e["miss"] = []
        self.save()
        return started

    def notified(self, key, within):
        now = self.clock()
        n = self.data.setdefault("notified", {})
        if now - n.get(key, 0) < within:
            return True
        n[key] = now
        self.save()
        return False


# ───────────────────────────── broker ─────────────────────────────

TYPE_NAMES = {"login": "login", "securenote": "note", "note": "note", "card": "card", "identity": "identity", "sshkey": "ssh", "ssh": "ssh"}
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
BUILTIN = {"login": {"username", "password", "uris", "notes"}, "note": {"notes"},
           "card": {"cardholder_name", "brand", "number", "exp_month", "exp_year", "code", "notes"},
           "identity": {"title", "first_name", "middle_name", "last_name", "email", "phone", "address1", "address2", "address3",
                        "city", "state", "postal_code", "country", "company", "ssn", "username", "passport_number",
                        "license_number", "notes"},
           "ssh": {"public_key", "fingerprint", "private_key", "notes"}}
ALL_BUILTIN = set().union(*BUILTIN.values())
FIELD_RE = re.compile(r"^(?:[a-z0-9_]{1,40}|field:.{1,100})$")


class Err(Exception):
    def __init__(self, code, message, **extra):
        super().__init__(message)
        self.code, self.message, self.extra = code, message, extra


MESSAGES = {
    "locked": "the owner's vault is locked: nothing can be read until he unlocks it (any vault action on his desktop)",
    "not_found": "no such item in your scope",
}


def norm_host(uri):
    u = (uri or "").strip()
    if not u:
        return ""
    p = urllib.parse.urlparse(u if "://" in u else "//" + u)
    h = (p.hostname or "").lower()
    return h[4:] if h.startswith("www.") else h


def entry_type(raw):
    return TYPE_NAMES.get(str(raw.get("type") or raw.get("entry_type") or "").replace("_", "").lower(), "login")


def rec_type(rec):
    """The item type of a `rbw get --raw` record. It has no type key (only the data shape differs), so use the list's `type` when
    there is one, else the keys of `data`."""
    if rec.get("type") or rec.get("entry_type"):
        return entry_type(rec)
    d = rec.get("data")
    if not isinstance(d, dict) or not d:
        return "note"
    if "private_key" in d or "fingerprint" in d:
        return "ssh"
    if "cardholder_name" in d or "brand" in d:
        return "card"
    if "first_name" in d or "last_name" in d:
        return "identity"
    return "login"


def uri_list(data):
    out = []
    for u in (data or {}).get("uris") or []:
        out.append(u.get("uri") if isinstance(u, dict) else u)
    return [x for x in out if x]


class Broker:
    def __init__(self):
        self.scopes = ScopeFile()
        self.rates = Rates()
        self.last_sync = None
        self.last_conn = time.monotonic()
        self.per_uid = {}
        self.total = 0
        self.owner_uid = os.getuid()
        self.idle = tune("VAULT_SHARE_IDLE", 600.0)
        self.max_stale = tune("VAULT_SHARE_MAX_STALE", 600.0)
        self.peer_file = os.environ.get("VAULT_SHARE_TEST_PEER_FILE") if TEST else None
        spec = importlib.util.spec_from_file_location('vault_share_write', HERE / 'vault-share-write.py')
        self.write_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.write_module)
        self.write_policy = self.write_module.WritePolicy(
            cfg_path('VAULT_SHARE_WRITE_POLICY', '/etc/vault-share/env-write.tsv'),
            test_root=TEST['scratch'] if TEST else None)
        self.write_lock = asyncio.Lock()

    async def verify_write(self, ident, uid, name, msg, deadline):
        await self.prompt_guard()
        if not await self.unlocked():
            raise self.write_module.WriteError('locked')
        rc, _ = await self.rbw('sync', timeout=min(15, max(0.01, deadline - time.monotonic())))
        if rc != 0:
            raise self.write_module.WriteError()
        resolved, rec = await self.resolve({'id': ident}, name)
        if (resolved != ident or rec.get('folder') != 'Users/' + name + '/Env/' + msg['project']
                or rec.get('name') != msg['env'] or rec_type(rec) != 'note'):
            raise self.write_module.WriteError('pending')
        for key, value in msg['values'].items():
            if self.value_of(rec, 'field:' + key)[0] != value:
                raise self.write_module.WriteError('pending')

    async def op_env_put(self, msg, uid, name):
        module = self.write_module
        try:
            module.request_data(msg)
            if not self.write_policy.allows(uid, name):
                raise module.WriteError('policy', 'policy')
            wait = self.rates.take(uid, 'write')
            if wait is not None:
                raise Err('rate_limited', 'too many writes', retry_after=int(wait) + 1)
            async with self.write_lock:
                loop = asyncio.get_running_loop()
                def verify(ident, peer_uid, peer_name, request, deadline):
                    future = asyncio.run_coroutine_threadsafe(self.verify_write(ident, peer_uid, peer_name, request, deadline), loop)
                    try:
                        future.result(timeout=max(0.01, deadline - time.monotonic()))
                    except BaseException:
                        future.cancel()
                        raise module.WriteError('pending', 'read-visibility') from None
                # Pending operations and spent UUIDs survive broker/session restarts and reboots.
                state = Path(os.environ.get('XDG_STATE_HOME') or (Path.home() / '.local/state'))
                engine = module.Writer(state / 'vault-share/env-write', self.write_policy.allows, verify=verify)
                body = await asyncio.to_thread(engine.run, msg, uid, name)
                return body, body['id'], ','.join(body['names'])
        except module.WriteError as error:
            raise Err(error.code, 'env write ' + error.code + ' (stage=' + error.stage + ')', stage=error.stage) from None

    # identity -----------------------------------------------------------------------------------
    def identity(self, writer):
        """-> (uid, name, pid). The fake peer hook (verified test mode only) replaces the SO_PEERCRED identity by a user name."""
        sock = writer.get_extra_info("socket")
        pid, uid, _gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        if self.peer_file:
            try:
                name = Path(self.peer_file).read_text().strip()
            except OSError:
                name = ""
            if name == "owner":
                return self.owner_uid, pwd.getpwuid(self.owner_uid).pw_name, pid
            if name == "root":
                return 0, "root", pid
            try:
                return pwd.getpwnam(name).pw_uid, name, pid
            except KeyError:
                return 59999, name, pid
        try:
            return uid, pwd.getpwuid(uid).pw_name, pid
        except KeyError:
            return uid, f"uid{uid}", pid

    # rbw ----------------------------------------------------------------------------------------
    async def rbw(self, *args, timeout=10):
        env = {"PATH": "/usr/bin", "LANG": os.environ.get("LANG", "C.UTF-8"), "HOME": str(Path.home()),
               "RBW_AGENT": "/usr/bin/false", "PINENTRY_USER_DATA": "vault-share:no-prompt"}
        for k in ("XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            if os.environ.get(k):
                env[k] = os.environ[k]
        if TEST:
            env["PATH"] = os.environ.get("PATH", "/usr/bin")
            for k in ("FAKE_DIR", "VAULT_RBW_CONF"):
                if os.environ.get(k):
                    env[k] = os.environ[k]
        try:
            proc = await asyncio.create_subprocess_exec(
                rbw_bin(), *args, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, env=env, start_new_session=True)
            out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            await proc.communicate()       # reap the killed child and drain its pipes before returning
            raise Err("unavailable", "rbw did not answer in time")
        except OSError:
            raise Err("unavailable", "rbw is not installed")
        finally:
            self.sweep_cgroup()
        return proc.returncode, out

    def sweep_cgroup(self):
        """An rbw-agent that was started by one of our rbw calls (the owner's agent normally lives in his session) would live in
        this unit's cgroup: kill it and say so."""
        try:
            rel = Path("/proc/self/cgroup").read_text().strip().split("::", 1)[1]
            if not rel.endswith("/vault-share.service"):
                return       # metadata-only CLI checks must never sweep the caller's session cgroup
            procs = Path("/sys/fs/cgroup" + rel + "/cgroup.procs").read_text().split()
        except (OSError, IndexError):
            return
        for p in procs:
            try:
                if int(p) != os.getpid() and Path(f"/proc/{p}/comm").read_text().strip() == "rbw-agent":
                    os.kill(int(p), 9)
                    log(f"killed an rbw-agent (pid {p}) that started inside this unit")
            except (OSError, ValueError):
                pass

    async def prompt_guard(self):
        # rbw-agent reloads the configured pinentry for each prompt; require our marker-aware wrapper before any read/sync.
        # config show is local metadata only and cannot start/unlock an agent. Never echo the config (email/server).
        rc, out = await self.rbw("config", "show", timeout=5)
        try:
            configured = json.loads(out).get("pinentry") if rc == 0 else None
            expected = REPO / ".local/bin/pinentry-themed"
            supported = isinstance(configured, str) and Path(configured).is_absolute() and Path(configured).resolve() == expected.resolve()
            supported = supported and os.access(expected, os.X_OK)
        except (ValueError, AttributeError, OSError, RuntimeError):
            supported = False
        if not supported:
            raise Err("unavailable", "rbw needs the supported pinentry-themed wrapper; the owner runs bw-setup")

    async def read_failed(self):
        # A lock/agent-exit race after unlocked is locked, while absent/out-of-scope items remain indistinguishable.
        if not await self.unlocked():
            raise Err("locked", MESSAGES["locked"])
        raise Err("not_found", MESSAGES["not_found"])

    async def unlocked(self):
        try:
            rc, _ = await self.rbw("unlocked", timeout=5)
        except Err:
            return False
        return rc == 0

    async def ensure_fresh(self):
        now = time.monotonic()
        if self.last_sync is None or now - self.last_sync > self.max_stale:
            try:
                rc, _ = await self.rbw("sync")
            except Err:
                rc = 1
            if rc != 0:
                log("rbw sync failed: serving the local copy")
            self.last_sync = now

    async def rbw_json(self, *args):
        rc, out = await self.rbw(*args)
        if rc != 0:
            await self.read_failed()
        try:
            return json.loads(out or "null")
        except ValueError:
            raise Err("unavailable", "rbw returned something unexpected")

    async def listing(self):
        rows = await self.rbw_json("list", "--raw")
        return rows if isinstance(rows, list) else []

    # ops ----------------------------------------------------------------------------------------
    def user_rules(self, name):
        return self.scopes.rules.get(name)

    async def resolve(self, msg, name):
        """-> (id, raw record) of an item inside the scope. One `rbw get --raw ID`; the scope is checked on that response."""
        if "id" in msg:
            ident = msg["id"]
            if not isinstance(ident, str) or not ID_RE.match(ident):
                raise Err("bad_request", "bad id")
        else:
            folder, nm = msg.get("folder"), msg.get("name")
            if not isinstance(folder, str) or not isinstance(nm, str) or not folder or not nm:
                raise Err("bad_request", "give id, or folder and name")
            rules = self.user_rules(name)
            hits = [r for r in await self.listing()
                    if in_scope(rules, r.get("folder"), r.get("name")) and nfc(r.get("folder") or "") == nfc(folder)
                    and nfc(r.get("name") or "") == nfc(nm) and r.get("id")]
            if not hits:
                raise Err("not_found", MESSAGES["not_found"])
            if len(hits) > 1:
                raise Err("ambiguous", f"{len(hits)} items called {nm} in {folder}: use the id (vault-share list)")
            ident = hits[0]["id"]
        rc, out = await self.rbw("get", "--raw", ident)
        if rc != 0:
            await self.read_failed()
        try:
            rec = json.loads(out) if rc == 0 else None
        except ValueError:
            rec = None
        if not isinstance(rec, dict) or rec.get("id") != ident or not in_scope(self.user_rules(name), rec.get("folder"), rec.get("name")):
            raise Err("not_found", MESSAGES["not_found"])
        return ident, rec

    @staticmethod
    def marker(rec):
        for f in rec.get("fields") or []:
            if f.get("name") == MARKER:
                return {x.strip() for x in str(f.get("value") or "").split(",") if x.strip()}
        return set()

    @staticmethod
    def value_of(rec, field):
        """-> (value or None, kind) kind builtin|custom."""
        data = rec.get("data") or {}
        if field.startswith("field:"):
            nm = field[6:]
            for f in rec.get("fields") or []:
                if f.get("name") == nm:
                    return f.get("value"), "custom"
            return None, "custom"
        if field == "notes":
            return rec.get("notes"), "builtin"
        if field == "uris":
            u = uri_list(data)
            return "\n".join(u) if u else None, "builtin"
        return data.get(field), "builtin"

    def describe(self, rec):
        t = rec_type(rec)
        data = rec.get("data") or {}
        mark = self.marker(rec)
        has_seed = bool(data.get("totp"))
        ssh_priv = bool(data.get("private_key")) if t == "ssh" else False
        fields = []
        for nm in sorted(BUILTIN[t]):
            if nm == "private_key" and "ssh" not in mark:
                continue
            v, _ = self.value_of(rec, nm)
            fields.append({"name": nm, "set": bool(v)})
        for f in rec.get("fields") or []:
            fields.append({"name": "field:" + str(f.get("name")), "set": bool(f.get("value")),
                           "hidden": str(f.get("type")).lower() in ("hidden", "1")})
        return {"id": rec.get("id"), "folder": rec.get("folder"), "name": rec.get("name"), "type": t,
                "totp": ("shared" if "totp" in mark else "refused") if has_seed else "none",
                "ssh_private": ("shared" if "ssh" in mark else "refused") if ssh_priv else "none",
                "fields": fields}

    async def op_list(self, msg, name):
        rules = self.user_rules(name)
        folder = msg.get("folder")
        if folder is not None and (not isinstance(folder, str) or not folder):
            raise Err("bad_request", "bad folder")
        out = []
        for r in await self.listing():
            if not in_scope(rules, r.get("folder"), r.get("name")) or not r.get("id"):
                continue
            f = nfc(r.get("folder") or "")
            if folder and not (f == nfc(folder) or f.startswith(nfc(folder) + "/")):
                continue
            out.append({"id": r["id"], "folder": r.get("folder"), "name": r.get("name"), "type": entry_type(r),
                        "user": r.get("user") or "", "hosts": sorted({h for h in (norm_host(u if isinstance(u, str) else (u or {}).get("uri"))
                                                                              for u in r.get("uris") or []) if h})})
        out.sort(key=lambda x: (x["folder"] or "", (x["name"] or "").casefold(), x["id"]))
        return {"count": len(out), "items": out}, None, "-"

    async def op_describe(self, msg, name):
        ident, rec = await self.resolve(msg, name)
        return {"item": self.describe(rec)}, ident, "-"

    def fields_of(self, msg):
        fl = msg.get("fields")
        if fl is None and isinstance(msg.get("field"), str):
            fl = [msg["field"]]
        if not isinstance(fl, list) or not 1 <= len(fl) <= 64 or not all(isinstance(x, str) and FIELD_RE.match(x) for x in fl):
            raise Err("bad_request", "fields: 1 to 64 field names")
        return list(dict.fromkeys(fl))

    async def op_get(self, msg, name):
        fields = self.fields_of(msg)
        for f in fields:
            if f in ("totp", "history"):
                raise Err("policy", "TOTP seeds are never served; codes only for items with the custom field vault-share: totp")
        ident, rec = await self.resolve(msg, name)
        t = rec_type(rec)
        mark = self.marker(rec)
        values, missing = {}, []
        for f in fields:
            if f == "private_key" and "ssh" not in mark:
                raise Err("policy", "SSH private keys are served only for items marked vault-share: ssh")
            if not f.startswith("field:") and f not in ALL_BUILTIN:
                raise Err("bad_request", f"unknown field {f}")
            v, _ = self.value_of(rec, f)
            if v in (None, "") or (not f.startswith("field:") and f not in BUILTIN[t]):
                missing.append(f)
            else:
                values[f] = v
        return {"id": ident, "values": values, "missing": missing}, ident, ",".join(clean_line(f, 60) for f in fields)

    async def op_totp(self, msg, name):
        ident, rec = await self.resolve(msg, name)
        if "totp" not in self.marker(rec):
            raise Err("policy", "TOTP seeds are never served; codes only for items with the custom field vault-share: totp")
        seed = (rec.get("data") or {}).get("totp")
        if not seed:
            raise Err("not_found", "this item has no TOTP seed")
        try:
            code, period, left = totp_now(seed)
        except ValueError as e:
            raise Err("policy", f"this TOTP seed cannot be used: {e}")
        return {"id": ident, "code": code, "period": period, "left": left}, ident, "totp"

    # request handling ---------------------------------------------------------------------------
    async def dispatch(self, msg, uid, name):
        if msg.get("v") != 1:
            raise Err("bad_request", "v must be 1")
        op = msg.get("op")
        if op == 'env-put':
            if self.rates.paused(uid):
                raise Err('rate_limited', 'paused after too many refused requests')
            return await self.op_env_put(msg, uid, name)
        if op not in ("whoami", "list", "describe", "get", "totp"):
            raise Err("bad_request", "unknown op")
        wait = self.rates.paused(uid)
        if wait:
            raise Err("rate_limited", "paused after too many refused requests", retry_after=int(wait) + 1)
        if op == "whoami":
            wait = self.rates.take(uid, "meta")
            if wait is not None:
                raise Err("rate_limited", "too many requests", retry_after=int(wait) + 1)
            up = await self.unlocked()
            rules = [rule_text(r) for r in self.user_rules(name) or []]
            return {"user": name, "uid": uid, "rules": rules, "vault": "unlocked" if up else "locked"}, None, "-"
        if op == "get":
            cost = len(self.fields_of(msg))
            kind = "read"
        elif op == "totp":
            cost, kind = 1, "read"
        else:
            cost, kind = 1, "meta"
        wait = self.rates.take(uid, kind, cost)
        if wait is None and op == "totp":
            wait = self.rates.take_totp(uid)
        if wait is not None:
            raise Err("rate_limited", "too many requests", retry_after=int(wait) + 1)
        if not await self.unlocked():
            if not self.rates.notified(f"locked:{name}", 600):
                notify(f"{name} is waiting for the vault (locked)", "vault-share: unlock it with any vault action")
            raise Err("locked", MESSAGES["locked"])
        await self.prompt_guard()
        await self.ensure_fresh()
        fn = {"list": self.op_list, "describe": self.op_describe, "get": self.op_get, "totp": self.op_totp}[op]
        return await fn(msg, name)

    async def handle(self, reader, writer):
        t0 = time.monotonic()
        self.last_conn = t0
        uid, name, pid = -1, "?", 0
        op, ident, fields, result = "-", "-", "-", "error"
        gate = None
        try:
            uid, name, pid = self.identity(writer)
            if uid == self.owner_uid or uid == 0:
                resp = {"ok": False, "v": 1, "error": "refused",
                        "message": f"uid {uid} is the owner: use rbw directly" if uid == self.owner_uid else f"uid {uid} has no vault scope"}
                result = "refused"
            elif not self.scopes.load():
                resp = {"ok": False, "v": 1, "error": "unavailable", "message": "the scope file is missing or invalid"}
                result = "unavailable"
            elif not self.user_rules(name):
                resp = {"ok": False, "v": 1, "error": "refused", "message": f"uid {uid} has no vault scope"}
                result = "refused"
            elif self.per_uid.get(uid, 0) >= 4 or self.total >= 16:
                resp = {"ok": False, "v": 1, "error": "rate_limited", "message": "too many connections", "retry_after": 1}
                result = "rate_limited"
            else:
                self.per_uid[uid] = self.per_uid.get(uid, 0) + 1
                self.total += 1
                gate = uid
                try:
                    cap = MAX_WRITE_REQUEST if self.write_policy.allows(uid, name) else MAX_REQUEST
                    reader._limit = cap
                    line = await asyncio.wait_for(reader.readline(), 5)
                    if len(line) > cap or not line.endswith(b"\n"):
                        raise ValueError
                    msg = json.loads(line)
                    if not isinstance(msg, dict):
                        raise ValueError
                    if msg.get('op') != 'env-put' and len(line) > MAX_REQUEST:
                        raise ValueError
                except (ValueError, asyncio.TimeoutError, asyncio.LimitOverrunError):
                    msg = None
                if msg is None:
                    resp = {"ok": False, "v": 1, "error": "bad_request", "message": "bad request"}
                    result = "bad_request"
                else:
                    op = clean_line(msg.get("op"), 20) if isinstance(msg.get("op"), str) else "-"
                    try:
                        body, ident, fields = await self.dispatch(msg, uid, name)
                        resp = {"ok": True, "v": 1, **body}
                        result = "ok"
                    except Err as e:
                        resp = {"ok": False, "v": 1, "error": e.code, "message": e.message, **e.extra}
                        result = e.code
                        if "id" in msg and isinstance(msg["id"], str):
                            ident = clean_line(msg["id"], 64)
                        if e.code in ("not_found", "policy", "ambiguous") and self.rates.miss(uid):
                            notify(f"vault-share: {name} made {MISS_LIMIT} refused requests in an hour",
                                   "paused for 15 minutes")
            writer.write(json.dumps(resp).encode() + b"\n")
            await writer.drain()
        except (ConnectionError, OSError):
            pass
        except Exception as e:     # never crash the service on one request, never leak details
            log(f"internal error {type(e).__name__}")
            try:
                writer.write(b'{"ok":false,"v":1,"error":"internal","message":"internal error"}\n')
                await writer.drain()
            except OSError:
                pass
        finally:
            if gate is not None:
                self.per_uid[gate] -= 1
                self.total -= 1
            writer.close()
            ms = int((time.monotonic() - t0) * 1000)
            comm = ""
            try:
                comm = clean_line(Path(f"/proc/{pid}/comm").read_text().strip(), 20)
            except OSError:
                pass
            log(f"op={op} user={clean_line(name, 32)} uid={uid} pid={pid} comm={comm or '-'} id={ident} fields={fields} "
                f"result={result} ms={ms}")

    async def idle_watch(self, server):
        while True:
            await asyncio.sleep(max(0.2, min(5.0, self.idle / 4)))
            if time.monotonic() - self.last_conn > self.idle and self.total == 0:
                log("idle: exiting (the socket stays with systemd)")
                server.close()
                return

    async def serve(self):
        fds = int(os.environ.get("LISTEN_FDS", "0")) if os.environ.get("LISTEN_PID") == str(os.getpid()) else 0
        if fds >= 1:
            s = socket.socket(fileno=3)
            s.setblocking(False)
            # systemd owns the pathname; closing our inherited descriptor must not unlink it.
            server = await asyncio.start_unix_server(self.handle, sock=s, limit=MAX_WRITE_REQUEST, cleanup_socket=False)
        elif TEST:
            path = sock_path()
            path.parent.mkdir(parents=True, exist_ok=True)
            path.unlink(missing_ok=True)
            old = os.umask(0o111)
            try:
                server = await asyncio.start_unix_server(self.handle, path=str(path), limit=MAX_WRITE_REQUEST)
            finally:
                os.umask(old)
            os.chmod(path, 0o666)
        else:
            raise SystemExit("vault-share serve: no socket from systemd (LISTEN_FDS); start vault-share.socket")
        log(f"ready: scopes {scopes_path()}, idle exit {int(self.idle)} s")
        watch = asyncio.ensure_future(self.idle_watch(server))
        try:
            await server.serve_forever()
        except asyncio.CancelledError:
            pass
        finally:
            watch.cancel()


def notify(title, body=""):
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-a", "vault-share", "-u", "low", "-t", "8000", "-h", "string:x-dunst-stack-tag:vault-share",
                        title, body], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def init_userns():
    """SO_PEERCRED reports the uid as seen from the broker's user namespace. PrivateUsers=yes (implied by ProtectSystem, ProtectHome,
    PrivateTmp, ... in a USER unit) would map td and yc both to 65534: refuse to serve then."""
    path = Path(os.environ["VAULT_SHARE_TEST_UIDMAP"]) if TEST and os.environ.get("VAULT_SHARE_TEST_UIDMAP") else Path("/proc/self/uid_map")
    try:
        parts = path.read_text().split()
    except OSError:
        parts = []
    if parts != ["0", "0", "4294967295"]:
        raise SystemExit("vault-share: refusing to serve inside a user namespace (uid_map " + " ".join(parts) + "): "
                         "SO_PEERCRED could not tell td from yc; the unit must not use Protect*/Private* options")


def harden():
    try:
        import ctypes
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(4, 0, 0, 0, 0)       # PR_SET_DUMPABLE 0
    except (OSError, AttributeError):
        pass


def cmd_serve(argv):
    harden()
    init_userns()
    asyncio.run(Broker().serve())
    return 0


# ───────────────────────────── client ─────────────────────────────

class ShareError(Exception):
    exit_code = 1

    def __init__(self, message, **extra):
        super().__init__(message)
        self.extra = extra


class Locked(ShareError):
    exit_code = 3


class NotFound(ShareError):
    exit_code = 1


class Policy(ShareError):
    exit_code = 4


class RateLimited(ShareError):
    exit_code = 5


class Unavailable(ShareError):
    exit_code = 6


ERRORS = {"locked": Locked, "not_found": NotFound, "ambiguous": NotFound, "policy": Policy, "refused": Policy,
          "conflict": Policy, "pending": Policy,
          "rate_limited": RateLimited, "unavailable": Unavailable, "bad_request": ShareError, "internal": ShareError}


def managed_account():
    """My name when I am a non-service row of this checkout's managed.tsv (REPO is /srv/dotfiles for td), else None."""
    if TEST and os.environ.get("VAULT_SHARE_TEST_AS"):
        return os.environ["VAULT_SHARE_TEST_AS"]
    try:
        me = pwd.getpwuid(os.getuid()).pw_name
        for line in (REPO / "infrastructure/users/managed.tsv").read_text().splitlines():
            c = line.split("\t")
            if line.strip() and not line.startswith("#") and len(c) >= 3 and c[0] == me and "service" not in c[2].split(","):
                return me
    except OSError:
        pass
    return None


class Client:
    def __init__(self, path=None, allow_self=False):
        self.path = Path(path) if path else sock_path()
        self.allow_self = allow_self or bool(TEST and os.environ.get("VAULT_SHARE_TEST_AS"))

    def request(self, msg, timeout=30):
        raw = json.dumps(msg).encode() + b'\n'
        writing = msg.get('op') == 'env-put'
        if len(raw) > (MAX_WRITE_REQUEST if writing else MAX_REQUEST):
            raise ShareError('request is too large')
        if writing and timeout == 30:
            timeout = 90
        d = self.path.parent
        try:
            st = os.lstat(d)
        except OSError:
            raise Unavailable(f"{d} does not exist: the owner runs `sudo ./apply-system.sh --only users`")
        if not stat.S_ISDIR(st.st_mode) or st.st_mode & 0o022 or (st.st_uid == os.getuid() and not self.allow_self):
            raise Unavailable(f"{d} is not the owner's broker directory (symlink, group/other-writable or your own)")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            try:
                s.connect(str(self.path))
            except OSError as e:
                raise Unavailable(f"cannot connect to {self.path} ({e.strerror}): is vault-share.socket running?")
            _pid, uid, _gid = struct.unpack("3i", s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            if uid != st.st_uid:
                raise Unavailable(f"{self.path} is served by uid {uid}, not by the owner of {d}")
            s.sendall(raw)
            buf = b""
            while not buf.endswith(b"\n") and len(buf) < 4 * 1024 * 1024:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            raise Unavailable("the broker did not answer in time")
        finally:
            s.close()
        try:
            resp = json.loads(buf)
        except ValueError:
            raise Unavailable("the broker answered something unexpected")
        if not isinstance(resp, dict):
            raise Unavailable("the broker answered something unexpected")
        if not resp.get("ok"):
            extra = {k: resp[k] for k in ("retry_after",) if k in resp}
            if writing:
                code, stage = resp.get('error'), resp.get('stage')
                extra['code'] = code if isinstance(code, str) and code in WRITE_CODES else 'unknown'
                extra['stage'] = stage if isinstance(stage, str) and stage in WRITE_STAGES else 'unknown'
                raise ERRORS.get(extra['code'], ShareError)('env write ' + extra['code'] + ' (stage=' + extra['stage'] + ')', **extra)
            raise ERRORS.get(resp.get("error"), ShareError)(resp.get("message") or "error", **extra)
        return resp


# ───────────────────────────── CLI ─────────────────────────────

def opt(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def cmd_check_scopes(argv):
    if not argv:
        print("usage: vault-share.py check-scopes FILE [--owner NAME]", file=sys.stderr)
        return 2
    try:
        text = Path(argv[0]).read_text()
    except OSError as e:
        print(f"cannot read {argv[0]}: {e.strerror}", file=sys.stderr)
        return 4
    rules, problems = parse_rules(text, owner=opt(argv, "--owner"))
    for p in problems:
        print(p, file=sys.stderr)
    if problems:
        return 4
    print(f"ok: {sum(len(v) for v in rules.values())} rules for {len(rules)} users")
    return 0


def cmd_render_scopes(argv):
    repo, local, managed, owner = opt(argv, "--repo"), opt(argv, "--local"), opt(argv, "--managed"), opt(argv, "--owner")
    if not (repo and owner and managed is not None):
        print('usage: vault-share.py render-scopes --repo FILE [--local FILE] --managed "td yc" --owner NAME', file=sys.stderr)
        return 2
    try:
        repo_text = Path(repo).read_text()
    except OSError as e:
        print(f"cannot read {repo}: {e.strerror}", file=sys.stderr)
        return 4
    local_text = ""
    if local and os.path.lexists(local):
        ok, why = trusted_local_file(local, os.getuid())
        if ok:
            local_text = Path(local).read_text()
        else:
            print(f"warning: {local} ignored: {why}", file=sys.stderr)
    text, warnings, problems = render_scopes(repo_text, local_text, managed.split(), owner)
    for w in warnings:
        print("warning: " + w, file=sys.stderr)
    for p in problems:
        print(p, file=sys.stderr)
    if problems:
        return 4
    sys.stdout.write(text)
    return 0


def envs_lib():
    loader = importlib.machinery.SourceFileLoader("envs_lib", str(REPO / ".local/bin/envs"))
    spec = importlib.util.spec_from_loader("envs_lib", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


def agent():
    try:
        return envs_lib().agent_context()
    except Exception:
        return "unknown (envs not importable)" if os.environ.get("CLAUDECODE") else None


def die(msg, code=1):
    print("vault-share: " + msg, file=sys.stderr)
    return code


def item_spec(spec):
    """An id, or FOLDER/NAME (split at the last /)."""
    if "/" in spec:
        folder, name = spec.rsplit("/", 1)
        return {"folder": folder, "name": name}
    return {"id": spec}


def call(msg):
    return Client().request(msg)


def guard(fn, *a):
    try:
        return fn(*a)
    except ShareError as e:
        extra = f" (retry in {e.extra['retry_after']} s)" if e.extra.get("retry_after") else ""
        return die(str(e) + extra, e.exit_code)


def clipboard_ok():
    wd = os.environ.get("WAYLAND_DISPLAY")
    if not wd or not shutil.which("wl-copy"):
        return False
    path = wd if wd.startswith("/") else os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), wd)
    return os.access(path, os.W_OK)


def vault_copy(text):
    subprocess.run(["wl-copy", "--sensitive"], input=text, text=True, check=True)
    subprocess.run([sys.executable, "-I", str(HERE / "vault-totp.py"), "arm-clear"], check=False)


def cmd_status(argv):
    if not managed_account():
        return cmd_owner_status()
    r = call({"v": 1, "op": "whoami"})
    print(f"user {r['user']} (uid {r['uid']}), vault {r['vault']}")
    for rule in r["rules"]:
        print("  " + rule)
    return 0


def cmd_list(argv):
    msg = {"v": 1, "op": "list"}
    if opt(argv, "--folder"):
        msg["folder"] = opt(argv, "--folder")
    r = call(msg)
    if "--json" in argv:
        print(json.dumps(r["items"], indent=1))
        return 0
    for i in r["items"]:
        print(f"{i['id']}\t{i['folder']}/{i['name']}\t{i['type']}\t{i['user']}\t{','.join(i['hosts'])}")
    print(f"{r['count']} items", file=sys.stderr)
    return 0


def cmd_copy(argv):
    if not argv:
        return die("usage: vault-share copy ITEM [--field F]", 2)
    if not clipboard_ok():
        return die("no clipboard for this user: use `envs run` (values go into the command, not the clipboard)", 4)
    fld = opt(argv, "--field") or "password"
    r = call({"v": 1, **item_spec(argv[0]), "op": "get", "fields": [fld]})
    if fld not in r["values"]:
        return die(f"the item has no {fld}", 1)
    vault_copy(r["values"][fld])
    print(f"{fld} copied (sensitive, cleared in 30 s)")
    return 0


def cmd_code(argv):
    if not argv:
        return die("usage: vault-share code ITEM [--print]", 2)
    r = call({"v": 1, **item_spec(argv[0]), "op": "totp"})
    if "--print" in argv:
        if sys.stdout.isatty() or agent():
            return die("--print writes the code to a pipe only, and never under an agent or to a terminal", 4)
        print(r["code"])
        return 0
    if not clipboard_ok():
        return die("no clipboard for this user: use --print into a pipe", 4)
    vault_copy(r["code"])
    print(f"code copied ({r['left']} s left; sensitive, cleared in 30 s)")
    return 0


def cmd_get(argv):
    fld = opt(argv, "--field")
    if not argv or not fld:
        return die("usage: vault-share get ITEM --field F", 2)
    a = agent()
    if sys.stdout.isatty() or a:
        return die("get writes to a pipe or a file only, never to a terminal and never under an agent"
                   + (f" ({a})" if a else "") + " (leak prevention, not a boundary)", 4)
    r = call({"v": 1, **item_spec(argv[0]), "op": "get", "fields": [fld]})
    if fld not in r["values"]:
        return die(f"the item has no {fld}", 1)
    sys.stdout.write(r["values"][fld])
    return 0


def run_rbw(*args):
    return subprocess.run([rbw_bin(), *args], capture_output=True, text=True)


def cmd_owner_status():
    ok = True

    def line(name, good, detail=""):
        nonlocal ok
        ok = ok and good
        print(f"{'ok  ' if good else 'FAIL'} {name}" + (f": {detail}" if detail else ""))

    sp = scopes_path()
    sf = ScopeFile()
    line("scope file", sf.load(), str(sp) if not sf.problem else sf.problem)
    d = sock_path().parent
    try:
        st = os.lstat(d)
        line("socket directory", stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and not st.st_mode & 0o022, f"{d} {oct(st.st_mode & 0o777)}")
    except OSError:
        line("socket directory", False, f"{d} missing (sudo ./apply-system.sh --only users)")
    if shutil.which("systemctl"):
        r = subprocess.run(["systemctl", "--user", "is-active", "vault-share.socket"], capture_output=True, text=True)
        line("vault-share.socket", r.stdout.strip() == "active", r.stdout.strip() or "unknown")
    for u, rules in sorted(sf.rules.items()):
        print(f"  {u}: {len(rules)} rules")
    return 0 if ok else 1


def cmd_report(argv):
    """Per user: the number of items inside the scope right now, from the owner's rbw (names only with --names)."""
    sf = ScopeFile()
    if not sf.load():
        return die("scope file: " + sf.problem, 1)
    up = run_rbw("unlocked")
    if up.returncode != 0:
        return die("rbw is locked: unlock it first (any vault action)", 3)
    rows = json.loads(run_rbw("list", "--raw").stdout or "[]")
    for u in sorted(sf.rules):
        hit = [r for r in rows if in_scope(sf.rules[u], r.get("folder"), r.get("name"))]
        print(f"{u}: {len(hit)} items in scope")
        if "--names" in argv:
            for r in sorted(hit, key=lambda r: ((r.get("folder") or ""), r.get("name") or "")):
                print(f"    {r.get('folder')}/{r.get('name')}")
    return 0


def cmd_check_rbw(argv):
    if argv:
        return 2
    try:
        # Only local config metadata; do not load scopes or runtime rate state for this doctor check.
        asyncio.run(Broker.__new__(Broker).prompt_guard())
    except Err as e:
        print(e.message, file=sys.stderr)
        return 1
    print("rbw pinentry-themed wrapper supports broker no-prompt requests")
    return 0


def cmd_selftest(argv):
    """Connect as the owner: the broker must answer `refused` and echo the REAL uid (a user namespace would show 65534)."""
    try:
        Client(allow_self=True).request({"v": 1, "op": "whoami"})
    except Policy as e:
        if f"uid {os.getuid()} " in str(e):
            print(f"ok: refused with uid {os.getuid()}")
            return 0
        return die(f"the broker saw another uid than {os.getuid()}: {e}", 1)
    except ShareError as e:
        return die(str(e), 1)
    return die("the broker answered the owner: it must refuse him", 1)


COMMANDS = {"check-scopes": cmd_check_scopes, "render-scopes": cmd_render_scopes, "serve": cmd_serve,
            "status": lambda a: guard(cmd_status, a), "list": lambda a: guard(cmd_list, a),
            "copy": lambda a: guard(cmd_copy, a), "code": lambda a: guard(cmd_code, a), "get": lambda a: guard(cmd_get, a),
            "report": cmd_report, "selftest": cmd_selftest}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    fn = cmd_check_rbw if argv[0] == "check-rbw" else COMMANDS.get(argv[0])
    if fn is None:
        print(f"unknown command {argv[0]}", file=sys.stderr)
        return 2
    return fn(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
