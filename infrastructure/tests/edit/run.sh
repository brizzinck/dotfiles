#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline tests of edit-anywhere (SUPER+CTRL+E): geometry at the pointer (clamping, scale, second monitor), the starting text
# from the primary selection, finish / cancel / empty / target gone, paste shortcut per class, the text kept on the clipboard,
# layout restore, and the nvim side (edit-anywhere.lua) driven headless with `nvim -u NONE`. Fake hyprctl / hyprd / wl-paste / wl-copy /
# notify-send: the live session, its clipboard and its windows are never touched.
#   infrastructure/tests/edit/run.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
EA="$REPO/.config/hypr/scripts/edit-anywhere.sh"
LUA="$REPO/.config/hypr/scripts/edit-anywhere.lua"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/home" "$T/fake"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }
F="$T/fake"

# ── fakes ──
cat >"$T/bin/hyprctl" <<'X2'
#!/bin/sh
echo "hyprctl $*" >>"$FAKE/log"
case "$1 $2" in
  "cursorpos -j") cat "$FAKE/cursor.json" ;;
  "monitors -j") cat "$FAKE/monitors.json" ;;
  "clients -j")
    printf '[{"address":"0x1","class":"%s"}' "$(cat "$FAKE/prev-class" 2>/dev/null || echo org.gnome.Test)"
    [ -e "$FAKE/editor-open" ] && printf ',{"address":"0x2","class":"float.edit"}'
    [ -e "$FAKE/prev-gone" ] && { printf '[]'; exit 0; }
    printf ']' ;;
  "activewindow -j") printf '{"address":"%s"}' "$(cat "$FAKE/active" 2>/dev/null || echo 0x1)" ;;
  "devices -j") printf '{"keyboards":[{"main":true,"active_layout_index":%s}]}' "$(cat "$FAKE/layout" 2>/dev/null || echo 0)" ;;
  "switchxkblayout all") echo "$3" >"$FAKE/layout" ;;
esac
exit 0
X2
cat >"$T/bin/hyprd" <<'X2'
#!/bin/sh
echo "hyprd $*" >>"$FAKE/log"
case "$1" in
  focuswindow) echo "${2#address:}" >"$FAKE/active" ;;
  sendshortcut) echo ok ;;
esac
exit 0
X2
cat >"$T/bin/notify-send" <<'X2'
#!/bin/sh
echo "notify $*" >>"$FAKE/log"
X2
cat >"$T/bin/wl-paste" <<'X2'
#!/bin/sh
f="$FAKE/clip"; list=0
for a; do case "$a" in --primary) f="$FAKE/primary" ;; --list-types) list=1 ;; esac; done
[ -e "$f.types" ] || exit 1
if [ "$list" = 1 ]; then cat "$f.types"; exit 0; fi
cat "$f"
X2
cat >"$T/bin/wl-copy" <<'X2'
#!/bin/sh
f="$FAKE/clip"
for a; do case "$a" in --primary) f="$FAKE/primary" ;; esac; done
cat >"$f"
printf 'text/plain\n' >"$f.types"
echo "wl-copy $*" >>"$FAKE/log"
X2
cat >"$T/bin/wtype" <<'X2'
#!/bin/sh
echo "wtype $*" >>"$FAKE/log"
X2
# a fake terminal: opens the "editor window" for the length of the command, then marks the end
cat >"$T/bin/term" <<'X2'
#!/bin/sh
touch "$FAKE/editor-open"
"$@"
rm -f "$FAKE/editor-open"
touch "$FAKE/term-done"
X2
# a fake nvim: NVIM_ACTION=finish:TEXT | cancel | empty
cat >"$T/bin/fakenvim" <<'X2'
#!/bin/bash
file="${*: -1}"
cp "$file" "$FAKE/started-with"
case "$NVIM_ACTION" in
  finish:*) printf '%b' "${NVIM_ACTION#finish:}" >"$file"; : >"$EDIT_ANYWHERE_DIR/saved" ;;
  empty) printf '' >"$file"; : >"$EDIT_ANYWHERE_DIR/saved" ;;
