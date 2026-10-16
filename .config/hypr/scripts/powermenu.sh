#!/usr/bin/env bash
# Power menu (fzf-menu, vim keys). SUPER+SHIFT+Escape and the power key.
set -u

entries=$'lock\nsuspend\nlogout\nreboot\npoweroff'

choice=$(printf '%s\n' "$entries" | fzf-menu -p power) || exit 0

confirm() {
  local answer
  answer=$(printf 'no\nyes\n' | fzf-menu -p "$1?") || return 1
  [[ $answer == yes ]]
}

case $choice in
  lock) pidof hyprlock >/dev/null || hyprlock ;;
  suspend) systemctl suspend ;;
  logout) confirm logout && hyprd exit ;;
  reboot) confirm reboot && systemctl reboot ;;
  poweroff) confirm poweroff && systemctl poweroff ;;
esac
