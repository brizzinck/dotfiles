#!/usr/bin/env bash
# bar: mode and visibility of the waybar bars (W1). Two bars per output live in one waybar process:
#   compact  the base bar (exclusive zone, always there while the bar is shown)
#   full     an overlay of the same height over it (non-exclusive, margin-top -28); SIGUSR1 toggles only this one, so the
#            exclusive zone and the window layout never change and nothing reloads
# State (survives restarts, reloads and logins because the config `include`s files rendered from it):
#   $STATE/mode              compact | full
#   $STATE/hidden            exists = the whole bar is hidden (cleared at login by `init`)
#   $STATE/compact.jsonc     {"start_hidden": <hidden>}                       included by the compact bar
#   $STATE/full.jsonc        {"start_hidden": <hidden or mode is compact>}    included by the full bar
#   $STATE/pinned.jsonc      module definitions of the pinned apps (pinned.sh gen from pinned.tsv)  included by both bars
#   $RT/stale                set after a SIGUSR1 toggle (the running config no longer matches the files), cleared by a reload
#
#   bar.sh mode toggle|compact|full   switch the mode (while hidden: show the bar, keep the mode)   SUPER+B
#   bar.sh hide toggle|on|off         hide or show the whole bar (reload)                           SUPER+CTRL+B
#   bar.sh status [--short]           "compact" | "full" | "compact hidden" | "full hidden" (--short: the mode only)
#   bar.sh render                     rewrite the include files from the state (and from pinned.tsv)
#   bar.sh reload                     render and reload waybar (SIGUSR2: config, stylesheet, includes)
#   bar.sh sync [--if-stale]          reload (with --if-stale only when a toggle left the running config stale; the
#                                     monitor.added hook of hyprland.lua uses it so a new monitor gets the right mode)
#   bar.sh init                       login / install: default mode, clear `hidden`, render
#   bar.sh restart                    stop waybar, render, start it again (log: $RT/waybar.log; WAYBAR_LOG_LEVEL=debug for details)
#   bar.sh menu                       fzf-menu: compact / full / hide / restart / theme
#   --dry-run                         print the writes and signals instead of doing them
# Never send SIGUSR1 to waybar by hand: the mode file would disagree with the screen (`sync` repairs that).
# Test hooks: BAR_STATE_DIR and BAR_RUN_DIR override the two directories.
set -u

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
STATE="${BAR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/waybar}"
RT="${BAR_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/waybar-bar}"
MODE_FILE="$STATE/mode"
HIDDEN_FILE="$STATE/hidden"
STALE_FILE="$RT/stale"
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

note() { notify-send -a waybar -h string:x-dunst-stack-tag:waybar-bar -t 2000 "$@" 2>/dev/null || true; }
say() { echo "$*"; }

mkdir -p "$STATE" "$RT" 2>/dev/null || true
# one mutating bar.sh at a time (a double press is two serial toggles); status, render and menu do not lock
if ((!DRY)) && [[ ${1:-} =~ ^(mode|hide|reload|sync|init|restart)$ ]]; then
  exec 9>"$RT/lock"
  flock -w 2 9 || { echo "bar.sh: busy" >&2; exit 1; }
fi

mode() { local m=compact; [[ -r $MODE_FILE ]] && m=$(<"$MODE_FILE"); [[ $m == full ]] && echo full || echo compact; }
hidden() { [[ -e $HIDDEN_FILE ]]; }

write_file() { # write_file PATH CONTENT (atomic)
  if ((DRY)); then say "would write $1: $2"; return 0; fi
  printf '%s\n' "$2" >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

render() {
  local h=false f=true
  if hidden; then h=true; elif [[ $(mode) == full ]]; then f=false; fi
  write_file "$STATE/compact.jsonc" "{ \"start_hidden\": $h }"
  write_file "$STATE/full.jsonc" "{ \"start_hidden\": $f }"
  write_file "$STATE/pinned.jsonc" "$("$HERE/pinned.sh" gen)"
}

# signal NAME: SIGUSR1 / SIGUSR2 to the waybar of this user; 1 when it is not running.
# -o = the oldest process only: waybar forks a child per script run, and until it execs the child still has the name
# "waybar" and the signal handlers of its parent, so a signal that reaches it makes that child abort.
signal() {
  if ((DRY)); then say "would run: pkill -o -u $(id -u) -$1 -x waybar"; return 0; fi
  pkill -o -u "$(id -u)" "-$1" -x waybar
}

reload() {
  render
  if signal USR2; then ((DRY)) || rm -f "$STALE_FILE"; else :; fi
  return 0
}

set_mode() { # set_mode compact|full: the visible bar changes through SIGUSR1 (no reload)
  local want=$1
  if hidden; then
    # showing a hidden bar: the mode is applied by the reload that shows it
    if ((DRY)); then say "would remove $HIDDEN_FILE"; else rm -f "$HIDDEN_FILE"; fi
    write_file "$MODE_FILE" "$want"
    reload
    return 0
  fi
  [[ $(mode) == "$want" ]] && return 0
  write_file "$MODE_FILE" "$want"
  render
  if signal USR1; then
    ((DRY)) && say "would touch $STALE_FILE" || : >"$STALE_FILE"
  fi
  return 0
}

cmd_mode() {
  local want
  case ${1:-toggle} in
    toggle)
      if hidden; then
        if ((DRY)); then say "would remove $HIDDEN_FILE"; else rm -f "$HIDDEN_FILE"; fi
        reload
        return 0
      fi
      if [[ $(mode) == full ]]; then want=compact; else want=full; fi ;;
    compact | full) want=$1 ;;
    *) echo "usage: bar.sh mode toggle|compact|full" >&2; return 2 ;;
  esac
  set_mode "$want"
}

