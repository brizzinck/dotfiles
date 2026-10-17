#!/usr/bin/env python3
"""popup.py: the confirmation screen of tgconfirm (a curses TUI, run by the broker inside a ghostty window of class float.confirm).

Shows what is about to happen in full (account, recipient name, @username, chat id, the message it replies to, the whole text)
and asks for a per-message random two-key code. The code is drawn here from the system RNG, is never written anywhere and the
broker never learns it. Rules (what makes a blind or prompt-injected attempt fail, see CLAUDE.md "Telegram sending"):

  * the code is two physical keys, e.g. "press G then T" (about 1 in 400); the ua / ru twin of each key counts as the same key
    (twins come from keymap.tsv); keys whose characters are ambiguous between layouts and the scroll keys are never used;
  * ANY other key cancels at once, one shot per message (Esc and q included); only the scroll keys j k d u, the arrows and
    PageUp/PageDown are neutral;
  * keys are ignored until the window has really been focused: the guard (0.7 s) starts at the terminal's first focus-in report
    (ESC [ I, mode 1004; with no report at all it starts FOCUS_WAIT = 2 s after the first frame), every key that arrives during
    the guard restarts it, a resize restarts it, and losing focus (ESC [ O) before the code is complete cancels;
  * the code is drawn only when the guard has passed, the window has a trustworthy size (MIN/MAX below) and the whole text has
    been on screen; it sits in a three-row box next to the recipient's name at a RANDOM row and column (the text flows around
    the box), so an overlay that covers the window cannot know where to leave a hole; after the code is shown ANY change of
    the window size cancels (the window was moved or resized under us);
  * the text is shown without interpretation: control characters, zero-width and bidi characters are made visible as <U+XXXX>,
    wrapped by display width (wide and combining characters counted like a terminal does) to the width that is really drawn, so
    what is sent is what was on screen, every character once;
  * 60 s without an answer = timeout.

Residual: another layer-shell client or a pointer/keyboard-capable agent can still draw over the window or move it partly off
screen without resizing; the screen-capture block (window rule) only hides the code from screenshots.

Input: --req FILE (JSON written by the broker: kind send|enable, title, account, name, username, chat_id, chat_kind,
reply_preview, text, timeout, nonce, result_file). Output: the broker's result file {"nonce", "result": confirmed | cancelled |
timeout}; no file means cancelled. Env: TGCONFIRM_LIB (keymap.tsv), TGCONFIRM_KEYMAP (path of the keymap, tests).
"""

from __future__ import annotations

import curses
import json
import os
import secrets
import sys
import time
import unicodedata

GUARD = 0.7
FOCUS_WAIT = 2.0                                # no focus report within this long after the first frame: assume focused
MIN_COLS, MIN_ROWS = 60, 18                     # smaller than the float-confirm rule can ever give: refuse (the window was shrunk)
MAX_COLS, MAX_ROWS = 400, 120
BOX = 3                                         # rows of the code box
NAV_KEYS = ("KeyJ", "KeyK", "KeyD", "KeyU")     # scroll keys (down, up, half page down, half page up)
RESERVED = NAV_KEYS + ("KeyQ",)                 # q is "quit" for people who expect it; it also just cancels
ESC_CHARS = {"\x1b"}
BIDI = set("​‌‍‎‏  ‪‫‬‭‮⁠⁡⁢⁣⁤⁦⁧⁨⁩﻿­")


# --- keymap (physical key -> characters of the layouts us, ua, ru) ----------------------------------------------------------
def load_keymap(path: str) -> dict[str, set[str]]:
    """{"KeyG": {"g", "G", "п", "П"}, ...} for the 26 letter keys; the built-in us letters when the file is missing."""
    keys: dict[str, set[str]] = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                c = line.rstrip("\n").split("\t")
                if len(c) >= 8 and c[1].startswith("Key") and len(c[1]) == 4:
                    keys[c[1]] = {x for x in c[2:8] if len(x) == 1}
    except OSError:
        pass
    if not keys:
        keys = {f"Key{ch.upper()}": {ch, ch.upper()} for ch in "abcdefghijklmnopqrstuvwxyz"}
    return keys


def char_index(keymap: dict[str, set[str]]) -> tuple[dict[str, str], set[str]]:
    """(char -> key for unambiguous chars, ambiguous chars)."""
    seen: dict[str, str] = {}
    ambiguous: set[str] = set()
    for key, chars in keymap.items():
        for ch in chars:
            if ch in seen and seen[ch] != key:
                ambiguous.add(ch)
            seen[ch] = key
    return {c: k for c, k in seen.items() if c not in ambiguous}, ambiguous


