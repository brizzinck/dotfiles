#!/usr/bin/env bash
# hypridle condition_cmd: exit 0 to let a listener's on-timeout fire,
# non-zero to defer it. Used to skip dim/lock/DPMS-off while Chrome is
# open — browser automation doesn't generate real input, so hypridle's
# idle timer never resets on its own and would otherwise dim/lock/DPMS-off
# the screen mid-session, breaking screenshot capture.
if hyprctl clients -j | jq -e 'any(.[]; .class == "google-chrome")' >/dev/null 2>&1; then
    exit 1
fi
exit 0
