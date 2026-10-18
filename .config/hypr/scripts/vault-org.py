#!/usr/bin/env python3
"""vault-org: tidy the Bitwarden vault into a folder tree without ever displaying a value. Python 3 stdlib only.
Run through `vault-audit` (.local/bin/vault-audit); `vault-audit --help` is this text.

  vault-audit [audit] [--names-hidden] [--json]
                      metadata inventory of every non-deleted item (bw serve, one request) -> counts and findings:
                      items without a folder, duplicate groups (same type + host set / name + username), near-duplicate
                      folders and names, empty folders, problems in the tool folders (Linux, Env/*, MCP). The audit file
                      $XDG_RUNTIME_DIR/vault/org/audit.json (600, tmpfs) holds ids, names, hosts, flags and counts, never a
                      value, a username or a hash. --names-hidden prints ids and hosts only; --json prints the audit file.
  vault-audit plan [--rules FILE] [--force]
                      proposal file ~/.local/state/vault/org-plan.tsv from the last audit and the rules file
  vault-audit review  fzf-menu reviewer of the plan (vim keys, every change saved at once)
  vault-audit apply [--dry-run] [--resume] [--yes]
                      encrypted backup first, then folders, moves, soft-trash of confirmed duplicates (journalled)

Secrets: the audit compares secrets only as HMAC-SHA256 under a key that exists for this process alone (so "same password"
is known, the password and its hash are not kept anywhere); usernames are compared the same way. Nothing secret reaches
argv, the audit file, the plan, a log or a notification. An agent ancestor (claude, codex, ...) never gets a master password
prompt: a closed bw session is exit 3 and the owner runs the tool himself.
Exit codes: 0 ok, 1 error, 2 usage, 3 bw locked (agent or no tty), 4 refused / plan invalid, 5 apply finished with skips.
"""
import hashlib
import hmac
import importlib.machinery
import importlib.util
import fnmatch
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import unicodedata
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]                      # ~/dotfiles for the owner, /srv/dotfiles for managed users
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "vault"
PLAN = STATE / "org-plan.tsv"
JOURNAL = STATE / "org-journal.tsv"
BACKUPS = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "vault-backups"
BW_TYPE = {1: "login", 2: "note", 3: "card", 4: "identity", 5: "ssh"}
SHARE_FIELD = "vault-share"
TOOL_FOLDER_RE = re.compile(r"^(?:(?:Env|Linux|MCP)|(?:Users/[^/]+|Shared)/Env)(?:/|$)")


class Fail(Exception):
    def __init__(self, msg, code=1):
        super().__init__(msg)
        self.msg, self.code = msg, code


# ───────────────────────────── helpers ─────────────────────────────

_mods = {}


def load(name, path):
    if name not in _mods:
        loader = importlib.machinery.SourceFileLoader(name, str(path))
        spec = importlib.util.spec_from_loader(name, loader)
        m = importlib.util.module_from_spec(spec)
        loader.exec_module(m)
        _mods[name] = m
    return _mods[name]


def vbw():
    """vault-bw.py with `die` turned into an exception (it would notify and wait for Enter)."""
    m = load("vault_bw", HERE / "vault-bw.py")

    def die(msg, code=1):
        raise Fail(msg, code)

    m.die = die
    return m


def envs_lib():
    return load("envs_lib", REPO / ".local/bin/envs")


