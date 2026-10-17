#!/usr/bin/env bash
# crash-watch: a toast when one of YOUR programs dumps core (systemd-coredump), logic after omarchy-crash-watch / -mute (MIT).
#   crash-watch.sh                  follow the journal (the user service crash-watch.service runs this)
#   crash-watch.sh list             recent coredumps in a terminal pager (coredumpctl list --since today)
#   crash-watch.sh mutes            show / edit the mute list ($EDITOR)
#   crash-watch.sh mute NAME        add NAME to the mute list; unmute NAME removes it
#   crash-watch.sh --event JSON     handle one journal record (tests)
# The toast (normal urgency, 20 s): click = Details (coredumpctl info in a floating terminal); the action menu
# (SUPER+ALT+X) has "Ask Claude" (a ghostty with `claude` and a prompt naming the dump; a normal session, nothing auto-approved)
# and "Mute NAME". At most one toast per program per 60 s. waybar is skipped: its watchdog (waybar-run.sh) already reports it.
# Mute list: ~/.local/state/crash-watch/muted (one program name per line).
set -u

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/crash-watch"
MUTED="$STATE/muted"
RATE="${XDG_RUNTIME_DIR:-/tmp}/crash-watch-last"
MSGID=fc2e22bc6ee647b6b90729ab34a250b1
RATE_SECONDS=60
SKIP_ALWAYS=(waybar)
mkdir -p "$STATE" "$RATE"

is_muted() { # NAME
  local n=$1 s
  for s in "${SKIP_ALWAYS[@]}"; do [[ $n == "$s" ]] && return 0; done
  [[ -r $MUTED ]] && grep -qxF -- "$n" "$MUTED"
}

rate_ok() { # NAME: true when no toast for NAME in the last RATE_SECONDS; records now
  local f="$RATE/${1//\//_}" now last=0
  now=$(date +%s)
  [[ -r $f ]] && last=$(cat "$f" 2>/dev/null || echo 0)
  ((now - last >= RATE_SECONDS)) || return 1
  echo "$now" >"$f"
}

toast_worker() { # COMM PID EXE SIGNAL
  local comm=$1 pid=$2 exe=$3 sig=$4 act prompt
  act=$(notify-send -a crash -u normal -t 20000 -h "string:x-dunst-stack-tag:crash-$comm" \
    -A "default=Details" -A "claude=Ask Claude" -A "mute=Mute $comm" \
    "$comm crashed ($sig)" "pid $pid · $exe"$'\n'"click: details · SUPER+ALT+X: ask Claude, mute" 2>/dev/null)
  case $act in
    default) ghostty --class=float.tui --title="crash: $comm" -e bash -c 'coredumpctl info "$1" 2>&1 | less -R' _ "$pid" ;;
    claude)
      prompt="A program of mine crashed: $comm ($exe), signal $sig, pid $pid. Investigate: coredumpctl info $pid, the journal around the time of the crash, and the package version. Explain the likely cause and what to try. Do not change anything without asking me."
      ghostty --title="crash: $comm" -e claude "$prompt" ;;
    mute) cmd_mute "$comm" ;;
  esac
}

handle_event() { # one JSON record
  local rec=$1 comm pid exe sig
  comm=$(jq -r '.COREDUMP_COMM // empty' <<<"$rec")
  [[ -n $comm ]] || return 0
  is_muted "$comm" && return 0
  rate_ok "$comm" || return 0
  pid=$(jq -r '.COREDUMP_PID // "?"' <<<"$rec")
  exe=$(jq -r '.COREDUMP_EXE // "?"' <<<"$rec")
  sig=$(jq -r '.COREDUMP_SIGNAL_NAME // "signal"' <<<"$rec")
  if [[ ${CRASH_WATCH_SYNC:-0} == 1 ]]; then toast_worker "$comm" "$pid" "$exe" "$sig"; else
    toast_worker "$comm" "$pid" "$exe" "$sig" >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

cmd_mute() {
  [[ -n ${1:-} ]] || { echo "usage: crash-watch.sh mute NAME" >&2; return 2; }
  grep -qxF -- "$1" "$MUTED" 2>/dev/null || echo "$1" >>"$MUTED"
  notify-send -a crash -t 3000 "Crash toasts muted" "$1 (crash-watch.sh unmute $1 or the hub row)" 2>/dev/null || true
}

cmd_unmute() {
  [[ -n ${1:-} ]] || { echo "usage: crash-watch.sh unmute NAME" >&2; return 2; }
  [[ -r $MUTED ]] || return 0
  grep -vxF -- "$1" "$MUTED" >"$MUTED.tmp"; mv -f "$MUTED.tmp" "$MUTED"
}

case ${1:-follow} in
  follow)
    # -n 0: only new records; COREDUMP_UID: only this user's programs
    journalctl -f -n 0 -o json "MESSAGE_ID=$MSGID" "COREDUMP_UID=$UID" 2>/dev/null | while IFS= read -r line; do
      handle_event "$line"
    done ;;
  --event) shift; handle_event "$1" ;;
  list) coredumpctl list --since today --no-pager 2>&1 | tail -n 40 ;;
  mutes) touch "$MUTED"; exec "${EDITOR:-nvim}" "$MUTED" ;;
  mute) shift; cmd_mute "${1:-}" ;;
  unmute) shift; cmd_unmute "${1:-}" ;;
  *) echo "usage: crash-watch.sh [follow|list|mutes|mute NAME|unmute NAME]" >&2; exit 2 ;;
esac
