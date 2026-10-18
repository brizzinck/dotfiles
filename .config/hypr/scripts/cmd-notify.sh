#!/usr/bin/env bash
# cmd-notify: a toast when a long shell command finishes while its terminal is not in front (DEV-a).
#
#   cmd-notify.sh notify --exit N --ms N --pid PID [--hidden]
#                                 the worker the zsh hook starts (~/.config/zsh/cmd-hooks.zsh): command text in $DF_CMD,
#                                 directory in $DF_CMD_DIR, tmux from $TMUX / $TMUX_PANE; PID = the shell
#   cmd-notify.sh locate --pid PID    print the window of that shell (see below); nothing is notified
#   cmd-notify.sh focus ADDRESS [SOCKET SESSION WINDOW PANE CLIENT_TTY]
#                                 focus the window (switches workspace) and, with a tmux socket, switch the client to the
#                                 session, select the window and the pane; nothing happens when the window is gone
#   cmd-notify.sh on | off | toggle | status      switch (hub row "Long-command notifications"); status exit 0 = ON
#   --dry-run  (or CMD_NOTIFY_DRY=1)  print the toast / the focus steps instead of showing / doing them
#
# "In front" = the Hyprland active window is the terminal window of the shell AND (no tmux, or the pane is the active pane
# of the active window of a client of its session). The window is found by walking the parent chain of the shell (or, in
# tmux, of the clients attached to the pane's session) to the first process that owns a window. When one process owns
# several windows (ghostty Ctrl+Shift+N) only the one titled `<session>:...` counts as the shell's window; without a title match
# the window is not decidable, so it counts as "not found" (never "the focused sibling"). A tmux inside a tmux pane is followed to
# the outer server (the client's chain ends in the outer `tmux: server`; the pane's shell has the outer $TMUX/$TMUX_PANE in its
# environment): in front = inner AND outer pane active, and the focus steps use the outer tmux. A shell whose window cannot be
# found still gets the toast (no Focus action). Hyprland: $HYPRLAND_INSTANCE_SIGNATURE when it answers, else the newest instance in
# $XDG_RUNTIME_DIR/hypr that does (tmux outlives Hyprland and its environment can be stale); none (td, yc, a TTY) = silent.
# `locate` prints: address TAB tmux-socket TAB session TAB window_id TAB pane_id TAB client_tty TAB focused(0|1)
# The toast: app `terminal`, summary "Finished in 1m 42s" / "Failed (exit 2) after 1m 42s", body = the command (80 characters,
# one line, markup escaped; "(command hidden)" for --hidden and for a command gitleaks flags) and the directory; a click
# (default action, also in the SUPER+ALT+X menu) runs `focus`. The command never goes through argv.
# Switch: the file ~/.local/state/cmd-notify/off (read on every run, so the toggle is live without a shell restart).
# Test hooks: CMD_NOTIFY_HYPRCTL, _HYPRD, _NOTIFY (notify-send), _TMUX, _STATE (state dir), _DRY=1.
set -u

HYPRCTL=${CMD_NOTIFY_HYPRCTL:-hyprctl}
HYPRD=${CMD_NOTIFY_HYPRD:-hyprd}
NOTIFY=${CMD_NOTIFY_NOTIFY:-notify-send}
TMUXBIN=${CMD_NOTIFY_TMUX:-tmux}
STATE=${CMD_NOTIFY_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/cmd-notify}
DRY=${CMD_NOTIFY_DRY:-0}
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

is_off() { [[ -e $STATE/off ]]; }

# pick_instance: make hyprctl reach a running Hyprland; fail when there is none
pick_instance() {
  local d sig
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && "$HYPRCTL" -j version >/dev/null 2>&1; then return 0; fi
  # shellcheck disable=SC2045 # instance directories are plain signatures, newest first
  for d in $(ls -1t "${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr" 2>/dev/null); do
    sig=$d
    if HYPRLAND_INSTANCE_SIGNATURE=$sig "$HYPRCTL" -j version >/dev/null 2>&1; then
      export HYPRLAND_INSTANCE_SIGNATURE=$sig
      return 0
    fi
  done
  return 1
}

