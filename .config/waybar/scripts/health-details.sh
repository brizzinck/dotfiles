#!/usr/bin/env bash
# health-details: left click of waybar custom/health. A fzf-menu (vim keys, float.tui) with every current health issue:
# failed system/user units, restart-looping units and the sysalert conditions (memory, CPU temperature, load, disk).
# The rows come from the "items" of the very same cached run that draws the badge (health.sh via cache.sh), so the
# badge and this view cannot disagree. The preview of a unit is `systemctl [--user] status` plus the last 30 journal
# lines; Enter opens the actions for the row (restart, stop, full journal in less, ...), then the list is rebuilt.
#
#   health-details.sh                  interactive view (Esc / q leaves)
#   health-details.sh --list           print the rows: id <TAB> label (empty when the system is healthy)
#   health-details.sh --preview ID     the preview text of one row
#   health-details.sh --actions ID     print the actions of one row: action <TAB> label
#   health-details.sh --do ID ACTION   run one action without the menu
#   --dry-run                          with --do: print the command instead of running it
#
# ID = scope:unit (scope system|user) for units, alert:KEY for sysalert conditions.
# Test hook: HEALTH_DETAILS_JSON=FILE reads the health JSON from FILE instead of the cache.
# System unit actions run in a float.tui terminal through sudo (asks there); user unit actions run directly.
set -u

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
SELF="$HERE/health-details.sh"
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

have() { command -v "$1" >/dev/null 2>&1; }

# the badge's data: the shared cache entry; FRESH=1 drops it first (after an action)
data() {
  if [[ -n ${HEALTH_DETAILS_JSON:-} ]]; then cat "$HEALTH_DETAILS_JSON"; return; fi
  [[ ${FRESH:-0} == 1 ]] && "$HERE/cache.sh" --drop health
  "$HERE/cache.sh" health 55 -- "$HERE/health.sh"
}

flag_of() { [[ $1 == user ]] && echo --user || echo --system; }

# rows: id <TAB> label. Every row carries its one-line reason ("unit (scope) restarting 5x - last error of the unit").
rows() {
  local json kind scope unit detail reason id
  json=$(data)
  while IFS=$'\t' read -r kind scope unit detail reason; do
    [[ -n $unit ]] || continue
    [[ -n $reason ]] || reason="no reason recorded"
    if [[ $kind == alert ]]; then
      id="alert:$unit"
      printf '%s\t%-10s %s - %s\n' "$id" "alert" "$detail" "$reason"
    else
      id="$scope:$unit"
      printf '%s\t%-10s %s (%s) %s - %s\n' "$id" "$kind" "$unit" "$scope" "$detail" "$reason"
    fi
  done < <(jq -r '.items[]? | [.kind, .scope, .unit, .detail, (.reason // "")] | @tsv' <<<"$json" 2>/dev/null)
  # the badge shows an issue but the cached run has no item list (cache written by an older health.sh): say so
  if [[ -n $json ]] && [[ $(jq -r '(.text // "") != "" and ((.items // []) | length == 0)' <<<"$json" 2>/dev/null) == true ]]; then
    printf 'none:\tdetails    the badge counts issues but the cached run has no item list yet - press Esc and click again in a minute\n'
  fi
}

preview() {
  local id=$1 scope unit key jl
  case $id in
    alert:*)
      key=${id#alert:}
      case $key in
        memory) echo "Memory pressure (sysalert)"; echo; free -h; echo; ps -eo pid,pmem,rss,comm --sort=-rss | head -9 ;;
        temp) echo "CPU temperature (sysalert)"; echo; { sensors 2>/dev/null || grep -H . /sys/class/thermal/thermal_zone*/temp 2>/dev/null; } | head -24
              echo; ps -eo pid,pcpu,comm --sort=-pcpu | head -8 ;;
        load) echo "Sustained load (sysalert)"; echo; uptime; echo; ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -10 ;;
        disk*) echo "Low disk space (sysalert)"; echo; df -h -x tmpfs -x devtmpfs -x efivarfs 2>/dev/null ;;
        *) echo "sysalert condition: $key" ;;
      esac ;;
    none:*) echo "No item list in the cached health run yet. The badge refreshes every minute." ;;
    *:*)
      scope=${id%%:*} unit=${id#*:}
      echo "== systemctl $(flag_of "$scope") status =="
      SYSTEMD_URLIFY=0 SYSTEMD_COLORS=1 systemctl "$(flag_of "$scope")" status --no-pager -l -n0 -- "$unit" 2>&1
      if [[ $(systemctl "$(flag_of "$scope")" show -p LoadState --value -- "$unit" 2>/dev/null) == not-found ]]; then
        echo; echo "(unit file is gone: $unit is not loaded any more; it may have been removed after this run)"
      fi
      echo
      echo "== journal, last 30 lines =="
      jl=$(journalctl "$(flag_of "$scope")" -u "$unit" -n 30 --no-pager 2>&1)
      if [[ -z $jl || $jl == '-- No entries --' ]]; then
        echo "(no journal entries: the unit never logged, they were rotated, or this user may not read the $scope journal)"
      else
        printf '%s\n' "$jl"
      fi ;;
    *) echo "unknown row: $id" ;;
  esac
}

