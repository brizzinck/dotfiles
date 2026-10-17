#!/usr/bin/env bash
# dim: the idle dim of hypridle (150 s), made robust. hypridle's own pair `brightnessctl -s set 25%` / `brightnessctl -r` saves
# whatever the brightness is when the dim fires: a second dim without a resume in between (a missed resume event, a
# restarted hypridle) saved the DIMMED value and "restored" the panel to 0.4 %. Here:
#   dim.sh dim        save the real brightness in $XDG_RUNTIME_DIR/dim-saved ONLY when no dim is active, then dim to 25 %
#                     (exponent 4, as before); starts a watcher that restores on pointer movement or when hypridle is gone
#   dim.sh restore    put the saved brightness back (hypridle on-resume, the watcher, a key press: input.keyboard.key in
#                     hyprland.lua, idle-toggle.sh); never restores a value that is itself dim-dark (falls back to 50 %)
#   dim.sh status     "dimmed (saved RAW of MAX)" or "normal"
#   dim.sh watchdog   start hypridle when it is missing and idle was not switched off on purpose (user timer hypridle-watch)
# Raw values are used for save and restore (brightnessctl set N, no percent maths). Input also wakes DPMS through
# misc:key_press_enables_dpms / mouse_move_enables_dpms in hyprland.lua.
set -u

RT="${XDG_RUNTIME_DIR:-/tmp}"
STATE="$RT/dim-saved"
WATCH_PID="$RT/dim-watch.pid"
IDLE_OFF="$RT/idle-off"
BCTL=${BRIGHTNESSCTL:-brightnessctl}

read_dev() { # -> "RAW MAX"
  "$BCTL" -m 2>/dev/null | awk -F, 'NR == 1 { print $3, $5 }'
}

dim_floor() { # raw value of the 25 % exponent-4 dim for MAX: anything at or below 1.5x of it counts as "already dark"
  awk -v m="$1" 'BEGIN { d = m * (0.25 ^ 4); print int(d * 1.5) + 1 }'
}

cmd_dim() {
  [[ -e $STATE ]] && return 0 # already dimmed: never save a dimmed value
  local raw max
  read -r raw max < <(read_dev)
  [[ $raw =~ ^[0-9]+$ && $max =~ ^[0-9]+$ ]] || return 0
  # the panel is already as dark as the dim would make it: nothing to dim, nothing to remember
  ((raw <= $(dim_floor "$max"))) && return 0
  printf '%s %s\n' "$raw" "$max" >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
  "$BCTL" -e4 set 25% >/dev/null 2>&1
  start_watch
}

cmd_restore() {
  [[ -r $STATE ]] || return 0
  local raw max cur_max
  read -r raw max <"$STATE"
  rm -f "$STATE"
  read -r _ cur_max < <(read_dev)
  max=${cur_max:-$max}
  if ! [[ $raw =~ ^[0-9]+$ ]] || ((raw <= $(dim_floor "$max"))); then raw=$((max / 2)); fi
  "$BCTL" set "$raw" >/dev/null 2>&1
  stop_watch
}

start_watch() {
  [[ ${DIM_NO_WATCH:-0} == 1 ]] && return 0
  stop_watch
  setsid -f bash -c 'echo $$ >"$1"; exec "$2" watch' _ "$WATCH_PID" "$(readlink -f "${BASH_SOURCE[0]}")" >/dev/null 2>&1 </dev/null
}

stop_watch() {
  local p
  p=$(cat "$WATCH_PID" 2>/dev/null || true)
  [[ $p =~ ^[0-9]+$ && $p != "$$" ]] && kill "$p" 2>/dev/null
  rm -f "$WATCH_PID"
  return 0
}

# the watcher: while dimmed, a moved pointer or a dead hypridle restores the brightness (the resume event may never come)
cmd_watch() {
  local pos0 pos
  pos0=$(hyprctl cursorpos 2>/dev/null)
  while [[ -e $STATE ]]; do
    sleep 1
    [[ -e $STATE ]] || break
    pos=$(hyprctl cursorpos 2>/dev/null)
    if [[ -n $pos && $pos != "$pos0" ]]; then cmd_restore; break; fi
    if ! pgrep -x hypridle >/dev/null 2>&1; then
      cmd_restore
      break
    fi
  done
  rm -f "$WATCH_PID"
}

cmd_watchdog() {
  [[ -e $IDLE_OFF ]] && return 0
  pgrep -x hypridle >/dev/null 2>&1 && return 0
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} || -S ${XDG_RUNTIME_DIR:-/nonexistent}/hypr ]] || pgrep -x Hyprland >/dev/null 2>&1 || return 0
  cmd_restore # a dimmed panel must not stay dim without hypridle
  setsid -f hypridle >/dev/null 2>&1 </dev/null
  notify-send -a idle -u low -t 3000 "hypridle restarted" "it was not running (idle off is SUPER+CTRL+I)" 2>/dev/null || true
}

case ${1:-} in
  dim) cmd_dim ;;
  restore) cmd_restore ;;
  status) if [[ -r $STATE ]]; then echo "dimmed (saved $(cat "$STATE"))"; else echo normal; fi ;;
  watch) cmd_watch ;;
  watchdog) cmd_watchdog ;;
  *) echo "usage: dim.sh dim|restore|status|watchdog" >&2; exit 2 ;;
esac
