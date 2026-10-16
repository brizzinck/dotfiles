# shellcheck shell=bash
# Shared paste helpers (sourced by paste-plain.sh and clipboard.sh): which shortcut a window class pastes with, and
# how to send it. The key is the physical V key (xkb keycode 55), so it works while the ua or ru layout is active:
# `sendshortcut V` resolves the name against the ACTIVE layout and fails on a Cyrillic one.
#   paste_class [ADDRESS]        class of that window (default: the active one)
#   paste_mods CLASS             "CTRL" or "CTRL SHIFT" (terminals)
#   paste_send [ADDRESS]         send the paste shortcut to ADDRESS (default: active window); PASTE_DRY=1 only prints

PASTE_KEYCODE=55
# shellcheck source=type-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/type-guard.sh"

paste_class() {
  if [[ -n ${1:-} ]]; then
    hyprctl clients -j 2>/dev/null | jq -r --arg a "$1" '[.[] | select(.address == $a)][0].class // ""'
  else
    hyprctl activewindow -j 2>/dev/null | jq -r '.class // ""'
  fi
}

paste_mods() {
  case ${1,,} in
    *ghostty* | float.tui | alacritty | kitty | foot | org.wezfurlong.wezterm | xterm*) echo "CTRL SHIFT" ;;
    *) echo "CTRL" ;;
  esac
}

paste_send() {
  local addr=${1:-} class mods target out
  class=$(paste_class "$addr")
  mods=$(paste_mods "$class")
  target=${addr:+address:$addr}
  if [[ ${PASTE_DRY:-0} == 1 ]]; then
    echo "class=${class:-?}: sendshortcut ${mods// /_},code:$PASTE_KEYCODE,${target:-activewindow}"
    return 0
  fi
  out=$(hyprd sendshortcut "${mods// /_},code:$PASTE_KEYCODE,${target:-activewindow}" 2>&1)
  if [[ $out != ok ]]; then
    # last resort: a virtual keyboard types into whatever is focused, so only for the active window or for the
    # recorded window while it still has focus (it may have closed or lost focus since the menu opened)
    if [[ -n $addr ]] && ! tg_ok "$addr" paste; then return 1; fi
    if [[ $mods == "CTRL SHIFT" ]]; then wtype -M ctrl -M shift -k v -m shift -m ctrl; else wtype -M ctrl -k v -m ctrl; fi
  fi
}
