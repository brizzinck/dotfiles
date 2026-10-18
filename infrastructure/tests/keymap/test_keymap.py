#!/usr/bin/env python3
"""Offline test of the SUPER+/ shortcut search (.config/keymap/keymap.py): exact word search with keywords, global binds first,
Start here rows on an empty query, Audit hidden from the all view, header / preview / cycle text, the keyword rules, and the real
menu in a private tmux. The unit part runs on fixture.json (KEYMAP_DB), the live part on ~/.cache/keymap/keymap.json when it is a
v4 database. Nothing is copied or sent: no entry is accepted, XDG_RUNTIME_DIR is a scratch directory.
  test_keymap.py [--quick]   --quick (doctor) skips the tmux part. Prints PASS / FAIL lines, exit 1 on any failure."""
import atexit
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
KM = REPO / ".config/keymap/keymap.py"
FIX = HERE / "fixture.json"
QUICK = "--quick" in sys.argv[1:]
TMP = Path(tempfile.mkdtemp(prefix="keymap-test."))
RUN = TMP / "run"
RUN.mkdir()
SOCK = f"keymap-test-{os.getpid()}"


def _cleanup():
    """runs on any exit, also after an exception: the private tmux server and the scratch directory never stay behind"""
    subprocess.run(["tmux", "-L", SOCK, "kill-server"], capture_output=True)
    shutil.rmtree(TMP, ignore_errors=True)


atexit.register(_cleanup)
ANSI = re.compile(r"\x1b\[[0-9;]*m")
results = []


def check(name, cond):
    results.append(bool(cond))
    print(("PASS  " if cond else "FAIL  ") + name)


def keymap(*args, query="", db=FIX):
    env = dict(os.environ, KEYMAP_DB=str(db), XDG_RUNTIME_DIR=str(RUN), FZF_QUERY=query, PYTHONPYCACHEPREFIX="/tmp/pycache")
    return subprocess.run([sys.executable, str(KM), *args], capture_output=True, text=True, env=env).stdout


def rows(query, db=FIX):
    """[(index, keys, description, scope)] of the plain menu rows"""
    out = []
    for line in ANSI.sub("", keymap("rows", query=query, db=db)).splitlines():
        f = line.split("\t")
        out.append((f[0], f[1].rstrip(), f[2], f[3].strip()))
    return out


def descs(query, db=FIX):
    return [r[2] for r in rows(query, db)]


spec = importlib.util.spec_from_file_location("km", KM)
km = importlib.util.module_from_spec(spec)
spec.loader.exec_module(km)

# ── fixture: search semantics ──
check("screenshot: the four hyprland screenshot rows come first", all(d.startswith("Screenshot") for d in descs("screenshot")[:4]))
check("'screen shot' (two words) finds the same rows first", all(d.startswith("Screenshot") for d in descs("screen shot")[:4]))
check("'screen shot': a handful of rows, not the fuzzy hundreds", 0 < len(rows("screen shot")) <= 8)
check("'screen shot': tmux / nvim rows that only contain 'screen' do not match", not any("Redraw" in d for d in descs("screen shot")))
for q in ("record", "clipboard", "password", "volume", "brightness"):
    r = rows(q)
    check(f"keyword '{q}': a global row first", r and r[0][3] == "global")
check("keyword words that appear nowhere in the row text find it ('snip' -> Screenshot rows)", descs("snip")[:1] == ["Screenshot region"])
check("'w' finds Super+W first", rows("w")[0][1] == "Super+W")
check("'w' does not match 'window' as a substring (Move window left is not a hit)", "Move window left" not in descs("w"))
check("exact: a typo finds nothing (no fuzzy matching)", rows("scrnsht") == [])
check("case-insensitive", descs("SCREENSHOT") == descs("screenshot"))
check("all words must match", rows("screenshot nonsenseword") == [])
check("a key chord matches as a substring of the keys (super+shift+h)", [r[1] for r in rows("super+shift+h")][:1] == ["Super+Shift+H"])
check("a short word matches a whole key part ('1' finds Super+1..0)", any(r[1] == "Super+1..0" for r in rows("1")))
check("highlighting: the matched words are bold + underlined in the description", "\x1b[1;4mScreenshot\x1b[22;24m" in keymap("rows", query="screenshot").splitlines()[0])
empty = rows("")
check("empty query: Start here rows first, in pins order, tagged start",
      [(r[1], r[3]) for r in empty[:5]] == [("Super+Space", "start"), ("Super+Enter", "start"), ("Super+W", "start"), ("Super+M", "start"), ("Super+/", "start")])
scopes = []
for r in empty:
    if not scopes or scopes[-1] != r[3]:
        scopes.append(r[3])
