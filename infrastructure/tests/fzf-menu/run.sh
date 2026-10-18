#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline test of fzf-menu's one-shot server terminals: slots a/b, standby hand-over, hot-path request flow, the Lua chunk that shows
# the window (geometry only when it differs), --no-clear in window modes, Esc / Enter / toggle, and the modal self-test.
# Fakes: hyprctl (canned JSON, logs every eval), the terminal (FZF_MENU_TERMINAL: starts the command in a window of a private tmux
# server), fzf (case 4). The owner's Hyprland, menus and clipboard are never touched (XDG_RUNTIME_DIR is a scratch directory).
#   run.sh [--quick]   --quick (doctor) = cases 1, 3, 4, 5a (dead serving window), 5e (window switcher), 5g, 7a (hidden menu) and 8a (standby ordering)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
FM="${FZF_MENU_UNDER_TEST:-$REPO/.local/bin/fzf-menu}"   # FZF_MENU_UNDER_TEST: run the suite against another copy (an older version)
QUICK=0
[[ ${1:-} == --quick ]] && QUICK=1
for c in tmux fzf jq; do command -v "$c" >/dev/null || { echo "SKIP: tmux, fzf and jq are required"; exit 0; }; done

T=$(mktemp -d "${TMPDIR:-/tmp}/fzfmenu-test.XXXXXX")
S="fzfmenu-test-$$"
fails=0 passes=0
SOCKS=("$S")
cleanup() {
  local s
  [[ -r $T/xdg/fzf-menu/server.pid ]] && kill "$(cat "$T/xdg/fzf-menu/server.pid")" 2>/dev/null
  for s in "${SOCKS[@]}"; do tmux -L "$s" kill-server 2>/dev/null; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$s"; done   # kill-server leaves the socket file behind
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
reset_logs() { : >"$FT_DIR/term.log"; : >"$FT_DIR/hypr.log"; rm -f "$FT_DIR/shown" "$FT_DIR/hide" "$FT_DIR/map-hide.log" "$FT_DIR"/ws-menu-*; }
reset_logs
# a 1920x1200 monitor at scale 1; the server window already has the normal menu size (60% x 65%) on it
echo '[{"id":0,"name":"eDP-1","focused":true,"width":1920,"height":1200,"scale":1.0}]' >"$FT_DIR/monitors.json"
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-98,"name":"special:menu-a"}}]' >"$FT_DIR/clients.json"
echo '{"address":"0xprev","class":"x","title":"x"}' >"$FT_DIR/activewindow.json"
tmux -L "$S" -f /dev/null new-session -d -s main -x 110 -y 30 'sleep 600'

# the window (tmux id) the last terminal with this title opened
win_of() { awk -F'\t' -v t="$1" '$1 == t { id = $2 } END { print id }' "$FT_DIR/term.log"; }
screen_of() { tmux -L "$S" capture-pane -p -t "${1:-}" 2>/dev/null; }
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
  MENU_WIN=$w
  [[ -n $w ]] || { echo "# no window for slot $slot" >&2; return 1; }
  wait_for '[[ $(screen_of '"$w"') == *"[I]"* ]]' 100
}
close_menu() { # keys... ; waits for the client, sets RC
  local k
  for k in "$@"; do
    tmux -L "$S" send-keys -t "$MENU_WIN" "$k"
    # an Escape from INSERT is finished when the tag says NORMAL: the next key must not arrive inside fzf's escape delay (a fixed
    # 0.1 s pause flaked under load: the two Escapes were read as one sequence)
    if [[ $k == Escape && $(screen_of "$MENU_WIN") == *"[I]"* ]]; then wait_for '[[ $(screen_of '"$MENU_WIN"') == *"[N]"* ]]' 60; fi
    sleep 0.1
  done
  wait "$CLIENT_PID"
  RC=$?
}

