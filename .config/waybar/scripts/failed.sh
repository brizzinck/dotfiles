#!/usr/bin/env bash
# Waybar custom/failed: failed system/user units plus services currently in a restart loop
# (Restart=always units stay "active" between crashes and never show up in --failed).
threshold=5

mapfile -t failed < <({ systemctl --failed --no-legend --plain
  systemctl --user --failed --no-legend --plain; } 2>/dev/null | awk '{print $1}')

# Alert only while a unit is actually in a restart loop: waiting for its next restart (auto-restart / activating),
# or its NRestarts counter grew since the previous check (and is at least $threshold). NRestarts alone is cumulative
# for the unit's lifetime, so a recovered unit would otherwise stay in the bar forever.
state_dir=${XDG_RUNTIME_DIR:-/tmp}
looping=()
for scope in system user; do
  flag=--system
  [[ $scope == user ]] && flag=--user
  state="$state_dir/waybar-failed-nrestarts.$scope"
  declare -A prev=()
  if [[ -r $state ]]; then
    while read -r unit n; do prev[$unit]=$n; done <"$state"
  fi
  new_state=""
  while read -r unit active sub n; do
    [[ -n $unit ]] || continue
    [[ $n =~ ^[0-9]+$ ]] || n=0
    new_state+="$unit $n"$'\n'
    if [[ $sub == auto-restart || $active == activating ]]; then
      looping+=("$unit ($scope, $sub, $n restarts)")
    elif [[ -n ${prev[$unit]:-} ]] && (( n >= threshold && n > prev[$unit] )); then
      looping+=("$unit ($scope, restarted again, $n restarts)")
    fi
  done < <(systemctl "$flag" show '*.service' -p Id -p ActiveState -p SubState -p NRestarts 2>/dev/null |
    awk -F= '/^Id=/ {id=$2} /^ActiveState=/ {a=$2} /^SubState=/ {s=$2} /^NRestarts=/ {n=$2}
             /^$/ && id != "" {print id, a, s, n; id=""} END {if (id != "") print id, a, s, n}')
  printf '%s' "$new_state" >"$state" 2>/dev/null || true
  unset prev
done

count=$(( ${#failed[@]} + ${#looping[@]} ))
if (( count == 0 )); then
  echo '{"text":""}'
  exit 0
fi

tooltip=$(printf '%s\n' "${failed[@]/#/failed: }" "${looping[@]/#/restarting: }" | sed '/^[a-z]*: $/d')
jq -cn --arg c "$count" --arg t "$tooltip" '{text: "󰀨 \($c)", class: "bad", tooltip: $t}'
