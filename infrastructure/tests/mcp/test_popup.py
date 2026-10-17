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
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: the right two keys confirm", g.feed("g", t0 + 1) == ("progress", 0) and g.feed("t", t0 + 1.1) == ("confirmed", 0))
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: the ua / ru twins of the keys confirm too (physical key)", g.feed("п", t0 + 1)[0] == "progress" and g.feed("е", t0 + 1.1)[0] == "confirmed")
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: capital letters count as the same key", g.feed("G", t0 + 1)[0] == "progress" and g.feed("T", t0 + 1.1)[0] == "confirmed")
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: a wrong first key cancels at once (one shot)", g.feed("x", t0 + 1)[0] == "cancelled")
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: a wrong second key cancels", g.feed("g", t0 + 1)[0] == "progress" and g.feed("y", t0 + 1.1)[0] == "cancelled")
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: the second key before the first is wrong", g.feed("t", t0 + 1)[0] == "cancelled")
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: keys in the first 0.7 s are ignored (neither progress nor cancel)", g.feed("g", t0 + 0.1) == ("ignored", 0) and g.pos == 0)
check("gate: ... and each such key restarts the guard (0.7 s from the LAST early key)", g.feed("g", t0 + 0.75) == ("ignored", 0) and g.feed("g", t0 + 1.4) == ("ignored", 0) and g.pos == 0)
check("gate: the first key after a quiet 0.7 s counts", g.feed("g", t0 + 2.2)[0] == "progress")
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: Esc, q, Enter, space, digits and Ctrl keys cancel", all(popup.Gate(code, km, t0, focus_wait=0).feed(k, t0 + 1)[0] == "cancelled" for k in ("\x1b", "q", "\n", " ", "5", "\x03", "\x04", "\t")))
check("gate: unknown function keys cancel", popup.Gate(code, km, t0, focus_wait=0).feed(999999, t0 + 1)[0] == "cancelled")
g = popup.Gate(code, km, t0, focus_wait=0)
ev = [g.feed(k, t0 + 1)[0] for k in ("j", "k", "d", "u", "о", "л")]
check("gate: the scroll keys j k d u (and their twins) are neutral, they scroll and do not cancel", ev == ["scroll"] * 6 and g.pos == 0)
check("gate: scroll keys between the two code keys do not break the sequence", [g.feed(k, t0 + 2)[0] for k in ("g", "j", "t")] == ["progress", "scroll", "confirmed"])
import curses
g = popup.Gate(code, km, t0, focus_wait=0)
check("gate: arrows and page keys scroll", [g.feed(k, t0 + 1)[0] for k in (curses.KEY_DOWN, curses.KEY_UP, curses.KEY_NPAGE, curses.KEY_PPAGE)] == ["scroll"] * 4)
check("gate: a mouse event is ignored, a resize is reported", g.feed(curses.KEY_MOUSE, t0 + 1)[0] == "ignored" and g.feed(curses.KEY_RESIZE, t0 + 1)[0] == "resize")
g = popup.Gate(code, km, t0, focus_wait=0)
g.feed(curses.KEY_RESIZE, t0 + 1)
check("gate: a resize restarts the guard (a code key right after it is ignored)", g.feed("g", t0 + 1.3) == ("ignored", 0))
hidden = popup.Gate(code, km, t0, focus_wait=0, code_visible=lambda: False)
check("gate: before the code is on screen (text not scrolled to the end) the code keys do not confirm, they cancel", hidden.feed("g", t0 + 1)[0] == "cancelled")