def alphabet(keymap: dict[str, set[str]]) -> list[str]:
    """Keys the code may use: not a scroll key, none of their characters ambiguous between keys or layouts."""
    idx, ambiguous = char_index(keymap)
    out = []
    for key in sorted(keymap):
        if key in RESERVED:
            continue
        if any(c in ambiguous for c in keymap[key]):
            continue
        out.append(key)
    return out


def key_label(key: str) -> str:
    return key[3:]


def make_code(keymap: dict[str, set[str]], rng=None) -> list[str]:
    rng = rng or secrets.SystemRandom()
    pool = alphabet(keymap)
    first = rng.choice(pool)
    second = rng.choice([k for k in pool if k != first])
    return [first, second]


def twin_hint(keymap: dict[str, set[str]], key: str) -> str:
    """The same physical key on the other layouts, e.g. 'ua п · ru п'; empty when they are all the same letter."""
    chars = sorted(c for c in keymap.get(key, ()) if c.islower() and not c.isascii())
    return " · ".join(chars)


SPECIAL = {"KEY_DOWN": ("scroll", 1), "KEY_UP": ("scroll", -1), "KEY_NPAGE": ("scroll", 1000), "KEY_PPAGE": ("scroll", -1000),
           "KEY_RESIZE": ("ignored", 0), "KEY_MOUSE": ("ignored", 0), "KEY_HOME": ("scroll", -100000), "KEY_END": ("scroll", 100000)}


# --- the key gate (pure: no curses, driven by the tests) --------------------------------------------------------------------
class Gate:
    """Feed it key and focus events; it says what each one means. `code` is a list of physical key names.

    Keys count only after `ready_at`: the guard starts at the first focus-in (or FOCUS_WAIT after t0 when the terminal never
    reports focus), is restarted by every key or resize that arrives while it runs, and is infinite while the window is unfocused."""

    def __init__(self, code: list[str], keymap: dict[str, set[str]], t0: float, guard: float = GUARD, code_visible=lambda: True,
                 focus_wait: float = FOCUS_WAIT):
        self.code, self.t0, self.guard, self.focus_wait = code, t0, guard, focus_wait
        self.index, _ = char_index(keymap)
        self.pos = 0
        self.code_visible = code_visible
        self.ready_at = t0 + focus_wait + guard      # the fallback; the first focus-in replaces it
        self.focused: bool | None = None             # None = no report yet
        self.saw_focus = False

    def ready(self, now: float) -> bool:
        return self.focused is not False and now >= self.ready_at

    def restart(self, now: float) -> None:
        """A resize or an early key: the guard window starts again (never shorter than it was)."""
        if self.focused is not False:
            self.ready_at = max(self.ready_at, now + self.guard)

    def focus_in(self, now: float) -> None:
        self.focused, self.saw_focus = True, True
        self.ready_at = now + self.guard

    def focus_out(self, now: float) -> str:
        """"cancelled" when the window loses focus after it was in play, else "ignored" (a report from before the window got focus)."""
        self.focused = False
        self.ready_at = float("inf")
        return "cancelled" if (self.saw_focus or now >= self.t0 + self.focus_wait) else "ignored"

    def feed(self, ch, now: float) -> tuple[str, int]:
        """(event, arg): ignored | scroll (arg = lines, +-1000 = half page) | progress | confirmed | cancelled | resize."""
        if ch == "focus-in":
            self.focus_in(now)
            return "ignored", 0
        if ch == "focus-out":
            return self.focus_out(now), 0
        if isinstance(ch, int) and getattr(curses, "KEY_RESIZE", None) == ch:
            self.restart(now)
            return "resize", 0
        if not self.ready(now):
            self.restart(now)
            return "ignored", 0
        if isinstance(ch, int):
            for name, (ev, arg) in SPECIAL.items():
                if getattr(curses, name, None) == ch:
                    return ev, arg
            return "cancelled", 0
        key = self.index.get(ch)
        if key == "KeyJ":
            return "scroll", 1
        if key == "KeyK":
            return "scroll", -1
        if key == "KeyD":
            return "scroll", 1000
        if key == "KeyU":
            return "scroll", -1000
        if key is not None and self.code_visible() and key == self.code[self.pos]:
            self.pos += 1
            return ("confirmed", 0) if self.pos == len(self.code) else ("progress", 0)
        return "cancelled", 0


