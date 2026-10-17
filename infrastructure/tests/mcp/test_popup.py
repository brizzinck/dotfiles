#!/usr/bin/env python3
"""Tests of infrastructure/mcp/confirm/popup.py: the key gate and the text safety as pure functions, and the real curses screen
in a private tmux (it reads the code from the screen like the owner would and presses it). Prints `ok NAME` / `FAIL NAME`.
Usage: test_popup.py REPO"""
import importlib.util
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

repo = sys.argv[1]
spec = importlib.util.spec_from_file_location("popup", os.path.join(repo, "infrastructure/mcp/confirm/popup.py"))
popup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(popup)
KEYMAP = os.path.join(repo, ".config/layout/keymap.tsv")
km = popup.load_keymap(KEYMAP)
results = []


def check(name, cond):
    results.append(bool(cond))
    print(("ok " if cond else "FAIL ") + name)


# --- keymap, alphabet, code ------------------------------------------------------------------------------------------------
check("keymap: all 26 letter keys, each with us, ua and ru characters", len(km) == 26 and all(len(v) >= 2 for v in km.values()) and "п" in km["KeyG"] and "е" in km["KeyT"])
idx, ambiguous = popup.char_index(km)
check("keymap: every letter character of every layout belongs to exactly one physical key (no ambiguity today)", not ambiguous and len(idx) > 100)
alpha = popup.alphabet(km)
check("alphabet: no scroll key and no q", not set(alpha) & set(popup.RESERVED))
check("alphabet: at least 20 keys, so a 2-key code is 1 in 380 or better", len(alpha) >= 20 and len(alpha) * (len(alpha) - 1) >= 380)
fake_ambiguous = {"KeyA": {"a", "A", "я"}, "KeyB": {"b", "B", "я"}, "KeyC": {"c", "C"}, "KeyD": {"d"}}
check("alphabet: a key with a character that another key also produces is never used", popup.alphabet(fake_ambiguous) == ["KeyC"])
seen = {tuple(popup.make_code(km)) for _ in range(4000)}
check("code: two DISTINCT keys, drawn from the whole alphabet (hundreds of different codes)", all(a != b and a in alpha and b in alpha for a, b in seen) and len(seen) > 300)
check("code: drawn from the system RNG (not a seeded generator)", "SystemRandom" in open(popup.__file__).read() and "random.seed" not in open(popup.__file__).read())

# --- the gate --------------------------------------------------------------------------------------------------------------
code = ["KeyG", "KeyT"]
t0 = 100.0
g = popup.Gate(code, km, t0)
check("gate: the right two keys confirm", g.feed("g", t0 + 1) == ("progress", 0) and g.feed("t", t0 + 1.1) == ("confirmed", 0))
g = popup.Gate(code, km, t0)
check("gate: the ua / ru twins of the keys confirm too (physical key)", g.feed("п", t0 + 1)[0] == "progress" and g.feed("е", t0 + 1.1)[0] == "confirmed")
g = popup.Gate(code, km, t0)
check("gate: capital letters count as the same key", g.feed("G", t0 + 1)[0] == "progress" and g.feed("T", t0 + 1.1)[0] == "confirmed")
g = popup.Gate(code, km, t0)
check("gate: a wrong first key cancels at once (one shot)", g.feed("x", t0 + 1)[0] == "cancelled")
g = popup.Gate(code, km, t0)
check("gate: a wrong second key cancels", g.feed("g", t0 + 1)[0] == "progress" and g.feed("y", t0 + 1.1)[0] == "cancelled")
g = popup.Gate(code, km, t0)
check("gate: the second key before the first is wrong", g.feed("t", t0 + 1)[0] == "cancelled")
g = popup.Gate(code, km, t0)
check("gate: keys in the first 0.7 s are ignored (neither progress nor cancel)", g.feed("g", t0 + 0.1) == ("ignored", 0) and g.feed("t", t0 + 0.69) == ("ignored", 0) and g.pos == 0)
check("gate: the first key right after the guard counts", g.feed("g", t0 + 0.71)[0] == "progress")
g = popup.Gate(code, km, t0)
check("gate: Esc, q, Enter, space, digits and Ctrl keys cancel", all(popup.Gate(code, km, t0).feed(k, t0 + 1)[0] == "cancelled" for k in ("\x1b", "q", "\n", " ", "5", "\x03", "\x04", "\t")))
check("gate: unknown function keys cancel", popup.Gate(code, km, t0).feed(999999, t0 + 1)[0] == "cancelled")
g = popup.Gate(code, km, t0)
ev = [g.feed(k, t0 + 1)[0] for k in ("j", "k", "d", "u", "о", "л")]
check("gate: the scroll keys j k d u (and their twins) are neutral, they scroll and do not cancel", ev == ["scroll"] * 6 and g.pos == 0)
check("gate: scroll keys between the two code keys do not break the sequence", [g.feed(k, t0 + 2)[0] for k in ("g", "j", "t")] == ["progress", "scroll", "confirmed"])
import curses
g = popup.Gate(code, km, t0)
check("gate: arrows and page keys scroll", [g.feed(k, t0 + 1)[0] for k in (curses.KEY_DOWN, curses.KEY_UP, curses.KEY_NPAGE, curses.KEY_PPAGE)] == ["scroll"] * 4)
check("gate: a resize is ignored, a mouse event too", g.feed(curses.KEY_RESIZE, t0 + 1)[0] == "ignored" and g.feed(curses.KEY_MOUSE, t0 + 1)[0] == "ignored")
hidden = popup.Gate(code, km, t0, code_visible=lambda: False)
check("gate: before the code is on screen (text not scrolled to the end) the code keys do not confirm, they cancel", hidden.feed("g", t0 + 1)[0] == "cancelled")

