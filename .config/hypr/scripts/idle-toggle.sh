#!/usr/bin/env bash
# Toggle hypridle (dim / lock / screen off / battery suspend). SUPER+CTRL+I.
# Waybar can show the state with `pgrep -x hypridle`.
set -u

if pgrep -x hypridle >/dev/null; then
  pkill -x hypridle
  notify-send -a idle -h string:x-dunst-stack-tag:idle -t 2000 "Idle lock: off" "screen will not dim, lock or sleep"
else
  setsid -f hypridle >/dev/null 2>&1
  notify-send -a idle -h string:x-dunst-stack-tag:idle -t 2000 "Idle lock: on"
fi
