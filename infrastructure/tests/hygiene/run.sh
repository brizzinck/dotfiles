#!/usr/bin/env bash
# FIX5 test hygiene: running the test suites must not leave Python bytecode (__pycache__) in the repo tree. `python3 -I` ignores
# PYTHONPYCACHEPREFIX and PYTHONDONTWRITEBYTECODE, so every such call needs -B, and the suites export PYTHONDONTWRITEBYTECODE for the
# other interpreters. The caches are gitignored and stow-ignored, but every doctor run used to rewrite them.
# The check removes the existing caches first (they are only caches: Python rebuilds them), runs the fast suites that import repo
# Python (keymap, layout, users, audio, selfcopy) and fails when any .pyc exists afterwards. `.local/bin/envs` is skipped: the
# envs suite has its own owner and may run at the same time.
#   run.sh [--quick]   --quick = keymap and layout only
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
QUICK=0; [[ ${1:-} == --quick ]] && QUICK=1
fails=0 passes=0
pass() { passes=$((passes + 1)); printf 'PASS  %s\n' "$1"; }
fail() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
caches() { find "$REPO" \( -path "$REPO/private" -o -path "$REPO/.git" -o -path "$REPO/.config/nvim" \) -prune -o -name '*.pyc' ! -name 'envs.*' ! -name 'envscpython*' -print; }
clean() { find "$REPO" \( -path "$REPO/private" -o -path "$REPO/.git" -o -path "$REPO/.config/nvim" \) -prune -o -name __pycache__ -type d -print0 | xargs -0 -r rm -rf; }
suites=(keymap layout)
((QUICK)) || suites+=(users audio selfcopy)
for s in "${suites[@]}"; do
  clean
  case $s in users | audio) "$REPO/infrastructure/tests/$s/run.sh" --quick >/dev/null 2>&1 ;; *) "$REPO/infrastructure/tests/$s/run.sh" >/dev/null 2>&1 ;; esac
  left=$(caches | head -3 | tr '\n' ' ')
  if [[ -z $left ]]; then pass "the $s suite leaves no Python bytecode in the repo"; else fail "the $s suite left bytecode behind: $left"; fi
done
echo "hygiene tests: $passes passed, $fails failed"
((fails == 0))