# --- text safety -----------------------------------------------------------------------------------------------------------
v = popup.visible("a​b‮c\u0007d\x1b[31me⁦f﻿­g\th\n")
check("visible: zero-width, bidi, bell, ESC, BOM and soft hyphen become <U+XXXX>, tab 4 spaces, newline kept",
      v == "a<U+200B>b<U+202E>c<U+0007>d<U+001B>[31me<U+2066>f<U+FEFF><U+00AD>g    h\n")
check("visible: Cyrillic, emoji and CJK pass through", popup.visible("Привіт 👍 日本") == "Привіт 👍 日本")
long = "word " * 500 + "\n\nlast line ж"
lines = popup.wrap(long, 40)
check("wrap: nothing is cut or dropped, no line exceeds the width", "".join(lines).replace(" ", "") == popup.visible(long).replace("\n", "").replace(" ", "") and all(sum(popup.width(c) for c in l) <= 40 for l in lines))
cjk = popup.wrap("日本語" * 30, 20)
check("wrap: double-width characters wrap by display width", all(sum(popup.width(c) for c in l) <= 20 for l in cjk) and "".join(cjk) == "日本語" * 30)
check("one_line: a long reply preview is shortened with an ellipsis, newlines made visible", popup.one_line("a\nb" + "x" * 200, 20).endswith("…") and "⏎" in popup.one_line("a\nb", 20))

# --- the real screen in a private tmux ------------------------------------------------------------------------------------
tmux = shutil.which("tmux")
if not tmux:
    print("SKIP the curses screen (no tmux)")
    sys.exit(0 if all(results) else 1)
TMP = tempfile.mkdtemp(prefix="tgpopup-test.")
SOCK = f"{TMP}/tmux.sock"


def t(*a):
    return subprocess.run([tmux, "-S", SOCK, "-f", "/dev/null", *a], capture_output=True, text=True).stdout


def start(req, name):
    res = f"{TMP}/{name}.res"
    req = {"kind": "send", "title": "Send this Telegram message?", "account": "main", "name": "Work chat", "username": "work", "chat_id": -1001111,
           "chat_kind": "Supergroup", "reply_preview": "", "text": "hello", "nonce": name, "timeout": 20, "result_file": res, **req}
    rf = f"{TMP}/{name}.req"
    json.dump(req, open(rf, "w"))
    t("kill-server")
    t("new-session", "-d", "-x", "100", "-y", "30",
      f"TERM=xterm-256color TGCONFIRM_KEYMAP={KEYMAP} {sys.executable} {popup.__file__} --req {rf}")
    return res


def screen():
    return t("capture-pane", "-p")


