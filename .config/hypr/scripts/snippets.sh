#!/usr/bin/env bash
# snippets: fzf-menu picker (vim keys) over ~/.config/snippets/snippets.tsv (name<TAB>text, `\n` = newline, `#` comments).
# Variables: {date} {time} {datetime} {clipboard} ({clip}). Enter types the text into the focused window with wtype,
# Alt+Enter only copies it. SUPER+SHIFT+period.
#   snippets.sh                 pick and insert
#   snippets.sh --list          names
#   snippets.sh --expand NAME   print the expanded text
set -u
FILE="${SNIPPETS_FILE:-$HOME/.config/snippets/snippets.tsv}"

expand() { # text from stdin-free arg
  local t=$1 clip=""
  if [[ $t == *"{clip"* ]]; then clip=$(wl-paste -n -t text/plain 2>/dev/null || true); fi
  t=${t//\{datetime\}/$(date '+%Y-%m-%d %H:%M')}
  t=${t//\{date\}/$(date +%F)}
  t=${t//\{time\}/$(date +%H:%M)}
  t=${t//\{clipboard\}/$clip}
  t=${t//\{clip\}/$clip}
  printf '%s' "${t//\\n/$'\n'}"
}
text_of() { awk -F'\t' -v n="$1" '!/^#/ && $1 == n { sub(/^[^\t]*\t/, ""); print; exit }' "$FILE"; }
names() { awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { print $1 }' "$FILE"; }

case ${1:-} in
  --list) names; exit 0 ;;
  --expand) expand "$(text_of "${2:?name}")"; echo; exit 0 ;;
esac

[[ -r $FILE ]] || { notify-send -a snippets "Snippets" "missing $FILE"; exit 1; }
# NORMAL y (yank) = Alt+Enter: copy only
export FZF_MENU_NORMAL_BINDS='y:become(printf "alt-enter\n%s\n" {1})'
res=$(awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { t = $2; gsub(/\\n/, " ", t); printf "%s\t%s\n", $1, substr(t, 1, 70) }' "$FILE" |
  fzf-menu -p snippet --delimiter=$'\t' --tabstop=24 --expect=alt-enter \
    --header 'Enter: type    Alt+Enter / y: copy only') || exit 0
key=$(sed -n 1p <<<"$res")
pick=$(sed -n 2p <<<"$res")
name=${pick%%$'\t'*}
[[ -n $name ]] || exit 0
out=$(expand "$(text_of "$name")"; echo x); out=${out%x}
if [[ $key == alt-enter ]] || ! command -v wtype >/dev/null 2>&1; then
  printf '%s' "$out" | wl-copy
  notify-send -a snippets -t 2000 "Snippet copied" "$name"
else
  sleep 0.2
  wtype -- "$out"
fi