# --- focus: the guard starts when the window really has focus --------------------------------------------------------------
g = popup.Gate(code, km, t0)
check("focus: with no focus report at all keys count only FOCUS_WAIT (2 s) + 0.7 s after the start", g.feed("g", t0 + 2.6)[0] == "ignored" and g.feed("g", t0 + 5)[0] == "progress")
g = popup.Gate(code, km, t0)
g.feed("focus-in", t0 + 0.3)
check("focus: the guard starts at the first focus-in, not at the start", g.feed("g", t0 + 0.6)[0] == "ignored")
g = popup.Gate(code, km, t0)
g.feed("focus-in", t0 + 0.3)
check("focus: ... 0.7 s after the focus-in the code counts (well before the 2 s fallback)", g.feed("g", t0 + 1.1)[0] == "progress" and g.feed("t", t0 + 1.2)[0] == "confirmed")
g = popup.Gate(code, km, t0)
g.feed("focus-in", t0 + 5)
check("focus: a late focus-in re-arms the guard", g.feed("g", t0 + 5.3)[0] == "ignored")
g = popup.Gate(code, km, t0)
g.feed("focus-in", t0 + 1)
g.feed("g", t0 + 3)
check("focus: losing focus before the code is complete cancels", g.feed("focus-out", t0 + 3.1)[0] == "cancelled")
g = popup.Gate(code, km, t0)
check("focus: a focus-out from before the window ever had focus is ignored, and keys stay ignored until a focus-in",
      g.feed("focus-out", t0 + 0.1)[0] == "ignored" and g.feed("g", t0 + 9)[0] == "ignored" and (g.feed("focus-in", t0 + 10), g.feed("g", t0 + 11))[1][0] == "progress")
g = popup.Gate(code, km, t0)
g.feed("focus-in", t0 + 1)
check("focus: a focus-out cancels even before any code key", g.feed("focus-out", t0 + 2)[0] == "cancelled")

# --- widths ----------------------------------------------------------------------------------------------------------------
check("width: ASCII 1, CJK 2, fullwidth 2, combining 0, emoji 2, Cyrillic 1", [popup.width(c) for c in "a日Ａ\u0301👍ж"] == [1, 2, 2, 0, 2, 1])
check("clip: by display cells, never splits a wide character, keeps a combining mark with its base", popup.clip("日本語", 5) == "日本" and popup.clip("e\u0301e\u0301e\u0301", 2) == "e\u0301e\u0301" and popup.clip("abc", 0) == "")
check("wrap: a combining mark never starts a line", all(not l or popup.width(l[0]) for l in popup.wrap("ab" + "e\u0301" * 10, 3)))

# --- the frame (pure) -------------------------------------------------------------------------------------------------------
def frame(text, h, w, top=0, seen_end=False, ready=True, slot=0.5, colf=0.5, **req):
    r = {"kind": "send", "title": "Send this Telegram message?", "account": "main", "name": "Work chat", "username": "work", "chat_id": -1001111,
         "chat_kind": "Supergroup", "reply_preview": "", "text": text, **req}
    return popup.layout(r, km, ["KeyG", "KeyT"], h, w, top, seen_end, ready, 50.0, slot, colf)


def cells(fr, w):
    """rows of the frame as strings (terminal cells, wide characters take 2) built from the draw ops"""
    rows = {}
    for y, x, text, style in fr["ops"]:
        row = rows.setdefault(y, {})
        cx = x
        for ch in text:
            cw = popup.width(ch)
            if cw == 0:
                row[cx - 1] = row.get(cx - 1, "") + ch
                continue
            row[cx] = ch
            if cw == 2:
                row[cx + 1] = ""
            cx += cw
            assert cx <= w - 1, (y, x, text, cx, w)
    return rows


for (h, w) in ((30, 100), (24, 60), (40, 140), (22, 64)):
    text = "x" * (w * 2) + "日本語" * 40 + "é" * 30 + " the end ж"
    fr = frame(text, h, w, seen_end=True)
    drawn = "".join(t for y, x, t, st in fr["ops"] if st == "text")
    first = frame(text, h, w)
    check(f"layout {w}x{h}: every op ends before the last column (nothing is cut by the screen)", all(x + popup.text_width(t) <= w - 1 for y, x, t, st in fr["ops"]) and cells(fr, w) is not None)
    check(f"layout {w}x{h}: the body is wrapped one cell narrower than it can be drawn (no character is clipped)", all(popup.text_width(t) <= w - 6 for y, x, t, st in fr["ops"] if st == "text") and drawn)
