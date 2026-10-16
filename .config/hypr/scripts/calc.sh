#!/usr/bin/env bash
# calc: calculator on libqalculate (qalc) in fzf-menu (vim keys). SUPER+equal.
# Type an expression: the header shows the live result. Enter copies the result to the clipboard (and the history keeps
# it). The list below the input is the history, newest first; in NORMAL mode y copies the highlighted entry's result,
# Enter on an empty input does the same. History: ~/.local/state/calc/history (expression <TAB> result, 200 lines).
#   calc.sh                  open the calculator
#   calc.sh --eval EXPR      print the result of one expression (the header uses this)
#   calc.sh --history        print the history rows
#   --dry-run                print what would run
set -u
HIST_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/calc"
HIST="${CALC_HISTORY:-$HIST_DIR/history}"
SELF=$(readlink -f "${BASH_SOURCE[0]}")
DRY=0
[[ ${1:-} == --dry-run ]] && { DRY=1; shift; }

evaluate() { # expression -> terse result (first line), empty when qalc cannot parse it
  [[ -n ${1// /} ]] || return 0
  timeout 3 qalc -t -- "$1" 2>/dev/null | head -n1
}

history_rows() { # result <TAB> display
  [[ -s $HIST ]] || return 0
  tac "$HIST" | awk -F'\t' '{ printf "%s\t%s   =   %s\n", $2, $1, $2 }'
}

case ${1:-} in
  --eval) shift; r=$(evaluate "$*"); [[ -n $r ]] && printf '= %s' "$r" || printf '(type an expression)'; exit 0 ;;
  --history) history_rows; exit 0 ;;
esac

if ((DRY)); then
  if command -v qalc >/dev/null 2>&1 && command -v fzf-menu >/dev/null 2>&1; then
    echo "fzf-menu -p calc (qalc live result in the header, Enter copies it)"
  else
    echo "no calculator installed (libqalculate, fzf-menu)"
  fi
  exit 0
fi
command -v qalc >/dev/null 2>&1 || { notify-send -a calc "Calculator" "Install libqalculate (qalc)"; exit 0; }
command -v fzf-menu >/dev/null 2>&1 || { notify-send -a calc "Calculator" "fzf-menu is missing"; exit 1; }

mkdir -p "$HIST_DIR"
export FZF_MENU_NORMAL_BINDS='y:accept'
res=$(history_rows | fzf-menu -p calc --disabled --print-query --no-sort --delimiter=$'\t' --with-nth=2.. \
  --header '(type an expression)' \
  --bind "change:transform-header:$SELF --eval {q}") || true
# status 1 (Enter with no matching row) is fine: the query is still the first output line
query=$(sed -n 1p <<<"$res")
sel=$(sed -n 2p <<<"$res")
if [[ -n $query ]]; then
  result=$(evaluate "$query")
  [[ -n $result ]] || { notify-send -a calc -t 3000 "Calculator" "cannot evaluate: $query"; exit 1; }
  { printf '%s\t%s\n' "$query" "$result"; } >>"$HIST"
  tail -n 200 "$HIST" >"$HIST.tmp" && mv "$HIST.tmp" "$HIST"
elif [[ -n $sel ]]; then
  result=${sel%%$'\t'*}
else
  exit 0
fi
printf '%s' "$result" | wl-copy
notify-send -a calc -t 3000 "Calculator" "$result  (copied)"
