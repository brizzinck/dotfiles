#!/usr/bin/env bash
# emoji: emoji picker in fzf-menu (vim keys). SUPER+period. The data is the emoji list that ships with rofimoji
# (picker/data/emojis_*.csv); the UI is the shared modal list. Recently used emoji come first.
#   Enter                type the emoji into the window that was focused before the menu (wtype, text on stdin)
#   Alt+Enter / y        copy it only
#   emoji.sh --list      print the rows (emoji <TAB> name and keywords)
#   emoji.sh --pick N    type/copy the emoji of row N without the menu (tests); --dry-run prints instead of acting
set -u
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/emoji"
RECENT="${EMOJI_RECENT:-$STATE/recent}"
DRY=0
args=()
for a in "$@"; do if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi; done
set -- "${args[@]+"${args[@]}"}"

data_dir() {
  local d
  for d in /usr/lib/python3*/site-packages/picker/data /usr/share/rofimoji/data; do
    [[ -d $d ]] && { echo "$d"; return 0; }
  done
  return 1
}

rows() {
  local d f
  d=$(data_dir) || return 1
  {
    # recently used first (they are already full rows in the recent file)
    [[ -s $RECENT ]] && cat "$RECENT"
    for f in "$d"/emojis_*.csv "$d"/additional/emojis_*.csv; do
      [[ -f $f && $f != */emojis_component.csv ]] && cat "$f"
    done | sed -E 's/ <small>\(([^)]*)\)<\/small>/\t\1/; t; s/^([^ ]+) (.*)$/\1\t\2/; s/^([^\t]+)\t([^\t]+)$/\1\t\2/' |
      awk -F'\t' '{ e = $1; sub(/ .*/, "", e); n = $0; sub(/^[^ \t]+[ \t]/, "", n); printf "%s\t%s\n", e, n }'
  } | awk -F'\t' '!seen[$1]++'
}

case ${1:-} in
  --list) rows; exit 0 ;;
esac

[[ -n $(data_dir) ]] || { notify-send -a emoji "Emoji picker" "emoji data not found (package rofimoji)"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
# shellcheck source=type-guard.sh
. "$HERE/type-guard.sh"
prev_win=$(tg_record)   # the window to type into: focused before the menu opens

remember() { # emoji row -> the recent file (30 newest, newest first)
  mkdir -p "$STATE"
  { printf '%s\n' "$1"; [[ -s $RECENT ]] && cat "$RECENT"; } | awk -F'\t' '!seen[$1]++' | head -n 30 >"$RECENT.tmp" &&
    mv "$RECENT.tmp" "$RECENT"
}

if [[ ${1:-} == --pick ]]; then
  pick=$(rows | sed -n "$((${2:?N} + 1))p")
  key=""
else
  export FZF_MENU_NORMAL_BINDS='y:become(printf "alt-enter\n%s\n" {})'
  res=$(rows | fzf-menu -p emoji --delimiter=$'\t' --with-nth=1.. --tabstop=4 --expect=alt-enter \
    --header 'Enter: type    Alt+Enter / y: copy only') || exit 0
  key=$(sed -n 1p <<<"$res")
  pick=$(sed -n 2p <<<"$res")
fi
emoji=${pick%%$'\t'*}
[[ -n $emoji ]] || exit 0
if ((DRY)); then
  [[ $key == alt-enter ]] && echo "wl-copy <$emoji>" || echo "wtype <$emoji>"
  exit 0
fi
remember "$pick"
if [[ $key == alt-enter ]] || ! have wtype; then
  printf '%s' "$emoji" | wl-copy
  notify-send -a emoji -t 1500 "Copied" "$emoji"
else
  sleep 0.2
  if tg_ok "$prev_win" emoji; then
    printf '%s' "$emoji" | wtype -
  else
    printf '%s' "$emoji" | wl-copy
  fi
fi