# ── case 1: first request is hot, slot a serves it, one toggle, standby b appears ──
echo "== case 1: hot request on slot a =="
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo && -r '"$RUN"'/server.pid ]]' 100
expect "server a is up (fifo, pid, slot file)" test "$(active_slot)" = a
PID_A=$(cat "$RUN/server.pid")
A_AT_START=$(count_term fzf-menu-server-a)
open_menu m1
close_menu Enter
expect "request 1: chosen row is printed, status 0" test "$RC" = 0 -a "$(cat "$T/m1.out")" = 1
expect "request 1 was hot" grep -q 'hot=1' "$T/m1.trace"
[[ -n ${FT_TRACE:-} ]] && echo "TRACE $(tr '\n' ' ' <"$T/m1.trace")"   # latency numbers: t0 -> server_got / shown / list_start (ms)
expect "request 1: exactly one toggle_special(menu-a), none for menu-b" test "$(count_log 'toggle_special("menu-a")')" = 1 -a "$(count_log 'toggle_special("menu-b")')" = 0
expect "request 1: no resize / no_anim when the window already has the target size" test "$(count_log 'resize')" = 0 -a "$(count_log 'no_anim')" = 0
expect "the slot a server is gone after its one request" bash -c '! kill -0 '"$PID_A"' 2>/dev/null'
expect "standby of slot b was started (by the parked server a, before any menu)" wait_for '[[ $(count_term fzf-menu-server-b) -ge 1 ]]' 60

# ── case 2: request 2 is served by b, which then starts a standby a ──
if ((!QUICK)); then
  echo "== case 2: second request on slot b =="
  wait_for '[[ $(active_slot) = b && -r '"$RUN"'/server.pid ]]' 100
  echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-99,"name":"special:menu-b"}}]' >"$FT_DIR/clients.json"
  open_menu m2
  close_menu Enter
  expect "request 2 was hot and served by slot b" bash -c 'grep -q hot=1 "$1/m2.trace" && [[ $2 = 1 ]]' _ "$T" "$(count_log 'toggle_special("menu-b")')"
  expect "request 2: standby of slot a was started again (when b became the active server)" wait_for '[[ $(count_term fzf-menu-server-a) -gt '"$A_AT_START"' ]]' 60
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

# ── fresh environment per case: a private tmux server (own socket, a killed server cannot be restarted on the same name at once),
# an empty runtime directory, empty logs ──
CASEN=0
fresh() {
  local old=$S
  [[ -r $RUN/server.pid ]] && kill "$(cat "$RUN/server.pid")" 2>/dev/null
  tmux -L "$old" kill-server 2>/dev/null
  CASEN=$((CASEN + 1))
  S="fzfmenu-test-$$-$CASEN"
  SOCKS+=("$S")
  export FT_SOCK=$S
  tmux -L "$S" -f /dev/null new-session -d -s main -x 110 -y 30 'sleep 600'
  rm -rf "$RUN"
  reset_logs
  echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-98,"name":"special:menu-a"}}]' >"$FT_DIR/clients.json"
}
# wait_client SECONDS: waits for CLIENT_PID, sets RC; returns 1 when it still runs after the time (and kills it)
wait_client() {
  local i
  for ((i = 0; i < $1 * 20; i++)); do
    kill -0 "$CLIENT_PID" 2>/dev/null || { wait "$CLIENT_PID"; RC=$?; return 0; }
    sleep 0.05
  done
  kill "$CLIENT_PID" 2>/dev/null
  wait "$CLIENT_PID" 2>/dev/null
  RC=-1
  return 1
}
standby_held() { ! ( exec 6>"$RUN/standby.lock"; flock -n 6 ); }
new_server() { # SLOT: a hidden server terminal of that slot, started the way spawn_slot does
  ( cd "$T" && "$FZF_MENU_TERMINAL" --class=float.tui --title="fzf-menu-server-$1" -e "$FM" --server "$1" >/dev/null 2>&1 & )
}

# ── case 5: Esc cancels, toggle closes the open menu (every check also proves the menu really opened on the hot path) ──
if ((!QUICK)); then
  echo "== case 5: Esc and toggle =="
  fresh
  "$FM" --server-start
  wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
  expect "5: the server is up" test -p "$RUN/server.fifo"
  open_menu m5
  expect "5: the menu window exists and shows the list" test -n "$MENU_WIN" -a "$(screen_of "$MENU_WIN" | grep -c '\[I\]')" -ge 1
  close_menu Escape Escape
  expect "Esc Esc: status 1, no output" test "$RC" = 1 -a -z "$(cat "$T/m5.out")"
  expect "5: ... and the request was hot (the menu really ran in the server window)" grep -q 'hot=1' "$T/m5.trace"
  wait_for '[[ -r '"$RUN"'/server.pid ]]' 100
  open_menu m6
  expect "5: the second menu opened too (window of the standby)" test -n "$MENU_WIN"
  # a second call while the menu is open closes it (the first caller gets status 1)
  "$FM" -p m6 < <(seq 2) >/dev/null 2>&1
  wait "$CLIENT_PID"
  expect "second call closes the open menu (first caller: status 1)" test "$?" = 1
