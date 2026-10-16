#!/usr/bin/env bash
# Fuzzy window switcher in rofi: every window on every workspace and monitor. SUPER+SHIFT+space.
# Rows are "ws  class  title" with the app icon; most recently focused first, the active window last.
# Enter focuses the window (`focuswindow address:`), which also switches to its workspace.
#   window-switcher.sh --list   print the rows (address, ws, class, title) without rofi
set -u

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

if [[ ${1:-} == --list ]]; then
  rows
  exit 0
fi

mapfile -t lines < <(rows)
((${#lines[@]})) || exit 0

addrs=()
for l in "${lines[@]}"; do
  IFS=$'\t' read -r addr _ <<<"$l"
  addrs+=("$addr")
done

# rofi's dmenu reads a "\0icon\x1f<name>" row option; a shell variable cannot hold the NUL, so stream the rows
emit() {
  local addr ws class title l
  for l in "${lines[@]}"; do
    IFS=$'\t' read -r addr ws class title <<<"$l"
    printf '%-6s %-26s %s\0icon\x1f%s\n' "$ws" "${class:0:26}" "$title" "${class,,}"
  done
}

n=${#lines[@]}
((n > 14)) && n=14
idx=$(emit | rofi -dmenu -i -p switch -show-icons -format i -no-custom \
  -theme-str "window { width: 900px; } listview { lines: $n; }") || exit 0

[[ -n $idx ]] && hyprd focuswindow "address:${addrs[idx]}" >/dev/null
