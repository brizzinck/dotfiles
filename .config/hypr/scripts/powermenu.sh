#!/usr/bin/env bash
# Power menu in rofi (dmenu mode). SUPER+SHIFT+Escape and the power key.
set -u

entries=$'lock\nsuspend\nlogout\nreboot\npoweroff'

choice=$(printf '%s\n' "$entries" |
  rofi -dmenu -i -p power -theme-str 'window { width: 320px; } listview { lines: 5; }') || exit 0

confirm() {
  local answer
  answer=$(printf 'no\nyes\n' | rofi -dmenu -i -p "$1?" -theme-str 'window { width: 320px; } listview { lines: 2; }') || return 1
  [[ $answer == yes ]]
}

case $choice in
  lock) pidof hyprlock >/dev/null || hyprlock ;;
  suspend) systemctl suspend ;;
  logout) confirm logout && hyprd exit ;;
  reboot) confirm reboot && systemctl reboot ;;
  poweroff) confirm poweroff && systemctl poweroff ;;
esac
