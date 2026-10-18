#!/usr/bin/env bash
# Offline test of SUPER+W for terminals (safe-close.sh + term-procs.py): a private tmux server (-L), a client attached through
# `script` (the fake "window"), fake hyprctl / hyprd / notify-send. Nothing of the live session is touched.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPTS="$REPO/.config/hypr/scripts"
T=$(mktemp -d)
SOCK="sc-test-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"   # kill-server leaves the socket file behind
  [ -n "${CLIENT_PID:-}" ] && kill "$CLIENT_PID" 2>/dev/null
  [ -n "${HOLD_PID:-}" ] && kill "$HOLD_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }

mkdir -p "$T/bin" "$T/run"
# label unit tests (no processes)
lab() { python3 "$SCRIPTS/term-procs.py" --label "$@"; }
expect "label: claude" test "$(lab claude --resume x)" = claude
expect "label: node + codex script" test "$(lab node /home/u/.npm-global/bin/codex)" = codex
expect "label: go test" test "$(lab go test ./...)" = "go test"
expect "label: env prefix" test "$(lab env A=1 cargo build)" = "cargo build"
expect "label: idle shell" test "$(lab -zsh)" = zsh

# a tmux server with: one idle shell, two "claude", one "nvim", one "go test"; the client runs under `script`
command -v tmux >/dev/null && command -v script >/dev/null || { echo "tmux/script missing: skipped"; exit 0; }
export TERMPROCS_TMUX="tmux -L $SOCK"
tm() { tmux -L "$SOCK" -f /dev/null "$@"; }
tm new-session -d -s term-t1 "bash --norc" 
for c in "exec -a claude sleep 300" "exec -a claude sleep 301" "exec -a nvim sleep 302" "exec -a mytool sleep 303"; do
  tm new-window -t term-t1 "bash --norc -c '$c'"
done
tail -f /dev/null | script -qfc "tmux -L $SOCK attach -t term-t1" /dev/null >/dev/null 2>&1 &
CLIENT_PID=$!
for _ in $(seq 1 50); do [ -n "$(tm list-clients 2>/dev/null)" ] && break; sleep 0.1; done
expect "a client is attached" test -n "$(tm list-clients 2>/dev/null)"
sleep 0.3
# the fake window pid = the `script` process (an ancestor of the tmux client)
WIN=$(pgrep -f "script -qfc tmux -L $SOCK attach" | head -1)
out=$(python3 "$SCRIPTS/term-procs.py" "$WIN")
IFS=$'\t' read -r kind session destroys attached summary <<<"$out"
expect "kind tmux and the session name" test "$kind:$session" = "tmux:term-t1"
expect "a session without destroy-unattached only detaches" test "$destroys" = 0
tm set-option -t term-t1 destroy-unattached on
out=$(python3 "$SCRIPTS/term-procs.py" "$WIN"); IFS=$'\t' read -r kind session destroys attached summary <<<"$out"
expect "destroy-unattached on = closes" test "$destroys" = 1

# safe-close.sh with fakes: first press warns, second press within the window closes
cat >"$T/bin/hyprctl" <<X
#!/bin/sh
echo '{"address":"0xabc","class":"com.mitchellh.ghostty","pid":$WIN}'
X
cat >"$T/bin/hyprd" <<'X'
#!/bin/sh
echo "hyprd $*" >>"$FAKE_LOG"
X
cat >"$T/bin/notify-send" <<'X'
#!/bin/sh
echo "notify $*" >>"$FAKE_LOG"
X
chmod +x "$T/bin"/*
export FAKE_LOG="$T/log" XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:$PATH"
: >"$FAKE_LOG"
"$SCRIPTS/safe-close.sh"
expect "first press warns with the summary" grep -q 'Closes term-t1: claude (2), nvim, mytool' "$FAKE_LOG"
expect "first press does not close" bash -c "! grep -q '^hyprd killactive' '$FAKE_LOG'"
"$SCRIPTS/safe-close.sh"
expect "second press closes" grep -q '^hyprd killactive' "$FAKE_LOG"
expect "--what prints the text" bash -c "[ \"\$('$SCRIPTS/safe-close.sh' --what)\" = 'Closes term-t1: claude (2), nvim, mytool' ]"

# only idle shells: the plain hint, as before
tm kill-window -t term-t1:1; tm kill-window -t term-t1:2; tm kill-window -t term-t1:3; tm kill-window -t term-t1:4
sleep 0.3
: >"$FAKE_LOG"; rm -f "$T/run/safe-close.state"
"$SCRIPTS/safe-close.sh"
expect "idle shells: the plain hint" grep -q 'Press SUPER+W again to close com.mitchellh.ghostty' "$FAKE_LOG"
expect "idle shells: no process list in the title" bash -c "! grep -q 'Closes' '$FAKE_LOG'"

echo "safe-close tests: $fails failure(s)"
exit $((fails > 0))