sd = "a" * 500
fr = frame(sd, 30, 80, seen_end=True)
lines = [t for y, x, t, st in sorted(fr["ops"]) if st == "text"]
check("layout: the last character of every full line is drawn (the old off-by-one)", "".join(lines) == sd[: len("".join(lines))] and all(len(l) == 74 for l in lines[:-1]))

big = "\n".join(f"line {i}" for i in range(100))
fr = frame(big, 30, 100)
check("layout: with the end not yet seen no code is drawn, even when ready", not fr["code_drawn"] and "Press" not in " ".join(t for y, x, t, st in fr["ops"]) and not fr["seen_end"])
fr = frame(big, 30, 100, top=10**6)
check("layout: scrolled to the end the code is drawn and the last line is visible", fr["code_drawn"] and fr["seen_end"] and any(t == "line 99" for y, x, t, st in fr["ops"]))
fr = frame(big, 30, 100, top=10**6, ready=False)
check("layout: the code is not drawn while the guard runs", not fr["code_drawn"] and fr["seen_end"])
fr = frame("short", 30, 100, ready=True)
check("layout: a short text shows the code at once", fr["code_drawn"])

# the code box: random row and column, text flows around it, nothing hidden
text = "\n".join(f"L{i:03d}" for i in range(12))
rows_seen, cols_seen = set(), set()
for k in range(40):
    fr = frame(text, 40, 100, seen_end=True, slot=k / 40, colf=k / 39)
    box = [y for y, x, t, st in fr["ops"] if t.startswith("┃")]
    rows_seen.add(min(box))
    cols_seen.add(min(x for y, x, t, st in fr["ops"] if t.startswith("┃")))
    shown_lines = [t for y, x, t, st in sorted(fr["ops"]) if st == "text"]
    check_ok = shown_lines == [f"L{i:03d}" for i in range(12)] and len(box) == 3
    if not check_ok:
        check("layout: the text stays complete and in order around the box", False)
        break
else:
    check("layout: the text stays complete and in order around the box at 40 different box positions", True)
check("layout: the box row and column vary with the random draw (not a fixed row relative to the text)", len(rows_seen) > 8 and len(cols_seen) > 8)
fr = frame("hello", 30, 100, seen_end=True)
bt = " ".join(t for y, x, t, st in fr["ops"] if t.startswith("┃") or st in ("key", "bold", "label") and y >= 5)
check("layout: the recipient is repeated next to the code", "Work chat" in " ".join(t for y, x, t, st in fr["ops"] if y >= 4 and st == "bold"))
longname = "N" * 200
fr = frame("hello", 30, 70, seen_end=True, name=longname)
head = "".join(t for y, x, t, st in sorted(fr["ops"]) if st == "bold" and y < 10)
check("layout: a long recipient name is wrapped over several rows, not truncated", head.count("N") >= 200)
for (h, w) in ((17, 100), (30, 59), (30, 401), (121, 100)):
    fr = frame("hello", h, w, seen_end=True)
    check(f"size {w}x{h}: outside the accepted window size nothing but a refusal is drawn, no code", not fr["ok"] and not fr["code_drawn"] and "Press" not in " ".join(t for y, x, t, st in fr["ops"]))
fr = frame("hello", 30, 100, seen_end=True)
check("size 100x30 is accepted", fr["ok"])
kind = popup.layout({"kind": "enable", "title": "Allow AI agents to send Telegram messages?", "text": "For 60 minutes."}, km, ["KeyG", "KeyT"], 30, 100, 0, False, True, 50.0, 0.3, 0.3)
check("layout: the enable popup has no recipient block but the same code box", kind["code_drawn"] and not any(t == "To" for y, x, t, st in kind["ops"]))

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
CUR = f"{TMP}/none.sock"                       # tmux socket of the current popup: one socket per popup (see start)
FOCUS_IN, FOCUS_OUT = "\x1b[I", "\x1b[O"
QUICK = os.environ.get("TGPOPUP_QUICK") == "1"      # doctor / run.sh --quick: the essential screens only


