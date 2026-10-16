#!/usr/bin/env bash
# Waybar custom/updates and custom/updates#alert: pending repo updates (checkupdates, from pacman-contrib) plus AUR (yay -Qua).
#   updates.sh           JSON for the full bar: count (empty when nothing is pending); class normal, or warning when the
#                        compact-bar alert condition holds
#   updates.sh --alert   JSON for the compact bar: empty unless >= 50 packages are pending or the last full upgrade
#                        (pacman.log "starting full system upgrade") is more than 14 days old; class warning
#   updates.sh list      pending packages in an fzf-menu with the package info as preview (R click)
# The two bars share one checkupdates run through cache.sh (two concurrent checkupdates share a temp database).
# Refresh now: ~/.config/waybar/scripts/cache.sh --drop updates; pkill -o -u "$UID" -RTMIN+9 -x waybar
set -u

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
G_UPD='󰏗'
MIN_COUNT=50
MAX_AGE_DAYS=14
PACLOG="${PACMAN_LOG:-/var/log/pacman.log}"

if [[ ${1:-} == --raw ]]; then # one real check: "repo<TAB>aur" counts then the package lines
  repo="" aur=""
  command -v checkupdates >/dev/null && repo=$(checkupdates 2>/dev/null)
  command -v yay >/dev/null && aur=$(yay -Qua 2>/dev/null)
  nr=0 na=0
  [[ -n $repo ]] && nr=$(wc -l <<<"$repo")
  [[ -n $aur ]] && na=$(wc -l <<<"$aur")
  printf '%s\t%s\n' "$nr" "$na"
  printf '%s\n%s\n' "$repo" "$aur" | sed '/^$/d' | head -25
  exit 0
fi

if [[ ${1:-} == list ]]; then
  rows=$("$HERE/cache.sh" updates 3500 -- "${BASH_SOURCE[0]}" --raw | sed 1d)
  if [[ -z $rows ]]; then notify-send -a updates -t 2500 "Updates" "nothing is pending"; exit 0; fi
  # shellcheck disable=SC2016  # {1} is fzf's placeholder, expanded by fzf
  printf '%s\n' "$rows" | fzf-menu -p updates --preview 'pacman -Si {1} 2>/dev/null || yay -Si {1} 2>/dev/null' >/dev/null || true
  exit 0
fi

alert=0
[[ ${1:-} == --alert ]] && alert=1

data=$("$HERE/cache.sh" updates 3500 -- "${BASH_SOURCE[0]}" --raw)
IFS=$'\t' read -r nr na <<<"$(head -n1 <<<"$data")"
nr=${nr:-0} na=${na:-0}
total=$((nr + na))
tooltip=$(sed 1d <<<"$data")

# days since the last full upgrade (pacman.log is world readable; -1 = unknown)
age=-1
last=$(grep 'starting full system upgrade' "$PACLOG" 2>/dev/null | tail -n1 | sed -E 's/^\[([^]]+)\].*/\1/')
if [[ -n $last ]] && ts=$(date -d "$last" +%s 2>/dev/null); then age=$((($(date +%s) - ts) / 86400)); fi

stale=0
((total >= MIN_COUNT)) && stale=1
((age > MAX_AGE_DAYS && total > 0)) && stale=1

if ((total == 0)) || { ((alert)) && ((!stale)); }; then
  echo '{"text":""}'
  exit 0
fi

class=normal
((stale)) && class=warning
head_line="Updates: $total pending (repo $nr, aur $na)"
((age >= 0)) && head_line+=$'\n'"Last full upgrade: $age day(s) ago"
jq -cn --arg t "$G_UPD $total" --arg c "$class" --arg tip "$head_line"$'\n'"$tooltip"$'\n\nL: sysup · R: pending list' \
  '{text: $t, class: $c, tooltip: $tip}'
