#!/usr/bin/env bash
# clean-mode: lock all input while wiping the keyboard and touchpad. SUPER+CTRL+Escape.
#   clean-mode.sh start [--dry-run]   disable the touchpad(s), enter the swallow-everything submap `clean`
#   clean-mode.sh stop  [--dry-run]   leave the submap, re-enable the touchpad(s)
#   clean-mode.sh devices             list the touchpad device names that would be disabled
# Leave with CTRL+SHIFT+ALT+Escape (bound inside the submap in hyprland.conf). A watchdog leaves automatically
# after CLEAN_TIMEOUT seconds (default 300) so a broken combo can never lock the session.
set -u
TIMEOUT="${CLEAN_TIMEOUT:-300}"
DRY=0; args=()
for a in "$@"; do if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi; done
set -- "${args[@]+"${args[@]}"}"
PIDF="${XDG_RUNTIME_DIR:-/tmp}/clean-mode.pid"
run() { if ((DRY)); then echo "would run: $*"; else "$@"; fi; }

devices() { hyprctl devices -j 2>/dev/null | jq -r '.mice[]? | select(.name | test("touchpad"; "i")) | .name'; }

set_touchpads() { # set_touchpads true|false
  local d
  while IFS= read -r d; do
    [[ -n $d ]] && run hyprctl keyword "device[$d]:enabled" "$1"
  done < <(devices)
}

case ${1:-start} in
  devices) devices ;;
  start)
    set_touchpads false
    run hyprctl dispatch submap clean
    if ((DRY)); then echo "would start watchdog: stop after ${TIMEOUT}s"; else
      (sleep "$TIMEOUT"; "$0" stop) >/dev/null 2>&1 &
      echo $! >"$PIDF"
    fi
    run notify-send -a clean-mode -u critical -t 8000 -h string:x-dunst-stack-tag:clean-mode "Cleaning mode" "Keyboard and touchpad are off. Leave: CTRL+SHIFT+ALT+Escape (automatic after $((TIMEOUT / 60)) min)" ;;
  stop)
    run hyprctl dispatch submap reset
    set_touchpads true
    if ((DRY)); then :; else
      if [[ -r $PIDF ]]; then kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; fi
    fi
    run notify-send -a clean-mode -t 2500 -h string:x-dunst-stack-tag:clean-mode "Cleaning mode off" ;;
  *) echo "usage: clean-mode.sh start|stop|devices [--dry-run]" >&2; exit 2 ;;
esac
