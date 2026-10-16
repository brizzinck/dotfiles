#!/usr/bin/env bash
# hypridle condition_cmd: exit 0 to let a listener's on-timeout fire,
# non-zero to defer it. Used to skip dim/lock/DPMS-off/suspend while a Chrome
# started for browser automation is running (--remote-debugging-port/pipe):
# automation doesn't generate real input, so hypridle's idle timer never
# resets on its own and would otherwise dim/lock/DPMS-off the screen
# mid-session, breaking screenshot capture. A normally used Chrome does not
# block idle.
for pid in $(pgrep -x 'chrome|google-chrome|google-chrome-stable'); do
    if tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -q -- '^--remote-debugging-'; then
        exit 1
    fi
done
exit 0
