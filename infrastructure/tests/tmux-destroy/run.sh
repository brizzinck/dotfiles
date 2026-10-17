#!/usr/bin/env bash
# Offline test of the tmux `session-created` hook: every term-* session gets destroy-unattached on (closing the ghostty window
# destroys it), every other session keeps the default. The hook line is read from .config/tmux/tmux.conf and loaded into a
# private tmux server (-L); clients are attached through `script`. Nothing of the live tmux server is touched.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
CONF="$REPO/.config/tmux/tmux.conf"
SOCK="tmux-destroy-test-$$"
T=$(mktemp -d)
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  pkill -f "tmux -L $SOCK" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }

command -v tmux >/dev/null && command -v script >/dev/null || { echo "tmux/script missing: skipped"; exit 0; }
tm() { tmux -L "$SOCK" "$@"; }

grep -E '^set-hook -g session-created ' "$CONF" >"$T/hook.conf"
expect "tmux.conf has a session-created hook" test -s "$T/hook.conf"
tmux -L "$SOCK" -f /dev/null new-session -d -s anchor
tm source-file "$T/hook.conf"

# attach(name): a client the way SUPER+Return makes one (new-session -s NAME, not detached)
attach() {
  local name=$1
  tail -f /dev/null | script -qfc "tmux -L $SOCK new-session -s $name" /dev/null >/dev/null 2>&1 &
  for _ in $(seq 1 50); do tm has-session -t "=$name" 2>/dev/null && break; sleep 0.1; done
}
attach term-1111
attach term-2222
attach work
opt() { tm list-sessions -F "#{session_name} #{destroy-unattached}" 2>/dev/null | awk -v s="$1" '$1 == s { print $2 }'; }
expect "term-1111 destroy-unattached on" test "$(opt term-1111)" = on
expect "term-2222 destroy-unattached on" test "$(opt term-2222)" = on
expect "named session keeps the default (off)" test "$(opt work)" = off
expect "the session that existed before the hook keeps the default" test "$(opt anchor)" = off

tm detach-client -s term-1111
tm detach-client -s work
sleep 0.5
expect "detaching a term-* session destroys it" bash -c "! tmux -L $SOCK has-session -t =term-1111"
expect "term-* with a client stays" tm has-session -t =term-2222
expect "detaching a named session keeps it" tm has-session -t =work

# the detached-terminal cleanup (kill-session.sh --detached): lists only unattached term-*, with their foreground commands,
# kills only the picked row. A fake menu picks the row that runs "mytool"; TMUX_TMPDIR keeps the default socket private.
export TMUX_TMPDIR="$T/tmp"; mkdir -p "$TMUX_TMPDIR"
unset TMUX
tmux -f /dev/null new-session -d -s term-d1 "exec -a mytool sleep 300"
tmux new-session -d -s term-d2 "exec -a idle sleep 300"
tmux new-session -d -s plain-d3
export TERMPROCS_TMUX="tmux"
rows=$(python3 "$REPO/.config/hypr/scripts/term-procs.py" --detached)
expect "--detached lists the unattached term-* sessions only" test "$(printf '%s\n' "$rows" | cut -f1 | sort | tr '\n' ' ')" = "term-d1 term-d2 "
expect "--detached shows the foreground command" bash -c "printf '%s\n' \"$rows\" | grep -q '^term-d1.*mytool\$'"
printf '#!/bin/sh\ngrep mytool | head -1\n' >"$T/menu"; chmod +x "$T/menu"
printf 'y\n' | KILL_SESSION_MENU="$T/menu" bash "$REPO/.config/tmux/scripts/kill-session.sh" --detached >/dev/null 2>&1
expect "the picked detached session is killed" bash -c "! tmux has-session -t =term-d1"
expect "the other detached term-* session is kept" tmux has-session -t =term-d2
expect "a non-term session is kept" tmux has-session -t =plain-d3
printf 'n\n' | KILL_SESSION_MENU="$T/menu" bash "$REPO/.config/tmux/scripts/kill-session.sh" --detached >/dev/null 2>&1
expect "nothing picked, nothing killed" tmux has-session -t =term-d2
tmux kill-server 2>/dev/null

echo "tmux-destroy: $fails failed"
[ "$fails" = 0 ]