# --- text safety, widths and wrapping ---------------------------------------------------------------------------------------
def visible(text: str) -> str:
    """Make every non-printing or deceptive character visible instead of interpreting it."""
    out = []
    for ch in text:
        if ch in "\n":
            out.append(ch)
        elif ch == "\t":
            out.append("    ")
        elif ch in BIDI or unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp") or ch in ESC_CHARS:
            out.append(f"<U+{ord(ch):04X}>")
        else:
            out.append(ch)
    return "".join(out)


def width(ch: str) -> int:
    """Cells a terminal gives one character (wcwidth semantics): 0 for combining marks, 2 for East Asian wide / fullwidth, else 1."""
    if unicodedata.combining(ch) or unicodedata.category(ch) in ("Mn", "Me") or 0x1160 <= ord(ch) <= 0x11FF:
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def text_width(s: str) -> int:
    return sum(width(c) for c in s)


def clip(s: str, cells: int) -> str:
    """The longest prefix of s that fits in `cells` display cells (a wide character is never split; combining marks stay with their base)."""
    out, w = [], 0
    for ch in s:
        cw = width(ch)
        if w + cw > cells:
            break
        out.append(ch)
        w += cw
    return "".join(out)


def wrap(text: str, cols: int) -> list[str]:
    """Wrap by display width, keeping every character; newlines start a new line. A combining mark never starts a line."""
    lines: list[str] = []
    cols = max(2, cols)
    for para in visible(text).split("\n"):
        cur, w = "", 0
        for ch in para:
            cw = width(ch)
            if cw and w + cw > cols and cur:
                lines.append(cur)
                cur, w = "", 0
            cur += ch
            w += cw
        lines.append(cur)
    return lines


def one_line(text: str, cols: int) -> str:
    s = visible(text).replace("\n", " ⏎ ")
    out, w = "", 0
    for ch in s:
        cw = width(ch)
        if w + cw > cols - 1:
            return out + "…"
        out, w = out + ch, w + cw
    return out


# --- the frame (pure: returns draw operations, no curses) -------------------------------------------------------------------
def size_ok(h: int, w: int) -> bool:
    return MIN_COLS <= w <= MAX_COLS and MIN_ROWS <= h <= MAX_ROWS