def t(*a):
    return subprocess.run([tmux, "-S", CUR, "-f", "/dev/null", *a], capture_output=True, text=True).stdout


def wait_for(pred, timeout=10):
    """poll pred every 50 ms; True as soon as it holds"""
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return bool(pred())


def start(req, name, size=(100, 30), focus=True):
    """Start popup.py in a private tmux of the given size; unless focus=False send the terminal's focus-in report like ghostty does."""
    res = f"{TMP}/{name}.res"
    req = {"kind": "send", "title": "Send this Telegram message?", "account": "main", "name": "Work chat", "username": "work", "chat_id": -1001111,
           "chat_kind": "Supergroup", "reply_preview": "", "text": "hello", "nonce": name, "timeout": 20, "result_file": res, **req}
    rf = f"{TMP}/{name}.req"
    json.dump(req, open(rf, "w"))
    global CUR
    t("kill-server")                            # the previous popup's server; its socket path is never reused, so a new-session can
    CUR = f"{TMP}/{name}.sock"                  # not hit a server that is still dying (that race was the flake under load)
    t("new-session", "-d", "-x", str(size[0]), "-y", str(size[1]),
      f"TERM=xterm-256color TGCONFIRM_KEYMAP={KEYMAP} {sys.executable} {popup.__file__} --req {rf}")
    if focus:
        # the first frame is drawn after the popup wrote ?1004h (focus reporting), so wait for it instead of sleeping
        wait_for(lambda: "Send this" in screen() or "Allow" in screen() or "unexpected size" in screen(), 10)
        t("send-keys", "-l", FOCUS_IN)
    return res


def screen():
    return t("capture-pane", "-p")


def code_from_screen(timeout=6):
    end = time.time() + timeout
    while time.time() < end:
        s = screen()
        for line in s.splitlines():
            parts = line.split()
            if "Press" in parts and "confirm" in parts and parts.index("Press") + 3 < len(parts):
                i = parts.index("Press")
                return parts[i + 1], parts[i + 3], s
        time.sleep(0.1)
    return None, None, screen()


def result(res, wait=10):
    end = time.time() + wait
    while time.time() < end:
        if os.path.exists(res):
            return json.load(open(res))
        time.sleep(0.1)
    return None


def key(k):
    t("send-keys", "-l", k)


def wrong_key(k1, k2):
    return next(c for c in "abcefhilmnoprsvwxyz" if c.upper() not in (k1, k2))


def alive():
    return t("list-panes", "-F", "#{pane_dead}").strip() == "0"


res = start({"text": "Hello\nthis has a zero width​ char"}, "a")
k1, k2, scr = code_from_screen()
check("screen: shows the account, recipient, @username, chat id and the full text", k1 and "main" in scr and "Work chat" in scr and "@work" in scr and "-1001111" in scr and "<U+200B>" in scr and "Hello" in scr)
check("screen: the recipient is shown again in the box next to the code", any("┃" in l and "Work chat" in l for l in scr.splitlines()))
key(k1)
time.sleep(0.2)
key(k2)
check("screen: the displayed code confirms", result(res) == {"nonce": "a", "result": "confirmed"})

if not QUICK:
    res = start({}, "b")
    k1, k2, scr = code_from_screen()
    ua = {kk: next((c for c in sorted(km["Key" + kk]) if c.islower() and not c.isascii()), kk.lower()) for kk in (k1, k2)}
    key(ua[k1])
    time.sleep(0.2)
    key(ua[k2])
    check("screen: the Cyrillic twins of the displayed keys confirm (ua/ru layout active)", result(res) == {"nonce": "b", "result": "confirmed"})

res = start({}, "c")
k1, k2, scr = code_from_screen()
key(wrong_key(k1, k2))
check("screen: a wrong key cancels immediately", result(res) == {"nonce": "c", "result": "cancelled"})

