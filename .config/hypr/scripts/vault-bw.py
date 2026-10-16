#!/usr/bin/env python3
"""vault-bw: actions on the official Bitwarden CLI (bw) next to rbw. Python 3 stdlib only.

Run through `vault.sh bw CMD` (hub rows in actions.d/u6.tsv, interactive ones in a float.tui terminal).

  vault-bw.py unlock          ask for the master password with pinentry and open a bw session (nothing happens when
                              the session is already open)
  vault-bw.py lock            `bw lock` and drop the stored session
  vault-bw.py state           print missing|unconfigured|locked|unlocked, exit 0 only when unlocked
  vault-bw.py new-login       name, username, URI, generated password -> a new login item (bw create item)
  vault-bw.py generate        password / passphrase generator, the result goes to the clipboard (sensitive)
  vault-bw.py edit            pick a login and edit it with `rbw edit` ($EDITOR; password and notes)
  vault-bw.py history         pick a login, pick an old password from `rbw history`, copy it (sensitive)
  vault-bw.py send-text       Bitwarden Send with a text, the link is copied
  vault-bw.py send-file       Bitwarden Send with a file picked from fd results, the link is copied
  vault-bw.py attach-get      pick an item with attachments, download one into ~/Downloads
  vault-bw.py attach-add      pick an item, pick a file, upload it as an attachment
  vault-bw.py delete          pick an item, type its name to confirm, move it to the Bitwarden trash
  vault-bw.py sync            bw sync (needs an open session)
  vault-bw.py import-csv FILE unlock, `bw import bitwardencsv FILE`, `bw sync` + `rbw sync`, drop the 2FA index (used by
                              2fa-import; the file is a path, never a secret on the command line)

Secrets: the master password only travels pinentry -> this process -> the environment of ONE `bw unlock` child
(--passwordenv), never argv, never a file. The session key lives in $XDG_RUNTIME_DIR/vault/bw-session (tmpfs, mode 600)
and reaches `bw` as BW_SESSION in that child's environment. Item JSON (with the new password) and the Send password
go to bw on stdin, never argv. Generated and old passwords are copied with `wl-copy --sensitive` and cleared in 30 s.
A Send link is meant to be shared, so it is copied plainly.
Test hooks: BW_BIN, RBW_BIN, PINENTRY_BIN, BW_DOWNLOAD_DIR, EDITOR.
"""
import base64
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

BW = os.environ.get("BW_BIN", "bw")
RBW = os.environ.get("RBW_BIN", "rbw")
HERE = Path(__file__).resolve().parent
TOTP_PY = HERE / "vault-totp.py"
RUN = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "vault"
SESSION = RUN / "bw-session"
CONF_HOME = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
RBW_CONF = CONF_HOME / "rbw" / "config.json"
DOWNLOADS = Path(os.environ.get("BW_DOWNLOAD_DIR") or Path.home() / "Downloads")
os.umask(0o077)


# ───────────────────────────── helpers ─────────────────────────────

def have(cmd):
    return shutil.which(cmd) is not None


def interactive():
    return sys.stdin.isatty() and sys.stderr.isatty()


def notify(title, body="", urgency="low"):
    if have("notify-send"):
        subprocess.run(
            ["notify-send", "-a", "vault", "-u", urgency, "-t", "5000",
             "-h", "string:x-dunst-stack-tag:vault", title, body],
            check=False,
        )


def poke_bar():
    subprocess.run(["pkill", "-o", "-u", str(os.getuid()), "-RTMIN+15", "-x", "waybar"], check=False, stderr=subprocess.DEVNULL)


def die(msg, code=1):
    print(msg, file=sys.stderr)
    notify("Vault", msg, "critical")
    if interactive():
        try:
            input("press Enter to close ")
        except (EOFError, KeyboardInterrupt):
            pass
    sys.exit(code)


def finish(title, body=""):
    """Success: a notification, a line in the terminal and a short moment to read it."""
    print(title + (": " + body if body else ""))
    notify(title, body)
    if interactive():
        time.sleep(1.0)


