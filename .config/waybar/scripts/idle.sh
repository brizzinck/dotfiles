#!/usr/bin/env bash
# Waybar custom/idle: shown only while hypridle is stopped (idle-inhibit on). Toggle: hypr/scripts/idle-toggle.sh
if pgrep -x hypridle >/dev/null; then
  echo '{"text":""}'
else
  echo '{"text":"󰅶","class":"on","tooltip":false}'
fi
