#!/usr/bin/env bash
# hypridle condition_cmd: exit 0 to let a listener's on-timeout fire,
# non-zero to defer it. Used to skip dim/screensaver/DPMS-off while
#  - a Chrome started for browser automation is running
#    (--remote-debugging-port/pipe): automation doesn't generate real input,
#    so hypridle's idle timer never resets on its own and would otherwise dim
#    the screen mid-session, breaking screenshot capture. A normally used
#    Chrome does not block idle;
#  - something is playing: any MPRIS player reports Playing, or a PipeWire
#    audio output stream is running (players that don't send idle-inhibit).
# Wayland/DBus idle inhibitors (video fullscreen etc.) are honoured by
# hypridle itself.
for pid in $(pgrep -x 'chrome|google-chrome|google-chrome-stable'); do
    if tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -q -- '^--remote-debugging-'; then
        exit 1
    fi
done

if command -v playerctl >/dev/null 2>&1 && playerctl -a status 2>/dev/null | grep -qx Playing; then
    exit 1
fi

if command -v pw-dump >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 &&
    pw-dump 2>/dev/null | jq -e 'any(.[]; .info.props["media.class"] == "Stream/Output/Audio" and .info.state == "running")' >/dev/null 2>&1; then
    exit 1
fi
exit 0
