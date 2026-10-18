"""FIX-DEVb: test mode cannot be switched on by hooks, and what tool() / harden_environment() / command_env() do outside it.
Each case loads .local/bin/envs in a fresh `python3 -I` with a chosen environment (no real vault tool is ever executed:
only the resolved PATHS are inspected).  usage: hardening_test.py ENVS REPO"""
import json
import os
import subprocess
import sys
import tempfile

ENVS, REPO = sys.argv[1], sys.argv[2]
PROBE = r'''
import importlib.machinery, importlib.util, json, os, sys
l = importlib.machinery.SourceFileLoader("envs_mod", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("envs_mod", l)); l.exec_module(m)
orig_path = os.environ.get("PATH", "")
m.harden_environment()
print(json.dumps({"test": m.test_mode(), "dirs": m.TEST_DIRS, "rbw": m.tool("rbw", "RBW_BIN", required=False),
                  "wl": m.tool("wl-copy", required=False), "git": m.tool("git", required=False), "path": os.environ["PATH"],
                  "hooks": [k for k in m.HOOK_ENV if k in os.environ], "cmdpath": m.command_env(os.environ)["PATH"],
                  "orig": orig_path, "state": os.environ.get("XDG_STATE_HOME"), "cmd_hooks": [k for k in m.HOOK_ENV if k in m.command_env(os.environ)]}))
'''
TESTS = os.path.join(REPO, "infrastructure/tests")
FAKES = f"{TESTS}/envs/bin:{TESTS}/vault-browse/bin"
fails = 0


def probe(extra, drop=()):
    env = {"PATH": "/usr/bin:/bin", "HOME": os.path.expanduser("~")}
    env.update(extra)
    for k in drop:
        env.pop(k, None)
    p = subprocess.run([sys.executable, "-I", "-B", "-c", PROBE, ENVS], env=env, capture_output=True, text=True)
    if p.returncode != 0:
        print("probe failed:", p.stderr[-300:])
        return {}
    return json.loads(p.stdout)


def expect(name, cond):
    global fails
    if cond:
        print(f"ok    {name}")
    else:
        fails += 1
        print(f"FAIL  {name}")


with tempfile.TemporaryDirectory() as tmp:
    iso = {"XDG_STATE_HOME": f"{tmp}/state", "XDG_RUNTIME_DIR": f"{tmp}/run"}
    outside = f"{tmp}/outside"
    os.makedirs(outside)
    evil = f"{outside}/rbw"
    with open(evil, "w") as f:
        f.write("#!/bin/sh\necho EVIL\n")
    os.chmod(evil, 0o755)

    a = probe({**iso, "ENVS_TOOL_PATH": FAKES, "RBW_BIN": "rbw", "ENVS_TEST_YES": "1"})
    expect("a tool directory below tests/ with isolated state/runtime dirs is test mode", a.get("test") is True)
    expect("test mode: rbw and wl-copy come from the fake directories", str(a.get("rbw", "")).startswith(TESTS)
           and str(a.get("wl", "")).startswith(TESTS))
    expect("test mode keeps its hook variables", "ENVS_TEST_YES" in a.get("hooks", []))

    b = probe({**iso, "ENVS_TOOL_PATH": outside, "RBW_BIN": evil, "ENVS_TEST_YES": "1", "ENVS_TEST_ROOT_PID": "1",
               "PINENTRY_BIN": evil, "VAULT_BW_NODUMP_SRC": evil})
    expect("a tool directory OUTSIDE tests/ is not test mode (hooks are dropped)", b.get("test") is False and b.get("dirs") == [])
    expect("outside test mode RBW_BIN / a fake rbw in ENVS_TOOL_PATH are never used", b.get("rbw") != evil
           and not str(b.get("rbw") or "").startswith(outside))
    expect("outside test mode the hook variables are removed from our environment", b.get("hooks") == [])
    expect("outside test mode our own subprocesses only see the system directories",
           b.get("path", "").startswith("/usr/bin:/usr/local/bin:") and ".local/bin" in b.get("path", ""))
    expect("... and the command we run gets the user's PATH and the hook variables back", b.get("cmdpath") == b.get("orig")
           and "ENVS_TEST_YES" in b.get("cmd_hooks", []))
    expect("outside test mode the state directory is the account's, not XDG_STATE_HOME",
           b.get("state") == os.path.expanduser("~/.local/state"))

    c = probe({**iso, "ENVS_TOOL_PATH": f"{FAKES}:{outside}"})
    expect("one entry outside tests/ spoils the whole list", c.get("test") is False)
    d = probe({"ENVS_TOOL_PATH": FAKES}, drop=("XDG_STATE_HOME", "XDG_RUNTIME_DIR"))
    expect("test dirs without isolated state/runtime dirs are not test mode (the fakes would write into the account)",
           d.get("test") is False)
    e = probe({"ENVS_TOOL_PATH": FAKES, "XDG_STATE_HOME": os.path.expanduser("~/.local/state"),
               "XDG_RUNTIME_DIR": f"{tmp}/run"})
    expect("the real state directory is refused for test mode", e.get("test") is False)
    f = probe({**iso, "ENVS_TOOL_PATH": f"{TESTS}/envs/bin"})
    expect("test mode: the vault tools never fall back to /usr/bin (rbw missing in the fake dir = not found)",
           f.get("test") is True and f.get("rbw") is None)
    g = probe({**iso, "ENVS_TOOL_PATH": FAKES, "RBW_BIN": evil})
    expect("test mode: an absolute RBW_BIN outside the fake directories is ignored", g.get("rbw") != evil)

sys.exit(1 if fails else 0)
