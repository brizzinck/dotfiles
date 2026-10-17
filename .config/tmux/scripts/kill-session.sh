#!/usr/bin/env bash
# Bound to prefix+X / prefix+Ctrl-x, runs inside a tmux popup.
# Interactively lists all active tmux sessions in fzf, with preview of windows and panes,
# and allows deleting (killing) sessions safely.
#
# Also callable directly from shell:
#   kill-session.sh                    # interactive picker
#   kill-session.sh <session_name>     # kill specific session safely (with confirmation)
#   kill-session.sh -f <session_name>  # force kill session without confirmation
#   kill-session.sh -u / --unnamed     # kill all unnamed/temporary sessions (numbers or term-*)
#   kill-session.sh -d / --detached    # pick (multi-select, confirm) unattached term-* sessions to kill; each row shows what runs in it
#   kill-session.sh -o / --others      # kill all sessions except the current one
#   kill-session.sh -c / --current     # kill current session safely
set -euo pipefail

current_session() {
  tmux display-message -p '#{session_name}' 2>/dev/null || echo ""
}

TERM_PROCS="$HOME/.config/hypr/scripts/term-procs.py"

# unattached term-* sessions as "name<TAB>created<TAB>windows<TAB>foreground commands" (term-procs.py reads /proc)
detached_terms() {
  timeout 5 python3 "$TERM_PROCS" --detached 2>/dev/null || true
}

list_sessions() {
  local curr name created nwin attached mark att extra
  curr="$(current_session)"
  declare -A cmds=()
  while IFS=$'\t' read -r name _ _ extra; do
    [ -n "$name" ] && cmds[$name]="$extra"
  done < <(detached_terms)
  while IFS=$'\t' read -r name nwin created attached; do
    mark=" "
    [ "$name" = "$curr" ] && mark="*"
    att="detached"
    [ "$attached" -gt 0 ] && att="attached"
    [ "$name" = "$curr" ] && att="current"
    extra=""
    if [[ -v "cmds[$name]" ]]; then
      extra="  runs: ${cmds[$name]:-only idle shells}"
    fi
    printf '%s\t%s %-16s (%d win)  %s  [%s]%s\n' "$name" "$mark" "$name" "$nwin" \
      "$(date -d "@$created" '+%Y-%m-%d %H:%M')" "$att" "$extra"
  done < <(tmux list-sessions -F "#{session_name}	#{session_windows}	#{session_created}	#{session_attached}" 2>/dev/null)
}

preview_session() {
  local s="${1:-}"
  if [ -z "$s" ] || ! tmux has-session -t "$s" 2>/dev/null; then
    echo "Session '$s' not found."
    return 0
  fi
  local created_ts
  created_ts="$(tmux display-message -p -t "$s" "#{session_created}" 2>/dev/null || echo "")"
  local created_str
  created_str="$(date -d "@$created_ts" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$created_ts")"
  local n_att
  n_att="$(tmux display-message -p -t "$s" "#{session_attached}" 2>/dev/null || echo "0")"

  echo "Session: $s"
  echo "Created: $created_str ($n_att client attached)"
  echo ""
  echo "Windows:"
  tmux list-windows -t "$s" -F "  #I: #W #{?window_active,[active],} (#{window_panes} panes)  [#{pane_current_command}] #{pane_current_path}" 2>/dev/null || true
}

