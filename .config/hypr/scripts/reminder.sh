#!/usr/bin/env bash
# reminder: "in 25 minutes: tea", set and listed with transient systemd user timers (logic of omarchy-reminder, MIT).
#   reminder.sh set [SPEC [MESSAGE...]]   SPEC = 25 | 25m | 90s | 2h | 1h30 | 1h30m | 14:30 (next time of day);
#                                         without arguments a prompt opens (fzf-menu): type `25 tea` or `14:30 standup`
#   reminder.sh list                      fzf-menu over the pending reminders; d / Alt+d cancels the selected one
#   reminder.sh clear [all]               cancel every reminder (asks first)
#   reminder.sh waybar                    JSON for custom/reminder (hidden while none is pending)
#   reminder.sh --parse TEXT              the live preview line of the prompt ("in 25 min: tea")
#   --dry-run                             print the systemd-run command, create nothing
# Timers are transient: they do not survive a reboot or logout (the prompt says so). The notification is critical (stays until
# dismissed), app name `reminder`. SUPER+ALT+T sets, SUPER+CTRL+ALT+T lists.
set -u

SELF=$(readlink -f "${BASH_SOURCE[0]}")
G_TIMER='󰔛'
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"
TRANSIENT="${XDG_RUNTIME_DIR:-/tmp}/systemd/transient"

poke() { pkill -o -u "$UID" -RTMIN+17 -x waybar 2>/dev/null || true; }
say() { if ((DRY)); then echo "note: $*"; else notify-send -a reminder -t 3500 -h string:x-dunst-stack-tag:reminder-set "$@"; fi; }