if not QUICK:
    res = start({}, "d")
    k1, k2, scr = code_from_screen()
    key(k1)
    time.sleep(0.2)
    key(wrong_key(k1, k2))
    check("screen: the first key right, the second wrong cancels", result(res) == {"nonce": "d", "result": "cancelled"})

if not QUICK:
    res = start({}, "e")
    code_from_screen()
    t("send-keys", "Escape")
    check("screen: Esc cancels", result(res) == {"nonce": "e", "result": "cancelled"})

# the guard: starts at the focus-in, any key during it is ignored AND restarts it
res = start({}, "f")
time.sleep(0.2)
scr = screen()
check("screen: right after the focus-in the code is not drawn yet (guard running)", "Press" not in scr and "Read the whole message" in scr)
key("x")                                    # a blind key inside the guard
time.sleep(0.3)
check("screen: a key inside the guard is ignored (the popup stays open, nothing is decided)", alive() and not os.path.exists(res))
time.sleep(0.3)
check("screen: ... and it restarted the guard (0.85 s after the focus-in, 0.6 s after that key, the code is still not drawn)", "Press" not in screen())
k1, k2, scr = code_from_screen()
check("screen: after a quiet 0.7 s the code is drawn", k1 is not None)
key(k1)
time.sleep(0.2)
key(k2)
check("screen: and confirms", result(res) == {"nonce": "f", "result": "confirmed"})

if not QUICK:
    # no focus report at all: the fallback arms the keys FOCUS_WAIT + 0.7 s after the start
    res = start({}, "f2", focus=False)
    time.sleep(1.5)
    check("screen: with no focus report the code is NOT drawn early", "Press" not in screen())
    k1, k2, scr = code_from_screen(5)
    check("screen: ... but it is drawn after the fallback margin (focus reporting is not required)", k1 is not None)
    key(k1)
    time.sleep(0.2)
    key(k2)
    check("screen: and works", result(res) == {"nonce": "f2", "result": "confirmed"})

if not QUICK:
    # losing focus before the code is complete
    res = start({}, "f3")
    k1, k2, scr = code_from_screen()
    key(k1)
    time.sleep(0.2)
    key(FOCUS_OUT)
    check("screen: losing focus after the first code key cancels (a window that is not in front cannot be confirmed)", result(res) == {"nonce": "f3", "result": "cancelled"})
    res = start({}, "f4")
    k1, k2, scr = code_from_screen()
    key(FOCUS_OUT)
    check("screen: losing focus while the code is shown cancels", result(res) == {"nonce": "f4", "result": "cancelled"})

if not QUICK:
    res = start({"timeout": 2}, "g")
    check("screen: no key for the whole timeout ends as 'timeout'", result(res, 5) == {"nonce": "g", "result": "timeout"})

    body = "\n".join(f"line {i} of a long message" for i in range(80)) + "\nTAIL-LINE-HIDDEN-AT-FIRST"
if not QUICK:
        res = start({"text": body}, "h")
        time.sleep(1.3)
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

if not QUICK:
    res = start({"text": body}, "i")
    time.sleep(1.3)
    key("g")
    check("screen: a code key pressed while the code is still hidden cancels", result(res) == {"nonce": "i", "result": "cancelled"})

res = start({"kind": "enable", "title": "Allow AI agents to send Telegram messages?", "text": "For 60 minutes. Every single message will still ask you again.", "name": None}, "j")
k1, k2, scr = code_from_screen()
check("screen: the enable popup shows its question and also needs the code, no recipient block", k1 and "Allow AI agents" in scr and "For 60 minutes" in scr and "To " not in scr.replace("┃ To", ""))

# geometry: a resize after the code is shown cancels; a window of the wrong size never shows a code
res = start({}, "k")
k1, k2, scr = code_from_screen()
check("screen: the code is shown before the resize", k1 is not None)


