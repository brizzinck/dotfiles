#!/usr/bin/env bash
# The nvim orphan guard (.config/nvim/lua/configs/orphan_guard.lua): a TUI server whose client is gone and that has no UI ends,
# also when its main loop is blocked. Runs nvim with the real config in a private tmux server, never on the desktop.
# Cases: `:detach` (the server outlives its TUI with no UI) and `:detach` + a blocking system() (the stuck server of 2026-11-03),
# each once with --clean (no guard: must stay, proves the case) and once with the config (guard: must end, swap file kept).
# Run: infrastructure/tests/nvim-orphan/run.sh   (about 1 minute)
set -u
command -v nvim >/dev/null && command -v tmux >/dev/null || { echo "nvim-orphan tests: nvim or tmux missing, skipped"; exit 0; }
T="$(mktemp -d)"
SOCK="ccnv-orphan-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
  rm -rf "$T"
}
trap cleanup EXIT
unset WAYLAND_DISPLAY DISPLAY TMUX HYPRLAND_INSTANCE_SIGNATURE
export XDG_STATE_HOME="$T/state" NVIM_ORPHAN_GRACE=2
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

kill_tree() { # kill_tree PID: the process and its descendants (the blocked case leaves a system() child behind)
  local c
  for c in $(pgrep -P "$1"); do kill_tree "$c"; done
  kill -9 "$1" 2>/dev/null
}

run_case() { # run_case NAME FLAGS BLOCK WANT(stays|ends)
  local name=$1 flags=$2 block=$3 want=$4 f pp tui srv got
  f="f-$name.md"
  (cd "$T" && tmux -L "$SOCK" new-session -d -s "p-$name" -x 160 -y 40 "nvim $flags --listen $T/$name.sock $f; sleep 60")
  sleep 5
  pp=$(tmux -L "$SOCK" display -p -t "p-$name" '#{pane_pid}')
  tui=$(pgrep -P "$pp" -x nvim | head -1)
  srv=$(pgrep -P "${tui:-0}" -x nvim | head -1)
  [ -n "$srv" ] || { bad "$name: no nvim server started"; return; }
  tmux -L "$SOCK" send-keys -t "p-$name" 'ihello' Escape
  sleep 0.5   # Escape and ':' in one burst read as Alt-:
  tmux -L "$SOCK" send-keys -t "p-$name" ':detach' Enter
  sleep 0.5
  [ "$block" = 1 ] && timeout 2 nvim --headless --clean --server "$T/$name.sock" --remote-send ':call system("sleep 120")<CR>' >/dev/null 2>&1
  sleep 13
  if kill -0 "$srv" 2>/dev/null; then got=stays; else got=ends; fi
  [ "$got" = "$want" ] && ok || bad "$name: server $want expected, it $got"
  if [ "$want" = ends ]; then
    ls "$XDG_STATE_HOME/nvim/swap" 2>/dev/null | grep -q "$f" && ok || bad "$name: the swap file of the modified buffer is gone"
  fi
  pgrep -f "^sh -c .*nvim-orphan-guard.* $srv " >/dev/null && bad "$name: the watcher outlived the server" || ok
  kill_tree "$srv"
}

run_case detach-noguard --clean 0 stays
run_case detach-guard "" 0 ends
run_case blocked-noguard --clean 1 stays
run_case blocked-guard "" 1 ends

echo "nvim-orphan tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