def layout(req: dict, keymap: dict[str, set[str]], code: list[str], h: int, w: int, top: int, seen_end: bool, ready: bool,
           left: float, slot_frac: float, col_frac: float, progress: int = 0) -> dict:
    """One frame. Returns {"ops": [(y, x, text, style)], "top", "seen_end", "code_drawn", "avail", "total", "ok"}.

    Every text op is clipped to the cells that really exist (x + width <= w - 1), and the body is wrapped to that same width minus
    one spare cell, so nothing the owner has to read is ever cut. The code box is three rows inserted into the text area at a
    random row (slot_frac) and a random column (col_frac); text rows flow around it."""
    ops: list[tuple[int, int, str, str]] = []

    def put(y: int, x: int, text: str, style: str = "") -> int:
        cells = w - 1 - x
        if 0 <= y < h and cells > 0:
            ops.append((y, x, clip(text, cells), style))
        return x + text_width(text)

    out = {"ops": ops, "top": top, "seen_end": seen_end, "code_drawn": False, "avail": 0, "total": 0, "ok": size_ok(h, w)}
    is_send = req.get("kind") == "send"
    title = str(req.get("title", "Confirm"))
    acct = f"account {req['account']}" if req.get("account") else ""
    put(0, 2, one_line(title, w - 4), "title")
    tag = f"{acct}   {int(left)} s".strip()
    if text_width(tag) < w - 4:
        put(0, max(2, w - 2 - text_width(tag)), tag, "warn" if left < 15 else "muted")
    if not out["ok"]:
        put(2, 2, f"This window has an unexpected size ({w}x{h}); it needs {MIN_COLS}x{MIN_ROWS} or more.", "warn")
        put(3, 2, "Nothing can be confirmed here. Esc cancels.", "muted")
        return out
    put(1, 2, "─" * (w - 5), "muted")
    y = 2
    if is_send:
        name = str(req.get("name", "?"))
        nlines = wrap(name, w - 13)[:6]
        for i, ln in enumerate(nlines):
            if i == 0:
                put(y, 2, "To", "label")
            put(y, 10, ln + ("…" if i == 5 and len(wrap(name, w - 13)) > 6 else ""), "bold")
            y += 1
        extra = " · ".join(x for x in (("@" + str(req["username"]).lstrip("@")) if req.get("username") else "",
                                       f"chat id {req.get('chat_id')}", str(req.get("chat_kind", ""))) if x)
        put(y, 10, one_line(extra, w - 12), "muted")
        y += 1
        if req.get("reply_preview"):
            put(y, 2, "Reply", "label")
            put(y, 10, "> " + one_line(str(req["reply_preview"]), w - 14), "muted")
            y += 1
    put(y, 2, "─" * (w - 5), "muted")
    y += 1
    foot = 3
    mid = h - y - foot
    text = str(req.get("text", ""))
    body = wrap(text, w - 6)
    cap = mid - BOX
    if cap < 3:
        out["ok"] = False
        put(2, 2, "This window is too small for the message.", "warn")
        return out
    out["avail"], out["total"] = cap, len(body)
    top = max(0, min(top, max(0, len(body) - cap)))
    out["top"] = top
    if top + cap >= len(body):
        seen_end = True
    out["seen_end"] = seen_end
    draw_code = bool(seen_end and ready)
    out["code_drawn"] = draw_code
    slot = int(slot_frac * (cap + 1))                     # 0..cap: the box sits above text row `slot`
    if draw_code:
        k1, k2 = (key_label(k) for k in code)
        who = (str(req.get("name", "?")) if is_send else title)
        rows = [[("┃ ", "muted"), ("To ", "label"), (one_line(who, 38), "bold")] if is_send else [("┃ ", "muted"), (one_line(who, 44), "bold")],
                [("┃ ", "muted"), ("Press ", "label"), (f" {k1} ", "key"), ("  then  ", "label"), (f" {k2} ", "key"), (" to confirm", "label")],
                [("┃ ", "muted"), (one_line("   ".join(f"{key_label(k)} = {twin_hint(keymap, k)}" for k in code if twin_hint(keymap, k)) or "any other key cancels", 44), "muted")]]
    else:
        rows = [[("┃ ", "muted"), ("Read the whole message first.", "warn")],
                [("┃ ", "muted"), ("Scroll to the end (j / d) to see the code.", "warn")],
                [("┃ ", "muted"), ("Any other key cancels. Esc cancels.", "muted")]]
    bw = max(sum(text_width(t) for t, _ in r) for r in rows)
    x0 = 2 + int(col_frac * max(0, (w - 2 - bw - 3)))
    for r in range(mid):
        if slot <= r < slot + BOX:
            x = x0
            for seg, style in rows[r - slot]:
                x = put(y + r, x, seg, style)
        else:
            k = r if r < slot else r - BOX
            if top + k < len(body):
                put(y + r, 4, body[top + k], "text")
    y += mid
    more = len(body) > cap and top + cap < len(body)
    parts = ["▼ more" if more else "", f"{len(text)} characters" if is_send else "",
             f"lines {top + 1}-{min(len(body), top + cap)} of {len(body)}" if len(body) > cap else "", "j/k d/u scroll" if len(body) > cap else ""]
    info = "   ".join(x for x in parts if x)
    put(y, 2, "─" * (w - 5), "muted")
    put(y + 1, 2, one_line(info, w - 4), "muted")
    put(y + 2, 2, "Any other key cancels. Esc cancels.", "bad" if progress else "muted")
    return out


# --- terminal input: curses keys plus the focus reports ncurses does not know -----------------------------------------------
def read_key(stdscr):
    """The next key as str / curses int, or "focus-in" / "focus-out" for ESC [ I / ESC [ O; None on timeout. Anything else that
    starts with ESC is returned as a bare ESC (which cancels)."""
    try:
        ch = stdscr.get_wch()
    except curses.error:
        return None
    if isinstance(ch, int):
        name = (curses.keyname(ch) or b"").decode("ascii", "replace")
        return {"kxIN": "focus-in", "kxOUT": "focus-out"}.get(name, ch)
    if ch != "\x1b":
        return ch
    stdscr.timeout(40)
    try:
        nxt = stdscr.get_wch()
        if nxt == "[":
            third = stdscr.get_wch()
            if third == "I":
                return "focus-in"
            if third == "O":
                return "focus-out"
    except curses.error:
        pass
    finally:
        stdscr.timeout(150)
    return "\x1b"


