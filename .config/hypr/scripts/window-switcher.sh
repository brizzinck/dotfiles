#!/usr/bin/env bash
# Fuzzy window switcher (fzf-menu, vim keys): every window on every workspace and monitor. SUPER+SHIFT+space.
# Rows are "ws  class  title"; most recently focused first, the active window last. The preview pane shows the
# window's details and a large app icon (kitty graphics). Enter focuses the window (`focuswindow address:`), which
# also switches to its workspace.
#   window-switcher.sh --list          print the rows (address, ws, class, title) without the menu
#   window-switcher.sh --preview ADDR  the preview pane text (details; the icon is drawn after it by the menu)
set -u
FZF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fzf"
SELF=$(readlink -f "${BASH_SOURCE[0]}")

rows() {
  hyprctl clients -j | jq -r --argjson multi "$(hyprctl monitors -j | jq 'length > 1')" '
    [ .[] | select(.mapped and (.workspace.id != -1)) ]
    | sort_by(.focusHistoryID)
    | (if length > 1 then .[1:] + [.[0]] else . end)
    | .[]
    | [ .address,
        ((if $multi then (.monitor | tostring) + ":" else "" end) + (.workspace.name | sub("^special:"; "*"))),
        .class,
        (.title | gsub("[\t\n]"; " ") | .[0:90]) ]
    | @tsv'
}

# the fzf-menu server's own window is not a window to switch to
hide_menu() { grep -v $'\tfloat.tui\tfzf-menu-server$\|\tfloat.tui\tmenu: ' || true; }

preview() { # ADDR: details, then the icon
  local addr=$1 json class icon lines
  json=$(hyprctl clients -j | jq -c --arg a "$addr" '.[] | select(.address == $a)')
  [[ -n $json ]] || { echo "window is gone"; return 0; }
  jq -r '"\(.title)\n\(.class)  ·  pid \(.pid)\nworkspace \(.workspace.name)  ·  \(.size[0])x\(.size[1])  ·  \(if .floating then "floating" else "tiled" end)\(if .pinned then "  ·  pinned" else "" end)\(if .xwayland then "  ·  xwayland" else "" end)\n"' <<<"$json"
  class=$(jq -r '.class' <<<"$json")
  icon=$("$FZF_DIR/app-icon.sh" "$class")
  [[ -n $icon ]] || { echo "(no icon found for $class)"; return 0; }
  lines=$(( ${FZF_PREVIEW_LINES:-24} - 5 ))
  FZF_PREVIEW_LINES=$(( lines < 4 ? 4 : lines )) "$FZF_DIR/image-preview.sh" "$icon"
}

case ${1:-} in
  --list) rows | hide_menu; exit 0 ;;
  --preview) preview "${2:?address}"; exit 0 ;;
esac

mapfile -t lines < <(rows | hide_menu)
((${#lines[@]})) || exit 0

# fzf rows: address (hidden) <TAB> ws, class, title
pick=$(for l in "${lines[@]}"; do
  IFS=$'\t' read -r addr ws class title <<<"$l"
  printf '%s\t%-6s %-26s %s\n' "$addr" "$ws" "${class:0:26}" "$title"
done | fzf-menu -p switch --delimiter=$'\t' --with-nth=2.. --accept-nth=1 \
  --header 'Enter: focus   Esc: normal mode   Alt+j/k: scroll preview' \
  --preview "$SELF --preview {1}" --preview-window 'right,45%,border-left') || exit 0

[[ -n $pick ]] && hyprd focuswindow "address:$pick" >/dev/null

