#!/usr/bin/env bash
# cursor-zoom: magnify the screen around the pointer (Hyprland cursor:zoom_factor). SUPER+CTRL+Z steps in (held = repeats),
# SUPER+CTRL+SHIFT+Z steps out, SUPER+CTRL+ALT+Z resets to 1. A config reload (hyprctl reload) also resets it.
#   cursor-zoom.sh in|out|reset|status [--dry-run]
set -u
STEP=0.5
MAX=8
DRY=0
ACT=""
for a in "$@"; do
  case $a in --dry-run) DRY=1 ;; in | out | reset | status) ACT=$a ;; esac
done
[[ -n $ACT ]] || { echo "usage: cursor-zoom.sh in|out|reset|status [--dry-run]" >&2; exit 2; }
cur=$(hyprctl getoption cursor:zoom_factor -j 2>/dev/null | jq -r '.float // 1')
[[ $cur =~ ^[0-9.]+$ ]] || cur=1
case $ACT in
  status) echo "$cur"; exit 0 ;;
  in) new=$(awk -v c="$cur" -v s="$STEP" -v m="$MAX" 'BEGIN { v = c + s; if (v > m) v = m; printf "%.2f", v }') ;;
  out) new=$(awk -v c="$cur" -v s="$STEP" 'BEGIN { v = c - s; if (v < 1) v = 1; printf "%.2f", v }') ;;
  reset) new=1 ;;
esac
if ((DRY)); then echo "zoom $cur -> $new: hyprctl eval hl.config({ cursor = { zoom_factor = $new } })"; exit 0; fi
hyprctl eval "hl.config({ cursor = { zoom_factor = $new } })" >/dev/null