check("empty query: global rows before the leader rows before tmux and nvim", scopes == ["start", "global", "leader", "tmux", "nvim"])
check("empty all view has no audit row, and a query in the all view has none either", not any("Hyprlock" in d for d in descs("")) and not any("Hyprlock" in d for d in descs("screen")))
(RUN / "keymap").mkdir(exist_ok=True)
(RUN / "keymap" / "block").write_text("audit")
audit_desc = "Lock screen has no vim keys (screen text)"
check("block view 'audit' (Tab cycle state) shows it, and a query searches inside the block only",
      [d.startswith(audit_desc) for d in descs("")] == [True] and len(descs("screen")) == 1 and descs("password") == [])
(RUN / "keymap" / "block").write_text("capture")
check("a selected block shows exactly its rows in source order", [r[0] for r in rows("")] == [str(i) for i in range(10, 16)])
(RUN / "keymap" / "block").unlink()

# header, preview, cycle
check("header: all view says the count and where the Audit block is", keymap("header").strip() == "All shortcuts · 28 · Audit: Tab to it")
p = keymap("preview", "15")
check("preview: Keys / What / Where / Block and the Run line, no source or block description",
      "Keys    Super+Shift+R" in p and "What    Record region (toggle)" in p and "Where   global" in p and "Block   Screenshots and recording" in p
      and "Run     Alt+R replays it" in p and "Source" not in p and "Hyprland." not in p)
note = [ln for ln in keymap("preview", "24").splitlines() if ln.startswith("Note")]
check("preview: a long note is cut to 300 characters and an ellipsis", note and len(note[0]) <= 312 and note[0].endswith("…"))
check("preview: ctx joins the Where line", "Where   audit · login" in keymap("preview", "28"))
o = keymap("cycle", "next").strip()
check("cycle: reload-sync + first + change-header (colon form last), the header of the new block",
      o.startswith("reload-sync(") and o.endswith(" rows)+first+change-header:Block: Apps and launchers (5)"))
keymap("cycle", "reset")

# keywords
d = json.loads(FIX.read_text())
rws = [dict(r) for r in d["rows"]]
for r in rws:
    r.pop("kw", None)
km.apply_keywords(rws, d["blocks"])
kw = {r["desc"]: r.get("kw", "") for r in rws}
check("keywords.tsv: rules add their words by description",
      "screenshot" in kw["Screenshot region"] and "password" in kw["Passwords (Bitwarden via rbw and fzf)"] and "volume" in kw["Volume up"])
check("keywords.tsv: the block title gives no words (Volume up sits in 'Audio, media, brightness' and gets no 'dim' / 'brightness')",
      "dim" not in kw["Volume up"].split() and "brightness" not in kw["Volume up"].split() and "brightness" in kw["Brightness up (focused monitor)"])
check("keywords.tsv: 'Lock screen' in 'System, power, bar' gets lock but no reboot / shutdown (those words belong to the power menu)",
      "lock" in kw["Lock screen (password; layout reset to us)"].split() and "reboot" not in kw["Lock screen (password; layout reset to us)"].split())
synth = [{"desc": "Show a clock", "block": "x"}, {"desc": "Block hint", "block": "x"}, {"desc": "Lock screen", "block": "x", "kw": "stale"},
         {"desc": "Power menu", "block": "x"}]
km.apply_keywords(synth, [])
check("keywords.tsv: 'lock' does not match clock or block (word anchor)", "kw" not in synth[0] and "kw" not in synth[1])
check("keywords.tsv: a row that already had words (reused from the old DB) is recomputed, not appended to",
      synth[2]["kw"].split()[0] == "lock" and "stale" not in synth[2]["kw"] and "reboot" in synth[3]["kw"])
broad = {"pins": [], "hypr_binds": 0, "blocks": [{"id": "b", "title": "B", "count": 9}],
         "rows": [{"keys": f"k{i}", "desc": f"lock {i}", "block": "b", "source": "x"} for i in range(9)]}
real_rules = km.keyword_rules
km.keyword_rules = lambda: [("lock", re.compile("lock"), ["w"])]
check("keymap check: a keyword rule that hits every row of a block of 8+ is a broadcast and fails",
      any("every row of the block" in e for e in km.problems(broad)))
about = {"pins": [], "hypr_binds": 0, "blocks": [{"id": "dictation", "title": "Dictation", "count": 9}],
         "rows": [{"keys": f"k{i}", "desc": f"dictation {i}", "block": "dictation", "source": "x"} for i in range(9)]}
km.keyword_rules = lambda: [("dictation", re.compile("dictation"), ["dictation", "voice"])]
check("keymap check: a correct rule on a block that is about its topic (block 'Dictation', rule 'dictation') is no broadcast",
      not any("every row of the block" in e for e in km.problems(about)))
km.keyword_rules = lambda: [("clock", re.compile("clock"), ["w"])]
check("keymap check: a rule that matches nothing still fails (stale rule)", any("matches no row" in e for e in km.problems(broad)))
km.keyword_rules = real_rules
check("keymap check: the committed keywords.tsv passes against the fixture except for rules the fixture has no row for",
      not any("does not compile" in e or "broadcast" in e or "too broad" in e for e in km.problems(json.loads(FIX.read_text()))))
