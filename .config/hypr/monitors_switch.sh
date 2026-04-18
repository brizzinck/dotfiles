#!/usr/bin/env bash

PIDFILE=/tmp/monitor-switch.pid
if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    sleep 0.2
fi
echo $$ > "$PIDFILE"
trap "rm -f $PIDFILE" EXIT

apply() {
    if hyprctl -j monitors all | grep -q '"HDMI-A-1"'; then
        hyprctl keyword monitor "eDP-1,disable" >/dev/null
        hyprctl keyword monitor "HDMI-A-1,2560x1440@144,0x0,1" >/dev/null
    else
        hyprctl keyword monitor "eDP-1,2880x1800@120,0x0,1.5" >/dev/null
    fi
}

LAST=""
while true; do
    CURRENT=$(hyprctl -j monitors all 2>/dev/null | grep -E '"name"|"disabled"' | sort)
    if [ "$CURRENT" != "$LAST" ]; then
        apply
        LAST="$CURRENT"
    fi
    sleep 2
done