esac
[ -n "${NVIM_LAYOUT_AFTER:-}" ] && echo "$NVIM_LAYOUT_AFTER" >"$FAKE/layout"
exit 0
X2
chmod +x "$T/bin"/*
export FAKE="$F" XDG_RUNTIME_DIR="$T/run" HOME="$T/home" PATH="$T/bin:$PATH" HYPRLAND_INSTANCE_SIGNATURE=fake
export EDIT_ANYWHERE_DIR="$T/run/edit-anywhere" EDIT_ANYWHERE_NO_NOTIFY=1 EDIT_ANYWHERE_TERMINAL="$T/bin/term" EDIT_ANYWHERE_NVIM="$T/bin/fakenvim"
export EDIT_ANYWHERE_SYNC=1
unset HUB_TARGET TG_SKIP
reset() { rm -f "$F"/log "$F"/term-done "$F"/prev-gone "$F"/editor-open "$F"/clip "$F"/clip.types "$F"/primary "$F"/primary.types "$F"/active "$F"/layout "$F"/prev-class; rm -rf "$EDIT_ANYWHERE_DIR"; unset NVIM_ACTION NVIM_LAYOUT_AFTER; }
set_primary() { printf '%s' "$1" >"$F/primary"; printf 'text/plain\n' >"$F/primary.types"; }
seen() { # seen TEXT [WINDOW] [SECONDS_AGO]: the watcher saw TEXT selected in WINDOW (default 0x1)
  printf '%s' "${2:-0x1}" >"$F/active"
  printf '%s' "$1" | CLIPBOARD_STATE=data "$EA" _seen
  rm -f "$F/active"
  [[ -n ${3:-} ]] && sed -i "1s/.*/$(($(date +%s) - $3))/" "$EDIT_ANYWHERE_DIR/seen"
  return 0
}
set_clip() { printf '%s' "$1" >"$F/clip"; printf '%s\n' "${2:-text/plain}" >"$F/clip.types"; }
run_flow() { # run_flow: open the editor and wait until the fake terminal (and the synchronous finish) is done
  HUB_TARGET=address:0x1 "$EA" open >/dev/null 2>&1
  for _ in $(seq 1 100); do [[ -e $F/term-done ]] && break; sleep 0.05; done
}

# ── geometry ──
laptop='[{"name":"eDP-1","x":0,"y":1440,"width":2880,"height":1800,"scale":1.5,"transform":0,"focused":true,"disabled":false,"reserved":[0,28,0,0]}]'
two='[{"name":"HDMI-A-1","x":0,"y":0,"width":2560,"height":1440,"scale":1.0,"transform":0,"focused":false,"disabled":false,"reserved":[0,28,0,0]},{"name":"eDP-1","x":0,"y":1440,"width":2880,"height":1800,"scale":1.5,"transform":0,"focused":true,"disabled":false,"reserved":[0,28,0,0]}]'
tiny='[{"name":"X-1","x":0,"y":0,"width":800,"height":300,"scale":1.0,"transform":0,"focused":true,"disabled":false,"reserved":[0,28,0,0]}]'
geo() { # geo MONITORS_JSON X Y -> "x,y WxH"
  reset; printf '%s' "$1" >"$F/monitors.json"; printf '{"x":%s,"y":%s}' "$2" "$3" >"$F/cursor.json"
  "$EA" --dry-run open 2>&1 | sed -n 's/^\[dry-run\] geometry \([0-9-]*,[0-9-]* [0-9]*x[0-9]*\):.*/\1/p'
}
expect "geometry: centred on the pointer (scale 1.5, bar reserved)" test "$(geo "$laptop" 960 2040)" = "510,420 900x360"
expect "geometry: top-left corner is clamped to the work area" test "$(geo "$laptop" 0 1440)" = "8,36 900x360"
expect "geometry: bottom-right corner is clamped" test "$(geo "$laptop" 1919 2639)" = "1012,832 900x360"
expect "geometry: pointer on the first monitor of two" test "$(geo "$two" 1000 700)" = "550,520 900x360"
expect "geometry: pointer on the laptop panel of two" test "$(geo "$two" 960 2040)" = "510,420 900x360"
expect "geometry: a small monitor shrinks the window" test "$(geo "$tiny" 400 150)" = "8,36 784x256"
expect "geometry: a pointer outside every monitor falls back to the focused one" test "$(geo "$laptop" 5000 5000)" = "1012,832 900x360"