def ask(label, default=""):
    suffix = f" [{default}]" if default else ""
    val = input(f"{label}{suffix}: ").strip()
    return val or default


def secret_prompt(label):
    return getpass.getpass(f"{label}: ")


# ───────────────────────────── bw runner and session ─────────────────────────────

def read_session():
    try:
        return SESSION.read_text().strip()
    except OSError:
        return ""


def write_session(key):
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    tmp = RUN / "bw-session.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(key)
    os.replace(tmp, SESSION)


def drop_session():
    SESSION.unlink(missing_ok=True)


def bw(*args, stdin=None, session=True, extra_env=None):
    env = dict(os.environ)
    env.pop("BW_SESSION", None)
    env["BW_NOINTERACTION"] = "true"
    env["NODE_NO_WARNINGS"] = "1"
    key = read_session() if session else ""
    if key:
        env["BW_SESSION"] = key
    if extra_env:
        env.update(extra_env)
    try:
        return subprocess.run([BW, *args], input=stdin, capture_output=True, text=True, env=env)
    except FileNotFoundError:
        die("bw is not installed (sudo ~/dotfiles/apply-system.sh --only install)")


def bw_json(*args, stdin=None):
    p = bw(*args, stdin=stdin)
    if p.returncode != 0:
        die(f"bw {' '.join(args[:2])} failed: {first_line(p.stderr or p.stdout)}")
    try:
        return json.loads(p.stdout)
    except ValueError:
        die(f"bw {' '.join(args[:2])} returned something that is not JSON")


def first_line(text):
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()[:200]
    return "no details"


def b64(obj):
    return base64.b64encode(json.dumps(obj).encode()).decode()


def status():
    """unauthenticated | locked | unlocked, or None when bw is missing or does not answer."""
    if not have(BW):
        return None
    p = bw("status")
    try:
        return json.loads(p.stdout).get("status")
    except ValueError:
        return None


def state():
    if not have(BW):
        return "missing"
    st = status()
    if st == "unauthenticated":
        return "unconfigured"
    if st == "unlocked":
        return "unlocked"
    return "locked"


# ───────────────────────────── pinentry and unlock ─────────────────────────────

def pinentry_bin():
    override = os.environ.get("PINENTRY_BIN")
    if override:
        return override
    try:
        cfg = json.loads(RBW_CONF.read_text()).get("pinentry")
        if cfg:
            return cfg
    except (OSError, ValueError):
        pass
    for cand in (shutil.which("pinentry-themed"), str(Path.home() / ".local/bin/pinentry-themed"),
                 shutil.which("pinentry")):
        if cand and os.access(cand, os.X_OK):
            return cand
    die("no pinentry found (run bw-setup, or install pinentry)")


def pin_escape(text):
    return text.replace("%", "%25").replace("\n", "%0A").replace("\r", "%0D")


def pin_ask(desc, error=None, prompt="Master password:"):
    """Run pinentry (Assuan) and return the typed secret, or None when cancelled."""
    lines = ["SETTITLE Bitwarden CLI", f"SETDESC {pin_escape(desc)}", f"SETPROMPT {prompt}"]
    if error:
        lines.append(f"SETERROR {pin_escape(error)}")
    lines += ["GETPIN", "BYE"]
    try:
        p = subprocess.run([pinentry_bin()], input=("\n".join(lines) + "\n").encode(),
                           capture_output=True)
    except OSError as e:
        die(f"could not start pinentry: {e}")
    for line in p.stdout.splitlines():
        if line.startswith(b"D "):
            data = re.sub(rb"%([0-9A-Fa-f]{2})", lambda m: bytes([int(m.group(1), 16)]), line[2:])
            return data.decode("utf-8", "replace")
        if line.startswith(b"ERR"):
            return None
    return None


