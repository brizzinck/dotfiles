#!/usr/bin/env bash
# power-profile: power profile via TLP Profiles Daemon (tlp-pd).
#   power-profile.sh get                 print the active profile (power-saver | balanced | performance)
#   power-profile.sh set <profile>       switch (polkit allows the active session, no sudo)
#   power-profile.sh cycle               power-saver -> balanced -> performance -> power-saver
#   power-profile.sh waybar              JSON for the custom/power module
#   power-profile.sh menu                picker (fzf-menu)
# Backends in order for `get`: system D-Bus net.hadess.PowerProfiles (the API tlp-pd implements, 4 ms), tlpctl (170 ms), session
# D-Bus, read-only /sys/firmware/acpi/platform_profile (last resort: tlp-pd balanced on battery shows low-power there).
set -u

ORDER=(power-saver balanced performance)
G_SAVER='󰌪' G_BAL='󰗑' G_PERF='󰓅'
note() { notify-send -a power-profile -h string:x-dunst-stack-tag:power-profile -t 2500 "$@" 2>/dev/null || true; }
poke_bar() { rm -f "${XDG_RUNTIME_DIR:-/tmp}/waybar-cache/toggles.json"; pkill -o -u "$UID" -RTMIN+8 -x waybar 2>/dev/null || true; }   # signal 8 = waybar toggles drawer
DBUS=(net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles)

get() {
  local p
  # D-Bus first (4 ms, the same value tlp-pd serves); `tlpctl get` is a python start (170 ms) and stays the fallback
  if p=$(busctl --system get-property "${DBUS[@]}" ActiveProfile 2>/dev/null | awk '{ gsub(/"/, "", $2); print $2 }') && [[ -n $p ]]; then echo "$p"; return 0; fi
  if command -v tlpctl >/dev/null 2>&1 && p=$(tlpctl get 2>/dev/null) && [[ -n $p ]]; then echo "$p"; return 0; fi
  if p=$(busctl get-property "${DBUS[@]}" ActiveProfile 2>/dev/null | awk '{ gsub(/"/, "", $2); print $2 }') && [[ -n $p ]]; then echo "$p"; return 0; fi
  if [[ -r /sys/firmware/acpi/platform_profile ]]; then
    case $(cat /sys/firmware/acpi/platform_profile) in
      low-power | quiet) echo power-saver ;;
      performance) echo performance ;;
      *) echo balanced ;;
    esac
    return 0
  fi
  return 1
}

can_set() { command -v tlpctl >/dev/null 2>&1 || busctl introspect net.hadess.PowerProfiles /net/hadess/PowerProfiles >/dev/null 2>&1; }

set_profile() {
  local want=$1 ok=0
  case $want in power-saver | balanced | performance) ;; *) echo "unknown profile: $want" >&2; return 2 ;; esac
  if command -v tlpctl >/dev/null 2>&1; then
    tlpctl set "$want" >/dev/null 2>&1 && ok=1
  elif busctl introspect net.hadess.PowerProfiles /net/hadess/PowerProfiles >/dev/null 2>&1; then
    busctl set-property "${DBUS[@]}" ActiveProfile s "$want" >/dev/null 2>&1 && ok=1
  else
    note -u normal "Power profile" "tlp-pd is not installed or running (sudo ~/dotfiles/apply-system.sh --only install && sudo ~/dotfiles/apply-system.sh --only services)"
    return 1
  fi
  if ((ok)); then note "Power profile: $want"; poke_bar; else note -u critical "Power profile" "could not switch to $want"; return 1; fi
}

cycle() {
  local cur i next
  cur=$(get) || cur=balanced
  for i in "${!ORDER[@]}"; do [[ ${ORDER[$i]} == "$cur" ]] && break; done
  next=${ORDER[$(((i + 1) % ${#ORDER[@]}))]}
  set_profile "$next"
}

waybar() {
  local p icon
  if ! p=$(get); then echo '{"text":""}'; return 0; fi
  case $p in power-saver) icon=$G_SAVER ;; performance) icon=$G_PERF ;; *) icon=$G_BAL ;; esac
  # class: enabled = a non-default profile, normal = balanced (the colour roles of waybar/style.css)
  jq -cn --arg t "$icon" --arg c "$([[ $p == balanced ]] && echo normal || echo enabled)" --arg tip "Power profile: $p\n\nL: next profile · R: choose" \
    '{text: $t, class: $c, tooltip: ($tip | gsub("\\\\n"; "\n"))}'
}

menu() {
  local pick
  pick=$(printf '%s\n' "${ORDER[@]}" | fzf-menu -p 'power profile' --header "now: $(get)") || return 0
  set_profile "$pick"
}

case ${1:-cycle} in
  get) get ;;
  set) set_profile "${2:-}" ;;
  cycle) cycle ;;
  waybar) waybar ;;
  menu) menu ;;
  *) echo "usage: power-profile.sh get|set P|cycle|waybar|menu" >&2; exit 2 ;;
esac
