#!/usr/bin/env python3
"""vault-browse: the Bitwarden vault browser (SUPER+CTRL+SHIFT+P). One modal fzf-menu list over rbw, bw for the rest.
Python 3 stdlib only. Run through `vault.sh browse [--here] [FOLDER]` (hub row, leader v b, `vault-browse`).

  vault-browse.py [--here] [FOLDER]     the browser; --here = in the current terminal (otherwise a float.tui menu)

The list shows every item rbw knows (login, card, identity, secure note, SSH key) with its folder; the preview shows the
fields with every secret masked (live TOTP code and seconds left, custom fields, URIs, attachments). Tab / Shift+Tab
cycle the folders (All, each folder, no folder, Trash); the header lists the keys. Keys work in NORMAL mode as letters
(Cyrillic twins come from the shared list library) and as Alt keys in both modes:

  Enter       login: type user, Tab, password into the window the browser was opened over; other types: field picker
  y  alt-y    copy the password (card number, SSH private key, note text)    u  alt-u   copy the user name
  o  alt-o    copy the TOTP code                                             f  alt-f   copy any field (picker)
  t  alt-t    type user, Tab, password                                       P  alt-p   type the password only
  e  alt-e    edit the item as JSON in $EDITOR (600 file on tmpfs, validated, shredded)
  n  alt-n    new item: login (generated password) or card / identity / note / SSH key from a template
  d  alt-d    move to the trash (in the Trash: delete for good)              r  alt-r   restore from the trash
  h  alt-h    password history                                               F  alt-a   attachments: download / upload
  w  alt-w    generator                                                      S  alt-m   Bitwarden Send (text / file)
  s  alt-s    sync (rbw and bw)                                              L  alt-l   lock the vault
  b  alt-b    unlock the bw CLI session (Trash and attachments need it)      O  alt-v   open the Bitwarden app
  Tab / Shift+Tab   next / previous folder

rbw does: the list, previews, copy, type, TOTP, history, sync, lock. bw does: Trash, attachments, edit, new, delete,
restore, Send (through vault-bw.py; the session key lives in $XDG_RUNTIME_DIR/vault/bw-session). Account settings,
emergency access and organisation admin stay in the app (the last list row opens it).

Internal subcommands (called by fzf): rows, header [--cycle next|prev], preview ID; `_act NAME ARGS` runs the steps that
need a terminal (editor, prompts) in their own float.tui window.

Secrets: never in the list, argv, notifications or logs. They go to `wl-copy --sensitive` (cleared in 30 s), to
`wtype -` on stdin (type-guard.sh: only into the window that was focused before the browser), to bw on stdin, or into
the 600 edit file on tmpfs that is shredded afterwards. The metadata cache ($XDG_RUNTIME_DIR/vault/browse-index.json:
names, folders, attachments, masked fields, never a value) only exists while the bw session is open.
Test hooks: RBW_BIN, BW_BIN, VAULT_TERMINAL (command prefix replacing `ghostty --class=float.tui -e`), VAULT_CLEAR_AFTER,
VAULT_BROWSE_STATE, EDITOR, FZF_MENU_HERE.
"""
import importlib.util
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

HERE = Path(__file__).resolve().parent
SELF = HERE / "vault-browse.py"
VAULT_SH = HERE / "vault.sh"
GUARD = HERE / "type-guard.sh"
RBW = os.environ.get("RBW_BIN", "rbw")
RUN = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "vault"
INDEX = RUN / "browse-index.json"
SESSION = RUN / "bw-session"
EDIT_DIR = RUN / "edit"
INDEX_TTL = 1800
MASK = "••••••••"
ALL, NOFOLDER, TRASH = "All", "(no folder)", "Trash"
DIM, RST = "\033[2m", "\033[0m"

TYPE_NAME = {"login": "Login", "card": "Card", "identity": "Identity", "note": "Secure note", "ssh": "SSH key"}
TYPE_TAG = {"login": "", "card": "card", "identity": "id", "note": "note", "ssh": "ssh"}
BW_TYPE = {1: "login", 2: "note", 3: "card", 4: "identity", 5: "ssh"}
BW_TYPE_KEY = {"login": "login", "note": "secureNote", "card": "card", "identity": "identity", "ssh": "sshKey"}

# NORMAL-mode letter -> action, Alt key -> action (Alt works in both modes; alt-j / alt-k scroll the preview)
NORMAL_KEYS = [("y", "pass"), ("u", "user"), ("o", "totp"), ("f", "field"), ("t", "type"), ("P", "passonly"),
               ("e", "edit"), ("n", "new"), ("d", "del"), ("r", "restore"), ("h", "hist"), ("F", "files"),
               ("w", "gen"), ("S", "send"), ("s", "sync"), ("L", "lock"), ("b", "unlock"), ("O", "app")]
ALT_KEYS = {"alt-y": "pass", "alt-u": "user", "alt-o": "totp", "alt-f": "field", "alt-t": "type", "alt-p": "passonly",
            "alt-e": "edit", "alt-n": "new", "alt-d": "del", "alt-r": "restore", "alt-h": "hist", "alt-a": "files",
            "alt-w": "gen", "alt-m": "send", "alt-s": "sync", "alt-l": "lock", "alt-b": "unlock", "alt-v": "app"}