safe_kill() {
  local targets=("$@")
  [ ${#targets[@]} -gt 0 ] || return 0

  local curr
  curr="$(current_session)"

  local -a all_sessions=()
  mapfile -t all_sessions < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  # Check if current session is among targets
  local includes_curr=0
  for t in "${targets[@]}"; do
    if [ "$t" = "$curr" ]; then
      includes_curr=1
      break
    fi
  done

  is_target() {
    local s="$1" t
    for t in "${targets[@]}"; do
      [ "$s" = "$t" ] && return 0
    done
    return 1
  }

  # Find a session that will survive: the client's previous session first,
  # otherwise any session not being killed
  local survivor=""
  local last
  last="$(tmux display-message -p '#{client_last_session}' 2>/dev/null || echo "")"
  if [ -n "$last" ] && tmux has-session -t "=$last" 2>/dev/null && ! is_target "$last"; then
    survivor="$last"
  else
    for s in "${all_sessions[@]}"; do
      if ! is_target "$s"; then
        survivor="$s"
        break
      fi
    done
  fi

  # Killing the current (and only remaining) session: create a fresh one so the
  # client moves there instead of the tmux server exiting
  if [ "$includes_curr" -eq 1 ] && [ -z "$survivor" ]; then
    local fresh="main" i=1
    while tmux has-session -t "=$fresh" 2>/dev/null || is_target "$fresh"; do
      fresh="main-$i"
      i=$((i + 1))
    done
    tmux new-session -d -s "$fresh" -c "$HOME"
    survivor="$fresh"
  fi

  # If current session will be killed, switch client first
  if [ "$includes_curr" -eq 1 ] && [ -n "$survivor" ]; then
    tmux switch-client -t "$survivor" 2>/dev/null || true
  fi

  for t in "${targets[@]}"; do
    if tmux has-session -t "$t" 2>/dev/null; then
      tmux kill-session -t "$t" 2>/dev/null || true
    fi
  done

  if [ -n "$survivor" ]; then
    if [ ${#targets[@]} -eq 1 ]; then
      tmux display-message "Session '${targets[0]}' killed" 2>/dev/null || true
    else
      tmux display-message "Sessions killed: ${#targets[@]}" 2>/dev/null || true
    fi
  fi
}

confirm_kill_one() {
  local target="${1:?session required}"
  if ! tmux has-session -t "$target" 2>/dev/null; then
    echo "Session '$target' no longer exists."
    sleep 0.5
    return 0
  fi

  local curr
  curr="$(current_session)"
  local total
  total="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | wc -l)"

  if [ "$target" = "$curr" ]; then
    if [ "$total" -le 1 ]; then
      printf "\nWarning: '%s' is the last active session!\nA new one will be created in its place. Kill it? [y/N]: " "$target"
    else
      printf "\nKill the current session '%s'?\nYou will be switched to another session. [y/N]: " "$target"
    fi
  else
    printf "\nKill session '%s'? [y/N]: " "$target"
  fi

  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "$target"
    echo "Session '$target' killed."
    sleep 0.4
  else
    echo "Cancelled."
    sleep 0.3
  fi
}

kill_unnamed() {
  local force="${1:-false}"
  local -a unnamed=()
  while IFS= read -r s; do
    if [[ "$s" =~ ^([0-9]+|term-[0-9]+)$ ]]; then
      unnamed+=("$s")
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  if [ ${#unnamed[@]} -eq 0 ]; then
    echo "No unnamed or temporary sessions found."
    sleep 0.8
    return 0
  fi

  if [ "$force" = "true" ]; then
    safe_kill "${unnamed[@]}"
    echo "Unnamed sessions killed (${#unnamed[@]})."
    return 0
  fi

  printf "\nFound %d unnamed sessions: %s\nKill them? [y/N]: " "${#unnamed[@]}" "${unnamed[*]}"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "${unnamed[@]}"
    echo "Unnamed sessions killed."
    sleep 0.8
  else
    echo "Cancelled."
    sleep 0.4
  fi
}

# Unattached term-* sessions piled up (a closed ghostty window used to only detach): list them with what runs in each,
# kill only the picked ones. Nothing is killed without the final confirmation.
kill_detached() {
  local rows chosen pick name created nwin cmds when
  local -a targets=()
  rows="$(detached_terms)"
  if [ -z "$rows" ]; then
    echo "No detached terminal sessions (term-*)."
    sleep 0.8
    return 0
  fi
  local list=""
  while IFS=$'\t' read -r name created nwin cmds; do
    when="$(date -d "@$created" '+%m-%d %H:%M')"
    list+="$name"$'\t'"$(printf '%-26s %s  %s win  runs: %s' "$name" "$when" "$nwin" "${cmds:-only idle shells}")"$'\n'
  done <<<"$rows"
  local menu="${KILL_SESSION_MENU:-$HOME/.local/bin/fzf-menu}" here=()  # KILL_SESSION_MENU: tests
  [ -t 0 ] && here=(--here)
  chosen="$(printf '%s' "$list" | "$menu" "${here[@]}" -m -p detached --delimiter=$'\t' --with-nth=2.. \
    --header='Tab select (Ctrl-a all)   Enter: review and kill   Esc: normal mode   q quit' \
    --bind='ctrl-a:select-all' --preview="bash '$0' --preview {1}" --preview-window='right,50%,wrap')" || return 0
  [ -n "$chosen" ] || return 0
  while IFS= read -r pick; do
    name="${pick%%$'\t'*}"
    [ -n "$name" ] && targets+=("$name")
  done <<<"$chosen"
  printf '\nKill %d detached terminal session(s) and everything running in them?\n' "${#targets[@]}"
  printf '  %s\n' "${targets[@]}"
  printf 'Continue? [y/N]: '
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "${targets[@]}"
    echo "Killed ${#targets[@]} detached session(s)."
    sleep 0.6
  else
    echo "Cancelled."
    sleep 0.3
  fi
}

kill_others() {
  local force="${1:-false}"
  local curr
  curr="$(current_session)"
  local -a others=()
  while IFS= read -r s; do
    if [ "$s" != "$curr" ]; then
      others+=("$s")
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  if [ ${#others[@]} -eq 0 ]; then
    echo "There are no other sessions (only '$curr' is active)."
    sleep 0.8
    return 0
  fi

  if [ "$force" = "true" ]; then
    safe_kill "${others[@]}"
    echo "Other sessions killed (${#others[@]})."
    return 0
  fi

  printf "\nKill all %d other sessions (except '%s'): %s\nContinue? [y/N]: " "${#others[@]}" "$curr" "${others[*]}"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "${others[@]}"
    echo "Other sessions killed."
    sleep 0.8
  else
    echo "Cancelled."
    sleep 0.4
  fi
}

# CLI Argument parsing
force=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preview)
      preview_session "${2:-}"
      exit 0
      ;;
    --list)
      list_sessions
      exit 0
      ;;
    --confirm-kill)
      confirm_kill_one "${2:-}"
      exit 0
      ;;
    -f|--force)
      force=true
      shift
      ;;
    -u|--unnamed)
      kill_unnamed "$force"
      exit 0
      ;;
    -d|--detached)
      kill_detached
      exit 0
      ;;
    -o|--others)
      kill_others "$force"
      exit 0
      ;;
    -c|--current)
      curr="$(current_session)"
      if [ -z "$curr" ]; then
        echo "Could not determine the current session."
        exit 1
      fi
      if [ "$force" = "true" ]; then
        safe_kill "$curr"
      else
        confirm_kill_one "$curr"
      fi
      exit 0
      ;;
    -k|--kill)
      shift
      targets=()
      while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
        targets+=("$1")
        shift
      done
      if [ ${#targets[@]} -eq 0 ]; then
        echo "Error: name the session to kill."
        exit 1
      fi
      if [ "$force" = "true" ]; then
        safe_kill "${targets[@]}"
      else
        for t in "${targets[@]}"; do
          confirm_kill_one "$t"
        done
      fi
      exit 0
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS] [SESSION_NAME]"
      echo ""
      echo "Options:"
      echo "  -u, --unnamed          Kill all unnamed/temporary sessions (numbers or term-*)"
      echo "  -d, --detached         Pick unattached term-* sessions to kill (shows what runs in each)"
      echo "  -o, --others           Kill all sessions except the current one"
      echo "  -c, --current          Kill current session safely"
      echo "  -k, --kill <session>   Kill specified session(s)"
      echo "  -f, --force            Skip confirmation prompt"
      echo "  -h, --help             Show this help message"
      echo ""
      echo "Without arguments, opens an interactive fzf picker."
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      exit 1
      ;;
    *)
      # Positional session name argument
      target="$1"
      shift
      if ! tmux has-session -t "$target" 2>/dev/null; then
        echo "Error: session '$target' does not exist!"
        exit 1
      fi
      if [ "$force" = "true" ]; then
        safe_kill "$target"
      else
        confirm_kill_one "$target"
      fi
      exit 0
      ;;
  esac
