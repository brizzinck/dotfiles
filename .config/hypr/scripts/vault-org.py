#!/usr/bin/env python3
"""vault-org: tidy the Bitwarden vault into a folder tree without ever reading a value. Python 3 stdlib only.
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
import json
import os
import re
import secrets
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
CONF = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "vault-org"
RULES = CONF / "rules.tsv"
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


def secret_blobs(item):
    """kind -> bytes of the values that make two items 'the same login'. Only hashed, never stored."""
    t = BW_TYPE.get(item.get("type"), "login")
    out = {}
    if t == "login":
        lg = item.get("login") or {}
        out["password"] = lg.get("password")
        out["totp"] = lg.get("totp")
    elif t == "card":
        c = item.get("card") or {}
        out["password"] = "|".join(str(c.get(k) or "") for k in ("number", "code", "expMonth", "expYear")) \
            if any(c.get(k) for k in ("number", "code")) else None
    elif t == "identity":
        i = item.get("identity") or {}
        out["password"] = "|".join(str(i.get(k) or "") for k in ("ssn", "passportNumber", "licenseNumber")) \
            if any(i.get(k) for k in ("ssn", "passportNumber", "licenseNumber")) else None
    elif t == "ssh":
        out["password"] = (item.get("sshKey") or {}).get("privateKey")
    out["notes"] = item.get("notes")
    flds = [(f.get("name") or "", f.get("value") or "") for f in item.get("fields") or []]
    out["fields"] = json.dumps(sorted(flds)) if flds else None
    atts = sorted((a.get("fileName") or "", str(a.get("size") or "")) for a in item.get("attachments") or [])
    out["attachments"] = json.dumps(atts) if atts else None
    return {k: (v if v else None) for k, v in out.items()}


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
    }
    kx = {"user": hmac_of(key, user_value(item), fold=True)}
    for kind, v in blobs.items():
        kx[kind] = hmac_of(key, v)
    return meta, kx


# ───────────────────────────── audit: groups and findings ─────────────────────────────

KINDS = ("password", "totp", "notes", "fields", "attachments")


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
        "version": 1, "created": now_iso(), "source": source,
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


# ───────────────────────────── main ─────────────────────────────

COMMANDS = {"audit": cmd_audit}


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = (argv[0], argv[1:]) if argv and not argv[0].startswith("-") else ("audit", argv)
    fn = COMMANDS.get(cmd)
    if fn is None:
        print(f"unknown command {cmd} (audit, plan, review, apply)", file=sys.stderr)
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
