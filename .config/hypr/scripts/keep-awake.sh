#!/usr/bin/env bash
# keep-awake: keep the machine awake for a while, until switched off, or while a window exists.
#
#   keep-awake.sh 15m|1h|2h|4h|<N>m|<N>h   hold an idle+sleep inhibitor for that long (replaces a running one)
#   keep-awake.sh until-off | on           hold until switched off
#   keep-awake.sh window ADDRESS           hold while that Hyprland window exists (window-menu hook `keep-awake`)
#   keep-awake.sh toggle                   off if active, otherwise until-off
#   keep-awake.sh off | stop               release
#   keep-awake.sh status                   exit 0 and print the state when active, exit 1 when off
#   keep-awake.sh waybar                   JSON for the custom/keepawake module (empty text when off)
#   keep-awake.sh menu                     rofi duration picker
#   --dry-run                              print what would happen, change nothing
#
# The inhibitor is `systemd-inhibit --what=idle:sleep --mode=block` held by a user process (pid file in
# $XDG_RUNTIME_DIR/keep-awake). hypridle honours logind idle inhibitors (general:ignore_dbus_inhibit = false), so
# dim, the clock screensaver and panel-off are skipped while it is active. No sudo: polkit allows the active session.
set -u

STATE="${XDG_RUNTIME_DIR:-/tmp}/keep-awake"
PIDF="$STATE/pid"
UNTILF="$STATE/until"   # epoch seconds, or "off" for no end
LABELF="$STATE/label"
WINF="$STATE/win"       # address of the watched window (window mode only)
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
G_AWAKE='󰒳'
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

note() { notify-send -a keep-awake -h string:x-dunst-stack-tag:keep-awake -t 2500 "$@" 2>/dev/null || true; }
poke_bar() { pkill -RTMIN+12 waybar 2>/dev/null || true; }

holder_pid() { # print the pid of the live holder, or fail
  local p
  [[ -r $PIDF ]] || return 1
  p=$(<"$PIDF")
  [[ $p =~ ^[0-9]+$ ]] && [[ -r /proc/$p/cmdline ]] && tr '\0' ' ' <"/proc/$p/cmdline" | grep -q -- '__hold' || return 1
  printf '%s\n' "$p"
}

stop_holder() {
  local p
  if p=$(holder_pid); then kill "$p" 2>/dev/null || true; fi
  rm -f "$PIDF" "$UNTILF" "$LABELF" "$WINF"
}

parse_secs() { # 15m / 1h / 90s / 90 (minutes) -> seconds
  local n=${1%[smh]}
  [[ $n =~ ^[0-9]+$ ]] || return 1
  case $1 in
    *h) echo $((n * 3600)) ;;
    *s) echo "$n" ;;
    *) echo $((n * 60)) ;;
  esac
}

start() { # start MODE VALUE LABEL   MODE = secs | forever | window
  local mode=$1 value=$2 label=$3 end why="keep-awake: $3"
  if ((DRY)); then
    echo "would run: systemd-inhibit --what=idle:sleep --who=keep-awake --why='$why' --mode=block $SELF __hold $mode $value"
    return 0
  fi
  command -v systemd-inhibit >/dev/null 2>&1 || { note -u critical "keep-awake" "systemd-inhibit not found"; return 1; }
  stop_holder
  mkdir -p "$STATE"
  if [[ $mode == secs ]]; then end=$(($(date +%s) + value)); else end=off; fi
  printf '%s\n' "$end" >"$UNTILF"
  printf '%s\n' "$label" >"$LABELF"
  if [[ $mode == window ]]; then printf '%s\n' "$value" >"$WINF"; fi
  nohup setsid systemd-inhibit --what=idle:sleep --who=keep-awake --why="$why" --mode=block \
    "$SELF" __hold "$mode" "$value" >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    holder_pid >/dev/null && break
    sleep 0.2
  done
  if holder_pid >/dev/null; then
    note "Keep awake: $label" "idle and sleep are inhibited"
  else
    rm -f "$UNTILF" "$LABELF"
    note -u critical "Keep awake failed" "could not take the inhibitor"
    return 1
  fi
  poke_bar
}

