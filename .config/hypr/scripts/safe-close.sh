#!/usr/bin/env bash
# SUPER+W: close the active window. For the classes in ~/.config/hypr/protected-classes (browsers, terminals,
# Telegram) the first press only shows a dunst hint; a second press on the same window within 1 s closes it.
#   safe-close.sh              close (or arm) the active window
#   safe-close.sh --check [C]  print whether class C (default: the active window's) is protected
set -u

list="$HOME/.config/hypr/protected-classes"
state="${XDG_RUNTIME_DIR:-/tmp}/safe-close.state"
window_ms=1000

is_protected() {
  [[ -r $list ]] || return 1
  grep -qixF -- "$1" < <(grep -vE '^[[:space:]]*(#|$)' "$list")
}

if [[ ${1:-} == --check ]]; then
  c=${2:-$(hyprctl activewindow -j | jq -r '.class // ""')}
  if is_protected "$c"; then echo "protected: $c"; else echo "plain: $c"; fi
  exit 0
fi

aw=$(hyprctl activewindow -j) || exit 0
addr=$(jq -r '.address // ""' <<<"$aw")
class=$(jq -r '.class // ""' <<<"$aw")
[[ -n $addr ]] || exit 0

if is_protected "$class"; then
  now=$(date +%s%3N)
  if [[ -r $state ]]; then
    read -r last_addr last_ms <"$state"
    if [[ $last_addr == "$addr" ]] && ((now - last_ms < window_ms)); then
      rm -f "$state"
      exec hyprd killactive
    fi
  fi
  printf '%s %s\n' "$addr" "$now" >"$state"
  notify-send -a safe-close -u low -t "$window_ms" -h string:x-dunst-stack-tag:safe-close \
    "Press SUPER+W again to close" "$class"
  exit 0
fi

exec hyprd killactive