# owner_of PID WINDOWS: print the first pid on the parent chain of PID that owns a window (WINDOWS = "pid TAB address TAB title" lines)
owner_of() {
  local p=$1 i ppid
  for ((i = 0; i < 32 && p > 1; i++)); do
    if grep -q "^$p"$'\t' <<<"$2"; then printf '%s\n' "$p"; return 0; fi
    # /proc/PID/stat: "pid (comm) state ppid ..."; comm may hold spaces, so cut after the last ")"
    ppid=$(sed -E 's/^.*\) [^ ]+ ([0-9]+).*$/\1/' "/proc/$p/stat" 2>/dev/null) || return 1
    [[ $ppid =~ ^[0-9]+$ ]] || return 1
    p=$ppid
  done
  return 1
}

# pick_window OWNER TITLE_PREFIX: the window of the terminal process OWNER that shows the shell; prints its address.
# One window = it. Several windows (ghostty Ctrl+Shift+N makes more windows in ONE process): the title `<session>:...` of the
# tmux session decides (the active one among several matches); no match = not decidable, return 1 (never "the focused sibling").
pick_window() {
  local owner=$1 prefix=$2 addr title m
  local -a all=() match=()
  while IFS=$'\t' read -r _ addr title; do
    [[ -n $addr ]] || continue
    all+=("$addr")
    [[ -n $prefix && $title == "$prefix":* ]] && match+=("$addr")
  done < <(grep "^$owner"$'\t' <<<"$windows")
  if ((${#match[@]})); then
    for m in "${match[@]}"; do [[ $m == "$active" ]] && { printf '%s\n' "$m"; return 0; }; done
    printf '%s\n' "${match[0]}"; return 0
  fi
  ((${#all[@]} == 1)) || return 1
  printf '%s\n' "${all[0]}"
}

# outer_of PID SOCKET: a tmux client that runs inside a pane of ANOTHER tmux server (nested tmux): its parent chain ends in the
# outer `tmux: server` (ppid 1), but the pane's shell has the outer $TMUX / $TMUX_PANE in its environment. Prints "socket TAB pane".
outer_of() {
  local p=$1 sock=$2 i ppid t tp
  for ((i = 0; i < 32 && p > 1; i++)); do
    if [[ -r /proc/$p/environ ]]; then
      t=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^TMUX=//p' | head -n1)
      tp=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -n1)
      if [[ -n $t && -n $tp && ${t%%,*} != "$sock" ]]; then printf '%s\t%s\n' "${t%%,*}" "$tp"; return 0; fi
    fi
    ppid=$(sed -E 's/^.*\) [^ ]+ ([0-9]+).*$/\1/' "/proc/$p/stat" 2>/dev/null) || return 1
    [[ $ppid =~ ^[0-9]+$ ]] || return 1
    p=$ppid
  done
  return 1
}

# collect SOCK PANE DEPTH UP SHELLPID: append the terminal window(s) that show the shell to the C_* arrays. SOCK/PANE = the tmux
# pane of the shell (empty = no tmux: the window of SHELLPID); UP = 1 while every tmux level above this one has the pane in front
# (a nested tmux counts only when the inner pane AND the outer pane are the active ones). Returns 2 when tmux cannot be asked.
collect() {
  local sock=$1 pane=$2 depth=$3 up=$4 shellpid=$5
  local tmuxline session='' win='' wa pa act=$up cpid ctty owner addr prefix='' outer osock opane
  local -a pids=() ttys=()
  if [[ -n $sock ]]; then
    tmuxline=$("$TMUXBIN" -S "$sock" display-message -p -t "$pane" '#{session_name}'$'\t''#{window_id}'$'\t''#{window_active}'$'\t''#{pane_active}' 2>/dev/null) || tmuxline=''
    [[ -n $tmuxline ]] || return 2
    IFS=$'\t' read -r session win wa pa <<<"$tmuxline"
    [[ $wa == 1 && $pa == 1 ]] || act=0
    prefix=$session
    while IFS=$'\t' read -r cpid ctty _; do
      [[ -n $cpid ]] || continue
      pids+=("$cpid"); ttys+=("$ctty")
    done < <("$TMUXBIN" -S "$sock" list-clients -t "$session" -F '#{client_pid}'$'\t''#{client_tty}'$'\t''#{client_session}' 2>/dev/null)
  else
    pids=("$shellpid"); ttys=('')
  fi
  local n
  for n in "${!pids[@]}"; do
    cpid=${pids[n]}
    if owner=$(owner_of "$cpid" "$windows") && addr=$(pick_window "$owner" "$prefix"); then
      C_ADDR+=("$addr"); C_SOCK+=("$sock"); C_SESSION+=("$session"); C_WINDOW+=("$win"); C_PANE+=("${sock:+$pane}"); C_TTY+=("${ttys[n]}"); C_ACT+=("$act")
    elif [[ -n $sock ]] && ((depth < 3)) && outer=$(outer_of "$cpid" "$sock"); then
      IFS=$'\t' read -r osock opane <<<"$outer"
      collect "$osock" "$opane" $((depth + 1)) "$act" "$shellpid"
    fi
  done
  return 0
}

# locate PID: sets L_ADDR L_SOCK L_SESSION L_WINDOW L_PANE L_TTY L_FOCUSED
locate() {
  local shellpid=$1 clients active windows="" rc i
  local -a C_ADDR=() C_SOCK=() C_SESSION=() C_WINDOW=() C_PANE=() C_TTY=() C_ACT=()
  L_ADDR='' L_SOCK='' L_SESSION='' L_WINDOW='' L_PANE='' L_TTY='' L_FOCUSED=0
  clients=$("$HYPRCTL" clients -j 2>/dev/null) || return 1
  windows=$(jq -r '.[] | [.pid, .address, .title] | @tsv' <<<"$clients" 2>/dev/null) || return 1
  active=$("$HYPRCTL" activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null)
  if [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]]; then
    collect "${TMUX%%,*}" "$TMUX_PANE" 0 1 "$shellpid"; rc=$?
    # the tmux server cannot be asked: treat the shell as a plain one
    ((rc == 2)) && collect '' '' 0 1 "$shellpid"
  else
    collect '' '' 0 1 "$shellpid"
  fi
  ((${#C_ADDR[@]})) || return 1
  # the window in front among the candidates (and the pane in front in it), else the first
  local best=0
  for i in "${!C_ADDR[@]}"; do
    if [[ ${C_ADDR[i]} == "$active" ]]; then
      best=$i
      [[ ${C_ACT[i]} == 1 ]] && { L_FOCUSED=1; break; }
    fi
  done
  L_ADDR=${C_ADDR[best]} L_SOCK=${C_SOCK[best]} L_SESSION=${C_SESSION[best]} L_WINDOW=${C_WINDOW[best]} L_PANE=${C_PANE[best]} L_TTY=${C_TTY[best]}
  return 0
}

print_located() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$L_ADDR" "$L_SOCK" "$L_SESSION" "$L_WINDOW" "$L_PANE" "$L_TTY" "$L_FOCUSED"; }

focus() { # ADDRESS [SOCKET SESSION WINDOW PANE CLIENT_TTY]
  local addr=$1 sock=${2:-} session=${3:-} win=${4:-} pane=${5:-} tty=${6:-} cur
  [[ -n $addr ]] || return 0
  "$HYPRCTL" clients -j 2>/dev/null | jq -e --arg a "$addr" 'any(.[]; .address == $a)' >/dev/null 2>&1 || return 0
  if [[ $DRY == 1 ]]; then
    printf 'focus: hyprd focuswindow address:%s\n' "$addr"
  else
    "$HYPRD" focuswindow "address:$addr" >/dev/null 2>&1 || true
  fi
  [[ -n $sock ]] || return 0
  if [[ -n $tty && -n $session ]]; then
    cur=$("$TMUXBIN" -S "$sock" display-message -p -c "$tty" '#{client_session}' 2>/dev/null) || cur=''
    if [[ -n $cur && $cur != "$session" ]]; then
      if [[ $DRY == 1 ]]; then printf 'focus: tmux switch-client -c %s -t %s\n' "$tty" "$session"
      else "$TMUXBIN" -S "$sock" switch-client -c "$tty" -t "$session" 2>/dev/null || true; fi
    fi
  fi
  if [[ -n $win ]]; then
    if [[ $DRY == 1 ]]; then printf 'focus: tmux select-window -t %s\n' "$win"
    else "$TMUXBIN" -S "$sock" select-window -t "$win" 2>/dev/null || true; fi
  fi
  if [[ -n $pane ]]; then
    if [[ $DRY == 1 ]]; then printf 'focus: tmux select-pane -t %s\n' "$pane"
    else "$TMUXBIN" -S "$sock" select-pane -t "$pane" 2>/dev/null || true; fi
  fi
}

human_duration() { # MS
  local s=$(($1 / 1000)) h m
  if ((s < 60)); then printf '%ds' "$s"
  elif ((s < 3600)); then printf '%dm %02ds' $((s / 60)) $((s % 60))
  else h=$((s / 3600)) m=$(((s % 3600) / 60)); printf '%dh %02dm' "$h" "$m"; fi
}

# toast_text TEXT: one line, at most 80 characters, control characters as spaces, & < > escaped for dunst's markup
toast_text() {
  local t=$1
  t=$(printf '%s' "$t" | tr '[:cntrl:]' ' ' | sed -E 's/ +/ /g; s/^ //; s/ $//')
  ((${#t} > 80)) && t="${t:0:79}…"
  # bash 5.2 patsub_replacement: a bare & in the replacement means the match, so it is escaped
  t=${t//&/\&amp;}; t=${t//</\&lt;}; t=${t//>/\&gt;}
  printf '%s' "$t"
}

cmd_notify() {
  local ec=0 ms=0 pid='' hidden=0 cmd dir summary body dur act short
  while (($#)); do
    case $1 in
      --exit) ec=${2:-0}; shift 2 ;;
      --ms) ms=${2:-0}; shift 2 ;;
      --pid) pid=${2:-}; shift 2 ;;
      --hidden) hidden=1; shift ;;
      *) echo "cmd-notify: unknown argument $1" >&2; return 2 ;;
    esac
  done
  [[ $pid =~ ^[0-9]+$ ]] || { echo "cmd-notify: --pid PID is required" >&2; return 2; }
  is_off && return 0
  command -v jq >/dev/null 2>&1 || return 0
  pick_instance || return 0
  if locate "$pid"; then
    [[ $L_FOCUSED == 1 ]] && return 0
  else
    L_ADDR='' L_SOCK='' L_SESSION='' L_WINDOW='' L_PANE='' L_TTY=''
  fi
  cmd=${DF_CMD:-} dir=${DF_CMD_DIR:-$PWD}
  if ((!hidden)) && command -v gitleaks >/dev/null 2>&1; then
    printf '%s' "$cmd" | gitleaks stdin --no-banner --redact --exit-code 3 -l error >/dev/null 2>&1
    [[ $? == 3 ]] && hidden=1
  fi
  if ((hidden)); then short='(command hidden)'; else short=$(toast_text "$cmd"); fi
  dur=$(human_duration "$ms")
  if ((ec == 0)); then summary="Finished in $dur"; else summary="Failed (exit $ec) after $dur"; fi
  dir=${dir/#$HOME/\~}
  body="$short"$'\n'"in $(toast_text "$dir") · click to focus"
  if [[ $DRY == 1 ]]; then
    printf 'notify-send: summary=%s\nbody=%s\n' "$summary" "$body"
    printf 'located: '; print_located
    [[ -n $L_ADDR ]] && focus "$L_ADDR" "$L_SOCK" "$L_SESSION" "$L_WINDOW" "$L_PANE" "$L_TTY"
    return 0
  fi
  if [[ -n $L_ADDR ]]; then
    act=$("$NOTIFY" -a terminal -i utilities-terminal -t 15000 -u normal -A default=Focus "$summary" "$body" 2>/dev/null)
    [[ $act == default ]] && focus "$L_ADDR" "$L_SOCK" "$L_SESSION" "$L_WINDOW" "$L_PANE" "$L_TTY"
  else
    "$NOTIFY" -a terminal -i utilities-terminal -t 15000 -u normal "$summary" "$body" >/dev/null 2>&1
  fi
  return 0
}

case ${1:-} in
  notify) shift; cmd_notify "$@" ;;
  locate)
    shift
    [[ ${1:-} == --pid && ${2:-} =~ ^[0-9]+$ ]] || { echo "usage: cmd-notify.sh locate --pid PID" >&2; exit 2; }
    pick_instance || exit 0
    locate "$2" || { echo "cmd-notify: no window found for pid $2" >&2; exit 1; }
    print_located
    ;;
  focus) shift; pick_instance || exit 0; focus "$@" ;;
  on) rm -f "$STATE/off" ;;
  off) mkdir -p "$STATE" && : >"$STATE/off" ;;
  toggle) if is_off; then rm -f "$STATE/off"; else mkdir -p "$STATE" && : >"$STATE/off"; fi ;;
  status) if is_off; then echo off; exit 1; else echo on; fi ;;
  -h | --help | '') sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) echo "cmd-notify: unknown command $1 (see --help)" >&2; exit 2 ;;
esac
