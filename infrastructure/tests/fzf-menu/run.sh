#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline test of fzf-menu's one-shot server terminals: slots a/b, standby hand-over, hot-path request flow, the Lua chunk that shows
# the window (geometry only when it differs), --no-clear in window modes, Esc / Enter / toggle, and the modal self-test.
# Fakes: hyprctl (canned JSON, logs every eval), the terminal (FZF_MENU_TERMINAL: starts the command in a window of a private tmux
# server), fzf (case 4). The owner's Hyprland, menus and clipboard are never touched (XDG_RUNTIME_DIR is a scratch directory).
#   run.sh [--quick]   --quick (doctor) = cases 1, 3 and 4
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
FM="$REPO/.local/bin/fzf-menu"
QUICK=0
[[ ${1:-} == --quick ]] && QUICK=1
for c in tmux fzf jq; do command -v "$c" >/dev/null || { echo "SKIP: tmux, fzf and jq are required"; exit 0; }; done

T=$(mktemp -d "${TMPDIR:-/tmp}/fzfmenu-test.XXXXXX")
S="fzfmenu-test-$$"
fails=0 passes=0
cleanup() {
  [[ -r $T/xdg/fzf-menu/server.pid ]] && kill "$(cat "$T/xdg/fzf-menu/server.pid")" 2>/dev/null
  tmux -L "$S" kill-server 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
pass() { passes=$((passes + 1)); printf 'PASS  %s\n' "$1"; }
fail() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
expect() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
wait_for() { local i; for ((i = 0; i < ${2:-100}; i++)); do eval "$1" && return 0; sleep 0.05; done; return 1; }

mkdir -p "$T/xdg" "$T/ft"
chmod 700 "$T/xdg"
RUN="$T/xdg/fzf-menu"
export FT_DIR="$T/ft" FT_SOCK="$S" XDG_RUNTIME_DIR="$T/xdg" XDG_CONFIG_HOME="$REPO/.config" HYPRLAND_INSTANCE_SIGNATURE=fake
export FZF_MENU_TERMINAL="$HERE/bin/fake-term" FZF_MENU_SERVER_ADDR=0xserver TERM=xterm-256color
export PATH="$HERE/bin:$PATH"
reset_logs() { : >"$FT_DIR/term.log"; : >"$FT_DIR/hypr.log"; }
reset_logs
# a 1920x1200 monitor at scale 1; the server window already has the normal menu size (60% x 65%) on it
echo '[{"id":0,"name":"eDP-1","focused":true,"width":1920,"height":1200,"scale":1.0}]' >"$FT_DIR/monitors.json"
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-98,"name":"special:menu-a"}}]' >"$FT_DIR/clients.json"
echo '{"address":"0xprev","class":"x","title":"x"}' >"$FT_DIR/activewindow.json"
tmux -L "$S" -f /dev/null new-session -d -s main -x 110 -y 30 'sleep 600'

# the window (tmux id) the last terminal with this title opened
win_of() { awk -F'\t' -v t="$1" '$1 == t { id = $2 } END { print id }' "$FT_DIR/term.log"; }
screen_of() { tmux -L "$S" capture-pane -p -t "$1" 2>/dev/null; }
count_log() { grep -c -- "$1" "$FT_DIR/hypr.log" 2>/dev/null; }
count_term() { grep -c -- "^$1" "$FT_DIR/term.log" 2>/dev/null; }
active_slot() { cat "$RUN/server.slot" 2>/dev/null; }
# open a menu through the client (rows 1..5) in the background; wait until the active server window shows the list
CLIENT_PID=""
open_menu() { # NAME [fzf-menu args...]
  local name=$1 slot w
  shift
  slot=$(active_slot)
  FZF_MENU_TRACE=1 "$FM" -p "$name" "$@" < <(seq 5) >"$T/$name.out" 2>"$T/$name.trace" &
  CLIENT_PID=$!
  wait_for '[[ -e $(ls -d '"$RUN"'/req.* 2>/dev/null | head -1)/started ]]' 60
  w=$(win_of "fzf-menu-server-$slot")
  MENU_WIN=$w; [[ -n $w ]] || echo "# no window for slot $slot" >&2
  wait_for '[[ $(screen_of '"$w"') == *"[I]"* ]]' 100
}
close_menu() { # keys... ; waits for the client, sets RC
  local k
  for k in "$@"; do tmux -L "$S" send-keys -t "$MENU_WIN" "$k"; sleep 0.1; done
  wait "$CLIENT_PID"
  RC=$?
}

# ── case 1: first request is hot, slot a serves it, one toggle, standby b appears ──
echo "== case 1: hot request on slot a =="
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo && -r '"$RUN"'/server.pid ]]' 100
expect "server a is up (fifo, pid, slot file)" test "$(active_slot)" = a
PID_A=$(cat "$RUN/server.pid")
open_menu m1
close_menu Enter
expect "request 1: chosen row is printed, status 0" test "$RC" = 0 -a "$(cat "$T/m1.out")" = 1
expect "request 1 was hot" grep -q 'hot=1' "$T/m1.trace"
expect "request 1: exactly one toggle_special(menu-a), none for menu-b" test "$(count_log 'toggle_special("menu-a")')" = 1 -a "$(count_log 'toggle_special("menu-b")')" = 0
expect "request 1: no resize / no_anim when the window already has the target size" test "$(count_log 'resize')" = 0 -a "$(count_log 'no_anim')" = 0
expect "the slot a server is gone after its one request" bash -c '! kill -0 '"$PID_A"' 2>/dev/null'
expect "standby of slot b was started" wait_for '[[ $(count_term fzf-menu-server-b) -ge 1 ]]' 60

