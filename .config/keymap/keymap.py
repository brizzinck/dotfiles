#!/usr/bin/env python3
"""keymap: the automatic shortcut reference. One generator, one JSON database, every view comes out of it.

  keymap gen             rebuild ~/.cache/keymap/keymap.json from the live sources (always)
  keymap json            print the database (rebuilt first when a source changed)
  keymap md              print docs/keymap.md generated from the database; `keymap md --write` writes the file
  keymap check           exit 1 when docs/keymap.md differs from a fresh generation, a pinned key vanished or a block is empty
  keymap stats           rows per block and the Hyprland bind count against the live table
  keymap menu            SUPER+/: every shortcut in an fzf-menu (Tab / Shift+Tab or l / h cycle the block, 0 = all)
  keymap page [--print]  SUPER+SHIFT+/: render the reading page and show it (--print: only write it, print the path)
  keymap rows|header|preview|cycle|run    helpers of the menu (they read the cached database, no staleness check per key)

Sources, all read live (cheap staleness check: mtimes of every source file + a hash of the live Hyprland bind table, so
opening is fast and `keymap gen` is only needed to force a rebuild):
  Hyprland   `hyprctl -j binds` (descriptions of the Lua binds; submaps resize and mouse), sorted into blocks by rules.tsv
  leader     the hub rows through .config/hub/leader (build_menu), so the menu and this list cannot drift
  tmux       a private tmux server that loads tmux.conf: `list-keys -F` (tables prefix, root, copy-mode-vi) next to a stock
             server (`-f /dev/null`) tells custom from default binds; the -N note of a bind is its description
  zsh        `bindkey -M viins/vicmd` and `zle -lL` from an interactive zsh on a pty, .zshrc functions and aliases
  nvim       a headless dump of every mapping that has a desc (nvim-dump.lua), grouped by the <leader> prefix
  bar        the L / M / R / Scroll tooltip hints of waybar modules.jsonc and the bar scripts
  telegram   apps/telegram/shortcuts-custom.json;  vimium  browsers/vimium-c.json (+ defaults table)
  obsidian   apps/obsidian/obsidian.vimrc (the nmap lines; ex commands are described in describe.tsv)
  committed  static.tsv: menu key lists, login screen, layout rules, zsh vi grammar (not reliably parseable)
Tables next to this file: blocks.tsv (block order, text, menu scope tag and rank), rules.tsv (Hyprland -> block), keywords.tsv
(search words), describe.tsv, pins.tsv, intro.tsv.

Search (menu and page, one definition: search() here, apply() in page.html): the query is split into words that must ALL match a
row; a word matches a substring of the keys, the description, the block title / scope tag or the keywords; a word of one or two
characters must match a whole key (`w` finds Super+W, not "window") or a whole word. Equal matches are ordered global Hyprland
binds first (blocks.tsv rank). No fuzzy matching. fzf's own matcher is off in the menu (`--disabled`): it cannot search the hidden
keyword field, and it matched 160 rows for "screen shot".
"""
import hashlib
import html
import importlib.machinery
import importlib.util
import json
import os
import pty
import re
import select
import shlex
import shutil
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
HOME = Path.home()
CFG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state"))
CACHE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "keymap"
RUN = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "keymap"
DB_FILE = Path(os.environ["KEYMAP_DB"]) if os.environ.get("KEYMAP_DB") else CACHE / "keymap.json"   # KEYMAP_DB: fixture DB of the tests
PAGE_FILE = CACHE / "keymap.html"
DOC_FILE = REPO / "docs" / "keymap.md"
KEYWORD_MAX_ROWS = 60     # a keywords.tsv rule that hits more descriptions than this is too broad (`keymap check`)
DB_VERSION = 5          # v5: keywords match the description only; v4: rows gain `kw` (keywords.tsv), blocks gain `scope` and `rank` (blocks.tsv)

GROUPS = ["Desktop", "Terminal", "Editor", "Menus and bar", "Apps and login"]


# ── small helpers ────────────────────────────────────────────────────────────────────────────────────────────────
def read_tsv(path, minimum=1):
    """Rows of a tab separated table: `#` comments and blank lines skipped, short rows padded with ''."""
    rows = []
    if not Path(path).is_file():
        return rows
    for line in Path(path).read_text(encoding="utf-8").split("\n"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        cols += [""] * (minimum - len(cols))
        rows.append(cols)
    return rows


def run(cmd, timeout=20, env=None, stdin=None):
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, input=stdin)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return res


def alts_text(alts):
    """[[chord, ...], ...] alternatives of sequences of chords of key names -> 'Super+Shift+H / Alt+Tab'."""
    return " / ".join(" ".join("+".join(chord) for chord in seq) for seq in alts)


def parse_keys(text):
    """Table syntax -> (alts, raw). `+` joins a chord, a space a sequence, ` / ` an alternative; `=text` is plain text."""
    if text.startswith("="):
        return [[[text[1:]]]], True
    alts = []
    for alt in text.split(" / "):
        alts.append([chord.split("+") if chord != "+" else ["+"] for chord in alt.split()])
    return alts, False


class Db:
    def __init__(self):
        self.rows = []

    def add(self, block, alts, desc, source, ctx="", note="", run="", n=1, raw=False, key_text=None):
        row = {"block": block, "keys": key_text if key_text is not None else alts_text(alts), "alts": alts, "desc": desc,
               "source": source}
        if ctx:
            row["ctx"] = ctx
        if note:
            row["note"] = note
        if run:
            row["run"] = run
        if n != 1:
            row["n"] = n
        if raw:
            row["raw"] = True
        self.rows.append(row)

    def add_text(self, block, keys, desc, source, **kw):
        alts, raw = parse_keys(keys)
        self.add(block, alts, desc, source, raw=raw, key_text=keys[1:] if raw else None, **kw)  # `=text`: plain text without the marker


# ── Hyprland ─────────────────────────────────────────────────────────────────────────────────────────────────────
HYPR_KEYS = {
    "return": "Enter", "space": "Space", "escape": "Esc", "tab": "Tab", "period": ".", "comma": ",", "slash": "/",
    "semicolon": ";", "apostrophe": "'", "grave": "`", "equal": "=", "minus": "-", "bracketleft": "[",
    "bracketright": "]", "backslash": "\\", "left": "Left", "right": "Right", "up": "Up", "down": "Down",
    "print": "Print", "backspace": "Backspace", "delete": "Delete", "home": "Home", "end": "End",
    "xf86audioraisevolume": "Vol up", "xf86audiolowervolume": "Vol down", "xf86audiomute": "Mute",
    "xf86audiomicmute": "Mic mute", "xf86monbrightnessup": "Bright up", "xf86monbrightnessdown": "Bright down",
    "xf86audioplay": "Play", "xf86audiopause": "Pause", "xf86audionext": "Next track", "xf86audioprev": "Prev track",
    "xf86poweroff": "Power", "mouse:272": "Left button", "mouse:273": "Right button", "mouse_down": "Scroll down",
    "mouse_up": "Scroll up",
}
MOUSE_DESC = {  # binds without a description: only the mouse ones are worth a row
    "mouse:272": ("windows", "Drag a window to move it"),
    "mouse:273": ("windows", "Drag a window to resize it"),
    "mouse_down": ("workspaces", "Next workspace"),
    "mouse_up": ("workspaces", "Previous workspace"),
}
MOD_BITS = [(64, "SUPER"), (4, "CTRL"), (8, "ALT"), (1, "SHIFT")]


def hypr_env():
    """hyprctl needs the instance signature; a shell older than the session may carry a stale or no one."""
    env = dict(os.environ)
    res = run(["hyprctl", "-j", "version"], timeout=3, env=env)
    if res is not None and res.returncode == 0:
        return env
    rt = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "hypr"
    socks = sorted(rt.glob("*/.socket.sock"), key=lambda p: p.stat().st_mtime, reverse=True) if rt.is_dir() else []
    for sock in socks:
        env["HYPRLAND_INSTANCE_SIGNATURE"] = sock.parent.name
        res = run(["hyprctl", "-j", "version"], timeout=3, env=env)
        if res is not None and res.returncode == 0:
            return env
    return None


