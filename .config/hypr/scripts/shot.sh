#!/usr/bin/env bash
# shot: hyprshot screenshots with the O1 ending (toast whose click opens satty, "Show folder" in the action menu).
#   shot.sh region|monitor|window [--dry-run]     Print, SHIFT+Print, SUPER+Print, ALT+S, the capture menu and the hub rows
# The file lands in ~/pics/screenshots and in the clipboard (hyprshot does both); hyprshot's own plain toast is silenced.
set -u
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
SHOTS="$HOME/pics/screenshots"
# shellcheck source=capture-lib.sh
. "$HERE/capture-lib.sh"
mode=${1:-region}
DRY=0
[[ ${2:-} == --dry-run ]] && DRY=1
case $mode in
  region) args=(-m region) ;;
  monitor) args=(-m output -m active) ;;
  window) args=(-m window -m active) ;;
  *) echo "usage: shot.sh region|monitor|window [--dry-run]" >&2; exit 2 ;;
esac
name="$(date +'%Y-%m-%d-%H%M%S')_hyprshot.png"
if ((DRY)); then echo "hyprshot ${args[*]} -o $SHOTS -f $name --silent; then the toast with Edit in satty / Show folder"; exit 0; fi
command -v hyprshot >/dev/null 2>&1 || { notify-send -a capture -u critical "Screenshot: hyprshot is missing" "install it from the hub"; exit 1; }
mkdir -p "$SHOTS"
hyprshot "${args[@]}" -o "$SHOTS" -f "$name" --silent || exit 0
[[ -s $SHOTS/$name ]] || exit 0
cap_toast_shot "$SHOTS/$name"
