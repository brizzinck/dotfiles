#!/usr/bin/env bash
# Offline test of the ghostty physical-key twins (K4) in .config/layout/layout.py: a fixture default list and config, no ghostty,
# no tmux, nothing live is touched. Checks: Ctrl+Shift+letter / punctuation get `key_*` twins with the same action and flags,
# ASCII-identical keys (digits, - = +), bare / Shift-only keys, names that already are physical and multi-character keys get none,
# `unbind` and `clear` in the config remove the twin, an explicit physical bind of the owner is never overridden, Ctrl+/ -> 0x1f.
set -u
export PYTHONDONTWRITEBYTECODE=1   # python3 -I ignores PYTHON* variables (hence -B there); this covers the other interpreters: no __pycache__ in the repo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
out="$(PYTHONPYCACHEPREFIX=/tmp/pycache python3 -I -B - "$REPO/.config/layout" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import layout as lay
L = lay.Layout(lay.load_map())
DEFAULTS = """keybind = ctrl+shift+,=reload_config
keybind = ctrl+,=open_config
keybind = copy=copy_to_clipboard:mixed
keybind = ctrl+shift+c=copy_to_clipboard:mixed
keybind = ctrl+shift+n=new_window
keybind = ctrl+shift+w=close_tab:this
keybind = ctrl+==increase_font_size:1
keybind = ctrl++=increase_font_size:1
keybind = ctrl+-=decrease_font_size:1
keybind = ctrl+0=reset_font_size
keybind = super+ctrl+[=goto_split:previous
keybind = alt+digit_1=goto_tab:1
keybind = alt+1=goto_tab:1
keybind = shift+arrow_left=adjust_selection:left
keybind = ctrl+shift+key_q=quit
keybind = shift+a=noop
keybind = performable:ctrl+shift+f=start_search
"""
def twins(config=""):
    text = lay.gen_ghostty(L, DEFAULTS, config)
    return [l[len("keybind = "):].rstrip("\n") for l in text.splitlines()
            if l.startswith("keybind = ") and not l.startswith("keybind = alt+")]
res = []
def check(name, cond):
    res.append(("ok" if cond else "FAIL") + "  " + name)
t = twins()
check("ctrl+shift+c twin", "ctrl+shift+key_c=copy_to_clipboard:mixed" in t)
check("ctrl+shift+n twin", "ctrl+shift+key_n=new_window" in t)
check("ctrl+shift+, twin on the comma key", "ctrl+shift+comma=reload_config" in t)
check("ctrl+, twin", "ctrl+comma=open_config" in t)
check("super+ctrl+[ twin", "super+ctrl+bracket_left=goto_split:previous" in t)
check("performable flag kept", "performable:ctrl+shift+key_f=start_search" in t)
check("no twin for ctrl+= ctrl++ ctrl+- ctrl+0 (same ASCII everywhere)", not any(x.startswith(("ctrl+equal", "ctrl+shift+equal", "ctrl+minus", "ctrl+digit")) for x in t))
check("no twin for alt+1 / alt+digit_1", not any("goto_tab" in x for x in t))
check("no twin for named keys (copy, arrow_left)", not any("copy_to_clipboard" in x and not x.startswith("ctrl+shift+key_c") for x in t) and not any("adjust_selection" in x for x in t))
check("Shift-only bind shift+a gets no twin (it would swallow typing)", not any("noop" in x for x in t))
check("an existing physical trigger is not duplicated", sum(1 for x in t if x.startswith("ctrl+shift+key_q=")) == 0)
check("ctrl+slash -> 0x1f", "ctrl+slash=text:\\x1f" in t)
t = twins("keybind = ctrl+shift+c=unbind\n")
check("unbind removes the twin", not any(x.startswith("ctrl+shift+key_c=") for x in t))
t = twins("keybind = clear\nkeybind = ctrl+shift+x=new_window\n")
check("clear drops the defaults, own bind gets a twin", t.count("ctrl+shift+key_x=new_window") == 1 and not any(x.startswith("ctrl+shift+key_n=") for x in t))
t = twins("keybind = ctrl+shift+key_n=goto_tab:2\n")
check("owner's explicit physical bind wins (no generated twin)", not any(x.startswith("ctrl+shift+key_n=new_window") for x in t))
t = twins("keybind = ctrl+shift+n=goto_tab:2\n")
check("owner's rebind of the character trigger moves the twin's action", "ctrl+shift+key_n=goto_tab:2" in t and "ctrl+shift+key_n=new_window" not in t)
t = twins("keybind = ctrl+slash=text:\\x00\n")
check("owner's ctrl+slash wins over the generated one", "ctrl+slash=text:\\x1f" not in t)
print("\n".join(res))
PY
)"
printf '%s\n' "$out"
fails="$(printf '%s\n' "$out" | grep -c '^FAIL')"
total="$(printf '%s\n' "$out" | grep -c '^\(ok\|FAIL\)')"
echo "layout tests: $((total - fails)) passed, $fails failed"
[ "$fails" = 0 ] && [ "$total" -gt 0 ]
