#!/usr/bin/env bash
# waybar: reload the config, the include files and the stylesheet (style.css @imports theme.css, which follows the
# `current` link). bar.sh reload renders the compact/full state first so the mode survives the reload.
set -u
bar="$HOME/.config/waybar/scripts/bar.sh"
if [[ -x $bar ]]; then
  "$bar" reload && echo "waybar: reloaded (bar.sh)"
elif pkill -u "$(id -u)" -USR2 -x waybar; then
  echo "waybar: reloaded"
fi
exit 0
