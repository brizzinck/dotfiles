"""FIX-DEVb: pieces of the TUI that are hard to reach through a pty. Run inside the sandbox of env.sh (fake vault).
  - the preview command quotes a checkout path (spaces, `$(...)`) for fzf's `sh -c`
  - `v` (reveal) of a protected environment needs the typed name (no terminal = refused, no flag written)
usage: tui_test.py ENVS WORKDIR"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

ENVS, WORK = sys.argv[1], Path(sys.argv[2])
loader = importlib.machinery.SourceFileLoader("envs_mod", ENVS)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("envs_mod", loader))
loader.exec_module(m)
fails = 0


def expect(name, cond):
    global fails
    print(("ok    " if cond else "FAIL  ") + name)
    fails += not cond


mark = WORK / "MARK"
root = WORK / "we ird $(touch MARK) `touch MARK2`"
root.mkdir(parents=True)
(root / ".envs.toml").write_text('project = "billing"\nenvironments = ["dev", "stage", "prod"]\ndefault = "dev"\n[secrets]\nDATABASE_URL = ""\n')
cmd = m.preview_command("envs", "billing", str(root), "-").replace("{1}", "dev")
p = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, cwd=str(WORK))
expect("preview: a checkout path with spaces and $(...) / backticks is data, never executed",
       not mark.exists() and not (WORK / "MARK2").exists())
expect("preview: and the quoted command still works for such a path", p.returncode == 0 and "environment dev" in p.stdout)
expect("preview command: absolute interpreter, -I, absolute script", cmd.startswith(f"{m.PY} -I ") and str(m.SELF) in cmd)

cfg = m.load_cfg(root)
m._REVEAL = m.run_dir() / "reveal-1-0123456789ab"
m._REVEAL.unlink(missing_ok=True)
try:
    m.tui_action("vars", "reveal", "DATABASE_URL", "billing", "prod", cfg, root, None)
    refused = False
except m.Fail:
    refused = True
expect("reveal of a protected environment without the typed name is refused and writes no flag", refused and not m._REVEAL.exists())
m.tui_action("vars", "reveal", "DATABASE_URL", "billing", "dev", cfg, root, None)
expect("reveal of an ordinary environment writes this run's flag", m._REVEAL.exists())
m._REVEAL.unlink(missing_ok=True)
sys.exit(1 if fails else 0)
