#!/usr/bin/env bash
# health: waybar custom/health. Failed or restart-looping units (failed.sh, critical) plus the conditions sysalert is
# currently alerting about (memory pressure, CPU temperature, sustained load, low disk: warning). Empty when clean.
# Run it through cache.sh (failed.sh keeps NRestarts state between runs, so two bars must share one run).
set -u

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
G_HEALTH='󰀨'
STATE="${SYSALERT_STATE:-${XDG_RUNTIME_DIR:-/tmp}/sysalert}"

units=0 lines=()
f=$("$HERE/failed.sh" 2>/dev/null)
if [[ -n $f ]] && [[ $(jq -r '.text // ""' <<<"$f") != "" ]]; then
  units=$(jq -r '.text' <<<"$f" | tr -dc '0-9')
  units=${units:-0}
  mapfile -t lines < <(jq -r '.tooltip // empty' <<<"$f")
fi

alerts=()
shopt -s nullglob
for a in "$STATE"/alerted.*; do
  key=${a##*/alerted.}
  case $key in
    memory) alerts+=("memory pressure") ;;
    temp) alerts+=("CPU temperature") ;;
    load) alerts+=("sustained load") ;;
    disk*) alerts+=("low disk space (${key#disk})") ;;
  esac
done

total=$((units + ${#alerts[@]}))
if ((total == 0)); then echo '{"text":""}'; exit 0; fi

class=warning
((units > 0)) && class=critical
tip=("System health: $total issue(s)")
((${#lines[@]})) && tip+=("${lines[@]}")
for a in "${alerts[@]}"; do tip+=("alert: $a"); done
tip+=("" "L: failed units · R: doctor")
printf '%s\n' "${tip[@]}" | jq -Rs --arg t "$G_HEALTH $total" --arg c "$class" '{text: $t, class: $c, tooltip: rtrimstr("\n")}' | jq -c .
