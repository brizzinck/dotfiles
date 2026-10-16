#!/usr/bin/env bash
# swayosd: the server reads ~/.config/swayosd/style.css (and its @imports) only at start, so restart it.
# It only draws the volume/brightness pill, nothing else depends on it.
set -u
command -v swayosd-server >/dev/null 2>&1 || exit 0
pgrep -u "$(id -u)" -x swayosd-server >/dev/null || exit 0

rt=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
if [[ -z ${WAYLAND_DISPLAY:-} || ! -S $rt/$WAYLAND_DISPLAY ]]; then
  sock=
  for s in "$rt"/wayland-[0-9]*; do
    [[ -S $s ]] && { sock=$s; break; }
  done
  [[ -n $sock ]] || exit 0
  export WAYLAND_DISPLAY=${sock##*/}
fi
export XDG_RUNTIME_DIR=$rt

pkill -u "$(id -u)" -x swayosd-server
for _ in 1 2 3 4 5; do pgrep -u "$(id -u)" -x swayosd-server >/dev/null || break; sleep 0.2; done
setsid -f swayosd-server >/dev/null 2>&1 < /dev/null
sleep 0.3
pgrep -u "$(id -u)" -x swayosd-server >/dev/null && echo "swayosd: restarted"
