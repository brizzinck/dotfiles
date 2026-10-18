"""Shared helpers of the dev launchers `db`, `api`, `ci`, `forge` (DEV-d). Imported by them through their own real path
(`<repo>/.config/devtools/devtools.py`), never run. Python 3 stdlib only; envs (`<repo>/.local/bin/envs`) is imported as a module
for root discovery, TOML reading, the agent check, tool paths and the test-mode rules (no copy of that code).

What lives here: the envs module, tool lookup (envs' safe directories plus the user-level install directories, test fakes first
in verified test mode), per-run directories on tmpfs, the keyboard-layout switch before a TUI starts, small TOML/YAML escapes.
"""
import importlib.machinery
import importlib.util
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[2]
ENVS_PATH = REPO / ".local/bin/envs"

_envs = None


def envs():
    """The envs script as a module (its main is guarded; nothing runs on import)."""
    global _envs
    if _envs is None:
        loader = importlib.machinery.SourceFileLoader("envs_mod", str(ENVS_PATH))
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("envs_mod", loader))
        loader.exec_module(m)
        _envs = m
    return _envs


class DevError(Exception):
    def __init__(self, msg, code=1):
        super().__init__(msg)
        self.msg, self.code = msg, code


def fail(msg, code=1):
    raise DevError(msg, code)


def warn(who, msg):
    print(f"{who}: {msg}", file=sys.stderr)


def home():
    return envs().HOME


# user-level install directories of the dev tools (go install, pipx, cargo, npm -g): fixed, never searched through PATH (a
# project's `_.path` could put its own `lazysql` first)
USER_BIN = [".local/bin", "go/bin", ".cargo/bin", ".npm-global/bin"]


def tool(name, required=True, hint=None):
    """Absolute path of an external tool: envs' lookup (test fakes first in verified test mode, then /usr/bin, /usr/local/bin,
    ~/.local/bin), then the user-level install directories. Missing = a message with the install hint, exit 127."""
    e = envs()
    p = e.tool(name, required=False)
    if p:
        return p
    if not e.TEST_DIRS or name not in e.SECRET_TOOLS:
        for d in USER_BIN:
            c = home() / d / name
            if c.is_file() and os.access(c, os.X_OK):
                return str(c)
    if required:
        fail(f"{name} is not installed" + (f" ({hint})" if hint else ""), 127)
    return None


USER_TOOLS_HINT = "run ~/dotfiles/infrastructure/dev/user-tools.sh"
REPO_PKG_HINT = "sudo ~/dotfiles/apply-system.sh --only install"


def runtime_base():
    return Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")


def run_root():
    d = runtime_base() / "devtools"
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def clean_stale(prefix):
    """Per-run directories `<prefix>-<pid>` of processes that are gone (a killed terminal)."""
    for d in run_root().glob(f"{prefix}-*"):
        m = re.fullmatch(rf"{re.escape(prefix)}-(\d+)", d.name)
        if m and d.is_dir() and not Path(f"/proc/{m.group(1)}").exists():
            _rmtree(d)


def _rmtree(d):
    import shutil
    shutil.rmtree(d, ignore_errors=True)


def run_dir(prefix):
    """A fresh 0700 directory `<runtime>/devtools/<prefix>-<pid>` (stale ones are removed first). Files in it are 0600."""
    clean_stale(prefix)
    d = run_root() / f"{prefix}-{os.getpid()}"
    if d.exists():
        _rmtree(d)
    d.mkdir(mode=0o700)
    os.chmod(d, 0o700)
    return d


def write_private(path, text):
    """A 0600 file, created exclusively (no symlink is followed)."""
    path = Path(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    return path


def switch_layout():
    """A TUI reads characters, so the keyboard goes to us (layout 0) before it starts, like lock-screen; never restored (the
    owner toggles with Caps). Quietly nothing without a Hyprland instance. DEVTOOLS_NO_LAYOUT=1 skips (tests)."""
    if os.environ.get("DEVTOOLS_NO_LAYOUT") == "1" or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return False
    hc = tool("hyprctl", required=False)
    if not hc:
        return False
    try:
        subprocess.run([hc, "switchxkblayout", "all", "0"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return False
    return True


def tty():
    return sys.stdin.isatty() and sys.stderr.isatty()


def project_root(extra_label=None, want=None):
    """The project root for a launcher: the one the cwd is in, else a picker over the bound checkouts (envs bindings), else None.
    EXTRA_LABEL adds one row that means "no project" (returns None). WANT(root) filters the picker rows (e.g. has a workflow file)."""
    e = envs()
    try:
        return e.find_root()
    except e.Fail:
        pass
    roots = []
    for key in e.bindings():
        r = Path(e.key_root(key))
        if (r / e.TOML).is_file() and r not in roots and (want is None or want(r)):
            roots.append(r)
    if not tty() or (not roots and not extra_label):
        return None
    rows = [f"{r.name:<24} {e.short_path(r)}" for r in roots] + ([extra_label] if extra_label else [])
    got = e.pick(rows, "project") if rows else None
    if not got:
        fail("no project chosen", 130)
    if extra_label and got == extra_label:
        return None
    return roots[rows.index(got)]


# escapes ------------------------------------------------------------------------------------------------------------------

def toml_str(s):
    return envs().toml_str(s)


def yaml_dq(s):
    """A YAML double-quoted scalar: backslash, quote and every control character escaped (a secret value with a quote or a
    newline cannot break out of the string or add a key)."""
    out = ['"']
    for ch in str(s):
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 0x20 or o == 0x7F or 0x80 <= o < 0xA0 or o in (0x2028, 0x2029, 0xFEFF):
            out.append(f"\\u{o:04x}" if o < 0x10000 else f"\\U{o:08x}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def main_wrap(who, fn, argv):
    """Run FN(argv), print DevError / envs.Fail messages as `who: message`, return the exit code."""
    e = envs()
    try:
        return fn(argv) or 0
    except DevError as ex:
        warn(who, ex.msg)
        return ex.code
    except e.Fail as ex:
        warn(who, ex.msg)
        return ex.code
    except (KeyboardInterrupt, EOFError):
        print(file=sys.stderr)
        return 130
    except BrokenPipeError:
        return 0