# ── starting text ──
reset; printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
set_primary "picked words"
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a selection the watcher never saw (left over from before) is not preloaded" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
seen "picked words"
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a fresh selection in a normal window is preloaded" bash -c "grep -q 'preloaded 12 characters' <<<'$out'"
expect "the watcher notes time, window and fingerprint, no text" bash -c "[ \$(wc -l <'$EDIT_ANYWHERE_DIR/seen') = 3 ] && ! grep -q picked '$EDIT_ANYWHERE_DIR/seen'"
seen "picked words" 0x9
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a selection made in another window (a terminal, an old chat) is not preloaded" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
seen "picked words" 0x1 600
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a selection older than EDIT_ANYWHERE_MAX_AGE is not preloaded" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
seen "other words"
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a selection that changed since the watcher saw it is not preloaded" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
seen "picked words"; printf '' | CLIPBOARD_STATE=nil "$EA" _seen
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a cleared selection (CLIPBOARD_STATE=nil) forgets the note" bash -c "[ ! -e '$EDIT_ANYWHERE_DIR/seen' ] && grep -q 'preloaded 0 characters' <<<'$out'"
date +%s%N >"$EDIT_ANYWHERE_DIR/watch-start"; seen "picked words"
expect "the event at watcher start (a selection made before it) is ignored" test ! -e "$EDIT_ANYWHERE_DIR/seen"
rm -f "$EDIT_ANYWHERE_DIR/watch-start"
seen "picked words"
echo org.gnome.Test >"$F/prev-class"
printf 'com.mitchellh.ghostty' >"$F/prev-class"
seen "picked words"
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "starting from a terminal preloads nothing (a terminal does not replace a selection)" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
printf 'org.gnome.Test' >"$F/prev-class"
printf 'text/plain\nx-kde-passwordManagerHint\n' >"$F/primary.types"
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a password-manager selection is never preloaded" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
printf 'image/png\n' >"$F/primary.types"
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "a non-text selection is never preloaded" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
rm -f "$F/primary" "$F/primary.types"
out=$(HUB_TARGET=address:0x1 "$EA" --dry-run open 2>&1)
expect "no selection: empty start" bash -c "grep -q 'preloaded 0 characters' <<<'$out'"
reset; printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
set_primary "fresh words"; seen "fresh words"
run_flow
expect "open: the fresh selection is the starting text" test "$(cat "$F/started-with")" = "fresh words"
rm -f "$F/term-done"
run_flow
expect "open: the same selection is not preloaded a second time" test ! -s "$F/started-with"

# ── finish: copy, refocus, paste ──
reset; printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
set_primary "old text"; set_clip "my clipboard"
export NVIM_ACTION='finish:new text'
run_flow
expect "finish: the text goes to the clipboard with wl-copy" grep -q '^wl-copy -t text/plain' "$F/log"
expect "finish: the previous window gets the focus" grep -q '^hyprd focuswindow address:0x1' "$F/log"
expect "finish: Ctrl+V on the physical V key into that window" grep -q '^hyprd sendshortcut CTRL,code:55,address:0x1' "$F/log"
expect "finish: the focus is restored before the paste" bash -c "[ \$(grep -n 'focuswindow' '$F/log' | head -1 | cut -d: -f1) -lt \$(grep -n 'sendshortcut' '$F/log' | head -1 | cut -d: -f1) ]"
expect "finish: the text stays on the clipboard after the paste" test "$(cat "$F/clip")" = "new text"
expect "finish: nothing is left in the session directory" bash -c "[ -z \"\$(ls -A '$EDIT_ANYWHERE_DIR')\" ]"
# the text must have been on the clipboard at paste time
reset; set_clip "my clipboard"; export NVIM_ACTION='finish:typed text'
cat >"$T/bin/hyprd" <<'X2'
#!/bin/sh
echo "hyprd $*" >>"$FAKE/log"
case "$1" in
  focuswindow) echo "${2#address:}" >"$FAKE/active" ;;
  sendshortcut) echo "clipboard at paste: [$(cat "$FAKE/clip")]" >>"$FAKE/log"; echo ok ;;
esac
X2
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
run_flow
expect "finish: the typed text is on the clipboard when the paste shortcut is sent" grep -q 'clipboard at paste: \[typed text\]' "$F/log"
reset; set_clip "my clipboard"; export NVIM_ACTION='finish:line one\nline two\n'
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
cat >"$T/bin/hyprd" <<'X2'
#!/bin/sh
echo "hyprd $*" >>"$FAKE/log"
case "$1" in
  focuswindow) echo "${2#address:}" >"$FAKE/active" ;;
  sendshortcut) cp "$FAKE/clip" "$FAKE/clip.at-paste"; echo ok ;;
esac
X2
run_flow
expect "finish: a trailing newline the owner typed in a multi-line text is kept" test "$(od -An -v -w64 -c "$F/clip.at-paste" | tr -d ' ')" = 'lineone\nlinetwo\n'
reset; set_clip "my clipboard"; export NVIM_ACTION='finish:one line'
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
run_flow
expect "finish: a one-line text has no trailing newline" test "$(od -An -v -w64 -c "$F/clip.at-paste" | tr -d ' ')" = 'oneline'

