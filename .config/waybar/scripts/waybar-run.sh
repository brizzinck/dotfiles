#!/usr/bin/env bash
# waybar-run: supervisor for waybar, started behind ws-ipc-proxy.py (clickable workspaces under the Lua Hyprland config;
# the why is in the proxy's header). Called by the Hyprland autostart and by bar.sh restart. Falls back to a plain waybar
# when the proxy does not come up, so the bar always starts. Also starts the pinned-apps daemon (pinned-watch.py, it
# outlives waybar restarts and keeps the "new" flags). Extra arguments go to waybar.
#
# Watchdog: waybar is a child of this script, and an abnormal exit (a signal such as SIGSEGV/SIGABRT/SIGKILL, or a non-zero
# status) starts it again, after 1, 2, 5, 10, 10 s (the n-th crash within the window). The proxy and the pinned daemon are
# checked, not started blindly, so a restart never duplicates them. A recovered crash (waybar still up after 5 s) posts
# one low-urgency notification; 5 crashes within 120 s end the loop with one notification. Every restart goes to the
# journal (`journalctl -t waybar-run`). Not a crash, so no restart: exit status 0, SIGTERM/SIGINT/SIGHUP (bar.sh restart
# stops this script first with SIGTERM; it passes the SIGTERM on to waybar and ends), and the Wayland socket being gone
# (the session is ending). One supervisor at a time: it holds a flock on $RT/supervisor.lock and writes
# $RT/supervisor.pid (doctor, bar.sh); a second waybar-run.sh exits at once.
# Test hook: BAR_RUN_DIR overrides $RT (as in bar.sh).
set -u
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
proxy="$here/ws-ipc-proxy.py"
RT="${BAR_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/waybar-bar}"
max_crashes=5
window=120
settle=5
delays=(1 2 5 10 10)

log() { logger -t waybar-run -- "$*" 2>/dev/null || true; echo "waybar-run: $*" >&2; }
note() { notify-send -a waybar -u "$1" -h string:x-dunst-stack-tag:waybar-crash -t 6000 "${@:2}" 2>/dev/null || true; }

mkdir -p "$RT" 2>/dev/null || true
# 8>&- / 9>&- on every child: only this script may hold the supervisor lock (and bar.sh's lock must not leak either)
exec 8>"$RT/supervisor.lock"
if ! flock -n 8; then log "already running (pid $(<"$RT/supervisor.pid" 2>/dev/null)), not starting a second supervisor"; exit 0; fi
echo $$ >"$RT/supervisor.pid"

sig0="${HYPRLAND_INSTANCE_SIGNATURE:-}"
wpid=""
stopping=0
on_term() { stopping=1; [[ -n $wpid ]] && kill -TERM "$wpid" 2>/dev/null; return 0; }
on_exit() { local p; { p=$(<"$RT/supervisor.pid"); } 2>/dev/null; [[ $p == "$$" ]] && rm -f "$RT/supervisor.pid"; return 0; }
trap on_term TERM INT HUP
trap on_exit EXIT

# prepare: daemons first (both start only when not running), then the signature that points waybar at the proxy
prepare() {
  HYPRLAND_INSTANCE_SIGNATURE="$sig0"
  [[ -n $sig0 ]] && "$here/pinned.sh" start 9>&- 8>&-
  if [[ -n $sig0 && -x $proxy ]]; then
    local fake="${XDG_RUNTIME_DIR:-/tmp}/hypr/${sig0}-wb" _
    if ! "$proxy" --ping; then
      setsid -f "$proxy" </dev/null >/dev/null 2>&1 9>&- 8>&-
      for _ in $(seq 30); do "$proxy" --ping && break; sleep 0.1; done
    fi
    if "$proxy" --ping && [[ -L $fake/.socket2.sock ]]; then
      HYPRLAND_INSTANCE_SIGNATURE="${sig0}-wb"
    fi
  fi
  export HYPRLAND_INSTANCE_SIGNATURE
}

# describe STATUS: "SIGSEGV" for 139, "exit status 1" otherwise
describe() {
  if (($1 > 128)); then echo "SIG$(kill -l "$1" 2>/dev/null || echo "$(($1 - 128))") (status $1)"; else echo "exit status $1"; fi
}

crashes=()
restarted=0
while :; do
  prepare
  waybar "$@" 8>&- &
  wpid=$!
  if ((restarted)); then
    ( sleep "$settle"; kill -0 "$wpid" 2>/dev/null && note low "Waybar crashed and was restarted" ) 8>&- 9>&- &
  fi
  wait "$wpid"; rc=$?
  while ((stopping)) && kill -0 "$wpid" 2>/dev/null; do wait "$wpid"; rc=$?; done
  wpid=""
  if ((stopping)); then log "stopped on request (waybar: $(describe "$rc"))"; exit 0; fi
  case $rc in
    0 | 129 | 130 | 143) log "waybar ended ($(describe "$rc")), not restarting"; exit 0 ;;
  esac
  [[ -S ${XDG_RUNTIME_DIR:-/run/user/$UID}/${WAYLAND_DISPLAY:-wayland-1} ]] || { log "waybar ended ($(describe "$rc")), the Wayland socket is gone: session over"; exit 0; }
  now=${EPOCHSECONDS:-$(date +%s)}
  recent=()
  for t in "${crashes[@]+"${crashes[@]}"}"; do ((now - t < window)) && recent+=("$t"); done
  crashes=("${recent[@]+"${recent[@]}"}" "$now")
  n=${#crashes[@]}
  if ((n >= max_crashes)); then
    log "waybar crashed ($(describe "$rc")), $n times within ${window}s: giving up (bar.sh restart starts it again; coredumpctl list waybar)"
    note normal "Waybar keeps crashing" "See: coredumpctl list waybar"
    exit 1
  fi
  d=${delays[n - 1]}
  log "waybar crashed ($(describe "$rc")), crash $n of $max_crashes within ${window}s: restarting in ${d}s"
  sleep "$d" 8>&- & wait $!
  ((stopping)) && { log "stopped on request while waiting to restart"; exit 0; }
  restarted=1
done