NEEDS_ITEM = {"pass", "user", "totp", "field", "type", "passonly", "edit", "del", "restore", "hist", "files"}
TRASH_OK = {"restore", "del"}


# ───────────────────────────── helpers ─────────────────────────────

def have(cmd):
    return shutil.which(cmd) is not None


def is_tty():
    return (sys.stdin.isatty() and sys.stderr.isatty()) or os.environ.get("FZF_MENU_HERE") == "1"


def notify(title, body="", urgency="low"):
    if have("notify-send"):
        subprocess.run(["notify-send", "-a", "vault", "-u", urgency, "-t", "5000",
                        "-h", "string:x-dunst-stack-tag:vault", title, body], check=False)


def poke_bar():
    subprocess.run(["pkill", "-o", "-u", str(os.getuid()), "-RTMIN+15", "-x", "waybar"],
                   check=False, stderr=subprocess.DEVNULL)


_mods = {}


def mod(name):
    """A sibling script with a hyphen in its name (imported, never run: their main is guarded)."""
    if name not in _mods:
        spec = importlib.util.spec_from_file_location(name.replace("-", "_"), HERE / f"{name}.py")
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        _mods[name] = m
    return _mods[name]


def vbw():
    m = mod("vault-bw")
    m.fzf = pick   # the pickers of vault-bw.py run through this file's picker (terminal or float.tui menu)
    return m


def clean(s):
    return str(s or "").replace("\t", " ").replace("\r", " ").replace("\n", " ")


def cell(s, width):
    s = clean(s)
    return (s[:width - 1] + "…" if len(s) > width else s).ljust(width)


def rbw(*args):
    try:
        return subprocess.run([RBW, *args], capture_output=True, text=True)
    except FileNotFoundError:
        return subprocess.CompletedProcess(args, 127, "", "rbw is not installed")


def kind_of(t):
    t = str(t or "").lower()
    if "card" in t:
        return "card"
    if "ident" in t:
        return "identity"
    if "note" in t:
        return "note"
    if "ssh" in t:
        return "ssh"
    return "login"


# ───────────────────────────── the picker ─────────────────────────────

def pick(rows, prompt, header="", print_query=False):
    """Pick one row (tab separated, the first column is the id and stays hidden). Returns the row or None. Runs in this
    terminal when there is one, otherwise as a float.tui fzf-menu (the hot menu server)."""
    cmd = ["fzf-menu"] + (["--here"] if is_tty() else []) + ["-p", prompt, "--delimiter=\t", "--with-nth=2..",
                                                           "--tabstop=4"]
    if header:
        cmd.append(f"--header={header}")
    if print_query:
        cmd.append("--print-query")
    p = subprocess.run(cmd, input="\n".join(rows) + "\n", stdout=subprocess.PIPE, text=True)
    out = p.stdout.splitlines()
    if print_query:
        query = out[0] if out else ""
        return (out[1] if len(out) > 1 and p.returncode == 0 else None), query
    return out[0] if p.returncode == 0 and out else None


def confirm(question):
    row = pick(["no\tno, keep it", "yes\tyes"], "confirm", question)
    return bool(row) and row.split("\t")[0] == "yes"


# ───────────────────────────── normalised records ─────────────────────────────
# One record shape for rbw (`rbw get --raw`) and bw (`bw get item`) items:
#   {id, name, type, folder, fields: [{label, value, secret, kind, primary, shown}], files: [{id, name, size}], deleted}
# `shown` is what the preview prints and never holds a secret; `value` is only kept in memory (never in the index).

def field(label, value, secret=False, kind=None, primary=False, shown=None):
    value = "" if value is None else str(value)
    if shown is None:
        shown = (MASK if value else "—") if secret else (value or "—")
    return {"label": label, "value": value, "secret": secret, "kind": kind, "primary": primary, "shown": shown}


def snake(key):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower()


def infer_type(data):
    keys = set(data or {})
    if not keys:
        return "note"
    if keys & {"private_key", "public_key", "fingerprint"}:
        return "ssh"
    if keys & {"number", "cardholder_name", "brand", "exp_year", "exp_month"}:
        return "card"
    if keys & {"first_name", "last_name", "address1", "ssn", "passport_number", "license_number"}:
        return "identity"
    return "login"


def lines_note(text):
    n = len([x for x in str(text or "").splitlines() if x.strip()])
    return f"{n} line{'s' if n != 1 else ''}" if n else "—"