fi

# ── case 5a (HIGH #1): the serving window is closed after the standby is up: the client must return, and the next menu works ──
echo "== case 5a: the serving window dies while the standby waits =="
fresh
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu m5a
KILL_WIN=$MENU_WIN
wait_for '[[ $(count_term fzf-menu-server-b) -ge 1 ]] && standby_held' 100
expect "5a: the standby of slot b is waiting" standby_held
tmux -L "$S" kill-window -t "$KILL_WIN"          # SUPER+W on the menu window
wait_client 4
expect "5a: the client returns within 4 s (old code: waits for ever)" test "$RC" != -1
expect "5a: ... as cancelled (1), the request is not run again cold" test "$RC" = 1 -a "$(grep -c '^fzf-menu-server' "$FT_DIR/term.log")" -le 3
wait_for '[[ -r '"$RUN"'/server.pid && $(active_slot) = b ]]' 100
open_menu m5b
close_menu Enter
expect "5a: the next menu works at once (status 0, chosen row printed)" test "$RC" = 0 -a "$(cat "$T/m5b.out")" = 1
expect "5a: ... served hot by the standby" grep -q 'hot=1' "$T/m5b.trace"

if ((!QUICK)); then
# ── case 5c (MED #3): the cold menu's background server spawn does not keep menu.lock; a detached app of the menu does not either ──
echo "== case 5c: menu.lock is released =="
fresh
export FZF_MENU_NORMAL_BINDS='x:execute-silent(setsid sleep 31337 </dev/null >/dev/null 2>&1 &)'
FZF_MENU_TRACE=1 "$FM" --cold -p c5c < <(seq 3) >"$T/c5c.out" 2>"$T/c5c.trace" &
CLIENT_PID=$!
wait_for '[[ -n $(win_of "menu: c5c") ]]' 100
MENU_WIN=$(win_of "menu: c5c")
wait_for '[[ $(screen_of '"$MENU_WIN"') == *"[I]"* ]]' 100
tmux -L "$S" send-keys -t "$MENU_WIN" Escape; sleep 0.4     # NORMAL mode is switched by an fzf transform: give it time
tmux -L "$S" send-keys -t "$MENU_WIN" x; sleep 0.5
close_menu Escape
unset FZF_MENU_NORMAL_BINDS
SLEEPER=$(pgrep -f '^sleep 31337$' | head -1)
expect "5c: the menu action started a detached process" test -n "$SLEEPER"
expect "5c: a detached app of a cold menu does not hold menu.lock" bash -c 'exec 9>"$1/menu.lock"; flock -n 9' _ "$RUN"
[[ -n $SLEEPER ]] && kill "$SLEEPER" 2>/dev/null
# the spawn after a cold menu (sleeps 2 s) is in the background: the lock must be free while it runs
expect "5c: the background server spawn does not hold menu.lock (a menu right after a cold one is not swallowed)" bash -c 'exec 9>"$1/menu.lock"; flock -n 9' _ "$RUN"
expect "5c: ... and the spawn really is still running at that moment (it holds spawn.lock for 2 s)" bash -c '! { exec 9>"$1/spawn.lock"; flock -n 9; }' _ "$RUN"
fi

if ((!QUICK)); then
# ── case 5i (LOW #9): a detached app started from a menu of the hidden server inherits none of the lock / fifo descriptors ──
echo "== case 5i: descriptors of a server menu =="
fresh
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
export FZF_MENU_NORMAL_BINDS='x:execute-silent(setsid sleep 31338 </dev/null >/dev/null 2>&1 &)'
open_menu m5i
unset FZF_MENU_NORMAL_BINDS
tmux -L "$S" send-keys -t "$MENU_WIN" Escape; sleep 0.4
tmux -L "$S" send-keys -t "$MENU_WIN" x; sleep 0.5
close_menu Escape
SLEEPER=$(pgrep -f '^sleep 31338$' | head -1)
expect "5i: the menu action started a detached process" test -n "$SLEEPER"
expect "5i: it holds no fifo, lock or request descriptor of fzf-menu (old code: server.lock, fifo, ...)" \
  test "$(for f in /proc/"${SLEEPER:-0}"/fd/*; do readlink "$f"; done 2>/dev/null | grep -c 'fzf-menu/')" = 0
[[ -n $SLEEPER ]] && kill "$SLEEPER" 2>/dev/null
fi