hold() { # internal: runs as the child of systemd-inhibit; the inhibitor lives as long as this process
  local mode=$1 value=$2 end
  mkdir -p "$STATE"
  echo $$ >"$PIDF"
  trap 'rm -f "$PIDF" "$UNTILF" "$LABELF" "$WINF"; poke_bar; exit 0' TERM INT HUP
  case $mode in
    secs)
      end=$(($(date +%s) + value))
      while [[ $(date +%s) -lt $end ]]; do sleep 5 & wait $!; done ;;
    forever) while :; do sleep 3600 & wait $!; done ;;
    window)
      while hyprctl clients -j 2>/dev/null | jq -e --arg a "$value" 'any(.[]; .address == $a)' >/dev/null 2>&1; do
        sleep 4 & wait $!
      done ;;
  esac
  rm -f "$PIDF" "$UNTILF" "$LABELF" "$WINF"
  poke_bar
  note "Keep awake: finished" "normal idle behaviour is back"
}

fmt_left() { # seconds -> 1h05 / 12m / <1m
  local s=$1
  if ((s >= 3600)); then printf '%dh%02d' $((s / 3600)) $((s % 3600 / 60))
  elif ((s > 0)); then printf '%dm' $(((s + 59) / 60))
  else printf '0m'; fi
}

active() { holder_pid >/dev/null; }

status() {
  local u label left
  active || { echo off; return 1; }
  u=$(cat "$UNTILF" 2>/dev/null) || u=off
  label=$(cat "$LABELF" 2>/dev/null) || label=awake
  if [[ $u =~ ^[0-9]+$ ]]; then
    left=$((u - $(date +%s))); ((left < 0)) && left=0
    echo "on $label (left $(fmt_left "$left"))"
  else
    echo "on $label"
  fi
}

waybar() {
  local u label left text
  if ! active; then echo '{"text":""}'; return 0; fi
  u=$(cat "$UNTILF" 2>/dev/null) || u=off
  label=$(cat "$LABELF" 2>/dev/null) || label=awake
  if [[ $u =~ ^[0-9]+$ ]]; then
    left=$((u - $(date +%s))); ((left < 0)) && left=0
    text="$G_AWAKE $(fmt_left "$left")"
  elif [[ $label == window* ]]; then
    text="$G_AWAKE win"
  else
    text="$G_AWAKE on"
  fi
  jq -cn --arg t "$text" --arg tip "Keep awake: $label\nclick: off, right click: choose duration" \
    '{text: $t, class: "on", tooltip: ($tip | gsub("\\\\n"; "\n"))}'
}

menu() {
  local pick
  command -v rofi >/dev/null 2>&1 || { note "Keep awake" "rofi not found"; return 1; }
  pick=$(printf '%s\n' '15 minutes' '1 hour' '2 hours' '4 hours' 'Until switched off' 'Off' |
    rofi -dmenu -i -p 'keep awake') || return 0
  case $pick in
    '15 minutes') run 15m ;;
    '1 hour') run 1h ;;
    '2 hours') run 2h ;;
    '4 hours') run 4h ;;
    'Until switched off') run until-off ;;
    Off) run off ;;
  esac
}

window_label() { # label from the window class
  local a=$1 c
  c=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$a" '.[] | select(.address == $a) | .class' 2>/dev/null)
  printf 'window %s' "${c:-$a}"
}

run() {
  local secs
  case ${1:-toggle} in
    __hold) hold "${2:?}" "${3:-}" ;;
    off | stop) if ((DRY)); then echo "would release the inhibitor"; else stop_holder; note "Keep awake: off"; poke_bar; fi ;;
    until-off | on | forever) start forever 0 "until switched off" ;;
    toggle) if active; then run off; else run until-off; fi ;;
    window) [[ -n ${2:-} ]] || { echo "usage: keep-awake.sh window ADDRESS" >&2; return 2; }
      # a second call for the same window releases it
      if active && [[ $(cat "$WINF" 2>/dev/null) == "$2" ]]; then run off; return; fi
      start window "$2" "$(window_label "$2")" ;;
    status) status ;;
    waybar) waybar ;;
    menu) menu ;;
    *)
      if secs=$(parse_secs "$1") && ((secs > 0)); then
        start secs "$secs" "$1"
      else
        echo "usage: keep-awake.sh 15m|1h|2h|until-off|toggle|off|status|window ADDR|waybar|menu [--dry-run]" >&2
        return 2
      fi ;;
  esac
}

run "$@"