# paste shortcut per class
for cls in com.mitchellh.ghostty Alacritty kitty foot; do
  reset; printf '%s' "$cls" >"$F/prev-class"; export NVIM_ACTION='finish:x'
  printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
  run_flow
  expect "terminal $cls pastes with Ctrl+Shift+V" grep -q '^hyprd sendshortcut CTRL_SHIFT,code:55,address:0x1' "$F/log"
done
rm -f "$F/clip.at-paste"
cat >"$T/bin/hyprd" <<'X2'
#!/bin/sh
echo "hyprd $*" >>"$FAKE/log"
case "$1" in
  focuswindow) echo "${2#address:}" >"$FAKE/active" ;;
  sendshortcut) echo ok ;;
esac
X2

# ── cancel, empty, gone, focus changed ──
reset; set_clip "my clipboard"; export NVIM_ACTION=cancel
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
run_flow
expect "cancel: nothing is pasted" bash -c "! grep -q sendshortcut '$F/log' && ! grep -q '^hyprd focuswindow' '$F/log'"
expect "cancel: the clipboard is untouched" test "$(cat "$F/clip")" = "my clipboard"
expect "cancel: the session directory is empty" bash -c "[ -z \"\$(ls -A '$EDIT_ANYWHERE_DIR')\" ]"
reset; set_clip "my clipboard"; export NVIM_ACTION=empty
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
run_flow
expect "empty text: nothing is pasted and the clipboard stays" bash -c "! grep -q sendshortcut '$F/log' && [ \"\$(cat '$F/clip')\" = 'my clipboard' ]"
reset; set_clip "my clipboard"; export NVIM_ACTION='finish:kept'; : >"$F/prev-gone"
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
run_flow
expect "target window gone: no paste, the text stays on the clipboard" bash -c "! grep -q sendshortcut '$F/log' && [ \"\$(cat '$F/clip')\" = kept ]"
reset; set_clip "my clipboard"; export NVIM_ACTION='finish:x'
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
# the focus never reaches the target (another window grabs it): type-guard refuses, the text stays on the clipboard
cat >"$T/bin/hyprd" <<'X2'
#!/bin/sh
echo "hyprd $*" >>"$FAKE/log"
case "$1" in focuswindow) echo 0x99 >"$FAKE/active" ;; sendshortcut) echo ok ;; esac
X2
run_flow
expect "focus changed: nothing is pasted, a notification says so" bash -c "! grep -q sendshortcut '$F/log' && grep -q 'Focus changed' '$F/log'"
cat >"$T/bin/hyprd" <<'X2'
#!/bin/sh
echo "hyprd $*" >>"$FAKE/log"
case "$1" in
  focuswindow) echo "${2#address:}" >"$FAKE/active" ;;
  sendshortcut) echo ok ;;
esac
X2

# ── layout restore ──
reset; set_clip "x"; export NVIM_ACTION='finish:x' NVIM_LAYOUT_AFTER=0; echo 2 >"$F/layout"
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
run_flow
expect "the keyboard layout from before the editor (ru = 2) is restored after K3 switched to us" bash -c "grep -q 'switchxkblayout all 2' '$F/log' && [ \"\$(cat '$F/layout')\" = 2 ]"

# ── the editor window already open: a second press focuses it ──
reset; : >"$F/editor-open"
printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
"$EA" open >/dev/null 2>&1
expect "second press focuses the open editor instead of opening another" grep -q '^hyprd focuswindow address:0x2' "$F/log"
rm -f "$F/editor-open"

# ── launch command: exec rules with a monitor-relative move ──
reset; printf '%s' "$laptop" >"$F/monitors.json"; printf '{"x":960,"y":2040}' >"$F/cursor.json"
# without EDIT_ANYWHERE_TERMINAL the script goes through hyprctl dispatch with exec rules
out=$(env -u EDIT_ANYWHERE_TERMINAL HUB_TARGET=address:0x1 "$EA" open 2>&1)
expect "launch: hyprctl dispatch exec_cmd with float, move and size rules" bash -c "grep -q 'hyprctl dispatch hl.dsp.exec_cmd(\"ghostty --class=float.edit --title=edit-anywhere -e .*edit-anywhere.sh _session\", { float = true, move = \"510 420\", size = \"900 360\" })' '$F/log'"
expect "launch: the session directory is private" test "$(stat -c %a "$EDIT_ANYWHERE_DIR")" = 700
rm -rf "$EDIT_ANYWHERE_DIR"

