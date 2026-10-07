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
#   kill-session.sh -o / --others      # kill all sessions except the current one
#   kill-session.sh -c / --current     # kill current session safely
set -euo pipefail

current_session() {
  tmux display-message -p '#{session_name}' 2>/dev/null || echo ""
}

list_sessions() {
  local curr
  curr="$(current_session)"
  tmux list-sessions -F "#{session_name}	#{session_windows}	#{session_created}	#{session_attached}" 2>/dev/null | \
    awk -F'\t' -v curr="$curr" '
      {
        sname = $1
        nwin = $2
        created = strftime("%Y-%m-%d %H:%M", $3)
        att = ($4 > 0) ? "attached" : "detached"
        mark = (sname == curr) ? "*" : " "
        if (sname == curr) att = "current"
        printf "%s\t%s %-16s (%d win)  %s  [%s]\n", sname, mark, sname, nwin, created, att
      }
    '
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

  # Find a session that will survive
  local survivor=""
  for s in "${all_sessions[@]}"; do
    local is_target=0
    for t in "${targets[@]}"; do
      if [ "$s" = "$t" ]; then
        is_target=1
        break
      fi
    done
    if [ "$is_target" -eq 0 ]; then
      survivor="$s"
      break
    fi
  done

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
      tmux display-message "Сессия '${targets[0]}' удалена" 2>/dev/null || true
    else
      tmux display-message "Удалено сессий: ${#targets[@]}" 2>/dev/null || true
    fi
  fi
}

confirm_kill_one() {
  local target="${1:?session required}"
  if ! tmux has-session -t "$target" 2>/dev/null; then
    echo "Сессия '$target' уже не существует."
    sleep 0.5
    return 0
  fi

  local curr
  curr="$(current_session)"
  local total
  total="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | wc -l)"

  if [ "$target" = "$curr" ]; then
    if [ "$total" -le 1 ]; then
      printf "\nВнимание: '%s' — последняя активная сессия!\nЕё удаление закроет tmux сервер. Удалить? [y/N]: " "$target"
    else
      printf "\nУдалить текущую сессию '%s'?\nБудет выполнен переход в другую сессию. [y/N]: " "$target"
    fi
  else
    printf "\nУдалить сессию '%s'? [y/N]: " "$target"
  fi

  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "$target"
    echo "Сессия '$target' удалена."
    sleep 0.4
  else
    echo "Отмена."
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
    echo "Безымянных или временных сессий не найдено."
    sleep 0.8
    return 0
  fi

  if [ "$force" = "true" ]; then
    safe_kill "${unnamed[@]}"
    echo "Безымянные сессии удалены (${#unnamed[@]})."
    return 0
  fi

  printf "\nНайдено %d безымянных сессий: %s\nУдалить их? [y/N]: " "${#unnamed[@]}" "${unnamed[*]}"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "${unnamed[@]}"
    echo "Безымянные сессии удалены."
    sleep 0.8
  else
    echo "Отмена."
    sleep 0.4
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
    echo "Других сессий нет (активна только '$curr')."
    sleep 0.8
    return 0
  fi

  if [ "$force" = "true" ]; then
    safe_kill "${others[@]}"
    echo "Другие сессии удалены (${#others[@]})."
    return 0
  fi

  printf "\nУдалить все %d других сессий (кроме '%s'): %s\nПродолжить? [y/N]: " "${#others[@]}" "$curr" "${others[*]}"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "${others[@]}"
    echo "Другие сессии удалены."
    sleep 0.8
  else
    echo "Отмена."
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
    -o|--others)
      kill_others "$force"
      exit 0
      ;;
    -c|--current)
      curr="$(current_session)"
      if [ -z "$curr" ]; then
        echo "Не удалось определить текущую сессию."
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
        echo "Ошибка: укажите сессию для удаления."
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
      echo "Неизвестная опция: $1"
      exit 1
      ;;
    *)
      # Positional session name argument
      target="$1"
      shift
      if ! tmux has-session -t "$target" 2>/dev/null; then
        echo "Ошибка: сессия '$target' не существует!"
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

NORMAL_KEYS='j,k,g,G,J,K,i,a,/,q,d,x,U,O'
chosen="$(printf "%s\n" "$initial" | fzf \
  --layout=reverse --delimiter=$'\t' --with-nth=2.. --multi --cycle \
  --prompt='N> ' \
  --header='j/k move   tab select   enter/d kill   U kill unnamed   O kill others   q quit' \
  --bind 'j:down,k:up,g:first,G:last,J:preview-down,K:preview-up,q:abort' \
  --bind 'ctrl-d:half-page-down,ctrl-u:half-page-up,ctrl-f:page-down,ctrl-b:page-up' \
  --bind "d:execute(bash '$0' --confirm-kill {1})+reload(bash '$0' --list)" \
  --bind "x:execute(bash '$0' --confirm-kill {1})+reload(bash '$0' --list)" \
  --bind "U:execute(bash '$0' --unnamed)+reload(bash '$0' --list)" \
  --bind "O:execute(bash '$0' --others)+reload(bash '$0' --list)" \
  --bind "i:unbind($NORMAL_KEYS)+change-prompt(I> )" \
  --bind "a:unbind($NORMAL_KEYS)+change-prompt(I> )" \
  --bind "/:unbind($NORMAL_KEYS)+change-prompt(I> )+clear-query" \
  --bind "esc:transform:[ \"\$FZF_PROMPT\" = 'I> ' ] && echo 'rebind($NORMAL_KEYS)+change-prompt(N> )' || echo abort" \
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
  printf "\nУдалить выбранные сессии (%d шт: %s)? [y/N]: " "${#targets[@]}" "${targets[*]}"
  read -r ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    safe_kill "${targets[@]}"
    echo "Выбранные сессии удалены."
    sleep 0.5
  else
    echo "Отмена."
    sleep 0.3
  fi
fi
