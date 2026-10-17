#!/usr/bin/env bash
# Waybar custom/failed: failed system/user units plus services currently in a restart loop
# (Restart=always units stay "active" between crashes and never show up in --failed).
# The JSON also carries "items" (kind scope unit detail), the machine-readable list that health-details.sh shows, so the
# badge and the details view come from one run. A stopped or disabled unit is inactive, never failed or looping.
threshold=5      # NRestarts at which a looping unit alerts at once
min_restarts=2   # restarts a unit needs before waiting for / starting again counts as looping at all

# One human line of why a unit is unhappy: the last journal line of the unit that is not systemd's own bookkeeping
# ("Main process exited", "Scheduled restart job", ...), else the unit's Result / exit status, else why nothing is known.
reason() { # reason SCOPE UNIT
  local flag=--system raw line res st unreadable=0
  [[ $1 == user ]] && flag=--user
  raw=$(journalctl "$flag" -u "$2" -n 60 -o cat --no-pager 2>&1)
  # journalctl prints a hint on stderr when the caller may not read other users' / the system journal
  grep -q 'not seeing messages from other users' <<<"$raw" && unreadable=1
  raw=$(grep -Ev '^(Hint: |-- |No journal files were found)' <<<"$raw")
  line=$(grep -Ev 'Main process exited|Failed with result|Scheduled restart job|Consumed .* CPU time|^(Started|Starting|Stopped|Stopping) |Deactivated successfully|Start request repeated|Service RestartSec' <<<"$raw" |
    tail -n 1)
  if [[ -z $line ]]; then
    read -r res st < <(systemctl "$flag" show "$2" -p Result --value -p ExecMainStatus --value 2>/dev/null | paste -sd' ')
    if [[ $(systemctl "$flag" show "$2" -p LoadState --value 2>/dev/null) == not-found ]]; then
      line="unit file is gone (not loaded)"
    elif [[ -n ${res:-} && $res != success ]]; then
      line="result $res, exit status ${st:-?}"
      if [[ -z $raw ]]; then line+=", no journal entries"; else line+=", only systemd start/stop messages in the journal"; fi
    elif ((unreadable)); then
      line="this user may not read the journal of the unit (add the user to systemd-journal)"
    elif [[ -z $raw ]]; then
      line="no journal entries (the unit never logged, or they were rotated)"
    else
      line="the journal only has systemd start/stop messages, nothing from the unit itself"
    fi
  fi
  line=${line//$'\t'/ }
  printf '%s' "${line:0:140}"
}

mapfile -t failed < <({ systemctl --failed --no-legend --plain 2>/dev/null | awk '{print "system", $1}'
  systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print "user", $1}'; } | awk 'NF == 2')

# Alert only while a unit is really in a restart loop. A unit in a normal start job (a D-Bus activated daemon, a oneshot
# service run by a timer) is "activating" with 0 restarts and must never alert. A unit counts as looping when it is
# waiting for its next restart (auto-restart) or starting again (activating) AND has already restarted $min_restarts
# times; it alerts when that holds on two consecutive runs or at $threshold restarts. Besides that, a unit alerts once
# its NRestarts counter grew since the previous run and is at least $threshold. NRestarts alone is cumulative for the
# unit's lifetime, so a recovered unit would otherwise stay in the bar forever.
state_dir=${XDG_RUNTIME_DIR:-/tmp}
looping=()
items=()
for scope in system user; do
  flag=--system
  [[ $scope == user ]] && flag=--user
  state="$state_dir/waybar-failed-nrestarts.$scope"
  declare -A prev=() prev_susp=()
  if [[ -r $state ]]; then
    while read -r unit n s; do prev[$unit]=$n prev_susp[$unit]=${s:-0}; done <"$state"
  fi
  new_state=""
  while read -r unit active sub n; do
    [[ -n $unit ]] || continue
    [[ $n =~ ^[0-9]+$ ]] || n=0
    susp=0
    if [[ $sub == auto-restart || $active == activating ]] && (( n >= min_restarts )); then susp=1; fi
    new_state+="$unit $n $susp"$'\n'
    if (( susp )) && { [[ ${prev_susp[$unit]:-0} == 1 ]] || (( n >= threshold )); }; then
      looping+=("$unit ($scope, $sub, $n restarts)")
      items+=("restarting"$'\t'"$scope"$'\t'"$unit"$'\t'"$sub, $n restarts"$'\t'"$(reason "$scope" "$unit")")
    elif [[ -n ${prev[$unit]:-} ]] && (( n >= threshold && n > prev[$unit] )); then
      looping+=("$unit ($scope, restarted again, $n restarts)")
      items+=("restarting"$'\t'"$scope"$'\t'"$unit"$'\t'"restarted again, $n restarts"$'\t'"$(reason "$scope" "$unit")")
    fi
  done < <(systemctl "$flag" show '*.service' -p Id -p ActiveState -p SubState -p NRestarts 2>/dev/null |
    awk -F= '/^Id=/ {id=$2} /^ActiveState=/ {a=$2} /^SubState=/ {s=$2} /^NRestarts=/ {n=$2}
             /^$/ && id != "" {print id, a, s, n; id=""} END {if (id != "") print id, a, s, n}')
  printf '%s' "$new_state" >"$state" 2>/dev/null || true
  unset prev prev_susp
done

count=$(( ${#failed[@]} + ${#looping[@]} ))
if (( count == 0 )); then
  echo '{"text":""}'
  exit 0
fi

for f in "${failed[@]}"; do
  items+=("failed"$'\t'"${f% *}"$'\t'"${f#* }"$'\t'"failed"$'\t'"$(reason "${f% *}" "${f#* }")")
done
items_json=$(printf '%s\n' "${items[@]}" | jq -Rn '[inputs | split("\t") | {kind: .[0], scope: .[1], unit: .[2], detail: .[3], reason: .[4]}]')
tooltip=$(jq -r '.[] | "\(.kind): \(.unit) (\(.scope), \(.detail)) - \(.reason)"' <<<"$items_json")
jq -cn --arg c "$count" --arg t "$tooltip" --argjson i "$items_json" '{text: "󰀨 \($c)", class: "bad", tooltip: $t, items: $i}'