if ((!QUICK)); then
# ── case 5d (MED #4): a second terminal of the same slot does not stay (one window per slot) ──
echo "== case 5d: one terminal per slot =="
fresh
mkdir -p "$RUN" && chmod 700 "$RUN"
new_server a
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
new_server a
sleep 1.2
expect "5d: only one window of slot a is left (old code: the second one waits as a standby of the same slot)" \
  test "$(tmux -L "$S" list-windows -F '#{window_name}' | grep -c '^fzf-menu-server-a$')" = 1
fi

# ── case 5e (MED #5): the window switcher does not list the hidden menu terminals ──
echo "== case 5e: window switcher =="
mkdir -p "$T/ft5"
echo '[{"id":0,"name":"eDP-1","focused":true,"width":1920,"height":1200,"scale":1.0}]' >"$T/ft5/monitors.json"
cat >"$T/ft5/clients.json" <<'JSON'
[{"address":"0x1","mapped":true,"workspace":{"id":1,"name":"1"},"focusHistoryID":0,"monitor":0,"class":"ghostty","title":"term","pid":5},
 {"address":"0x2","mapped":true,"workspace":{"id":-98,"name":"special:menu-a"},"focusHistoryID":1,"monitor":0,"class":"float.tui","title":"fzf-menu-server-a","pid":6},
 {"address":"0x3","mapped":true,"workspace":{"id":-99,"name":"special:menu-b"},"focusHistoryID":2,"monitor":0,"class":"float.tui","title":"fzf-menu-server-b","pid":7},
 {"address":"0x4","mapped":true,"workspace":{"id":-97,"name":"special:menu"},"focusHistoryID":3,"monitor":0,"class":"float.tui","title":"fzf-menu-server","pid":8},
 {"address":"0x5","mapped":true,"workspace":{"id":2,"name":"2"},"focusHistoryID":4,"monitor":0,"class":"float.tui","title":"menu: pick","pid":9},
 {"address":"0x6","mapped":true,"workspace":{"id":2,"name":"2"},"focusHistoryID":5,"monitor":0,"class":"float.tui","title":"hub","pid":10}]
JSON
SW=$(FT_DIR="$T/ft5" "$REPO/.config/hypr/scripts/window-switcher.sh" --list)
expect "5e: only the real windows are listed (the terminal and the hub; no standby a / b, no old server, no open menu)" \
  test "$(cut -f1 <<<"$SW" | sort | tr '\n' ' ')" = "0x1 0x6 "

if ((!QUICK)); then
# ── case 5f (MED #6): a request a client already gave up on is skipped by the server (no second menu); the next request works ──
echo "== case 5f: abandoned request =="
fresh
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
req=$(mktemp -d "$RUN/req.XXXXXX")
seq 3 >"$req/in"
printf 'PROMPT=x\nTITLE=x\nNORESTORE=1\nSIZE=normal\nFZF_ARGS=()\n' >"$req/cfg"
: >"$req/env"
mkdir "$req/owner"                                # the client's claim: it went cold with this request
printf '%s\n' "$req" >"$RUN/server.fifo"
sleep 0.6
expect "5f: the server did not start the abandoned request (old code: started + a second menu)" test ! -e "$req/started" -a ! -e "$req/rc"
expect "5f: the server is still waiting" test -p "$RUN/server.fifo" -a -r "$RUN/server.pid"
open_menu m5f
close_menu Enter
expect "5f: the next request is served, status 0" test "$RC" = 0 -a "$(cat "$T/m5f.out")" = 1
expect "5f: ... hot, by the same server" grep -q 'hot=1' "$T/m5f.trace"
fi