# ── case 2: request 2 is served by b, which then starts a standby a ──
if ((!QUICK)); then
  echo "== case 2: second request on slot b =="
  wait_for '[[ $(active_slot) = b && -r '"$RUN"'/server.pid ]]' 100
  echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-99,"name":"special:menu-b"}}]' >"$FT_DIR/clients.json"
  A_BEFORE=$(count_term fzf-menu-server-a)
  open_menu m2
  close_menu Enter
  expect "request 2 was hot and served by slot b" bash -c 'grep -q hot=1 "$1/m2.trace" && [[ $2 = 1 ]]' _ "$T" "$(count_log 'toggle_special("menu-b")')"
  expect "request 2: standby of slot a was started again" wait_for '[[ $(count_term fzf-menu-server-a) -gt '"$A_BEFORE"' ]]' 60
fi

# ── case 3: --size large resizes + centres inside one eval with no_anim around it ──
echo "== case 3: --size large =="
wait_for '[[ -r '"$RUN"'/server.pid ]]' 100
slot=$(active_slot)
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-99,"name":"special:menu-'"$slot"'"}}]' >"$FT_DIR/clients.json"
: >"$FT_DIR/hypr.log"
open_menu m3 --size large
close_menu Enter
[[ -n ${FT_DEBUG:-} ]] && cat "$FT_DIR/hypr.log"
chunk=$(grep -c 'EVAL' "$FT_DIR/hypr.log")
expect "large: ONE eval for the whole show" test "$chunk" = 1
expect "large: chunk has no_anim 1 ... resize 85% x 85% ... center ... no_anim unset" bash -c '
  l=$(cat "$1/hypr.log"); [[ $l == *"no_anim"*"value = \"1\""* && $l == *"resize({ x = 1632, y = 1020"* && $l == *"center("* && $l == *"value = \"unset\""* ]]' _ "$T/ft"
expect "large: toggle is inside the same chunk, between the two set_prop calls" bash -c '
  l=$(cat "$1/hypr.log"); a=${l%%toggle_special*}; [[ $a == *"value = \"1\""* && $a != *unset* && ${l#*toggle_special} == *resize*unset* ]]' _ "$T/ft"
expect "large menu still hot" grep -q 'hot=1' "$T/m3.trace"

# ── case 4: window modes pass --no-clear to fzf, --here does not ──
echo "== case 4: --no-clear =="
rm -f "$FT_DIR/fzf.log"
(
  # a runtime directory of its own: no server and no standby exist there, so the request takes the cold path
  mkdir -p "$T/xdg4" && chmod 700 "$T/xdg4"
  export XDG_RUNTIME_DIR="$T/xdg4" PATH="$HERE/fakefzf:$PATH" FZF_MENU_NO_SERVER=1
  seq 3 | "$FM" --cold -p cold-test >"$T/cold.out" 2>&1
  FZF_MENU_HERE=1 "$FM" -p here-test < <(seq 3) >"$T/here.out" 2>&1
)
expect "cold window mode: fzf got --no-clear" bash -c 'awk "/^---\$/{n++} n==0" "$1/fzf.log" | grep -qx -- "--no-clear"' _ "$T/ft"
expect "--here: fzf got no --no-clear" bash -c 'awk "/^---\$/{n++} n==1" "$1/fzf.log" | grep -qx -- "--no-clear" && exit 1; exit 0' _ "$T/ft"
expect "--here ran in this terminal (two fzf runs logged)" test "$(grep -c '^---$' "$FT_DIR/fzf.log")" = 2

# ── case 5: Esc cancels, toggle closes the open menu ──
if ((!QUICK)); then
  echo "== case 5: Esc and toggle =="
  tmux -L "$S" kill-server 2>/dev/null
  tmux -L "$S" -f /dev/null new-session -d -s main -x 110 -y 30 'sleep 600'
  rm -rf "$RUN"; reset_logs
  "$FM" --server-start
  wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
  open_menu m5
  close_menu Escape Escape
  expect "Esc Esc: status 1, no output" test "$RC" = 1 -a -z "$(cat "$T/m5.out")"
  wait_for '[[ -r '"$RUN"'/server.pid ]]' 100
  open_menu m6
  # a second call while the menu is open closes it (the first caller gets status 1)
  "$FM" -p m6 < <(seq 2) >/dev/null 2>&1
  wait "$CLIENT_PID"
  expect "second call closes the open menu (first caller: status 1)" test "$?" = 1
fi

# ── case 6: the modal self-test ──
if ((!QUICK)); then
  echo "== case 6: --self-test =="
  expect "fzf-menu --self-test is green" bash -c '"$1" --self-test >/dev/null 2>&1' _ "$FM"
fi

echo
echo "fzf-menu tests: $passes passed, $fails failed"
((fails == 0))
