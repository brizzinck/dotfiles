#!/usr/bin/env bash
# atuin-history.sh: rows, filter cycling and preview for the Ctrl+R history list (~/.config/zsh/history.zsh). The list itself
# is the shared modal fzf (vimfzf look, [I]/[N]); this script only feeds it from the local atuin database.
#
#   rows              NUL-separated records `exit TAB duration TAB age TAB directory TAB command` of the current filter
#                     (newest first, duplicates folded by atuin); the filter is the first line of $DF_ATUIN_STATE
#   cycle +1|-1       fzf `transform` action: next/previous filter (global -> workspace -> directory -> session), prints
#                     `reload(...)+change-header(...)`; workspace is skipped outside a git repository
#   header            the header text for the current filter
#   preview FILE      exit status, duration, age, directory and the full command of one record (FILE = fzf's {f})
#   filter            the filter name that `rows` uses now
# Environment: DF_ATUIN_STATE (state file, default $XDG_RUNTIME_DIR/atuin-fzf.$PPID), ATUIN_SESSION (the shell's id, atuin
# needs it for the session filter), ATUIN_BIN (test hook: the atuin binary).
set -u
atuin=${ATUIN_BIN:-atuin}
state=${DF_ATUIN_STATE:-${XDG_RUNTIME_DIR:-/tmp}/atuin-fzf.$PPID}
self=$(readlink -f "${BASH_SOURCE[0]}")

in_repo() { git rev-parse --show-toplevel >/dev/null 2>&1; }
cur() {
  local f
  f=$(head -n1 "$state" 2>/dev/null) || f=global
  case $f in global | workspace | directory | session) ;; *) f=global ;; esac
  [[ $f == workspace ]] && ! in_repo && f=directory
  printf '%s' "$f"
}
header() { printf 'filter: %s · Tab / Shift+Tab, NORMAL l / h: next / previous' "$(cur)"; }

case ${1:-} in
  rows)
    # -r: without a terminal atuin 18 prints oldest first and `--reverse` (documented as "oldest first") gives newest first
    exec "$atuin" search -r --filter-mode "$(cur)" --print0 \
      --format '{exit}\t{duration}\t{relativetime}\t{directory}\t{command}'
    ;;
  cycle)
    order=(global workspace directory session)
    in_repo || order=(global directory session)
    now=$(cur) i=0 n=${#order[@]} idx=0
    for ((i = 0; i < n; i++)); do [[ ${order[i]} == "$now" ]] && idx=$i; done
    step=${2:-+1}
    case $step in -1) idx=$(((idx + n - 1) % n)) ;; *) idx=$(((idx + 1) % n)) ;; esac
    printf '%s\n' "${order[idx]}" >"$state"
    printf 'reload(%q rows)+change-header(%s)' "$self" "$(header)"
    ;;
  header) header ;;
  filter) cur ;;
  preview)
    rec=$(tr -d '\0' <"${2:?preview FILE}") || exit 0
    ex=${rec%%$'\t'*}; rec=${rec#*$'\t'}
    du=${rec%%$'\t'*}; rec=${rec#*$'\t'}
    age=${rec%%$'\t'*}; rec=${rec#*$'\t'}
    dir=${rec%%$'\t'*}; cmd=${rec#*$'\t'}
    printf 'exit %s · %s · %s ago · %s\n%s\n' "$ex" "$du" "$age" "${dir/#$HOME/\~}" "$cmd"
    ;;
  *) printf 'usage: atuin-history.sh rows | cycle +1|-1 | header | filter | preview FILE\n' >&2; exit 2 ;;
esac