if ((!QUICK)); then
# ── case 5j (FIX3 F2): the server won the claim but stalls before `started`: the client waits, never a second (cold) menu ──
echo "== case 5j: lost claim =="
claim_case() { # MODE slow|die: a fake server that wins `mkdir owner`, then stalls 1.8 s (slow) or dies (die)
  local mode=$1
  fresh
  mkdir -p "$RUN" && chmod 700 "$RUN"
  mkfifo "$RUN/server.fifo"
  sleep 600 & SP=$!
  echo "$SP" >"$RUN/server.pid"
  (
    exec 3<>"$RUN/server.fifo"
    read -r -u 3 rq
    mkdir "$rq/owner"
    if [[ $mode == takeover ]]; then
      # the claimant dies after the client lost the claim (0.5 s), and a DIFFERENT live process takes over server.pid (a standby
      # that became the server): the old loop followed the file and waited for ever
      sleep 1.2
      kill "$SP"
      sleep 600 & echo "$!" >"$RUN/server.pid"; echo "$!" >"$T/sp2.pid"
      sleep 3
    elif [[ $mode == stall ]]; then
      sleep 4                                  # alive, never writes `started`: only the bound ends the wait
    elif [[ $mode == slow ]]; then
      sleep 1.8
      echo "$BASHPID" >"$rq/started.tmp" && mv -f "$rq/started.tmp" "$rq/started"
      echo picked >"$rq/out"; echo 0 >"$rq/rc"; echo finished 1<>"$rq/done"   # O_RDWR: a plain write blocks on a fifo nobody reads
      sleep 0.3
    else
      kill "$SP"
      sleep 0.2
    fi
  ) &
  CLAUSER=$!
  FZF_MENU_NO_SERVER=1 "$FM" -p t5j < <(seq 3) >"$T/m5j.out" 2>/dev/null &
  CLIENT_PID=$!
  wait_client 6 || tmux -L "$S" kill-server 2>/dev/null   # a client that went cold waits for its fake terminal: let that end too
  wait "$CLAUSER" 2>/dev/null
  kill "$SP" 2>/dev/null
}
claim_case slow
expect "5j: a slow server that owns the request is waited for: its answer comes back (old code: gave up after 1 s)" test "$RC" = 0 -a "$(cat "$T/m5j.out")" = picked
expect "5j: ... and no cold menu was opened (old code: a second window)" test ! -s "$FT_DIR/term.log"
FZF_MENU_CLAIM_WAIT=20 claim_case takeover
expect "5j: the wait watches the pid read at the lost claim, not a new server.pid (old code: waits for ever)" test "$RC" = 1 -a ! -s "$T/m5j.out"
expect "5j: ... no cold menu either" test ! -s "$FT_DIR/term.log"
kill "$(cat "$T/sp2.pid")" 2>/dev/null
FZF_MENU_CLAIM_WAIT=2 claim_case stall
expect "5j: a server that stays alive but never starts is given up on after the bound (old code: waits for ever)" test "$RC" = 1 -a ! -s "$T/m5j.out"
# FIX-DEVb2 #7: FZF_MENU_CLAIM_WAIT is read as arithmetic by bash: a value that is not a number made the wait 0 s (the client gave
# up on a server that was only slow) or an arithmetic error; anything but 1-9999 seconds is the default (30 s)
rm -f "$T/claim-injected"
for bad in abc -5 2.5 "x[\$(touch $T/claim-injected)]"; do
  FZF_MENU_CLAIM_WAIT="$bad" claim_case slow
  expect "5j: FZF_MENU_CLAIM_WAIT='$bad' is the default wait: the slow server is still waited for (old code: gave up at once or failed)" test "$RC" = 0 -a "$(cat "$T/m5j.out")" = picked
done
expect "5j: ... and the payload ran nothing" test ! -e "$T/claim-injected"
claim_case die
expect "5j: a server that died holding the claim = cancelled (status 1, no output)" test "$RC" = 1 -a ! -s "$T/m5j.out"
expect "5j: ... and no cold menu was opened (old code: the same request ran again cold)" test ! -s "$FT_DIR/term.log"

# ── case 5k (FIX5 #2): the client already closed its end of the `done` fifo when the server reports `finished`: the server must still
# exit (a write-only open of a fifo nobody reads blocks for ever: the server and its window stayed, holding the slot lock) ──
echo "== case 5k: finished with no reader =="
fresh
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
req=$(mktemp -d "$RUN/req.XXXXXX")
seq 5 >"$req/in"
printf '%s\n' 'declare -- PROMPT="t5k"' 'declare -- TITLE="t5k"' 'declare -- NORESTORE="1"' 'declare -- SIZE="normal"' 'declare -a FZF_ARGS=()' >"$req/cfg"
env -0 >"$req/env"
mkfifo "$req/done"
exec 8<>"$req/done"
printf '%s\n' "$req" >"$RUN/server.fifo"
wait_for '[[ -e '"$req"'/started ]]' 100
W5K=$(win_of "fzf-menu-server-a")
wait_for '[[ $(screen_of '"$W5K"') == *"[I]"* ]]' 100
exec 8>&-                                          # the client gave up (its 0.5 s read timed out) before the server said `finished`
tmux -L "$S" send-keys -t "$W5K" Enter
wait_for '[[ -e '"$req"'/rc ]]' 60
SP5K=$(cat "$req/started")
expect "5k: the answer was served (rc 0, row 1)" test "$(cat "$req/rc" 2>/dev/null)" = 0 -a "$(cat "$req/out" 2>/dev/null)" = 1
wait_for '! kill -0 '"$SP5K"' 2>/dev/null' 60
expect "5k: the server process exits although nobody reads the done fifo (old code: blocks in open for ever)" bash -c "! kill -0 $SP5K 2>/dev/null"
kill "$SP5K" 2>/dev/null
rm -rf "$req"
fi

