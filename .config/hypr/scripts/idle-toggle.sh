#!/usr/bin/env bash
# Toggle hypridle (dim / clock screensaver / panel off). SUPER+CTRL+I.
# Waybar shows the state (toggles drawer, `pgrep -x hypridle`) and is refreshed with signal 8.
set -u

if pgrep -x hypridle >/dev/null; then
  : >"${XDG_RUNTIME_DIR:-/tmp}/idle-off" # on purpose: the hypridle watchdog leaves it off
  pkill -x hypridle
  ~/.config/hypr/scripts/dim.sh restore # a panel that was dimmed must not stay dim
  notify-send -a idle -h string:x-dunst-stack-tag:idle -t 2000 "Idle: off" "screen will not dim or show the clock"
else
  rm -f "${XDG_RUNTIME_DIR:-/tmp}/idle-off"
  setsid -f hypridle >/dev/null 2>&1
  notify-send -a idle -h string:x-dunst-stack-tag:idle -t 2000 "Idle: on"
fi
pkill -o -u "$UID" -RTMIN+8 -x waybar 2>/dev/null || true   # signal 8 = waybar toggles drawer