# --- the screen -------------------------------------------------------------------------------------------------------------
STYLES = {"title": ("bold", "green"), "muted": ("", "muted"), "label": ("", "label"), "warn": ("", "yellow"), "bad": ("", "red"),
          "bold": ("bold", None), "key": ("keycap", "yellow"), "text": ("", None), "": ("", None)}


def run(req: dict, keymap: dict[str, set[str]]) -> str:
    os.environ.setdefault("ESCDELAY", "25")
    rng = secrets.SystemRandom()
    code = make_code(keymap, rng)
    slot_frac, col_frac = rng.random(), rng.random()
    timeout = float(req.get("timeout", 60))

    def ui(stdscr) -> str:
        curses.curs_set(0)
        curses.use_default_colors()
        for i, fg in enumerate((8, 7, 10, 11, 9, 14), start=1):   # muted, label, green, yellow, red, aqua (palette 8,7,10,11,9,14)
            curses.init_pair(i, fg if curses.COLORS > fg else 7, -1)
        colors = {"muted": curses.color_pair(1), "label": curses.color_pair(2), "green": curses.color_pair(3), "yellow": curses.color_pair(4),
                  "red": curses.color_pair(5), None: 0}

        def attr(style: str) -> int:
            flag, color = STYLES.get(style, ("", None))
            a = colors[color]
            if flag == "bold":
                a |= curses.A_BOLD
            if flag == "keycap":
                a |= curses.A_BOLD | curses.A_REVERSE
            return a

        stdscr.keypad(True)
        stdscr.timeout(150)
        os.write(1, b"\x1b[?1004h")      # focus reports (ESC [ I / ESC [ O): the guard starts when the window really has focus
        try:
            return loop(stdscr, attr)
        finally:
            os.write(1, b"\x1b[?1004l")

    def loop(stdscr, attr) -> str:
        top = 0
        seen_end = False
        shown = False                 # the code has been on screen: from then on the window must not change size
        t0 = time.monotonic()
        state = {"visible": False}
        gate = Gate(code, keymap, t0, GUARD, lambda: state["visible"])
        size = stdscr.getmaxyx()
        while True:
            now = time.monotonic()
            left = timeout - (now - t0)
            if left <= 0:
                return "timeout"
            cur = stdscr.getmaxyx()
            if cur != size:
                if shown:
                    return "cancelled"           # moved or resized under us after the code was shown: do not trust the screen
                size = cur
                gate.restart(now)
            h, w = size
            fr = layout(req, keymap, code, h, w, top, seen_end, gate.ready(now), left, slot_frac, col_frac, gate.pos)
            top, seen_end = fr["top"], fr["seen_end"]
            state["visible"] = fr["code_drawn"]
            shown = shown or fr["code_drawn"]
            stdscr.erase()
            for y, x, text, style in fr["ops"]:
                try:
                    stdscr.addstr(y, x, text, attr(style))
                except curses.error:
                    pass
            stdscr.refresh()
            ch = read_key(stdscr)
            if ch is None:
                continue
            ev, arg = gate.feed(ch, time.monotonic())
            if ev == "scroll":
                if abs(arg) >= 100000:
                    top = 0 if arg < 0 else 10 ** 6
                else:
                    top += arg if abs(arg) < 1000 else (max(1, fr["avail"] // 2) if arg > 0 else -max(1, fr["avail"] // 2))
            elif ev == "resize":
                if shown:
                    return "cancelled"
            elif ev == "confirmed":
                return "confirmed"
            elif ev == "cancelled":
                return "cancelled"

    return curses.wrapper(ui)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] != "--req":
        print("usage: popup.py --req FILE", file=sys.stderr)
        return 2
    try:
        with open(argv[1]) as f:
            req = json.load(f)
    except (OSError, ValueError):
        print("popup.py: cannot read the request", file=sys.stderr)
        return 2
    lib = os.environ.get("TGCONFIRM_LIB", "/usr/local/lib/tgconfirm")
    keymap = load_keymap(os.environ.get("TGCONFIRM_KEYMAP") or os.path.join(lib, "keymap.tsv"))
    try:
        result = run(req, keymap)
    except KeyboardInterrupt:
        result = "cancelled"
    except Exception:       # a broken screen must never read as a confirmation
        result = "cancelled"
    out = req.get("result_file")
    if out:
        try:
            fd = os.open(out + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump({"nonce": req.get("nonce"), "result": result}, f)
            os.rename(out + ".tmp", out)      # atomic: a reader never sees a half-written answer
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