def type_fields(typ, data, notes):
    f = []
    if typ == "login":
        f.append(field("user", data.get("username")))
        f.append(field("pass", data.get("password"), True, primary=True))
        if data.get("totp"):
            f.append(field("totp", data["totp"], True, "totp"))
        uris = [u for u in (data.get("uris") or []) if u]
        for u in uris or [""]:
            f.append(field("url", u))
    elif typ == "card":
        num = re.sub(r"\D", "", str(data.get("number") or ""))
        f.append(field("holder", data.get("cardholder_name")))
        f.append(field("brand", data.get("brand")))
        f.append(field("number", data.get("number"), True, "cardnum", True,
                       shown=("•••• " + num[-4:]) if len(num) >= 8 else (MASK if num else "—")))
        exp = "/".join(str(x) for x in (data.get("exp_month"), data.get("exp_year")) if x)
        f.append(field("expires", exp))
        f.append(field("cvv", data.get("code"), True))
    elif typ == "identity":
        name = " ".join(str(data.get(k)) for k in ("title", "first_name", "middle_name", "last_name") if data.get(k))
        f.append(field("name", name))
        for label, key in (("company", "company"), ("email", "email"), ("phone", "phone"), ("user", "username")):
            if data.get(key):
                f.append(field(label, data[key]))
        addr = ", ".join(str(data[k]) for k in ("address1", "address2", "address3", "postal_code", "city", "state",
                                                "country") if data.get(k))
        if addr:
            f.append(field("address", addr))
        for label, key in (("ssn", "ssn"), ("passport", "passport_number"), ("license", "license_number")):
            if data.get(key):
                f.append(field(label, data[key], True))
    elif typ == "ssh":
        f.append(field("finger", data.get("fingerprint")))
        f.append(field("public", data.get("public_key")))
        f.append(field("private", data.get("private_key"), True, primary=True))
    f.append(field("notes", notes, True, "notes", primary=(typ == "note"), shown=lines_note(notes)))
    return f


def build_rec(ident, name, folder, typ, data, custom, notes, files=None, deleted=None):
    fields = type_fields(typ, data, notes)
    for c in custom:
        label = clean(c.get("name")) or "field"
        if c.get("linked"):
            continue
        fields.append(field(label, c.get("value"), bool(c.get("hidden")), "custom"))
    return {"id": ident, "name": name or "", "type": typ, "folder": folder or "", "fields": fields,
            "files": files or [], "deleted": deleted}


def norm_rbw(d, hint=None):
    data = d.get("data") or {}
    typ = hint or infer_type(data)
    custom = []
    for c in d.get("fields") or []:
        ty = str(c.get("type") if c.get("type") is not None else "text").lower()
        custom.append({"name": c.get("name"), "value": c.get("value"), "hidden": ty in ("hidden", "1"),
                       "linked": ty in ("linked", "3")})
    data = dict(data)
    data["uris"] = [u.get("uri") if isinstance(u, dict) else u for u in (data.get("uris") or [])]
    return build_rec(d.get("id") or "", d.get("name"), d.get("folder"), typ, data, custom, d.get("notes"))


def norm_bw(item, folders):
    typ = BW_TYPE.get(item.get("type"), "login")
    src = item.get(BW_TYPE_KEY[typ]) or {}
    data = {snake(k): v for k, v in src.items()}
    if "key_fingerprint" in data:
        data["fingerprint"] = data["key_fingerprint"]
    data["uris"] = [u.get("uri") for u in (src.get("uris") or []) if isinstance(u, dict)]
    custom = [{"name": c.get("name"), "value": c.get("value"), "hidden": c.get("type") == 1,
               "linked": c.get("type") == 3} for c in item.get("fields") or []]
    files = [{"id": a.get("id"), "name": clean(a.get("fileName")), "size": clean(a.get("sizeName") or a.get("size"))}
             for a in item.get("attachments") or []]
    return build_rec(item.get("id") or "", item.get("name"), folders.get(item.get("folderId")), typ, data, custom,
                     item.get("notes"), files, item.get("deletedDate"))


def public(rec):
    """The record without any value: what the metadata index may hold."""
    out = dict(rec)
    out["fields"] = [{k: v for k, v in f.items() if k != "value"} for f in rec["fields"]]
    return out


# ───────────────────────────── metadata index (bw) ─────────────────────────────

def drop_index():
    INDEX.unlink(missing_ok=True)


def bw_open():
    return SESSION.exists() and SESSION.stat().st_size > 0


def build_index():
    """Names, folders, attachments and masked fields of every bw item incl. the trash, or None (bw locked)."""
    if not bw_open() or not have(os.environ.get("BW_BIN", "bw")):
        return None
    m = vbw()
    try:
        raw = {}
        for key, args in (("items", ("list", "items")), ("trash", ("list", "items", "--trash")),
                          ("folders", ("list", "folders"))):
            p = m.bw(*args)
            if p.returncode != 0:
                return None
            raw[key] = json.loads(p.stdout or "[]")
    except (ValueError, SystemExit):
        return None
    folders = {f["id"]: f.get("name") or "" for f in raw["folders"] if f.get("id")}
    items = {}
    for it in raw["items"] + raw["trash"]:
        if it.get("id"):
            items[it["id"]] = public(norm_bw(it, folders))
    idx = {"built": time.time(), "items": items, "trash": [i["id"] for i in raw["trash"] if i.get("id")]}
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    tmp = INDEX.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(idx, f)
    os.replace(tmp, INDEX)
    return idx


def read_index(build=False):
    try:
        idx = json.loads(INDEX.read_text())
        if time.time() - idx.get("built", 0) < INDEX_TTL:
            return idx
    except (OSError, ValueError):
        pass
    return build_index() if build else None


# ───────────────────────────── rbw data ─────────────────────────────

def list_entries():
    p = rbw("list", "--raw")
    if p.returncode != 0:
        return None
    try:
        raw = json.loads(p.stdout or "[]")
    except ValueError:
        return None
    return [{"id": i["id"], "name": i.get("name") or "", "user": i.get("user") or "", "folder": i.get("folder") or "",
             "type": kind_of(i.get("type"))} for i in raw if i.get("id")]


