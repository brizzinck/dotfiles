#!/usr/bin/env bash
# Bound to prefix+N.
# Snapshots the current session under its name (replacing the previous snapshot
# with that name), then creates a new unnamed session and switches to it. The new
# session is not part of that snapshot; it gets a name and is saved only when you
# press prefix+S (or prefix+N) in it yourself.
#
# An unnamed (numeric) current session has no name to save under, so the binding
# prompts for one and passes it as <label>; the session is renamed to it.
#
#   save-and-new.sh <current_session> <start_dir> [label]
set -euo pipefail

SCRIPTS="$HOME/.config/tmux/scripts"

current="${1:?current session required}"
start_dir="${2:-$HOME}"
label="${3:-}"

if [ -n "$label" ]; then
  # Explicit name: same rules as prefix+S (unique, no overwrite)
  bash "$SCRIPTS/snapshot-save.sh" "$label"
else
  bash "$SCRIPTS/snapshot-save.sh" --replace "${current//[^a-zA-Z0-9._-]/_}"
fi

new="$(tmux new-session -d -P -F '#{session_name}' -c "$start_dir")"
tmux switch-client -t "=$new"
tmux display-message "Session saved → new session (not saved)"
