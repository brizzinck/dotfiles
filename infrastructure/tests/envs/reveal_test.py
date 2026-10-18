"""FIX-DEVb2 #3: `_preview` honours a reveal flag only when the pid in its name is an ancestor that runs the TUI. A real TUI
(tmux, section 15) is the positive end-to-end case; here the argv of one chosen pid is faked inside a child python that
runs `main(["_preview", ...])` in the sandbox of env.sh (fake vault). Needs a bound checkout of billing at ROOT.
usage: reveal_test.py ENVS ROOT WORKDIR"""
import os
import subprocess
import sys
import time
from pathlib import Path

ENVS, ROOT, WORK = sys.argv[1], sys.argv[2], Path(sys.argv[3])
WORK.mkdir(parents=True, exist_ok=True)
RUN = Path(os.environ["XDG_RUNTIME_DIR"]) / "envs"
LOG = Path(os.environ["FAKE_DIR"]) / "logger.log"
fails = 0
CHILD = WORK / "child.py"
CHILD.write_text(r'''
import contextlib, importlib.machinery, importlib.util, io, os, sys
envs, fake, kind, flag, env = sys.argv[1:6]
l = importlib.machinery.SourceFileLoader("envs_mod", envs)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("envs_mod", l)); l.exec_module(m)
real, real_exe = m.proc_argv, m.proc_exe
tui = [m.PY.encode(), b"-I", str(m.SELF).encode(), b""]
argv = {"tui": tui, "extra-arg": tui[:3] + [b"run", b""], "other-script": [tui[0], b"-I", b"/tmp/other", b""],
        "no-dash-I": [tui[0], tui[2], b""], "not-python": [b"/bin/sh", b"-I", tui[2], b""],
        "bad-exe": tui, "relative": [tui[0], b"-I", b"envs", b""]}[kind]
exe = {"not-python": "/bin/sh", "bad-exe": "/usr/bin/perl"}.get(kind, m.PY)    # the kernel's view of the process
m.proc_argv = lambda pid: argv if pid == int(fake) else real(pid)
m.proc_exe = lambda pid: os.path.realpath(exe) if pid == int(fake) else real_exe(pid)
os.environ["ENVS_REVEAL_FILE"] = flag
out = io.StringIO()
with contextlib.redirect_stdout(out):
    try:
        m.main(["_preview", "vars", "billing", sys.argv[6], env, "DATABASE_URL"])
    except SystemExit:
        pass
sys.stdout.write(out.getvalue())
''')


def expect(name, cond):
    global fails
    print(("ok    " if cond else "FAIL  ") + name)
    fails += not cond


def logged():
    return LOG.read_text() if LOG.exists() else ""


def flag_text(env):
    return f"billing\t{env}\tDATABASE_URL\t{time.time() + 600}"


def case(fake, kind, env="dev"):
    """fake = 'self-sh' (the pid of the sh between us and the child, an ancestor), 'sibling' (a live process that is not an
    ancestor), 'init' (pid 1). Returns the preview text."""
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    py = sys.executable
    if fake == "self-sh":
        script = (f'F="{RUN}/reveal-$$-0123456789ab"; printf "%s" "$1" >"$F"; '
                  f'"{py}" -I -B "{CHILD}" "{ENVS}" "$$" "{kind}" "$F" {env} "{ROOT}"; rm -f "$F"; true')
        p = subprocess.run(["sh", "-c", script, "sh", flag_text(env)], capture_output=True, text=True)
        return p.stdout
    sib = subprocess.Popen(["sleep", "30"]) if fake == "sibling" else None
    pid = sib.pid if sib else 1
    flag = RUN / f"reveal-{pid}-0123456789ab"
    flag.write_text(flag_text(env))
    try:
        p = subprocess.run([py, "-I", "-B", str(CHILD), ENVS, str(pid), kind, str(flag), env, ROOT], capture_output=True, text=True)
    finally:
        flag.unlink(missing_ok=True)
        if sib:
            sib.kill()
            sib.wait()
    return p.stdout


SECRET_DEV, SECRET_PROD = "SECRET-billing-dev-db", "SECRET-billing-prod-db"
expect("control: an ancestor that runs the TUI (argv = python -I envs) reveals the value", SECRET_DEV in case("self-sh", "tui"))
LOG.write_text("") if LOG.exists() else None
out = case("self-sh", "tui", "prod")
expect("a revealed protected value is journaled", SECRET_PROD in out and "preview shows project=billing env=prod" in logged())
# REVIEW-ENVS-FINAL #1: argv0 spoofed through `exec -a` (the kernel's /proc/PID/exe is something else) and a relative script path
# (resolved against a cwd the process can change) do not count either
for kind in ("extra-arg", "other-script", "no-dash-I", "not-python", "bad-exe", "relative"):
    out = case("self-sh", kind)
    expect(f"an ancestor that is not the TUI ({kind}) reveals nothing", SECRET_DEV not in out and "••••" in out)
LOG.write_text("") if LOG.exists() else None
out = case("self-sh", "extra-arg", "prod")
expect("... prod either, and nothing is journaled", SECRET_PROD not in out and "preview shows" not in logged())
out = case("sibling", "tui")
expect("a flag naming a live process that is not an ancestor reveals nothing, even with a TUI-looking argv", SECRET_DEV not in out and "••••" in out)
out = case("init", "tui")
expect("a flag naming pid 1 reveals nothing", SECRET_DEV not in out)
sys.exit(1 if fails else 0)