def fetch_rec(ident, hint=None):
    p = rbw("get", "--raw", ident)
    if p.returncode != 0:
        return None
    try:
        return norm_rbw(json.loads(p.stdout), hint)
    except ValueError:
        return None


def totp_code(ident):
    p = rbw("code", ident)
    code = p.stdout.strip()
    return code if p.returncode == 0 and code else None


# ───────────────────────────── state, rows, header ─────────────────────────────

def state_file():
    return Path(os.environ.get("VAULT_BROWSE_STATE") or RUN / "browse-state.json")


def read_state():
    try:
        return json.loads(state_file().read_text())
    except (OSError, ValueError):
        return {"folder": ALL, "folders": [ALL, TRASH], "count": 0}


def write_state(st):
    path = state_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(st, f)


def folder_names(entries):
    names = sorted({e["folder"] for e in entries if e["folder"]}, key=str.lower)
    out = [ALL] + names
    if names and any(not e["folder"] for e in entries):
        out.append(NOFOLDER)
    return out + [TRASH]


def entry_row(e, extra=""):
    tag = TYPE_TAG[e["type"]]
    text = f"{cell(e['name'], 30)} {DIM}{cell(e['folder'] or '—', 12)} {cell(tag, 5)} {clean(e['user']) or extra}{RST}"
    return f"{e['id']}\t{text}"


def build_rows(folder, entries):
    if folder == TRASH:
        idx = read_index(build=True)
        if idx is None:
            return ["@unlock\tThe bw CLI is locked: Enter unlocks it to list the trash"]
        rows = []
        for ident in idx["trash"]:
            r = idx["items"].get(ident)
            if r:
                e = {"id": ident, "name": r["name"], "user": "", "folder": r["folder"], "type": r["type"]}
                rows.append(entry_row(e, "deleted " + str(r.get("deleted") or "")[:10]))
        rows.sort(key=lambda x: x.split("\t")[1].lower())
        return rows or ["@none\tThe trash is empty"]
    sel = [e for e in entries if folder == ALL or e["folder"] == folder or (folder == NOFOLDER and not e["folder"])]
    rows = [entry_row(e) for e in sorted(sel, key=lambda e: (e["name"].lower(), e["user"].lower()))]
    if folder == ALL:
        rows.append("@app\t» Open the Bitwarden app: account settings, emergency access, organisations")
    return rows


def header_text(st):
    """Four short lines (the list pane is narrow next to the preview): folder, then the keys."""
    cur = st.get("folder", ALL)
    folders = st.get("folders") or [ALL]
    pos = folders.index(cur) + 1 if cur in folders else 1
    lock = "" if bw_open() else " · bw locked: b"
    return (f"Folder: {cur} ({pos}/{len(folders)}) · Tab / Shift+Tab: folder{lock}\n"
            "y pass · u user · o totp · f field · t type · P pass only · Enter: type\n"
            "e edit · n new · d trash · r restore · h history · F files · w generator\n"
            "S send · s sync · L lock · b unlock bw · O app · Alt+key: same letter")


def sync_state(step=0):
    """Re-read the folder list from rbw, move the current folder STEP places (Tab: 1, Shift+Tab: -1) and store the
    state. Returns (state, entries); entries is None when rbw cannot be read."""
    st = read_state()
    entries = list_entries()
    if entries is None:
        return st, None
    folders = folder_names(entries)
    cur = st.get("folder", ALL)
    if cur not in folders:
        cur = ALL
    if step:
        cur = folders[(folders.index(cur) + step) % len(folders)]
    st.update(folder=cur, folders=folders, count=len(entries))
    write_state(st)
    return st, entries


def cmd_rows():
    st, entries = sync_state()
    if entries is None:
        print("@none\tCould not read the vault (locked and cancelled?)")
        return 0
    print("\n".join(build_rows(st["folder"], entries)))
    return 0


def cmd_header(argv):
    """The header; with --cycle it first moves the folder (fzf runs this before `rows`, which then lists that folder)."""
    step = 0
    if "--cycle" in argv:
        step = -1 if argv[argv.index("--cycle") + 1] == "prev" else 1
    print(header_text(sync_state(step)[0]))
    return 0


# ───────────────────────────── preview ─────────────────────────────

def seconds_left(period):
    return period - int(time.time()) % period


def render(rec, live=None, files=None):
    t = mod("vault-totp")
    out = [rec["name"], ""]
    meta = f"{TYPE_NAME.get(rec['type'], rec['type'])} · {rec['folder'] or 'no folder'}"
    if rec.get("deleted"):
        meta += f" · in the trash since {str(rec['deleted'])[:10]}"
    out += [f"{DIM}{meta}{RST}", ""]
    for f in rec["fields"]:
        shown = f["shown"]
        if f["kind"] == "totp":
            if live:
                shown = f"{t.group(live[0])} ({live[1]}s)"
            elif live is False:
                shown = "(could not read the code)"
            else:
                shown = MASK
        if len(shown) > 70:
            shown = shown[:69] + "…"
        out.append(f"{DIM}{f['label']:<9}{RST}{shown}")
    files = rec["files"] if files is None else files
    if files:
        out.append("")
        out.append(f"{DIM}{'files':<9}{RST}" + ", ".join(f"{x['name']} ({x['size']})" if x["size"] else x["name"]
                                                          for x in files))
    return "\n".join(out)