def resize_to(x, y, res=None):
    """resize the private window and wait until tmux reports the new size (retry once). A popup that already decided has exited and
    taken its tmux server with it, so an existing result file also counts as 'the resize arrived'."""
    done = lambda: bool(res and os.path.exists(res)) or t("display-message", "-p", "#{window_width}x#{window_height}").strip() == f"{x}x{y}"
    for _ in range(2):
        t("resize-window", "-x", str(x), "-y", str(y))
        if wait_for(done, 3):
            return True
    return False


check("screen: the window really has the new size", resize_to(90, 28, res))
check("screen: any size change after the code was shown cancels", result(res) == {"nonce": "k", "result": "cancelled"})
res = start({}, "k2", size=(100, 30))
resize_to(90, 28)                                   # before the code is drawn: allowed, the guard restarts
k1, k2, scr = code_from_screen()
check("screen: a resize BEFORE the code is shown is tolerated (the compositor applies the window rule's size at map time), the code appears afterwards", k1 is not None and not os.path.exists(res))
res = start({}, "k3", size=(50, 14))
wait_for(lambda: "unexpected size" in screen(), 10)
scr = screen()
check("screen: a window smaller than the minimum shows a refusal and never a code", "unexpected size" in scr and "Press" not in scr and "Work chat" not in scr)
key("g")
check("screen: ... and no key confirms there", result(res) != {"nonce": "k3", "result": "confirmed"})

# the full text on screen: every character exactly once, in order, across the scrolled pages
def rule_rows(lines):
    return [i for i, l in enumerate(lines) if l.strip() and set(l.strip()) == {"─"}]


def text_rows(scr):
    lines = scr.splitlines()
    rr = rule_rows(lines)
    if len(rr) != 3:
        return None
    return [l[4:].rstrip() for l in lines[rr[1] + 1:rr[2]] if "┃" not in l]


def merge(acc, new):
    """append the rows of `new` that are not yet in `acc` (the pages overlap: find the longest suffix of acc that is a prefix of new)"""
    for k in range(min(len(acc), len(new)), 0, -1):
        if acc[-k:] == new[:k]:
            return acc + new[k:]
    return acc + new


words = " ".join(f"w{i:04d}" for i in range(60))
longword = "".join(f"{i:03x}" for i in range(220))
cjk = "".join(chr(0x4e00 + i) for i in range(70))
comb = "".join(chr(0x61 + i % 26) + "́" for i in range(40))
cyr = "".join(chr(0x430 + i % 32) for i in range(60))
emo = "👍🎉🔥" * 10
FULL = f"{words}\n{longword}\n{cjk}\n{comb}\n{cyr}\n{emo}\nlast line ж END"
strip_ws = lambda x: "".join(x.split())
for size in (((100, 30),) if QUICK else ((100, 30), (60, 24), (140, 40), (64, 19))):
    res = start({"text": FULL}, f"r{size[0]}", size=size)
    time.sleep(1.4)
    acc = text_rows(screen())
    ok = acc is not None
    if ok:
        for _ in range(40):
            scr = screen()
            if "▼ more" not in scr:
                break
            key("d")
            time.sleep(0.2)
            rows = text_rows(screen())
            if rows is None:
                ok = False
                break
            acc = merge(acc, rows)
        else:
            ok = False
    got = strip_ws("".join(acc or []))
    want = strip_ws(FULL.replace("​", ""))
    check(f"render {size[0]}x{size[1]}: every character of the text appears exactly once and in order across the scrolled pages", ok and got == want)
    if got != want:
        print(f"#   got  {len(got)}: {got[:200]!r}...{got[-80:]!r}\n#   want {len(want)}: {want[:200]!r}...{want[-80:]!r}")
    k1, k2, scr = code_from_screen(2)
    check(f"render {size[0]}x{size[1]}: at the end of the text the code is drawn; Esc then cancels", k1 is not None)
    t("send-keys", "Escape")
    result(res)

t("kill-server")
shutil.rmtree(TMP, ignore_errors=True)
sys.exit(0 if all(results) else 1)
