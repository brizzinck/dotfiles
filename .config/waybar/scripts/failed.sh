#!/usr/bin/env bash
# Waybar custom/failed: failed system/user units plus services that restarted more than a threshold
# (Restart=always units stay "active" between crashes and never show up in --failed).
threshold=5

mapfile -t failed < <({ systemctl --failed --no-legend --plain
  systemctl --user --failed --no-legend --plain; } 2>/dev/null | awk '{print $1}')

looping=()
for scope in system user; do
  flag=--system
  [[ $scope == user ]] && flag=--user
  while read -r unit n; do
    [[ -n $unit && $n =~ ^[0-9]+$ && $n -ge $threshold ]] && looping+=("$unit ($scope, $n restarts)")
  done < <(systemctl "$flag" show '*.service' -p Id -p NRestarts 2>/dev/null |
    awk -F= '/^Id=/ {id=$2} /^NRestarts=/ {print id, $2}')
done

count=$(( ${#failed[@]} + ${#looping[@]} ))
if (( count == 0 )); then
  echo '{"text":""}'
  exit 0
fi

tooltip=$(printf '%s\n' "${failed[@]/#/failed: }" "${looping[@]/#/restarting: }" | sed '/^[a-z]*: $/d')
jq -cn --arg c "$count" --arg t "$tooltip" '{text: "󰀨 \($c)", class: "bad", tooltip: $t}'