def cmd_preview(ident):
    if ident.startswith("@"):
        print({"@app": "Account settings, emergency access, organisation admin and everything else the\n"
                       "app does stay there. Enter opens the desktop app.",
               "@unlock": "Trash, attachments and editing use the official CLI (bw). Enter asks for the master\n"
                          "password once per login (pinentry).",
               }.get(ident, ""))
        return 0
    idx = read_index()
    if idx and ident in idx["trash"] and ident in idx["items"]:
        print(render(idx["items"][ident]))
        print("\nr restores it · d deletes it for good")
        return 0
    rec = fetch_rec(ident)
    if rec is None:
        print("could not read the entry")
        return 0
    live = None
    totp = next((f for f in rec["fields"] if f["kind"] == "totp"), None)
    if totp:
        code = totp_code(ident)
        if code:
            period = mod("vault-totp").period_of(totp["value"])
            live = (code, seconds_left(period))
        else:
            live = False
    files = None
    if idx and ident in idx["items"]:
        files = idx["items"][ident]["files"]
    print(render(rec, live, files))
    return 0


# ───────────────────────────── clipboard and typing ─────────────────────────────

def clip(text, secret=True):
    vbw().copy(text, sensitive=secret)


def tg(snippet, *args):
    """A line of type-guard.sh (the one guard every typing menu uses); stdout of it."""
    p = subprocess.run(["bash", "-c", f'. "{GUARD}"; {snippet}', "_", *args], capture_output=True, text=True)
    return p.stdout.strip(), p.returncode


def type_text(text, prev):
    if not have("wtype"):
        notify("Vault", "wtype is not installed", "critical")
        return False
    if tg('tg_ok "$1" vault', prev)[1] != 0:
        return False   # the guard notified; nothing is typed
    subprocess.run(["wtype", "-"], input=text, text=True, check=False)
    return True


def type_login(user, password, prev, password_only=False):
    time.sleep(0.2)
    if password_only:
        return type_text(password, prev)
    if user and not type_text(user, prev):
        return False
    if user:
        if tg('tg_ok "$1" vault', prev)[1] != 0:
            return False
        subprocess.run(["wtype", "-k", "Tab"], check=False)
    return type_text(password, prev)


# ───────────────────────────── terminal steps ─────────────────────────────

def run_tui(*args):
    """Steps that read the keyboard (editor, prompts) run in this terminal, or in a float.tui window of their own."""
    if is_tty():
        return call_act(*args)
    term = shlex.split(os.environ.get("VAULT_TERMINAL") or "ghostty --class=float.tui --title=vault -e")
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    subprocess.run([*term, sys.executable, "-I", str(SELF), "_act", *args], env=env, check=False)
    return 0


def shred(path):
    path = Path(path)
    if not path.exists():
        return
    if have("shred"):
        subprocess.run(["shred", "-u", str(path)], check=False)
    if path.exists():
        try:
            path.write_bytes(b"\0" * path.stat().st_size)
        except OSError:
            pass
        path.unlink(missing_ok=True)


def editor_cmd(path):
    ed = shlex.split(os.environ.get("VISUAL") or os.environ.get("EDITOR") or ("nvim" if have("nvim") else "vi"))
    if os.path.basename(ed[0]) in ("nvim", "vim", "vi"):
        # no swap, undo, backup or viminfo copy of a file full of secrets
        ed += ["-n", "-i", "NONE", "-c", "setlocal noundofile noswapfile nobackup nowritebackup"]
    return [*ed, str(path)]


def edit_json(obj, validate):
    """Edit OBJ as JSON in $EDITOR in a 600 file on tmpfs; returns the validated object or None (discarded).
    VALIDATE(new) returns an error text or ''. The file is shredded in every case."""
    EDIT_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(EDIT_DIR, 0o700)
    path = EDIT_DIR / f"{secrets.token_hex(8)}.json"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    try:
        while True:
            subprocess.run(editor_cmd(path), check=False)
            try:
                new = json.loads(path.read_text())
                err = validate(new)
            except ValueError as e:
                err = f"not valid JSON: {e}"
            if not err:
                return new
            print(f"Cannot save: {err}")
            try:
                again = input("[e] edit again, anything else discards: ").strip().lower().startswith("e")
            except (EOFError, KeyboardInterrupt):
                again = False
            if not again:
                return None
    finally:
        shred(path)


def folder_of(m, item):
    return m.folder_map().get(item.get("folderId")) or ""


def act_edit(ident):
    m = vbw()
    m.ensure()
    item = m.bw_json("get", "item", ident)
    old_folder = folder_of(m, item)
    work = dict(item)
    work["_folder"] = old_folder or None

    def validate(new):
        if not isinstance(new, dict):
            return "the top level must be an object"
        if new.get("id") != item.get("id"):
            return "the id must not change"
        if new.get("type") != item.get("type"):
            return "the type must not change"
        if not isinstance(new.get("name"), str) or not new["name"].strip():
            return "the name must be a non-empty string"
        return ""

    new = edit_json(work, validate)
    if new is None:
        m.finish("Edit discarded")
        return
    new_folder = new.pop("_folder", None) or ""
    if new == item and new_folder == old_folder:
        m.finish("No changes", item.get("name") or "")
        return
    if new_folder != old_folder:
        new["folderId"] = m.folder_id(new_folder)
    p = m.bw("edit", "item", ident, stdin=m.b64(new))
    new = work = item = None
    if p.returncode != 0:
        m.die(f"could not save the item: {m.first_line(p.stderr or p.stdout)}")
    drop_index()
    m.refresh_rbw()
    m.finish("Saved", "rbw synced")


