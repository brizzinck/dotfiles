#!/usr/bin/env bash
# Clipboard history: cliphist + rofi. SUPER+C.
# Enter copies the entry, Alt+d deletes it (the menu reopens).
set -u

while true; do
  rc=0
  pick=$(cliphist list | rofi -dmenu -i -p clip -display-columns 2 -kb-custom-1 'Alt+d' \
    -mesg 'Enter: copy    Alt+d: delete') || rc=$?
  case $rc in
    0) printf '%s' "$pick" | cliphist decode | wl-copy; exit 0 ;;
    10) printf '%s' "$pick" | cliphist delete ;;
    *) exit 0 ;;
  esac
done