# SPEC -> seconds from now (stdout); returns 1 when it is not a time spec
spec_seconds() {
  local s=$1 h m now t
  if [[ $s =~ ^([0-9]{1,2}):([0-9]{2})$ ]]; then
    h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
    ((h < 24 && m < 60)) || return 1
    now=$(date +%s)
    t=$(date -d "$(printf '%02d:%02d' "$h" "$m")" +%s)
    ((t > now)) || t=$(date -d "tomorrow $(printf '%02d:%02d' "$h" "$m")" +%s)
    echo $((t - now)); return 0
  fi
  if [[ $s =~ ^([0-9]+)$ ]]; then echo $((10#${BASH_REMATCH[1]} * 60)); return 0; fi
  if [[ $s =~ ^(([0-9]+)h)?(([0-9]+)m?)?$ && -n $s && ( -n ${BASH_REMATCH[2]} || -n ${BASH_REMATCH[4]} ) ]]; then
    h=${BASH_REMATCH[2]:-0} m=${BASH_REMATCH[4]:-0}
    echo $((10#$h * 3600 + 10#$m * 60)); return 0
  fi
  if [[ $s =~ ^([0-9]+)s$ ]]; then echo "$((10#${BASH_REMATCH[1]}))"; return 0; fi
  return 1
}

human() { # seconds -> 1h05m / 25m / 40s
  local t=$1
  if ((t >= 3600)); then printf '%dh%02dm' $((t / 3600)) $((t % 3600 / 60))
  elif ((t >= 120)); then printf '%dm' $(((t + 30) / 60))
  else printf '%ds' "$t"; fi
}

preview() { # TEXT
  local spec msg secs
  read -r spec msg <<<"$1"
  [[ -n $spec ]] || { printf '(25 tea | 14:30 standup | 1h30 call)'; return; }
  if secs=$(spec_seconds "$spec"); then
    printf 'in %s: %s' "$(human "$secs")" "${msg:-Reminder}"
  else
    printf '(time first: 25, 90s, 2h, 1h30, 14:30)'
  fi
}

cmd_set() {
  local spec msg secs unit text
  if (($# >= 1)); then
    spec=$1; shift; msg="$*"
  else
    command -v fzf-menu >/dev/null 2>&1 || { notify-send -a reminder "Reminder" "fzf-menu is missing"; exit 1; }
    export FZF_MENU_NORMAL_BINDS='y:accept'
    text=$(printf '' | fzf-menu -p reminder --disabled --print-query --header "$(preview "")" \
      --bind "change:transform-header:$SELF --parse {q}" | sed -n 1p) || true
    [[ -n $text ]] || exit 0
    read -r spec msg <<<"$text"
  fi
  secs=$(spec_seconds "$spec") || { say "Reminder not set" "not a time: $spec (try 25, 90s, 2h, 1h30, 14:30)"; exit 1; }
  ((secs >= 1)) || { say "Reminder not set" "the time is in the past"; exit 1; }
  msg=${msg:-Reminder}
  unit="reminder-$(date +%s)-$RANDOM"
  # the transient service shows the message and pokes waybar; the timer fires once after $secs seconds
  local -a cmd=(systemd-run --user --quiet --unit="$unit" --description="reminder: $msg" --on-active="${secs}s"
    --timer-property=AccuracySec=1s bash -c 'notify-send -u critical -a reminder "Reminder" "$1"; pkill -o -u "$2" -RTMIN+17 -x waybar' _ "$msg" "$UID")
  if ((DRY)); then printf '%q ' "${cmd[@]}"; echo; return 0; fi
  "${cmd[@]}" || { say "Reminder failed" "systemd-run --user did not accept the timer"; exit 1; }
  poke
  say "Reminder set" "in $(human "$secs"): $msg"$'\n'"(timers do not survive a reboot)"
}

# one line per pending reminder: unit <TAB> seconds left <TAB> message
pending() {
  local now unit nxt msg
  now=$(date +%s)
  systemctl --user list-timers 'reminder-*' --all --output=json 2>/dev/null | jq -r '.[] | [.unit, (.next // 0)] | @tsv' 2>/dev/null |
    while IFS=$'\t' read -r unit nxt; do
      [[ $unit == reminder-*.timer && $nxt =~ ^[0-9]+$ && $nxt -gt 0 ]] || continue
      msg=$(sed -n 's/^Description=reminder: //p' "$TRANSIENT/${unit%.timer}.service" 2>/dev/null | head -1)
      printf '%s\t%s\t%s\n' "${unit%.timer}" $((nxt / 1000000 - now)) "${msg:-Reminder}"
    done | sort -t$'\t' -k2,2n
}

cmd_list() {
  local rows labels pick unit
  rows=$(pending)
  if [[ -z $rows ]]; then say "Reminders" "none pending (SUPER+ALT+T sets one)"; return 0; fi
  if ((DRY)); then printf '%s\n' "$rows"; return 0; fi
  labels=$(while IFS=$'\t' read -r unit left msg; do printf '%s\t%-8s %s\n' "$unit" "in $(human "$((left > 0 ? left : 0))")" "$msg"; done <<<"$rows")
  export FZF_MENU_NORMAL_BINDS='d:become(printf "alt-d\n%s\n" {1})'
  pick=$(printf '%s\n' "$labels" | fzf-menu -p reminders --delimiter=$'\t' --with-nth=2 --accept-nth=1 --expect=alt-d \
    --header 'd / Alt+d cancels the selected reminder') || exit 0
  # the first output line is the --expect key (empty for Enter), the second the unit
  [[ $(sed -n 1p <<<"$pick") == alt-d ]] || return 0
  unit=$(sed -n 2p <<<"$pick")
  [[ -n $unit ]] || return 0
  systemctl --user stop "$unit.timer" "$unit.service" 2>/dev/null
  poke
  say "Reminder cancelled" ""
}

cmd_clear() {
  local rows
  rows=$(pending)
  [[ -n $rows ]] || { say "Reminders" "none pending"; return 0; }
  if ((!DRY)) && [[ ${1:-} != --yes ]]; then
    [[ $(printf 'no\nyes\n' | fzf-menu -p "cancel all reminders?") == yes ]] || return 0
  fi
  while IFS=$'\t' read -r unit _; do
    if ((DRY)); then echo "systemctl --user stop $unit.timer $unit.service"; else systemctl --user stop "$unit.timer" "$unit.service" 2>/dev/null; fi
  done <<<"$rows"
  ((DRY)) || { poke; say "Reminders cancelled" ""; }
}

cmd_waybar() {
  local rows n left msg tip
  rows=$(pending)
  if [[ -z $rows ]]; then echo '{"text":""}'; return 0; fi
  n=$(wc -l <<<"$rows")
  IFS=$'\t' read -r _ left msg <<<"$(head -n1 <<<"$rows")"
  tip=$(while IFS=$'\t' read -r _ l m; do printf 'in %s: %s\n' "$(human "$((l > 0 ? l : 0))")" "$m"; done <<<"$rows")
  jq -cn --arg t "$G_TIMER $(human "$((left > 0 ? left : 0))")$([[ $n -gt 1 ]] && echo " +$((n - 1))")" --arg tip "${tip}"$'\n\n'"L: list · M: new · R: clear all" \
    '{text: $t, class: "normal", tooltip: $tip}'
}

case ${1:-set} in
  set) shift 2>/dev/null; cmd_set "$@" ;;
  list | show) cmd_list ;;
  clear) shift; cmd_clear "$@" ;;
  waybar) cmd_waybar ;;
  --parse) shift; preview "$*" ;;
  *) cmd_set "$@" ;;
esac