def act_new_template(typ, folder):
    m = vbw()
    m.ensure()
    tpl_name = {"card": "item.card", "identity": "item.identity", "note": "item.securenote", "ssh": "item.sshkey"}[typ]
    item = m.bw_json("get", "template", "item")
    p = m.bw("get", "template", tpl_name)
    try:
        sub = json.loads(p.stdout) if p.returncode == 0 else None
    except ValueError:
        sub = None
    if sub is None:
        if typ != "ssh":
            m.die(f"bw has no template {tpl_name}")
        sub = {"privateKey": "", "publicKey": "", "keyFingerprint": ""}
    item.update(type={v: k for k, v in BW_TYPE.items()}[typ], name="", notes=None, favorite=False, fields=[],
                folderId=None, login=None, secureNote=None, card=None, identity=None)
    item[BW_TYPE_KEY[typ]] = sub if typ != "note" else {"type": 0}
    item["_folder"] = folder if folder not in (ALL, NOFOLDER, TRASH) else None

    def validate(new):
        if not isinstance(new, dict):
            return "the top level must be an object"
        if new.get("type") != item["type"]:
            return "the type must not change"
        if not isinstance(new.get("name"), str) or not new["name"].strip():
            return "give the item a name"
        return ""

    new = edit_json(item, validate)
    if new is None:
        m.finish("New item discarded")
        return
    new["folderId"] = m.folder_id(new.pop("_folder", None) or "")
    p = m.bw("create", "item", stdin=m.b64(new))
    name = new.get("name")
    new = item = None
    if p.returncode != 0:
        m.die(f"could not create the item: {m.first_line(p.stderr or p.stdout)}")
    drop_index()
    m.refresh_rbw()
    m.finish(f"Created {name}", "rbw synced")


def act_new_login(folder):
    vbw().cmd_new_login(folder if folder not in (ALL, NOFOLDER, TRASH) else None)
    drop_index()


ACTS = {
    "edit": lambda a: act_edit(a[0]),
    "new-login": lambda a: act_new_login(a[0] if a else ""),
    "new-tpl": lambda a: act_new_template(a[0], a[1] if len(a) > 1 else ""),
    "gen": lambda a: vbw().cmd_generate(),
    "send-text": lambda a: vbw().cmd_send_text(),
    "send-file": lambda a: vbw().cmd_send_file(),
}


def call_act(name, *args):
    try:
        ACTS[name](list(args))
    except (KeyboardInterrupt, EOFError):
        print()
    except SystemExit:
        pass   # vault-bw.py's die() already showed the reason
    return 0


# ───────────────────────────── actions that need no terminal ─────────────────────────────

def copy_field(rec, f):
    if f["kind"] == "totp":
        code = totp_code(rec["id"])
        if not code:
            notify("Vault", "Could not read the TOTP code", "critical")
            return
        period = mod("vault-totp").period_of(f["value"])
        clip(code)
        notify("2FA code copied", f"{rec['name']}: valid for {seconds_left(period)} s, clipboard clears in 30 s")
        return
    clip(f["value"], secret=f["secret"])
    noun = {"pass": "Password", "user": "User name", "number": "Card number", "cvv": "Card CVV",
            "private": "Private key"}.get(f["label"], f["label"].capitalize())
    notify(f"{noun} copied", f"{rec['name']}" + (" · cleared in 30 s" if f["secret"] else ""))


def pick_field(rec):
    rows = [f"{i}\t{f['label']:<9} {f['shown'] if f['kind'] != 'totp' else 'live code'}"
            for i, f in enumerate(rec["fields"]) if f["value"]]
    if not rows:
        notify("Vault", "This item has nothing to copy")
        return None
    row = pick(rows, "field", f"{rec['name']}: Enter copies the field (secrets: cleared in 30 s)")
    return rec["fields"][int(row.split("\t")[0])] if row else None


def act_history(ident, name):
    p = rbw("history", ident)
    entries = []
    for line in p.stdout.splitlines():
        if ": " in line:
            when, pw = line.split(": ", 1)
            entries.append((when.strip(), pw))
    if p.returncode != 0 or not entries:
        notify("Vault", f"{name} has no old passwords")
        return
    rows = [f"{n}\t{when}\t{'*' * min(len(pw), 16)}" for n, (when, pw) in enumerate(entries)]
    row = pick(rows, "history", f"{name}: Enter copies that old password (sensitive, cleared in 30 s)")
    if row:
        clip(entries[int(row.split("\t")[0])][1])
        notify("Old password copied", f"{name} · cleared in 30 s")