def hypr_binds():
    """Live bind table (list of dicts) or None when Hyprland is not reachable."""
    env = hypr_env()
    if env is None:
        return None
    res = run(["hyprctl", "-j", "binds"], timeout=5, env=env)
    if res is None or res.returncode != 0:
        return None
    try:
        return json.loads(res.stdout)
    except ValueError:
        return None


def hypr_label(bind):
    """The text the hub and df_bind_run use: mods in SUPER CTRL ALT SHIFT order, key as in the live table."""
    mods = [name for bit, name in MOD_BITS if bind["modmask"] & bit]
    return "+".join(mods + [bind["key"]])


def hypr_chord(modmask, key, catch_all=False):
    if catch_all:
        return [["any other key"]]
    mods = [name.capitalize() for bit, name in MOD_BITS if modmask & bit]
    name = HYPR_KEYS.get(key.lower())
    if name is None:
        name = key.upper() if (len(key) == 1 and mods) else key
    return [mods + [name]]


def load_rules():
    return [(kind, re.compile(rx, re.I), block) for kind, rx, block in read_tsv(HERE / "rules.tsv", 3)]


def classify(rules, submap, label, desc):
    for kind, rx, block in rules:
        target = {"submap": submap, "desc": desc, "key": label.lower()}.get(kind, "")
        if rx.search(target):
            return block
    return "hypr-other"


def hub_notes():
    """keys text of a hub row (lower case) -> its explanatory text, used as the note of the matching bind."""
    notes = {}
    for cols in read_tsv(CFG / "hub/actions.tsv", 10) + [c for p in sorted((CFG / "hub/actions.d").glob("*.tsv"))
                                                         for c in read_tsv(p, 10)]:
        keys, desc = cols[3], cols[8]
        if keys and keys != "-" and desc and desc != "-":
            notes[keys.lower()] = desc
    return notes


WS_RE = re.compile(r"^(Move window to )?[Ww]orkspace (\d+)$")


def collect_hyprland(db, binds):
    rules = load_rules()
    notes = hub_notes()
    seen = set()
    groups = {}  # collapsed workspace digit binds: (prefix, modmask, submap) -> [bind]
    order = []
    for b in binds:
        ident = (b["submap"], b["modmask"], b["key"], bool(b.get("catch_all")))
        if b.get("has_description"):
            if ident in seen:
                continue
            seen.add(ident)
            m = WS_RE.match(b["description"])
            if m:
                gkey = (m.group(1) or "", b["modmask"], b["submap"])
                if gkey not in groups:
                    groups[gkey] = []
                    order.append(("ws", gkey))
                groups[gkey].append(b)
            else:
                order.append(("bind", b))
        elif b["key"] in MOUSE_DESC and not b["submap"]:
            order.append(("mouse", b))
    for kind, item in order:
        if kind == "bind":
            b = item
            label = hypr_label(b)
            sub = b["submap"]
            block = classify(rules, sub, label, b["description"])
            alts = [hypr_chord(b["modmask"], b["key"], bool(b.get("catch_all")))]
            ctx = f"{sub} mode" if sub else ""
            runnable = "" if (sub or b.get("catch_all") or b.get("mouse")) else label
            db.add(block, alts, b["description"], "hyprland", ctx=ctx, note=notes.get(label.lower(), ""), run=runnable)
        elif kind == "mouse":
            b = item
            block, desc = MOUSE_DESC[b["key"]]
            db.add(block, [hypr_chord(b["modmask"], b["key"])], desc, "hyprland", n=0)
        else:
            prefix, modmask, sub = item
            binds_ = groups[item]
            nums = sorted(int(WS_RE.match(b["description"]).group(2)) for b in binds_)
            digit_keys = "".join(b["key"] for b in binds_)
            mods = [name.capitalize() for bit, name in MOD_BITS if modmask & bit]
            rng = f"{nums[0]}-{nums[-1]}" if len(nums) > 1 else str(nums[0])
            keyname = f"{digit_keys[0]}..{digit_keys[-1]}" if len(digit_keys) > 1 else digit_keys
            desc = f"{'Move window to workspace' if prefix else 'Workspace'} {rng}"
            db.add("workspaces", [[mods + [keyname]]], desc, "hyprland", n=len(binds_))


