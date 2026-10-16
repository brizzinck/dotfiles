#!/usr/bin/env bash
# health: waybar custom/health. Failed or restart-looping units (failed.sh, critical) plus the conditions sysalert is
# currently alerting about (memory pressure, CPU temperature, sustained load, low disk: warning). Empty when clean.
# Run it through cache.sh (failed.sh keeps NRestarts state between runs, so two bars must share one run).
# The JSON carries "items" (kind unit|alert, scope, unit, detail) next to the badge fields: health-details.sh (left click)
# reads the same cached run, so the badge and the details view cannot disagree.
set -u

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
G_HEALTH='󰀨'
STATE="${SYSALERT_STATE:-${XDG_RUNTIME_DIR:-/tmp}/sysalert}"

units=0 lines=() items='[]'
f=$("$HERE/failed.sh" 2>/dev/null)
if [[ -n $f ]] && [[ $(jq -r '.text // ""' <<<"$f") != "" ]]; then
  units=$(jq -r '.text' <<<"$f" | tr -dc '0-9')
  units=${units:-0}
  mapfile -t lines < <(jq -r '.tooltip // empty' <<<"$f")
  items=$(jq -c '.items // []' <<<"$f")
fi

alerts=() alert_items=() r='' mp=''

shopt -s nullglob
for a in "$STATE"/alerted.*; do
  key=${a##*/alerted.}
  case $key in
    memory)
      r=$(free -m | awk '/^Mem:/ {printf "%d MiB available of %d MiB", $7, $2}')
      alerts+=("memory pressure - $r") alert_items+=("memory"$'\t'"memory pressure"$'\t'"$r") ;;
    temp)
      r=$(sensors 2>/dev/null | awk '/Tctl|Tdie|Package id 0/ {print $2 " (" $1 ")"; exit}')
      r="CPU at ${r:-an unknown temperature}, above the sysalert limit"
      alerts+=("CPU temperature - $r") alert_items+=("temp"$'\t'"CPU temperature"$'\t'"$r") ;;
    load)
      r="load average $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) cores"
      alerts+=("sustained load - $r") alert_items+=("load"$'\t'"sustained load"$'\t'"$r") ;;
    disk*)
      mp=${key#disk}; mp=${mp//_//}
      r=$(df --output=pcent,avail -h "$mp" 2>/dev/null | awk 'NR == 2 {print $1 " used, " $2 " free"}')
      r="${mp} ${r:-usage unknown}"
      alerts+=("low disk space (${mp}) - $r") alert_items+=("$key"$'\t'"low disk space ($mp)"$'\t'"$r") ;;
  esac
done

total=$((units + ${#alerts[@]}))
if ((total == 0)); then echo '{"text":""}'; exit 0; fi

class=warning
((units > 0)) && class=critical
tip=("System health: $total issue(s)")
((${#lines[@]})) && tip+=("${lines[@]}")
for a in "${alerts[@]}"; do tip+=("alert: $a"); done
tip+=("" "L: details · R: doctor")
if ((${#alert_items[@]})); then
  items=$(printf '%s\n' "${alert_items[@]}" | jq -Rn --argjson u "$items" '$u + [inputs | split("\t") | {kind: "alert", scope: "system", unit: .[0], detail: .[1], reason: .[2]}]')
fi
printf '%s\n' "${tip[@]}" | jq -Rs --arg t "$G_HEALTH $total" --arg c "$class" --argjson i "$items" '{text: $t, class: $c, tooltip: rtrimstr("\n"), items: $i}' | jq -c .