# ── case 5g (LOW #10): a standby that meets the probe lock for a moment waits for it instead of exiting ──
echo "== case 5g: standby vs probe =="
fresh
mkdir -p "$RUN" && chmod 700 "$RUN"
( exec 6>"$RUN/standby.lock"; flock 6; sleep 0.18 ) &
new_server b
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 40
expect "5g: the server came up (old code: it exited on the probe lock)" test -p "$RUN/server.fifo"
wait

if ((!QUICK)); then
# ── case 5h (LOW #11): no window found = only the toggle, no `address:` dispatch ──
echo "== case 5h: window not found =="
fresh
export FZF_MENU_SERVER_ADDR=
echo '[]' >"$FT_DIR/clients.json"
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu m5h --size large
close_menu Enter
export FZF_MENU_SERVER_ADDR=0xserver
expect "5h: toggle_special still happens" test "$(count_log 'toggle_special("menu-a")')" = 1
expect "5h: no dispatcher with an empty address (old code: set_prop / resize / center on \"address:\")" test "$(count_log 'address:"')" = 0
fi

# ── case 7 (FIX-MENU2): a menu that is open but hidden (another window took the focus, Hyprland hid its special workspace) ──
# fake hyprctl: `$FT_DIR/hide` present = no monitor shows the menu window; fake-events.py = the Hyprland event socket (socket2)
hide_menu() { echo "${1:-99}" >"$FT_DIR/hide"; }
show_menu() { rm -f "$FT_DIR/hide"; }
ev() { echo "$1" >"$T/ev.fifo"; }
start_events() { # the event socket of the fake instance (wait_conn: a watcher connected)
  rm -f "$T/ev.fifo" "$T/ev.conn"; mkfifo "$T/ev.fifo"; : >"$T/ev.conn"; EVSEEN=0
  "$HERE/bin/fake-events.py" "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" "$T/ev.fifo" "$T/ev.conn" &
  EVPID=$!
  wait_for '[[ -S '"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE"'/.socket2.sock ]]' 60
}
stop_events() { [[ -n ${EVPID:-} ]] && kill "$EVPID" 2>/dev/null; wait "$EVPID" 2>/dev/null; EVPID=""; rm -rf "$XDG_RUNTIME_DIR/hypr"; }
wait_conn() { wait_for '[[ $(wc -l <"'"$T"'/ev.conn") -gt ${EVSEEN:-0} ]]' 60; EVSEEN=$(wc -l <"$T/ev.conn"); }   # a NEW watcher connected to the event socket

echo "== case 7a: a second call while the open menu is hidden cancels it and opens a new one =="
fresh
show_menu
export FZF_MENU_HIDE_MS=60000                      # the watcher stays out of this case: only the toggle rule is tested
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu h1
OLD=$CLIENT_PID
expect "7a: the first menu is open and visible" test -n "$MENU_WIN"
wait_for 'standby_held' 100                        # the standby of slot b (250 ms after the menu opened) takes the new request
hide_menu
"$FM" -p h2 < <(seq 3) >"$T/h2.out" 2>"$T/h2.trace" &
NEW=$!
CLIENT_PID=$OLD
wait_client 6
expect "7a: the hidden menu's caller got 1 and no output" test "$RC" = 1 -a ! -s "$T/h1.out"
show_menu
wait_for '[[ -n $(win_of fzf-menu-server-b) ]]' 100
W7=$(win_of fzf-menu-server-b)
wait_for '[[ $(screen_of '"$W7"') == *"[I]"* ]]' 100
expect "7a: the new menu opened (window of the standby shows the list)" test "$(screen_of "$W7" | grep -c '\[I\]')" -ge 1
tmux -L "$S" send-keys -t "$W7" Enter
CLIENT_PID=$NEW
wait_client 6
expect "7a: the new call is answered normally (status 0, row 1)" test "$RC" = 0 -a "$(cat "$T/h2.out")" = 1
unset FZF_MENU_HIDE_MS

