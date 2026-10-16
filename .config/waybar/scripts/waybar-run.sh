#!/usr/bin/env bash
# waybar-run: start waybar behind ws-ipc-proxy.py (clickable workspaces under the Lua Hyprland config; the why is in
# the proxy's header). Called by the Hyprland autostart and by bar.sh restart. Falls back to a plain waybar when the
# proxy does not come up, so the bar always starts. Extra arguments go to waybar.
set -u
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
proxy="$here/ws-ipc-proxy.py"

if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -x $proxy ]]; then
  fake="${XDG_RUNTIME_DIR:-/tmp}/hypr/${HYPRLAND_INSTANCE_SIGNATURE}-wb"
  # 9>&-: the proxy must not inherit bar.sh's lock
  if ! "$proxy" --ping; then
    setsid -f "$proxy" </dev/null >/dev/null 2>&1 9>&-
    for _ in $(seq 30); do "$proxy" --ping && break; sleep 0.1; done
  fi
  if "$proxy" --ping && [[ -L $fake/.socket2.sock ]]; then
    export HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE}-wb"
  fi
fi
exec waybar "$@"
