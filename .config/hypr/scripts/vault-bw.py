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
  vault-bw.py call [--stdin] BW-ARGS...
                              run one bw command through the backend below (--stdin: the body for create / edit is read
                              from stdin; stdout / exit code are bw's): the way shell scripts (linux-pass) reach bw
  vault-bw.py nodump-status   print yes, or no (reason): is the non-dumpable library for the bw processes that hold the session key
                              there, probed and intact (read-only, compiles nothing); nodump-build builds and probes it
  vault-bw.py serve-status    print running|stopped and the socket; exit 0 only when the server answers
  vault-bw.py serve-stop      stop the per-session server (the session key stays; the next bw action restarts it)

Backend (BW1): rbw does every read it can (lists, pickers, get, TOTP, history, sync). What only bw can do (edit, create,
delete, restore, Trash, folders incl. rename and delete, templates, attachments) goes through ONE per-session `bw serve --hostname unix://...bw.sock`
(no TCP, never): `bw` of the CLI is a ~1 s start per call, the server answers in milliseconds. The socket is
$XDG_RUNTIME_DIR/vault/bw.sock (dir 700, socket 600), the server is a user unit `vault-bw-serve` started by this file
(`_serve`: reads the 600 session file, puts the key into the environment of the one `bw serve` child, never argv; without a
user manager it is a detached child). It starts when a bw action needs it, stops on lock, at login (session-start), when the
rbw agent locks (seen within 20 s) and after 15 minutes without a request, or the rbw `lock_timeout` when that is shorter
(the session key stays; the next bw action starts it again). The client trusts the socket only inside a real, 700,
own-user $XDG_RUNTIME_DIR/vault (no /tmp fallback: it is /run/user/UID when the variable is unset; anything else = the CLI
path) and only when SO_PEERCRED says the server is this user's, before one byte of a request is sent. `bw()` below is the
one client: REST over AF_UNIX (http.client), the CLI as fallback when the server cannot run
or the call has no REST form (Send, import, passphrases).

Secrets: the master password only travels pinentry -> this process -> a pipe that ONE `bw unlock` child reads
(--passwordfile /dev/fd/N), never argv, never the environment, never a file. The session key lives in
$XDG_RUNTIME_DIR/vault/bw-session (tmpfs, mode 600) and reaches `bw` as BW_SESSION in the environment of the bw child.
Crash metadata: RLIMIT_CORE=0 only stops the core FILE; systemd-coredump still writes COREDUMP_ENVIRON (the whole
environment) to the journal, which the wheel group can read (checked: a crash with RLIMIT_CORE 0 is logged with its
environment). So every bw process that holds BW_SESSION also runs with PR_SET_DUMPABLE 0 (a tiny LD_PRELOAD library built
with cc into ~/.cache/vault on first use; the kernel then dumps nothing and systemd-coredump is never called, and
/proc/PID/environ is closed to other processes of this user too). Without a compiler it falls back to RLIMIT_CORE 0 only. Item JSON (with the new password) and the Send password
go to bw on stdin, never argv. Generated and old passwords are copied with `wl-copy --sensitive` and cleared in 30 s.
A Send link is meant to be shared, so it is copied plainly.
Test hooks: BW_BIN, RBW_BIN, PINENTRY_BIN, VAULT_RBW_CONF, BW_DOWNLOAD_DIR, EDITOR, VAULT_BW_SERVE=0 (CLI only),
VAULT_BW_LAUNCH=popen|systemd, VAULT_BW_NODUMP=0 (no dumpable-0 library), VAULT_BW_IDLE (seconds; default the rbw lock_timeout
capped at 900), VAULT_BW_SERVE_POLL (supervisor tick, 2 s), VAULT_BW_RBW_POLL (how often it runs `rbw unlocked`, 20 s).
vault-browse.py (the vault browser, SUPER+CTRL+SHIFT+P) imports this file for the bw session, the pickers and the
actions above; run directly it is the command line behind the u6 hub rows.
"""
import base64
import getpass
import http.client
import json
import os
import re
import resource
import secrets
import shutil
import signal
import socket
import stat
import string
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path

BW = os.environ.get("BW_BIN", "bw")
RBW = os.environ.get("RBW_BIN", "rbw")
HERE = Path(__file__).resolve().parent
TOTP_PY = HERE / "vault-totp.py"
RUN = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}") / "vault"   # never /tmp: anybody can plant a directory there
SESSION = RUN / "bw-session"
SOCK = RUN / "bw.sock"
SERVE_PID = RUN / "bw-serve.pid"      # pid of the supervisor (`_serve`)
SERVE_USED = RUN / "bw-serve.used"    # touched by every request: the idle clock
SERVE_LOCK = RUN / "bw-serve.lock"
SERVE_LOG = RUN / "bw-serve.log"
SERVE_ON = os.environ.get("VAULT_BW_SERVE", "1") != "0"
UNIT = os.environ.get("VAULT_BW_UNIT", "vault-bw-serve")
SERVE_HOST = "localhost:8087"         # the Host header bw's origin protection allows (the port is never bound)
CONF_HOME = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
RBW_CONF = Path(os.environ.get("VAULT_RBW_CONF") or CONF_HOME / "rbw" / "config.json")
DOWNLOADS = Path(os.environ.get("BW_DOWNLOAD_DIR") or Path.home() / "Downloads")
TERMINAL_UNLOCK = False
CACHE_HOME = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
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


def no_core():
    """No core FILE for this process and everything it starts (the limit is inherited, so one call at import replaces a
    preexec_fn per child: preexec_fn is not safe in a threaded program such as the vault browser). It does NOT keep the
    environment out of the journal: see NODUMP_C."""
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    except (OSError, ValueError):
        pass


no_core()

NODUMP_C = """#include <sys/prctl.h>
__attribute__((constructor)) static void vault_nodump(void) { prctl(PR_SET_DUMPABLE, 0, 0, 0, 0); }
"""
_nodump_lib = None
_nodump_why = ""
_nodump_failed_at = None
_nodump_lock = threading.Lock()


def _sha(data):
    import hashlib
    return hashlib.sha256(data).hexdigest()


def _nodump_build():
    """(path, "") of a verified library, or ("", reason). The library lives in the per-boot 0700 directory on tmpfs (nothing
    survives a reboot, so a corrupt or planted file is never trusted for ever), is built under a file lock (concurrent
    processes build once), is probed once (a child with the library must report PR_GET_DUMPABLE 0) and carries a marker
    with its own sha256 that every later process compares before it trusts the file."""
    import fcntl
    if os.environ.get("VAULT_BW_NODUMP") == "0":
        return "", "switched off (VAULT_BW_NODUMP=0)"
    src = os.environ.get("VAULT_BW_NODUMP_SRC") or NODUMP_C     # the env is a test hook (a library that does not work)
    try:
        RUN.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError as e:
        return "", f"no runtime directory ({e.strerror})"
    if not run_dir_trusted():
        return "", f"{RUN} is not a private directory of this user"
    lib = RUN / f"nodump-{_sha(src.encode())[:12]}.so"
    mark = RUN / (lib.name + ".ok")
    if re.search(r"[ :]", str(lib)):
        return "", "the library path contains a space or colon (LD_PRELOAD cannot hold it)"

    def verified():
        try:
            return mark.read_text().strip() == _sha(lib.read_bytes())
        except OSError:
            return False

    if verified():
        return str(lib), ""
    try:
        with open(RUN / "nodump.lock", "a") as lockf:
            fcntl.flock(lockf, fcntl.LOCK_EX)
            if verified():       # another process built it while this one waited
                return str(lib), ""
            lib.unlink(missing_ok=True)
            mark.unlink(missing_ok=True)
            if not have("cc"):
                return "", "no C compiler (cc)"
            tmp = RUN / f".nodump.{os.getpid()}.so"
            r = subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-x", "c", "-o", str(tmp), "-"], input=src.encode(),
                               capture_output=True)
            if r.returncode != 0:
                tmp.unlink(missing_ok=True)
                return "", "the compile failed: " + first_line(r.stderr.decode(errors="replace"))
            os.replace(tmp, lib)
            # one probe: the library must really make a process non-dumpable (a broken one is ignored by ld.so with a
            # warning on stderr, and the protection would silently be off)
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LD_PRELOAD": str(lib)}
            probe = subprocess.run([sys.executable, "-I", "-c",
                                    "import ctypes, sys; sys.stdout.write(str(ctypes.CDLL(None).prctl(3, 0, 0, 0, 0)))"],
                                   capture_output=True, text=True, env=env)
            if probe.stdout.strip() != "0":
                lib.unlink(missing_ok=True)
                return "", f"the probe did not report non-dumpable (PR_GET_DUMPABLE {probe.stdout.strip() or '?'}): {first_line(probe.stderr)}"
            mark.write_text(_sha(lib.read_bytes()))
            return str(lib), ""
    except OSError as e:
        return "", f"cannot build the library ({e.strerror})"


def nodump_lib():
    """Path of the LD_PRELOAD library that makes a process non-dumpable (no core, no systemd-coredump journal entry with the
    environment, /proc/PID/environ closed to the rest of this user's processes), or None. Thread-safe: every thread gets the
    same answer, the first one builds. A failed build (no cc yet, a transient compile error) is kept for VAULT_BW_NODUMP_RETRY
    seconds (default 120) and then tried again: the per-session `_serve` process lives for hours and used to keep the failure
    (no protection) until the session ended."""
    global _nodump_lib, _nodump_why, _nodump_failed_at
    with _nodump_lock:
        if not _nodump_lib:
            try:
                retry = float(os.environ.get("VAULT_BW_NODUMP_RETRY") or 120)
            except ValueError:
                retry = 120.0
            if not 0 <= retry <= 86400:               # also nan and inf
                retry = 120.0
            if _nodump_failed_at is None or time.monotonic() - _nodump_failed_at >= retry:
                _nodump_lib, _nodump_why = _nodump_build()
                _nodump_failed_at = None if _nodump_lib else time.monotonic()
        return _nodump_lib or None


def _nodump_state():
    """(verified library path or "", reason): the READ-ONLY view (no compile, no file written): is there a library whose probe marker
    still matches its sha256."""
    if os.environ.get("VAULT_BW_NODUMP") == "0":
        return "", "switched off (VAULT_BW_NODUMP=0)"
    src = os.environ.get("VAULT_BW_NODUMP_SRC") or NODUMP_C
    if not run_dir_trusted():
        return "", f"{RUN} is not a private directory of this user (or does not exist yet)"
    lib = RUN / f"nodump-{_sha(src.encode())[:12]}.so"
    try:
        if (RUN / (lib.name + ".ok")).read_text().strip() == _sha(lib.read_bytes()):
            return str(lib), ""
    except OSError:
        pass
    return "", "the library is not built yet (the first bw call that holds a session key builds it; vault-bw.py nodump-build)"


def cmd_nodump_status():
    """yes, or no (reason): is the library there, probed and intact (doctor). Read-only: it never compiles anything."""
    lib, why = _nodump_state()
    if lib:
        print("yes")
        return 0
    print(f"no ({why})")
    return 1


def cmd_nodump_build():
    """yes, or no (reason): build the library if needed, probe it (what the first bw call with a session key does)."""
    if nodump_lib():
        print("yes")
        return 0
    print(f"no ({_nodump_why})")
    return 1


def with_nodump(env):
    """env with the dumpable-0 library preloaded (for a child that holds a secret); unchanged without the library."""
    lib = nodump_lib()
    if lib:
        env["LD_PRELOAD"] = lib + (":" + env["LD_PRELOAD"] if env.get("LD_PRELOAD") else "")
    return env


def bw_cli(*args, stdin=None, session=True, extra_env=None, pass_fds=()):
    """One `bw` process (about 1 s of start-up each): the fallback and the calls the server does not do."""
    env = dict(os.environ)
    env.pop("BW_SESSION", None)
    env["BW_NOINTERACTION"] = "true"
    env["NODE_NO_WARNINGS"] = "1"
    key = read_session() if session else ""
    if key:
        env["BW_SESSION"] = key
    if extra_env:
        env.update(extra_env)
    if env.get("BW_SESSION"):
        with_nodump(env)
    try:
        return subprocess.run([BW, *args], input=stdin, capture_output=True, text=True, env=env, pass_fds=pass_fds)
    except FileNotFoundError:
        die("bw is not installed (sudo ~/dotfiles/apply-system.sh --only install)")


def bw(*args, stdin=None, session=True, extra_env=None):
    """The one way to run a bw command: through the per-session server when it can (REST over the unix socket, started on
    demand while a session key exists), else as a CLI process. Same arguments and the same CompletedProcess either way."""
    if SERVE_ON and session and not extra_env:
        done = bw_via_server(args, stdin)
        if done is not None:
            return done
    return bw_cli(*args, stdin=stdin, session=session, extra_env=extra_env)


# ───────────────────────────── the per-session bw server (REST over a unix socket) ─────────────────────────────

class ServeDown(Exception):
    """Nothing listens on the socket."""


class ServeBroken(Exception):
    """The server went away in the middle of a request."""


def run_dir_trusted():
    """The directory that holds the socket and the session key is a real directory of this user that nobody else can enter
    (a symlink, a foreign owner or group/other bits mean: do not talk to anything in it, use the CLI)."""
    try:
        st = os.lstat(RUN)
    except OSError:
        return False
    return stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and not st.st_mode & 0o077


def peer_is_me(sock):
    """SO_PEERCRED: the process that owns the other end of the socket runs as this user."""
    try:
        _pid, uid, _gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
    except (OSError, struct.error):
        return False
    return uid == os.getuid()


class _UnixConn(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__(SERVE_HOST, timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self._path)
        except OSError:
            s.close()
            raise
        if not peer_is_me(s):   # nothing is sent (item JSON, passwords) to a server another user owns
            s.close()
            raise ServeDown("the socket is served by another user")
        self.sock = s


_start_failed = False


def touch_used():
    try:
        os.utime(SERVE_USED)
    except FileNotFoundError:
        try:
            fd = os.open(SERVE_USED, os.O_WRONLY | os.O_CREAT, 0o600)
            os.close(fd)
        except OSError:
            pass
    except OSError:
        pass


def rest(method, path, query=None, body=None, ctype="application/json", timeout=120):
    """One request to the server -> (status, bytes). ServeDown when nothing listens, ServeBroken when it dies mid-request."""
    if query:
        path += "?" + urllib.parse.urlencode(query)
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = ctype
    if not run_dir_trusted():
        raise ServeDown(f"{RUN} is not a private directory of this user")
    conn = _UnixConn(str(SOCK), timeout)
    try:
        try:
            conn.connect()
        except (FileNotFoundError, ConnectionRefusedError, NotADirectoryError, PermissionError) as e:
            raise ServeDown(str(e)) from e
        try:
            conn.request(method, path, body=data, headers=headers)
            resp = conn.getresponse()
            raw = resp.read()
        except (OSError, http.client.HTTPException) as e:
            raise ServeBroken(str(e)) from e
        touch_used()
        return resp.status, raw
    finally:
        conn.close()


def serve_up():
    try:
        return rest("GET", "/status", timeout=5)[0] == 200
    except (ServeDown, ServeBroken):
        return False


def read_pid():
    try:
        pid = int(SERVE_PID.read_text().strip())
    except (OSError, ValueError):
        return 0
    try:
        cmd = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return 0
    return pid if b"vault-bw.py" in cmd and b"_serve" in cmd else 0


def serve_args():
    return [sys.executable, "-I", str(Path(__file__).resolve()), "_serve"]


def serve_environment():
    """The non-secret settings the detached server needs (the session key is read from the 600 file by `_serve`)."""
    keep = ("BW_BIN", "RBW_BIN", "VAULT_RBW_CONF", "VAULT_BW_IDLE", "BITWARDENCLI_APPDATA_DIR", "XDG_CONFIG_HOME",
            "VAULT_BW_SERVE_POLL", "VAULT_BW_RBW_POLL", "FAKE_DIR", "PATH", "VAULT_BW_UNIT")
    env = {k: os.environ[k] for k in keep if k in os.environ}
    env["XDG_RUNTIME_DIR"] = str(RUN.parent)
    return env


def launch_serve():
    """Start `_serve` as a transient user unit (survives the window it was started from) or, without a user manager, as a
    detached child. Returns the Popen for the second form."""
    SERVE_LOG.touch(mode=0o600)
    mode = os.environ.get("VAULT_BW_LAUNCH", "auto")
    env = serve_environment()
    if mode != "popen" and have("systemd-run") and have("systemctl"):
        sd_env = dict(os.environ)
        if os.environ.get("VAULT_BW_SYSTEMD_RUNTIME"):   # test hook: the user bus lives in the real runtime directory
            sd_env["XDG_RUNTIME_DIR"] = os.environ["VAULT_BW_SYSTEMD_RUNTIME"]
        subprocess.run(["systemctl", "--user", "stop", UNIT], check=False, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, env=sd_env)
        cmd = ["systemd-run", "--user", "--quiet", "--collect", f"--unit={UNIT}",
               "--description=Bitwarden CLI server (unix socket)", "-p", "LimitCORE=0"] + [f"--setenv={k}={v}" for k, v in env.items()] \
            + ["--", *serve_args()]
        if subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          env=sd_env).returncode == 0:
            return None
    log = open(SERVE_LOG, "ab")
    return subprocess.Popen(serve_args(), stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                            env=dict(os.environ, **env))


def start_serve(wait=20.0):
    """Make the server run (needs a stored session key). True when it answers."""
    global _start_failed
    if not SERVE_ON or not have(BW) or not read_session():
        return False
    try:
        RUN.mkdir(parents=True, exist_ok=True)
        os.chmod(RUN, 0o700)
        import fcntl
        if not run_dir_trusted():
            raise OSError("not a private directory of this user")
        lock = os.open(SERVE_LOCK, os.O_WRONLY | os.O_CREAT, 0o600)
    except OSError:
        _start_failed = True
        return False
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not read_session():   # a lock ran while we waited for the flock: the key is gone, so is the server's reason to be
            return False
        if serve_up():
            return True
        stop_serve()   # a slow first server (still starting, no socket yet) must not be orphaned by the new one
        try:
            child = launch_serve()
        except OSError:
            _start_failed = True
            return False
        deadline = time.time() + wait
        while time.time() < deadline:
            if not read_session():   # a lock ran meanwhile (it waits for this flock): stop waiting, it stops the server
                return False
            if SOCK.exists() and serve_up():
                return True
            if child is not None and child.poll() is not None:
                break
            time.sleep(0.05)
        _start_failed = True
        return False
    finally:
        os.close(lock)


def stop_serve(wait=4.0):
    """Stop the server (SIGTERM to its supervisor, which ends the bw child) and remove the socket. Idempotent."""
    pid = read_pid()
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        end = time.time() + wait
        while time.time() < end and read_pid():
            time.sleep(0.05)
        if read_pid():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    SOCK.unlink(missing_ok=True)
    SERVE_PID.unlink(missing_ok=True)


VALUE_OPTS = {"--folderid", "--search", "--itemid", "--output", "--file", "--collectionid", "--organizationid"}


def split_args(a):
    pos, opt, i = [], {}, 0
    while i < len(a):
        x = a[i]
        if x.startswith("--"):
            if x in VALUE_OPTS and i + 1 < len(a):
                opt[x] = a[i + 1]
                i += 2
                continue
            opt[x] = True
        else:
            pos.append(x)
        i += 1
    return pos, opt


def multipart(field_name, filename, content):
    """multipart/form-data body with one file part. The file name goes out twice, like a browser would: `filename*=UTF-8''..`
    (RFC 5987, percent-encoded UTF-8: busboy, which bw serve uses, prefers it) and an ASCII-only plain `filename=".."` for
    parsers that do not know the star form (busboy reads a plain one as latin1, which garbled every non-ASCII name).
    Quote, CR and LF are %-escaped in the plain form (WHATWG) so they cannot end the parameter or the header line."""
    boundary = "----vaultbw" + secrets.token_hex(12)
    plain = "".join(
        {'"': "%22", "\r": "%0D", "\n": "%0A"}.get(c, c if " " <= c < "\x7f" and c != "\\" else "_") for c in filename)
    star = urllib.parse.quote(filename, safe="!#$&+-.^_`|~", encoding="utf-8", errors="replace")
    head = (f'--{boundary}\r\nContent-Disposition: form-data; name="{field_name}"; filename="{plain}"; '
            f"filename*=UTF-8''{star}\r\n"
            "Content-Type: application/octet-stream\r\n\r\n").encode("ascii")
    return head + content + f"\r\n--{boundary}--\r\n".encode(), f"multipart/form-data; boundary={boundary}"


def translate(args, stdin):
    """bw CLI arguments -> (method, path, query, body, ctype, kind, mutating, outfile), or None when there is no REST form
    (Send, import, TOTP, generate, ...). kind says how the answer becomes CLI-style stdout."""
    pos, opt = split_args(list(args))
    if not pos:
        return None
    cmd, tail = pos[0], pos[1:]
    q = urllib.parse.quote

    def body():
        try:
            return base64.b64decode(stdin.strip(), validate=True)
        except ValueError:
            return stdin.encode() if isinstance(stdin, str) else stdin

    if cmd == "status" and not tail:
        return ("GET", "/status", None, None, None, "template", False, None)
    if cmd == "sync" and not tail:
        return ("POST", "/sync", None, None, None, "text:Syncing complete.", True, None)
    if cmd == "list" and len(tail) == 1 and tail[0] in ("items", "folders"):
        query = {}
        if opt.get("--trash"):
            query["trash"] = "true"
        for flag, name in (("--folderid", "folderid"), ("--search", "search"), ("--collectionid", "collectionid"),
                           ("--organizationid", "organizationid")):
            if isinstance(opt.get(flag), str):
                query[name] = opt[flag]
        return ("GET", f"/list/object/{tail[0]}", query or None, None, None, "list", False, None)
    if cmd == "get" and len(tail) == 2:
        what, ident = tail
        if what == "item":
            return ("GET", f"/object/item/{q(ident, safe='')}", None, None, None, "data", False, None)
        if what == "template":
            return ("GET", f"/object/template/{q(ident, safe='')}", None, None, None, "template", False, None)
        if what == "attachment" and isinstance(opt.get("--itemid"), str) and isinstance(opt.get("--output"), str):
            return ("GET", f"/object/attachment/{q(ident, safe='')}", {"itemid": opt["--itemid"]}, None, None, "file",
                    False, opt["--output"])
    if cmd == "create" and len(tail) == 1 and tail[0] in ("item", "folder") and stdin is not None:
        return ("POST", f"/object/{tail[0]}", None, body(), "application/json", "data", True, None)
    if cmd == "create" and tail == ["attachment"] and isinstance(opt.get("--file"), str) \
            and isinstance(opt.get("--itemid"), str):
        try:
            content = Path(opt["--file"]).read_bytes()
        except OSError:
            return None
        data, ctype = multipart("file", os.path.basename(opt["--file"]), content)
        return ("POST", "/attachment", {"itemid": opt["--itemid"]}, data, ctype, "data", True, None)
    if cmd == "edit" and len(tail) == 2 and tail[0] == "item" and stdin is not None:
        return ("PUT", f"/object/item/{q(tail[1], safe='')}", None, body(), "application/json", "data", True, None)
    if cmd == "edit" and len(tail) == 2 and tail[0] == "folder" and stdin is not None:   # rename: body {"name": ...}
        return ("PUT", f"/object/folder/{q(tail[1], safe='')}", None, body(), "application/json", "data", True, None)
    if cmd == "delete" and len(tail) == 2 and tail[0] == "folder":   # its items stay, without a folder
        return ("DELETE", f"/object/folder/{q(tail[1], safe='')}", None, None, None, "none", True, None)
    if cmd == "delete" and len(tail) == 2 and tail[0] == "item":
        return ("DELETE", f"/object/item/{q(tail[1], safe='')}", {"permanent": "true"} if opt.get("--permanent") else None,
                None, None, "none", True, None)
    if cmd == "restore" and len(tail) == 2 and tail[0] == "item":
        return ("POST", f"/restore/item/{q(tail[1], safe='')}", None, None, None, "data", True, None)
    return None


def render(req, status_code, raw):
    """The server's answer as the CompletedProcess the CLI would have produced."""
    kind, outfile = req[5], req[7]
    argv = ["bw (server)", req[0], req[1]]
    if kind == "file" and status_code == 200:
        try:
            fd = os.open(outfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(raw)
        except OSError as e:
            return subprocess.CompletedProcess(argv, 1, "", f"could not write {outfile}: {e}")
        return subprocess.CompletedProcess(argv, 0, f"Saved {outfile}\n", "")
    try:
        doc = json.loads(raw.decode("utf-8", "replace") or "{}")
    except ValueError:
        return subprocess.CompletedProcess(argv, 1, "", f"the bw server answered something that is not JSON ({status_code})")
    if not isinstance(doc, dict):
        doc = {"success": False}
    if status_code >= 400 or not doc.get("success", True):
        msg = doc.get("message")
        if not msg and isinstance(doc.get("data"), dict):
            msg = doc["data"].get("message")
        return subprocess.CompletedProcess(argv, 1, "", (msg or f"bw server error {status_code}") + "\n")
    data = doc.get("data")
    if kind == "template":
        data = data.get("template", data) if isinstance(data, dict) else data
    elif kind == "list":
        data = data.get("data", []) if isinstance(data, dict) else (data or [])
    if kind.startswith("text:"):
        out = kind[5:] + "\n"
    elif kind == "none" or data is None:
        out = ""
    else:
        out = json.dumps(data)
    return subprocess.CompletedProcess(argv, 0, out, "")


def bw_via_server(args, stdin):
    """The call through the server, or None for 'use the CLI' (no REST form, no session, server cannot run)."""
    req = translate(args, stdin)
    if req is None:
        return None
    method, path, query, body, ctype, _kind, mutating, _outfile = req
    for attempt in (0, 1):
        try:
            code, raw = rest(method, path, query, body, ctype or "application/json")
        except ServeDown:
            if attempt == 0 and not _start_failed and read_session() and start_serve():
                continue
            return None
        except ServeBroken as e:
            if mutating:
                return subprocess.CompletedProcess(["bw (server)"], 1, "", "the bw server stopped during the request "
                                                   f"({e}); check the vault before repeating it\n")
            return None
        return render(req, code, raw)
    return None


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


_status_memo = (0.0, None)


def status():
    """unauthenticated | locked | unlocked, or None when bw is missing or does not answer. With a stored session key the
    server answers (and is started when it is not running); the answer is remembered for 3 s inside one process."""
    global _status_memo
    if not have(BW):
        return None
    if time.time() - _status_memo[0] < 3 and _status_memo[1]:
        return _status_memo[1]
    p = bw("status")
    try:
        st = json.loads(p.stdout).get("status")
    except ValueError:
        return None
    _status_memo = (time.time(), st)
    return st


def forget_status():
    global _status_memo, _start_failed
    _status_memo = (0.0, None)
    _start_failed = False


def state():
    if not have(BW):
        return "missing"
    st = status()
    if st == "unauthenticated":
        return "unconfigured"
    if st == "unlocked":
        return "unlocked"
    return "locked"


IDLE_DEFAULT = 900   # seconds: the rbw lock_timeout here is a year, which would keep the server (and the key) alive all day


def idle_limit():
    """Seconds without a request after which the server stops: VAULT_BW_IDLE, else the rbw lock_timeout capped at 15 min."""
    try:
        return max(2, int(os.environ["VAULT_BW_IDLE"]))
    except (KeyError, ValueError):
        pass
    try:
        return min(IDLE_DEFAULT, max(30, int(json.loads(RBW_CONF.read_text()).get("lock_timeout", IDLE_DEFAULT))))
    except (OSError, ValueError, TypeError):
        return IDLE_DEFAULT


def rbw_unlocked():
    try:
        return subprocess.run([RBW, "unlocked"], capture_output=True).returncode == 0
    except OSError:
        return None


def die_with_parent():
    """preexec_fn of the bw child (the supervisor is single-threaded): SIGTERM when the supervisor dies in any way (even
    SIGKILL), so no orphan server keeps the key. The core limit is inherited from `no_core()` at import."""
    try:
        import ctypes
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, signal.SIGTERM)   # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass


def cmd_serve():
    """The supervisor behind `_serve`: runs `bw serve` on the socket with the session key in ITS environment only, and ends
    it (and itself) on SIGTERM, when the session file is gone (lock), after the idle limit and when the rbw agent locked."""
    key = read_session()
    if not key or not have(BW):
        return 1
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    SOCK.unlink(missing_ok=True)
    SERVE_PID.write_text(str(os.getpid()))
    touch_used()
    env = with_nodump(dict(os.environ, BW_SESSION=key, BW_NOINTERACTION="true", NODE_NO_WARNINGS="1"))
    key = None
    log = open(SERVE_LOG, "ab")
    child = subprocess.Popen([BW, "serve", "--hostname", f"unix://{SOCK}"], stdin=subprocess.DEVNULL, stdout=log,
                             stderr=log, env=env, preexec_fn=die_with_parent)
    env = None
    stop = {"now": False}

    def on_term(_sig, _frm):
        stop["now"] = True

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_term)
    poll = float(os.environ.get("VAULT_BW_SERVE_POLL", "2"))
    rbw_poll = float(os.environ.get("VAULT_BW_RBW_POLL", "20"))   # `rbw unlocked` is a process: not every 2 s (43k a day)
    idle, seen_rbw, chmoded, last, last_rbw = idle_limit(), False, False, 0.0, 0.0
    while not stop["now"] and child.poll() is None:
        time.sleep(0.1 if not chmoded else min(0.5, poll))
        if not chmoded and SOCK.exists():
            try:
                os.chmod(SOCK, 0o600)
            except OSError:
                pass
            chmoded = True
        now = time.time()
        if now - last < poll:
            continue
        last = now
        if not SESSION.exists():
            break
        try:
            if now - SERVE_USED.stat().st_mtime > idle:
                break
        except OSError:
            pass
        if now - last_rbw >= rbw_poll and rbw_ready():
            last_rbw = now
            up = rbw_unlocked()
            if up:
                seen_rbw = True
            elif up is False and seen_rbw:
                break
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(4)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    SOCK.unlink(missing_ok=True)
    try:
        if SERVE_PID.read_text().strip() == str(os.getpid()):
            SERVE_PID.unlink()
    except OSError:
        pass
    return 0


def cmd_serve_status():
    up = serve_up()
    pid = read_pid()
    print(f"{'running' if up else 'stopped'} socket={SOCK} pid={pid or '-'}")
    return 0 if up else 1


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
    """Run pinentry (Assuan) and return the typed secret, or None when cancelled. With no graphical session (or
    `unlock --terminal`) the password is read on this terminal instead (no echo)."""
    if TERMINAL_UNLOCK:
        if error:
            print(error, file=sys.stderr)
        try:
            return getpass.getpass("Bitwarden master password: ") or None
        except (EOFError, KeyboardInterrupt):
            return None
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
        # the master password goes through a pipe the child reads as /dev/fd/N: it is in no argv, no environment (a crash
        # record of bw would list it), no file; a password is far below the pipe buffer, so writing first cannot block
        rfd, wfd = os.pipe()
        try:
            os.write(wfd, pw.encode() + b"\n")
            os.close(wfd)
            wfd = -1
            p = bw_cli("unlock", "--raw", "--passwordfile", f"/dev/fd/{rfd}", session=False, pass_fds=(rfd,))
        finally:
            os.close(rfd)
            if wfd >= 0:
                os.close(wfd)
        pw = None
        key = p.stdout.strip()
        if p.returncode == 0 and key:
            stop_serve()          # a server that is still running holds the old key
            write_session(key)
            forget_status()
            start_serve()         # one start now: every bw call after this is a request, not a process
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
    # Order matters (BW1-fix): the key is read once and the session file goes FIRST, so no client can start a new server
    # with it while we stop the old one (`start_serve` and `_serve` both need the file). Then the server is stopped under
    # the same flock `start_serve` holds (a start that is in flight finishes first and is stopped too), then ONE `bw lock`
    # clears bw's own keys with the key we still hold in memory. The real `bw serve` exits by itself on POST /lock, so the
    # REST lock cannot be relied on to finish its disk writes: the server is stopped, not asked.
    key = read_session()
    drop_session()
    lock = None
    try:
        import fcntl
        RUN.mkdir(parents=True, exist_ok=True)
        lock = os.open(SERVE_LOCK, os.O_WRONLY | os.O_CREAT, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
    except OSError:
        pass   # no directory or no flock: stop it anyway
    try:
        stop_serve()
    finally:
        if lock is not None:
            os.close(lock)
    if have(BW):
        bw_cli("lock", session=False, extra_env={"BW_SESSION": key} if key else None)
    forget_status()
    poke_bar()


# ───────────────────────────── clipboard, pickers, rbw ─────────────────────────────

WL_COPY = "wl-copy"          # envs sets an absolute path (the secret goes to its stdin: never one a project's PATH can shadow)


def copy(text, sensitive=True):
    if not have(WL_COPY):
        die("wl-copy is not installed")
    cmd = [WL_COPY, "--sensitive"] if sensitive else [WL_COPY]
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


def rbw_all_items():
    """Every item rbw knows as {id, name, login: {username}, attachments: []}, or None (rbw not set up or locked and
    cancelled): the ids are the Bitwarden cipher ids, so they work for bw too."""
    if not rbw_ready():
        return None
    p = subprocess.run([RBW, "list", "--raw"], capture_output=True, text=True)
    if p.returncode != 0:
        return None
    try:
        raw = json.loads(p.stdout or "[]")
    except ValueError:
        return None
    return [{"id": i["id"], "name": i.get("name"), "login": {"username": i.get("user")}, "attachments": []}
            for i in raw if i.get("id")]


def item_rows(items, with_attachments=False):
    rows = []
    for i in sorted(items, key=lambda i: (i.get("name") or "").lower()):
        user = ((i.get("login") or {}).get("username")) or ""
        n = len(i.get("attachments") or [])
        extra = f"   [{n} file{'s' if n != 1 else ''}]" if with_attachments else ""
        rows.append(f"{i['id']}\t{clean(i.get('name'))}\t{clean(user)}{extra}")
    return rows


def pick_item(prompt, items=None, with_attachments=False, header=""):
    if items is None:
        items = None if with_attachments else rbw_all_items()   # rbw has no attachment list: bw answers those
        if items is None:
            items = list_items()
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

def generate_local(classes, length):
    """A password from the character classes u l n s (at least one of each chosen class), random from the OS."""
    sets = {"u": string.ascii_uppercase, "l": string.ascii_lowercase, "n": string.digits, "s": "!@#$%^&*"}
    chosen = [sets[c] for c in "ulns" if c in classes]
    if not chosen:
        chosen = [sets["l"], sets["n"]]
    length = max(length, len(chosen))
    pool = "".join(chosen)
    chars = [secrets.choice(c) for c in chosen] + [secrets.choice(pool) for _ in range(length - len(chosen))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def generate_password(*opts):
    flags = [o for o in opts if re.fullmatch(r"-[a-z]+", o)]
    if flags and not any("p" in f for f in flags):
        classes = "".join(flags).lstrip("-").replace("-", "")
        try:
            length = int(opts[list(opts).index("--length") + 1])
        except (ValueError, IndexError):
            length = 14
        return generate_local(classes, length)   # no `bw generate` process (a second) for plain character passwords
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


# ───────────────────────────── folders ─────────────────────────────

def folder_map():
    """{folder id: name} from `bw list folders` (one server request)."""
    return {f["id"]: f.get("name") or "" for f in bw_json("list", "folders") if f.get("id")}


def folder_id(name, create=True):
    """The id of the folder called NAME (None for an empty name); a missing folder is created when asked to."""
    if not name:
        return None
    for fid, fname in folder_map().items():
        if fname == name:
            return fid
    if not create:
        return None
    p = bw("create", "folder", stdin=b64({"name": name}))
    try:
        return json.loads(p.stdout)["id"]
    except (ValueError, KeyError, TypeError):
        die(f"could not create the folder {name}: {first_line(p.stderr or p.stdout)}")


# ───────────────────────────── new login ─────────────────────────────

def cmd_new_login(folder=None):
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
    item.update(type=1, name=name, notes=None, favorite=False, folderId=folder_id(folder), fields=[],
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
    global TERMINAL_UNLOCK
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
    if cmd == "nodump-status":
        return cmd_nodump_status()
    if cmd == "nodump-build":
        return cmd_nodump_build()
    if cmd == "_serve":
        return cmd_serve()
    if cmd == "serve-status":
        return cmd_serve_status()
    if cmd == "serve-stop":
        stop_serve()
        return 0
    if cmd == "call":
        rest_args = argv[1:]
        feed = None
        if rest_args[:1] == ["--stdin"]:      # `call --stdin create item`: the body arrives on stdin (base64 JSON)
            rest_args, feed = rest_args[1:], sys.stdin.read()
        p = bw(*rest_args, stdin=feed)
        sys.stdout.write(p.stdout or "")
        sys.stderr.write(p.stderr or "")
        return p.returncode
    if cmd == "unlock" and "--terminal" in argv[1:]:
        TERMINAL_UNLOCK = True
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