# ── the nvim side, headless and without the owner's config ──
if command -v nvim >/dev/null 2>&1; then
  nv() { # nv INITIAL_TEXT KEYS -> exit code; leaves text in $T/n/text.txt and the marker in $T/n/saved
    rm -rf "$T/n"; mkdir -p "$T/n"; printf '%s' "$1" >"$T/n/text.txt"
    EDIT_ANYWHERE_DIR="$T/n" timeout 20 nvim --headless -u NONE -n -i NONE --cmd 'set noswapfile' -c "luafile $LUA" "$T/n/text.txt" \
      -c "lua vim.defer_fn(function() vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes([==[$2]==], true, false, true), 't', false) end, 900)" \
      -c "lua vim.defer_fn(function() vim.cmd('qall!') end, 3500)" >/dev/null 2>&1
  }
  nv "sel" 'abc<C-s>'; expect "nvim: Ctrl+S in insert mode finishes, the text continues the selection, no trailing newline" bash -c "[ \"\$(od -An -v -w64 -c '$T/n/text.txt' | tr -d ' ')\" = 'selabc' ] && [ -e '$T/n/saved' ]"
  nv "" 'hi<Esc>ZZ'; expect "nvim: ZZ finishes" bash -c "[ \"\$(cat '$T/n/text.txt')\" = hi ] && [ -e '$T/n/saved' ]"
  nv "" 'hi<Esc>:wq<CR>'; expect "nvim: :wq finishes" bash -c "[ \"\$(cat '$T/n/text.txt')\" = hi ] && [ -e '$T/n/saved' ]"
  nv "" 'hi<Esc><C-s>'; expect "nvim: Ctrl+S in normal mode finishes" bash -c "[ \"\$(cat '$T/n/text.txt')\" = hi ] && [ -e '$T/n/saved' ]"
  nv "keep" 'x<Esc>:q!<CR>'; expect "nvim: :q! cancels (no marker)" bash -c "[ ! -e '$T/n/saved' ]"
  nv "keep" '<Esc>ZQ'; expect "nvim: ZQ cancels (no marker)" bash -c "[ ! -e '$T/n/saved' ]"
  nv "" 'one<CR>two<CR><C-s>'; expect "nvim: a trailing newline typed by the owner is kept" bash -c "[ \"\$(od -An -v -w64 -c '$T/n/text.txt' | tr -d ' ')\" = 'one\ntwo\n' ]"
  nv "" 'ok<C-ы>'; expect "nvim: Ctrl+S on the ru layout key finishes" bash -c "[ -e '$T/n/saved' ]"
  nv "" 'ok<C-і>'; expect "nvim: Ctrl+S on the ua layout key finishes" bash -c "[ -e '$T/n/saved' ]"
  nv "" 'ok<Esc>'; expect "nvim: Esc is an ordinary Esc (no marker, still open until killed)" bash -c "[ ! -e '$T/n/saved' ]"
  # starts in insert mode with wrap on, markdown filetype, no swap/undo
  EDIT_ANYWHERE_DIR="$T/n" timeout 20 nvim --headless -u NONE -n -i NONE -c "luafile $LUA" "$T/n/text.txt" \
    -c "lua vim.defer_fn(function() local f=io.open('$T/n/state','w'); f:write(vim.fn.mode()..' '..vim.bo.filetype..' wrap='..tostring(vim.wo.wrap)..' undofile='..tostring(vim.bo.undofile)..' swap='..tostring(vim.bo.swapfile)); f:close(); vim.cmd('qall!') end, 600)" >/dev/null 2>&1
  expect "nvim: starts in INSERT, filetype markdown, wrap on, no undofile or swap" test "$(cat "$T/n/state")" = "i markdown wrap=true undofile=false swap=false"
  # without the session directory the module does nothing at all
  out=$(env -u EDIT_ANYWHERE_DIR timeout 20 nvim --headless -u NONE -n -i NONE -c "luafile $LUA" -c 'lua vim.defer_fn(function() io.stdout:write(vim.fn.mode()) vim.cmd("qall!") end, 400)' 2>&1)
  expect "nvim: the helper is inert without EDIT_ANYWHERE_DIR" test "$out" = n
else
  echo "SKIP  nvim not installed: the nvim-side tests were skipped"
fi

echo "edit tests: $fails failure(s)"
exit $((fails > 0))
