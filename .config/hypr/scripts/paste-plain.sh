#!/usr/bin/env bash
# paste-plain: paste the clipboard as plain text (SUPER+CTRL+V). Drops html/rtf/image formats by re-copying only
# text/plain, then sends the paste shortcut to the active window (CTRL+SHIFT+V for terminals).
#   --dry-run  print what would be sent
set -u
DRY=0; [[ ${1:-} == --dry-run ]] && DRY=1
class=$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // ""')
case ${class,,} in
  *ghostty* | float.tui | alacritty | kitty | foot | org.wezfurlong.wezterm | xterm*) mods="CTRL SHIFT" ;;
  *) mods="CTRL" ;;
esac
if ((DRY)); then echo "class=$class: wl-paste -n -t text/plain | wl-copy -t text/plain; sendshortcut ${mods/ /+},V"; exit 0; fi
txt=$(wl-paste -n -t text/plain 2>/dev/null; echo x)
txt=${txt%x}
[[ -n $txt ]] || { notify-send -a paste-plain -t 2000 "Paste as plain text" "clipboard has no text"; exit 0; }
# keep the password-manager hint: a sensitive copy (2FA code, password) must stay out of cliphist and keep its 30 s clear
sens=()
if wl-paste --list-types 2>/dev/null | grep -qx 'x-kde-passwordManagerHint'; then sens=(--sensitive); fi
printf '%s' "$txt" | wl-copy "${sens[@]}" -t text/plain
sleep 0.25   # let the physical SUPER+CTRL be released first
hyprctl dispatch sendshortcut "${mods// /_},V,activewindow" >/dev/null 2>&1 || wtype -M ctrl -k v -m ctrl
if ((${#sens[@]})); then "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/vault.sh" arm-clear; fi