if ((!QUICK)); then
echo "== case 7b: a visible menu is still closed by the second call =="
fresh
show_menu
export FZF_MENU_HIDE_MS=60000
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu h3
TERMS_BEFORE=$(grep -c . "$FT_DIR/term.log")
"$FM" -p h3b < <(seq 2) >"$T/h3b.out" 2>&1
RC2=$?
CLIENT_PID=$CLIENT_PID wait_client 6
expect "7b: the second call exits 1 at once, the first caller got 1" test "$RC2" = 1 -a "$RC" = 1
expect "7b: ... and no new menu terminal was opened" test "$(grep -c . "$FT_DIR/term.log")" -le "$((TERMS_BEFORE + 1))"
unset FZF_MENU_HIDE_MS

echo "== case 7c: hidden for more than FZF_MENU_HIDE_MS cancels the menu (events) =="
fresh
show_menu
export FZF_MENU_HIDE_MS=1000
start_events
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu h4
wait_conn
expect "7c: the watcher listens on the event socket" test -s "$T/ev.conn"
T0=$(date +%s%N)
hide_menu
ev 'activespecialv2>>,,eDP-1'
wait_client 5
EL=$((($(date +%s%N) - T0) / 1000000))
expect "7c: cancelled (status 1, no output) after about a second (${EL} ms)" test "$RC" = 1 -a ! -s "$T/h4.out" -a "$EL" -ge 900 -a "$EL" -lt 4000
show_menu

echo "== case 7d: a short hide is kept =="
fresh
show_menu
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu h5
wait_conn
hide_menu
ev 'activespecialv2>>,,eDP-1'
sleep 0.4
show_menu
ev 'activespecialv2>>menu-a,special:menu-a,eDP-1'
sleep 2
expect "7d: still open after the flicker (old code and a too eager watcher: cancelled)" kill -0 "$CLIENT_PID"
tmux -L "$S" send-keys -t "$MENU_WIN" Enter
wait_client 6
expect "7d: ... and answered normally" test "$RC" = 0 -a "$(cat "$T/h5.out")" = 1

echo "== case 7e: a menu whose window has the focus is not cancelled =="
fresh
show_menu
# hyprctl prints hex addresses (the focus check reads one with a hex pattern): this case has a real-looking one
export FZF_MENU_SERVER_ADDR=0xa5e1
echo '[{"address":"0xa5e1","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-98,"name":"special:menu-a"}}]' >"$FT_DIR/clients.json"
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu h6
wait_conn
printf '{\n    "address": "0xa5e1",\n    "class": "float.tui"\n}\n' >"$FT_DIR/activewindow.json"   # hyprctl prints it indented
hide_menu
ev 'activewindowv2>>a5e1'
sleep 2.2
expect "7e: still open" kill -0 "$CLIENT_PID"
echo '{"address":"0xprev","class":"x","title":"x"}' >"$FT_DIR/activewindow.json"
show_menu
tmux -L "$S" send-keys -t "$MENU_WIN" Escape Escape
wait_client 6
stop_events
export FZF_MENU_SERVER_ADDR=0xserver
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-98,"name":"special:menu-a"}}]' >"$FT_DIR/clients.json"

echo "== case 7f: no event socket = polling every 500 ms =="
fresh
show_menu
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
open_menu h7
sleep 0.3
hide_menu
wait_client 6
expect "7f: cancelled by polling (status 1)" test "$RC" = 1 -a ! -s "$T/h7.out"
show_menu
unset FZF_MENU_HIDE_MS