def unlock():
    st = status()
    if st == "unlocked":
        return
    if st is None:
        die("bw is not installed or does not answer")
    if st == "unauthenticated":
        die("bw is not logged in: run bw-setup in a terminal first")
    error = None
    for _ in range(3):
        pw = pin_ask("Unlock the Bitwarden CLI session for this login.\nIt stays open until you lock the vault "
                     "or log in again.", error)
        if pw is None:
            print("cancelled", file=sys.stderr)
            sys.exit(1)
        p = bw("unlock", "--raw", "--passwordenv", "BWV_MP", session=False, extra_env={"BWV_MP": pw})
        pw = None
        key = p.stdout.strip()
        if p.returncode == 0 and key:
            write_session(key)
            sync_quiet()
            poke_bar()
            return
        error = "Wrong master password, try again." if "nvalid" in (p.stderr + p.stdout) \
            else first_line(p.stderr or p.stdout)
    die("could not unlock the Bitwarden CLI")


def sync_quiet():
    bw("sync")


def ensure():
    if not have(BW):
        die("bw is not installed (sudo ~/dotfiles/apply-system.sh --only install)")
    unlock()


def cmd_lock():
    if have(BW) and status() not in (None, "unauthenticated"):
        bw("lock", session=True)
    drop_session()
    poke_bar()


# ───────────────────────────── clipboard, pickers, rbw ─────────────────────────────

def copy(text, sensitive=True):
    if not have("wl-copy"):
        die("wl-copy is not installed")
    cmd = ["wl-copy", "--sensitive"] if sensitive else ["wl-copy"]
    subprocess.run(cmd, input=text, text=True, check=True)
    if sensitive:
        subprocess.run([sys.executable, "-I", str(TOTP_PY), "arm-clear"], check=False)


def rbw_ready():
    if not have(RBW):
        return False
    try:
        return json.loads(RBW_CONF.read_text()).get("email") is not None
    except (OSError, ValueError):
        return False


def refresh_rbw():
    """Make rbw see what bw changed: sync it and drop the cached 2FA index."""
    if rbw_ready():
        subprocess.run([RBW, "sync"], check=False)
    if TOTP_PY.exists():
        subprocess.run([sys.executable, "-I", str(TOTP_PY), "forget"], check=False)
    poke_bar()


def fzf(rows, prompt, header="", print_query=False):
    """Pick one row (tab separated, the first column is the id and stays hidden). Returns the row or None.
    The list is the shared modal fzf (fzf-menu --here: INSERT/NORMAL, Ctrl+j/k, Esc)."""
    if not have("fzf-menu"):
        die("fzf-menu is not installed (~/.local/bin/fzf-menu)")
    cmd = ["fzf-menu", "--here", "-p", prompt, "--delimiter=\t", "--with-nth=2..", "--tabstop=4"]
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


def clean(s):
    return str(s or "").replace("\t", " ").replace("\n", " ")


def list_items():
    items = bw_json("list", "items")
    return [i for i in items if not i.get("deletedDate")]


def item_rows(items, with_attachments=False):
    rows = []
    for i in sorted(items, key=lambda i: (i.get("name") or "").lower()):
        user = ((i.get("login") or {}).get("username")) or ""
        n = len(i.get("attachments") or [])
        extra = f"   [{n} file{'s' if n != 1 else ''}]" if with_attachments else ""
        rows.append(f"{i['id']}\t{clean(i.get('name'))}\t{clean(user)}{extra}")
    return rows


def pick_item(prompt, items=None, with_attachments=False, header=""):
    items = items if items is not None else list_items()
    if not items:
        die("no items to pick from")
    row = fzf(item_rows(items, with_attachments), prompt, header)
    if not row:
        sys.exit(0)
    ident = row.split("\t")[0]
    return next(i for i in items if i["id"] == ident)


