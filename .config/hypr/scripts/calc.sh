#!/usr/bin/env bash
# calc: calculator. SUPER+equal. rofi-calc (libqalculate) when installed, otherwise qalc in a float.tui terminal.
# Enter copies the result to the clipboard. --dry-run prints the chosen backend.
set -u
DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1
if [[ -e /usr/lib/rofi/calc.so ]] || [[ -e /usr/lib64/rofi/calc.so ]]; then
  cmd=(rofi -show calc -modi calc -no-show-match -no-sort -calc-command "echo -n '{result}' | wl-copy")
elif command -v qalc >/dev/null 2>&1; then
  cmd=(ghostty --class=float.tui -e qalc)
else
  ((DRY)) && { echo "no calculator installed (rofi-calc / libqalculate; sudo ~/dotfiles/apply-system.sh --only install)"; exit 0; }
  notify-send -a calc "Calculator" "Install rofi-calc or libqalculate (root script)"
  exit 0
fi
if ((DRY)); then echo "${cmd[*]}"; else pkill -x rofi 2>/dev/null; exec "${cmd[@]}"; fi
