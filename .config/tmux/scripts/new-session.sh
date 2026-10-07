#!/usr/bin/env bash
# Creates a new tmux session with an explicit, unique name.
set -euo pipefail

raw_name="${1:-}"
name="$(echo "$raw_name" | xargs)"
name="${name// /_}"

if [ -z "$name" ]; then
  tmux display-message "Ошибка: имя сессии обязательно!"
  exit 1
fi

if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  tmux display-message "Ошибка: недопустимые символы в имени сессии!"
  exit 1
fi

if tmux has-session -t "$name" 2>/dev/null; then
  tmux display-message "Ошибка: сессия '${name}' уже существует!"
  exit 1
fi

# Determine start directory: pane current path if inside tmux client, otherwise $HOME
start_path="$HOME"
if [ -n "${TMUX_PANE:-}" ]; then
  start_path="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_current_path}' 2>/dev/null || echo "$HOME")"
fi

tmux new-session -d -s "$name" -c "$start_path"
if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$name"
fi
tmux display-message "Сессия '${name}' создана"
