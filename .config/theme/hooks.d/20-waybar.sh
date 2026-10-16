#!/usr/bin/env bash
# waybar: SIGUSR2 reloads config and stylesheet (the style @imports theme.css, which follows the `current` link).
set -u
if pkill -u "$(id -u)" -USR2 -x waybar; then
  echo "waybar: reloaded"
fi
exit 0
