#!/usr/bin/env bash
# Pick a URL from the current pane's scrollback and open it (prefix+u).
# Enter opens in the browser; ctrl-y (NORMAL mode: y) copies to the Wayland clipboard. The list is the shared modal fzf.
# Own script instead of tmux-fzf-url: that plugin installs a third-party binary via curl|bash.
set -euo pipefail

pane="${1:-${TMUX_PANE:-}}"
[ -n "$pane" ] || exit 1

urls=$(tmux capture-pane -J -p -S -3000 -t "$pane" |
  grep -oE "(https?|ftp|file)://[-[:alnum:]_+&@#/%?=~|!:,.;]*[-[:alnum:]_+&@#/%=~|]" |
  awk '!seen[$0]++' | tac) || true
[ -n "$urls" ] || { tmux display-message "no URLs in pane"; exit 0; }

# NORMAL y (yank) = ctrl-y: copy
export FZF_MENU_NORMAL_BINDS='y:become(printf "ctrl-y\n%s\n" {+})'
out=$(printf '%s\n' "$urls" |
  "$HOME/.local/bin/fzf-menu" --here -m --no-sort -p url --header='enter: open  ctrl-y / y: copy' --expect=ctrl-y) || exit 0
key=$(head -1 <<<"$out")
sel=$(tail -n +2 <<<"$out")
[ -n "$sel" ] || exit 0

if [ "$key" = "ctrl-y" ]; then
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$sel" | wl-copy
    tmux display-message "copied $(wc -l <<<"$sel") URL(s)"
  fi
else
  while IFS= read -r u; do
    nohup xdg-open "$u" >/dev/null 2>&1 &
  done <<<"$sel"
fi