echo "== case 7g: cold menu on a regular workspace: visible = toggle, hidden = cancelled and replaced =="
fresh
show_menu
export FZF_MENU_NO_SERVER=1
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":3,"name":"3"}}]' >"$FT_DIR/clients.json"
"$FM" --cold -p c7 < <(seq 3) >"$T/c7.out" 2>&1 &
CLIENT_PID=$!
wait_for '[[ -n $(win_of "menu: c7") ]]' 100
MENU_WIN=$(win_of "menu: c7")
wait_for '[[ $(screen_of '"$MENU_WIN"') == *"[I]"* ]]' 100
"$FM" --cold -p c7b < <(seq 2) >/dev/null 2>&1
RC2=$?
wait_client 6
expect "7g: visible cold menu: the second call closes it (both status 1, no second window)" test "$RC2" = 1 -a "$RC" = 1 -a -z "$(win_of "menu: c7b")"
"$FM" --cold -p c8 < <(seq 3) >"$T/c8.out" 2>&1 &
CLIENT_PID=$!
wait_for '[[ -n $(win_of "menu: c8") ]]' 100
MENU_WIN=$(win_of "menu: c8")
wait_for '[[ $(screen_of '"$MENU_WIN"') == *"[I]"* ]]' 100
hide_menu 99
OLD=$CLIENT_PID
"$FM" --cold -p c9 < <(seq 3) >"$T/c9.out" 2>&1 &
NEW=$!
CLIENT_PID=$OLD
wait_client 6
expect "7g: hidden cold menu: cancelled (status 1)" test "$RC" = 1 -a ! -s "$T/c8.out"
show_menu
wait_for '[[ -n $(win_of "menu: c9") ]]' 100
W9=$(win_of "menu: c9")
wait_for '[[ $(screen_of '"$W9"') == *"[I]"* ]]' 100
tmux -L "$S" send-keys -t "$W9" Enter
CLIENT_PID=$NEW
wait_client 6
expect "7g: ... and the new menu opened and was answered" test "$RC" = 0 -a "$(cat "$T/c9.out")" = 1
unset FZF_MENU_NO_SERVER
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-98,"name":"special:menu-a"}}]' >"$FT_DIR/clients.json"
fi

# ── case 8 (FIX-MENU2, the live bug): a standby is never mapped while a menu is shown ──
# Hyprland hides the special workspace a monitor shows when a window is mapped on a special workspace that does not exist yet.
# The fake models it (fake-term: map-hide.log + $FT_DIR/hide). The old code started the standby 250 ms after a menu opened: every
# hot menu vanished half a second later (waybar right click on the volume icon).
echo "== case 8a: no standby window appears while a menu is shown =="
fresh
show_menu
unset FZF_MENU_HIDE_MS
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
wait_for 'standby_held' 100                        # b is parked before the first menu
open_menu m8a
N_BEFORE=$(grep -c . "$FT_DIR/term.log")
sleep 1.3                                          # the old 250 ms standby spawn, and some time for a late one
expect "8a: no terminal was started while the menu is shown" test "$(grep -c . "$FT_DIR/term.log")" = "$N_BEFORE"
expect "8a: the shown menu was not hidden (old code: the standby mapped on a new special workspace)" test ! -e "$FT_DIR/hide" -a ! -s "$FT_DIR/map-hide.log"
expect "8a: ... and its caller still waits" kill -0 "$CLIENT_PID"
close_menu Enter
expect "8a: answered normally (status 0, row 1)" test "$RC" = 0 -a "$(cat "$T/m8a.out")" = 1

if ((!QUICK)); then
echo "== case 8b: a menu right after another one waits for the standby that is still on its way =="
fresh
show_menu
export FT_MAP_DELAY=0.3                            # a terminal needs 0.3 s until its window is mapped
"$FM" --server-start
wait_for '[[ -p '"$RUN"'/server.fifo ]]' 100
wait_for 'standby_held' 100
open_menu m8b1
close_menu Enter
# b took over and started the standby a' (its window maps 0.3 s later): the next menu is requested at once
wait_for '[[ $(active_slot) = b && -r '"$RUN"'/server.pid ]]' 100
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-99,"name":"special:menu-b"}}]' >"$FT_DIR/clients.json"
open_menu m8b2
sleep 1.2
expect "8b: the second menu was shown without being hidden by the late standby (old code / no wait: hidden)" test ! -e "$FT_DIR/hide" -a ! -s "$FT_DIR/map-hide.log"
expect "8b: ... it is on screen and waits" kill -0 "$CLIENT_PID"
expect "8b: ... and the standby a' did get its window (it is parked, ready for the third menu)" test "$(count_term fzf-menu-server-a)" -ge 2
close_menu Enter
expect "8b: answered normally" test "$RC" = 0 -a "$(cat "$T/m8b2.out")" = 1
unset FT_MAP_DELAY
echo '[{"address":"0xserver","size":[1152,780],"monitor":0,"pid":1,"class":"float.tui","workspace":{"id":-98,"name":"special:menu-a"}}]' >"$FT_DIR/clients.json"
fi

# ── case 6: the modal self-test ──
if ((!QUICK)); then
  echo "== case 6: --self-test =="
  expect "fzf-menu --self-test is green" bash -c '"$1" --self-test >/dev/null 2>&1' _ "$FM"
fi

echo
echo "fzf-menu tests: $passes passed, $fails failed"
((fails == 0))
