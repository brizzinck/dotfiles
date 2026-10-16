#!/usr/bin/env bash
# Fuzzy project switcher: pick a directory, jump to (or create) its tmux session.
# Usage: sessionizer.sh [dir]   (inside tmux: prefix+F popup; outside: SUPER+P in ghostty)
# Session names are the directory basename; a clash with a session that lives in a
# different directory gets the parent directory prepended, then a numeric suffix.
set -euo pipefail

roots=("$HOME/job" "$HOME/dotfiles")

list_dirs() {
  if command -v zoxide >/dev/null 2>&1; then
    zoxide query -l 2>/dev/null || true
  fi
  if command -v fd >/dev/null 2>&1; then
    fd -t d -d 2 . "${roots[@]}" 2>/dev/null || true
  else
    find "${roots[@]}" -maxdepth 2 -type d -not -path '*/.git*' 2>/dev/null || true
  fi
}

if [ -n "${1:-}" ]; then
  dir="$1"
else
  preview='eza -1 --git {} 2>/dev/null || ls -1 {}'
  dir=$(list_dirs | awk 'NF && !seen[$0]++' |
    "$HOME/.local/bin/fzf-menu" --here -p project --preview "$preview" --preview-window=right:50%) || exit 0
fi
[ -d "$dir" ] || exit 0
dir="${dir%/}"

sanitize() { printf '%s' "$1" | tr '.: ' '___'; }

base="$(sanitize "$(basename "$dir")")"
parent="$(sanitize "$(basename "$(dirname "$dir")")")"

# Pick a name: reuse the session if it already lives in $dir, otherwise make it unique.
name="$base"
candidates=("$base" "${parent}-${base}")
for c in "${candidates[@]}"; do
  if ! tmux has-session -t "=$c" 2>/dev/null; then
    name="$c"
    break
  fi
  if [ "$(tmux display-message -p -t "=$c:" '#{session_path}' 2>/dev/null)" = "$dir" ]; then
    name="$c"
    break
  fi
  name=""
done
if [ -z "$name" ]; then
  n=2
  while tmux has-session -t "=${parent}-${base}-${n}" 2>/dev/null; do n=$((n + 1)); done
  name="${parent}-${base}-${n}"
fi

if ! tmux has-session -t "=$name" 2>/dev/null; then
  tmux new-session -ds "$name" -c "$dir"
fi

if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "=$name"
else
  exec tmux attach-session -t "=$name"
fi
