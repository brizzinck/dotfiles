#!/usr/bin/env bash
# Runs on tmux's session-created hook (see tmux.conf).
# Auto-named sessions get a random unused name from POOL; once the pool is
# fully taken, fall back to a timestamp instead of leaving the plain
# tmux-assigned number.
set -euo pipefail

POOL=(pukich soska piska loxxx gopnix chmoxxx kolobox shpendrik pshik vareniki)
session_name="${1:?session name required}"

# Sessions that don't carry a real, human-chosen name: tmux's own plain
# numeric auto-naming (0, 1, 2, ...) and the Hyprland $mainMod+Return
# terminal binding, which passes `-s "term-$(date +%s%N)"` (see
# hyprland.conf). Anything else (e.g. `tmux new -s foo`) is left untouched.
AUTO_NAME_RE='^([0-9]+|term-[0-9]+)$'
[[ "$session_name" =~ $AUTO_NAME_RE ]] || exit 0

existing=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

available=()
for name in "${POOL[@]}"; do
  grep -qxF "$name" <<<"$existing" || available+=("$name")
done

if (( ${#available[@]} > 0 )); then
  pick="${available[RANDOM % ${#available[@]}]}"
else
  pick="$(date +%s%N)"
fi

tmux rename-session -t "$session_name" "$pick"