actions() {
  local id=$1 scope unit
  case $id in
    alert:*)
      printf 'btop\tbtop (processes)\n'
      printf 'doctor\tdoctor.sh --fails\n' ;;
    *:*)
      scope=${id%%:*} unit=${id#*:}
      printf 'restart\tRestart %s\n' "$unit"
      printf 'stop\tStop %s\n' "$unit"
      printf 'stop-disable\tStop and disable autostart\n'
      printf 'reset\tReset the failed state (reset-failed)\n'
      printf 'journal\tFull journal in less (end)\n'
      printf 'follow\tFollow the journal live\n'
      printf 'status\tFull status in less\n' ;;
  esac
}

# run a shell snippet in a float.tui terminal and wait for a key afterwards
in_terminal() {
  if ((DRY)); then echo "terminal: $1"; return 0; fi
  setsid -f ghostty --class=float.tui -e bash -c "$1"'; read -rn1 -p "press a key" _' >/dev/null 2>&1
}
in_terminal_nowait() {
  if ((DRY)); then echo "terminal: $1"; return 0; fi
  setsid -f ghostty --class=float.tui -e bash -c "$1" >/dev/null 2>&1
}

note() { ((DRY)) || notify-send -a health -u low -t 3500 "$@" 2>/dev/null || true; }

# run ID ACTION; sets RESULT=stay when the list should be rebuilt, RESULT=leave when a terminal took over
run_action() {
  local id=$1 act=$2 scope unit f q cmd err
  RESULT=stay
  case $id in
    alert:*)
      case $act in
        btop) in_terminal_nowait btop ;;
        doctor) in_terminal "$HOME/dotfiles/doctor.sh --fails" ;;
      esac
      RESULT=leave; return ;;
  esac
  scope=${id%%:*} unit=${id#*:} f=$(flag_of "$scope")
  printf -v q '%q' "$unit"
  case $act in
    journal) in_terminal_nowait "journalctl $f -u $q -e"; RESULT=leave; return ;;
    follow) in_terminal_nowait "journalctl $f -u $q -f -n 100"; RESULT=leave; return ;;
    status) in_terminal_nowait "systemctl $f status -l -- $q"; RESULT=leave; return ;;
  esac
  case $act in
    restart) cmd="systemctl $f restart -- $q" ;;
    stop) cmd="systemctl $f stop -- $q" ;;
    stop-disable) cmd="systemctl $f disable --now -- $q" ;;
    reset) cmd="systemctl $f reset-failed -- $q" ;;
    *) echo "health-details: unknown action $act" >&2; RESULT=stay; return ;;
  esac
  if [[ $scope == user ]]; then
    if ((DRY)); then echo "$cmd"; RESULT=stay; return; fi
    err=$(mktemp)
    if bash -c "$cmd" 2>"$err"; then
      note "health" "$act: $unit"
    else
      note -u normal "health: $act failed" "$unit: $(head -c 200 "$err")"
    fi
    rm -f "$err"
    sleep 1
    RESULT=stay
  else
    in_terminal "sudo $cmd"
    RESULT=leave
  fi
}

interactive() {
  local list id act pick
  have fzf-menu || { echo "health-details: fzf-menu not found" >&2; exit 1; }
  while :; do
    list=$(rows)
    if [[ -z $list ]]; then
      note "health" "No health issues"
      printf 'No health issues right now\n' | fzf-menu -p health --header 'Esc: normal mode   q: close' >/dev/null || true
      return 0
    fi
    pick=$(printf '%s\n' "$list" | fzf-menu -p health --delimiter=$'\t' --with-nth=2.. --accept-nth=1 \
      --header 'Enter: actions   Esc: normal mode   Alt+j/k: scroll preview' \
      --preview "$SELF --preview {1}" --preview-window 'down,65%,wrap,border-top') || return 0
    [[ -n $pick ]] || return 0
    id=$pick
    [[ $id == none:* ]] && return 0
    act=$(actions "$id" | fzf-menu -p "${id#*:}" --delimiter=$'\t' --with-nth=2.. --accept-nth=1 \
      --header 'Enter: run   Esc: normal mode') || continue
    [[ -n $act ]] || continue
    run_action "$id" "$act"
    [[ $RESULT == leave ]] && return 0
    FRESH=1   # the next list is a fresh run (the badge follows within its interval)
    export FRESH
  done
}

case ${1:-} in
  --list) rows ;;
  --preview) preview "${2:?id}" ;;
  --actions) actions "${2:?id}" ;;
  --do) run_action "${2:?id}" "${3:?action}" ;;
  '' ) interactive ;;
  *) echo "usage: health-details.sh [--list|--preview ID|--actions ID|--do ID ACTION [--dry-run]]" >&2; exit 2 ;;
esac