def act_files(ident, name):
    m = vbw()
    m.ensure()
    item = m.bw_json("get", "item", ident)
    atts = item.get("attachments") or []
    rows = ["@up\tUpload a file..."] + [
        f"{a['id']}\tdownload  {clean(a.get('fileName'))}  {clean(a.get('sizeName') or a.get('size'))}" for a in atts]
    row = pick(rows, "files", f"{name}: Enter downloads into {m.DOWNLOADS} (never overwrites)")
    if not row:
        return
    key = row.split("\t")[0]
    if key == "@up":
        path = m.pick_file("upload")
        p = m.bw("create", "attachment", "--file", path, "--itemid", ident)
        if p.returncode != 0:
            m.die(f"upload failed: {m.first_line(p.stderr or p.stdout)}")
        drop_index()
        m.finish("Attachment uploaded", f"{os.path.basename(path)} -> {name}")
        return
    att = next(a for a in atts if a["id"] == key)
    m.DOWNLOADS.mkdir(parents=True, exist_ok=True)
    target = m.free_path(m.DOWNLOADS, m.safe_name(att.get("fileName")))
    p = m.bw("get", "attachment", key, "--itemid", ident, "--output", str(target))
    if p.returncode != 0:
        m.die(f"download failed: {m.first_line(p.stderr or p.stdout)}")
    m.finish("Attachment saved", str(target))


def act_delete(ident, name, permanent):
    m = vbw()
    if permanent:
        if not confirm(f"Delete \"{name}\" for good? This cannot be undone."):
            return
        m.ensure()
        p = m.bw("delete", "item", ident, "--permanent")
        msg = f"Deleted for good: {name}"
    else:
        if not confirm(f"Move \"{name}\" to the trash? (restorable for 30 days)"):
            return
        m.ensure()
        p = m.bw("delete", "item", ident)
        msg = f"Moved to the trash: {name}"
    if p.returncode != 0:
        m.die(f"delete failed: {m.first_line(p.stderr or p.stdout)}")
    drop_index()
    m.refresh_rbw()
    m.finish(msg)


def act_restore(ident, name):
    m = vbw()
    m.ensure()
    p = m.bw("restore", "item", ident)
    if p.returncode != 0:
        m.die(f"restore failed: {m.first_line(p.stderr or p.stdout)}")
    drop_index()
    m.refresh_rbw()
    m.finish(f"Restored: {name}", "rbw synced")


def pick_new_type():
    row = pick(["login\tLogin (generated password)", "card\tCard", "identity\tIdentity", "note\tSecure note",
                "ssh\tSSH key"], "new", "New item: pick the type")
    return row.split("\t")[0] if row else None


def vault_sh(*args):
    return subprocess.run([str(VAULT_SH), *args], check=False).returncode


# ───────────────────────────── the loop ─────────────────────────────

def menu_args(sock):
    me = f"python3 -I {shlex.quote(str(SELF))}"
    binds = "\n".join(f'{k}:become(printf "%s\\n%s\\n%s\\n" {{q}} {a} {{1}})' for k, a in NORMAL_KEYS)
    args = ["-p", "vault", "--delimiter=\t", "--with-nth=2..", "--tabstop=4", "--print-query",
            "--expect=" + ",".join(ALT_KEYS),
            f"--bind=tab:transform-header({me} header --cycle next)+reload-sync({me} rows)",
            f"--bind=shift-tab:transform-header({me} header --cycle prev)+reload-sync({me} rows)",
            f"--preview={me} preview {{1}}", "--preview-window=right,45%,wrap,border-left",
            f"--listen={sock}"]
    return args, binds


def run_menu(rows, st, sock, here):
    args, binds = menu_args(sock)
    env = dict(os.environ, FZF_MENU_NORMAL_BINDS=binds)
    cmd = ["fzf-menu"] + (["--here"] if here else []) + args + [f"--header={header_text(st)}"]
    p = subprocess.run(cmd, input="\n".join(rows) + "\n", stdout=subprocess.PIPE, text=True, env=env)
    lines = p.stdout.split("\n")
    query = lines[0] if lines else ""
    key = lines[1] if len(lines) > 1 else ""
    ident = (lines[2] if len(lines) > 2 else "").split("\t")[0]
    return p.returncode, query, key, ident