cmd_hide() {
  case ${1:-toggle} in
    toggle) if hidden; then cmd_hide off; else cmd_hide on; fi; return ;;
    on) if ((DRY)); then say "would write $HIDDEN_FILE"; else : >"$HIDDEN_FILE"; fi ;;
    off) if ((DRY)); then say "would remove $HIDDEN_FILE"; else rm -f "$HIDDEN_FILE"; fi ;;
    *) echo "usage: bar.sh hide toggle|on|off" >&2; return 2 ;;
  esac
  reload
}

cmd_status() {
  local m
  m=$(mode)
  if [[ ${1:-} == --short ]]; then echo "$m"; return 0; fi
  if hidden; then echo "$m hidden"; else echo "$m"; fi
}

cmd_init() {
  [[ -r $MODE_FILE ]] || write_file "$MODE_FILE" compact
  if ((DRY)); then say "would remove $HIDDEN_FILE and $STALE_FILE"; else rm -f "$HIDDEN_FILE" "$STALE_FILE"; fi
  render
}

cmd_sync() {
  if [[ ${1:-} == --if-stale && ! -e $STALE_FILE ]]; then return 0; fi
  reload
}

cmd_restart() {
  local _
  if ((DRY)); then say "would run: pkill -x waybar; render; setsid -f waybar-run.sh"; return 0; fi
  pkill -u "$(id -u)" -x waybar 2>/dev/null
  for _ in $(seq 30); do pgrep -u "$(id -u)" -x waybar >/dev/null || break; sleep 0.1; done
  if pgrep -u "$(id -u)" -x waybar >/dev/null; then # did not exit on SIGTERM
    pkill -KILL -u "$(id -u)" -x waybar 2>/dev/null
    sleep 0.5
  fi
  rm -f "$STALE_FILE"
  render
  : >"$RT/waybar.log"
  setsid -f "$HERE/waybar-run.sh" ${WAYBAR_LOG_LEVEL:+--log-level "$WAYBAR_LOG_LEVEL"} >>"$RT/waybar.log" 2>&1 </dev/null 9>&-   # waybar must not inherit the lock; waybar-run.sh = waybar behind ws-ipc-proxy.py
  # a start that dies at once is retried one time
  for _ in $(seq 20); do pgrep -u "$(id -u)" -x waybar >/dev/null && return 0; sleep 0.1; done
  setsid -f "$HERE/waybar-run.sh" ${WAYBAR_LOG_LEVEL:+--log-level "$WAYBAR_LOG_LEVEL"} >>"$RT/waybar.log" 2>&1 </dev/null 9>&-
}

cmd_menu() {
  local pick rows
  command -v fzf-menu >/dev/null 2>&1 || { note "Bar" "fzf-menu not found"; return 1; }
  rows=$'Compact bar\nFull bar\n'"$(hidden && echo 'Show bar' || echo 'Hide bar')"$'\nRestart waybar\nTheme: toggle black / night'
  pick=$(printf '%s\n' "$rows" | fzf-menu -p "bar ($(cmd_status))") || return 0
  case $pick in
    'Compact bar') "$0" mode compact ;;
    'Full bar') "$0" mode full ;;
    'Hide bar' | 'Show bar') "$0" hide toggle ;;
    'Restart waybar') "$0" restart ;;
    Theme*) theme toggle ;;
  esac
}

case ${1:-} in
  mode) shift; cmd_mode "${1:-toggle}" ;;
  hide) shift; cmd_hide "${1:-toggle}" ;;
  status) shift; cmd_status "${1:-}" ;;
  render) render ;;
  reload) reload ;;
  sync) shift; cmd_sync "${1:-}" ;;
  init) cmd_init ;;
  restart) cmd_restart ;;
  menu) cmd_menu ;;
  *) echo "usage: bar.sh mode toggle|compact|full | hide toggle|on|off | status [--short] | render | reload | sync [--if-stale] | init | restart | menu [--dry-run]" >&2; exit 2 ;;
esac
