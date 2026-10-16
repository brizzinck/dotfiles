#!/usr/bin/env bash
# Notification history in fzf-menu (vim keys). SUPER+SHIFT+X. Rows come from `dunstctl history` (newest first).
#   Enter       show the notification again (dunstctl history-pop ID)
#   Alt+d / d   remove it from the history (the list reloads in place)
#   notif-history.sh --list          print the rows (id <TAB> app, summary, first body line)
#   notif-history.sh --preview ID    the full text of one entry
#   notif-history.sh --rm ID         remove one entry
set -u
SELF=$(readlink -f "${BASH_SOURCE[0]}")

history_json() { dunstctl history 2>/dev/null; }

rows() {
  history_json | jq -r '.data[0][] |
    [ (.id.data | tostring),
      ((.appname.data // "") | .[0:16]),
      ((.summary.data // "") | gsub("[\t\n]"; " ") | .[0:60]),
      ((.body.data // "") | gsub("<[^>]*>"; "") | (split("\n")[0] // "") | gsub("[\t]"; " ") | .[0:80]) ]
    | "\(.[0])\t\(.[1] | . + (" " * (16 - length)))  \(.[2])\t\(.[3])"'
}

preview() {
  history_json | jq -r --argjson id "$1" '.data[0][] | select(.id.data == $id)
    | "\(.summary.data)\n\(.appname.data)  ·  urgency \(.urgency.data // "?")\n",
      ((.body.data // "") | gsub("<[^>]*>"; ""))'
}

case ${1:-} in
  --list) rows; exit 0 ;;
  --preview) preview "${2:?id}"; exit 0 ;;
  --rm) dunstctl history-rm "${2:?id}"; exit 0 ;;
esac

[[ -n $(rows) ]] || { notify-send -a history -t 2000 "Notification history" "the history is empty"; exit 0; }
reload="reload($SELF --list)"
export FZF_MENU_NORMAL_BINDS="d:execute-silent($SELF --rm {1})+$reload"
id=$(rows | fzf-menu -p history --delimiter=$'\t' --with-nth=2.. --accept-nth=1 --no-sort \
  --header 'Enter: show again   Alt+d / d: remove   Esc: normal mode' \
  --bind "alt-d:execute-silent($SELF --rm {1})+$reload" \
  --preview "$SELF --preview {1}" --preview-window 'right,45%,wrap,border-left') || exit 0
[[ -n $id ]] && dunstctl history-pop "$id"