def agent():
    try:
        return envs_lib().agent_context()
    except Exception:       # a broken envs must not turn an agent into a trusted caller
        return "unknown (envs not importable)" if os.environ.get("CLAUDECODE") else None


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def atomic_write(path, text, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(path.name + f".tmp{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def clean(s):
    return re.sub(r"[\t\r\n\x00-\x1f\x7f]", " ", str(s or "")).strip()


def org_dir(m):
    d = m.RUN / "org"
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def audit_path(m):
    return m.RUN / "org" / "audit.json"


def opened_bw(m):
    """The bw session must be open. The owner is asked for the master password (pinentry); under an agent, or with no way to
    ask, a closed session is exit 3."""
    st = m.status()
    if st == "unlocked":
        return
    a = agent()
    if a:
        raise Fail(f"bw is locked: the owner runs vault-audit himself (refused under {a})", 3)
    if st is None:
        raise Fail("bw is not installed (sudo ~/dotfiles/apply-system.sh --only install)", 1)
    m.ensure()


# ───────────────────────────── audit: normalise ─────────────────────────────

def norm_host(uri):
    uri = (uri or "").strip()
    if not uri:
        return ""
    low = uri.lower()
    if low.startswith("androidapp://"):
        return "android:" + low[len("androidapp://"):].strip("/")
    if low.startswith("iosapp://"):
        return "ios:" + low[len("iosapp://"):].strip("/")
    p = urllib.parse.urlparse(uri if "://" in uri else "//" + uri)
    host = (p.hostname or "").lower() if p.netloc or "://" in uri else ""
    if host.startswith("www."):
        host = host[4:]
    return host


# Comparison v1 deliberately refuses data whose preservation cannot be verified. These are bw export/API fields,
# not rbw's reduced record shape. New schema fields require an explicit comparison review before duplicate trash.
COMPARISON_VERSION = 1
TYPE_FIELDS = {
    1: ("login", {"username", "password", "totp", "uris", "fido2Credentials", "passwordRevisionDate"}),
    2: ("secureNote", {"type"}),
    3: ("card", {"cardholderName", "brand", "number", "expMonth", "expYear", "code"}),
    4: ("identity", {"title", "firstName", "middleName", "lastName", "address1", "address2", "address3", "city",
                     "state", "postalCode", "country", "company", "email", "phone", "ssn", "username",
                     "passportNumber", "licenseNumber"}),
    5: ("sshKey", {"privateKey", "publicKey", "keyFingerprint"}),
}
ITEM_FIELDS = {"object", "id", "organizationId", "folderId", "type", "name", "notes", "favorite", "reprompt",
               "fields", "attachments", "passwordHistory", "collectionIds", "revisionDate", "creationDate",
               "deletedDate", "organizationUseTotp", "edit", "viewPassword", "permissions"} | {v[0] for v in TYPE_FIELDS.values()}


def comparison_problem(item):
    spec = TYPE_FIELDS.get(item.get("type"))
    if spec is None or set(item) - ITEM_FIELDS:
        return "unsupported item shape"
    field, allowed = spec
    data = item.get(field)
    if not isinstance(data, dict) or set(data) - allowed:
        return "unsupported type data"
    if any(item.get(k) is not None for k in {v[0] for v in TYPE_FIELDS.values()} - {field}):
        return "unexpected type data"
    if item.get("attachments"):
        return "attachments require verified content equality"
    if item.get("type") == 1 and data.get("fido2Credentials"):
        return "passkeys require a dedicated preservation check"
    for field, allowed in (("fields", {"name", "value", "type", "linkedId"}),
                           ("passwordHistory", {"password", "lastUsedDate"})):
        values = item.get(field) or []
        if not isinstance(values, list) or any(not isinstance(v, dict) or set(v) - allowed for v in values):
            return "unsupported " + field + " shape"
    uris = data.get("uris") or []
    if not isinstance(uris, list) or any(not isinstance(v, dict) or set(v) - {"uri", "match"} for v in uris):
        return "unsupported URI shape"
    return None


def secret_blobs(item):
    """Versioned full comparison payloads, HMACed in memory only. Missing payloads may be subsets; unknown data may not."""
    field = TYPE_FIELDS.get(item.get("type"), (None, None))[0]
    data = dict(item.get(field) or {}) if field else {}
    out = {"notes": item.get("notes"), "fields": item.get("fields"), "history": item.get("passwordHistory")}
    if item.get("type") == 1:
        out.update({k: data.pop(k, None) for k in ("password", "totp", "uris", "username")})
        data.pop("fido2Credentials", None)       # non-empty passkeys are refused above
    out["type-data"] = data
    out["policy"] = {k: item[k] for k in ("organizationId", "collectionIds", "favorite", "reprompt",
                                          "organizationUseTotp", "edit", "viewPassword", "permissions") if k in item}
    return {k: json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False) if v not in (None, "", [], {}) else None
            for k, v in out.items()}


def user_value(item):
    t = BW_TYPE.get(item.get("type"), "login")
    if t == "login":
        return (item.get("login") or {}).get("username")
    if t == "card":
        return (item.get("card") or {}).get("cardholderName")
    if t == "identity":
        i = item.get("identity") or {}
        return i.get("username") or i.get("email")
    return None


def hmac_of(key, value, fold=False):
    if value is None or value == "":
        return None
    v = str(value).strip().casefold() if fold else str(value)
    return hmac.new(key, v.encode(), hashlib.sha256).digest()


def normalise(item, folders, key):
    """-> Meta: JSON-safe fields (kept in the audit file) plus k_* HMACs (memory only, `kx` below)."""
    t = BW_TYPE.get(item.get("type"), "login")
    hosts = sorted({h for h in (norm_host(u.get("uri")) for u in (item.get("login") or {}).get("uris") or []) if h})
    fnames = [f.get("name") or "" for f in item.get("fields") or []]
    blobs = secret_blobs(item)
    meta = {
        "id": item["id"], "type": t, "name": clean(item.get("name")),
        "folder": folders.get(item.get("folderId")) if item.get("folderId") else None,
        "folder_id": item.get("folderId") or None,
        "hosts": hosts, "user": bool(user_value(item)), "totp": bool(blobs.get("totp")),
        "notes": bool(item.get("notes")), "fields": len(fnames), "marker": SHARE_FIELD in fnames,
        "attachments": len(item.get("attachments") or []),
        "revision": item.get("revisionDate") or "", "created": item.get("creationDate") or "",
        "duplicate_review": comparison_problem(item),
    }
    kx = {"user": hmac_of(key, user_value(item)), "comparison_version": COMPARISON_VERSION,
          "unsafe": comparison_problem(item)}
    for kind, v in blobs.items():
        kx[kind] = hmac_of(key, v)
    return meta, kx


# ───────────────────────────── audit: groups and findings ─────────────────────────────

KINDS = ("password", "totp", "notes", "fields", "history", "uris", "username", "type-data", "policy")


def norm_name(name):
    n = unicodedata.normalize("NFKD", name or "").casefold()
    n = re.sub(r"^(?:https?://)?(?:www\.)?", "", n)
    return re.sub(r"[^0-9a-zЀ-ӿ]+", "", n)


def norm_name_notld(name):
    n = unicodedata.normalize("NFKD", name or "").casefold()
    n = re.sub(r"^(?:https?://)?(?:www\.)?", "", n)
    n = re.sub(r"\.[a-z]{2,}(?:/.*)?$", "", n)
    return re.sub(r"[^0-9a-zЀ-ӿ]+", "", n)


def data_rank(m):
    return (m["attachments"], 1 if m["totp"] else 0, 1 if m["notes"] else 0, m["fields"], m["revision"], m["id"])


def relation(ka, kk):
    """How a member (hashes ka) relates to the keep (kk): identical; subset (it only lacks things the keep has); or
    differs:KIND,... (it has a secret, notes, ... the keep does not have or has differently)."""
    if ka.get("comparison_version") != COMPARISON_VERSION or kk.get("comparison_version") != COMPARISON_VERSION:
        return "review:unsupported comparison version"
    if ka.get("unsafe") or kk.get("unsafe"):
        return "review:" + (ka.get("unsafe") or kk["unsafe"])
    diff = [k for k in KINDS if ka.get(k) != kk.get(k)]
    if not diff:
        return "identical"
    if all(ka.get(k) is None for k in diff):
        return "subset"
    return "differs:" + ",".join(k for k in diff if ka.get(k) is not None)


def dup_groups(metas, kxs):
    by_id = {m["id"]: m for m in metas}
    groups, used = [], set()
    # no-user: a login without a username on a host where another item has one, anchored on the item with the username
    host_items = {}
    for m in metas:
        if m["type"] == "login" and m["hosts"]:
            host_items.setdefault(frozenset(m["hosts"]), []).append(m)
    for ms in host_items.values():
        withu = [m for m in ms if m["user"]]
        nou = [m for m in ms if not m["user"]]
        if withu and nou:
            anchor = max(withu, key=lambda m: (m["revision"], m["id"]))
            groups.append({"class": "no-user", "members": [anchor["id"]] + sorted(m["id"] for m in nou), "keep": anchor["id"]})
            used.update(m["id"] for m in nou)
            used.add(anchor["id"])
    buckets = {}
    for m in metas:
        if m["id"] not in used:
            ident = frozenset(m["hosts"]) if m["hosts"] else ("name", norm_name(m["name"]))
            buckets.setdefault((m["type"], ident, kxs[m["id"]]["user"]), []).append(m)
    for ms in buckets.values():
        if len(ms) > 1:
            keep = max(ms, key=data_rank)
            same = all(relation(kxs[m["id"]], kxs[keep["id"]]) == "identical" for m in ms)
            groups.append({"class": "identical" if same else "same-login", "members": [m["id"] for m in ms],
                           "keep": keep["id"]})
    rank = {"identical": 0, "same-login": 1, "no-user": 2}
    groups.sort(key=lambda g: (rank[g["class"]], min(by_id[i]["name"].casefold() for i in g["members"]), min(g["members"])))
    for n, g in enumerate(groups, 1):
        g["id"] = f"g{n}"
        keep = g["keep"]
        g["members"] = [keep] + sorted(i for i in g["members"] if i != keep)
        g["rel"] = {i: "keep" if i == keep else relation(kxs[i], kxs[keep]) for i in g["members"]}
        g["differs"] = [] if g["class"] == "identical" else \
            sorted(k for k in KINDS if len({kxs[i].get(k) for i in g["members"]}) > 1)
    return groups


def folder_findings(metas, folders):
    """folders = [{id, name}], metas as above."""
    counts = {f["id"]: 0 for f in folders}
    for m in metas:
        if m["folder_id"] in counts:
            counts[m["folder_id"]] += 1
    names = {f["id"]: f["name"] for f in folders}
    empty = []
    for f in folders:
        below = sum(c for fid, c in counts.items() if names[fid] == f["name"] or names[fid].startswith(f["name"] + "/"))
        if below == 0:
            empty.append(f["id"])

    def fnorm(n):
        return re.sub(r"[\s_-]+", "", unicodedata.normalize("NFKD", n).casefold())

    by = {}
    for f in folders:
        by.setdefault(fnorm(f["name"]), []).append(f["id"])
    near = sorted(sorted(v) for v in by.values() if len(v) > 1)
    return counts, empty, near


def build_audit(items, trash_count, folders, key, source="bw-serve"):
    folder_name = {f["id"]: f.get("name") or "" for f in folders if f.get("id")}
    metas, kxs = [], {}
    for it in items:
        if it.get("deletedDate"):
            continue
        meta, kx = normalise(it, folder_name, key)
        metas.append(meta)
        kxs[meta["id"]] = kx
    metas.sort(key=lambda m: (m["name"].casefold(), m["id"]))
    free = [m for m in metas if not TOOL_FOLDER_RE.match(m["folder"] or "")]   # tool folders are not tidied (envs, linux-pass, MCP)
    groups = dup_groups(free, kxs)
    fl = [{"id": f["id"], "name": f.get("name") or ""} for f in folders if f.get("id")]
    fl.sort(key=lambda f: (f["name"].casefold(), f["id"]))
    counts, empty, near_f = folder_findings(metas, fl)
    in_group = {}
    for g in groups:
        for i in g["members"]:
            in_group[i] = g["id"]
    near_n = {}
    for m in free:
        n = norm_name_notld(m["name"])
        if n:
            near_n.setdefault(n, []).append(m["id"])
    near_names = []
    for ids in near_n.values():
        gs = {in_group.get(i) for i in ids}
        if len(ids) > 1 and not (len(gs) == 1 and None not in gs):
            near_names.append(sorted(ids))
    near_names.sort()
    tool = []
    users = local_users()
    seen_env = {}
    for m in metas:
        f = m["folder"] or ""
        if f == "Linux":
            if m["type"] != "login":
                tool.append({"id": m["id"], "problem": "Linux item is not a login"})
            elif users is not None and m["name"] not in users:
                tool.append({"id": m["id"], "problem": "Linux item name is not a local user"})
        elif f == "Env" or f.startswith("Env/"):
            if m["type"] != "note":
                tool.append({"id": m["id"], "problem": "Env item is not a secure note"})
            k = (f, m["name"])
            if k in seen_env:
                tool.append({"id": m["id"], "problem": "two items with this name in one Env folder"})
            seen_env[k] = m["id"]
    findings = {
        "no_folder": [m["id"] for m in metas if not m["folder_id"]],
        "tool_folder": tool,
        "empty_folder": [f for f in empty if not TOOL_FOLDER_RE.match(folder_name.get(f, ""))],
        "near_dup_folder": near_f,
        "near_dup_name": near_names,
        "marked": [m["id"] for m in metas if m["marker"]],
    }
    return {
        "version": 1, "comparison_version": COMPARISON_VERSION, "created": now_iso(), "source": source,
        "trash": trash_count,
        "items": metas,
        "folders": [dict(f, items=counts.get(f["id"], 0)) for f in fl],
        "groups": groups,
        "findings": findings,
    }


def local_users():
    """Names of the local login accounts (root and uid 1000+ with a real shell), or None when unknown."""
    env = os.environ.get("VAULT_ORG_USERS")
    if env is not None:
        return {u for u in env.split(",") if u}
    try:
        import pwd
        return {p.pw_name for p in pwd.getpwall()
                if (p.pw_uid == 0 or 1000 <= p.pw_uid < 60000) and not p.pw_shell.endswith(("nologin", "false"))}
    except Exception:
        return None


# ───────────────────────────── audit: command ─────────────────────────────

def fetch(m):
    """(items, trash count, folders) through the bw server: three requests."""
    def jl(*args):
        p = m.bw(*args)
        if p.returncode != 0:
            raise Fail(f"bw {' '.join(args[:2])} failed: {m.first_line(p.stderr or p.stdout)}", 1)
        try:
            data = json.loads(p.stdout or "[]")
        except ValueError:
            raise Fail(f"bw {' '.join(args[:2])} returned something that is not JSON", 1)
        return data

    items = jl("list", "items")
    trash = jl("list", "items", "--trash")
    folders = jl("list", "folders")
    return items, len(trash), folders


def cmd_audit(argv):
    hidden = json_out = False
    for a in argv:
        if a == "--names-hidden":
            hidden = True
        elif a == "--json":
            json_out = True
        else:
            raise Fail("usage: vault-audit [audit] [--names-hidden] [--json]", 2)
    m = vbw()
    opened_bw(m)
    items, trash, folders = fetch(m)
    key = secrets.token_bytes(32)
    doc = build_audit(items, trash, folders, key)
    items = None
    key = None
    org_dir(m)
    atomic_write(audit_path(m), json.dumps(doc, indent=1, sort_keys=True) + "\n")
    if json_out:
        print(audit_path(m).read_text(), end="")
        return 0
    print(report(doc, hidden))
    return 0


def label(m, hidden):
    if hidden:
        return f"{m['id']}  {','.join(m['hosts']) or '-'}"
    return f"{m['id']}  {m['name']}" + (f"  [{','.join(m['hosts'])}]" if m["hosts"] else "")


def report(doc, hidden=False):
    by = {i["id"]: i for i in doc["items"]}
    fn = {f["id"]: f for f in doc["folders"]}
    f = doc["findings"]
    out = [f"vault audit {doc['created']}",
           f"  items {len(doc['items'])}  trash {doc['trash']}  folders {len(doc['folders'])}  "
           f"groups {len(doc['groups'])}  without folder {len(f['no_folder'])}  empty folders {len(f['empty_folder'])}",
           f"  tool-folder problems {len(f['tool_folder'])}  near-duplicate folders {len(f['near_dup_folder'])}  "
           f"near-duplicate names {len(f['near_dup_name'])}  marked for vault-share {len(f['marked'])}"]
    for g in doc["groups"]:
        out.append(f"duplicate group {g['id']} ({g['class']}"
                   + (f", differs: {', '.join(g['differs'])}" if g.get("differs") else "") + f"), keep {g['keep']}")
        for i in g["members"]:
            out.append("    " + ("* " if i == g["keep"] else "  ") + label(by[i], hidden) + f"  rev {by[i]['revision'][:10]}")
    if f["no_folder"]:
        out.append("without a folder:")
        out += ["    " + label(by[i], hidden) for i in f["no_folder"]]
    for p in f["tool_folder"]:
        out.append(f"tool folder: {label(by[p['id']], hidden)}: {p['problem']}")
    for fid in f["empty_folder"]:
        out.append(f"empty folder: {fid if hidden else fn[fid]['name']}")
    for ids in f["near_dup_folder"]:
        out.append("near-duplicate folders: " + ", ".join(i if hidden else fn[i]["name"] for i in ids))
    for ids in f["near_dup_name"]:
        out.append("near-duplicate names: " + "; ".join(label(by[i], hidden) for i in ids))
    for i in f["marked"]:
        out.append("vault-share marker: " + label(by[i], hidden))
    return "\n".join(out)


# ───────────────────────────── scopes (display only) ─────────────────────────────

CONF_ROOT = Path(os.environ.get("VAULT_ORG_CONF") or Path.home() / ".config")   # holds vault-org/ and vault-share/ (test hook)


def vs():
    return load("vault_share", HERE / "vault-share.py")


def interactive_users():
    """Interactive managed users from the registry (infrastructure/users/managed.tsv; a service row is none)."""
    out = []
    try:
        for line in (REPO / "infrastructure/users/managed.tsv").read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                c = line.split("\t")
                if len(c) >= 3 and "service" not in c[2].split(","):
                    out.append(c[0])
    except OSError:
        pass
    return out


def scope_rules():
    """-> (rules {user: [rule]}, planned). The installed /etc/vault-share/scopes.tsv when it exists; else what apply-system
    would render from the repo file and the owner's overlay (planned = True)."""
    v = vs()
    etc = Path(os.environ.get("VAULT_ORG_SCOPES") or "/etc/vault-share/scopes.tsv")
    try:
        rules, _ = v.parse_rules(etc.read_text())
        return rules, False
    except OSError:
        pass
    try:
        import pwd
        owner = pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        owner = "owner"
    local = CONF_ROOT / "vault-share" / "scopes.local.tsv"
    local_text = ""
    ok, _why = v.trusted_local_file(local, os.getuid())
    if ok:
        local_text = local.read_text()
    try:
        repo_text = (REPO / "infrastructure/vault-share/scopes.tsv").read_text()
    except OSError:
        repo_text = ""
    text, _w, _p = v.render_scopes(repo_text, local_text, interactive_users(), owner)
    rules, _ = v.parse_rules(text)
    return rules, True


def scope_users(rules, folder, name):
    v = vs()
    return [u for u in sorted(rules) if v.in_scope(rules[u], folder, name)]


# ───────────────────────────── plan: file format ─────────────────────────────

class Row:
    __slots__ = ("kind", "id", "name", "current", "target", "rev", "note")

    def __init__(self, kind, id, name, current, target, rev="-", note=""):
        self.kind, self.id, self.name, self.current, self.target, self.rev, self.note = \
            kind, id, clean(name), current, target, rev or "-", clean(note)

    def line(self):
        if self.kind == "folder":
            return "\t".join(["@folder", self.id, self.name, self.target, self.rev, self.note])
        return "\t".join([self.id, self.name, self.current or "-", self.target, self.rev, self.note])

    def copy(self):
        return Row(self.kind, self.id, self.name, self.current, self.target, self.rev, self.note)


def format_plan(header, rows):
    out = [f"# vault-org plan v1 audit={header['audit']} items={header['items']} generated={header['generated']}",
           "# id\tname\tcurrent\ttarget\trevision\tnote"]
    out += [r.line() for r in rows]
    return "\n".join(out) + "\n"


def parse_plan(text):
    """-> (header, rows, problems)."""
    header, rows, problems = {}, [], []
    lines = text.splitlines()
    m = re.match(r"^# vault-org plan v(\d+) audit=(\S*) items=(\d+) generated=(\S+)$", lines[0]) if lines else None
    if not m:
        return header, rows, ["the first line is not a 'vault-org plan v1' header"]
    header = {"version": int(m.group(1)), "audit": m.group(2), "items": int(m.group(3)), "generated": m.group(4)}
    for n, line in enumerate(lines[1:], 2):
        if not line.strip() or line.startswith("#"):
            continue
        c = line.split("\t")
        if c[0] == "@folder":
            if len(c) != 6:
                problems.append(f"line {n}: a folder row has 6 columns")
                continue
            rows.append(Row("folder", c[1], c[2], None, c[3], c[4], c[5]))
        else:
            if len(c) != 6:
                problems.append(f"line {n}: an item row has 6 columns (a tab in a name or note?)")
                continue
            rows.append(Row("item", c[0], c[1], None if c[2] == "-" else c[2], c[3], c[4], c[5]))
    return header, rows, problems


def tool_root(folder):
    """The tool folder tree a folder belongs to (Env, Linux, MCP, Users/x/Env, Shared/Env), or None."""
    m = TOOL_FOLDER_RE.match(folder or "")
    if not m:
        return None
    mm = re.match(r"^(Env|Linux|MCP|(?:Users/[^/]+|Shared)/Env)(?:/|$)", folder)
    return mm.group(1)


def folder_problem(name):
    if len(name) > 512:
        return "longer than 512 characters"
    if any(ord(c) < 32 or ord(c) == 127 for c in name) or "\t" in name:
        return "control character"
    if "*" in name:
        return "a * is not allowed"
    return vs().valid_path(unicodedata.normalize("NFC", name))


def validate_plan(header, rows, audit=None, allow_tool=False):
    problems = []
    if header.get("version") != 1:
        problems.append("plan version is not 1")
    if not header.get("audit"):
        problems.append("the header has no audit id")
    seen, by = set(), {}
    for r in rows:
        key = (r.kind, r.id)
        if key in seen:
            problems.append(f"{r.id}: listed twice")
        seen.add(key)
        by[(r.kind, r.id)] = r
    items = {r.id: r for r in rows if r.kind == "item"}
    folder_names = {r.id: r.name for r in rows if r.kind == "folder"}
    groups = {}
    if audit:
        for g in audit.get("groups", []):
            for i in g["members"]:
                groups[i] = g["id"]
    renames = {}
    for r in rows:
        t = r.target
        if r.kind == "item":
            if t == "keep":
                continue
            if t.startswith("folder:"):
                bad = folder_problem(t[7:])
                if bad:
                    problems.append(f"{r.id}: target folder {t[7:]!r}: {bad}")
                    continue
                if not allow_tool and (tool_root(r.current) or tool_root(t[7:])) and tool_root(r.current) != tool_root(t[7:]):
                    problems.append(f"{r.id}: moves between a tool folder (Linux, MCP, Env/*) and another folder are refused "
                                    "(--allow-tool-folders)")
            elif t.startswith("trash-duplicate-of:"):
                k = t.split(":", 1)[1]
                if not allow_tool and tool_root(r.current):
                    problems.append(f"{r.id}: items in a tool folder are never trashed (--allow-tool-folders)")
                if k not in items:
                    problems.append(f"{r.id}: the keep {k} is not in the plan")
                    continue
                if k == r.id:
                    problems.append(f"{r.id}: duplicate of itself")
                elif items[k].target.startswith("trash-duplicate-of:"):
                    problems.append(f"{r.id}: the keep {k} is itself trashed (no chains or cycles)")
                elif audit and not (groups.get(r.id) and groups.get(r.id) == groups.get(k)) and "manual" not in r.note.split():
                    problems.append(f"{r.id}: {k} is not in the same audit group (pick it in the reviewer: it is then marked manual)")
            else:
                problems.append(f"{r.id}: unknown item target {t!r}")
        else:
            if t == "keep":
                continue
            if tool_root(r.name) and not allow_tool:
                problems.append(f"folder {r.id}: a tool folder is never renamed or deleted (--allow-tool-folders)")
                continue
            if t == "delete-if-empty":
                continue
            if t.startswith("rename:"):
                if tool_root(t[7:]) and not allow_tool:
                    problems.append(f"folder {r.id}: renaming into a tool folder is refused")
                    continue
                bad = folder_problem(t[7:])
                if bad:
                    problems.append(f"folder {r.id}: new name {t[7:]!r}: {bad}")
                    continue
                if t[7:] in {n for i, n in folder_names.items() if i != r.id}:
                    problems.append(f"folder {r.id}: {t[7:]!r} exists already: move the items instead")
                if t[7:] in renames:
                    problems.append(f"folder {r.id}: {t[7:]!r} is the new name of another folder too")
                renames[t[7:]] = r.id
            else:
                problems.append(f"folder {r.id}: unknown folder target {t!r}")
    return problems


# ───────────────────────────── plan: rules and proposals ─────────────────────────────

def load_rules(path):
    """-> (rules [(kind, pattern, target)], note). A missing file is no rules."""
    p = Path(path)
    if not p.exists():
        return [], f"no rules file ({p}): every proposal stays where it is (format: infrastructure/vault-org/rules.example.tsv)"
    rules = []
    for n, line in enumerate(p.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        c = line.split("\t")
        if len(c) != 3 or c[0] not in ("host", "name", "folder", "type"):
            raise Fail(f"{p} line {n}: expected kind<TAB>pattern<TAB>folder with kind host|name|folder|type", 4)
        bad = folder_problem(c[2])
        if bad:
            raise Fail(f"{p} line {n}: target folder: {bad}", 4)
        rules.append((c[0], c[1], c[2]))
    return rules, ""


def rule_target(rules, meta):
    for kind, pat, target in rules:
        if kind == "host" and any(fnmatch.fnmatchcase(h, pat.lower()) for h in meta["hosts"]):
            return target, f"rule host {pat}"
        if kind == "name" and fnmatch.fnmatchcase(meta["name"].casefold(), pat.casefold()):
            return target, f"rule name {pat}"
        if kind == "folder" and meta["folder"] and fnmatch.fnmatchcase(meta["folder"], pat):
            return target, f"rule folder {pat}"
        if kind == "type" and meta["type"] == pat:
            return target, f"rule type {pat}"
    return None, ""


def propose(audit, rules):
    """The generated plan rows from an audit document and the rules."""
    metas = {i["id"]: i for i in audit["items"]}
    folders = {f["id"]: f for f in audit["folders"]}
    in_group = {}
    for g in audit["groups"]:
        for i in g["members"]:
            in_group[i] = g
    # near-duplicate folders: the items of the smaller one go to the larger one, the smaller one is deleted when empty
    merge_to, folder_note = {}, {}
    for ids in audit["findings"]["near_dup_folder"]:
        ranked = sorted(ids, key=lambda i: (-folders[i]["items"], folders[i]["name"].casefold(), i))
        major = ranked[0]
        for i in ranked[1:]:
            merge_to[folders[i]["name"]] = folders[major]["name"]
            folder_note[i] = f"near-duplicate of {folders[major]['name']!r}"
    rows = []
    for m in audit["items"]:
        target, note = "keep", ""
        g = in_group.get(m["id"])
        if m.get("duplicate_review"):
            note = "duplicate review: " + m["duplicate_review"]
        tool = tool_root(m["folder"])
        if tool:
            note = "tool folder"
        elif g and m["id"] != g["keep"] and g["rel"].get(m["id"]) in ("identical", "subset"):
            target = f"trash-duplicate-of:{g['keep']}"
            note = f"{g['id']} {g['class']}" + ("" if g["class"] == "identical" else f": {g['rel'][m['id']]}")
        else:
            if g and m["id"] != g["keep"]:
                rel = g["rel"].get(m["id"], "")
                kinds = rel.split(":", 1)[1].replace(",", " and ") + " differs" if rel.startswith("differs:") else rel
                note = f"{g['id']} {g['class']}: {kinds}" + (", older revision" if m["revision"] < metas[g["keep"]]["revision"] else "")
                if g["class"] == "no-user":
                    note += ", no username"
            elif g:
                note = f"{g['id']} {g['class']}: keep" + ("; duplicate review: " + m["duplicate_review"] if m.get("duplicate_review") else "")
            dest, why = rule_target(rules, m)
            if dest is None and m["folder"] in merge_to:
                dest, why = merge_to[m["folder"]], "merge near-duplicate folder"
            if dest and dest != m["folder"]:
                target = f"folder:{dest}"
                note = (note + "; " if note else "") + why
        rows.append(Row("item", m["id"], m["name"], m["folder"], target, m["revision"], note))
    empty = set(audit["findings"]["empty_folder"])
    for f in audit["folders"]:
        target, note = "keep", folder_note.get(f["id"], "")
        if tool_root(f["name"]):
            note = "tool folder"
        elif f["id"] in empty:
            target, note = "delete-if-empty", "empty"
        elif f["id"] in folder_note:
            target = "delete-if-empty"
        rows.append(Row("folder", f["id"], f["name"], None, target, "-", note))
    return rows


# ───────────────────────────── plan: files and commands ─────────────────────────────

META = STATE / "org-plan.meta.json"


def load_audit(m):
    try:
        return json.loads(audit_path(m).read_text())
    except (OSError, ValueError):
        raise Fail("no audit yet: run vault-audit first (it is removed on lock and at login)", 1)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def read_meta():
    try:
        return json.loads(META.read_text())
    except (OSError, ValueError):
        return {}


def write_meta(meta):
    atomic_write(META, json.dumps(meta, indent=1, sort_keys=True) + "\n")


def load_plan(path=PLAN):
    try:
        text = Path(path).read_text()
    except OSError:
        raise Fail(f"no plan yet: run vault-audit plan ({path})", 1)
    header, rows, problems = parse_plan(text)
    if problems:
        raise Fail("the plan is invalid:\n  " + "\n  ".join(problems), 4)
    return header, rows


def save_plan(header, rows, path=PLAN):
    atomic_write(path, format_plan(header, rows))


def has_manual_edits():
    if not PLAN.exists():
        return False
    meta = read_meta()
    return bool(meta.get("reviewed")) or sha(PLAN.read_text()) != meta.get("sha")


def summary_counts(rows, audit, rules):
    """Counts of what the plan does and the scope impact per user (counts only)."""
    c = {"move": 0, "trash": 0, "rename": 0, "delete": 0, "keep": 0}
    metas = {i["id"]: i for i in audit["items"]} if audit else {}
    before = {u: 0 for u in rules}
    after = {u: 0 for u in rules}
    for r in rows:
        if r.kind == "folder":
            if r.target.startswith("rename:"):
                c["rename"] += 1
            elif r.target == "delete-if-empty":
                c["delete"] += 1
            continue
        if r.target.startswith("folder:"):
            c["move"] += 1
        elif r.target.startswith("trash-duplicate-of:"):
            c["trash"] += 1
        else:
            c["keep"] += 1
        for u in scope_users(rules, r.current, r.name):
            before[u] += 1
        if not r.target.startswith("trash-duplicate-of:"):
            dest = r.target[7:] if r.target.startswith("folder:") else r.current
            for u in scope_users(rules, dest, r.name):
                after[u] += 1
    return c, before, after, metas


def summary_lines(rows, audit):
    rules, planned = scope_rules()
    c, before, after, _ = summary_counts(rows, audit, rules)
    out = [f"{c['move']} moves, {c['trash']} duplicates to the trash, {c['rename']} folder renames, "
           f"{c['delete']} empty folders deleted, {c['keep']} items stay"]
    for u in sorted(rules):
        out.append(f"{u}: {before[u]} -> {after[u]} items in scope" + (" (planned scopes)" if planned else ""))
    return out


def cmd_plan(argv):
    rules_file, force, i = str(CONF_ROOT / "vault-org" / "rules.tsv"), False, 0
    while i < len(argv):
        if argv[i] == "--rules" and i + 1 < len(argv):
            rules_file, i = argv[i + 1], i + 2
        elif argv[i] == "--force":
            force, i = True, i + 1
        else:
            raise Fail("usage: vault-audit plan [--rules FILE] [--force]", 2)
    m = vbw()
    audit = load_audit(m)
    if has_manual_edits() and not force:
        raise Fail(f"{PLAN} has manual edits or reviewed rows: --force replaces it (the old one is kept as .bak)", 4)
    rules, note = load_rules(rules_file)
    rows = propose(audit, rules)
    header = {"version": 1, "audit": audit["created"], "items": len(audit["items"]), "generated": now_iso()}
    problems = validate_plan(header, rows, audit)
    if problems:
        raise Fail("the generated plan is invalid:\n  " + "\n  ".join(problems), 1)
    if PLAN.exists():
        atomic_write(PLAN.with_suffix(".tsv.bak"), PLAN.read_text())
    text = format_plan(header, rows)
    atomic_write(PLAN, text)
    write_meta({"audit": audit["created"], "sha": sha(text), "reviewed": [],
                "proposal": {r.id: [r.target, r.note] for r in rows}})
    if note:
        print(note)
    print(f"plan written: {PLAN}")
    for line in summary_lines(rows, audit):
        print("  " + line)
    return 0


def cmd_check(argv):
    """Validate the plan file (what apply checks first); exit 4 with one line per problem."""
    allow = False
    for a in argv:
        if a == "--allow-tool-folders":
            allow = True
        else:
            raise Fail("usage: vault-audit check [--allow-tool-folders]", 2)
    header, rows = load_plan()
    try:
        audit = json.loads(audit_path(vbw()).read_text())
    except (OSError, ValueError):
        audit = None
    problems = validate_plan(header, rows, audit, allow)
    if problems:
        raise Fail("\n".join(problems), 4)
    print(f"plan ok: {len(rows)} rows")
    return 0


# ───────────────────────────── review (fzf-menu) ─────────────────────────────

# NORMAL-mode letter -> action; Alt key -> action. vimfzf keeps j k g G q i a I A / c x p J K v for itself.
NORMAL_KEYS = [("f", "folder"), ("n", "keep"), ("d", "dup"), ("D", "dupall"), ("u", "undo"), ("r", "reset"), ("t", "filter"),
               ("e", "edit"), ("s", "summary"), ("R", "rename")]
ALT_KEYS = {"alt-f": "folder", "alt-n": "keep", "alt-d": "dup", "alt-D": "dupall", "alt-u": "undo", "alt-r": "reset",
            "alt-t": "filter", "alt-e": "edit", "alt-s": "summary", "alt-R": "rename"}
FILTERS = ["all", "changes", "notes", "duplicates", "folders"]
SELF = Path(__file__).resolve()


def mark_of(r, reviewed):
    a = "·"
    if r.target.startswith("folder:") or r.target.startswith("rename:"):
        a = "→"
    elif r.target.startswith("trash-duplicate-of:") or r.target == "delete-if-empty":
        a = "✗"
    b = "✓" if r.id in reviewed else ("!" if r.note else " ")
    return a + b


def cell(s, w):
    s = clean(s)
    return (s[:w - 1] + "…" if len(s) > w else s).ljust(w)


def row_text(r, reviewed, rules):
    if r.kind == "folder":
        left = f"{mark_of(r, reviewed)} [folder] {cell(r.name, 28)}"
        right = "" if r.target == "keep" else f" → {r.target}"
        return f"{left}{right}   {r.note}"
    dest = r.target[7:] if r.target.startswith("folder:") else r.current
    who = "" if r.target.startswith("trash-duplicate-of:") else " ".join(scope_users(rules, dest, r.name))
    cur = r.current or "-"
    tgt = "" if r.target == "keep" else f" → {r.target.replace('folder:', '')}"
    return f"{mark_of(r, reviewed)} {cell(r.name, 30)} {cell(cur, 16)}{tgt}   [{who}]   {r.note}"


def visible(rows, filt, audit):
    ingroup = {i for g in audit["groups"] for i in g["members"]}
    out = []
    for r in rows:
        if filt == "all" or (filt == "changes" and r.target != "keep") or (filt == "notes" and r.note) \
                or (filt == "duplicates" and r.kind == "item" and (r.id in ingroup or r.target.startswith("trash-duplicate-of:"))) \
                or (filt == "folders" and r.kind == "folder"):
            out.append(r)
    return out


def cmd_preview(argv):
    """fzf preview: metadata of one row from the audit file and the plan; never a value."""
    if not argv:
        return 2
    ident = argv[0]
    m = vbw()
    audit = load_audit(m)
    header, rows = load_plan()
    row = next((r for r in rows if r.id == ident), None)
    if row is None:
        return 0
    rules, planned = scope_rules()
    if row.kind == "folder":
        f = next((x for x in audit["folders"] if x["id"] == ident), None)
        print(f"Folder {row.name}\n{f['items'] if f else '?'} items\nplan: {row.target}\n{row.note}")
        return 0
    it = next((x for x in audit["items"] if x["id"] == ident), None)
    if it:
        print(f"{it['name']}\ntype      {it['type']}\nfolder    {it['folder'] or '(none)'}\nhosts     {', '.join(it['hosts']) or '-'}")
        print(f"username  {'yes' if it['user'] else 'no'}\ntotp      {'yes' if it['totp'] else 'no'}\n"
              f"notes     {'yes' if it['notes'] else 'no'}\nfields    {it['fields']}\nfiles     {it['attachments']}\n"
              f"revision  {it['revision']}")
    g = next((g for g in audit["groups"] if ident in g["members"]), None)
    if g:
        by = {x["id"]: x for x in audit["items"]}
        print(f"\ngroup {g['id']} ({g['class']}) differs: {', '.join(g['differs']) or '-'}")
        for i in g["members"]:
            print(f"  {'*' if i == g['keep'] else ' '} {i}  {by[i]['name']}  rev {by[i]['revision'][:10]}  {g['rel'].get(i, '')}")
    print(f"\nplan: {row.target}\nnote: {row.note or '-'}")
    dest = row.target[7:] if row.target.startswith("folder:") else row.current
    if not row.target.startswith("trash-duplicate-of:"):
        print("shared with: " + (", ".join(scope_users(rules, dest, row.name)) or "nobody") + (" (planned scopes)" if planned else ""))
    return 0


def run_menu(lines, header, pos):
    me = f"python3 -I {shlex.quote(str(SELF))}"
    binds = "\n".join(f'{k}:become(printf "%s\\n%s\\n%s\\n" {{q}} {a} {{1}})' for k, a in NORMAL_KEYS)
    cmd = ["fzf-menu", "--here", "-p", "reorg", "--delimiter=\t", "--with-nth=2..", "--tabstop=4", "--print-query",
           "--expect=" + ",".join(ALT_KEYS), f"--bind=load:pos({max(1, pos)})",
           f"--preview={me} _preview {{1}}", "--preview-window=right,45%,wrap,border-left", f"--header={header}"]
    env = dict(os.environ, FZF_MENU_NORMAL_BINDS=binds)
    p = subprocess.run(cmd, input="\n".join(lines) + "\n", stdout=subprocess.PIPE, text=True, env=env)
    out = p.stdout.split("\n")
    key = out[1] if len(out) > 1 else ""
    ident = (out[2] if len(out) > 2 else "").split("\t")[0]
    return p.returncode, key, ident


def pick(lines, prompt, header="", print_query=False):
    cmd = ["fzf-menu", "--here", "-p", prompt, "--delimiter=\t", "--with-nth=2..", "--tabstop=4"]
    if header:
        cmd.append(f"--header={header}")
    if print_query:
        cmd.append("--print-query")
    p = subprocess.run(cmd, input="\n".join(lines) + "\n", stdout=subprocess.PIPE, text=True)
    out = p.stdout.split("\n")
    if print_query:
        return (out[1] if len(out) > 1 and p.returncode == 0 else ""), out[0]
    return out[0] if p.returncode == 0 else ""


class Review:
    def __init__(self, m, audit, header, rows):
        self.m, self.audit, self.header, self.rows = m, audit, header, rows
        self.meta = read_meta()
        self.reviewed = set(self.meta.get("reviewed", []))
        self.rules, self.planned = scope_rules()
        self.filt = "all"
        self.pos = 1
        self.stack = []
        self.msg = ""
        self.by = {i["id"]: i for i in audit["items"]}
        self.group = {}
        for g in audit["groups"]:
            for i in g["members"]:
                self.group[i] = g

    def row(self, ident):
        return next((r for r in self.rows if r.id == ident), None)

    def snapshot(self):
        self.stack.append(([r.copy() for r in self.rows], set(self.reviewed)))
        del self.stack[:-50]

    def save(self):
        text = format_plan(self.header, self.rows)
        atomic_write(PLAN, text)
        self.meta.update(sha=sha(text), reviewed=sorted(self.reviewed))
        write_meta(self.meta)

    def folder_choices(self):
        names = {f["name"] for f in self.audit["folders"]} | {r.target[7:] for r in self.rows if r.target.startswith("folder:")}
        names |= {r.target[7:] for r in self.rows if r.target.startswith("rename:")}
        try:
            names |= {t for _k, _p, t in load_rules(CONF_ROOT / "vault-org" / "rules.tsv")[0]}
        except Fail:
            pass
        return sorted(names - {""}, key=str.casefold)

    def act(self, action, ident):
        r = self.row(ident) if ident else None
        if action == "filter":
            self.filt = FILTERS[(FILTERS.index(self.filt) + 1) % len(FILTERS)]
            self.pos = 1
            return
        if action == "summary":
            lines = summary_lines(self.rows, self.audit)
            pick([f"-\t{x}" for x in lines], "summary", "Esc: back")
            return
        if action == "undo":
            if self.stack:
                self.rows, self.reviewed = self.stack.pop()
                self.save()
            else:
                self.msg = "nothing to undo"
            return
        if action == "edit":
            self.edit_plan()
            return
        if r is None:
            return
        self.snapshot()
        if action == "keep":
            r.target, r.note = "keep", ""
        elif action == "reset":
            prop = self.meta.get("proposal", {}).get(r.id)
            if prop:
                r.target, r.note = prop
            self.reviewed.discard(r.id)
        elif action == "folder" and r.kind == "item":
            dest = self.pick_folder()
            if dest is None:
                self.stack.pop()
                return
            r.target = "keep" if dest == r.current else f"folder:{dest}"
            if r.target == "keep":
                r.note = ""
        elif action == "dup" and r.kind == "item":
            keep = self.pick_dup(r)
            if keep is None:
                self.stack.pop()
                return
            g = self.group.get(r.id)
            same = g is not None and keep in g["members"]
            r.target = f"trash-duplicate-of:{keep}"
            r.note = f"{g['id']} {g['class']}" if same else "manual"
        elif action == "dupall" and r.kind == "item":
            g = self.group.get(r.id)
            if not g:
                self.msg = "this item is in no duplicate group"
                self.stack.pop()
                return
            r.target = "keep"
            for i in g["members"]:
                o = self.row(i)
                if o and i != r.id:
                    o.target, o.note = f"trash-duplicate-of:{r.id}", f"{g['id']} {g['class']}"
        elif action == "rename" and r.kind == "folder":
            try:
                new = input(f"New name for folder {r.name!r} (empty = cancel): ").strip()
            except EOFError:
                new = ""
            bad = folder_problem(new) if new else None
            if not new or bad:
                self.msg = bad or ""
                self.stack.pop()
                return
            r.target = f"rename:{new}"
        else:
            self.stack.pop()
            return
        self.save()

    def pick_folder(self):
        rows = ["__new__\tNew folder..."] + [f"{n}\t{n}" for n in self.folder_choices()]
        got = pick(rows, "folder", "Enter: move the item there")
        if not got:
            return None
        if got == "__new__":
            try:
                name = input("New folder name (Parent/Child, empty = cancel): ").strip()
            except EOFError:
                return None
            if not name:
                return None
            bad = folder_problem(name)
            if bad:
                self.msg = f"{name!r}: {bad}"
                return None
            return name
        return got.split("\t")[0]

    def pick_dup(self, r):
        me = self.by.get(r.id)
        cands = [x for x in self.audit["items"] if x["id"] != r.id]
        cands.sort(key=lambda x: (not (me and x["type"] == me["type"] and set(x["hosts"]) & set(me["hosts"])),
                                  x["name"].casefold()))
        rows = [f"{x['id']}\t{x['name']}   {','.join(x['hosts'])}   rev {x['revision'][:10]}" for x in cands]
        got = pick(rows, "duplicate of", "Enter: this item is a duplicate of the chosen keep")
        return got.split("\t")[0] if got else None

    def edit_plan(self):
        d = self.m.RUN / "org"
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / "plan-edit.tsv"
        atomic_write(tmp, format_plan(self.header, self.rows))
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or ("nvim" if shutil.which("nvim") else "vi")
        cmd = [editor] + (["-n", "-i", "NONE", "-u", "NONE"] if os.path.basename(editor) == "nvim" else []) + [str(tmp)]
        while True:
            subprocess.run(cmd)
            header, rows, problems = parse_plan(tmp.read_text())
            if not problems:
                problems = validate_plan(header, rows, self.audit)
            if not problems:
                self.snapshot()
                self.header, self.rows = header, rows
                self.save()
                break
            print("\n".join(problems))
            try:
                ans = input("[e]dit again or [d]iscard? ").strip().lower()
            except EOFError:
                ans = "d"
            if ans.startswith("d"):
                break
        tmp.unlink(missing_ok=True)

    def header_text(self):
        n_ch = sum(1 for r in self.rows if r.target != "keep")
        keys = "f folder  n keep  d dup-of  D trash group  u undo  r reset  t filter  e edit  s summary  R rename  Enter reviewed"
        return (f"Reorganise  filter {self.filt}  rows {len(visible(self.rows, self.filt, self.audit))}/{len(self.rows)}  "
                f"changes {n_ch}  reviewed {len(self.reviewed)}" + (f"  [{self.msg}]" if self.msg else "") + f"\n{keys}")


def cmd_review(argv):
    if argv:
        raise Fail("usage: vault-audit review", 2)
    if not shutil.which("fzf-menu"):
        raise Fail("fzf-menu is not installed (~/.local/bin/fzf-menu)", 1)
    m = vbw()
    audit = load_audit(m)
    header, rows = load_plan()
    rv = Review(m, audit, header, rows)
    problems = validate_plan(header, rows, audit)
    if problems:
        print("the plan has problems (fix them with e):\n  " + "\n  ".join(problems[:10]))
    while True:
        vis = visible(rv.rows, rv.filt, audit)
        lines = [f"{r.id}\t{row_text(r, rv.reviewed, rv.rules)}" for r in vis]
        if not lines:
            lines = ["-\t(nothing in this filter: t changes it)"]
        rc, key, ident = run_menu(lines, rv.header_text(), rv.pos)
        rv.msg = ""
        if rc != 0 and not key and not ident:
            break
        action = ALT_KEYS.get(key, key) if key else ""
        ids = [r.id for r in vis]
        if ident in ids:
            rv.pos = ids.index(ident) + 1
        if not action:                      # Enter: mark reviewed, next row
            if ident in ids:
                rv.snapshot()
                rv.reviewed.add(ident)
                rv.save()
                rv.pos = min(len(ids), rv.pos + 1)
            continue
        rv.act(action, ident)
        if action == "filter":
            rv.pos = 1
    return 0


# ───────────────────────────── apply ─────────────────────────────

class Journal:
    """~/.local/state/vault/org-journal.tsv: `# plan-sha256=...` then time<TAB>step<TAB>id<TAB>result, one line per finished step,
    appended and flushed at once so an interrupt leaves a consistent file."""

    def __init__(self, plan_sha, resume=False, new_journal=False):
        self.sha, self.done = plan_sha, set()
        STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
        if JOURNAL.exists():
            head = JOURNAL.read_text().splitlines()[:1]
            same = bool(head) and head[0] == f"# plan-sha256={plan_sha}"
            if resume and not same and not new_journal:
                raise Fail("the journal belongs to another plan: --new-journal archives it and starts over", 4)
            if resume and same:
                for line in JOURNAL.read_text().splitlines()[1:]:
                    c = line.split("\t")
                    if len(c) == 4 and c[3].startswith("ok"):
                        self.done.add((c[1], c[2]))
            else:
                os.replace(JOURNAL, JOURNAL.with_name(JOURNAL.name + ".prev"))
        if not JOURNAL.exists():
            fd = os.open(JOURNAL, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            os.write(fd, f"# plan-sha256={plan_sha}\n".encode())
            os.close(fd)

    def seen(self, step, ident):
        return (step, ident) in self.done

    def log(self, step, ident, result):
        fd = os.open(JOURNAL, os.O_WRONLY | os.O_APPEND, 0o600)
        try:
            os.write(fd, f"{now_iso()}\t{step}\t{ident}\t{clean(result)}\n".encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        if result.startswith("ok"):
            self.done.add((step, ident))


def folder_parents(name):
    parts = name.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts) + 1)]


def get_json(m, *args):
    p = m.bw(*args)
    if p.returncode != 0:
        raise Fail(m.first_line(p.stderr or p.stdout), 1)
    try:
        return json.loads(p.stdout or "null")
    except ValueError:
        raise Fail("bw returned something that is not JSON", 1)


def backup_export(m):
    """Account-key encrypted export (no master password is asked: bw export without --password); returns the path.
    Anything wrong stops the whole run before a single change."""
    BACKUPS.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(BACKUPS, 0o700)
    path = BACKUPS / f"vault-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    p = m.bw_cli("export", "--format", "encrypted_json", "--output", str(path))
    if p.returncode != 0 or not path.exists():
        path.unlink(missing_ok=True)
        raise Fail("backup failed: nothing was changed (" + m.first_line(p.stderr or p.stdout) + ")", 1)
    os.chmod(path, 0o600)
    try:
        doc = json.loads(path.read_text())
        live = [i for i in get_json(m, "list", "items") if not i.get("deletedDate")]
        trash = get_json(m, "list", "items", "--trash")
        n = len(doc.get("items", []))
        if doc.get("encrypted") is not True or n not in (len(live), len(live) + len(trash)):
            raise ValueError(f"encrypted={doc.get('encrypted')} items={n} live={len(live)}")
    except (OSError, ValueError, Fail) as e:
        path.unlink(missing_ok=True)
        raise Fail(f"backup failed: nothing was changed ({e})", 1)
    old = sorted(BACKUPS.glob("vault-*.json"))
    for f in old[:-5]:
        f.unlink(missing_ok=True)
    return path


def would(rows, audit):
    """The --dry-run text: what apply would do, from the plan alone."""
    out = [f"would write an encrypted backup to {BACKUPS}/vault-<time>.json",
           "would sync, then:"]
    folders = {r.id: r for r in rows if r.kind == "folder"}
    for r in rows:
        if r.kind == "folder" and r.target.startswith("rename:"):
            out.append(f"would rename folder {r.id} {r.name}: -> {r.target[7:]}")
    want_f = sorted({p for r in rows if r.kind == "item" and r.target.startswith("folder:")
                     for p in folder_parents(r.target[7:])}
                    | {p for r in rows if r.kind == "folder" and r.target.startswith("rename:") for p in folder_parents(r.target[7:])},
                    key=lambda x: (x.count("/"), x))
    existing = {r.name for r in rows if r.kind == "folder"}
    for f in want_f:
        if f not in existing:
            out.append(f"would create folder {f}")
    for r in rows:
        if r.kind == "item" and r.target.startswith("folder:"):
            out.append(f"would move {r.id} {r.name}: {r.current or '-'} -> {r.target[7:]}")
    for r in rows:
        if r.kind == "item" and r.target.startswith("trash-duplicate-of:"):
            out.append(f"would trash {r.id} {r.name} (duplicate of {r.target.split(':', 1)[1]}), soft, restorable 30 days")
    for r in rows:
        if r.kind == "folder" and r.target == "delete-if-empty":
            out.append(f"would delete folder {r.id} {r.name} if it holds no item")
    out.append("would sync bw and rbw")
    out += summary_lines(rows, audit) if audit else []
    return out


def confirm(summary):
    print("\n".join(summary))
    if not (sys.stdin.isatty() and sys.stderr.isatty()):
        raise Fail("no terminal to confirm on: apply asks [y/N] and has no --yes outside the tests", 4)
    return input("Apply this plan? [y/N] ").strip().lower() == "y"


def apply_plan(argv):
    dry = resume = new_journal = yes = False
    for a in argv:
        if a == "--dry-run":
            dry = True
        elif a == "--resume":
            resume = True
        elif a == "--new-journal":
            new_journal = True
        elif a == "--yes":
            yes = True
        else:
            raise Fail("usage: vault-audit apply [--dry-run] [--resume] [--new-journal] [--yes]", 2)
    if yes and not envs_lib().test_mode():
        raise Fail("--yes is only honoured in the tests", 4)
    m = vbw()
    header, rows = load_plan()
    try:
        audit = json.loads(audit_path(m).read_text())
    except (OSError, ValueError):
        audit = None
    problems = validate_plan(header, rows, audit)
    if problems:
        raise Fail("the plan is invalid:\n  " + "\n  ".join(problems), 4)
    if dry:
        print("\n".join(would(rows, audit)))
        return 0
    a = agent()
    if a:
        raise Fail(f"apply is refused under an agent ({a}): the owner runs vault-audit apply himself", 4)
    plan_sha = sha(PLAN.read_text())
    changes = [r for r in rows if r.target != "keep"]
    if not changes:
        print("nothing to do: the plan changes nothing")
        return 0
    import fcntl
    org_dir(m)
    lock = os.open(m.RUN / "org" / "apply.lock", os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise Fail("another vault-audit apply is running", 4)
    opened_bw(m)
    if not (yes or confirm(["About to change the vault:"] + ["  " + x for x in summary_lines(rows, audit or {"groups": [], "items": []})])):
        print("cancelled")
        return 130
    return Applier(m, rows, Journal(plan_sha, resume, new_journal), audit).run()


class Applier:
    def __init__(self, m, rows, journal, audit):
        self.m, self.rows, self.j, self.audit = m, rows, journal, audit
        self.counts = {"moved": 0, "trashed": 0, "renamed": 0, "created": 0, "deleted": 0, "already": 0}
        self.skipped = []
        self.wrote = 0

    def live_folders(self):
        """Fresh id -> name snapshot. Plan display columns and earlier snapshots are never mutation authority."""
        folders = get_json(self.m, "list", "folders")
        if not isinstance(folders, list):
            raise Fail("cannot verify the live folders; audit and review again")
        cur = {}
        for f in folders:
            if not isinstance(f, dict) or not f.get("id") or not isinstance(f.get("name"), str) or f["id"] in cur:
                raise Fail("cannot verify the live folders; audit and review again")
            cur[f["id"]] = unicodedata.normalize("NFC", f["name"])
        return cur

    def fmap(self):
        return {name: ident for ident, name in self.live_folders().items()}

    @staticmethod
    def ordinary_folder(name):
        if tool_root(name):
            raise Fail("live tool-folder protection: audit and review again")
        if name is not None and folder_problem(name):
            raise Fail("cannot verify the live folder name; audit and review again")

    def item_folder(self, item, folders):
        fid = item.get("folderId")
        if fid is None:
            return None
        if fid not in folders:
            raise Fail("the item's live folder is unknown; audit and review again")
        return folders[fid]

    def rename_guard(self, ident, new):
        cur = self.live_folders()
        if ident not in cur:
            raise Fail("the folder does not exist any more")
        self.ordinary_folder(cur[ident])
        self.ordinary_folder(new)
        if any(name == new and fid != ident for fid, name in cur.items()):
            raise Fail("live rename collision: audit and review again")
        return cur[ident]


    def step(self, step, ident, label, fn):
        """Run one journalled step; fn returns (result, kind) with kind created|moved|... or raises Fail."""
        if self.j.seen(step, ident):
            self.counts["already"] += 1
            return
        try:
            res = fn()
        except Fail as e:
            self.j.log(step, ident, "failed: " + e.msg)
            self.skipped.append(f"{ident} {label}: {e.msg}")
            return
        self.j.log(step, ident, res)
        if res.startswith("skipped"):
            self.skipped.append(f"{ident} {label}: {res}")

    def run(self):
        m = self.m
        try:
            if not self.j.seen("backup", "-"):
                p = m.bw("sync")
                if p.returncode != 0:
                    raise Fail("bw sync failed: " + m.first_line(p.stderr or p.stdout), 1)
                path = backup_export(m)
                self.j.log("backup", "-", f"ok {path}")
                print(f"backup: {path}")
            else:
                print("backup: done in an earlier run of this plan")
            self.renames()
            self.creates()
            self.moves()
            self.trash()
            self.empty_folders()
            self.finish()
        except KeyboardInterrupt:
            print("\ninterrupted: the journal is consistent, vault-audit apply --resume continues", file=sys.stderr)
            return 130
        return self.summary()

    def renames(self):
        m = self.m
        for r in self.rows:
            if r.kind != "folder" or not r.target.startswith("rename:"):
                continue
            new = r.target[7:]

            def go(r=r, new=new):
                if self.rename_guard(r.id, new) == new:
                    return "ok (already)"
                for par in folder_parents(new)[:-1]:
                    m.folder_id(par, create=True)
                self.rename_guard(r.id, new)       # parent creation may have taken time; recheck at the write boundary
                p = m.bw("edit", "folder", r.id, stdin=m.b64({"name": new}))
                if p.returncode != 0:
                    raise Fail("rename failed: " + m.first_line(p.stderr or p.stdout))
                self.counts["renamed"] += 1
                self.wrote += 1
                return "ok renamed"

            self.step("rename", r.id, r.name, go)

    def creates(self):
        m = self.m
        want = sorted({p for r in self.rows if r.kind == "item" and r.target.startswith("folder:")
                       for p in folder_parents(r.target[7:])}, key=lambda x: (x.count("/"), x))
        for name in want:
            def go(name=name):
                if name in self.fmap():
                    return "ok (already)"
                if m.folder_id(name, create=True) is None:
                    raise Fail("could not create the folder")
                self.counts["created"] += 1
                self.wrote += 1
                return "ok created"

            self.step("create", name, name, go)

    def moves(self):
        m = self.m
        for r in self.rows:
            if r.kind != "item" or not r.target.startswith("folder:"):
                continue
            dest = r.target[7:]

            def go(r=r, dest=dest):
                item = get_json(m, "get", "item", r.id)
                if not item:
                    raise Fail("the item does not exist any more")
                if item.get("deletedDate"):
                    return "skipped (in the trash)"
                folders = self.live_folders()
                self.ordinary_folder(self.item_folder(item, folders))
                self.ordinary_folder(dest)
                targets = [fid for fid, name in folders.items() if name == dest]
                if len(targets) != 1:
                    raise Fail("target folder missing or ambiguous; audit and review again")
                fid = targets[0]
                self.ordinary_folder(folders[fid])
                if item.get("folderId") == fid:
                    self.counts["already"] += 1
                    return "ok (already)"
                item["folderId"] = fid
                p = m.bw("edit", "item", r.id, stdin=m.b64(item))
                item = None
                if p.returncode != 0:
                    raise Fail("move failed: " + m.first_line(p.stderr or p.stdout))
                try:
                    back = json.loads(p.stdout or "{}")
                except ValueError:
                    back = {}
                if back.get("folderId") != fid:
                    raise Fail("the answer does not show the new folder")
                self.counts["moved"] += 1
                self.wrote += 1
                return "ok moved"

            self.step("move", r.id, r.name, go)

    def trash(self):
        m = self.m
        key = secrets.token_bytes(32)
        for r in self.rows:
            if r.kind != "item" or not r.target.startswith("trash-duplicate-of:"):
                continue
            keep_id = r.target.split(":", 1)[1]

            def go(r=r, keep_id=keep_id):
                x = get_json(m, "get", "item", r.id)
                k = get_json(m, "get", "item", keep_id)
                if not x or x.get("deletedDate"):
                    return "ok (already)"
                if not k or k.get("deletedDate"):
                    return "skipped (the keep is gone or in the trash)"
                if r.rev not in ("-", "") and x.get("revisionDate") != r.rev:
                    return "skipped (changed after the audit)"
                folders = self.live_folders()
                self.ordinary_folder(self.item_folder(x, folders))
                self.ordinary_folder(self.item_folder(k, folders))
                mx, kx = normalise(x, folders, key)
                mk, kk = normalise(k, folders, key)
                words = set(re.split(r"[\s:;,]+", r.note))
                rel = relation(kx, kk)
                if mx["type"] != mk["type"]:
                    return "skipped (no longer a duplicate: another type)"
                if "manual" in words:
                    if kx["user"] is not None and kx["user"] != kk["user"]:
                        return "skipped (no longer a duplicate: another username)"
                elif "no-user" in words:
                    if mx["user"] or mx["hosts"] != mk["hosts"]:
                        return "skipped (no longer a duplicate)"
                elif mx["hosts"] != mk["hosts"] or kx["user"] != kk["user"] or (not mx["hosts"] and norm_name(mx["name"]) != norm_name(mk["name"])):
                    return "skipped (no longer a duplicate)"
                if rel not in ("identical", "subset") or ("identical" in words and rel != "identical"):
                    return "skipped (no longer a duplicate: " + rel + ")"
                p = m.bw("delete", "item", r.id)
                if p.returncode != 0:
                    raise Fail("trash failed: " + m.first_line(p.stderr or p.stdout))
                self.counts["trashed"] += 1
                self.wrote += 1
                return "ok trashed"

            self.step("trash", r.id, r.name, go)

    def empty_folders(self):
        m = self.m
        for r in self.rows:
            if r.kind != "folder" or r.target != "delete-if-empty":
                continue

            def go(r=r):
                cur = self.live_folders()
                if r.id not in cur:
                    return "ok (already)"
                self.ordinary_folder(cur[r.id])
                items = [i for i in get_json(m, "list", "items", "--folderid", r.id) if not i.get("deletedDate")]
                if items:
                    return f"skipped (the folder holds {len(items)} items)"
                cur = self.live_folders()       # listing items may race a folder rename
                if r.id not in cur:
                    return "ok (already)"
                self.ordinary_folder(cur[r.id])
                p = m.bw("delete", "folder", r.id)
                if p.returncode != 0:
                    raise Fail("delete failed: " + m.first_line(p.stderr or p.stdout))
                self.counts["deleted"] += 1
                self.wrote += 1
                return "ok deleted"

            self.step("delete-folder", r.id, r.name, go)

    def finish(self):
        m = self.m
        m.bw("sync")
        m.refresh_rbw()
        for f in ("browse-index.json", "browse-index.tmp"):
            (m.RUN / f).unlink(missing_ok=True)
        audit_path(m).unlink(missing_ok=True)       # the inventory is stale now
        self.j.log("sync", "-", "ok")

    def summary(self):
        c = self.counts
        print(f"applied: {c['moved']} moved, {c['trashed']} to the trash, {c['renamed']} folders renamed, "
              f"{c['created']} folders created, {c['deleted']} empty folders deleted"
              + (f", {c['already']} steps were already done" if c["already"] else ""))
        for line in summary_lines(self.rows, self.audit or {"groups": [], "items": []}):
            print("  " + line)
        if self.skipped:
            print(f"{len(self.skipped)} skipped or failed:")
            for x in self.skipped:
                print("  " + x)
            return 5
        return 0


def cmd_apply(argv):
    return apply_plan(argv)


# ───────────────────────────── main ─────────────────────────────

COMMANDS = {"audit": cmd_audit, "plan": cmd_plan, "check": cmd_check, "review": cmd_review, "apply": cmd_apply, "_preview": cmd_preview}


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = (argv[0], argv[1:]) if argv and not argv[0].startswith("-") else ("audit", argv)
    fn = COMMANDS.get(cmd)
    if fn is None:
        print(f"unknown command {cmd} (audit, plan, check, review, apply)", file=sys.stderr)
        return 2
    try:
        return fn(rest) or 0
    except Fail as e:
        print(e.msg, file=sys.stderr)
        return e.code
    except (KeyboardInterrupt, EOFError):
        print(file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