def start_ticker(sock):
    """Tick the preview once a second (live TOTP code and countdown) through the fzf --listen socket."""
    stop = threading.Event()

    def loop():
        while not stop.wait(1.0):
            if os.path.exists(sock) and have("curl"):
                subprocess.run(["curl", "-s", "--max-time", "1", "--unix-socket", sock, "-X", "POST",
                                "http://localhost", "-d", "refresh-preview"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)

    t = threading.Thread(target=loop, daemon=True)
    t.start()
    return stop


def read_item_action(action, ident, entry, ctx):
    """Copy or type from one rbw item; True when something was copied or typed (the browser then closes)."""
    rec = fetch_rec(ident, (entry or {}).get("type"))
    if rec is None:
        notify("Vault", "Could not read the item (locked and cancelled?)", "critical")
        return False
    by_label = {f["label"]: f for f in rec["fields"]}
    f = None
    done = False
    if action == "pass":
        f = next((x for x in rec["fields"] if x["primary"] and x["value"]), None) or pick_field(rec)
    elif action == "user":
        f = by_label.get("user")
        if not (f and f["value"]):
            f = None
            notify("Vault", "This item has no user name")
    elif action == "totp":
        f = next((x for x in rec["fields"] if x["kind"] == "totp"), None)
        if f is None:
            notify("Vault", "This item has no TOTP key")
    elif action == "field":
        f = pick_field(rec)
    elif rec["type"] != "login" or "pass" not in by_label:
        notify("Vault", "Only logins can be typed: f copies a field")
    else:
        done = type_login(by_label["user"]["value"], by_label["pass"]["value"], ctx["prev"], action == "passonly")
    if f is not None:
        copy_field(rec, f)
        done = True
    rec = by_label = f = None
    return done


def act_dispatch(action, ident, ctx):
    """Run one action; returns True to keep browsing, False to leave."""
    entry = ctx["entries"].get(ident)
    folder = ctx["folder"]
    in_trash = folder == TRASH
    if action in NEEDS_ITEM and (not ident or ident.startswith("@")):
        notify("Vault", "No item selected")
        return True
    if in_trash and action in NEEDS_ITEM and action not in TRASH_OK:
        notify("Vault", "This item is in the trash: r restores it, d deletes it for good")
        return True
    name = (entry or {}).get("name") or ident
    if in_trash:
        name = ((read_index() or {"items": {}})["items"].get(ident) or {}).get("name") or ident

    if action == "enter":
        if ident == "@app":
            vault_sh("app")
            return False
        if ident == "@unlock":
            action = "unlock"
        elif not ident or ident.startswith("@"):
            return True
        elif in_trash:
            action = "restore"
        else:
            action = "type" if (entry or {}).get("type") == "login" else "field"

    if action in ("pass", "user", "totp", "field", "type", "passonly"):
        return not read_item_action(action, ident, entry, ctx)

    if action == "edit":
        run_tui("edit", ident)
    elif action == "new":
        typ = pick_new_type()
        if typ == "login":
            run_tui("new-login", folder)
        elif typ:
            run_tui("new-tpl", typ, folder)
    elif action == "del":
        vbw_call(act_delete, ident, name, in_trash)
    elif action == "restore":
        if not in_trash:
            notify("Vault", "Restore works in the Trash folder (Tab to it)")
        else:
            vbw_call(act_restore, ident, name)
    elif action == "hist":
        act_history(ident, name)
    elif action == "files":
        vbw_call(act_files, ident, name)
    elif action == "gen":
        run_tui("gen")
    elif action == "send":
        row = pick(["send-text\tText", "send-file\tFile"], "send", "Bitwarden Send: what to share?")
        if row:
            run_tui(row.split("\t")[0])
    elif action == "sync":
        vault_sh("sync")
        drop_index()
    elif action == "lock":
        vault_sh("lock")
        return False
    elif action == "unlock":
        vbw_call(lambda: vbw().ensure())
        drop_index()
    elif action == "app":
        vault_sh("app")
        return False
    return True


def vbw_call(fn, *args):
    try:
        fn(*args)
    except SystemExit:
        pass   # vault-bw.py's die() already showed the reason (and waited for Enter in a terminal)
    except (KeyboardInterrupt, EOFError):
        print()


def browse(here_flag, folder0):
    here = here_flag or is_tty()
    if not have("fzf-menu"):
        notify("Vault", "fzf-menu is not installed", "critical")
        return 1
    if not have(RBW):
        notify("Vault", "rbw is not installed (sudo ./apply-system.sh --only install)", "critical")
        return 1
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    state = RUN / f"browse-state.{os.getpid()}.json"
    os.environ["VAULT_BROWSE_STATE"] = str(state)
    prev, _ = tg("tg_record \"$@\"", *(["--here"] if here else []))
    sock = str(RUN / f"fzf-browse.{os.getpid()}.sock")
    st = {"folder": folder0 or ALL, "folders": [ALL, TRASH], "count": 0}
    stop = start_ticker(sock)
    try:
        while True:
            entries = list_entries()
            if entries is None:
                notify("Vault", "Could not read the vault (locked and cancelled?)", "critical")
                return 1
            poke_bar()
            if bw_open():
                read_index(build=True)
            folders = folder_names(entries)
            if st["folder"] not in folders:
                st["folder"] = ALL
            st.update(folders=folders, count=len(entries))
            write_state(st)
            rows = build_rows(st["folder"], entries)
            rc, _query, key, ident = run_menu(rows, st, sock, here)
            action = ALT_KEYS.get(key, key) if key else ("enter" if rc == 0 else "")
            if not action:
                return 0
            st = read_state()   # Tab inside fzf moved the folder
            ctx = {"entries": {e["id"]: e for e in entries}, "folder": st["folder"], "prev": prev}
            if not act_dispatch(action, ident, ctx):
                return 0
    finally:
        stop.set()
        state.unlink(missing_ok=True)
        try:
            os.unlink(sock)
        except OSError:
            pass
        poke_bar()


def main(argv):
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv and argv[0] == "rows":
        return cmd_rows()
    if argv and argv[0] == "header":
        return cmd_header(argv[1:])
    if argv and argv[0] == "preview" and len(argv) > 1:
        return cmd_preview(argv[1])
    if argv and argv[0] == "_act" and len(argv) > 1:
        return call_act(*argv[1:])
    here = "--here" in argv
    rest = [a for a in argv if a != "--here"]
    return browse(here, rest[0] if rest else "")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