def pick_file(prompt="file"):
    """fzf over fd results (type a full path to use a file outside the list)."""
    home = str(Path.home())
    if have("fd"):
        p = subprocess.run(["fd", "--type", "f", "--max-depth", "6", "--exclude", ".git",
                            "--exclude", "node_modules", ".", home],
                           capture_output=True, text=True)
        paths = p.stdout.splitlines()
    else:
        p = subprocess.run(["find", home, "-maxdepth", "6", "-type", "f", "-not", "-path", "*/.*"],
                           capture_output=True, text=True)
        paths = p.stdout.splitlines()
    rows = [f"{x}\t{x.replace(home, '~', 1)}" for x in paths]
    row, query = fzf(rows, prompt, "Enter: choose the file    or type a full path", print_query=True)
    path = row.split("\t")[0] if row else os.path.expanduser(query.strip())
    if not path or not os.path.isfile(path):
        die("no file chosen")
    return path


# ───────────────────────────── generator ─────────────────────────────

def generate_password(*opts):
    p = bw("generate", *opts, session=False)
    pw = p.stdout.strip()
    if p.returncode != 0 or not pw:
        die(f"bw generate failed: {first_line(p.stderr)}")
    return pw


PRESETS = [
    ("pw20", "Password, 20 characters: letters and digits", ["-uln", "--length", "20"]),
    ("pw32", "Password, 32 characters: letters, digits, symbols", ["-ulns", "--length", "32"]),
    ("pw12", "Password, 12 characters: letters and digits (short limits)", ["-uln", "--length", "12"]),
    ("pp4", "Passphrase, 4 words (Title-Case, a digit)", ["-p", "--words", "4", "--separator", "-", "-c",
                                                          "--includeNumber"]),
    ("pp6", "Passphrase, 6 words", ["-p", "--words", "6", "--separator", "-"]),
    ("pin6", "PIN, 6 digits", ["-n", "--length", "6"]),
    ("custom", "Custom length / symbols...", None),
]


def cmd_generate():
    row = fzf([f"{k}\t{label}" for k, label, _ in PRESETS], "generate",
              "Enter: copy to the clipboard (sensitive, cleared in 30 s)")
    if not row:
        return
    key = row.split("\t")[0]
    opts = next(o for k, _, o in PRESETS if k == key)
    if opts is None:
        try:
            length = max(5, int(ask("Length", "24")))
        except ValueError:
            die("the length must be a number")
        symbols = ask("Symbols (y/N)", "n").lower().startswith("y")
        opts = ["-uln" + ("s" if symbols else ""), "--length", str(length)]
    pw = generate_password(*opts)
    copy(pw)
    finish("Generated and copied", "sensitive clipboard, cleared in 30 s")


# ───────────────────────────── new login ─────────────────────────────

def cmd_new_login():
    ensure()
    name = ask("Name")
    if not name:
        die("a name is required")
    username = ask("Username / e-mail")
    uri = ask("URI (https://...)")
    mode = ask("Password: [g]enerate 24 (letters, digits)  [s]ymbols too  [p]assphrase  [m]anual", "g").lower()[:1]
    if mode == "m":
        pw = secret_prompt("Password (hidden)")
        if not pw:
            die("empty password")
    elif mode == "s":
        pw = generate_password("-ulns", "--length", "24")
    elif mode == "p":
        pw = generate_password("-p", "--words", "5", "--separator", "-", "-c", "--includeNumber")
    else:
        pw = generate_password("-uln", "--length", "24")

    item = bw_json("get", "template", "item")
    login = bw_json("get", "template", "item.login")
    login.update(username=username or None, password=pw, totp=None,
                 uris=[{"match": None, "uri": uri}] if uri else [])
    item.update(type=1, name=name, notes=None, favorite=False, folderId=None, fields=[],
                login=login, secureNote=None, card=None, identity=None)
    p = bw("create", "item", stdin=b64(item))
    item = login = None
    if p.returncode != 0:
        die(f"could not create the item: {first_line(p.stderr or p.stdout)}")
    copy(pw)
    pw = None
    refresh_rbw()
    finish(f"Created {name}", "password copied (sensitive, cleared in 30 s); rbw synced")


# ───────────────────────────── rbw: edit and history ─────────────────────────────