# ── leader menu ──────────────────────────────────────────────────────────────────────────────────────────────────
def load_leader_module():
    path = CFG / "hub/leader"
    loader = importlib.machinery.SourceFileLoader("df_leader", str(path))
    spec = importlib.util.spec_from_loader("df_leader", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def leader_key(k):
    return {"space": "Space", "semicolon": ";"}.get(k, k)


def collect_leader(db):
    mod = load_leader_module()
    menu, errors = mod.build_menu()
    if errors:
        print("keymap: leader menu has problems: " + "; ".join(errors), file=sys.stderr)
    lead = ["Super", ";"]
    for key, label, body in menu:
        if isinstance(body, list):
            for k, lab, _cmd in body:
                db.add("leader", [[lead, [leader_key(key)], [leader_key(k)]]], f"{label}: {lab}", "leader")
        else:
            db.add("leader", [[lead, [leader_key(key)]]], label, "leader")


# ── tmux ─────────────────────────────────────────────────────────────────────────────────────────────────────────
TMUX_SOCK = "df-keymap"
TMUX_MODS = {"C": "Ctrl", "M": "Alt", "S": "Shift"}
TMUX_KEYS = {"Space": "Space", "Tab": "Tab", "Escape": "Esc", "Enter": "Enter", "BSpace": "Backspace", "Up": "Up",
             "Down": "Down", "Left": "Left", "Right": "Right", "PageUp": "PageUp", "PageDown": "PageDown",
             "Home": "Home", "End": "End", "DoubleClick1Pane": "Double click", "TripleClick1Pane": "Triple click"}


def tmux_list(conf):
    """Rows (table, key, note, command) of a private tmux server; None when tmux is missing."""
    env = {k: v for k, v in os.environ.items() if k != "TMUX"}
    base = ["tmux", "-L", f"{TMUX_SOCK}-{os.getpid()}", "-f", conf]
    started = run(base + ["new-session", "-d", "-s", "km", "-x", "200", "-y", "50"], timeout=20, env=env)
    if started is None or started.returncode != 0:
        return None
    fmt = "#{key_table}\t#{key_string}\t#{key_note}\t#{key_command}"
    rows, last = [], -1
    try:
        for _ in range(30):  # plugins (run-shell -b) add binds a moment after the config: wait until the count settles
            res = run(base + ["list-keys", "-F", fmt], timeout=10, env=env)
            if res is None or res.returncode != 0:
                break
            rows = [line.split("\t", 3) for line in res.stdout.split("\n") if line.count("\t") >= 3]
            if len(rows) == last:
                break
            last = len(rows)
            time.sleep(0.15)
    finally:
        run(base + ["kill-server"], timeout=10, env=env)
        # kill-server leaves the socket file behind: hundreds of dead ones piled up in /tmp/tmux-UID
        try:
            os.unlink(os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp", f"tmux-{os.getuid()}", f"{TMUX_SOCK}-{os.getpid()}"))
        except OSError:
            pass
    return rows


def tmux_key(table, ks):
    """tmux key string -> alts ([] when the key is not worth a row: Cyrillic twins, mouse events)."""
    if not ks.isascii() or ks.startswith(("Mouse", "Wheel", "Drag", "SecondClick", "C-Mouse", "M-Mouse")):
        return []
    mods = []
    while len(ks) > 2 and ks[1] == "-" and ks[0] in TMUX_MODS:
        mods.append(TMUX_MODS[ks[0]])
        ks = ks[2:]
    base = TMUX_KEYS.get(ks, ks)
    if len(base) == 1 and base.isalpha() and mods:
        if base.isupper() and "Shift" not in mods:
            mods.append("Shift")
        base = base.upper()
    chord = mods + [base]
    return [[["Prefix"], chord] if table == "prefix" else [chord]]


def collect_tmux(db):
    conf = str(CFG / "tmux/tmux.conf")
    live = tmux_list(conf)
    if not live:
        return False
    stock = {(t, k): c for t, k, _n, c in (tmux_list("/dev/null") or [])}
    describe = [(re.compile(rx), text) for kind, rx, text in read_tsv(HERE / "describe.tsv", 3) if kind == "tmux-cmd"]
    home = str(HOME)
    seen = {}
    for table, ks, note, cmd in live:
        if table not in ("prefix", "root", "copy-mode-vi"):
            continue
        alts = tmux_key(table, ks)
        if not alts:
            continue
        is_stock = stock.get((table, ks)) == cmd
        if is_stock and (table != "prefix" or not note):
            continue
        desc = note
        if not desc:
            for rx, text in describe:
                if rx.search(cmd):
                    desc = text
                    break
        if not desc:
            desc = re.sub(r"\s+", " ", cmd.replace(home, "~"))[:90]
        block = "tmux-default" if is_stock else "tmux-custom"
        ctx = {"root": "", "prefix": "", "copy-mode-vi": "copy mode (vi)"}[table]
        mark = (block, table, ks)
        if mark in seen:
            continue
        seen[mark] = True
        db.rows.append({"block": block, "keys": "", "alts": alts, "desc": desc, "source": "tmux", "_cmd": cmd,
                        "_table": table, "_key": ks, **({"ctx": ctx} if ctx else {})})
    merge_tmux(db)
    return True


def merge_tmux(db):
    """Rows with the same command in one table become alternatives (S and C-s); Alt+1..9 collapse into one row."""
    tables = {"prefix": 0, "root": 1, "copy-mode-vi": 2}
    db.rows.sort(key=lambda r: (r["source"] != "tmux", tables.get(r.get("_table"), 0)) if r["source"] == "tmux" else (False, 0))
    out, by_cmd = [], {}
    digits = []
    for row in db.rows:
        if row["source"] != "tmux":
            out.append(row)
            continue
        key = (row["block"], row["_table"], row["_cmd"])
        if re.fullmatch(r"M-[1-9]", row["_key"]) and row["_table"] == "root":
            digits.append(row)
            continue
        if key in by_cmd:
            by_cmd[key]["alts"].extend(row["alts"])
            continue
        by_cmd[key] = row
        out.append(row)
    if digits:
        first = digits[0]
        first["alts"] = [[["Alt", f"1..{len(digits)}"]]]
        first["desc"] = f"Jump to window 1..{len(digits)}"
        first["n"] = len(digits)
        out.append(first)
    db.rows = out
    for row in db.rows:
        if row["source"] == "tmux":
            row["keys"] = alts_text(row["alts"])
            for k in ("_cmd", "_table", "_key"):
                row.pop(k, None)


# ── zsh ──────────────────────────────────────────────────────────────────────────────────────────────────────────
ZSH_SCRIPT = (
    "print -r -- @@KM-START\n"
    "for km in viins vicmd; do print -r -- \"@@KM $km\"; bindkey -M $km; done\n"
    "print -r -- @@KM-WIDGETS; zle -l\n"
    "print -r -- @@KM-END\nexit\n"
)
ZSH_NAMED = {"^I": "Tab", "^M": "Enter", "^J": "Enter", "^?": "Backspace", "^H": "Backspace", "^[": "Esc"}
ZSH_SEQ = {"[Z": ["Shift", "Tab"], "[3~": ["Delete"], "[A": ["Up"], "[B": ["Down"], "[C": ["Right"], "[D": ["Left"],
           "OA": ["Up"], "OB": ["Down"], "[5~": ["PageUp"], "[6~": ["PageDown"], "[1;5C": ["Ctrl", "Right"],
           "[1;5D": ["Ctrl", "Left"], "[3;5~": ["Ctrl", "Delete"], "[1~": ["Home"], "[4~": ["End"]}


def zsh_session():
    """Run an interactive zsh on a pty (fzf and the oh-my-zsh plugins only bind their keys with a tty) and return its output."""
    zsh = shutil.which("zsh")
    if not zsh:
        return None
    master, slave = pty.openpty()
    env = dict(os.environ, TERM="xterm-256color", CLAUDECODE="")
    env.pop("TMUX", None)
    proc = subprocess.Popen([zsh, "-i"], stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True,
                            start_new_session=True)
    os.close(slave)
    buf, deadline, sent = b"", time.time() + 25, False
    try:
        while time.time() < deadline:
            ready, _, _ = select.select([master], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
            if not sent and (b"%" in buf or b"\xe2\x9e\x9c" in buf or b"$" in buf or time.time() > deadline - 20):
                # first prompt drawn: the rc files are done
                time.sleep(0.4)
                os.write(master, ZSH_SCRIPT.encode())
                sent = True
            if re.search(rb"^@@KM-END$", buf, re.M):
                break
    finally:
        try:
            os.write(master, b"exit\n")
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.close(master)
    text = buf.decode("utf-8", "replace").replace("\r", "")
    return re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]|\x07", "", text)


def zsh_keyspec(spec):
    """bindkey key text ('^X', '^[s', '^[[Z') -> chord list, or None when it is not a plain readable key."""
    if "\\M-" in spec or "\\C-" in spec:
        return None
    spec = spec.replace('\\"', '"').replace("\\\\", "\\").replace("\\^", "^").replace("\\`", "`").replace("\\$", "$")
    if spec in ZSH_NAMED:
        return [[ZSH_NAMED[spec]]]
    if spec.startswith("^[") and len(spec) > 2:
        rest = spec[2:]
        if rest in ZSH_SEQ:
            return [ZSH_SEQ[rest]]
        if len(rest) == 1 and rest.isprintable():
            return [["Alt", rest.upper() if rest.isalpha() else rest]]
        return None
    chords, i = [], 0
    while i < len(spec):
        if spec[i] == "^" and i + 1 < len(spec):
            ch = spec[i + 1]
            chords.append(["Ctrl", ch.upper() if ch.isalpha() else ch])
            i += 2
        elif spec[i] == "\\" and i + 1 < len(spec):
            chords.append([spec[i + 1]])
            i += 2
        else:
            chords.append([spec[i]])
            i += 1
    return chords


def collect_zsh(db):
    out = zsh_session()
    if not out or not re.search(r"^@@KM-END$", out, re.M):
        return False
    body = re.split(r"^@@KM-START$", out, flags=re.M)[-1]
    custom = set()
    for line in body.split("@@KM-WIDGETS", 1)[-1].split("@@KM-END")[0].split("\n"):
        name = line.split(" ", 1)[0].strip()
        # autosuggestions and syntax highlighting wrap every builtin ("name (_zsh_autosuggest_bound_..)"): only the
        # widgets nobody wrapped are the user's or a plugin's own
        if not name or name[0] in "._" or "_bound_" in line or " -C " in line or name.startswith("autosuggest-orig"):
            continue
        custom.add(name)
    desc = {k: v for kind, k, v in read_tsv(HERE / "describe.tsv", 3) if kind == "zsh-widget"}
    seen = {}
    parts = re.split(r"^@@KM (viins|vicmd)\n", body, flags=re.M)
    modes = {}
    for i in range(1, len(parts) - 1, 2):
        modes[parts[i]] = parts[i + 1].split("@@KM-WIDGETS")[0]
    for mode, text in modes.items():
        ctx = {"viins": "INSERT", "vicmd": "NORMAL"}[mode]
        for line in text.split("\n"):
            m = re.match(r'^"((?:[^"\\]|\\.)*)" (\S+)$', line)
            if not m:
                continue
            spec, widget = m.groups()
            if widget in ("self-insert", "undefined-key", "beep", "digit-argument", "bracketed-paste") or widget.startswith("_"):
                continue
            if widget not in desc and widget not in custom:
                continue
            if spec in ("^X", "^V") and widget == "vi-quoted-insert":
                continue
            chords = zsh_keyspec(spec)
            if not chords:
                continue
            text_ = desc.get(widget) or widget.replace("-", " ").capitalize()
            key = (tuple(map(tuple, chords)), text_)
            if key in seen:
                seen[key]["ctx"] = ", ".join(sorted(set(seen[key]["ctx"].split(", ")) | {ctx}, key=["INSERT", "NORMAL"].index))
                continue
            db.add("zsh-keys", [chords], text_, "zsh", ctx=ctx)
            seen[key] = db.rows[-1]
    return True


ALIAS_RE = re.compile(r"^\s*alias\s+([\w.-]+)=(['\"])(.*)\2\s*(?:#.*)?$")
FUNC_RE = re.compile(r"^([A-Za-z_][\w-]*)\(\)\s*\{")


def collect_zsh_text(db):
    path = HOME / ".zshrc"
    if not path.is_file():
        return
    overrides = {k: v for kind, k, v in read_tsv(HERE / "describe.tsv", 3) if kind == "helper"}
    lines = path.read_text(encoding="utf-8").split("\n")
    for i, line in enumerate(lines):
        m = FUNC_RE.match(line.lstrip())
        if m and not m.group(1).startswith("_") and line == line.lstrip():
            name = m.group(1)
            comment = []
            j = i - 1
            while j >= 0 and lines[j].startswith("#"):
                comment.insert(0, lines[j].lstrip("# ").rstrip())
                j -= 1
            comment = [c for c in comment if c and "──" not in c]
            desc = overrides.get(name) or " ".join(comment)
            if desc:
                db.add_text("zsh-helpers", name, desc[:1].upper() + desc[1:], "zsh")
            continue
        a = ALIAS_RE.match(line)
        if a:
            name, _q, value = a.groups()
            value = value.replace("$HOME", "~")
            db.add_text("zsh-aliases", name, value, "zsh")
    for name, desc in overrides.items():
        if not any(r["block"] == "zsh-helpers" and r["keys"] == name for r in db.rows) and re.search(
                rf"^{re.escape(name)}\(\)", "\n".join(lines), re.M):
            db.add_text("zsh-helpers", name, desc, "zsh")


# ── nvim ─────────────────────────────────────────────────────────────────────────────────────────────────────────
NVIM_NAMES = {"cr": "Enter", "esc": "Esc", "tab": "Tab", "space": "Space", "bs": "Backspace", "del": "Delete",
              "up": "Up", "down": "Down", "left": "Left", "right": "Right", "leader": "Space", "bar": "|",
              "lt": "<", "bslash": "\\", "pageup": "PageUp", "pagedown": "PageDown", "home": "Home", "end": "End"}


def nvim_tokens(lhs, leader):
    """'<C-W>d' -> [['Ctrl','W'], ['d']]; the leader character is shown as Space."""
    toks, i = [], 0
    while i < len(lhs):
        ch = lhs[i]
        if ch == "<":
            j = lhs.find(">", i)
            if j > i + 1:
                inner = lhs[i + 1:j]
                parts = inner.split("-")
                mods, key = [], inner
                while len(parts) > 1 and parts[0].upper() in ("C", "S", "M", "A", "D"):
                    mods.append({"C": "Ctrl", "S": "Shift", "M": "Alt", "A": "Alt", "D": "Super"}[parts.pop(0).upper()])
                    key = "-".join(parts)
                key = NVIM_NAMES.get(key.lower(), key if len(key) > 1 and key[0] in "Ff" and key[1:].isdigit()
                                     else (key.upper() if len(key) == 1 and mods and "Shift" not in mods else key))
                toks.append(mods + [key])
                i = j + 1
                continue
        toks.append(["Space"] if ch == leader else [ch])
        i += 1
    return toks


def collect_nvim(db):
    nvim = shutil.which("nvim")
    if not nvim:
        return False
    dump = HERE / "nvim-dump.lua"
    wait = 'lua vim.wait(15000, function() return package.loaded["mappings"] ~= nil end, 50); vim.wait(400)'
    res = run([nvim, "--headless", "-c", wait, "-c", f"luafile {dump}", "-c", "qa!"], timeout=40)
    if res is None or not res.stdout.strip():
        return False
    try:
        data = json.loads(res.stdout.strip().split("\n")[-1])
    except ValueError:
        return False
    leader = data["leader"]
    tbl = read_tsv(HERE / "describe.tsv", 3)
    prefix = {k: v for kind, k, v in tbl if kind == "nvim-prefix"}
    tidy = [(re.compile(k), v) for kind, k, v in tbl if kind == "nvim-desc"]
    skip = [re.compile(k) for kind, k, _v in tbl if kind == "nvim-skip"]
    merged, order = {}, []
    for m in data["keys"]:
        lhs, desc, mode = m["lhs"], m["desc"], m["mode"]
        if not lhs.isascii() or any(rx.search(desc) for rx in skip):
            continue
        for rx, repl in tidy:
            if rx.search(desc):
                desc = rx.sub(repl, desc)
        key = (lhs, desc)
        if key not in merged:
            merged[key] = set()
            order.append(key)
        merged[key].add({"v": "x"}.get(mode, mode))
    order.sort(key=lambda k: (k[0].lower(), k[0], k[1]))  # nvim_get_keymap order is a hash order: sort for a stable document
    for lhs, desc in order:
        modes = merged[(lhs, desc)]
        toks = nvim_tokens(lhs, leader)
        block = "nvim-edit"
        if lhs.startswith(leader) and len(lhs) > 1:
            block = prefix.get(lhs[1], "nvim-files")
        elif lhs.startswith(leader):
            block = "nvim-files"
        elif re.fullmatch(r"gr.|g[OdDIyl]|K|[\[\]][edwDEW]", lhs):
            block = "nvim-lsp"
        if desc.lower().startswith("telescope"):
            block = "nvim-find"
        elif "nvcheatsheet" in desc:
            block = "nvim-files"
        desc = desc[:1].upper() + desc[1:]
        label = {"n": "", "x": "visual", "i": "insert", "t": "terminal", "o": "operator", "c": "command line"}
        if "n" in modes:
            ctx = ""
        else:
            ctx = ", ".join(label[m] for m in sorted(modes) if label.get(m))
        db.add(block, [toks], desc, "nvim", ctx=ctx)
    return True


# ── waybar ───────────────────────────────────────────────────────────────────────────────────────────────────────
HINT_RE = re.compile(r"((?:L|M|R|Scroll): [^·\"\\\n$]+?(?: · (?:L|M|R|Scroll): [^·\"\\\n$]+?)*)(?=[\"\\\n]|$)")
BAR_KEY = {"L": "L", "M": "M", "R": "R", "Scroll": "Scroll"}


def bar_rows(db, label, hint, source):
    for item in hint.split(" · "):
        k, _, what = item.partition(": ")
        if k not in BAR_KEY or not what.strip():
            continue
        what = what.strip().strip("'`").replace("{}", "focus the app").rstrip(".")
        db.add("bar", [[[BAR_KEY[k]]]], what, source, ctx=label)


def collect_bar(db):
    labels = {k: v for kind, k, v in read_tsv(HERE / "describe.tsv", 3) if kind == "barmod"}
    seen = set()

    def emit(label, hint, source):
        if (label, hint) in seen:
            return
        seen.add((label, hint))
        bar_rows(db, label, hint, source)

    mods = CFG / "waybar/modules.jsonc"
    if mods.is_file():
        module = ""
        for line in mods.read_text(encoding="utf-8").split("\n"):
            m = re.match(r'^\s{0,2}"([\w/#.-]+)"\s*:\s*\{', line)
            if m:
                module = m.group(1)
            if line.lstrip().startswith("//"):
                continue
            if "tooltip" in line or "hint" in line.lower():
                h = HINT_RE.search(line.replace("\\n", "\n"))
                if h:
                    emit(labels.get(module, module.replace("custom/", "")), h.group(1), "waybar")
    scripts = CFG / "waybar/scripts"
    toggles = scripts / "toggles.sh"
    if toggles.is_file():
        label = ""
        for line in toggles.read_text(encoding="utf-8").split("\n"):
            m = re.search(r'LABEL="([^"]+)"', line)
            if m:
                label = re.sub(r" \(.*\)$", "", m.group(1))
            h = re.search(r'HINT="([^"]+)"', line)
            if h:
                emit(f"Switch: {label}", h.group(1), "waybar")
    for name in ("updates.sh", "health.sh", "ai-usage.sh", "recording.sh", "pinned-watch.py"):
        path = scripts / name
        if path.is_file():
            for hint in dict.fromkeys(h for h in HINT_RE.findall(path.read_text(encoding="utf-8").replace("\\n", "\n"))):
                emit(labels.get(f"script:{name}", name), hint, "waybar")


# ── Telegram, Vimium C ───────────────────────────────────────────────────────────────────────────────────────────
def strip_json_comments(text):
    return "\n".join(line for line in text.split("\n") if not line.lstrip().startswith("//"))


def collect_telegram(db):
    path = REPO / "apps/telegram/shortcuts-custom.json"
    if not path.is_file():
        return
    for item in json.loads(strip_json_comments(path.read_text(encoding="utf-8"))):
        keys, command = item.get("keys", ""), item.get("command")
        if not keys.isascii() or not command:
            continue
        chord = [{"alt": "Alt", "ctrl": "Ctrl", "shift": "Shift", "meta": "Super"}.get(p, p.upper() if len(p) == 1 else p)
                 for p in keys.split("+")]
        db.add("telegram", [[chord]], command.replace("_", " ").capitalize(), "telegram")


def collect_vimium(db):
    path = REPO / "browsers/vimium-c.json"
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    table = {k: v for kind, k, v in read_tsv(HERE / "describe.tsv", 3) if kind == "vimium"}
    keys = []
    for line in data.get("keyMappings", []):
        m = re.match(r"#.*defaults stay \((.*)\)\.", line)
        if m:
            keys = m.group(1).split()
    for k in keys:
        desc = table.get(k, "Vimium C default")
        db.add("vimium", [[[c] for c in k]] if len(k) > 1 else [[[k]]], desc, "vimium")
    notes = []

    def site_of(pattern):  # a ':' URL prefix names a host; a '^' regex is shown as what it matches
        if pattern.startswith("^"):
            return "the generated keymap page (file:// ... /.cache/keymap/)" if "keymap" in pattern else pattern
        return pattern.split("//")[1].split("/")[0]

    off = [site_of(r["pattern"]) for r in data.get("exclusionRules", []) if r.get("passKeys") == ""]
    if off:
        notes.append("Vimium C is switched off on " + ", ".join(off) + ".")
    for r in data.get("exclusionRules", []):
        if r.get("passKeys"):
            notes.append(f"On {site_of(r['pattern'])} it passes the keys {r['passKeys']} to the page.")
    return {"vimium": " ".join(notes)} if notes else {}


def obsidian_chords(lhs):
    """vimrc lhs (`<Space>ff`, `<C-o>`, `gd`, `jj`) -> sequence of chords of key names."""
    out = []
    for tok in re.findall(r"<[^>]+>|.", lhs):
        m = re.fullmatch(r"<C-(.)>", tok)
        if m:
            out.append(["Ctrl", m.group(1)])
        elif tok.lower() == "<space>":
            out.append(["Space"])
        else:
            out.append([tok])
    return out


def collect_obsidian(db):
    path = REPO / "apps/obsidian/obsidian.vimrc"
    if not path.is_file():
        return
    desc = {k: v for kind, k, v in read_tsv(HERE / "describe.tsv", 3) if kind == "obsidian"}
    cmds = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        t = line.split()
        if len(t) == 4 and t[0] == "exmap" and t[2] == "obcommand":
            cmds[t[1]] = t[3]
        elif len(t) >= 3 and t[0] in ("nmap", "imap", "vmap"):
            ex = t[2][1:] if t[2].startswith(":") else ""
            text = desc.get(ex) or desc.get(t[1]) or (f"Obsidian command {cmds[ex]}" if ex in cmds else f"{t[1]} -> {t[2]}")
            ctx = {"nmap": "NORMAL", "imap": "INSERT", "vmap": "VISUAL"}[t[0]]
            db.add("obsidian", [obsidian_chords(t[1])], text, "obsidian", ctx=ctx)


def collect_static(db):
    for cols in read_tsv(HERE / "static.tsv", 5):
        block, keys, desc, ctx, note = cols[:5]
        db.add_text(block, keys, desc, "committed table", ctx=ctx, note=note)


# ── build, cache ─────────────────────────────────────────────────────────────────────────────────────────────────
def source_files():
    files = [HERE / "keymap.py", HERE / "nvim-dump.lua", *sorted(HERE.glob("*.tsv")),
             CFG / "hypr/hyprland.lua", CFG / "hypr/monitors.lua", CFG / "hub/leader", CFG / "hub/leader-groups.tsv",
             CFG / "hub/actions.tsv", *sorted((CFG / "hub/actions.d").glob("*.tsv")),
             CFG / "tmux/tmux.conf", CFG / "tmux/tmux-layout.conf",
             HOME / ".zshrc", CFG / "zsh/vi-mode.zsh", CFG / "zsh/layout-keys.zsh",
             CFG / "waybar/modules.jsonc", *sorted((CFG / "waybar/scripts").glob("*")),
             REPO / "apps/telegram/shortcuts-custom.json", REPO / "browsers/vimium-c.json",
             REPO / "apps/obsidian/obsidian.vimrc"]
    nvim = CFG / "nvim"
    if nvim.exists():
        root = nvim.resolve()
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            files.extend(Path(dirpath) / f for f in filenames if f.endswith((".lua", ".json")))
    return files


def stamp(binds):
    h = hashlib.sha1()
    h.update(str(DB_VERSION).encode())
    for f in source_files():
        try:
            st = f.stat()
            h.update(f"{f}:{st.st_mtime_ns}:{st.st_size}\n".encode())
        except OSError:
            h.update(f"{f}:-\n".encode())
    h.update(json.dumps(binds, sort_keys=True).encode() if binds is not None else b"no-hyprland")
    return h.hexdigest()


def load_db():
    try:
        return json.loads(DB_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def build(binds, old=None, quiet=False):
    db = Db()
    notes = {}
    warn = []
    if binds is not None:
        collect_hyprland(db, binds)
    elif old:
        for r in old["rows"]:
            if r["source"] == "hyprland":
                db.rows.append(dict(r))
        warn.append("Hyprland is not reachable: reused the Hyprland rows of the previous build")
    else:
        warn.append("Hyprland is not reachable and there is no earlier build: no Hyprland rows")
    for name, fn in (("leader", collect_leader), ("tmux", collect_tmux), ("zsh", collect_zsh), ("zsh text", collect_zsh_text),
                     ("nvim", collect_nvim), ("bar", collect_bar), ("telegram", collect_telegram),
                     ("obsidian", collect_obsidian)):
        try:
            ok = fn(db)
        except Exception as exc:  # a broken source must not take the others down
            ok, _ = False, warn.append(f"{name}: {type(exc).__name__}: {exc}")
        if ok is False and old:
            src = {"tmux": "tmux", "zsh": "zsh", "nvim": "nvim"}.get(name)
            if src:
                db.rows.extend(dict(r) for r in old["rows"] if r["source"] == src and r["block"] != "zsh-helpers"
                               and r["block"] != "zsh-aliases")
                warn.append(f"{name}: could not be read, reused the previous rows")
    try:
        notes.update(collect_vimium(db))
    except Exception as exc:
        warn.append(f"vimium: {type(exc).__name__}: {exc}")
    collect_static(db)
    blocks = []
    for cols in read_tsv(HERE / "blocks.tsv", 6):
        bid, group, title, desc = cols[:4]
        rank = cols[5].strip()
        blocks.append({"id": bid, "group": group, "title": title, "desc": desc, "scope": cols[4].strip(),
                       "rank": int(rank) if rank.isdigit() else 5})
    ids = {b["id"] for b in blocks}
    for row in db.rows:
        if row["block"] not in ids:
            warn.append(f"row {row['keys']!r} has the unknown block {row['block']!r}: moved to hypr-other")
            row["block"] = "hypr-other"
    order = {b["id"]: i for i, b in enumerate(blocks)}
    db.rows.sort(key=lambda r: order[r["block"]])  # stable: source order inside a block
    apply_keywords(db.rows, blocks)
    for i, row in enumerate(db.rows):
        row["i"] = i
    counts = {}
    for row in db.rows:
        counts[row["block"]] = counts.get(row["block"], 0) + 1
    for b in blocks:
        b["count"] = counts.get(b["id"], 0)
        if b["id"] in notes:
            b["note"] = notes[b["id"]]
    pins = [c[0] for c in read_tsv(HERE / "pins.tsv", 1)]
    out = {
        "version": DB_VERSION,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "stamp": stamp(binds),
        "hypr_binds": sum(1 for b in (binds or []) if b.get("has_description")) if binds is not None
        else (old or {}).get("hypr_binds", 0),
        "groups": [{"id": g} for g in GROUPS],
        "blocks": blocks,
        "intro": [{"title": t, "text": x} for t, x in read_tsv(HERE / "intro.tsv", 2)],
        "pins": pins,
        "warnings": warn,
        "rows": db.rows,
    }
    return out


def keyword_rules():
    """[(regex source, compiled, words)] of keywords.tsv; a regex that does not compile is kept with None (keymap check reports it)"""
    rules = []
    for cols in read_tsv(HERE / "keywords.tsv", 2):
        try:
            rx = re.compile(cols[0], re.I)
        except re.error:
            rx = None
        rules.append((cols[0], rx, cols[1].split()))
    return rules


def apply_keywords(rows, blocks):
    """row["kw"] = the words of every keywords.tsv rule that matches the DESCRIPTION (deduplicated, rule order). Never the block
    title: a title such as "System, power, bar" would hand "reboot shutdown" to every row of the block (block words are searched
    anyway through the block field). A row reused from the old DB loses its old words first, so a changed rule takes effect."""
    rules = keyword_rules()
    for row in rows:
        row.pop("kw", None)
        text = row["desc"]
        words = []
        for _src, rx, ws in rules:
            if rx is not None and rx.search(text):
                words += [w for w in ws if w not in words]
        if words:
            row["kw"] = " ".join(words)


def write_db(data):
    CACHE.mkdir(parents=True, exist_ok=True)
    tmp = DB_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    tmp.replace(DB_FILE)


def fast_db():
    """The cached database without any staleness check (rows / header / preview / cycle run on every key press)."""
    data = load_db()
    if data and data.get("version") == DB_VERSION:
        return data
    return ensure_db()


def ensure_db(force=False):
    if os.environ.get("KEYMAP_DB"):          # test fixture: only ever loaded, never rebuilt
        data = load_db()
        if data:
            return data
    binds = hypr_binds()
    old = load_db()
    if not force and old and old.get("version") == DB_VERSION and binds is not None and old.get("stamp") == stamp(binds):
        return old
    if not force and binds is None and old and old.get("version") == DB_VERSION:
        return old  # no Hyprland (TTY, ssh): the cache is the best answer
    data = build(binds, old)
    write_db(data)
    return data


# ── markdown ─────────────────────────────────────────────────────────────────────────────────────────────────────
def md_cell(text):
    return text.replace("|", "\\|")


def md_keys(row):
    if row.get("raw"):
        return md_cell(row["keys"])
    return " / ".join(f"`{md_cell(' '.join('+'.join(c) for c in seq))}`" for seq in row["alts"])


def render_md(data):
    out = ["# Keymap", "",
           "Generated by `keymap md` (`.config/keymap/keymap.py`) from the live sources, never edit it by hand: run `keymap md --write`",
           "after changing binds (`doctor.sh` fails when this file is stale). `SUPER` is the main modifier.",
           "`SUPER+/` searches every shortcut below (fzf-menu), `SUPER+SHIFT+/` opens the same data as a reading page.", ""]
    out += ["| Group | Block | Shortcuts |", "|---|---|---|"]
    for g in data["groups"]:
        for b in data["blocks"]:
            if b["group"] == g["id"] and b["count"]:
                out.append(f"| {g['id']} | [{b['title']}](#{anchor(b['title'])}) | {b['count']} |")
    out.append("")
    for card in data["intro"]:
        out.append(f"- **{card['title']}**: {card['text']}")
    out.append("")
    by_block = {}
    for row in data["rows"]:
        by_block.setdefault(row["block"], []).append(row)
    for g in data["groups"]:
        out += [f"## {g['id']}", ""]
        for b in data["blocks"]:
            if b["group"] != g["id"] or not by_block.get(b["id"]):
                continue
            out += [f"### {b['title']}", "", b["desc"] + (" " + b["note"] if b.get("note") else ""), ""]
            rows = by_block[b["id"]]
            has_ctx = any(r.get("ctx") for r in rows)
            if has_ctx:
                out += ["| Keys | Action | Context |", "|---|---|---|"]
            else:
                out += ["| Keys | Action |", "|---|---|"]
            for r in rows:
                desc = md_cell(r["desc"]) + (f" ({md_cell(r['note'])})" if r.get("note") and r["source"] != "hyprland" else "")
                if has_ctx:
                    out.append(f"| {md_keys(r)} | {desc} | {md_cell(r.get('ctx', ''))} |")
                else:
                    out.append(f"| {md_keys(r)} | {desc} |")
            out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def anchor(title):
    s = re.sub(r"[^\w\s-]", "", title.lower())
    return re.sub(r"\s", "-", s)


# ── checks and stats ─────────────────────────────────────────────────────────────────────────────────────────────
def problems(data):
    errs = []
    texts = {(r["keys"]).lower() for r in data["rows"]}
    for pin in data["pins"]:
        if pin.lower() not in texts:
            errs.append(f"pinned key {pin!r} matches no row (pins.tsv)")
    for b in data["blocks"]:
        if not b["count"] and b["id"] not in ("hypr-other",):
            errs.append(f"block {b['id']} is empty (its source returned nothing)")
    texts_kw = [r["desc"] for r in data["rows"]]
    for src, rx, words in keyword_rules():
        if rx is None:
            errs.append(f"keywords.tsv: the regex {src!r} does not compile")
            continue
        hits = sum(1 for t in texts_kw if rx.search(t))
        if not hits:
            errs.append(f"keywords.tsv: the regex {src!r} matches no row (stale rule)")
        elif hits > KEYWORD_MAX_ROWS:
            errs.append(f"keywords.tsv: the regex {src!r} matches {hits} rows (more than {KEYWORD_MAX_ROWS}: too broad, anchor it)")
        for b in data["blocks"]:
            rows_b = [r["desc"] for r in data["rows"] if r["block"] == b["id"]]
            # a block that is ABOUT the rule's topic (title or id holds one of its words, "Dictation" and the rule "dictation") is
            # uniform on purpose: the rule is correct there, not a broadcast
            about = any(w.lower() in f"{b['title']} {b['id']}".lower() for w in words)
            if len(rows_b) >= 8 and all(rx.search(t) for t in rows_b) and not about:
                errs.append(f"keywords.tsv: the regex {src!r} matches every row of the block {b['id']} (a broadcast, anchor it)")
    hypr = sum(r.get("n", 1) for r in data["rows"] if r["source"] == "hyprland")
    if data.get("hypr_binds") and hypr != data["hypr_binds"]:
        errs.append(f"Hyprland rows cover {hypr} binds, the live table has {data['hypr_binds']} described ones")
    return errs


def cmd_stats(data):
    for g in data["groups"]:
        print(g["id"])
        for b in data["blocks"]:
            if b["group"] == g["id"]:
                print(f"  {b['count']:4d}  {b['id']:14s} {b['title']}")
    total = len(data["rows"])
    hypr = sum(r.get("n", 1) for r in data["rows"] if r["source"] == "hyprland")
    print(f"total {total} rows; Hyprland rows cover {hypr} binds (mouse extras not counted), live described binds {data.get('hypr_binds')}")
    for w in data.get("warnings", []):
        print("warning:", w)


# ── menu (SUPER+/) ───────────────────────────────────────────────────────────────────────────────────────────────
def menu_state():
    RUN.mkdir(parents=True, exist_ok=True, mode=0o700)
    return RUN / "block"


def current_block():
    try:
        return menu_state().read_text().strip()
    except OSError:
        return ""


def menu_blocks(data):
    return [b for b in data["blocks"] if b["count"]]


MENU_HIDDEN = {"audit"}     # blocks left out of the "all" view of the menu (Tab reaches them; the page shows everything)
KEYS_W = 24                 # width of the keys column in the menu, in terminal cells
START_SCOPE = "start"


def cell_width(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def fit_cells(text, width):
    """text padded with spaces to `width` cells; longer text is cut to width-1 cells plus an ellipsis"""
    if cell_width(text) <= width:
        return text + " " * (width - cell_width(text))
    out, used = "", 0
    for c in text:
        w = cell_width(c)
        if used + w > width - 1:
            break
        out, used = out + c, used + w
    return out + "…" + " " * (width - used - 1)


def key_parts(row):
    """whole keys of a row, lower case: the elements of its chords, their `..` ranges and, for plain text, its words"""
    parts = set()
    for seq in row.get("alts") or []:
        for chord in seq:
            for k in chord:
                k = k.lower()
                parts.add(k)
                parts.update(p for p in k.split("..") if p)
    if row.get("raw"):
        parts.update(w for w in re.split(r"[\s+/]+", row["keys"].lower()) if w)
    return parts


def row_fields(row, blocks):
    b = blocks[row["block"]]
    return {"keys": row["keys"].lower(), "parts": key_parts(row), "desc": row["desc"].lower(),
            "blk": f"{b['title']} {b.get('scope', '')}".lower(), "kw": row.get("kw", "").lower()}


def token_weight(tok, f):
    """0 = no match; 5 whole key, 4 key substring, 3 description word start, 2 description substring or keyword, 1 block / scope"""
    short = len(tok) <= 2
    word = re.compile(r"\b" + re.escape(tok) + (r"\b" if short else ""))
    best = 0
    if tok in f["parts"]:
        best = 5
    elif not short and tok in f["keys"]:
        best = 4
    if best < 3 and word.search(f["desc"]):
        best = 3
    if best < 2 and (tok in f["desc"] if not short else False):
        best = 2
    if best < 2 and (word.search(f["kw"]) if short else tok in f["kw"]):
        best = 2
    if best < 1 and (word.search(f["blk"]) if short else tok in f["blk"]):
        best = 1
    return best


def search(data, query, block=""):
    """rows to show: [(row, is_pin)]. Empty query in the all view: the pins first, then every row by (block rank, index) without
    MENU_HIDDEN blocks; a selected block shows its rows in source order; with a query: all words must match, best first."""
    blocks = {b["id"]: b for b in data["blocks"]}
    toks = query.lower().split()
    rows = [r for r in data["rows"] if (r["block"] == block if block else r["block"] not in MENU_HIDDEN)]
    if not toks:
        if block:
            return [(r, False) for r in rows]
        pinned, seen = [], set()
        for pin in data.get("pins", []):
            hit = next((r for r in rows if r["keys"].lower() == pin.lower()), None)
            if hit is not None and hit["i"] not in seen:
                seen.add(hit["i"])
                pinned.append((hit, True))
        rest = sorted((r for r in rows if r["i"] not in seen), key=lambda r: (blocks[r["block"]].get("rank", 5), r["i"]))
        return pinned + [(r, False) for r in rest]
    scored = []
    for r in rows:
        f = row_fields(r, blocks)
        ws = [token_weight(t, f) for t in toks]
        if all(ws):
            scored.append((-sum(ws), blocks[r["block"]].get("rank", 5), r["i"], r))
    scored.sort(key=lambda x: x[:3])
    return [(x[3], False) for x in scored]


def highlight(desc, toks):
    """desc with the matched words bold + underlined (same rule as the match: short words only as whole words)"""
    spans = []
    low = desc.lower()
    for t in toks:
        rx = re.compile(r"\b" + re.escape(t) + r"\b") if len(t) <= 2 else re.compile(re.escape(t))
        spans += [m.span() for m in rx.finditer(low)]
    if not spans:
        return desc
    spans.sort()
    merged = [list(spans[0])]
    for a, b in spans[1:]:
        if a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    out, pos = "", 0
    for a, b in merged:
        out += desc[pos:a] + "\033[1;4m" + desc[a:b] + "\033[22;24m"
        pos = b
    return out + desc[pos:]


def row_line(r, blocks, toks, pin):
    """index, keys (green, fixed width), description (+ dim context), scope tag: tab separated, --tabstop=1 shows a tab as one space"""
    ctx = f"  \033[90m({r['ctx']})\033[0m" if r.get("ctx") else ""
    scope = START_SCOPE if pin else blocks[r["block"]].get("scope", "")
    return f"{r['i']}\t\033[32m{fit_cells(r['keys'], KEYS_W)}\033[0m\t{highlight(r['desc'], toks)}{ctx}\t \033[90m{scope}\033[0m"


def cmd_rows(data):
    blocks = {b["id"]: b for b in data["blocks"]}
    query = os.environ.get("FZF_QUERY", "")
    toks = query.lower().split()
    lines = [row_line(r, blocks, toks, pin) for r, pin in search(data, query, current_block())]
    sys.stdout.write("\n".join(lines) + ("\n" if lines else ""))


def cmd_header(data):
    only = current_block()
    if only:
        b = next((b for b in data["blocks"] if b["id"] == only), None)
        print(f"Block: {b['title']} ({b['count']})" if b else "All shortcuts")
    else:
        n = sum(1 for r in data["rows"] if r["block"] not in MENU_HIDDEN)
        print(f"All shortcuts · {n} · Audit: Tab to it")


def cmd_cycle(data, how):
    ids = [""] + [b["id"] for b in menu_blocks(data)]
    cur = current_block()
    i = ids.index(cur) if cur in ids else 0
    if how == "next":
        i = (i + 1) % len(ids)
    elif how == "prev":
        i = (i - 1) % len(ids)
    else:
        i = 0
    menu_state().write_text(ids[i])
    me = shlex.quote(str(Path(sys.argv[0]).resolve()))
    print(f"reload-sync({me} rows)+first+change-header:{header_text(data)}")


def header_text(data):
    import io
    from contextlib import redirect_stdout
    buf = io.StringIO()
    with redirect_stdout(buf):
        cmd_header(data)
    return buf.getvalue().strip()


def cmd_preview(data, idx):
    try:
        row = data["rows"][int(idx)]
    except (ValueError, IndexError):
        return
    b = next(b for b in data["blocks"] if b["id"] == row["block"])
    print(f"Keys    {row['keys']}")
    print(f"What    {row['desc']}")
    print(f"Where   {b.get('scope', '')}" + (f" · {row['ctx']}" if row.get("ctx") else ""))
    print(f"Block   {b['title']}")
    if row.get("note"):
        note = row["note"]
        print(f"Note    {note if len(note) <= 300 else note[:299] + '…'}")
    if row.get("run"):
        print("Run     Alt+R replays it")


def notify(text, title="Shortcuts"):
    subprocess.run(["notify-send", "-a", "keymap", "-u", "low", "-t", "2500", title, text], check=False)


def cmd_menu(data):
    if not shutil.which("fzf-menu"):
        print("keymap: fzf-menu is not installed", file=sys.stderr)
        return 1
    me = str(Path(sys.argv[0]).resolve())
    qme = shlex.quote(me)
    menu_state().write_text("")
    req = RUN / "run-request"
    req.unlink(missing_ok=True)
    env = dict(os.environ)
    env.pop("FZF_QUERY", None)
    env["FZF_MENU_NORMAL_BINDS"] = "\n".join([
        f"l:transform({me} cycle next)", f"h:transform({me} cycle prev)", f"0:transform({me} cycle reset)",
        f"r:execute-silent(printf %s {{1}} > {req})+accept",
        f"y:accept",
    ])
    # Not used on purpose: --no-hscroll (it disables --freeze-right: the scope tag would vanish on long lines), --track (with
    # reload-sync it drops typed characters), --exact / --nth / --tiebreak / --scheme (the search is search() above: fzf cannot
    # look into the hidden keyword field), --multi.
    cmd = ["fzf-menu", "-p", "keys", "--size", "large",
           "--ansi", "--disabled", "--delimiter=\t", "--with-nth=2..", "--accept-nth=1", "--tabstop=1",
           "--freeze-right=1", "--ellipsis=…", "--no-sort",
           "--header", header_text(data),
           "--footer=Enter copy · Alt+R run · Tab / Shift+Tab block · 0 all",   # short: the footer is only as wide as the list
           "--bind", f"change:reload-sync({qme} rows)+first",
           "--bind", f"tab:transform({qme} cycle next)", "--bind", f"btab:transform({qme} cycle prev)",
           "--bind", f"alt-r:execute-silent(printf %s {{1}} > {req})+accept",
           "--preview", f"{qme} preview {{1}}", "--preview-window", "right,38%,wrap,border-left"]
    blocks = {b["id"]: b for b in data["blocks"]}
    rows = "\n".join(row_line(r, blocks, [], pin) for r, pin in search(data, "")) + "\n"
    res = subprocess.run(cmd, input=rows, stdout=subprocess.PIPE, text=True, env=env)
    choice = res.stdout.strip()
    if res.returncode != 0 or not choice:
        return 0
    row = data["rows"][int(choice)]
    if req.exists():
        req.unlink(missing_ok=True)
        time.sleep(0.12)
        return run_row(row)
    copy(row["keys"])
    notify(f"{row['keys']} copied: {row['desc']}")
    return 0


def copy(text):
    if shutil.which("wl-copy"):
        subprocess.run(["wl-copy"], input=text, text=True, check=False)


def run_row(row):
    if not row.get("run"):
        notify("This shortcut cannot be run from here (only global Hyprland binds can).")
        return 0
    env = hypr_env()
    if env is None:
        notify("Hyprland is not reachable.")
        return 1
    label = row["run"].replace("]]", "] ]")
    subprocess.run(["hyprctl", "eval", f"df_bind_run([==[{label}]==])"], env=env, capture_output=True, check=False)
    return 0


# ── reading page ─────────────────────────────────────────────────────────────────────────────────────────────────
def theme_tokens():
    for base in (STATE / "theme/current", REPO / "themes/generated/black"):
        try:
            return json.loads((base / "tokens.json").read_text(encoding="utf-8")), (base / "tokens.css").read_text(encoding="utf-8")
        except (OSError, ValueError):
            continue
    return {"variant": "black", "tokens": {}}, ""


def page_stamp(data):
    tokens, _css = theme_tokens()
    h = hashlib.sha1()
    h.update(data["stamp"].encode())
    h.update(tokens.get("variant", "").encode())
    h.update(str((HERE / "page.html").stat().st_mtime_ns).encode())
    h.update(str(Path(__file__).stat().st_mtime_ns).encode())
    return h.hexdigest()


def render_page(data):
    tokens, css = theme_tokens()
    tpl = (HERE / "page.html").read_text(encoding="utf-8")
    payload = {"blocks": [b for b in data["blocks"] if b["count"]], "groups": [g["id"] for g in data["groups"]],
               "intro": data["intro"], "pins": data["pins"], "variant": tokens.get("variant", "black"),
               "rows": [{k: r[k] for k in ("i", "block", "keys", "alts", "desc", "source", "ctx", "note", "raw", "kw") if k in r}
                        for r in data["rows"]], "generated": data["generated"]}
    blob = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
    return (tpl.replace("/*TOKENS*/", css).replace("/*VARIANT*/", html.escape(tokens.get("variant", "black")))
            .replace("/*STAMP*/", page_stamp(data)).replace("/*DATA*/", blob))


def ensure_page(data):
    want = page_stamp(data)
    try:
        if f'content="{want}"' in PAGE_FILE.read_text(encoding="utf-8")[:2000]:
            return PAGE_FILE
    except OSError:
        pass
    CACHE.mkdir(parents=True, exist_ok=True)
    tmp = PAGE_FILE.with_suffix(".tmp")
    tmp.write_text(render_page(data), encoding="utf-8")
    tmp.replace(PAGE_FILE)
    return PAGE_FILE


def hypr_clients(env):
    res = run(["hyprctl", "-j", "clients"], timeout=5, env=env)
    try:
        return json.loads(res.stdout) if res is not None and res.returncode == 0 else []
    except ValueError:
        return []


def float_new_window(env, before):
    """The page is a new Zen window (a window rule cannot tell it from other Zen windows: its title arrives after the
    window is mapped), so float, size and center that window once it shows up."""
    deadline = time.time() + 8
    while time.time() < deadline:
        for c in hypr_clients(env):
            if c["class"] == "app.zen_browser.zen" and c["address"] not in before and c.get("mapped", True):
                addr = f"address:{c['address']}"
                for step in (["setfloating", addr], ["resizewindowpixel", f"exact 80% 85%,{addr}"],
                             ["focuswindow", addr], ["centerwindow"]):
                    subprocess.run(["hyprd", *step], env=env, capture_output=True, check=False)
                return
        time.sleep(0.15)


def cmd_page(data, args):
    path = ensure_page(data)
    if "--print" in args:
        print(path)
        return 0
    url = f"file://{path}"
    env = hypr_env() or dict(os.environ)
    zen = shutil.which("flatpak") and subprocess.run(["flatpak", "info", "app.zen_browser.zen"], capture_output=True).returncode == 0
    if zen:
        before = {c["address"] for c in hypr_clients(env)}
        subprocess.Popen(["flatpak", "run", "app.zen_browser.zen", "--new-window", url], env=env, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        float_new_window(env, before)
    else:
        subprocess.Popen(["xdg-open", url], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    return 0


# ── main ─────────────────────────────────────────────────────────────────────────────────────────────────────────
def main(argv):
    cmd = argv[0] if argv else "menu"
    args = argv[1:]
    os.environ.setdefault("PYTHONPYCACHEPREFIX", "/tmp/pycache")
    if cmd in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    if cmd == "gen":
        data = ensure_db(force=True)
        print(f"keymap: {len(data['rows'])} shortcuts in {len([b for b in data['blocks'] if b['count']])} blocks -> {DB_FILE}")
        for w in data["warnings"]:
            print("keymap: warning:", w, file=sys.stderr)
        return 0
    data = fast_db() if cmd in ("rows", "header", "preview", "cycle", "run") else ensure_db()
    if cmd == "json":
        json.dump(data, sys.stdout, ensure_ascii=False, indent=1)
        print()
    elif cmd == "md":
        text = render_md(data)
        if "--write" in args:
            DOC_FILE.write_text(text, encoding="utf-8")
            print(f"keymap: wrote {DOC_FILE}")
        else:
            sys.stdout.write(text)
    elif cmd == "check":
        errs = problems(data)
        try:
            same = DOC_FILE.read_text(encoding="utf-8") == render_md(data)
        except OSError:
            same = False
        if not same:
            errs.append("docs/keymap.md is stale: run `keymap md --write`")
        for e in errs:
            print(f"keymap: {e}", file=sys.stderr)
        if not errs:
            print(f"keymap: {len(data['rows'])} shortcuts, docs/keymap.md is current")
        return 1 if errs else 0
    elif cmd == "stats":
        cmd_stats(data)
    elif cmd == "menu":
        return cmd_menu(data)
    elif cmd == "rows":
        cmd_rows(data)
    elif cmd == "header":
        cmd_header(data)
    elif cmd == "cycle":
        cmd_cycle(data, args[0] if args else "next")
    elif cmd == "preview":
        cmd_preview(data, args[0] if args else "0")
    elif cmd == "run":
        return run_row(data["rows"][int(args[0])])
    elif cmd == "page":
        return cmd_page(data, args)
    else:
        print(f"keymap: unknown command {cmd!r}; see keymap --help", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
