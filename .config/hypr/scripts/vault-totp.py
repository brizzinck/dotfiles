#!/usr/bin/env python3
"""vault-totp: 2FA helper on top of rbw (Bitwarden / Vaultwarden). Python 3 stdlib only.

  vault-totp.py list [--refresh]    id<TAB>name<TAB>user<TAB>folder<TAB>period of every login that has a TOTP key
  vault-totp.py code ID             print the current code (nothing else on stdout)
  vault-totp.py preview ID          name, user, grouped code and seconds left (for the fzf preview pane)
  vault-totp.py copy ID             copy the code with `wl-copy --sensitive`, notify with the seconds left, clear in 30 s
  vault-totp.py arm-clear           if the clipboard holds a sensitive value, clear it after 30 s unless it changed
  vault-totp.py forget              drop the cached 2FA entry index

Secrets never touch persistent storage: the entry index (ids, names, users, no secrets) is cached in
$XDG_RUNTIME_DIR/vault (tmpfs, mode 600) and dropped on lock/sync/login. The code goes to the clipboard with the
x-kde-passwordManagerHint (cliphist skips it) and never into a notification, a log or argv.
Test hooks: RBW_BIN (default rbw), VAULT_CLEAR_AFTER (seconds, default 30).
"""
import hashlib
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import parse_qs, urlparse

RBW = os.environ.get("RBW_BIN", "rbw")
RUN = Path(os.environ.get("XDG_RUNTIME_DIR") or "/tmp") / "vault"
INDEX = RUN / "totp-index.tsv"
INDEX_TTL = 600
CLEAR_AFTER = int(os.environ.get("VAULT_CLEAR_AFTER", "30"))
HINT = "x-kde-passwordManagerHint"


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def rbw(*args):
    try:
        return subprocess.run([RBW, *args], capture_output=True, text=True)
    except FileNotFoundError:
        die("rbw is not installed")


def notify(title, body="", urgency="low"):
    subprocess.run(
        ["notify-send", "-a", "vault", "-u", urgency, "-t", "5000",
         "-h", "string:x-dunst-stack-tag:vault", title, body],
        check=False,
    )


def period_of(totp):
    """Step length from an otpauth:// URI, 30 s otherwise (a bare base32 secret, steam://)."""
    if totp.startswith("otpauth://"):
        try:
            q = parse_qs(urlparse(totp).query)
            return max(1, int(q.get("period", ["30"])[0]))
        except ValueError:
            return 30
    if totp.startswith("steam://"):
        return 30
    return 30


def fetch_totp_entry(item):
    """(id, name, user, folder, period) when the login has a TOTP key, else None."""
    ident = item.get("id") or item.get("name")
    p = rbw("get", "--raw", ident)
    if p.returncode != 0:
        return None
    try:
        data = json.loads(p.stdout)
    except ValueError:
        return None
    totp = (data.get("data") or {}).get("totp")
    if not totp:
        return None
    return (item.get("id") or "", item.get("name") or "", item.get("user") or "",
            item.get("folder") or "", period_of(totp))


def build_index():
    p = rbw("list", "--raw")
    if p.returncode != 0:
        die(p.stderr.strip() or "rbw list failed (is the vault set up? run bw-setup)", 2)
    items = [i for i in json.loads(p.stdout or "[]") if str(i.get("type", "")).lower() == "login"]
    with ThreadPoolExecutor(max_workers=6) as pool:
        rows = [r for r in pool.map(fetch_totp_entry, items) if r]
    rows.sort(key=lambda r: (r[3].lower(), r[1].lower(), r[2].lower()))
    return rows


def clean(s):
    return s.replace("\t", " ").replace("\n", " ")


def write_index(rows):
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    tmp = INDEX.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        for r in rows:
            f.write("\t".join(clean(str(c)) for c in r) + "\n")
    os.replace(tmp, INDEX)


def read_index(refresh=False):
    fresh = INDEX.exists() and time.time() - INDEX.stat().st_mtime < INDEX_TTL
    if refresh or not fresh:
        rows = build_index()
        write_index(rows)
        return [[str(c) for c in r] for r in rows]
    return [line.rstrip("\n").split("\t") for line in INDEX.read_text().splitlines() if line]


def find(ident):
    for row in read_index():
        if row[0] == ident:
            return row
    return [ident, ident, "", "", "30"]


def get_code(ident):
    p = rbw("code", ident)
    code = p.stdout.strip()
    if p.returncode != 0 or not code:
        die(p.stderr.strip() or "rbw code failed", 3)
    return code


def seconds_left(period):
    return period - int(time.time()) % period


def group(code):
    if code.isdigit() and len(code) == 6:
        return f"{code[:3]} {code[3:]}"
    if code.isdigit() and len(code) == 8:
        return f"{code[:4]} {code[4:]}"
    return code


def clipboard_hash():
    """sha256 of the clipboard text when it is flagged sensitive, else None."""
    types = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True)
    if types.returncode != 0 or HINT not in types.stdout.split():
        return None
    p = subprocess.run(["wl-paste", "--no-newline"], capture_output=True)
    return hashlib.sha256(p.stdout).hexdigest() if p.returncode == 0 else None


def arm_clear():
    digest = clipboard_hash()
    if not digest:
        return
    # detached waiter; the digest goes over stdin so it never shows up in the process list
    proc = subprocess.Popen(
        [sys.executable, "-I", os.path.abspath(__file__), "_wait-clear"],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True, text=True,
    )
    proc.stdin.write(digest)
    proc.stdin.close()


def wait_clear():
    digest = sys.stdin.read().strip()
    time.sleep(CLEAR_AFTER)
    if digest and clipboard_hash() == digest:
        subprocess.run(["wl-copy", "--clear"], check=False)


def cmd_copy(ident):
    row = find(ident)
    code = get_code(ident)
    period = int(row[4]) if len(row) > 4 and row[4].isdigit() else 30
    left = seconds_left(period)
    subprocess.run(["wl-copy", "--sensitive"], input=code, text=True, check=True)
    arm_clear()
    label = row[1] + (f" ({row[2]})" if row[2] else "")
    notify("2FA code copied", f"{label}: valid for {left} s, clipboard clears in {CLEAR_AFTER} s")


def cmd_preview(ident):
    row = find(ident)
    p = rbw("code", ident)
    code = p.stdout.strip()
    period = int(row[4]) if len(row) > 4 and row[4].isdigit() else 30
    left = seconds_left(period)
    print(row[1])
    if row[2]:
        print(row[2])
    if row[3]:
        print(f"folder: {row[3]}")
    print()
    if p.returncode != 0 or not code:
        print("could not read the code")
        print(p.stderr.strip())
        return
    bar = "#" * (left * 20 // period) + "." * (20 - left * 20 // period)
    print(f"  {group(code)}")
    print()
    print(f"  [{bar}] {left:2d} s")
    print()
    print("  Enter: copy (sensitive, cleared in 30 s)")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "list":
        for row in read_index(refresh="--refresh" in rest):
            print("\t".join(row))
    elif cmd == "code":
        print(get_code(rest[0]))
    elif cmd == "preview":
        cmd_preview(rest[0])
    elif cmd == "copy":
        cmd_copy(rest[0])
    elif cmd == "arm-clear":
        arm_clear()
    elif cmd == "_wait-clear":
        wait_clear()
    elif cmd == "forget":
        INDEX.unlink(missing_ok=True)
    else:
        die(f"unknown command {cmd}", 2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
