#!/usr/bin/env bash
# Bound to prefix+Q.
# Kills the current session and moves every client attached to it into a fresh
# unnamed session (not saved until you save it yourself with prefix+S / prefix+N).
#
#   kill-and-new.sh <current_session> <start_dir>
set -euo pipefail

current="${1:?current session required}"
start_dir="${2:-$HOME}"

new="$(tmux new-session -d -P -F '#{session_name}' -c "$start_dir")"

while IFS= read -r client; do
  [ -n "$client" ] && tmux switch-client -c "$client" -t "=$new"
done < <(tmux list-clients -t "=$current" -F '#{client_name}' 2>/dev/null)

tmux kill-session -t "=$current"
tmux display-message "Session '${current}' killed → new session (not saved)"
