#!/usr/bin/env bash
# Waybar custom/updates: pending repo updates (checkupdates, from pacman-contrib) plus AUR (yay -Qua).
# Hidden when there is nothing to update. Refresh now: pkill -RTMIN+9 waybar
repo=""
aur=""
command -v checkupdates >/dev/null && repo=$(checkupdates 2>/dev/null)
command -v yay >/dev/null && aur=$(yay -Qua 2>/dev/null)

nr=0
na=0
[[ -n $repo ]] && nr=$(wc -l <<<"$repo")
[[ -n $aur ]] && na=$(wc -l <<<"$aur")
total=$(( nr + na ))

if (( total == 0 )); then
  echo '{"text":""}'
  exit 0
fi

tooltip=$(printf '%s\n%s\n' "$repo" "$aur" | sed '/^$/d' | head -25)
jq -cn --arg c "$total" --arg t "repo $nr, aur $na"$'\n'"$tooltip" \
  '{text: "󰏗 \($c)", class: "updates", tooltip: $t}'
