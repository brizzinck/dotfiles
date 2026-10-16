#!/usr/bin/env bash
# dunst: re-read dunstrc and the drop-ins in dunstrc.d (50-theme.conf follows the `current` link).
# `dunstctl reload` keeps the running notifications and the history untouched.
set -u
command -v dunstctl >/dev/null 2>&1 || exit 0
pgrep -u "$(id -u)" -x dunst >/dev/null || exit 0
dunstctl reload && echo "dunst: reloaded"
