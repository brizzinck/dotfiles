#!/usr/bin/env python3
"""popup.py: the confirmation screen of tgconfirm (a curses TUI, run by the broker inside a ghostty window of class float.confirm).

Shows what is about to happen in full (account, recipient name, @username, chat id, the message it replies to, the whole text)
and asks for a per-message random two-key code. The code is drawn here from the system RNG, is never written anywhere and the
broker never learns it. Rules (what makes a blind or prompt-injected attempt fail, see CLAUDE.md "Telegram send"):

  * the code is two physical keys, e.g. "press G then T" (about 1 in 400); the ua / ru twin of each key counts as the same key
    (twins come from keymap.tsv); keys whose characters are ambiguous between layouts and the scroll keys are never used;
  * ANY other key cancels at once, one shot per message (Esc and q included); only the scroll keys j k d u, the arrows and
    PageUp/PageDown are neutral;
  * keys that arrive in the first 0.7 s after the first frame are ignored (a typing burst or a scripted key never counts);
  * the text is shown without interpretation: control characters, zero-width and bidi characters are made visible as <U+XXXX>;
  * when the text does not fit, the code is shown only after the last line has been on screen (hidden tails cannot be missed);
  * 60 s without an answer = timeout.

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
    """Feed it key events; it says what each one means. `code` is a list of physical key names."""

    def __init__(self, code: list[str], keymap: dict[str, set[str]], t0: float, guard: float = GUARD, code_visible=lambda: True):
        self.code, self.t0, self.guard = code, t0, guard
        self.index, _ = char_index(keymap)
        self.pos = 0
        self.code_visible = code_visible

    def feed(self, ch, now: float) -> tuple[str, int]:
        """(event, arg): ignored | scroll (arg = lines, +-1000 = half page) | progress | confirmed | cancelled."""
        if now < self.t0 + self.guard:
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


# --- text safety and wrapping -----------------------------------------------------------------------------------------------
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
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def wrap(text: str, cols: int) -> list[str]:
    """Wrap by display width, keeping every character; newlines start a new line."""
    lines: list[str] = []
    for para in visible(text).split("\n"):
        cur, w = "", 0
        for ch in para:
            cw = width(ch)
            if w + cw > cols and cur:
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


# --- the screen -------------------------------------------------------------------------------------------------------------
def run(req: dict, keymap: dict[str, set[str]]) -> str:
    os.environ.setdefault("ESCDELAY", "25")
    code = make_code(keymap)
    timeout = float(req.get("timeout", 60))

    def ui(stdscr) -> str:
        curses.curs_set(0)
        curses.use_default_colors()
        for i, fg in enumerate((8, 7, 10, 11, 9, 14), start=1):   # muted, label, green, yellow, red, aqua (palette 8,7,10,11,9,14)
            curses.init_pair(i, fg if curses.COLORS > fg else 7, -1)
        MUTED, LABEL, GREEN, YELLOW, RED, AQUA = (curses.color_pair(i) for i in range(1, 7))
        stdscr.keypad(True)
        stdscr.timeout(150)

        def put(y: int, x: int, text: str, attr: int = 0) -> int:
            """addstr that clips instead of raising on a small window; returns the next x."""
            h_, w_ = stdscr.getmaxyx()
            if y < 0 or y >= h_ or x >= w_ - 1:
                return x
            try:
                stdscr.addstr(y, x, text[: max(0, w_ - 1 - x)], attr)
            except curses.error:
                pass
            return x + len(text)

        top = 0
        seen_end = False
        t0 = time.monotonic()
        state = {"gate": None}

        def code_visible() -> bool:
            return seen_end

        gate = Gate(code, keymap, t0, GUARD, code_visible)
        state["gate"] = gate
        result = ""
        is_send = req.get("kind") == "send"
        while not result:
            now = time.monotonic()
            left = timeout - (now - t0)
            if left <= 0:
                return "timeout"
            h, w = stdscr.getmaxyx()
            cols = max(20, w - 4)
            head = 2
            fields: list[tuple[str, str, int]] = []
            if is_send:
                fields.append(("To", str(req.get("name", "?")), curses.A_BOLD))
                extra = " · ".join(x for x in (("@" + str(req["username"]).lstrip("@")) if req.get("username") else "",
                                               f"chat id {req.get('chat_id')}", str(req.get("chat_kind", ""))) if x)
                fields.append(("", extra, MUTED))
                if req.get("reply_preview"):
                    fields.append(("Reply", "> " + one_line(str(req["reply_preview"]), cols - 8), MUTED))
            body = wrap(str(req.get("text", "")), cols)
            foot = 5
            avail = max(3, h - head - len(fields) - foot - 2)
            overflow = len(body) > avail
            top = max(0, min(top, max(0, len(body) - avail)))
            if top + avail >= len(body):
                seen_end = True
            stdscr.erase()
            title = str(req.get("title", "Confirm"))
            acct = f"account {req['account']}" if req.get("account") else ""
            put(0, 2, one_line(title, w - 4), curses.A_BOLD | GREEN)
            tag = f"{acct}   {int(left)} s".strip()
            if len(tag) < w - 4:
                put(0, max(2, w - 2 - len(tag)), tag, YELLOW if left < 15 else MUTED)
            put(1, 2, "─" * max(0, w - 4), MUTED)
            y = head
            for label, val, attr in fields:
                if label:
                    put(y, 2, label, LABEL)
                put(y, 10, one_line(val, max(10, w - 12)), attr)
                y += 1
            put(y, 2, "─" * max(0, w - 4), MUTED)
            y += 1
            for i in range(avail):
                if top + i < len(body):
                    put(y + i, 4, body[top + i])
            y += avail
            more = overflow and top + avail < len(body)
            info = f"{len(str(req.get('text', '')))} characters" if is_send else ""
            if overflow:
                info += f"   lines {top + 1}-{min(len(body), top + avail)} of {len(body)}   j/k d/u scroll"
            put(y, 2, "─" * max(0, w - 4), MUTED)
            put(y + 1, 2, one_line(info, w - 4) + ("   ▼ more" if more else ""), MUTED)
            if seen_end:
                k1, k2 = (key_label(k) for k in code)
                x = put(y + 2, 2, "Press ", LABEL)
                x = put(y + 2, x, f" {k1} ", curses.A_BOLD | YELLOW | curses.A_REVERSE)
                x = put(y + 2, x, "  then  ", LABEL)
                x = put(y + 2, x, f" {k2} ", curses.A_BOLD | YELLOW | curses.A_REVERSE)
                put(y + 2, x, "  to confirm", LABEL)
                hint = "   ".join(f"{key_label(k)} = {twin_hint(keymap, k)}" for k in code if twin_hint(keymap, k))
                if hint:
                    put(y + 3, 2, one_line(hint, w - 4), MUTED)
                put(y + 4, 2, "Any other key cancels. Esc cancels.", RED if gate.pos else MUTED)
            else:
                put(y + 2, 2, "Scroll to the end (j / d) to see the code.", YELLOW)
                put(y + 4, 2, "Any other key cancels. Esc cancels.", MUTED)
            stdscr.refresh()
            try:
                ch = stdscr.get_wch()
            except curses.error:
                continue
            ev, arg = gate.feed(ch, time.monotonic())
            if ev == "scroll":
                if abs(arg) >= 100000:
                    top = 0 if arg < 0 else len(body)
                else:
                    top += arg if abs(arg) < 1000 else (avail // 2 if arg > 0 else -(avail // 2))
            elif ev == "confirmed":
                result = "confirmed"
            elif ev == "cancelled":
                result = "cancelled"
        return result

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