done

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is not installed (pacman -S fzf)."
  read -n1 -r -p "press any key..."
  exit 1
fi

initial="$(list_sessions)"
if [ -z "$initial" ]; then
  echo "No active tmux sessions found."
  read -n1 -r -p "press any key..."
  exit 0
fi

# The list is the shared modal fzf (INSERT opens, Esc = NORMAL with j/k g/G, d/x kill, U kill unnamed, D pick detached terminals, O kill others,
# q quit; ua/ru twins come from the library). NORMAL-mode extras travel in FZF_MENU_NORMAL_BINDS.
FZF_MENU="$HOME/.local/bin/fzf-menu"
if [ ! -x "$FZF_MENU" ]; then
  echo "fzf-menu is missing ($FZF_MENU): run stow in ~/dotfiles"
  read -n1 -r -p "press any key..."
  exit 1
fi
reload="reload(bash '$0' --list)"
export FZF_MENU_NORMAL_BINDS="d:execute(bash '$0' --confirm-kill {1})+$reload
x:execute(bash '$0' --confirm-kill {1})+$reload
U:execute(bash '$0' --unnamed)+$reload
D:execute(bash '$0' --detached)+$reload
O:execute(bash '$0' --others)+$reload"
chosen="$(printf "%s\n" "$initial" | "$FZF_MENU" --here -m -p sessions --delimiter=$'\t' --with-nth=2.. \
  --header='Tab select   Enter kill   Esc: normal mode   NORMAL: j/k g/G move   d kill   U kill unnamed   D detached terminals   O kill others   q quit' \
  --preview="bash '$0' --preview {1}" \
  --preview-window='right,50%,wrap')" || exit 0

[ -n "$chosen" ] || exit 0

# Parse selected session names from chosen
mapfile -t lines <<< "$chosen"
targets=()
for l in "${lines[@]}"; do
  sname="${l%%$'\t'*}"
  sname="$(echo "$sname" | xargs)"
  [ -n "$sname" ] && targets+=("$sname")
done

if [ ${#targets[@]} -eq 1 ]; then
  confirm_kill_one "${targets[0]}"
elif [ ${#targets[@]} -gt 1 ]; then
  printf "\nKill the selected sessions (%d: %s)? [y/N]: " "${#targets[@]}" "${targets[*]}"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "${targets[@]}"
    echo "Selected sessions killed."
    sleep 0.5
  else
    echo "Cancelled."
    sleep 0.3
  fi
fi
