#!/usr/bin/env bash
# Waybar custom/dnd: shown only while dunst is paused, with the number of waiting notifications.
if [[ $(dunstctl is-paused 2>/dev/null) == true ]]; then
  jq -cn --arg n "$(dunstctl count waiting 2>/dev/null)" \
    '{text: "󰂛 \($n)", class: "on", tooltip: "notifications paused (\($n) waiting)"}'
else
  echo '{"text":""}'
fi