def code_from_screen(timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        s = screen()
        for line in s.splitlines():
            if line.strip().startswith("Press ") and "to confirm" in line:
                parts = line.split()
                return parts[1], parts[3], s
        time.sleep(0.1)
    return None, None, screen()


def result(res, wait=3):
    end = time.time() + wait
    while time.time() < end:
        if os.path.exists(res):
            return json.load(open(res))
        time.sleep(0.1)
    return None


def key(k):
    t("send-keys", "-l", k)


res = start({"text": "Hello\nthis has a zero width​ char"}, "a")
k1, k2, scr = code_from_screen()
check("screen: shows the account, recipient, @username, chat id and the full text", k1 and "main" in scr and "Work chat" in scr and "@work" in scr and "-1001111" in scr and "<U+200B>" in scr and "Hello" in scr)
time.sleep(0.9)
key(k1)
time.sleep(0.2)
key(k2)
r = result(res)
check("screen: the displayed code pressed after the guard time confirms", r == {"nonce": "a", "result": "confirmed"})

res = start({}, "b")
k1, k2, scr = code_from_screen()
twin = {"G": "п", "T": "е", "V": "м", "O": "щ"}
ua = {kk: next((c for c in sorted(km["Key" + kk]) if c.islower() and not c.isascii()), kk.lower()) for kk in (k1, k2)}
time.sleep(0.9)
key(ua[k1])
time.sleep(0.2)
key(ua[k2])
r = result(res)
check("screen: the Cyrillic twins of the displayed keys confirm (ua/ru layout active)", r == {"nonce": "b", "result": "confirmed"})

res = start({}, "c")
k1, k2, scr = code_from_screen()
time.sleep(0.9)
wrong = next(c for c in "abcefhilmnoprsvwxyz" if c.upper() not in (k1, k2))
key(wrong)
r = result(res)
check("screen: a wrong key cancels immediately", r == {"nonce": "c", "result": "cancelled"})

res = start({}, "d")
k1, k2, scr = code_from_screen()
time.sleep(0.9)
key(k1)
time.sleep(0.2)
wrong = next(c for c in "abcefhilmnoprsvwxyz" if c.upper() not in (k1, k2))
key(wrong)
check("screen: the first key right, the second wrong cancels", result(res) == {"nonce": "d", "result": "cancelled"})

res = start({}, "e")
code_from_screen()
time.sleep(0.9)
t("send-keys", "Escape")
check("screen: Esc cancels", result(res) == {"nonce": "e", "result": "cancelled"})

res = start({}, "f")
k1, k2, scr = code_from_screen()
key(k1)           # inside the 0.7 s guard (the first frame was drawn a moment ago): ignored
key(k2)
time.sleep(0.4)
alive = t("list-panes", "-F", "#{pane_dead}").strip() == "0"
check("screen: the correct code typed inside the first 0.7 s is ignored (the popup stays open)", alive and not os.path.exists(res))
time.sleep(0.8)
key(k1)
time.sleep(0.2)
key(k2)
check("screen: the same code after the guard confirms", result(res) == {"nonce": "f", "result": "confirmed"})

res = start({"timeout": 2}, "g")
check("screen: no key for the whole timeout ends as 'timeout'", result(res, 5) == {"nonce": "g", "result": "timeout"})

body = "\n".join(f"line {i} of a long message" for i in range(80)) + "\nTAIL-LINE-HIDDEN-AT-FIRST"
res = start({"text": body}, "h")
time.sleep(1.0)
scr = screen()
check("screen: a long text is scrollable, the code is NOT shown until the end has been on screen", "Press " not in scr and "Scroll to the end" in scr and "TAIL-LINE" not in scr and "▼ more" in scr)
for _ in range(20):
    key("d")
    time.sleep(0.05)
k1, k2, scr = code_from_screen(3)
check("screen: after scrolling to the end the last line and the code are shown, no cancel happened", k1 and "TAIL-LINE-HIDDEN-AT-FIRST" in scr and not os.path.exists(res))
key(k1)
time.sleep(0.2)
key(k2)
check("screen: and the code then confirms", result(res) == {"nonce": "h", "result": "confirmed"})

res = start({"text": body}, "i")
time.sleep(1.0)
key("g")
check("screen: a code key pressed while the code is still hidden cancels", result(res) == {"nonce": "i", "result": "cancelled"})

res = start({"kind": "enable", "title": "Allow AI agents to send Telegram messages?", "text": "For 60 minutes. Every single message will still ask you again.", "name": None}, "j")
k1, k2, scr = code_from_screen()
check("screen: the enable popup shows its question and also needs the code, no recipient block", k1 and "Allow AI agents" in scr and "For 60 minutes" in scr and "To " not in scr)
t("kill-server")
shutil.rmtree(TMP, ignore_errors=True)
sys.exit(0 if all(results) else 1)
