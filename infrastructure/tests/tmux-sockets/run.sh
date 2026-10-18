#!/usr/bin/env bash
# FIX3 F6: a test suite (or tool) that starts a private tmux server (-L name) must not leave the dead socket file behind
# (`kill-server` does not remove it: hundreds piled up in /tmp/tmux-UID). Each suite runs with its own empty TMUX_TMPDIR and the
# directory must hold no socket afterwards. Slow suites run in their quick variant; the live tmux server is never involved.
#   run.sh
set -u
export PYTHONDONTWRITEBYTECODE=1   # python3 -I ignores PYTHON* variables (hence -B there); this covers the other interpreters: no __pycache__ in the repo
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
command -v tmux >/dev/null || { echo "SKIP: tmux is required"; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
passes=0 fails=0
leftover() { find "$1" -type s 2>/dev/null | wc -l; }
case_run() { # NAME CMD...
  local name=$1 d out
  shift
  d="$T/$name"; mkdir -p -m 700 "$d"
  TMUX_TMPDIR="$d" PYTHONPYCACHEPREFIX="$T/pyc" "$@" >"$T/$name.log" 2>&1
  out=$(leftover "$d")
  if [ "$out" = 0 ]; then passes=$((passes + 1)); printf 'PASS  %s leaves no tmux socket file\n' "$name"
  else fails=$((fails + 1)); printf 'FAIL  %s left %s socket file(s): %s\n' "$name" "$out" "$(find "$d" -type s -printf '%f ' | head -c 200)"; fi
}
case_run safe-close "$REPO/infrastructure/tests/safe-close/run.sh"
case_run tmux-destroy "$REPO/infrastructure/tests/tmux-destroy/run.sh"
case_run fzf-menu-selftest "$REPO/.local/bin/fzf-menu" --self-test
case_run keymap-collector python3 -I -B "$REPO/.config/keymap/keymap.py" gen
printf 'tmux socket tests: %s passed, %s failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
