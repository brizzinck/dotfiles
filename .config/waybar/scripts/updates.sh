#!/usr/bin/env bash
# Waybar custom/updates and custom/updates#alert: pending updates (repo, AUR, flatpak, npm tools) from the state of `sysup check`.
# The module only shows; the install is started by the owner (L click = sysup in a floating terminal).
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

if [[ ${1:-} == --raw ]]; then
  # "repo<TAB>aur<TAB>flatpak<TAB>downloaded<TAB>npm" counts, then the package lines. The data comes from `sysup check`
  # (user timer, state file); a stale or missing state file triggers one real check here.
  PENDING="${XDG_STATE_HOME:-$HOME/.local/state}/sysup/pending.json"
  if [[ ! -r $PENDING ]] || (($(date +%s) - $(stat -c %Y "$PENDING") > 21600)); then
    command -v sysup >/dev/null && sysup check --quiet >/dev/null 2>&1
  fi
  if [[ -r $PENDING ]]; then
    jq -r '[(.repo | length), (.aur | length), (.flatpak | length), .downloaded, (.npm | length)] | @tsv' "$PENDING"
    jq -r '(.repo[] | "\(.name) \(.old) -> \(.new)\(if .downloaded then " (downloaded)" else "" end)"),
           (.aur[] | "\(.name) \(.old) -> \(.new) (AUR)"),
           (.flatpak[] | "\(.name) (flatpak)"),
           (.npm[] | "\(.name) \(.old) -> \(.new) (npm)")' "$PENDING" | head -25
    exit 0
  fi
  repo="" aur=""
  command -v checkupdates >/dev/null && repo=$(checkupdates 2>/dev/null)
  command -v yay >/dev/null && aur=$(yay -Qua 2>/dev/null)
  nr=0 na=0
  [[ -n $repo ]] && nr=$(wc -l <<<"$repo")
  [[ -n $aur ]] && na=$(wc -l <<<"$aur")
  printf '%s\t%s\t0\t0\t0\n' "$nr" "$na"
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
IFS=$'\t' read -r nr na nf dl nn <<<"$(head -n1 <<<"$data")"
nr=${nr:-0} na=${na:-0} nf=${nf:-0} dl=${dl:-0} nn=${nn:-0}
pkgs=$((nr + na)) # the compact-bar alert counts packages only
total=$((nr + na + nf))
tooltip=$(sed 1d <<<"$data")

# days since the last full upgrade (pacman.log is world readable; -1 = unknown)
age=-1
last=$(grep 'starting full system upgrade' "$PACLOG" 2>/dev/null | tail -n1 | sed -E 's/^\[([^]]+)\].*/\1/')
if [[ -n $last ]] && ts=$(date -d "$last" +%s 2>/dev/null); then age=$((($(date +%s) - ts) / 86400)); fi

stale=0
((pkgs >= MIN_COUNT)) && stale=1
((age > MAX_AGE_DAYS && total > 0)) && stale=1

if ((total == 0)) || { ((alert)) && ((!stale)); }; then
  echo '{"text":""}'
  exit 0
fi

class=normal
((stale)) && class=warning
head_line="Updates: $total pending (repo $nr, aur $na, flatpak $nf; npm tools $nn)"
if ((nr > 0)); then
  if ((dl >= nr)); then head_line+=$'\n'"All $nr repo packages are already downloaded (background)"; else head_line+=$'\n'"Downloaded in the background: $dl of $nr repo packages"; fi
fi
((age >= 0)) && head_line+=$'\n'"Last full upgrade: $age day(s) ago"
jq -cn --arg t "$G_UPD $total" --arg c "$class" --arg tip "$head_line"$'\n'"$tooltip"$'\n\nL: install everything · M: check now · R: pending list' \
  '{text: $t, class: $c, tooltip: $tip}'