def rbw_items():
    if not rbw_ready():
        die("rbw is not set up (run bw-setup)")
    p = subprocess.run([RBW, "list", "--raw"], capture_output=True, text=True)
    if p.returncode != 0:
        die(f"rbw list failed: {first_line(p.stderr)}")
    out = []
    for i in json.loads(p.stdout or "[]"):
        if str(i.get("type", "")).lower() == "login":
            out.append({"id": i.get("id"), "name": i.get("name"),
                        "login": {"username": i.get("user")}, "attachments": []})
    return out


def cmd_edit():
    item = pick_item("edit", rbw_items(), header="rbw edit: password (first line) and notes in $EDITOR. "
                     "Name, username and URI: use the desktop app")
    env = dict(os.environ)
    if not env.get("VISUAL") and not env.get("EDITOR"):
        env["EDITOR"] = "nvim" if have("nvim") else "vi"
    rc = subprocess.run([RBW, "edit", item["id"]], env=env).returncode
    if rc != 0:
        die(f"rbw edit failed (exit {rc})")
    refresh_rbw()
    finish(f"Saved {item['name']}")


def cmd_history():
    item = pick_item("history", rbw_items())
    p = subprocess.run([RBW, "history", item["id"]], capture_output=True, text=True)
    if p.returncode != 0:
        die(f"rbw history failed: {first_line(p.stderr)}")
    entries = []
    for line in p.stdout.splitlines():
        if ": " in line:
            when, pw = line.split(": ", 1)
            entries.append((when.strip(), pw))
    if not entries:
        die(f"{item['name']} has no old passwords")
    rows = [f"{n}\t{when}\t{'*' * min(len(pw), 16)}" for n, (when, pw) in enumerate(entries)]
    row = fzf(rows, "history", "Enter: copy that old password (sensitive, cleared in 30 s)")
    if not row:
        return
    copy(entries[int(row.split("\t")[0])][1])
    entries = None
    finish("Old password copied", "sensitive clipboard, cleared in 30 s")


# ───────────────────────────── Bitwarden Send ─────────────────────────────

def iso_in(days):
    when = datetime.now(timezone.utc) + timedelta(days=days)
    return when.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def send_options(send):
    """Ask the shared Send options and write them into the template object."""
    try:
        days = float(ask("Delete after how many days", "1"))
        count = ask("Max access count (empty = unlimited)")
        count = int(count) if count else None
    except ValueError:
        die("days and the access count must be numbers")
    pw = secret_prompt("Password for the link (empty = none)")
    send.update(notes=None, deletionDate=iso_in(days), expirationDate=None,
                maxAccessCount=count, password=pw or None, emails=None, disabled=False, hideEmail=False)


def create_send(send, *extra):
    p = bw("send", "create", *extra, stdin=b64(send))
    send["password"] = None
    if p.returncode != 0:
        die(f"could not create the Send: {first_line(p.stderr or p.stdout)}")
    try:
        link = json.loads(p.stdout).get("accessUrl")
    except ValueError:
        link = None
    if not link:
        die("the Send was created but bw returned no link (see the web vault)")
    copy(link, sensitive=False)
    finish("Send link copied", link.split("#")[0] + "#...")


def cmd_send_text():
    ensure()
    print("Text to send. Finish with an empty line.")
    lines = []
    while True:
        line = input()
        if not line and lines:
            break
        if not line and not lines:
            continue
        lines.append(line)
    send = bw_json("send", "template", "send.text")
    send.update(type=0, name=ask("Name", "Send " + datetime.now().strftime("%Y-%m-%d %H:%M")),
                text={"text": "\n".join(lines), "hidden": False}, file=None)
    send_options(send)
    create_send(send)


def cmd_send_file():
    ensure()
    path = pick_file("send file")
    send = bw_json("send", "template", "send.file")
    send.update(type=1, name=ask("Name", os.path.basename(path)), text=None,
                file={"fileName": os.path.basename(path)})
    send_options(send)
    create_send(send, "--file", path)


# ───────────────────────────── attachments ─────────────────────────────

