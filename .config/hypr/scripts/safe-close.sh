#!/usr/bin/env bash
# SUPER+W: close the active window. For the classes in ~/.config/hypr/protected-classes (browsers, terminals,
# Telegram) the first press only shows a dunst hint; a second press on the same window within 1 s closes it.
# A ghostty window says what its close takes with it (term-procs.py reads the tmux session and the foreground commands of its
# panes): "Closes term-17...: claude (2), nvim, go test" when the session is destroyed with the window (destroy-unattached),
# "Detaches term-17... (keeps running): ..." when it only detaches (new term-* sessions always get destroy-unattached from the
# tmux session-created hook; only a session that predates the hook fix, or a named one, still detaches); idle shells alone give
# the plain hint. The warning stays 2.5 s, so the second press has that long.
#   safe-close.sh              close (or arm) the active window
#   safe-close.sh --check [C]  print whether class C (default: the active window's) is protected
#   safe-close.sh --what       print the warning text for the active window (no close, no notification)
set -u

list="$HOME/.config/hypr/protected-classes"
state="${XDG_RUNTIME_DIR:-/tmp}/safe-close.state"
window_ms=1000
warn_ms=2500
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

# "kind<TAB>session<TAB>destroys<TAB>attached<TAB>summary" of a ghostty window (pid) -> the warning title, empty when nothing runs
close_warning() {
  local pid=$1 kind session destroys _ summary
  IFS=$'\t' read -r kind session destroys _ summary < <(timeout 3 python3 "$HERE/term-procs.py" "$pid" 2>/dev/null)
  [[ -n ${summary:-} ]] || return 0
  if [[ $kind == tmux && $destroys != 1 ]]; then
    printf 'Detaches %s (keeps running): %s' "$session" "$summary"
  elif [[ $kind == tmux ]]; then
    printf 'Closes %s: %s' "$session" "$summary"
  else
    printf 'Closes this terminal: %s' "$summary"
  fi
}

is_protected() {
  [[ -r $list ]] || return 1
  grep -qixF -- "$1" < <(grep -vE '^[[:space:]]*(#|$)' "$list")
}

if [[ ${1:-} == --check ]]; then
  c=${2:-$(hyprctl activewindow -j | jq -r '.class // ""')}
  if is_protected "$c"; then echo "protected: $c"; else echo "plain: $c"; fi
  exit 0
fi

aw=$(hyprctl activewindow -j) || exit 0
addr=$(jq -r '.address // ""' <<<"$aw")
class=$(jq -r '.class // ""' <<<"$aw")
pid=$(jq -r '.pid // ""' <<<"$aw")
[[ -n $addr ]] || exit 0

if [[ ${1:-} == --what ]]; then
  [[ $class == com.mitchellh.ghostty && -n $pid ]] && close_warning "$pid"
  echo
  exit 0
fi

if is_protected "$class"; then
  now=$(date +%s%3N)
  if [[ -r $state ]]; then
    read -r last_addr last_ms last_win <"$state"
    if [[ $last_addr == "$addr" ]] && ((now - last_ms < ${last_win:-$window_ms})); then
      rm -f "$state"
      exec hyprd killactive
    fi
  fi
  warning=""
  [[ $class == com.mitchellh.ghostty && -n $pid ]] && warning=$(close_warning "$pid")
  if [[ -n $warning ]]; then
    printf '%s %s %s\n' "$addr" "$now" "$warn_ms" >"$state"
    notify-send -a safe-close -u normal -t "$warn_ms" -h string:x-dunst-stack-tag:safe-close \
      "$warning" "Press SUPER+W again to close"
  else
    printf '%s %s %s\n' "$addr" "$now" "$window_ms" >"$state"
    notify-send -a safe-close -u low -t "$window_ms" -h string:x-dunst-stack-tag:safe-close \
      "Press SUPER+W again to close" "$class"
  fi
  exit 0
fi

exec hyprd killactive
