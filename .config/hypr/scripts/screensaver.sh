#!/usr/bin/env bash
# Clock-only idle screensaver: hyprlock with ~/.config/hypr/screensaver.conf (no
# password field). Nothing is suspended or killed, processes keep running.
#   screensaver.sh start  - show it (no-op when any hyprlock already runs)
#   screensaver.sh stop   - dismiss it without authentication (hypridle on-resume)
# Dismissal: hyprlock's grace period unlocks on pointer motion; on any input
# hypridle's on-resume calls `stop`, which sends SIGUSR1 (hyprlock's unlock
# signal) to the screensaver instance only - a manual password lock is never
# touched.
set -u

conf="$HOME/.config/hypr/screensaver.conf"
pattern='^hyprlock .*screensaver\.conf'

case "${1:-start}" in
  start)
    pidof hyprlock >/dev/null && exit 0
    # grace = one year: it counts from lock start, the screensaver may stay on for hours
    exec hyprlock --config "$conf" --grace 31536000
    ;;
  stop)
    for _ in 1 2 3; do
      pgrep -f "$pattern" >/dev/null || exit 0
      pkill -USR1 -f "$pattern"
      sleep 0.3
    done
    ;;
  *)
    echo "usage: ${0##*/} start|stop" >&2
    exit 2
    ;;
esac