check("keywords.tsv: every regex compiles", all(rx is not None for _s, rx, _w in km.keyword_rules()))
check("fit_cells: pads to the width, cuts with an ellipsis", km.fit_cells("ab", 5) == "ab   " and km.fit_cells("abcdefgh", 5) == "abcd…" and km.cell_width(km.fit_cells("日本語日本語", 7)) == 7)

# ── live database ──
live = Path.home() / ".cache/keymap/keymap.json"
try:
    live_ok = json.loads(live.read_text()).get("version") == km.DB_VERSION
except (OSError, ValueError):
    live_ok = False
if live_ok:
    for q in ("screenshot", "record", "clipboard", "password", "volume", "brightness"):
        check(f"live '{q}': a global row among the first 3", any(r[3] == "global" for r in rows(q, live)[:3]))
    check("live 'screen shot' returns fewer than 25 rows", len(rows("screen shot", live)) < 25)
    for q, limit in (("reboot", 12), ("shutdown", 12), ("dim", 14), ("password", 60)):
        check(f"live '{q}': at most {limit} rows (block titles do not broadcast words)", 0 < len(rows(q, live)) <= limit)
    check("live 'reboot': the power menu rows only", all(re.search(r"power menu|reboot", d, re.I) for d in descs("reboot", live)))
    check("live 'dim': brightness rows only (no volume row)", all("rightness" in d or "ight" in d or "dim" in d.lower() for d in descs("dim", live)))
    check("live 'lock': the first rows are real lock rows, ahead of block / clock text hits",
          all(re.search(r"\block\b", d, re.I) for d in descs("lock", live)[:3]))
    check("live 'w' still finds Super+W first", rows("w", live)[0][1] == "Super+W")
    check("live: an empty query starts with the Start here rows", rows("", live)[0][3] == "start")
else:
    print("SKIP  live database (missing or an older version: run keymap gen)")

# ── the menu itself in a private tmux ──
sock = SOCK
if not QUICK and (not shutil.which("tmux") or not shutil.which("fzf")):
    print("SKIP  menu UI (tmux and fzf are required)")
    QUICK = True
if not QUICK:
    def tmux(*a):
        return subprocess.run(["tmux", "-L", sock, "-f", "/dev/null", *a], capture_output=True, text=True).stdout

    def shot():
        return tmux("capture-pane", "-p", "-t", "0")

    def waitfor(text, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            if text in shot():
                return True
            time.sleep(0.05)
        return False

    cmd = (f"PATH={REPO}/.local/bin:$PATH XDG_RUNTIME_DIR={RUN} XDG_CONFIG_HOME={REPO}/.config FZF_MENU_HERE=1 "
           f"KEYMAP_DB={FIX} python3 {KM} menu; sleep 3")
    tmux("new-session", "-d", "-x", "140", "-y", "30", cmd)
    waitfor("All shortcuts")
    for c in "screen shot":
        tmux("send-keys", "-t", "0", "-l", c)
        time.sleep(0.04)
    waitfor("7/7")
    waitfor("Keys    Print")
    scr = shot()
    lines = scr.splitlines()
    check("UI: typing 'screen shot' narrows the list to 7 rows", "7/7" in scr)
    check("UI: no '··' truncation marks", "··" not in scr)
    keyrows = [ln for ln in lines if re.match(r"^(▌| ) (Print|Shift\+Print|Super\+Print|Alt\+S|Super\+R|Super\+; c s|Super\+Shift\+R) ", ln)]
    check("UI: every list line starts with its keys text (the fixed keys column)", len(keyrows) == 7 and all(ln[2:26].strip() for ln in keyrows))
    check("UI: the description starts at one column on every row", len({ln.index("Screenshot") if "Screenshot" in ln[:40] else 28 for ln in keyrows[:4]}) == 1 and len({ln[2:26].rstrip() != "" for ln in keyrows}) == 1)
    check("UI: the scope tag is visible after the description", "Screenshot region  global" in scr and "Capture: Screenshot region  leader" in scr)
    check("UI: no audit row", "Hyprlock" not in scr)
    check("UI: the header line is not cut", "All shortcuts · 28 · Audit: Tab to it" in scr)
    check("UI: the preview shows the compact Keys / Where lines", "Keys    Print" in scr and "Where   global" in scr)
    check("UI: the footer is complete", "Enter copy · Alt+R run · Tab / Shift+Tab block · 0 all" in scr)
    tmux("send-keys", "-t", "0", "Escape")
    time.sleep(0.2)
    tmux("send-keys", "-t", "0", "Escape")
    time.sleep(0.8)
    check("UI: Esc Esc exits the menu", "python" not in tmux("list-panes", "-F", "#{pane_current_command}"))
    tmux("kill-server")

print(f"\nkeymap tests: {sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if all(results) else 1)