def safe_name(name):
    base = os.path.basename((name or "").replace("\\", "/"))
    if base in ("", ".", ".."):
        base = "attachment"
    return base


def free_path(directory, name):
    target = directory / name
    stem, suffix = target.stem, target.suffix
    n = 1
    while target.exists():
        target = directory / f"{stem} ({n}){suffix}"
        n += 1
    return target


def cmd_attach_get():
    ensure()
    items = [i for i in list_items() if i.get("attachments")]
    if not items:
        die("no item has attachments")
    item = pick_item("attachments", items, with_attachments=True)
    rows = [f"{a['id']}\t{clean(a.get('fileName'))}\t{clean(a.get('sizeName') or a.get('size'))}"
            for a in item["attachments"]]
    row = fzf(rows, "download", f"{item['name']}: Enter downloads into {DOWNLOADS}")
    if not row:
        return
    att_id = row.split("\t")[0]
    att = next(a for a in item["attachments"] if a["id"] == att_id)
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    target = free_path(DOWNLOADS, safe_name(att.get("fileName")))
    p = bw("get", "attachment", att_id, "--itemid", item["id"], "--output", str(target))
    if p.returncode != 0:
        die(f"download failed: {first_line(p.stderr or p.stdout)}")
    finish("Attachment saved", str(target))


def cmd_attach_add():
    ensure()
    item = pick_item("attach to")
    path = pick_file("upload")
    p = bw("create", "attachment", "--file", path, "--itemid", item["id"])
    if p.returncode != 0:
        die(f"upload failed: {first_line(p.stderr or p.stdout)}")
    finish("Attachment uploaded", f"{os.path.basename(path)} -> {item['name']}")


# ───────────────────────────── delete, sync ─────────────────────────────

def cmd_delete():
    ensure()
    item = pick_item("delete", header="the item goes to the Bitwarden trash (restorable for 30 days)")
    name = item.get("name") or ""
    print(f"Delete: {name}")
    typed = input("Type the item name to confirm (anything else cancels): ")
    if typed != name:
        print("Cancelled.")
        time.sleep(0.8)
        return
    p = bw("delete", "item", item["id"])
    if p.returncode != 0:
        die(f"delete failed: {first_line(p.stderr or p.stdout)}")
    refresh_rbw()
    finish(f"Moved to the trash: {name}")


def cmd_sync():
    if state() != "unlocked":
        print("bw is locked: nothing to sync", file=sys.stderr)
        return 1
    p = bw("sync")
    return p.returncode


def cmd_import_csv(path):
    if not os.path.isfile(path):
        die(f"import-csv: no such file: {path}")
    ensure()
    p = bw("import", "bitwardencsv", path)
    if p.returncode != 0:
        die(f"bw import failed: {first_line(p.stderr or p.stdout)}")
    print(first_line(p.stdout) or "imported")
    bw("sync")
    refresh_rbw()
    return 0


# ───────────────────────────── main ─────────────────────────────

COMMANDS = {
    "unlock": lambda: (ensure(), None)[1],
    "lock": cmd_lock,
    "new-login": cmd_new_login,
    "generate": cmd_generate,
    "edit": cmd_edit,
    "history": cmd_history,
    "send-text": cmd_send_text,
    "send-file": cmd_send_file,
    "attach-get": cmd_attach_get,
    "attach-add": cmd_attach_add,
    "delete": cmd_delete,
}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "state":
        st = state()
        print(st)
        return 0 if st == "unlocked" else 1
    if cmd == "sync":
        return cmd_sync()
    if cmd == "import-csv":
        if len(argv) != 2:
            print("usage: vault-bw.py import-csv FILE", file=sys.stderr)
            return 2
        return cmd_import_csv(argv[1])
    fn = COMMANDS.get(cmd)
    if fn is None:
        print(f"unknown command {cmd}", file=sys.stderr)
        return 2
    try:
        fn()
    except (KeyboardInterrupt, EOFError):
        print()
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
