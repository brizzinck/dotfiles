#!/usr/bin/env bash
# wallpaper: the figure colour follows the variant (wallpaper.svg in the generated fragment). wallpaper.sh renders the
# missing PNGs per output and restarts only the swaybg instances whose file changed; nothing else is touched.
set -u
w="$HOME/.config/hypr/scripts/wallpaper.sh"
[[ -x $w ]] || exit 0
pgrep -u "$(id -u)" -x Hyprland >/dev/null || exit 0
"$w" apply && echo "wallpaper: applied"
exit 0
