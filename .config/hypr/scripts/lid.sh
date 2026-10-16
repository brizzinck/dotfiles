#!/usr/bin/env bash
# lid: "keep working with the lid closed" toggle and the lid switch handler.
#
#   lid.sh toggle | on | off     hold / release a `systemd-inhibit --what=handle-lid-switch` (user process, no sudo)
#   lid.sh status                exit 0 + "on" while held, exit 1 + "off" otherwise
#   lid.sh waybar                JSON for the custom/lid module (empty text while off)
#   lid.sh event close|open      called by the Hyprland lid switch binds (hyprland.lua):
#                                  close: another monitor active -> disable eDP-1 only;
#                                         otherwise, while the toggle is on -> blank eDP-1 (dpms off);
#                                         otherwise logind suspends as usual (default lid action)
#                                  open:  re-enable eDP-1 (monitor rule from monitors.lua) / dpms on
#   --dry-run                    print the commands instead of running them
#
# With the inhibitor held logind ignores the lid, so agents and builds keep running with the lid shut.
# Docked (external monitor) logind already ignores the lid; the handler just turns the laptop panel off.
set -u

PANEL="${LID_PANEL:-eDP-1}"
STATE="${XDG_RUNTIME_DIR:-/tmp}/lid-awake"
PIDF="$STATE/pid"
MARK="$STATE/panel-off"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
MONITORS="$HOME/.config/hypr/monitors.lua"
G_LID='󰛆'
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

note() { notify-send -a lid -h string:x-dunst-stack-tag:lid -t 2500 "$@" 2>/dev/null || true; }
poke_bar() { pkill -RTMIN+13 waybar 2>/dev/null || true; }
do_cmd() { if ((DRY)); then echo "would run: $*"; else "$@"; fi; }

holder_pid() {
  local p
  [[ -r $PIDF ]] || return 1
  p=$(cat "$PIDF" 2>/dev/null)
  [[ $p =~ ^[0-9]+$ ]] && [[ -r /proc/$p/cmdline ]] && tr '\0' ' ' <"/proc/$p/cmdline" | grep -q -- '__hold' || return 1
  printf '%s\n' "$p"
}
active() { holder_pid >/dev/null; }

hold() { # runs as the child of systemd-inhibit
  mkdir -p "$STATE"
  echo $$ >"$PIDF"
  trap 'rm -f "$PIDF"; poke_bar; exit 0' TERM INT HUP
  while :; do sleep 3600 & wait $!; done
}

enable() {
  local _
  if ((DRY)); then
    echo "would run: systemd-inhibit --what=handle-lid-switch --who=lid-awake --why='keep working with the lid closed' --mode=block $SELF __hold"
    return 0
  fi
  active && return 0
  command -v systemd-inhibit >/dev/null 2>&1 || { note -u critical "Lid" "systemd-inhibit not found"; return 1; }
  mkdir -p "$STATE"
  nohup setsid systemd-inhibit --what=handle-lid-switch --who=lid-awake --why="keep working with the lid closed" --mode=block \
    "$SELF" __hold >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do active && break; sleep 0.2; done
  if active; then
    note "Lid closed: keep working" "closing the lid will not suspend"
  else
    note -u critical "Lid toggle failed" "could not take the inhibitor"
    return 1
  fi
  poke_bar
}

disable() {
  local p
  if ((DRY)); then echo "would release the lid inhibitor"; return 0; fi
  if p=$(holder_pid); then kill "$p" 2>/dev/null || true; fi
  rm -f "$PIDF"
  note "Lid closed: suspend (default)" "closing the lid suspends again"
  poke_bar
}

# monitors other than the laptop panel that are enabled
external_count() {
  hyprctl monitors -j 2>/dev/null | jq --arg p "$PANEL" '[.[] | select(.name != $p and (.disabled | not))] | length' 2>/dev/null || echo 0
}

# Lua expression that re-applies the panel's monitor rule from monitors.lua (the data hyprland.lua loads)
panel_enable_lua() {
  printf 'for _, m in ipairs(dofile(%s)) do if m.output == %s then hl.monitor(m) end end' \
    "$(jq -Rn --arg v "$MONITORS" '$v')" "$(jq -Rn --arg v "$PANEL" '$v')"
}

event() {
  case ${1:-} in
    close)
      if [[ $(external_count) -gt 0 ]]; then
        do_cmd hyprctl eval "hl.monitor({ output = \"$PANEL\", disabled = true })"
        ((DRY)) || { mkdir -p "$STATE"; echo disabled >"$MARK"; }
      elif active; then
        do_cmd hyprd dpms off "$PANEL"
        ((DRY)) || { mkdir -p "$STATE"; echo dpms >"$MARK"; }
      else
        ((DRY)) && echo "nothing to do: no external monitor and the toggle is off (logind suspends)"
      fi ;;
    open)
      local m=""
      [[ -r $MARK ]] && m=$(cat "$MARK" 2>/dev/null)
      if [[ $m == dpms ]]; then
        do_cmd hyprd dpms on "$PANEL"
      elif [[ $m == disabled ]] || hyprctl monitors all -j 2>/dev/null | jq -e --arg p "$PANEL" 'any(.[]; .name == $p and .disabled)' >/dev/null 2>&1; then
        do_cmd hyprctl eval "$(panel_enable_lua)"
      fi
      ((DRY)) || rm -f "$MARK" ;;
    *) echo "usage: lid.sh event close|open" >&2; return 2 ;;
  esac
}

waybar() {
  if active; then
    jq -cn --arg t "$G_LID" '{text: $t, class: "on", tooltip: "Lid closed: keep working (no suspend on close)\nclick: off"}'
  else
    echo '{"text":""}'
  fi
}

case ${1:-toggle} in
  __hold) hold ;;
  on) enable ;;
  off) disable ;;
  toggle) if active; then disable; else enable; fi ;;
  status) if active; then echo on; else echo off; exit 1; fi ;;
  waybar) waybar ;;
  event) event "${2:-}" ;;
  *) echo "usage: lid.sh toggle|on|off|status|waybar|event close|open [--dry-run]" >&2; exit 2 ;;
esac
