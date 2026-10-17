#!/usr/bin/env bash
# lid: "keep working with the lid closed" toggle and the lid switch handler.
#
#   lid.sh toggle | on | off     hold / release a `systemd-inhibit --what=handle-lid-switch` (user process, no sudo)
#   lid.sh status                exit 0 + "on" while held, exit 1 + "off" otherwise
#   lid.sh waybar                JSON for the custom/lid module (empty text while off)
#   lid.sh panel [toggle|on|off] the laptop panel on/off (SUPER+CTRL+Delete); refuses to switch the only screen off
#   lid.sh mirror [toggle|on|off] the external monitor mirrors the laptop panel (SUPER+CTRL+ALT+Delete) and back
#   lid.sh recover               re-enable the laptop panel when no other monitor is left (monitor.removed hook)
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
G_LID='󰌢'
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

note() {
  if ((DRY)); then echo "note: $*"; return 0; fi
  notify-send -a lid -h string:x-dunst-stack-tag:lid -t 2500 "$@" 2>/dev/null || true
}
poke_bar() { pkill -o -u "$UID" -RTMIN+8 -x waybar 2>/dev/null || true; }   # signal 8 = waybar toggles drawer
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

# the first external monitor (name), empty when there is none
external_name() {
  hyprctl monitors -j 2>/dev/null | jq -r --arg p "$PANEL" '[.[] | select(.name != $p and (.disabled | not))][0].name // empty' 2>/dev/null
}

panel_disabled() {
  hyprctl monitors all -j 2>/dev/null | jq -e --arg p "$PANEL" 'any(.[]; .name == $p and .disabled)' >/dev/null 2>&1
}

# Lua: re-apply the rule of monitors.lua for one output (the output-specific rule first, then the fallback rule with output "")
monitor_rule_lua() {
  printf 'for _, m in ipairs(dofile(%s)) do if m.output == %s or m.output == "" then local r = {}; for k, v in pairs(m) do r[k] = v end; r.output = %s; hl.monitor(r); break end end' \
    "$(jq -Rn --arg v "$MONITORS" '$v')" "$(jq -Rn --arg v "$1" '$v')" "$(jq -Rn --arg v "$1" '$v')"
}

panel_cmd() { # on | off | toggle
  local want=${1:-toggle} off=0 ext
  panel_disabled && off=1
  [[ $want == toggle ]] && { ((off)) && want=on || want=off; }
  if [[ $want == off ]]; then
    ((off)) && return 0
    ext=$(external_name)
    if [[ -z $ext ]]; then
      note -u normal "Laptop panel stays on" "no external monitor is connected (the only screen is never switched off)"
      ((DRY)) && echo "refused: no external monitor"
      return 0
    fi
    do_cmd hyprctl eval "hl.monitor({ output = \"$PANEL\", disabled = true })"
    note "Laptop panel off" "external monitor: $ext (SUPER+CTRL+Delete brings it back)"
  else
    ((off)) || return 0
    do_cmd hyprctl eval "$(panel_enable_lua)"
    note "Laptop panel on" ""
  fi
}

mirror_cmd() { # on | off | toggle: the external monitor shows the laptop panel
  local want=${1:-toggle} ext mirrored=0
  ext=$(external_name)
  if [[ -z $ext ]]; then
    note -u normal "Mirroring needs a second monitor" "no external monitor is connected"
    ((DRY)) && echo "refused: no external monitor"
    return 0
  fi
  hyprctl monitors -j 2>/dev/null | jq -e --arg e "$ext" 'any(.[]; .name == $e and (.mirrorOf != "none"))' >/dev/null 2>&1 && mirrored=1
  [[ $want == toggle ]] && { ((mirrored)) && want=off || want=on; }
  if [[ $want == on ]]; then
    ((mirrored)) && return 0
    panel_disabled && do_cmd hyprctl eval "$(panel_enable_lua)"
    do_cmd hyprctl eval "hl.monitor({ output = \"$ext\", mode = \"preferred\", position = \"auto\", scale = 1, mirror = \"$PANEL\" })"
    note "Mirroring" "$ext shows the laptop panel (SUPER+CTRL+ALT+Delete to stop)"
  else
    ((mirrored)) || return 0
    do_cmd hyprctl eval "$(monitor_rule_lua "$ext")"
    note "Mirroring off" "$ext is a separate screen again"
  fi
}

# the external monitor went away while the panel was switched off: bring the panel back (never end up with no screen)
recover() {
  if panel_disabled && [[ -z $(external_name) ]]; then
    do_cmd hyprctl eval "$(panel_enable_lua)"
    note "Laptop panel on" "the external monitor is gone"
  fi
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
    jq -cn --arg t "$G_LID" '{text: $t, class: "enabled", tooltip: "Lid closed: keep working (no suspend on close)\n\nL: toggle"}'
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
  panel) panel_cmd "${2:-toggle}" ;;
  mirror) mirror_cmd "${2:-toggle}" ;;
  recover) recover ;;
  *) echo "usage: lid.sh toggle|on|off|status|waybar|panel [toggle|on|off]|mirror [toggle|on|off]|recover|event close|open [--dry-run]" >&2; exit 2 ;;
esac
